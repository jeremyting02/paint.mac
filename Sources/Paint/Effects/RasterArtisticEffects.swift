import Foundation

extension RasterFilter {
    static let artisticEffects: [Self] = [
        .init("Linocut", category: "Artistic", [
            .init("Threshold", 0...100, 50), .init("Line Spacing", 2...50, 7), .init("Angle", -180...180, 45)
        ]) { source, width, _, values, isCancelled in
            let threshold = values[0] / 100
            let radians = values[2] * Double.pi / 180
            let horizontal = cos(radians) / values[1], vertical = sin(radians) / values[1]
            var output = source
            for offset in stride(from: 0, to: source.count, by: 4) {
                if offset & 0xffff == 0, isCancelled() { return nil }
                if source[offset + 3] == 0 { continue }
                let pixel = offset / 4
                let luminance = Double(artisticLuma(source, offset)) / 255
                let phase = Double(pixel % width) * horizontal + Double(pixel / width) * vertical
                let surface = phase - floor(phase)
                let light = luminance > threshold + 0.22 * (0.5 - surface)
                output[offset] = light ? 255 : 0
                output[offset + 1] = output[offset]
                output[offset + 2] = output[offset]
            }
            return output
        },
        .init("Mosaic", category: "Artistic", [
            .init("Tile Size", 1...128, 12), .init("Grout Width", 0...12, 1),
            .init("Bevel", 0...100, 25), .init("Stagger Rows", 0...1, 0)
        ]) { source, width, height, values, isCancelled in
            let size = Int(values[0]), grout = min(Int(values[1]), max(0, (size - 1) / 2))
            let bevel = values[2] / 100
            var output = source
            for top in stride(from: 0, to: height, by: size) {
                if isCancelled() { return nil }
                let bottom = min(top + size, height)
                let start = values[3] == 1 && (top / size).isMultiple(of: 2) ? -size / 2 : 0
                for left in stride(from: start, to: width, by: size) {
                    let minX = max(0, left), right = min(left + size, width)
                    var color = SIMD3<Int>(repeating: 0)
                    var total = 0
                    for y in top..<bottom {
                        for x in minX..<right {
                            let offset = (y * width + x) * 4
                            let alpha = Int(source[offset + 3])
                            color &+= SIMD3(Int(source[offset]), Int(source[offset + 1]), Int(source[offset + 2])) &* alpha
                            total += alpha
                        }
                    }
                    guard total > 0 else { continue }
                    for y in top..<bottom {
                        for x in minX..<right {
                            let offset = (y * width + x) * 4
                            if source[offset + 3] == 0 { continue }
                            let insetLight = min(x - left, y - top), insetDark = min(left + size - 1 - x, top + size - 1 - y)
                            let shade: Double
                            if min(insetLight, insetDark) < grout { shade = 0.15 }
                            else if insetLight == grout { shade = 1 + bevel }
                            else if insetDark == grout { shade = 1 - bevel }
                            else { shade = 1 }
                            for channel in 0..<3 {
                                output[offset + channel] = UInt8(clamping: Int((Double(color[channel]) * shade / Double(total)).rounded()))
                            }
                        }
                    }
                }
            }
            return output
        },
        .init("Oil Painting", category: "Artistic", [
            .init("Brush Size", 1...12, 3), .init("Coarseness", 1...64, 25)
        ]) { source, width, height, values, isCancelled in
            oilPaint(source, width: width, height: height, radius: Int(values[0]),
                     buckets: Int(values[1]), isCancelled: isCancelled)
        },
        .init("Pencil Sketch", category: "Artistic", [
            .init("Pencil Tip Size", 1...20, 3), .init("Range", -20...20, 0)
        ]) { source, width, height, values, isCancelled in
            pencilSketch(source, width: width, height: height, radius: Int(values[0]),
                         range: values[1], isCancelled: isCancelled)
        },
        .init("Stained Glass", category: "Artistic", [
            .init("Cell Size", 2...128, 16), .init("Lead Width", 0...12, 2), .init("Seed", 0...999, 0)
        ]) { source, width, height, values, isCancelled in
            stainedGlass(source, width: width, height: height, size: Int(values[0]), lead: values[1],
                         seed: Int(values[2]), isCancelled: isCancelled)
        }
    ]

    private static func artisticLuma(_ pixels: Data, _ offset: Int) -> Int {
        (19 * Int(pixels[offset]) + 183 * Int(pixels[offset + 1]) + 54 * Int(pixels[offset + 2]) + 128) / 256
    }

