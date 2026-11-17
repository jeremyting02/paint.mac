import CoreGraphics

/// Decode and quantize RGB channels in a matrix-based ICC profile's own linear space.
struct RasterTransferCurve {
    private let decoded: [SIMD3<Float>]
    private let thresholds: [SIMD3<Float>]

    init?(colorSpace: CGColorSpace) {
        guard let linear = CGColorSpaceCreateLinearized(colorSpace) else { return nil }
        func sample(_ value: CGFloat) -> SIMD3<Float>? {
            // A linearized copy uses the same primaries. A neutral input samples all three
            // transfer curves at once, including profiles with individual channel curves.
            guard let source = CGColor(colorSpace: colorSpace, components: [value, value, value, 1]),
                  let components = source.converted(to: linear, intent: .relativeColorimetric, options: nil)?.components,
                  components.count == 4, components.prefix(3).allSatisfy(\.isFinite)
            else { return nil }
            return SIMD3(Float(components[2]), Float(components[1]), Float(components[0]))
        }

        let decoded = (0...255).compactMap { sample(CGFloat($0) / 255) }
        let thresholds = (0..<255).compactMap { sample((CGFloat($0) + 0.5) / 255) }
        guard decoded.count == 256, thresholds.count == 255 else { return nil }
        for channel in 0..<3 {
            guard zip(thresholds, thresholds.dropFirst()).allSatisfy({ $0[channel] <= $1[channel] })
            else { return nil }
        }
        self.decoded = decoded
        self.thresholds = thresholds
    }

    func linearValue(of byte: UInt8, channel: Int) -> Float { decoded[Int(byte)][channel] }

    func encodedByte(for value: Float, channel: Int) -> UInt8 {
        var low = 0
        var high = thresholds.count
        while low < high {
            let middle = (low + high) / 2
            if value < thresholds[middle][channel] { high = middle }
            else { low = middle + 1 }
        }
        return UInt8(low)
    }
}
