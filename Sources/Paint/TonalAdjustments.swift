import Foundation

enum RGBChannel: Int, CaseIterable {
    case red, green, blue

    var pixelOffset: Int { 2 - rawValue }
    var title: String {
        switch self {
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }
}

struct ChannelHistogram {
    private(set) var bins: [[Int]]

    init(pixels: Data, mask: Data?, isCancelled: () -> Bool = { false }) {
        bins = Array(repeating: Array(repeating: 0, count: 256), count: 3)
        guard mask == nil || mask?.count == pixels.count / 4 else { return }
        func count(_ pixels: UnsafeRawBufferPointer, coverage: UnsafeRawBufferPointer?) {
            for pixel in 0..<(pixels.count / 4) {
                if pixel & 0x3fff == 0, isCancelled() { return }
                if let coverage, coverage[pixel] == 0 { continue }
                let offset = pixel * 4
                guard pixels[offset + 3] > 0 else { continue }
                for channel in RGBChannel.allCases {
                    bins[channel.rawValue][Int(pixels[offset + channel.pixelOffset])] += 1
                }
            }
        }
        pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            if let mask {
                mask.withUnsafeBytes { (coverage: UnsafeRawBufferPointer) in count(source, coverage: coverage) }
            } else {
                count(source, coverage: nil)
            }
        }
    }

    private init(bins: [[Int]]) { self.bins = bins }

    subscript(_ channel: RGBChannel) -> [Int] { bins[channel.rawValue] }

    func remapped(by tables: [[UInt8]]) -> Self {
        let output = bins.enumerated().map { channel, input in
            var result = Array(repeating: 0, count: 256)
            for (value, count) in input.enumerated() {
                result[Int(tables[channel][value])] += count
            }
            return result
        }
        return Self(bins: output)
    }
}

struct LevelSettings {
    enum Parameter: Int, CaseIterable {
        case inputBlack, inputWhite, gamma, outputBlack, outputWhite

        var title: String {
            switch self {
            case .inputBlack: return "Black point"
            case .inputWhite: return "White point"
            case .gamma: return "Gamma"
            case .outputBlack: return "Black point"
            case .outputWhite: return "White point"
            }
        }

        var range: ClosedRange<Double> { self == .gamma ? 0.1...10 : 0...255 }
    }

    struct Channel {
        var inputBlack = 0.0
        var inputWhite = 255.0
        var gamma = 1.0
        var outputBlack = 0.0
        var outputWhite = 255.0

        subscript(_ parameter: Parameter) -> Double {
            get {
                switch parameter {
                case .inputBlack: return inputBlack
                case .inputWhite: return inputWhite
                case .gamma: return gamma
                case .outputBlack: return outputBlack
                case .outputWhite: return outputWhite
                }
            }
            set {
                guard newValue.isFinite else { return }
                let stepped = (newValue * (parameter == .gamma ? 100 : 1)).rounded() / (parameter == .gamma ? 100 : 1)
                let value = min(parameter.range.upperBound, max(parameter.range.lowerBound, stepped))
                switch parameter {
                case .inputBlack: inputBlack = min(value, inputWhite - 1)
                case .inputWhite: inputWhite = max(value, inputBlack + 1)
                case .gamma: gamma = value
                case .outputBlack: outputBlack = min(value, outputWhite)
                case .outputWhite: outputWhite = max(value, outputBlack)
                }
            }
        }

        var table: [UInt8] {
            (0...255).map { value in
                let fraction = (Double(value) - inputBlack) / (inputWhite - inputBlack)
                let normalized = min(1, max(0, fraction))
                return UInt8((outputBlack + pow(normalized, 1 / gamma) * (outputWhite - outputBlack)).rounded())
            }
        }
    }

    private(set) var channels = Array(repeating: Channel(), count: 3)

    subscript(_ channel: RGBChannel) -> Channel { channels[channel.rawValue] }

    mutating func set(_ parameter: Parameter, to value: Double, channels selected: Set<RGBChannel>) {
        for channel in selected { channels[channel.rawValue][parameter] = value }
    }

    mutating func set(_ parameter: Parameter, to swatch: [Double], channels selected: Set<RGBChannel>) {
        guard swatch.count == channels.count else { return }
        for channel in selected { channels[channel.rawValue][parameter] = swatch[channel.rawValue] }
    }

    mutating func auto(using histogram: ChannelHistogram, channels selected: Set<RGBChannel>) {
        for channel in selected {
            let bins = histogram[channel]
            guard let black = bins.firstIndex(where: { $0 > 0 }),
                  let white = bins.lastIndex(where: { $0 > 0 }),
                  black < white else { continue }
            var adjustment = Channel()
            adjustment[.inputBlack] = Double(black)
            adjustment[.inputWhite] = Double(white)
            channels[channel.rawValue] = adjustment
        }
    }

    var tables: [[UInt8]] { channels.map(\.table) }

    func filter() -> RasterFilter {
        let tables = self.tables
        return RasterFilter("Levels", editor: .levels) { source, _, _, _, isCancelled in
            applyTables(tables, to: source, skipTransparent: true, isCancelled: isCancelled)
        }
    }
}

