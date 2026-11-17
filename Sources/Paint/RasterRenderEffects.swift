import Foundation

extension RasterFilter {
    static let renderEffects: [Self] = [
        Self("Add Noise", category: "Noise", [.init("Intensity", 0...100, 35),
                                              .init("Color Saturation", 0...100, 0),
                                              .init("Coverage", 0...100, 100, step: 0.1),
                                              .init("Seed", 0...65535, 0)], preview: { source, width, height, values, cancelled in
            MetalRasterEffects.procedural(.noise, pixels: source, width: width, height: height,
                                          values: values, isCancelled: cancelled)
        }) { source, _, _, values, isCancelled in
            let intensity = values[0] * 2.55
            let saturation = values[1] / 100
            let coverage = values[2] / 100
            let seed = UInt64(values[3])
            guard intensity > 0, coverage > 0 else { return source }
            var result = source
            let completed = result.withUnsafeMutableBytes { (pixels: UnsafeMutableRawBufferPointer) in
                for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 0 {
                    if offset & 0xffff == 0, isCancelled() { return false }
                    let hash = UInt64(offset) &* 0x9e3779b97f4a7c15 &+ seed
                    guard noise(hash) < coverage else { continue }
                    let gray = noise(hash &+ 1) - noise(hash &+ 2)
                    for channel in 0..<3 {
                        let channelHash = hash &+ UInt64(channel * 2 + 3)
                        let color = noise(channelHash) - noise(channelHash &+ 1)
                        let shift = intensity * (gray + (color - gray) * saturation)
                        pixels[offset + channel] = UInt8(clamping: Int((Double(pixels[offset + channel]) + shift).rounded()))
                    }
                }
                return true
            }
            return completed ? result : nil
        },
        Self("Ordered Dither", category: "Color", [.init("Levels per Channel", 2...16, 2)]) {
            source, width, _, values, isCancelled in
            let bayer4 = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
            let levels = values[0] - 1
            if let accelerated = MetalRasterEffects.orderedDither(source, width: width, levels: Int(levels),
                                                                 isCancelled: isCancelled) {
                return accelerated
            }
            var result = source
            let completed = result.withUnsafeMutableBytes { (pixels: UnsafeMutableRawBufferPointer) in
                for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 0 {
                    if offset & 0xffff == 0, isCancelled() { return false }
                    let pixel = offset / 4
                    let threshold = (Double(bayer4[(pixel / width % 4) * 4 + pixel % width % 4]) + 0.5) / 16
                    for channel in 0..<3 {
                        let normalized = Double(pixels[offset + channel]) / 255 * levels
                        let step = floor(normalized + threshold)
                        pixels[offset + channel] = UInt8((step * 255 / levels).rounded())
                    }
                }
                return true
            }
            return completed ? result : nil
        },
        cloudEffect("Clouds", turbulence: false),
        cloudEffect("Turbulence", turbulence: true),
        fractalEffect("Julia Fractal", julia: true),
        fractalEffect("Mandelbrot Fractal", julia: false)
    ]

    private static func noise(_ seed: UInt64) -> Double {
        // SplitMix64 hash so previews and Repeat Last Effect use the same sample pattern.
        var value = seed &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return Double((value ^ (value >> 31)) >> 11) / 9_007_199_254_740_992
    }

