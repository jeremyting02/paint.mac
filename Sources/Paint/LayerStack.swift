import Foundation
import CoreGraphics

struct PaintLayer {
    var name: String
    var image: CGImage { didSet { pdnPixels = nil } }
    var isVisible = true
    var isBackground = false
    var opacity: UInt8 = 255
    var blendMode: LayerBlendMode = .normal
    var metadata: [PDNMetadata] = []
    var pdnPixels: Data?

    var workingColorSpace: CGColorSpace {
        if let colorSpace = image.colorSpace, colorSpace.model == .rgb { return colorSpace }
        return BGRA8.sRGB
    }

    var straightPixels: Data? { pdnPixels ?? BGRA8.pixels(from: image, in: workingColorSpace) }

    func withPixels(_ pixels: Data) -> PaintLayer? {
        replacingPixels(pixels, colorSpace: workingColorSpace)
    }

    private func replacingPixels(_ pixels: Data, colorSpace: CGColorSpace) -> PaintLayer? {
        guard let image = BGRA8.image(from: pixels, width: image.width, height: image.height, colorSpace: colorSpace)
        else { return nil }
        var updated = self
        updated.image = image
        updated.pdnPixels = pixels
        return updated
    }

    func applyingColorSpace(_ colorSpace: CGColorSpace, converting: Bool) -> PaintLayer? {
        if workingColorSpace == colorSpace, image.colorSpace == colorSpace { return self }
        guard let source = straightPixels else { return nil }
        let data = if converting {
            BGRA8.converted(source, width: image.width, height: image.height, from: workingColorSpace, to: colorSpace)
        } else {
            Optional(source)
        }
        return data.flatMap { replacingPixels($0, colorSpace: colorSpace) }
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
        guard let padded = BGRA8.image(from: pixels, width: width, height: height, colorSpace: workingColorSpace) else {
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
            guard let masked = BGRA8.image(from: pixels, width: cropped.width, height: cropped.height,
                                           colorSpace: workingColorSpace) else { return false }
            image = masked
            pdnPixels = pixels
        }
        return true
    }
}

struct LayerStack {
    private static let layerLimit = 128
    private static let documentPixelLimit = 64 * 1024 * 1024

    static func supportsCanvas(width: Int, height: Int) -> Bool {
        (1...4096).contains(width) && (1...4096).contains(height) && width * height <= 8_388_608
    }

    static func layerCapacity(width: Int, height: Int) -> Int {
        guard supportsCanvas(width: width, height: height) else { return 0 }
        return min(layerLimit, documentPixelLimit / (width * height))
    }
    var layers: [PaintLayer] // Bottom to top.
    var active: Int
    var metadata: [PDNMetadata] = []
    var colorProfile: RGBColorProfile?

    var activeLayer: PaintLayer { layers[active] }
    var workingColorSpace: CGColorSpace { colorProfile?.colorSpace ?? BGRA8.sRGB }
    var remainingLayerCapacity: Int {
        Self.layerCapacity(width: activeLayer.image.width, height: activeLayer.image.height) - layers.count
    }
    var canDuplicate: Bool { remainingLayerCapacity > 0 }
    var canMergeDown: Bool { active > 0 }
    var needsBlendComposite: Bool {
        let visible = layers.lazy.filter { $0.isVisible && $0.opacity > 0 }
        return (visible.first?.opacity ?? 255) < 255 || !visible.dropFirst().isEmpty
    }

    static func blank(width: Int, height: Int, colorProfile: RGBColorProfile? = nil) -> Self? {
        guard supportsCanvas(width: width, height: height),
              let image = makeBitmap(width: width, height: height,
                                     colorSpace: colorProfile?.colorSpace ?? BGRA8.sRGB)?.makeImage() else { return nil }
        return Self(layers: [PaintLayer(name: "Background", image: image, isBackground: true)], active: 0,
                    colorProfile: colorProfile)
    }

    mutating func insertBlankLayer() throws {
        guard canDuplicate else { throw PDNError.tooLarge }
        let dimensions = activeLayer.image
        guard let image = Self.makeBitmap(width: dimensions.width, height: dimensions.height,
                                          colorSpace: workingColorSpace)?.makeImage()
        else { throw CocoaError(.fileReadUnknown) }
        let names = Set(layers.map(\.name))
        var number = 1
        while names.contains("Layer \(number)") { number += 1 }
        active += 1
        layers.insert(PaintLayer(name: "Layer \(number)", image: image), at: active)
    }

    func copyingFlattened(preview: PaintLayer) -> PaintLayer? {
        var background = self
        background.layers[active] = preview
        return background.flattenedLayer()
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
        let lower = layers[active - 1]
        // Paint.NET applies the upper layer's settings to the pixels and keeps the lower layer's properties.
        if upper.opacity > 0 {
            guard let source = upper.straightPixels, var pixels = lower.straightPixels else { return false }
            upper.blendMode.composite(source, onto: &pixels, opacity: upper.opacity)
            guard let merged = lower.withPixels(pixels) else { return false }
            layers[active - 1] = merged
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
        guard combined.count <= Self.layerCapacity(width: width, height: height) else {
            throw PDNError.tooLarge
        }
        let destination = workingColorSpace
        let existingCount = layers.count
        layers = try combined.enumerated().map { index, layer in
            var padded: PaintLayer
            if index < existingCount {
                padded = layer
            } else {
                guard let converted = layer.applyingColorSpace(destination, converting: true) else {
                    throw PDNError.unsupported("the imported layer's color profile")
                }
                padded = converted
            }
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
        guard let composite = blendComposite() else { return nil }
        return PaintLayer(name: "Background", image: composite.image, isBackground: true, pdnPixels: composite.pixels)
    }

    func blendComposite() -> (image: CGImage, pixels: Data)? {
        let image = activeLayer.image
        let pixelCount = image.width * image.height
        var sources: [CompositeSource] = []
        for layer in layers where layer.isVisible && layer.opacity > 0 {
            guard let bytes = layer.straightPixels, bytes.count == pixelCount * 4 else { return nil }
            sources.append(CompositeSource(pixels: bytes, stride: image.width, offset: 0,
                                           mode: layer.blendMode, opacity: layer.opacity))
        }
        let pixels = RegionComposite.fullPixels(count: pixelCount, sources: sources)
        guard let flat = BGRA8.image(from: pixels, width: image.width, height: image.height, colorSpace: workingColorSpace)
        else { return nil }
        return (flat, pixels)
    }

    func applyingColorProfile(_ profile: RGBColorProfile, converting: Bool) throws -> Self {
        var result = self
        result.layers = try layers.map { layer in
            guard let output = layer.applyingColorSpace(profile.colorSpace, converting: converting) else {
                throw PDNError.unsupported("the selected color profile cannot be applied to this image")
            }
            return output
        }
        result.colorProfile = profile
        result.metadata = profile.embedding(in: metadata)
        return result
    }

    static func makeBitmap(width: Int, height: Int, colorSpace: CGColorSpace = BGRA8.sRGB) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
