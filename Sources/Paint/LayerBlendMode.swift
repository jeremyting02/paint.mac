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
        render(width: image.width, height: image.height) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    static func render(width: Int, height: Int, draw: (CGContext) -> Void) -> Data? {
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let converted = pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                                          bitmapInfo: byteOrder | CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { return false }
            draw(context)
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
