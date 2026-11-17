import Foundation

enum PixelateEffect {
    private enum Downsampling: String, CaseIterable {
        case anisotropic = "Anisotropic"
        case highQualityBicubic = "Bicubic (High Quality)"
        case multisampleBilinear = "Multisample Bilinear"
        case bicubic = "Bicubic"
        case bilinear = "Bilinear"
        case nearest = "Nearest Neighbor"

        var resamplingMode: ImageResampler.Mode {
            switch self {
            case .anisotropic: return .fant
            case .highQualityBicubic, .bicubic: return .bicubic
            case .multisampleBilinear, .bilinear: return .bilinearLowQuality
            case .nearest: return .nearest
            }
        }
    }

    private static let upsampling: [ImageResampler.Mode] = [.bicubic, .bilinear, .nearest]

    static let filter = RasterFilter("Pixelate", category: "Distort", [
        .init("Cell Size", 1...200, 2),
        .init("Scale Down", choices: Downsampling.allCases.map(\.rawValue), initial: 2),
        .init("Scale Up", choices: upsampling.map(\.rawValue), initial: 2)
    ], renderInColorSpace: { source, width, height, colorSpace, _, values, isCancelled in
        let size = Int(values[0])
        if size == 1 { return source }
        let reduction = Downsampling.allCases[Int(values[1])]
        let enlargement = upsampling[Int(values[2])]
        // Smooth reconstruction also uses cells whose centers lie outside the canvas.
        // Sample those cells from the edge-extended original before scaling up.
        let halo = switch enlargement {
        case .nearest: 0
        case .bilinear: 1
        default: 2
        }
        let columns = (width + size - 1) / size + 2 * halo
        let rows = (height + size - 1) / size + 2 * halo
        let cells: Data
        if reduction == .multisampleBilinear {
            let transfer = LinearEffectTransfer(colorSpace: colorSpace)
            guard let sampled = multisample(source, width: width, height: height, cellSize: size,
                                            columns: columns, rows: rows, halo: halo, transfer: transfer,
                                            isCancelled: isCancelled)
            else { return nil }
            cells = sampled
        } else {
            let scaler = ImageResampler(sourceWidth: width, sourceHeight: height, width: columns, height: rows,
                                        mode: reduction.resamplingMode, linearLight: true,
                                        samplingRatio: SIMD2(repeating: Float(size)),
                                        samplingOrigin: SIMD2(repeating: Float(-halo * size)),
                                        widenKernel: reduction == .highQualityBicubic, colorSpace: colorSpace)
            guard let sampled = scaler.resample(source, isCancelled: isCancelled) else { return nil }
            cells = sampled
        }
        guard !isCancelled() else { return nil }
        let scaler = ImageResampler(sourceWidth: columns, sourceHeight: rows, width: width, height: height,
                                    mode: enlargement, linearLight: true,
                                    samplingRatio: SIMD2(repeating: 1 / Float(size)),
                                    samplingOrigin: SIMD2(repeating: Float(halo)), colorSpace: colorSpace)
        return scaler.resample(cells, isCancelled: isCancelled)
    })

    private static let fractions: [SIMD2<Double>] = [
        SIMD2(3, 1) / 8, SIMD2(7, 3) / 8, SIMD2(1, 5) / 8, SIMD2(5, 7) / 8
    ]

    private static func multisample(_ pixels: Data, width: Int, height: Int, cellSize: Int,
                                    columns: Int, rows: Int, halo: Int, transfer: LinearEffectTransfer,
                                    isCancelled: () -> Bool) -> Data? {
        var cells = Data(count: columns * rows * 4)
        let finished = pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            cells.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                for row in 0..<rows {
                    if isCancelled() { return false }
                    for column in 0..<columns {
                        let origin = SIMD2(Double((column - halo) * cellSize), Double((row - halo) * cellSize))
                        var sample = SIMD4<Double>.zero
                        // Four rotated-grid samples are bilinearly interpolated in premultiplied linear light.
                        for fraction in fractions {
                            let point = origin + fraction * Double(cellSize) - 0.5
                            sample += bilinear(source, at: point, width: width, height: height, transfer: transfer)
                        }
                        let offset = (row * columns + column) * 4
                        let alpha = UInt8(clamping: Int((sample.w * 255 / 4).rounded(.toNearestOrEven)))
                        target[offset + 3] = alpha
                        guard alpha > 0 else { continue }
                        for channel in 0..<3 {
                            target[offset + channel] = transfer.encode(sample[channel] / sample.w, channel: channel)
                        }
                    }
                }
                return true
            }
        }
        return finished ? cells : nil
    }

    private static func bilinear(_ pixels: UnsafeRawBufferPointer, at point: SIMD2<Double>,
                                 width: Int, height: Int, transfer: LinearEffectTransfer) -> SIMD4<Double> {
        let left = Int(floor(point.x)), top = Int(floor(point.y))
        let xFraction = point.x - Double(left), yFraction = point.y - Double(top)
        func sample(x: Int, y: Int) -> SIMD4<Double> {
            let offset = (min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))) * 4
            return transfer.premultipliedPixel(in: pixels, at: offset)
        }
        let upper = sample(x: left, y: top) * (1 - xFraction) + sample(x: left + 1, y: top) * xFraction
        let lower = sample(x: left, y: top + 1) * (1 - xFraction) + sample(x: left + 1, y: top + 1) * xFraction
        return upper * (1 - yFraction) + lower * yFraction
    }
}
