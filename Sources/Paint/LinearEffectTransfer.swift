import CoreGraphics
import Foundation

struct LinearEffectTransfer {
    private enum Encoding {
        case sRGB
        case profile(RasterTransferCurve)
        case identity
    }

    private let encoding: Encoding
    private let decoded: [SIMD3<Double>]

    init(colorSpace: CGColorSpace) {
        if colorSpace == BGRA8.sRGB {
            encoding = .sRGB
            decoded = Self.linearSRGB
        } else if let curve = RasterTransferCurve(colorSpace: colorSpace) {
            encoding = .profile(curve)
            decoded = (0...255).map { value in
                let byte = UInt8(value)
                return SIMD3(Double(curve.linearValue(of: byte, channel: 0)),
                             Double(curve.linearValue(of: byte, channel: 1)),
                             Double(curve.linearValue(of: byte, channel: 2)))
            }
        } else {
            // Match the resampler's encoded-domain fallback for profiles without a linear counterpart.
            encoding = .identity
            decoded = Self.identity
        }
    }

    func premultipliedPixel(in bytes: UnsafeRawBufferPointer, at offset: Int) -> SIMD4<Double> {
        let alpha = Double(bytes[offset + 3]) / 255
        return SIMD4(decoded[Int(bytes[offset])].x * alpha, decoded[Int(bytes[offset + 1])].y * alpha,
                     decoded[Int(bytes[offset + 2])].z * alpha, alpha)
    }

    func encode(_ linear: Double, channel: Int) -> UInt8 {
        let encoded: Double
        switch encoding {
        case .sRGB:
            encoded = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        case let .profile(curve):
            return curve.encodedByte(for: Float(linear), channel: channel)
        case .identity:
            encoded = linear
        }
        return UInt8(clamping: Int((encoded * 255).rounded(.toNearestOrEven)))
    }

    private static let identity = (0...255).map { SIMD3<Double>(repeating: Double($0) / 255) }
    private static let linearSRGB = identity.map { channels in
        let value = channels.x
        let linear = value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        return SIMD3<Double>(repeating: linear)
    }
}
