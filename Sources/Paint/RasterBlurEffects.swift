import Foundation

extension RasterFilter {
    static let blurEffects: [Self] = [
        Self("Motion Blur", category: "Blurs", [
            .init("Angle", -180...180, 0, step: 0.1),
            .init("Distance", 0...200, 10),
            .init("Centered", choices: ["Off", "On"], initial: 1),
            .init("Edge Behavior", choices: ["Clamp", "Wrap", "Mirror", "Transparent"])
        ], preview: { bytes, width, height, values, cancelled in
            let taps = motionTaps(values)
            guard !taps.isEmpty else { return bytes }
            let parameters = [SIMD4(Float(taps.count), Float(values[3]), 0, 0)] + taps.map {
                SIMD4(Float($0.x), Float($0.y), Float($0.weight), 0)
            }
            return MetalRasterEffects.blur(.motion, pixels: bytes, width: width, height: height,
                                           parameters: parameters, isCancelled: cancelled)
        }, render: { bytes, width, height, values, cancelled in
            let taps = motionTaps(values)
            guard !taps.isEmpty else { return bytes }
            let edge = BlurEdge.allCases[Int(values[3])]
            return renderBlur(bytes, width: width, height: height, edge: edge, cancelled: cancelled) { raster, x, y in
                var sum = Pixel.zero
                for tap in taps { sum += raster.at(x + tap.x, y + tap.y) * tap.weight }
                return sum
            }
        }),
        Self("Fragment Blur", category: "Blurs", [
            .init("Fragment Count", 2...50, 4), .init("Distance", 0...100, 8), .init("Rotation", 0...360, 0)
        ], preview: { bytes, width, height, values, cancelled in
            guard values[1] > 0 else { return bytes }
            return MetalRasterEffects.blur(.fragment, pixels: bytes, width: width, height: height,
                                            parameters: [SIMD4(Float(values[0]), 0, 0, 0)] + fragmentOffsets(values).map {
                SIMD4(Float($0.x), Float($0.y), 0, 0)
            }, isCancelled: cancelled)
        }, render: { bytes, width, height, values, cancelled in
            let distance = values[1]
            guard distance > 0 else { return bytes }
            let offsets = fragmentOffsets(values)
            return renderBlur(bytes, width: width, height: height, cancelled: cancelled) { raster, x, y in
                var sum = raster.at(x, y)
                for offset in offsets { sum += raster.at(x + offset.x, y + offset.y) }
                return sum / Double(offsets.count + 1)
            }
        }),
        Self("Radial Blur", category: "Blurs", [
            .init("Angle", 0...360, 15, step: 0.1), .init("Center X", 0...100, 50), .init("Center Y", 0...100, 50),
            .init("Quality", 1...5, 2)
        ], preview: { bytes, width, height, values, cancelled in
            guard values[0] > 0 else { return bytes }
            let originX = Double(width - 1) * values[1] / 100
            let originY = Double(height - 1) * values[2] / 100
            let rotations = radialRotations(values)
            return MetalRasterEffects.blur(.radial, pixels: bytes, width: width, height: height,
                                            parameters: [SIMD4(Float(rotations.count), Float(originX), Float(originY), 0)] +
                                                rotations.map { SIMD4(Float($0.sine), Float($0.cosine), 0, 0) },
                                            isCancelled: cancelled)
        }, render: { bytes, width, height, values, cancelled in
            guard values[0] > 0 else { return bytes }
            let originX = Double(width - 1) * values[1] / 100
            let originY = Double(height - 1) * values[2] / 100
            let rotations = radialRotations(values)
            return renderBlur(bytes, width: width, height: height, cancelled: cancelled) { raster, x, y in
                let dx = Double(x) - originX, dy = Double(y) - originY
                var sum = Pixel.zero
                for rotation in rotations {
                    let px = originX + rotation.cosine * dx - rotation.sine * dy
                    let py = originY + rotation.sine * dx + rotation.cosine * dy
                    sum += raster.interpolated(px, py)
                }
                return sum / Double(rotations.count)
            }
        }),
        Self("Surface Blur", category: "Blurs", [
            .init("Radius", 0...100, 6), .init("Threshold", 0...255, 25)
        ], preview: { bytes, width, height, values, cancelled in
            let radius = Int(values[0]), threshold = values[1] / 255
            guard radius > 0, threshold > 0 else { return bytes }
            let offsets = surfaceOffsets(radius: radius)
            return MetalRasterEffects.blur(.surface, pixels: bytes, width: width, height: height,
                                            parameters: [SIMD4(Float(offsets.count), Float(threshold), 0, 0)] + offsets.map {
                SIMD4(Float($0.x), Float($0.y), Float($0.weight), 0)
            }, isCancelled: cancelled)
        }, render: { bytes, width, height, values, cancelled in
            let radius = Int(values[0]), threshold = values[1] / 255
            guard radius > 0, threshold > 0 else { return bytes }
            let offsets = surfaceOffsets(radius: radius)
            return renderBlur(bytes, width: width, height: height, cancelled: cancelled) { raster, x, y in
                let center = raster.at(x, y)
                var sum = Pixel.zero, totalWeight = 0.0
                for offset in offsets {
                    let sample = raster.at(x + offset.x, y + offset.y)
                    let delta = sample - center
                    let difference = max(abs(delta.x), abs(delta.y), abs(delta.z), abs(delta.w))
                    if difference >= threshold { continue }
                    let weight = offset.weight * (1 - difference / threshold)
                    sum += sample * weight
                    totalWeight += weight
                }
                return sum / totalWeight
            }
        }),
        Self("Median Blur", category: "Blurs", [
            .init("Radius", 0...100, 2), .init("Percentile", 0...100, 50), .init("Quality", 1...5, 3)
        ], preview: { bytes, width, height, values, cancelled in
            let radius = Int(values[0])
            guard radius > 0 else { return bytes }
            let offsets = neighborhood(radius: radius, density: Int(values[2]) + 1)
            return acceleratedQuantile(bytes, width: width, height: height, offsetSets: [offsets],
                                       percentile: values[1], cancelled: cancelled)
        }, render: { bytes, width, height, values, cancelled in
            let radius = Int(values[0])
            guard radius > 0 else { return bytes }
            let offsets = neighborhood(radius: radius, density: Int(values[2]) + 1)
            return renderQuantile(bytes, width: width, height: height, offsetSets: [offsets],
                                  percentile: values[1], cancelled: cancelled)
        }),
        Self("Sketch Blur", category: "Blurs", [
            .init("Radius", 0...100, 8), .init("Percentile", 0...100, 50), .init("Smoothness", 1...8, 3)
        ], preview: { bytes, width, height, values, cancelled in
            let radius = Int(values[0])
            guard radius > 0 else { return bytes }
            let count = 9 + Int(values[2]) * 6
            let sets = (0..<8).map { sketchOffsets(radius: radius, count: count, phase: $0) }
            return acceleratedQuantile(bytes, width: width, height: height, offsetSets: sets,
                                       percentile: values[1], cancelled: cancelled)
        }, render: { bytes, width, height, values, cancelled in
            let radius = Int(values[0])
            guard radius > 0 else { return bytes }
            // Vary the sampling pattern by image region so flat areas stay stable while edges look irregular.
            let count = 9 + Int(values[2]) * 6
            let sets = (0..<8).map { phase in sketchOffsets(radius: radius, count: count, phase: phase) }
            return renderQuantile(bytes, width: width, height: height, offsetSets: sets,
                                  percentile: values[1], cancelled: cancelled)
        })
    ]

