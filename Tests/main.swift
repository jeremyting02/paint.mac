import Foundation

// Serialized by the Paint.NET 5.2 document engine from known BGRA samples.
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let imported = try PDNFile.read(data)
let reopened = try PDNFile.read(PDNFile.write(imported))

let base: [UInt8] = [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255,
                     98, 31, 71, 0, 200, 20, 50, 128, 255, 255, 255, 255]
let top: [UInt8] = [4, 3, 2, 1, 99, 101, 5, 200, 10, 240, 20, 255,
                    42, 23, 1, 0, 0, 20, 0, 20, 9, 12, 15, 100]
for stack in [imported, reopened] {
    precondition(stack.layers.map(\.name) == ["Base", "Top – 日本"])
    precondition(stack.layers.map(\.isVisible) == [true, false])
    precondition(stack.layers.map(\.opacity) == [255, 161])
    precondition(stack.layers.map(\.pdnPixels) == [Data(base), Data(top)])
    precondition(stack.activeLayer.image.width == 2 && stack.activeLayer.image.height == 3)
}
do {
    _ = try PDNFile.read(data.dropLast())
    preconditionFailure("Accepted truncated pixel data")
} catch PDNError.invalid {}
print("Paint.NET 5.2 layer round-trip passed")
