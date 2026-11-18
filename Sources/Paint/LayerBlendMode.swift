import Accelerate
import CoreGraphics
import Foundation

// Raw values and legacy class names are part of the Paint.NET PDN format.
enum LayerBlendMode: Int, CaseIterable {
    case normal = 0, multiply, additive, colorBurn, colorDodge, reflect, glow
    case overlay, difference, negation, lighten, darken, screen, xor

    var title: String {
        ["Normal", "Multiply", "Additive", "Color Burn", "Color Dodge", "Reflect", "Glow",
         "Overlay", "Difference", "Negation", "Lighten", "Darken", "Screen", "Xor"][rawValue]
    }

    var pdnClass: String {
        "PaintDotNet.UserBlendOps+" + title.replacingOccurrences(of: " ", with: "") + "BlendOp"
    }

    private func blend(_ background: Int, _ source: Int) -> Int {
        switch self {
        case .normal: return source
        case .multiply: return (background * source + 127) / 255
        case .additive: return min(255, background + source)
        case .colorBurn: return source == 0 ? 0 : max(0, 255 - (255 - background) * 255 / source)
        case .colorDodge: return source == 255 ? 255 : min(255, background * 255 / (255 - source))
        case .reflect: return source == 255 ? 255 : min(255, background * background / (255 - source))
        case .glow: return Self.reflect.blend(source, background)
        case .overlay:
            if background < 128 { return (2 * background * source + 127) / 255 }
            return 255 - (2 * (255 - background) * (255 - source) + 127) / 255
        case .difference: return abs(background - source)
        case .negation: return 255 - abs(255 - background - source)
        case .lighten: return max(background, source)
        case .darken: return min(background, source)
        case .screen: return background + source - (background * source + 127) / 255
        case .xor: return background ^ source
        }
    }