    private static func oilPaint(_ source: Data, width: Int, height: Int, radius: Int, buckets: Int,
                                 isCancelled: () -> Bool) -> Data? {
        var output = source
        var histogram = Array(repeating: SIMD4<Int>(repeating: 0), count: buckets)
        func addColumn(_ column: Int, rows: ClosedRange<Int>, sign: Int) {
            for row in rows {
                let offset = (row * width + column) * 4
                let alpha = Int(source[offset + 3]) * sign
                if alpha == 0 { continue }
                let bucket = artisticLuma(source, offset) * buckets / 256
                histogram[bucket] &+= SIMD4(Int(source[offset]) * alpha, Int(source[offset + 1]) * alpha,
                                            Int(source[offset + 2]) * alpha, alpha)
            }
        }
        for y in 0..<height {
            if isCancelled() { return nil }
            for index in histogram.indices { histogram[index] = .zero }
            let rows = max(0, y - radius)...min(height - 1, y + radius)
            for x in 0..<min(width, radius) { addColumn(x, rows: rows, sign: 1) }
            for x in 0..<width {
                if x + radius < width { addColumn(x + radius, rows: rows, sign: 1) }
                if x - radius > 0 { addColumn(x - radius - 1, rows: rows, sign: -1) }
                let offset = (y * width + x) * 4
                if source[offset + 3] == 0 { continue }
                var winner = histogram[artisticLuma(source, offset) * buckets / 256]
                for bucket in histogram where bucket.w > winner.w { winner = bucket }
                guard winner.w > 0 else { continue }
                for channel in 0..<3 { output[offset + channel] = UInt8(winner[channel] / winner.w) }
            }
        }
        return output
    }

    private static func pencilSketch(_ source: Data, width: Int, height: Int, radius: Int, range: Double,
                                     isCancelled: () -> Bool) -> Data? {
        var blurred = Data(count: width * height)
        for y in 0..<height {
            if isCancelled() { return nil }
            let row = y * width
            var sum = 0
            for x in 0..<min(width, radius) { sum += artisticLuma(source, (row + x) * 4) }
            for x in 0..<width {
                if x + radius < width { sum += artisticLuma(source, (row + x + radius) * 4) }
                if x - radius > 0 { sum -= artisticLuma(source, (row + x - radius - 1) * 4) }
                blurred[row + x] = UInt8(sum / (min(width - 1, x + radius) - max(0, x - radius) + 1))
            }
        }
        var sums = Array(repeating: 0, count: width)
        var output = source
        for y in 0..<min(height, radius) {
            for x in 0..<width { sums[x] += Int(blurred[y * width + x]) }
        }
        for y in 0..<height {
            if isCancelled() { return nil }
            let count = min(height - 1, y + radius) - max(0, y - radius) + 1
            for x in 0..<width {
                if y + radius < height { sums[x] += Int(blurred[(y + radius) * width + x]) }
                if y - radius > 0 { sums[x] -= Int(blurred[(y - radius - 1) * width + x]) }
                let offset = (y * width + x) * 4
                if source[offset + 3] == 0 { continue }
                let luma = artisticLuma(source, offset)
                let dodge = Double(luma) * 255 / Double(max(1, sums[x] / count))
                let gray = UInt8(clamping: Int((dodge + range * 2).rounded()))
                output[offset] = gray
                output[offset + 1] = gray
                output[offset + 2] = gray
            }
        }
        return output
    }

    private static func stainedGlass(_ source: Data, width: Int, height: Int, size: Int, lead: Double,
                                     seed: Int, isCancelled: () -> Bool) -> Data? {
        func cellCenter(_ gx: Int, _ gy: Int) -> SIMD2<Double> {
            var hash = UInt64(truncatingIfNeeded: gx &* 73_856_093 ^ gy &* 19_349_663 ^ seed &* 83_492_791)
            hash ^= hash >> 16
            hash = hash &* 0x85ebca6b
            hash ^= hash >> 13
            let x = 0.2 + Double(hash & 255) * 0.6 / 255
            let y = 0.2 + Double((hash >> 8) & 255) * 0.6 / 255
            return SIMD2((Double(gx) + x) * Double(size), (Double(gy) + y) * Double(size))
        }
        var output = source
        var centers: [SIMD2<Double>] = []
        for y in 0..<height {
            if isCancelled() { return nil }
            for x in 0..<width {
                if x.isMultiple(of: size) {
                    centers.removeAll(keepingCapacity: true)
                    for gy in (y / size - 1)...(y / size + 1) {
                        for gx in (x / size - 1)...(x / size + 1) { centers.append(cellCenter(gx, gy)) }
                    }
                }
                let offset = (y * width + x) * 4
                if source[offset + 3] == 0 { continue }
                let point = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                var nearest = centers[0], second = centers[1]
                var firstDistance = Double.infinity, secondDistance = Double.infinity
                for candidate in centers {
                    let delta = point - candidate
                    let distance = delta.x * delta.x + delta.y * delta.y
                    if distance < firstDistance {
                        second = nearest
                        secondDistance = firstDistance
                        nearest = candidate
                        firstDistance = distance
                    } else if distance < secondDistance {
                        second = candidate
                        secondDistance = distance
                    }
                }
                let spacing = hypot(nearest.x - second.x, nearest.y - second.y)
                let seam = (secondDistance - firstDistance) / (2 * spacing)
                let sampleX = min(width - 1, max(0, Int(floor(nearest.x))))
                let sampleY = min(height - 1, max(0, Int(floor(nearest.y))))
                let sampleOffset = (sampleY * width + sampleX) * 4
                let sample = source[sampleOffset + 3] == 0 ? offset : sampleOffset
                let shade = lead == 0 ? 1 : min(1, max(0, (seam - lead / 2) + 0.5))
                for channel in 0..<3 {
                    output[offset + channel] = UInt8(clamping: Int((Double(source[sample + channel]) * shade).rounded()))
                }
            }
        }
        return output
    }
}
