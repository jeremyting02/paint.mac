import Foundation
import simd

extension RasterFilter {
    static let distortionEffects: [Self] = [
        Self("Dents", category: "Distort", [
            .init("Scale", 1...100, 25), .init("Refraction", 0...100, 50),
            .init("Detail", 1...100, 10), .init("Turbulence", 0...100, 10),
            .init("Angle", -180...180, 137.2, step: 0.1), .init("Quality", 1...4, 2), .init("Seed", 0...9999, 0)
        ], preview: { source, width, height, values, cancelled in
            guard values[1] != 0 else { return source }
            return MetalRasterEffects.distortion(.dents, pixels: source, width: width, height: height,
                                                  values: values, isCancelled: cancelled)
        }) { source, width, height, values, isCancelled in
            guard values[1] != 0 else { return source }
            let size = Double(min(width, height))
            let center = SIMD2(Double(width - 1), Double(height - 1)) / 2
            let noiseScale = max(1, size * values[0] / 320)
            let amplitude = size * values[1] / 600
            let detail = values[2] / 100
            let turbulence = values[3] / 100
            let angle = values[4] * .pi / 180
            let direction = SIMD2(cos(angle), sin(angle))
            let perpendicular = SIMD2(-direction.y, direction.x)
            let seed = UInt64(values[6])
            return warp(source, width, height, quality: Int(values[5]), isCancelled: isCancelled) { point in
                let relative = point - center
                let x = simd_dot(relative, direction) / noiseScale
                let y = simd_dot(relative, perpendicular) / noiseScale
                let wide = noise(x, y, seed: seed)
                let fine = noise(x * 3, y * 3, seed: seed + 1)
                let offset = (wide * (1 - detail) + fine * detail) * amplitude
                let shear = noise(x + 24, y * 2, seed: seed + 2) * amplitude * turbulence
                return point + direction * offset + perpendicular * shear
            }
        },
        Self("Frosted Glass", category: "Distort", [
            .init("Maximum Scatter Radius", 0...200, 4), .init("Minimum Scatter Radius", 0...200, 0),
            .init("Diffusion", 0.1...5, 1, step: 0.1), .init("Smoothness", 1...4, 2), .init("Seed", 0...9999, 0)
        ], preview: { source, width, height, values, cancelled in
            guard values[0] != 0 else { return source }
            return MetalRasterEffects.distortion(.frostedGlass, pixels: source, width: width, height: height,
                                                  values: values, isCancelled: cancelled)
        }) { source, width, height, values, isCancelled in
            let maximum = values[0]
            guard maximum != 0 else { return source }
            let minimum = min(maximum, values[1])
            let seed = UInt64(values[4])
            return warp(source, width, height, quality: Int(values[3]), isCancelled: isCancelled) { point in
                let x = Int((point.x * 4).rounded())
                let y = Int((point.y * 4).rounded())
                let angle = random(x, y, seed: seed) * 2 * .pi
                let distance = minimum + (maximum - minimum) * pow(random(x, y, seed: seed + 1), 1 / values[2])
                return point + SIMD2(cos(angle), sin(angle)) * distance
            }
        },
        Self("Polar Inversion", category: "Distort", [
            .init("Scale", -4...4, 1, step: 0.01), .init("Offset X", -100...100, 0), .init("Offset Y", -100...100, 0),
            .init("Edge (1 Clamp, 2 Reflect, 3 Wrap)", 1...3, 2), .init("Quality", 1...4, 2)
        ], preview: { source, width, height, values, cancelled in
            guard values[0] != 0 else { return source }
            return MetalRasterEffects.distortion(.polarInversion, pixels: source, width: width, height: height,
                                                  values: values, isCancelled: cancelled)
        }) { source, width, height, values, isCancelled in
            let amount = values[0]
            guard amount != 0 else { return source }
            let center = SIMD2(Double(width - 1) * (0.5 + values[1] / 200), Double(height - 1) * (0.5 + values[2] / 200))
            let radius = Double(min(width, height)) / 2
            let edge = DistortionEdge(rawValue: Int(values[3])) ?? .reflect
            return warp(source, width, height, edge: edge, quality: Int(values[4]), isCancelled: isCancelled) { point in
                let vector = point - center
                let squared = simd_length_squared(vector)
                guard squared > 0.0001 else { return point }
                return center + vector * (1 - amount + amount * radius * radius / squared)
            }
        },
        Self("Waves", category: "Distort", [
            .init("Mode (1 Wave, 2 Ripple, 3 Spiral, 4 Flower)", 1...4, 1),
            .init("Amplitude", 0...200, 16), .init("Wavelength", 1...400, 80),
            .init("Angle", -180...180, 0), .init("Phase", -180...180, 0), .init("Petals", 2...24, 6),
            .init("Offset X", -100...100, 0), .init("Offset Y", -100...100, 0), .init("Quality", 1...4, 2)
        ], preview: { source, width, height, values, cancelled in
            guard values[1] != 0 else { return source }
            return MetalRasterEffects.distortion(.waves, pixels: source, width: width, height: height,
                                                  values: values, isCancelled: cancelled)
        }) { source, width, height, values, isCancelled in
            let amplitude = values[1]
            guard amplitude != 0 else { return source }
            let mode = Int(values[0])
            let frequency = 2 * .pi / values[2]
            let angle = values[3] * .pi / 180
            let phase = values[4] * .pi / 180
            let direction = SIMD2(cos(angle), sin(angle))
            let perpendicular = SIMD2(-direction.y, direction.x)
            let center = SIMD2(Double(width - 1) * (0.5 + values[6] / 200), Double(height - 1) * (0.5 + values[7] / 200))
            return warp(source, width, height, quality: Int(values[8]), isCancelled: isCancelled) { point in
                let relative = point - center
                if mode == 1 {
                    let displacement = sin(simd_dot(relative, direction) * frequency + phase) * amplitude
                    return point + perpendicular * displacement
                }
                let distance = simd_length(relative)
                guard distance > 0 else { return point }
                let theta = atan2(relative.y, relative.x) - angle
                let argument: Double
                switch mode {
                case 3: argument = distance * frequency + theta * 3
                case 4: argument = theta * values[5] + distance * frequency / 2
                default: argument = distance * frequency
                }
                return point + relative / distance * (sin(argument + phase) * amplitude)
            }
        },
        Self("Outline", category: "Stylize", [
            .init("Thickness", 0...70, 3), .init("Intensity", 0...100, 50), .init("Quality", 1...8, 8)
        ]) { source, width, height, values, isCancelled in
            outline(source, width, height, radius: Int(values[0]), intensity: values[1] / 100,
                    precision: Int(values[2]), isCancelled: isCancelled)
        },
        Self("Relief", category: "Stylize", [.init("Angle", -180...180, 0, step: 0.1)], preview: {
            source, width, height, values, cancelled in
            MetalRasterEffects.distortion(.relief, pixels: source, width: width, height: height,
                                          values: values, isCancelled: cancelled)
        }) { source, width, height, values, isCancelled in
            relief(source, width, height, angle: values[0] * .pi / 180, isCancelled: isCancelled)
        }
    ]