    func composite(_ source: Data, onto destination: inout Data, opacity: UInt8) {
        destination.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            source.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                composite(source, onto: target, opacity: opacity)
            }
        }
    }

    func composite(_ source: UnsafeRawBufferPointer, onto target: UnsafeMutableRawBufferPointer, opacity: UInt8) {
        for i in stride(from: 0, to: target.count, by: 4) {
            let alpha = Int(source[i + 3]) * Int(opacity)
            if alpha == 0 { continue }
            let backdropAlpha = Int(target[i + 3])
            if backdropAlpha == 0 || (alpha == 65025 && self == .normal) {
                for channel in i..<(i + 3) { target[channel] = source[channel] }
                target[i + 3] = UInt8((alpha + 127) / 255)
                continue
            }
            // Blend only the overlap. The uncovered parts keep their original colors.
            let backdrop = backdropAlpha * (65025 - alpha)
            let foreground = (255 - backdropAlpha) * alpha
            let overlap = backdropAlpha * alpha
            let total = backdrop + foreground + overlap
            for channel in i..<(i + 3) {
                let a = Int(target[channel]), b = Int(source[channel])
                let sum = backdrop * a + foreground * b + overlap * blend(a, b)
                target[channel] = UInt8((sum + total / 2) / total)
            }
            target[i + 3] = UInt8((total + 32512) / 65025)
        }
    }

    private func blend(_ background: Float, _ source: Float) -> Float {
        switch self {
        case .normal: return source
        case .multiply: return background * source
        case .additive: return min(1, background + source)
        case .colorBurn: return source == 0 ? 0 : max(0, 1 - (1 - background) / source)
        case .colorDodge: return source == 1 ? 1 : min(1, background / (1 - source))
        case .reflect: return source == 1 ? 1 : min(1, background * background / (1 - source))
        case .glow: return Self.reflect.blend(source, background)
        case .overlay:
            return background < 0.5 ? 2 * background * source : 1 - 2 * (1 - background) * (1 - source)
        case .difference: return abs(background - source)
        case .negation: return 1 - abs(1 - background - source)
        case .lighten: return max(background, source)
        case .darken: return min(background, source)
        case .screen: return background + source - background * source
        case .xor: return Float(Self.byte(background) ^ Self.byte(source)) / 255
        }
    }

    // The stack keeps premultiplied BGRA in floating point until all visible layers are combined.
    func composite(_ source: UnsafeRawBufferPointer, startingAt firstPixel: Int,
                   onto target: UnsafeMutableBufferPointer<SIMD4<Float>>, opacity: UInt8) {
        let layerAlpha = Float(opacity) / 255
        for index in target.indices {
            let offset = (firstPixel + index) * 4
            let bytes = source.loadUnaligned(fromByteOffset: offset, as: SIMD4<UInt8>.self)
            var color = SIMD4<Float>(bytes) / 255
            let alpha = color.w * layerAlpha
            if alpha == 0 { continue }
            color.w = 1
            let backdrop = target[index]
            let foreground = color * alpha
            if self == .normal || backdrop.w == 0 {
                target[index] = foreground + backdrop * (1 - alpha)
            } else {
                let straight = backdrop / backdrop.w
                let overlap = SIMD4(blend(straight.x, color.x), blend(straight.y, color.y),
                                    blend(straight.z, color.z), 1)
                target[index] = backdrop * (1 - alpha) + foreground * (1 - backdrop.w) +
                    overlap * (backdrop.w * alpha)
            }
        }
    }

    static func storeComposite(_ source: UnsafeBufferPointer<SIMD4<Float>>,
                               in pixels: UnsafeMutableRawBufferPointer, startingAt firstPixel: Int) {
        for (index, pixel) in source.enumerated() where pixel.w > 0 {
            let offset = (firstPixel + index) * 4
            let straight = pixel / pixel.w
            pixels[offset] = byte(straight.x)
            pixels[offset + 1] = byte(straight.y)
            pixels[offset + 2] = byte(straight.z)
            pixels[offset + 3] = byte(pixel.w)
        }
    }

    private static func byte(_ component: Float) -> UInt8 {
        UInt8(min(255, max(0, (component * 255).rounded(.toNearestOrEven))))
    }
}

