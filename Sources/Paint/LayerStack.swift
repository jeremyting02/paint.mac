import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PaintLayer {
    var name: String
    var image: CGImage { didSet { pdnPixels = nil } }
    var isVisible = true
    var isBackground = false
    var opacity: UInt8 = 255
    var blendMode: LayerBlendMode = .normal
    var metadata: [PDNMetadata] = []
    var pdnPixels: Data?

    var straightPixels: Data? { pdnPixels ?? BGRA8.pixels(from: image) }

    mutating func crop(to rect: CGRect) -> Bool {
        guard let cropped = image.cropping(to: rect) else { return false }
        let original = pdnPixels
        let stride = image.width * 4
        image = cropped
        if let original {
            var pixels = Data(capacity: cropped.width * cropped.height * 4)
            for row in Int(rect.minY)..<(Int(rect.minY) + cropped.height) {
                let start = row * stride + Int(rect.minX) * 4
                pixels.append(original[start..<(start + cropped.width * 4)])
            }
            pdnPixels = pixels
        }
        return true
    }
}

struct LayerStack {
    static let limit = 8
    var layers: [PaintLayer] // Bottom to top.
    var active: Int
    var metadata: [PDNMetadata] = []

    var activeLayer: PaintLayer { layers[active] }
    var canDuplicate: Bool { layers.count < Self.limit }
    var canMergeDown: Bool { active > 0 }
    var needsBlendComposite: Bool {
        layers.lazy.filter { $0.isVisible && $0.opacity > 0 }.dropFirst().contains { $0.blendMode != .normal }
    }

    mutating func duplicateActiveLayer() -> Bool {
        guard canDuplicate else { return false }
        var copy = activeLayer
        copy.isBackground = false
        active += 1
        layers.insert(copy, at: active)
        return true
    }

    mutating func mergeActiveLayerDown() -> Bool {
        guard canMergeDown else { return false }
        let upper = activeLayer
        var lower = layers[active - 1]
        // Paint.NET applies the upper layer's settings to the pixels and keeps the lower layer's properties.
        if upper.opacity > 0 {
            guard let source = upper.straightPixels, var pixels = lower.straightPixels else { return false }
            upper.blendMode.composite(source, onto: &pixels, opacity: upper.opacity)
            guard let image = BGRA8.image(from: pixels, width: lower.image.width, height: lower.image.height)
            else { return false }
            lower.image = image
            lower.pdnPixels = pixels
            layers[active - 1] = lower
        }
        layers.remove(at: active)
        active -= 1
        return true
    }

    func draw(in context: CGContext, rect: CGRect, preview: CGImage? = nil) {
        context.saveGState()
        for (index, layer) in layers.enumerated() where layer.isVisible {
            context.setAlpha(CGFloat(layer.opacity) / 255)
            context.draw(index == active ? preview ?? layer.image : layer.image, in: rect)
        }
        context.restoreGState()
    }

    func flattened() -> CGImage? {
        let visible = layers.filter { $0.isVisible && $0.opacity > 0 }
        if visible.count == 1, visible[0].opacity == 255 { return visible[0].image }
        if needsBlendComposite { return blendComposite() }
        let image = activeLayer.image
        guard let bitmap = Self.makeBitmap(width: image.width, height: image.height) else { return nil }
        draw(in: bitmap, rect: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bitmap.makeImage()
    }

    func blendComposite(preview: CGImage? = nil) -> CGImage? {
        let image = activeLayer.image
        var pixels = Data(count: image.width * image.height * 4)
        for (index, layer) in layers.enumerated() where layer.isVisible && layer.opacity > 0 {
            let source = index == active ? preview : nil
            let sourcePixels = if let source { BGRA8.pixels(from: source) } else { layer.straightPixels }
            guard let bytes = sourcePixels else { return nil }
            layer.blendMode.composite(bytes, onto: &pixels, opacity: layer.opacity)
        }
        return BGRA8.image(from: pixels, width: image.width, height: image.height)
    }

    static func makeBitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

enum PaintFiles {
    static func readPNG(_ data: Data) throws -> CGImage {
        let corrupt = CocoaError(.fileReadCorruptFile, userInfo: [
            NSLocalizedDescriptionKey: "The file could not be read as a static PNG image."
        ])
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw corrupt }

        guard width <= 4096, height <= 4096, width * height <= 8_388_608 else {
            throw CocoaError(.fileReadTooLarge, userInfo: [
                NSLocalizedDescriptionKey: "PNG images can be at most 4,096 pixels per side and 8,388,608 pixels total."
            ])
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw corrupt }
        return image
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return bytes as Data
    }
}