struct CurveGraph: Equatable {
    struct Point: Equatable {
        let input: Int
        let output: Int
    }

    private(set) var points = [Point(input: 0, output: 0), Point(input: 255, output: 255)]

    func boundsForMovingPoint(at input: Int) -> ClosedRange<Int> {
        let lower = points.last(where: { $0.input < input }).map { $0.input + 1 } ?? 0
        let upper = points.first(where: { $0.input > input }).map { $0.input - 1 } ?? 255
        return lower...upper
    }

    mutating func setPoint(_ point: Point, replacing input: Int? = nil) {
        let output = min(255, max(0, point.output))
        let bounds = input.map(boundsForMovingPoint(at:)) ?? 0...255
        let boundedInput = min(bounds.upperBound, max(bounds.lowerBound, point.input))
        points.removeAll { $0.input == (input ?? boundedInput) }
        let insertion = points.firstIndex(where: { $0.input > boundedInput }) ?? points.endIndex
        points.insert(Point(input: boundedInput, output: output), at: insertion)
    }

    mutating func removePoint(at input: Int) {
        guard let index = points.firstIndex(where: { $0.input == input }),
              index > 0, index < points.count - 1 else { return }
        points.remove(at: index)
    }

    var table: [UInt8] {
        // Use a natural cubic spline through the points. Outside the end points,
        // extend the closest output value as a constant.
        let count = points.count
        var curvature = [Double](repeating: 0, count: count)
        var residual = curvature
        let x = points.map { Double($0.input) }
        let y = points.map { Double($0.output) }
        for i in 1..<(count - 1) {
            let left = x[i] - x[i - 1]
            let right = x[i + 1] - x[i]
            let weight = left / (left + right)
            let denominator = weight * curvature[i - 1] + 2
            curvature[i] = (weight - 1) / denominator
            let change = (y[i + 1] - y[i]) / right - (y[i] - y[i - 1]) / left
            residual[i] = (6 * change / (left + right) - weight * residual[i - 1]) / denominator
        }
        for i in stride(from: count - 2, through: 0, by: -1) {
            curvature[i] = curvature[i] * curvature[i + 1] + residual[i]
        }
        var segment = 0
        return (0...255).map { input in
            let value = Double(input)
            guard value > x[0] else { return UInt8(points[0].output) }
            guard value < x[count - 1] else { return UInt8(points[count - 1].output) }
            while value > x[segment + 1] { segment += 1 }
            let width = x[segment + 1] - x[segment]
            let right = (value - x[segment]) / width
            let left = 1 - right
            let correction = ((left * left * left - left) * curvature[segment]
                            + (right * right * right - right) * curvature[segment + 1]) * width * width / 6
            let output = (left * y[segment] + right * y[segment + 1] + correction).rounded()
            return UInt8(min(255, max(0, output)))
        }
    }
}

struct CurveSettings {
    enum Mode: Int { case luminosity, rgb }

    var mode = Mode.luminosity
    var luminosity = CurveGraph()
    var rgb = Array(repeating: CurveGraph(), count: 3)

    func filter() -> RasterFilter {
        let channelTables = rgb.map(\.table)
        let intensityTable = luminosity.table
        let mode = self.mode
        return RasterFilter("Curves", editor: .curves) { source, _, _, _, isCancelled in
            switch mode {
            case .luminosity: return applyLuminosity(intensityTable, to: source, isCancelled: isCancelled)
            case .rgb: return applyTables(channelTables, to: source, isCancelled: isCancelled)
            }
        }
    }
}

extension RasterFilter {
    static let autoLevel = Self("Auto-Level") { source, _, _, mask, _, isCancelled in
        let histogram = ChannelHistogram(pixels: source, mask: mask, isCancelled: isCancelled)
        guard !isCancelled() else { return nil }
        var levels = LevelSettings()
        levels.auto(using: histogram, channels: Set(RGBChannel.allCases))
        return applyTables(levels.tables, to: source, skipTransparent: true, isCancelled: isCancelled)
    }
}

private func applyTables(_ tables: [[UInt8]], to source: Data, skipTransparent: Bool = false,
                         isCancelled: () -> Bool) -> Data? {
    var output = source
    let completed = output.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            if offset & 0xffff == 0, isCancelled() { return false }
            if skipTransparent, bytes[offset + 3] == 0 { continue }
            for channel in RGBChannel.allCases {
                let index = offset + channel.pixelOffset
                bytes[index] = tables[channel.rawValue][Int(bytes[index])]
            }
        }
        return true
    }
    return completed ? output : nil
}

private func applyLuminosity(_ table: [UInt8], to source: Data, isCancelled: () -> Bool) -> Data? {
    var output = source
    let completed = output.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            if offset & 0xffff == 0, isCancelled() { return false }
            let lightness = 0.2126 * Double(bytes[offset + 2]) + 0.7152 * Double(bytes[offset + 1])
                          + 0.0722 * Double(bytes[offset])
            let intensity = Int(lightness.rounded())
            let difference = Int(table[intensity]) - intensity
            for channel in 0..<3 {
                bytes[offset + channel] = UInt8(clamping: Int(bytes[offset + channel]) + difference)
            }
        }
        return true
    }
    return completed ? output : nil
}