enum BGRA8 {
    static func overwrite(_ color: SIMD4<UInt8>, coverage: Int, pixel: Int = 0,
                          in target: UnsafeMutableRawBufferPointer) {
        let foreground = Int(color.w) * coverage
        let backdrop = Int(target[pixel + 3]) * (255 - coverage)
        let total = foreground + backdrop
        for channel in 0..<3 {
            let value = Int(color[channel])
            let old = Int(target[pixel + channel])
            if total == 0 {
                target[pixel + channel] = UInt8((value * coverage + old * (255 - coverage) + 127) / 255)
            } else {
                target[pixel + channel] = UInt8((value * foreground + old * backdrop + total / 2) / total)
            }
        }
        target[pixel + 3] = UInt8((total + 127) / 255)
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let byteOrder = CGBitmapInfo.byteOrder32Little.rawValue
    private static let straightFormat = CGBitmapInfo(rawValue: byteOrder | CGImageAlphaInfo.first.rawValue)

    static func image(from pixels: Data, width: Int, height: Int, colorSpace: CGColorSpace = sRGB) -> CGImage? {
        guard width > 0, height > 0, pixels.count.isMultiple(of: 4),
              (pixels.count / 4).isMultiple(of: width), pixels.count / 4 / width == height,
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return image(from: provider, width: width, height: height, colorSpace: colorSpace)
    }

    static func image(from provider: CGDataProvider, width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace,
                       bitmapInfo: straightFormat,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func pixels(from image: CGImage, in colorSpace: CGColorSpace = sRGB) -> Data? {
        if let source = image.colorSpace, source.model == .rgb,
           let straight = straightProviderPixels(from: image) {
            return converted(straight, width: image.width, height: image.height, from: source, to: colorSpace)
                ?? rasterizedPixels(from: image, in: colorSpace)
        }
        return rasterizedPixels(from: image, in: colorSpace)
    }

    static func rasterizedPixels(from image: CGImage, in colorSpace: CGColorSpace = sRGB) -> Data? {
        render(width: image.width, height: image.height, colorSpace: colorSpace) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    static func converted(_ pixels: Data, width: Int, height: Int,
                          from source: CGColorSpace, to destination: CGColorSpace) -> Data? {
        guard width > 0, height > 0, pixels.count.isMultiple(of: 4),
              (pixels.count / 4).isMultiple(of: width), pixels.count / 4 / width == height else { return nil }
        if source == destination { return pixels }
        func format(for colorSpace: CGColorSpace) -> vImage_CGImageFormat {
            vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: .passUnretained(colorSpace),
                                 bitmapInfo: straightFormat, version: 0, decode: nil, renderingIntent: .relativeColorimetric)
        }
        var inputFormat = format(for: source)
        var outputFormat = format(for: destination)
        guard let converter = vImageConverter_CreateWithCGImageFormat(&inputFormat, &outputFormat, nil, 0, nil)?
            .takeRetainedValue() else { return nil }
        var result = Data(count: pixels.count)
        let status = pixels.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            result.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: input.baseAddress),
                                        height: UInt(height), width: UInt(width), rowBytes: width * 4)
                var dst = vImage_Buffer(data: output.baseAddress, height: UInt(height), width: UInt(width), rowBytes: width * 4)
                return vImageConvert_AnyToAny(converter, &src, &dst, nil, 0)
            }
        }
        // vImage reads the unassociated channels directly, even if alpha is zero.
        return status == kvImageNoError ? result : nil
    }

    private static func straightProviderPixels(from image: CGImage) -> Data? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.decode == nil else { return nil }
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let bgra = image.alphaInfo == .first && order == .byteOrder32Little
        let rgba = image.alphaInfo == .last && (order == .byteOrderDefault || order == .byteOrder32Big)
        guard bgra || rgba, let providerData = image.dataProvider?.data else { return nil }
        let data = providerData as Data
        let rowBytes = image.width * 4
        let rowStride = image.bytesPerRow
        let (lastRow, overflow) = (image.height - 1).multipliedReportingOverflow(by: rowStride)
        guard rowStride >= rowBytes, !overflow, lastRow <= data.count, rowBytes <= data.count - lastRow
        else { return nil }
        if bgra && rowStride == rowBytes { return Data(data.prefix(lastRow + rowBytes)) }

        // Reading straight-alpha bytes directly preserves RGB at zero and low alpha.
        var pixels = Data(count: rowBytes * image.height)
        pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for row in 0..<image.height {
                    let input = row * rowStride
                    let output = row * rowBytes
                    if bgra {
                        target[output..<(output + rowBytes)].copyBytes(from: source[input..<(input + rowBytes)])
                    } else {
                        for column in stride(from: 0, to: rowBytes, by: 4) {
                            target[output + column] = source[input + column + 2]
                            target[output + column + 1] = source[input + column + 1]
                            target[output + column + 2] = source[input + column]
                            target[output + column + 3] = source[input + column + 3]
                        }
                    }
                }
            }
        }
        return pixels
    }

    static func render(width: Int, height: Int, opaque: Bool = false, colorSpace: CGColorSpace = sRGB,
                       draw: (CGContext) -> Void) -> Data? {
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let converted = pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                                          bitmapInfo: byteOrder | CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { return false }
            draw(context)
            if opaque { return true }
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Int(bytes[index + 3])
                if alpha == 0 || alpha == 255 { continue }
                for channel in index..<(index + 3) {
                    bytes[channel] = UInt8(min(255, (Int(bytes[channel]) * 255 + alpha / 2) / alpha))
                }
            }
            return true
        }
        return converted ? pixels : nil
    }
}
