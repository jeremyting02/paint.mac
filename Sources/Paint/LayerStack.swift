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

    func withPixels(_ pixels: Data) -> PaintLayer? {
        guard let image = BGRA8.image(from: pixels, width: image.width, height: image.height) else { return nil }
        var updated = self
        updated.image = image
        updated.pdnPixels = pixels
        return updated
    }

    func clearing(_ region: CGRect, mask: Data?, from source: Data) -> Data {
        let width = image.width, regionWidth = Int(region.width)
        let origin = Int(region.minY) * width + Int(region.minX)
        var cleared = source
        if let mask {
            cleared.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                for (index, selected) in mask.enumerated() where selected != 0 {
                    let pixel = origin + index / regionWidth * width + index % regionWidth
                    target.storeBytes(of: UInt32(0), toByteOffset: pixel * 4, as: UInt32.self)
                }
            }
        } else {
            for row in 0..<Int(region.height) {
                let start = (origin + row * width) * 4
                cleared.resetBytes(in: start..<(start + regionWidth * 4))
            }
        }
        return cleared
    }

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

    mutating func crop(to rect: CGRect, keeping mask: Data? = nil) -> Bool {
        guard let cropped = image.cropping(to: rect),
              mask == nil || mask?.count == cropped.width * cropped.height else { return false }
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
        if let mask {
            guard var pixels = straightPixels else { return false }
            pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                for (index, selected) in mask.enumerated() where selected == 0 {
                    target.storeBytes(of: UInt32(0), toByteOffset: index * 4, as: UInt32.self)
                }
            }
            guard let masked = BGRA8.image(from: pixels, width: cropped.width, height: cropped.height) else { return false }
            image = masked
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
    private let croppedSource: PaintLayer?
    let isPaste: Bool

    init?(layer: PaintLayer, selection: CGRect, mask: Data? = nil) {
        let width = layer.image.width, height = layer.image.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard !selection.isEmpty, bounds.contains(selection), selection == selection.integral,
              let source = layer.straightPixels else { return nil }
        self.layer = layer
        self.source = source
        self.selection = selection
        self.bounds = bounds
        isPaste = false
        if let mask {
            var foreground = layer
            guard foreground.crop(to: selection, keeping: mask) else { return nil }
            croppedSource = foreground
        } else {
            croppedSource = nil
        }
        cleared = layer.clearing(selection, mask: mask, from: source)
    }

    init?(layer: PaintLayer, pastedImage: CGImage, at destination: CGRect) {
        guard let source = layer.straightPixels, let foreground = BGRA8.pixels(from: pastedImage) else { return nil }
        self.layer = layer
        self.source = source
        cleared = source
        selection = destination
        bounds = CGRect(x: 0, y: 0, width: layer.image.width, height: layer.image.height)
        croppedSource = PaintLayer(name: layer.name, image: pastedImage, pdnPixels: foreground)
        isPaste = true
    }

    static func rotatedBounds(of rect: CGRect, by angle: CGFloat) -> CGRect {
        if angle == 0 { return rect.integral }
        let width = abs(cos(angle)) * rect.width + abs(sin(angle)) * rect.height
        let height = abs(sin(angle)) * rect.width + abs(cos(angle)) * rect.height
        let bounds = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        // Avoid expanding exact pixel edges due to trigonometric rounding at right angles.
        return bounds.insetBy(dx: 1e-9, dy: 1e-9).integral
    }

    func transformed(to destination: CGRect, rotation: CGFloat = 0, flipX: Bool = false, flipY: Bool = false,
                     copy: Bool = false) -> PaintLayer? {
        if !isPaste && destination == selection && rotation == 0 && !flipX && !flipY { return layer }
        let width = layer.image.width
        let target = Self.rotatedBounds(of: destination, by: rotation).intersection(bounds)
        var pixels = copy ? source : cleared
        if !target.isEmpty {
            let rowBytes = Int(target.width) * 4
            let targetStart = (Int(target.minY) * width + Int(target.minX)) * 4
            let foreground: Data
            let foregroundStart: Int
            let foregroundStride: Int
            if rotation == 0 && !flipX && !flipY && destination == destination.integral && destination.size == selection.size {
                let x = Int(target.minX - destination.minX), y = Int(target.minY - destination.minY)
                if let croppedSource, let pixels = croppedSource.pdnPixels {
                    foreground = pixels
                    foregroundStride = croppedSource.image.width * 4
                    foregroundStart = y * foregroundStride + x * 4
                } else {
                    foreground = source
                    foregroundStride = width * 4
                    foregroundStart = (Int(selection.minY) + y) * foregroundStride + (Int(selection.minX) + x) * 4
                }
            } else {
                guard let rendered = renderPixels(destination: destination, visible: target, rotation: rotation,
                                                  flipX: flipX, flipY: flipY) else { return nil }
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
        return layer.withPixels(pixels)
    }

    private func renderPixels(destination: CGRect, visible: CGRect, rotation: CGFloat, flipX: Bool, flipY: Bool) -> Data? {
        guard let image = croppedSource?.image ?? layer.image.cropping(to: selection) else { return nil }
        // Rasterize only the on-canvas portion. The drawing context has a bottom-left origin.
        return BGRA8.render(width: Int(visible.width), height: Int(visible.height)) { bitmap in
            bitmap.interpolationQuality = .low
            bitmap.translateBy(x: destination.midX - visible.minX, y: visible.maxY - destination.midY)
            bitmap.rotate(by: rotation)
            bitmap.scaleBy(x: flipX ? -1 : 1, y: flipY ? -1 : 1)
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
    static func readClipboardImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              LayerStack.supportsCanvas(width: width, height: height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return image
    }

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
