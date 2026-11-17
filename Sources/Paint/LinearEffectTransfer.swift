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
    private let inverseExponent: Double

    init(colorSpace: CGColorSpace, sampleExponent: Double = 1) {
        let linear: [SIMD3<Double>]
        if colorSpace == BGRA8.sRGB {
            encoding = .sRGB
            linear = Self.linearSRGB
        } else if let curve = RasterTransferCurve(colorSpace: colorSpace) {
            encoding = .profile(curve)
            linear = (0...255).map { value in
                let byte = UInt8(value)
                return SIMD3(Double(curve.linearValue(of: byte, channel: 0)),
                             Double(curve.linearValue(of: byte, channel: 1)),
                             Double(curve.linearValue(of: byte, channel: 2)))
            }
        } else {
            // Match the resampler's encoded-domain fallback for profiles without a linear counterpart.
            encoding = .identity
            linear = Self.identity
        }
        inverseExponent = 1 / sampleExponent
        decoded = sampleExponent == 1 ? linear : linear.map {
            SIMD3(pow(max(0, $0.x), sampleExponent), pow(max(0, $0.y), sampleExponent),
                  pow(max(0, $0.z), sampleExponent))
        }
    }

    func premultipliedPixel(in bytes: UnsafeRawBufferPointer, at offset: Int) -> SIMD4<Double> {
        let alpha = Double(bytes[offset + 3]) / 255
        return SIMD4(decoded[Int(bytes[offset])].x * alpha, decoded[Int(bytes[offset + 1])].y * alpha,
                     decoded[Int(bytes[offset + 2])].z * alpha, alpha)
    }

    func encode(_ linear: Double, channel: Int) -> UInt8 {
        let color = inverseExponent == 1 ? linear : pow(max(0, linear), inverseExponent)
        let encoded: Double
        switch encoding {
        case .sRGB:
            encoded = color <= 0.0031308 ? color * 12.92 : 1.055 * pow(color, 1 / 2.4) - 0.055
        case let .profile(curve):
            return curve.encodedByte(for: Float(color), channel: channel)
        case .identity:
            encoded = color
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