    private static func fragmentOffsets(_ values: [Double]) -> [(x: Int, y: Int)] {
        let phase = values[2] * .pi / 180, distance = values[1], count = Int(values[0])
        return (0..<count).map { fragment in
            let angle = phase + Double(fragment) * 2 * .pi / Double(count)
            return (Int((distance * cos(angle)).rounded()), Int((distance * sin(angle)).rounded()))
        }
    }

    private static func radialRotations(_ values: [Double]) -> [(sine: Double, cosine: Double)] {
        let steps = 2 * Int(values[3]) * Int(values[3]) + 1
        let spread = values[0] * .pi / 180
        return (0..<steps).map { step in
            let angle = spread * (Double(step) / Double(steps - 1) - 0.5)
            return (sin(angle), cos(angle))
        }
    }

    private static func surfaceOffsets(radius: Int) -> [(x: Int, y: Int, weight: Double)] {
        neighborhood(radius: radius, density: 4).map { offset in
            let distanceSquared = Double(offset.x * offset.x + offset.y * offset.y)
            return (offset.x, offset.y, exp(-2 * distanceSquared / Double(radius * radius)))
        }
    }

    private static func acceleratedQuantile(_ bytes: Data, width: Int, height: Int,
                                            offsetSets: [[(x: Int, y: Int)]], percentile: Double,
                                            cancelled: () -> Bool) -> Data? {
        let count = offsetSets[0].count
        guard count <= 113 else { return nil }
        let rank = (percentile / 100 * Double(count - 1)).rounded()
        let offsets = offsetSets.flatMap { $0.map { SIMD4(Float($0.x), Float($0.y), 0, 0) } }
        return MetalRasterEffects.blur(.quantile, pixels: bytes, width: width, height: height,
                                       parameters: [SIMD4(Float(count), Float(rank), Float(offsetSets.count), 0)] + offsets,
                                       isCancelled: cancelled)
    }

