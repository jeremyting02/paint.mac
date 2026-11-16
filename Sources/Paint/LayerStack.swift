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

    mutating func padCanvas(width: Int, height: Int) throws {
        guard width != image.width || height != image.height else { return }
        guard let source = straightPixels else { throw CocoaError(.fileReadUnknown) }
        let stride = image.width * 4
        var pixels = Data(count: width * height * 4)
        // BGRA rows start at the top, so padding adds space on the right and bottom.
        for row in 0..<image.height {
            let start = row * width * 4
            let sourceStart = source.startIndex + row * stride
            pixels.replaceSubrange(start..<(start + stride), with: source[sourceStart..<(sourceStart + stride)])
        }
        guard let padded = BGRA8.image(from: pixels, width: width, height: height) else {
            throw CocoaError(.fileReadUnknown)
        }
        image = padded
        pdnPixels = pixels
    }

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

struct SelectedPixelsTransform {
    private let layer: PaintLayer
    private let source: Data
    private let cleared: Data
    private let selection: CGRect
    private let bounds: CGRect

    init?(layer: PaintLayer, selection: CGRect) {
        let width = layer.image.width, height = layer.image.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard !selection.isEmpty, bounds.contains(selection), selection == selection.integral,
              let source = layer.straightPixels else { return nil }
        self.layer = layer
        self.source = source
        self.selection = selection
        self.bounds = bounds

        var cleared = source
        for row in Int(selection.minY)..<Int(selection.maxY) {
            let start = (row * width + Int(selection.minX)) * 4
            cleared.resetBytes(in: start..<(start + Int(selection.width) * 4))
        }
        self.cleared = cleared
    }

    static func rotatedBounds(of rect: CGRect, by angle: CGFloat) -> CGRect {
        if angle == 0 { return rect }
        let width = abs(cos(angle)) * rect.width + abs(sin(angle)) * rect.height
        let height = abs(sin(angle)) * rect.width + abs(cos(angle)) * rect.height
        let bounds = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        // Avoid expanding exact pixel edges due to trigonometric rounding at right angles.
        return bounds.insetBy(dx: 1e-9, dy: 1e-9).integral
    }

    func transformed(to destination: CGRect, rotation: CGFloat = 0) -> PaintLayer? {
        if destination == selection && rotation == 0 { return layer }
        let width = layer.image.width
        let target = Self.rotatedBounds(of: destination, by: rotation).intersection(bounds)
        var pixels = cleared
        if !target.isEmpty {
            let rowBytes = Int(target.width) * 4
            let targetStart = (Int(target.minY) * width + Int(target.minX)) * 4
            let foreground: Data
            let foregroundStart: Int
            let foregroundStride: Int
            if rotation == 0 && destination.size == selection.size {
                foreground = source
                let sourceX = Int(selection.minX + target.minX - destination.minX)
                let sourceY = Int(selection.minY + target.minY - destination.minY)
                foregroundStart = (sourceY * width + sourceX) * 4
                foregroundStride = width * 4
            } else {
                guard let rendered = renderPixels(destination: destination, visible: target, rotation: rotation) else { return nil }
                foreground = rendered
                foregroundStart = 0
                foregroundStride = rowBytes
            }
            pixels.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                foreground.withUnsafeBytes { (original: UnsafeRawBufferPointer) in
                    for row in 0..<Int(target.height) {
                        let start = targetStart + row * width * 4
                        let sourceStart = foregroundStart + row * foregroundStride
                        LayerBlendMode.normal.composite(
                            UnsafeRawBufferPointer(rebasing: original[sourceStart..<(sourceStart + rowBytes)]),
                            onto: UnsafeMutableRawBufferPointer(rebasing: destination[start..<(start + rowBytes)]),
                            opacity: 255
                        )
                    }
                }
            }
        }
        guard let image = BGRA8.image(from: pixels, width: width, height: layer.image.height) else { return nil }
        var moved = layer
        moved.image = image
        moved.pdnPixels = pixels
        return moved
    }

    private func renderPixels(destination: CGRect, visible: CGRect, rotation: CGFloat) -> Data? {
        guard let image = layer.image.cropping(to: selection) else { return nil }
        // Rasterize only the on-canvas portion. The drawing context has a bottom-left origin.
        return BGRA8.render(width: Int(visible.width), height: Int(visible.height)) { bitmap in
            bitmap.interpolationQuality = .low
            bitmap.translateBy(x: destination.midX - visible.minX, y: visible.maxY - destination.midY)
            bitmap.rotate(by: rotation)
            bitmap.draw(image, in: CGRect(x: -destination.width / 2, y: -destination.height / 2,
                                          width: destination.width, height: destination.height))
        }
    }
}

