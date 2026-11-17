import Foundation

// Serialized by the Paint.NET 5.2 document engine from known BGRA samples.
let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: fixture)
let imported = try PDNFile.read(data)
let reopened = try PDNFile.read(PDNFile.write(imported))
precondition(imported.resolution == .standard && reopened.resolution == imported.resolution)
precondition(reopened.metadata.map(\.key) == imported.metadata.map(\.key))
precondition(reopened.metadata.map(\.value) == imported.metadata.map(\.value))

let base: [UInt8] = [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255,
                     98, 31, 71, 0, 200, 20, 50, 128, 255, 255, 255, 255]
let top: [UInt8] = [4, 3, 2, 1, 99, 101, 5, 200, 10, 240, 20, 255,
                    42, 23, 1, 0, 0, 20, 0, 20, 9, 12, 15, 100]
for stack in [imported, reopened] {
    precondition(stack.layers.map(\.name) == ["Base", "Top – 日本"])
    precondition(stack.layers.map(\.isVisible) == [true, false])
    precondition(stack.layers.map(\.opacity) == [255, 161])
    precondition(stack.layers.map(\.blendMode) == [.normal, .normal])
    precondition(stack.layers.map(\.pdnPixels) == [Data(base), Data(top)])
    precondition(stack.activeLayer.image.width == 2 && stack.activeLayer.image.height == 3)
}
do {
    _ = try PDNFile.read(data.dropLast())
    preconditionFailure("Accepted truncated pixel data")
} catch PDNError.invalid {}

for mode in LayerBlendMode.allCases {
    var changed = imported
    changed.layers[1].blendMode = mode
    changed.layers[1].opacity = 73
    let saved = try PDNFile.read(PDNFile.write(changed))
    precondition(saved.layers[1].blendMode == mode && saved.layers[1].opacity == 73)
    precondition(saved.layers[1].pdnPixels == Data(top))
}

var blend = Data([200, 0, 255, 255, 0, 0, 0, 0])
LayerBlendMode.additive.composite(Data([100, 64, 31, 255, 100, 64, 31, 255]), onto: &blend, opacity: 128)
precondition(blend == Data([228, 32, 255, 255, 100, 64, 31, 128]))

var layers = imported
layers.layers[0].opacity = 128
layers.layers[0].blendMode = .multiply
layers.layers[1].blendMode = .screen
precondition(layers.duplicateActiveLayer())
precondition(layers.active == 2 && layers.layers.count == 3)
precondition(layers.activeLayer.name == "Top – 日本" && layers.activeLayer.pdnPixels == Data(top))
precondition(layers.activeLayer.opacity == 161 && layers.activeLayer.blendMode == .screen)
precondition(!layers.activeLayer.isVisible && !layers.activeLayer.isBackground)
layers.layers[2].opacity = 0
precondition(layers.mergeActiveLayerDown() && layers.activeLayer.pdnPixels == Data(top))
precondition(layers.mergeActiveLayerDown() && layers.active == 0 && layers.layers.count == 1)
precondition(layers.activeLayer.name == "Base" && layers.activeLayer.isVisible)
precondition(layers.activeLayer.opacity == 128 && layers.activeLayer.blendMode == .multiply)
let merged = try PDNFile.read(PDNFile.write(layers))
precondition(merged.activeLayer.pdnPixels == layers.activeLayer.pdnPixels)
precondition(merged.activeLayer.pdnPixels?[4..<12] == Data([49, 255, 2, 255, 255, 152, 13, 255]))
precondition(!layers.mergeActiveLayerDown())

let incoming = try PaintFiles.layersForImport(from: fixture)
precondition(incoming.map(\.name) == ["Layers52: Base", "Layers52: Top – 日本"])
precondition(incoming.map(\.isVisible) == [true, false])
let widePixels = Data([255, 0, 0, 255, 0, 0, 0, 0, 0, 255, 0, 255])
let wideImage = BGRA8.image(from: widePixels, width: 3, height: 1)!
var expanded = imported
try expanded.importLayers(incoming + [PaintLayer(name: "Wide", image: wideImage, pdnPixels: widePixels)])
precondition(expanded.layers.count == 5 && expanded.activeLayer.name == "Wide")
precondition(expanded.layers.allSatisfy { $0.image.width == 3 && $0.image.height == 3 })
precondition(expanded.layers[0].pdnPixels?[0..<12] == Data(base.prefix(8)) + Data(count: 4))
precondition(expanded.activeLayer.pdnPixels == widePixels + Data(count: 24))

expanded.layers[4].blendMode = .screen
expanded.layers[4].opacity = 128
let flattened = expanded.flattenedLayer()!
precondition(flattened.name == "Background" && flattened.isBackground)
precondition(flattened.opacity == 255 && flattened.isVisible && flattened.blendMode == .normal)
let flatDoc = LayerStack(layers: [flattened], active: 0)
let flatAgain = try PDNFile.read(PDNFile.write(flatDoc))
precondition(flatAgain.activeLayer.pdnPixels == expanded.blendComposite()?.pixels)
print("Paint.NET 5.2 layer round-trip passed")