    private enum DistortionEdge: Int {
        case clamp = 1, reflect, wrap

        func index(_ value: Int, count: Int) -> Int {
            switch self {
            case .clamp:
                return min(count - 1, max(0, value))
            case .wrap:
                return ((value % count) + count) % count
            case .reflect:
                guard count > 1 else { return 0 }
                let period = (count - 1) * 2
                let position = ((value % period) + period) % period
                return min(position, period - position)
            }
        }
    }

    private static func warp(_ source: Data, _ width: Int, _ height: Int, edge: DistortionEdge = .clamp,
                             quality: Int, isCancelled: () -> Bool,
                             map: (SIMD2<Double>) -> SIMD2<Double>) -> Data? {
        var output = Data(count: source.count)
        let offsets = quality == 3
            ? [SIMD2(-0.25, -0.25), SIMD2(0.25, 0.25)]
            : [SIMD2(-0.25, -0.25), SIMD2(0.25, -0.25), SIMD2(-0.25, 0.25), SIMD2(0.25, 0.25)]
        let complete = source.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                for y in 0..<height {
                    if isCancelled() { return false }
                    for x in 0..<width {
                        let point = SIMD2(Double(x), Double(y))
                        let offset = (y * width + x) * 4
                        if quality == 1 {
                            let position = map(point)
                            let sx = edge.index(Int(position.x.rounded()), count: width)
                            let sy = edge.index(Int(position.y.rounded()), count: height)
                            let pixel = input.loadUnaligned(fromByteOffset: (sy * width + sx) * 4, as: UInt32.self)
                            output.storeBytes(of: pixel, toByteOffset: offset, as: UInt32.self)
                        } else if quality == 2 {
                            store(sample(input, width, height, at: map(point), edge: edge), in: output, at: offset)
                        } else {
                            var color = SIMD4<Double>.zero
                            for shift in offsets { color += sample(input, width, height, at: map(point + shift), edge: edge) }
                            store(color / Double(offsets.count), in: output, at: offset)
                        }
                    }
                }
                return true
            }
        }
        return complete ? output : nil
    }

    private static func sample(_ input: UnsafeRawBufferPointer, _ width: Int, _ height: Int,
                               at point: SIMD2<Double>, edge: DistortionEdge) -> SIMD4<Double> {
        let x = Int(floor(point.x)), y = Int(floor(point.y))
        let fractionX = point.x - Double(x), fractionY = point.y - Double(y)
        let x0 = edge.index(x, count: width), x1 = edge.index(x + 1, count: width)
        let y0 = edge.index(y, count: height), y1 = edge.index(y + 1, count: height)
        func read(_ x: Int, _ y: Int) -> SIMD4<Double> {
            let offset = (y * width + x) * 4
            let alpha = Double(input[offset + 3]) / 255
            return SIMD4(Double(input[offset]) * alpha, Double(input[offset + 1]) * alpha,
                         Double(input[offset + 2]) * alpha, Double(input[offset + 3]))
        }
        let upper = blend(read(x0, y0), read(x1, y0), fraction: fractionX)
        let lower = blend(read(x0, y1), read(x1, y1), fraction: fractionX)
        return blend(upper, lower, fraction: fractionY)
    }

    private static func blend(_ a: SIMD4<Double>, _ b: SIMD4<Double>, fraction: Double) -> SIMD4<Double> {
        a + (b - a) * fraction
    }

    private static func store(_ premultiplied: SIMD4<Double>, in output: UnsafeMutableRawBufferPointer, at offset: Int) {
        let alpha = byteValue(premultiplied.w)
        if alpha == 0 {
            output.storeBytes(of: UInt32(0), toByteOffset: offset, as: UInt32.self)
            return
        }
        let unpremultiply = 255 / premultiplied.w
        for channel in 0..<3 { output[offset + channel] = byteValue(premultiplied[channel] * unpremultiply) }
        output[offset + 3] = alpha
    }

    private static func byteValue(_ number: Double) -> UInt8 { UInt8(min(255, max(0, number.rounded()))) }

    private static func random(_ x: Int, _ y: Int, seed: UInt64) -> Double {
        var value = UInt64(bitPattern: Int64(x)) &* 0x9e3779b97f4a7c15
        value ^= (UInt64(bitPattern: Int64(y)) &* 0xc2b2ae3d27d4eb4f) &+ (seed &* 0x165667b19e3779f9)
        value ^= value >> 30
        value &*= 0xbf58476d1ce4e5b9
        value ^= value >> 27
        value &*= 0x94d049bb133111eb
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992
    }

    private static func noise(_ x: Double, _ y: Double, seed: UInt64) -> Double {
        let column = Int(floor(x)), row = Int(floor(y))
        let fx = x - Double(column), fy = y - Double(row)
        let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
        let top = random(column, row, seed: seed) * (1 - u) + random(column + 1, row, seed: seed) * u
        let bottom = random(column, row + 1, seed: seed) * (1 - u) + random(column + 1, row + 1, seed: seed) * u
        return (top * (1 - v) + bottom * v) * 2 - 1
    }

    private static func outline(_ source: Data, _ width: Int, _ height: Int, radius: Int, intensity: Double,
                                precision: Int, isCancelled: () -> Bool) -> Data? {
        guard radius > 0 else { return source }
        let shift = 8 - precision
        let taps = radius == 1 ? [-1, 0, 1] : [-radius, -(radius / 2), 0, radius / 2, radius]
        let count = taps.count * taps.count
        let lower = Int((Double(count - 1) * (1 - intensity) / 2).rounded())
        let upper = Int((Double(count - 1) * (1 + intensity) / 2).rounded())
        let offsets = taps.flatMap { y in taps.map { SIMD4(Float($0), Float(y), 0, 0) } }
        let parameters = [SIMD4(Float(count), Float(lower), Float(upper), Float(shift))] + offsets
        if let accelerated = MetalRasterEffects.blur(.outline, pixels: source, width: width, height: height,
                                                     parameters: parameters, isCancelled: isCancelled) {
            return accelerated
        }
        var samples = [UInt8](repeating: 0, count: count)
        var result = source
        let complete = source.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            result.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                for y in 0..<height {
                    if isCancelled() { return false }
                    for x in 0..<width {
                        let offset = (y * width + x) * 4
                        guard input[offset + 3] != 0 else { continue }
                        for channel in 0..<3 {
                            var index = 0
                            for dy in taps {
                                let row = DistortionEdge.clamp.index(y + dy, count: height) * width
                                for dx in taps {
                                    let pixel = (row + DistortionEdge.clamp.index(x + dx, count: width)) * 4
                                    let premultiplied = Int(input[pixel + channel]) * Int(input[pixel + 3]) / 255
                                    samples[index] = UInt8(premultiplied >> shift)
                                    index += 1
                                }
                            }
                            samples.sort()
                            output[offset + channel] = 255 - ((samples[upper] - samples[lower]) << shift)
                        }
                    }
                }
                return true
            }
        }
        return complete ? result : nil
    }

    private static func relief(_ source: Data, _ width: Int, _ height: Int, angle: Double,
                               isCancelled: () -> Bool) -> Data? {
        let delta = SIMD2(cos(angle), sin(angle))
        var output = source
        let complete = source.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                for y in 0..<height {
                    if isCancelled() { return false }
                    for x in 0..<width {
                        let offset = (y * width + x) * 4
                        guard input[offset + 3] != 0 else { continue }
                        let point = SIMD2(Double(x), Double(y))
                        let leading = sample(input, width, height, at: point - delta, edge: .clamp)
                        let trailing = sample(input, width, height, at: point + delta, edge: .clamp)
                        for channel in 0..<3 {
                            let color = Double(input[offset + channel]) + (leading[channel] - trailing[channel]) / 2
                            output[offset + channel] = byteValue(color)
                        }
                    }
                }
                return true
            }
        }
        return complete ? output : nil
    }
}
