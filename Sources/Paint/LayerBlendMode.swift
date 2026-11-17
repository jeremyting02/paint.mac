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
}

enum BGRA8 {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let byteOrder = CGBitmapInfo.byteOrder32Little.rawValue

    static func image(from pixels: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: byteOrder | CGImageAlphaInfo.first.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func pixels(from image: CGImage) -> Data? {
        if let straight = straightProviderPixels(from: image) { return straight }
        return rasterizedPixels(from: image)
    }

    static func rasterizedPixels(from image: CGImage) -> Data? {
        render(width: image.width, height: image.height) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    private static func straightProviderPixels(from image: CGImage) -> Data? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.decode == nil,
              image.colorSpace?.name == CGColorSpace.sRGB else { return nil }
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

    static func render(width: Int, height: Int, opaque: Bool = false, draw: (CGContext) -> Void) -> Data? {
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