    private static func motionTaps(_ values: [Double]) -> [(x: Int, y: Int, weight: Double)] {
        let distance = Int(values[1])
        guard distance > 0 else { return [] }
        let angle = values[0] * .pi / 180
        let start = values[2] == 1 ? -Double(distance) / 2 : 0
        let directionX = -cos(angle), directionY = sin(angle)
        var weights: [SIMD2<Int>: Double] = [:]
        // Precompute the bilinear taps once because every destination is at an integer pixel.
        for step in 0...distance {
            let position = start + Double(step)
            let x = directionX * position, y = directionY * position
            let left = Int(floor(x)), top = Int(floor(y))
            let dx = x - Double(left), dy = y - Double(top)
            weights[SIMD2(left, top), default: 0] += (1 - dx) * (1 - dy)
            weights[SIMD2(left + 1, top), default: 0] += dx * (1 - dy)
            weights[SIMD2(left, top + 1), default: 0] += (1 - dx) * dy
            weights[SIMD2(left + 1, top + 1), default: 0] += dx * dy
        }
        return weights.keys.sorted { first, second in
            first.y == second.y ? first.x < second.x : first.y < second.y
        }.compactMap { offset in
            guard let weight = weights[offset], weight > 1e-12 else { return nil }
            return (offset.x, offset.y, weight / Double(distance + 1))
        }
    }

    private enum BlurEdge: CaseIterable {
        case clamp, wrap, mirror, transparent

        func index(_ position: Int, extent: Int) -> Int? {
            if (0..<extent).contains(position) { return position }
            switch self {
            case .clamp: return min(extent - 1, max(0, position))
            case .wrap: return (position % extent + extent) % extent
            case .mirror:
                let period = extent * 2
                let mirrored = (position % period + period) % period
                return min(mirrored, period - mirrored - 1)
            case .transparent: return nil
            }
        }
    }

    private struct BlurRaster {
        let bytes: UnsafeRawBufferPointer
        let width: Int
        let height: Int
        let edge: BlurEdge

