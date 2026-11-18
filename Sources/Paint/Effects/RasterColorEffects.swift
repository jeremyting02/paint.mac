import Foundation

extension RasterFilter {
    static let colorEffects: [Self] = [
        Self("Quantize / Dither", category: "Color", [.init("Colors", 2...256, 16),
                                                     .init("Dither Strength", 0...100, 0)]) {
            source, width, height, values, isCancelled in
            PaletteQuantizer.apply(source, width: width, height: height, count: Int(values[0]),
                                   dither: values[1] / 100, isCancelled: isCancelled)
        },
        point("Red Eye Removal", category: "Photo", [.init("Tolerance", 0...100, 50),
                                                     .init("Saturation", 0...100, 20)]) { pixel, values in
            let others = max(pixel.y, pixel.z)
            let minimumRed = 0.6 - values[0] / 200
            let redness = pixel.x - others
            guard pixel.x > minimumRed, redness > 0.35 * (1 - values[0] / 100), pixel.w > 0 else { return pixel }
            let red = others + redness * values[1] / 100
            return Pixel(red, pixel.y, pixel.z, pixel.w)
        }
    ]
}

enum PaletteQuantizer {
    private struct Sample {
        var weight = 0
        var sum = SIMD3<Int64>.zero

        var color: SIMD3<Double> {
            SIMD3(Double(sum.x), Double(sum.y), Double(sum.z)) / Double(weight)
        }

        mutating func add(_ value: SIMD3<Int64>, weight: Int) {
            self.weight += weight
            sum &+= value &* Int64(weight)
        }
    }

    private struct Bucket {
        let samples: [Sample]
        let axis: Int
        let priority: Double

        init(_ samples: [Sample]) {
            self.samples = samples
            var minimum = SIMD3<Double>(repeating: 255)
            var maximum = SIMD3<Double>.zero
            for sample in samples {
                let color = sample.color
                for channel in 0..<3 {
                    minimum[channel] = min(minimum[channel], color[channel])
                    maximum[channel] = max(maximum[channel], color[channel])
                }
            }
            let lengths = maximum - minimum
            self.axis = (0..<3).max { lengths[$0] < lengths[$1] } ?? 0
            self.priority = samples.count > 1 ? lengths[axis] : 0
        }

        func split() -> (Bucket, Bucket) {
            let sorted = samples.sorted { $0.color[axis] < $1.color[axis] }
            let halfWeight = sorted.reduce(0) { $0 + $1.weight } / 2
            var cumulative = 0
            var index = 0
            repeat {
                cumulative += sorted[index].weight
                index += 1
            } while index < sorted.count - 1 && cumulative < halfWeight
            return (Bucket(Array(sorted[..<index])), Bucket(Array(sorted[index...])))
        }

        var centroid: SIMD3<Double> {
            let total = samples.reduce(into: Sample()) { sample, next in
                sample.weight += next.weight
                sample.sum &+= next.sum
            }
            return total.color
        }
    }

    static func apply(_ source: Data, width: Int, height: Int, count: Int, dither: Double,
                      useMetal: Bool = true, isCancelled: () -> Bool) -> Data? {
        guard !isCancelled() else { return nil }
        let metal = useMetal && width * height >= 65_536 ? MetalPaletteQuantizer(source: source, width: width, height: height) : nil
        // Use a bounded histogram with alpha weights so near-transparent samples do not dominate.
        let histogram: [Sample]
        if let totals = metal?.histogram(isCancelled: isCancelled) {
            histogram = totals.map { Sample(weight: Int($0.w), sum: SIMD3(Int64($0.x), Int64($0.y), Int64($0.z))) }
        } else {
            guard !isCancelled() else { return nil }
            var bins = [Sample](repeating: Sample(), count: 32 * 32 * 32)
            let complete = source.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for offset in stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] > 0 {
                    if offset & 0xffff == 0, isCancelled() { return false }
                    let blue = Int(bytes[offset]), green = Int(bytes[offset + 1]), red = Int(bytes[offset + 2])
                    bins[key(blue, green, red)].add(SIMD3(Int64(blue), Int64(green), Int64(red)),
                                                    weight: Int(bytes[offset + 3]))
                }
                return true
            }
            guard complete else { return nil }
            histogram = bins
        }
        let samples = histogram.filter { $0.weight > 0 }
        guard !samples.isEmpty else { return source }
        var buckets = [Bucket(samples)]
        while buckets.count < count,
              let index = buckets.indices.max(by: { buckets[$0].priority < buckets[$1].priority }),
              buckets[index].priority > 0 {
            if isCancelled() { return nil }
            let (left, right) = buckets[index].split()
            buckets[index] = left
            buckets.append(right)
        }
        let palette = buckets.map { $0.centroid.rounded(.toNearestOrAwayFromZero) }
        let matrix = [-8, 0, -6, 2, 4, -4, 6, -2, -5, 3, -7, 1, 7, -1, 5, -3]
        if let metal {
            let lookup = dither == 0 ? histogram.map { bin in
                UInt32(bin.weight == 0 ? 0 : nearest(to: bin.color, in: palette))
            } : nil
            let phases = matrix.flatMap { phase in
                let bias = Double(phase) * 4 * dither
                return (0...255).map { UInt8(clamp(Int(Double($0) + bias)) >> 3) }
            }
            let packed = palette.map { SIMD4(UInt8($0.x), UInt8($0.y), UInt8($0.z), 0) }
            if let output = metal.map(palette: packed, lookup: lookup, phases: phases, isCancelled: isCancelled) { return output }
            if isCancelled() { return nil }
        }
        var colorLookUp = [Int](repeating: -1, count: histogram.count)
        var output = source
        let wroteAll = output.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                if isCancelled() { return false }
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    guard bytes[offset + 3] > 0 else { continue }
                    let bias = Double(matrix[(y % 4) * 4 + x % 4]) * 4 * dither
                    let blue = Int(bytes[offset]), green = Int(bytes[offset + 1]), red = Int(bytes[offset + 2])
                    let original = SIMD3(Double(blue), Double(green), Double(red))
                    let adjusted = original + bias
                    let bin = key(clamp(Int(adjusted.x)), clamp(Int(adjusted.y)), clamp(Int(adjusted.z)))
                    if colorLookUp[bin] < 0 {
                        let sample = dither == 0 ? histogram[bin].color : binCenter(bin)
                        colorLookUp[bin] = nearest(to: sample, in: palette)
                    }
                    let color = palette[colorLookUp[bin]]
                    bytes[offset] = UInt8(color.x)
                    bytes[offset + 1] = UInt8(color.y)
                    bytes[offset + 2] = UInt8(color.z)
                }
            }
            return true
        }
        return wroteAll ? output : nil
    }

    private static func key(_ blue: Int, _ green: Int, _ red: Int) -> Int {
        (blue >> 3) | ((green >> 3) << 5) | ((red >> 3) << 10)
    }

    private static func binCenter(_ key: Int) -> SIMD3<Double> {
        SIMD3(Double((key & 31) * 8 + 4), Double(((key >> 5) & 31) * 8 + 4), Double((key >> 10) * 8 + 4))
    }

    private static func clamp(_ value: Int) -> Int { min(255, max(0, value)) }

    private static func nearest(to sample: SIMD3<Double>, in palette: [SIMD3<Double>]) -> Int {
        var closest = 0
        var minimum = Double.infinity
        for (index, candidate) in palette.enumerated() {
            let difference = sample - candidate
            let squared = difference * difference
            let distance = squared.x + squared.y + squared.z
            if distance < minimum {
                closest = index
                minimum = distance
            }
        }
        return closest
    }
}