    private static func cloudEffect(_ name: String, turbulence: Bool) -> Self {
        Self(name, category: "Render", [.init("Scale", 2...1000, 60),
                                       .init("Roughness", 0...100, 50), .init("Seed", 0...65535, 0)], preview: {
            source, width, height, values, cancelled in
            MetalRasterEffects.procedural(turbulence ? .turbulence : .clouds, pixels: source, width: width, height: height,
                                          values: values, isCancelled: cancelled)
        }) {
            source, width, height, values, isCancelled in
            let scale = values[0], falloff = values[1] / 100
            let seed = UInt64(values[2])
            let total = (0..<5).reduce(0.0) { $0 + pow(falloff, Double($1)) }
            var result = source
            let completed = result.withUnsafeMutableBytes { (pixels: UnsafeMutableRawBufferPointer) in
                for row in 0..<height {
                    if isCancelled() { return false }
                    for column in 0..<width {
                        var wavelength = scale
                        var amplitude = 1.0
                        var sum = 0.0
                        for octave in 0..<5 {
                            let value = interpolatedNoise(x: Double(column) / wavelength, y: Double(row) / wavelength,
                                                          seed: seed &+ UInt64(octave) &* 0xce91)
                            sum += amplitude * (turbulence ? abs(value * 2 - 1) : value)
                            wavelength /= 2
                            amplitude *= falloff
                        }
                        let gray = UInt8(clamping: Int((sum / total * 255).rounded()))
                        let offset = (row * width + column) * 4
                        pixels[offset] = gray
                        pixels[offset + 1] = gray
                        pixels[offset + 2] = gray
                        pixels[offset + 3] = 255
                    }
                }
                return true
            }
            return completed ? result : nil
        }
    }

    private static func interpolatedNoise(x: Double, y: Double, seed: UInt64) -> Double {
        let left = UInt64(x), top = UInt64(y)
        let dx = x - Double(left), dy = y - Double(top)
        let tx = dx * dx * (3 - 2 * dx), ty = dy * dy * (3 - 2 * dy)
        let topLeft = seed &+ (left &* 0x85ebca6b) &+ (top &* 0xc2b2ae35)
        let a = noise(topLeft), b = noise(topLeft &+ 0x85ebca6b)
        let c = noise(topLeft &+ 0xc2b2ae35), d = noise(topLeft &+ 0x85ebca6b &+ 0xc2b2ae35)
        let upper = a + (b - a) * tx, lower = c + (d - c) * tx
        return upper + (lower - upper) * ty
    }

    private static func fractalEffect(_ name: String, julia: Bool) -> Self {
        let controls: [Control] = [
            .init("Zoom", 1...100, 1, step: 0.1), .init("Iterations", 8...256, 64),
            .init("Angle", -180...180, 0)
        ]
        return Self(name, category: "Render", controls, preview: { source, width, height, values, cancelled in
            MetalRasterEffects.procedural(julia ? .julia : .mandelbrot, pixels: source, width: width, height: height,
                                          values: values, isCancelled: cancelled)
        }) { source, width, height, values, isCancelled in
            let scale = 3.2 / Double(min(width, height)) / values[0]
            let angle = values[2] * .pi / 180
            let sine = sin(angle), cosine = cos(angle), limit = Int(values[1])
            var result = source
            let completed = result.withUnsafeMutableBytes { (pixels: UnsafeMutableRawBufferPointer) in
                for row in 0..<height {
                    if isCancelled() { return false }
                    for column in 0..<width {
                        let x = (Double(column) + 0.5 - Double(width) / 2) * scale
                        let y = (Double(row) + 0.5 - Double(height) / 2) * scale
                        let rotatedX = x * cosine - y * sine
                        let rotatedY = x * sine + y * cosine
                        let real = julia ? -0.745 : rotatedX - 0.65
                        let imaginary = julia ? 0.113 : rotatedY
                        var zr = julia ? rotatedX : 0, zi = julia ? rotatedY : 0
                        var iterations = 0
                        while iterations < limit && zr * zr + zi * zi <= 4 {
                            (zr, zi) = (zr * zr - zi * zi + real, 2 * zr * zi + imaginary)
                            iterations += 1
                        }
                        let offset = (row * width + column) * 4
                        let shade = iterations == limit ? 0.0 : sqrt(Double(iterations) / Double(limit))
                        pixels[offset] = UInt8(255 * shade)
                        pixels[offset + 1] = UInt8(220 * shade * shade)
                        pixels[offset + 2] = UInt8(190 * shade)
                        pixels[offset + 3] = 255
                    }
                }
                return true
            }
            return completed ? result : nil
        }
    }
}