struct LayerStack {
    static let limit = 8
    static func supportsCanvas(width: Int, height: Int) -> Bool {
        (1...4096).contains(width) && (1...4096).contains(height) && width * height <= 8_388_608
    }
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

    mutating func importLayers(_ incoming: [PaintLayer]) throws {
        guard !incoming.isEmpty else { return }
        let combined = layers + incoming
        let width = combined.reduce(0) { max($0, $1.image.width) }
        let height = combined.reduce(0) { max($0, $1.image.height) }
        guard combined.count <= Self.limit, Self.supportsCanvas(width: width, height: height) else {
            throw PDNError.tooLarge
        }
        layers = try combined.map { layer in
            var padded = layer
            try padded.padCanvas(width: width, height: height)
            return padded
        }
        active = layers.count - 1
    }

    func draw(in context: CGContext, rect: CGRect, preview: CGImage? = nil) {
        context.saveGState()
        for (index, layer) in layers.enumerated() where layer.isVisible {
            context.setAlpha(CGFloat(layer.opacity) / 255)
            context.draw(index == active ? preview ?? layer.image : layer.image, in: rect)
        }
        context.restoreGState()
    }

    func flattenedLayer() -> PaintLayer? {
        let visible = layers.filter { $0.isVisible && $0.opacity > 0 }
        if visible.count == 1, let layer = visible.first, layer.opacity == 255 {
            return PaintLayer(name: "Background", image: layer.image, isBackground: true, pdnPixels: layer.pdnPixels)
        }
        if needsBlendComposite {
            guard let composite = blendComposite() else { return nil }
            return PaintLayer(name: "Background", image: composite.image, isBackground: true, pdnPixels: composite.pixels)
        }
        let image = activeLayer.image
        guard let bitmap = Self.makeBitmap(width: image.width, height: image.height) else { return nil }
        draw(in: bitmap, rect: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = bitmap.makeImage() else { return nil }
        return PaintLayer(name: "Background", image: flat, isBackground: true)
    }

    func blendComposite(preview: CGImage? = nil) -> (image: CGImage, pixels: Data)? {
        let image = activeLayer.image
        var pixels = Data(count: image.width * image.height * 4)
        for (index, layer) in layers.enumerated() where layer.isVisible && layer.opacity > 0 {
            let source = index == active ? preview : nil
            let sourcePixels = if let source { BGRA8.pixels(from: source) } else { layer.straightPixels }
            guard let bytes = sourcePixels else { return nil }
            layer.blendMode.composite(bytes, onto: &pixels, opacity: layer.opacity)
        }
        guard let flat = BGRA8.image(from: pixels, width: image.width, height: image.height) else { return nil }
        return (flat, pixels)
    }

    static func makeBitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

enum PaintFiles {
    static func layersForImport(from url: URL) throws -> [PaintLayer] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let name = url.deletingPathExtension().lastPathComponent
        let layers = if url.pathExtension.lowercased() == "pdn" {
            try PDNFile.read(data).layers
        } else {
            [PaintLayer(name: "Background", image: try readPNG(data))]
        }
        return layers.map { layer in
            var imported = layer
            imported.name = "\(name): \(layer.name)"
            imported.isBackground = false
            return imported
        }
    }

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

        guard LayerStack.supportsCanvas(width: width, height: height) else {
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
