import CoreGraphics
import Foundation

enum ImageOrientationEdit: String, CaseIterable {
    case flipHorizontal = "Flip Horizontal"
    case flipVertical = "Flip Vertical"
    case clockwise = "Rotate 90° Clockwise"
    case counterClockwise = "Rotate 90° Counterclockwise"
    case halfTurn = "Rotate 180°"

    var swapsDimensions: Bool { self == .clockwise || self == .counterClockwise }

    func selectionTransform(width: Int, height: Int) -> CGAffineTransform {
        let w = CGFloat(width), h = CGFloat(height)
        switch self {
        case .flipHorizontal: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .flipVertical: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .clockwise: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .counterClockwise: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .halfTurn: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        }
    }

    fileprivate func destination(x: Int, y: Int, width: Int, height: Int) -> (x: Int, y: Int) {
        switch self {
        case .flipHorizontal: return (width - 1 - x, y)
        case .flipVertical: return (x, height - 1 - y)
        case .clockwise: return (height - 1 - y, x)
        case .counterClockwise: return (y, width - 1 - x)
        case .halfTurn: return (width - 1 - x, height - 1 - y)
        }
    }
}

enum CanvasAnchor: String, CaseIterable {
    case topLeft = "Top Left", top = "Top", topRight = "Top Right"
    case left = "Left", center = "Center", right = "Right"
    case bottomLeft = "Bottom Left", bottom = "Bottom", bottomRight = "Bottom Right"

    func offset(widthDelta: Int, heightDelta: Int) -> (x: Int, y: Int) {
        let index = Self.allCases.firstIndex(of: self)!
        return ([0, widthDelta / 2, widthDelta][index % 3],
                [0, heightDelta / 2, heightDelta][index / 3])
    }
}

extension LayerStack {
    func reoriented(_ operation: ImageOrientationEdit, activeOnly: Bool = false) throws -> Self {
        let width = activeLayer.image.width, height = activeLayer.image.height
        let newWidth = operation.swapsDimensions ? height : width
        let newHeight = operation.swapsDimensions ? width : height
        guard !activeOnly || (newWidth == width && newHeight == height) else { throw PDNError.invalid }
        var result = self
        for index in layers.indices where !activeOnly || index == active {
            let layer = layers[index]
            guard let source = layer.straightPixels else { throw CocoaError(.fileReadUnknown) }
            var pixels = Data(count: source.count)
            source.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                pixels.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                    for y in 0..<height {
                        for x in 0..<width {
                            let target = operation.destination(x: x, y: y, width: width, height: height)
                            let word = input.loadUnaligned(fromByteOffset: (y * width + x) * 4, as: UInt32.self)
                            output.storeBytes(of: word, toByteOffset: (target.y * newWidth + target.x) * 4, as: UInt32.self)
                        }
                    }
                }
            }
            result.layers[index] = try layer.replacingRaster(pixels, width: newWidth, height: newHeight)
        }
        if !activeOnly, operation.swapsDimensions, let resolution, resolution.horizontal != resolution.vertical {
            result.metadata = resolution.transposed.updating(metadata)
        }
        return result
    }

    func resizedCanvas(width: Int, height: Int, anchor: CanvasAnchor, fill: UInt32 = 0) throws -> Self {
        guard layers.count <= Self.layerCapacity(width: width, height: height) else { throw PDNError.tooLarge }
        let oldWidth = activeLayer.image.width, oldHeight = activeLayer.image.height
        guard width != oldWidth || height != oldHeight else { return self }
        let offset = anchor.offset(widthDelta: width - oldWidth, heightDelta: height - oldHeight)
        let targetX = max(0, offset.x), sourceX = max(0, -offset.x)
        let targetY = max(0, offset.y), sourceY = max(0, -offset.y)
        let copyWidth = min(width - targetX, oldWidth - sourceX)
        let copyHeight = min(height - targetY, oldHeight - sourceY)
        var result = self
        for (index, layer) in layers.enumerated() {
            guard let source = layer.straightPixels else { throw CocoaError(.fileReadUnknown) }
            var pixels = Data(count: width * height * 4)
            if index == 0, fill != 0 {
                pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                    for offset in stride(from: 0, to: bytes.count, by: 4) {
                        bytes.storeBytes(of: fill.littleEndian, toByteOffset: offset, as: UInt32.self)
                    }
                }
            }
            for row in 0..<copyHeight {
                let start = ((row + targetY) * width + targetX) * 4
                let read = source.startIndex + ((row + sourceY) * oldWidth + sourceX) * 4
                pixels.replaceSubrange(start..<(start + copyWidth * 4), with: source[read..<(read + copyWidth * 4)])
            }
            result.layers[index] = try layer.replacingRaster(pixels, width: width, height: height)
        }
        return result
    }

    func resizedImage(width: Int, height: Int, sampling: ImageResampler.Mode, linearLight: Bool) throws -> Self {
        guard layers.count <= Self.layerCapacity(width: width, height: height) else { throw PDNError.tooLarge }
        let oldWidth = activeLayer.image.width, oldHeight = activeLayer.image.height
        guard width != oldWidth || height != oldHeight else { return self }
        let resampler = ImageResampler(sourceWidth: oldWidth, sourceHeight: oldHeight, width: width, height: height,
                                       mode: sampling, linearLight: linearLight, colorSpace: activeLayer.workingColorSpace)
        var result = self
        result.layers = try layers.map { layer in
            guard let source = layer.straightPixels else { throw CocoaError(.fileReadUnknown) }
            return try layer.replacingRaster(resampler.resample(source), width: width, height: height)
        }
        return result
    }
}

private extension PaintLayer {
    func replacingRaster(_ pixels: Data, width: Int, height: Int) throws -> Self {
        guard let image = BGRA8.image(from: pixels, width: width, height: height, colorSpace: workingColorSpace)
        else { throw CocoaError(.fileReadUnknown) }
        var layer = self
        layer.image = image
        layer.pdnPixels = pixels
        return layer
    }
}
