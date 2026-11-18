import CoreGraphics
import Foundation

struct ImageResampler {
    enum Mode: String, CaseIterable {
        case bicubic = "Bicubic"
        case bicubicSmooth = "Bicubic (Smooth)"
        case bilinear = "Bilinear"
        case bilinearLowQuality = "Bilinear (Low Quality)"
        case adaptiveSharp = "Adaptive (Sharp)"
        case lanczos = "Lanczos"
        case fant = "Fant"
        case nearest = "Nearest Neighbor"
    }

    struct Tap {
        let index: Int
        let weight: Float
    }

    private let sourceWidth: Int
    private let sourceHeight: Int
    private let width: Int
    private let height: Int
    private let horizontal: [[Tap]]
    private let vertical: [[Tap]]
    private let mode: Mode
    private let linearLight: Bool
    private let profileTransfer: RasterTransferCurve?

    init(sourceWidth: Int, sourceHeight: Int, width: Int, height: Int, mode: Mode, linearLight: Bool,
         samplingRatio: SIMD2<Float>? = nil, samplingOrigin: SIMD2<Float> = .zero,
         widenKernel: Bool = true, colorSpace: CGColorSpace? = nil) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.width = width
        self.height = height
        self.mode = mode
        if linearLight, mode != .nearest, let colorSpace, colorSpace != BGRA8.sRGB {
            profileTransfer = RasterTransferCurve(colorSpace: colorSpace)
            // Some LUT-based ICC profiles have no linearized counterpart.
            self.linearLight = profileTransfer != nil
        } else {
            profileTransfer = nil
            self.linearLight = linearLight
        }
        horizontal = Self.taps(from: sourceWidth, to: width, mode: mode, ratio: samplingRatio?.x, origin: samplingOrigin.x,
                               widenKernel: widenKernel)
        vertical = Self.taps(from: sourceHeight, to: height, mode: mode, ratio: samplingRatio?.y, origin: samplingOrigin.y,
                             widenKernel: widenKernel)
    }

    func resample(_ pixels: Data, useMetal: Bool = true, isCancelled: () -> Bool = { false }) -> Data? {
        guard !isCancelled() else { return nil }
        if useMetal, width * height >= 65_536 {
            if let result = resampleOnMetal(pixels, isCancelled: isCancelled) { return result }
            if isCancelled() { return nil }
        }
        var result = Data(count: width * height * 4)
        let completed = pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            result.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Bool in
                if mode == .nearest {
                    for y in 0..<height {
                        if isCancelled() { return false }
                        for x in 0..<width {
                            let offset = (vertical[y][0].index * sourceWidth + horizontal[x][0].index) * 4
                            let value = source.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                            target.storeBytes(of: value, toByteOffset: (y * width + x) * 4, as: UInt32.self)
                        }
                    }
                    return true
                }

                // Choose the pass order that uses the smaller intermediate raster.
                let horizontalFirst = width * sourceHeight <= sourceWidth * height
                let middleWidth = horizontalFirst ? width : sourceWidth
                let middleHeight = horizontalFirst ? sourceHeight : height
                let table = linearLight ? Self.linearSRGB : Self.identitySRGB
                var middle = [SIMD4<Float>](repeating: .zero, count: middleWidth * middleHeight)
                for y in 0..<middleHeight {
                    if isCancelled() { return false }
                    for x in 0..<middleWidth {
                        var value = SIMD4<Float>.zero
                        for tap in horizontalFirst ? horizontal[x] : vertical[y] {
                            let index = horizontalFirst ? y * sourceWidth + tap.index : tap.index * sourceWidth + x
                            value += Self.readPixel(source, offset: index * 4, colors: table,
                                                    transfer: profileTransfer) * tap.weight
                        }
                        middle[y * middleWidth + x] = value
                    }
                }
                for y in 0..<height {
                    if isCancelled() { return false }
                    for x in 0..<width {
                        var value = SIMD4<Float>.zero
                        for tap in horizontalFirst ? vertical[y] : horizontal[x] {
                            let index = horizontalFirst ? tap.index * middleWidth + x : y * middleWidth + tap.index
                            value += middle[index] * tap.weight
                        }
                        let offset = (y * width + x) * 4
                        let alpha = Self.byte(value.w)
                        target[offset + 3] = alpha
                        guard alpha > 0 else { continue }
                        for channel in 0..<3 {
                            let unpremultiplied = min(1, max(0, value[channel] / value.w))
                            if let profileTransfer {
                                target[offset + channel] = profileTransfer.encodedByte(for: unpremultiplied, channel: channel)
                            } else {
                                target[offset + channel] = Self.byte(linearLight ? Self.encodeSRGB(unpremultiplied) : unpremultiplied)
                            }
                        }
                    }
                }
                return true
            }
        }
        return completed ? result : nil
    }

    func resampleOnMetal(_ pixels: Data, isCancelled: () -> Bool = { false }) -> Data? {
        let transfer = linearLight && mode != .nearest ? profileTransfer?.tables ?? Self.srgbTables : nil
        return MetalRasterGeometry.resize(pixels, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                          width: width, height: height, horizontal: horizontal, vertical: vertical,
                                          nearest: mode == .nearest, transfer: transfer, isCancelled: isCancelled)
    }

    private static func readPixel(_ data: UnsafeRawBufferPointer, offset: Int, colors: [Float],
                                  transfer: RasterTransferCurve?) -> SIMD4<Float> {
        let alpha = Float(data[offset + 3]) / 255
        if let transfer {
            return SIMD4(transfer.linearValue(of: data[offset], channel: 0) * alpha,
                         transfer.linearValue(of: data[offset + 1], channel: 1) * alpha,
                         transfer.linearValue(of: data[offset + 2], channel: 2) * alpha, alpha)
        }
        return SIMD4(colors[Int(data[offset])] * alpha, colors[Int(data[offset + 1])] * alpha,
                     colors[Int(data[offset + 2])] * alpha, alpha)
    }

    private static func byte(_ value: Float) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }

    private static let identitySRGB = (0...255).map { Float($0) / 255 }
    private static let linearSRGB = identitySRGB.map { value in
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static let srgbTables: (decoded: [SIMD3<Float>], thresholds: [SIMD3<Float>]) = {
        // Use the canonical encoder's exact Float boundaries instead of a GPU pow approximation.
        let thresholds = (0..<255).map { code in
            var low: UInt32 = 0, high = Float(1).bitPattern
            while low < high {
                let midpoint = (low + high) / 2
                if Int(byte(encodeSRGB(Float(bitPattern: midpoint)))) <= code { low = midpoint + 1 }
                else { high = midpoint }
            }
            return SIMD3<Float>(repeating: Float(bitPattern: low))
        }
        return (linearSRGB.map { SIMD3<Float>(repeating: $0) }, thresholds)
    }()

    private static func encodeSRGB(_ value: Float) -> Float {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    static func bicubicWeight(_ distance: Float) -> Float {
        if distance < 1 { return ((1.5 * distance - 2.5) * distance) * distance + 1 }
        if distance < 2 { return ((-0.5 * distance + 2.5) * distance - 4) * distance + 2 }
        return 0
    }

    private static func taps(from source: Int, to target: Int, mode: Mode, ratio explicitRatio: Float?, origin: Float,
                             widenKernel: Bool) -> [[Tap]] {
        let ratio = explicitRatio ?? Float(source) / Float(target)
        if source == target && ratio == 1 && origin == 0 { return (0..<source).map { [Tap(index: $0, weight: 1)] } }
        let kernel: Mode = mode == .adaptiveSharp ? (ratio > 1 ? .lanczos : .bicubic) : mode
        return (0..<target).map { index in
            let edge = origin + Float(index) * ratio
            let center = edge + ratio / 2 - 0.5
            if kernel == .nearest {
                return [Tap(index: min(source - 1, max(0, Int(edge + ratio / 2))), weight: 1)]
            }
            if kernel == .fant && ratio > 1 {
                let end = origin + Float(index + 1) * ratio
                let last = explicitRatio == nil ? min(source, Int(ceil(end))) : Int(ceil(end))
                return (Int(floor(edge))..<last).map { pixel in
                    let overlap = min(end, Float(pixel + 1)) - max(edge, Float(pixel))
                    return Tap(index: min(source - 1, max(0, pixel)), weight: overlap / ratio)
                }
            }
            let scale = widenKernel && kernel != .bilinearLowQuality ? max(ratio, 1) : 1
            let radius: Float
            switch kernel {
            case .lanczos: radius = 3
            case .bicubic, .bicubicSmooth: radius = 2
            default: radius = 1
            }
            let first = Int(ceil(center - radius * scale))
            let last = Int(floor(center + radius * scale))
            let weights = (first...last).map { weight(abs(Float($0) - center) / scale, mode: kernel) }
            let total = weights.reduce(0, +)
            // Extend the source's edge pixels for samples outside the image.
            return weights.enumerated().compactMap { offset, value in
                guard value != 0 else { return nil }
                return Tap(index: min(source - 1, max(0, offset + first)), weight: value / total)
            }
        }
    }

    private static func weight(_ x: Float, mode: Mode) -> Float {
        switch mode {
        case .lanczos:
            if x == 0 { return 1 }
            guard x < 3 else { return 0 }
            let t = Float.pi * x
            return (sin(t) / t) * (sin(t / 3) / (t / 3))
        case .bicubic:
            return bicubicWeight(x)
        case .bicubicSmooth:
            if x < 1 { return ((3 * x - 6) * x * x + 4) / 6 }
            let distance = max(0, 2 - x)
            return distance * distance * distance / 6
        default:
            return max(0, 1 - x)
        }
    }
}
