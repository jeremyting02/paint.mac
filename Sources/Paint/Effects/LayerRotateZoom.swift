import Foundation

enum LayerRotateZoom {
    private enum Tiling: Int, CaseIterable {
        case transparent, repeatImage, mirror

        func index(_ value: Int, extent: Int) -> Int? {
            switch self {
            case .transparent: return (0..<extent).contains(value) ? value : nil
            case .repeatImage:
                let position = value % extent
                return position < 0 ? position + extent : position
            case .mirror:
                let period = extent * 2
                let position = (value % period + period) % period
                return position < extent ? position : period - position - 1
            }
        }
    }

    private struct Projection {
        let center: SIMD2<Double>
        let translation: SIMD2<Double>
        let zoom: Double
        let roll: Double
        let direction: Double
        let tilt: Double
        let depth: Double

        var isIdentity: Bool { roll == 0 && tilt == 0 && translation == .zero && zoom == 1 }

        func inverseSampler() -> (SIMD2<Double>) -> SIMD2<Double>? {
            let azimuth = SIMD2(cos(direction), sin(direction))
            let orthogonal = SIMD2(-azimuth.y, azimuth.x)
            let tiltCos = cos(tilt), tiltSin = sin(tilt)
            let rollCos = cos(roll), rollSin = sin(roll)
            return { destination in
                let point = (destination - center - translation) / zoom
                let u = point.x * azimuth.x + point.y * azimuth.y
                let v = point.x * orthogonal.x + point.y * orthogonal.y
                // Invert a perspective projection of the plane tilted along the chosen compass direction.
                let denominator = depth * tiltCos - u * tiltSin
                guard tiltCos > 1e-8, denominator > 1e-6 else { return nil }
                let tiltedX = u * depth / denominator
                let tiltedY = v * (depth + tiltSin * tiltedX) / depth
                let rolled = azimuth * tiltedX + orthogonal * tiltedY
                let original = SIMD2(rollCos * rolled.x + rollSin * rolled.y,
                                     -rollSin * rolled.x + rollCos * rolled.y)
                return original + center
            }
        }
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: UnsafeRawBufferPointer
        let tiling: Tiling

        func word(_ x: Int, _ y: Int) -> UInt32 {
            guard let column = tiling.index(x, extent: width), let row = tiling.index(y, extent: height) else { return 0 }
            return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: (row * width + column) * 4, as: UInt32.self))
        }

        func premultiplied(_ word: UInt32) -> SIMD4<Double> {
            let alpha = Double(word >> 24) / 255
            let scale = alpha / 255
            return SIMD4(Double(word & 255) * scale, Double((word >> 8) & 255) * scale,
                         Double((word >> 16) & 255) * scale, alpha)
        }

        func sample(_ position: SIMD2<Double>, nearest: Bool) -> SIMD4<Double> {
            if nearest { return premultiplied(word(Int(position.x.rounded()), Int(position.y.rounded()))) }
            let x = Int(floor(position.x)), y = Int(floor(position.y))
            let dx = position.x - Double(x), dy = position.y - Double(y)
            let a = premultiplied(word(x, y)) * (1 - dx) + premultiplied(word(x + 1, y)) * dx
            let b = premultiplied(word(x, y + 1)) * (1 - dx) + premultiplied(word(x + 1, y + 1)) * dx
            return a * (1 - dy) + b * dy
        }
    }

    static let filter = RasterFilter("Rotate / Zoom", [
        .init("Rotation", -180...180, 0, step: 0.1), .init("Tilt Direction", -180...180, 0, step: 0.1),
        .init("Tilt Angle", 0...90, 0, step: 0.1), .init("Horizontal Pan (%)", -100...100, 0, step: 0.01),
        .init("Vertical Pan (%)", -100...100, 0, step: 0.01), .init("Zoom (%)", 1...1_000, 100, step: 0.1),
        .init("Quality", 1...4, 2), .init("Tiling", choices: ["Transparent", "Repeat", "Mirror"]),
        .init("Sampling", choices: ["Bilinear", "Nearest Neighbor"])
    ], preview: renderOnMetal, render: render)

    private static func projection(width: Int, height: Int, values: [Double]) -> Projection {
        let degrees = Double.pi / 180
        return Projection(center: SIMD2(Double(width - 1), Double(height - 1)) / 2,
                          translation: SIMD2(values[3] * Double(width), values[4] * Double(height)) / 100,
                          zoom: values[5] / 100, roll: values[0] * degrees,
                          direction: values[1] * degrees, tilt: values[2] * degrees,
                          depth: Double(max(width, height)) * 1.75)
    }

    static func renderOnMetal(_ bytes: Data, _ width: Int, _ height: Int, _ values: [Double],
                              _ isCancelled: () -> Bool) -> Data? {
        let projection = projection(width: width, height: height, values: values)
        if projection.isIdentity { return isCancelled() ? nil : bytes }
        guard width * height >= 65_536 else { return nil }
        let modes = UInt32(values[7] * 2 + values[8])
        let parameters = MetalRasterGeometry.ProjectionParameters(
            sizeAndModes: SIMD4(UInt32(width), UInt32(height), UInt32(values[6]), modes),
            centerAndPan: SIMD4(Float(projection.center.x), Float(projection.center.y),
                                Float(projection.translation.x), Float(projection.translation.y)),
            project: SIMD4(Float(projection.zoom), Float(projection.depth), Float(cos(projection.tilt)), Float(sin(projection.tilt))),
            angles: SIMD4(Float(cos(projection.direction)), Float(sin(projection.direction)),
                          Float(cos(projection.roll)), Float(sin(projection.roll)))
        )
        return MetalRasterGeometry.project(bytes, parameters: parameters, isCancelled: isCancelled)
    }

    static func render(_ bytes: Data, _ width: Int, _ height: Int, _ values: [Double],
                       _ isCancelled: () -> Bool) -> Data? {
        let projection = projection(width: width, height: height, values: values)
        if projection.isIdentity { return bytes }
        let tiling = Tiling.allCases[Int(values[7])]
        let nearest = values[8] == 1
        let quality = Int(values[6])
        let subpixel = (0..<quality).map { (Double($0) + 0.5) / Double(quality) - 0.5 }
        let offsets = subpixel.flatMap { y in subpixel.map { x in SIMD2(x, y) } }
        let inverse = projection.inverseSampler()
        var result = Data(count: bytes.count)
        let completed = result.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            bytes.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                let raster = Raster(width: width, height: height, bytes: input, tiling: tiling)
                for y in 0..<height {
                    for x in 0..<width {
                        if x & 63 == 0, isCancelled() { return false }
                        let center = SIMD2(Double(x), Double(y))
                        let start = (y * width + x) * 4
                        if nearest && quality == 1 {
                            if let pixel = inverse(center) {
                                let word = raster.word(Int(pixel.x.rounded()), Int(pixel.y.rounded()))
                                output.storeBytes(of: word.littleEndian, toByteOffset: start, as: UInt32.self)
                            }
                        } else {
                            var sum = SIMD4<Double>.zero
                            for offset in offsets {
                                if let pixel = inverse(center + offset) { sum += raster.sample(pixel, nearest: nearest) }
                            }
                            let value = sum / Double(offsets.count)
                            let alpha = byte(value.w)
                            output[start + 3] = alpha
                            if alpha > 0 {
                                for channel in 0..<3 { output[start + channel] = byte(value[channel] / value.w) }
                            }
                        }
                    }
                }
                return true
            }
        }
        return completed ? result : nil
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8((min(1, max(0, value)) * 255).rounded())
    }
}