        func word(_ x: Int, _ y: Int) -> UInt32 {
            guard let column = edge.index(x, extent: width), let row = edge.index(y, extent: height) else { return 0 }
            return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: (row * width + column) * 4, as: UInt32.self))
        }

        func at(_ x: Int, _ y: Int) -> Pixel {
            let value = word(x, y)
            let alpha = Double(value >> 24) / 255
            let scale = alpha / 255
            return Pixel(Double(value & 255) * scale, Double((value >> 8) & 255) * scale,
                         Double((value >> 16) & 255) * scale, alpha)
        }

        func interpolated(_ x: Double, _ y: Double) -> Pixel {
            let ix = Int(floor(x)), iy = Int(floor(y))
            let dx = x - Double(ix), dy = y - Double(iy)
            let top = at(ix, iy) * (1 - dx) + at(ix + 1, iy) * dx
            let bottom = at(ix, iy + 1) * (1 - dx) + at(ix + 1, iy + 1) * dx
            return top * (1 - dy) + bottom * dy
        }
    }

    private static func renderBlur(_ bytes: Data, width: Int, height: Int, edge: BlurEdge = .clamp, cancelled: () -> Bool,
                                   sample: (BlurRaster, Int, Int) -> Pixel) -> Data? {
        var result = bytes
        let completed = result.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            bytes.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                let raster = BlurRaster(bytes: source, width: width, height: height, edge: edge)
                for y in 0..<height {
                    for x in 0..<width {
                        if x & 127 == 0, cancelled() { return false }
                        let value = sample(raster, x, y)
                        let offset = (y * width + x) * 4
                        target[offset + 3] = blurByte(value.w)
                        for channel in 0..<3 {
                            target[offset + channel] = value.w > 0 ? blurByte(value[channel] / value.w) : 0
                        }
                    }
                }
                return true
            }
        }
        return completed ? result : nil
    }

    private static func blurByte(_ component: Double) -> UInt8 {
        UInt8((min(1, max(0, component)) * 255).rounded())
    }

    private static func neighborhood(radius: Int, density: Int) -> [(x: Int, y: Int)] {
        let spacing = max(1, (radius + density - 1) / density)
        let span = radius / spacing
        var offsets: [(x: Int, y: Int)] = []
        for row in -span...span {
            for column in -span...span {
                let x = column * spacing, y = row * spacing
                if x * x + y * y <= radius * radius { offsets.append((x, y)) }
            }
        }
        return offsets
    }

    private static func sketchOffsets(radius: Int, count: Int, phase: Int) -> [(x: Int, y: Int)] {
        var offsets = [(x: 0, y: 0)]
        let goldenAngle = Double.pi * (3 - sqrt(5.0))
        for index in 0..<count {
            let angle = Double(index) * goldenAngle + Double(phase) * .pi / 4
            let distance = Double(radius) * sqrt((Double(index) + 0.5) / Double(count))
            offsets.append((Int((distance * cos(angle)).rounded()), Int((distance * sin(angle)).rounded())))
        }
        return offsets
    }

    private static func renderQuantile(_ bytes: Data, width: Int, height: Int,
                                       offsetSets: [[(x: Int, y: Int)]], percentile: Double,
                                       cancelled: () -> Bool) -> Data? {
        var result = bytes
        var ordered = [UInt64]()
        ordered.reserveCapacity(offsetSets[0].count)
        let completed = result.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            bytes.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                let raster = BlurRaster(bytes: source, width: width, height: height, edge: .clamp)
                for y in 0..<height {
                    for x in 0..<width {
                        if x & 127 == 0, cancelled() { return false }
                        let region = ((x / 4) &* 19) ^ ((y / 4) &* 23)
                        let offsets = offsetSets[region % offsetSets.count]
                        ordered.removeAll(keepingCapacity: true)
                        for offset in offsets {
                            let color = raster.word(x + offset.x, y + offset.y)
                            let blue = color & 255, green = (color >> 8) & 255, red = (color >> 16) & 255
                            let alpha = color >> 24
                            let luminance = (54 * red + 183 * green + 19 * blue) * alpha
                            ordered.append(UInt64(luminance) << 32 | UInt64(color))
                        }
                        ordered.sort()
                        let quantile = Int((percentile / 100 * Double(ordered.count - 1)).rounded())
                        let selected = UInt32(truncatingIfNeeded: ordered[quantile]).littleEndian
                        target.storeBytes(of: selected, toByteOffset: (y * width + x) * 4, as: UInt32.self)
                    }
                }
                return true
            }
        }
        return completed ? result : nil
    }
}
