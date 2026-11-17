import CoreGraphics

struct BrushOptions {
    enum Pattern: String, CaseIterable {
        case solid = "Solid Color"
        case horizontal = "Horizontal"
        case vertical = "Vertical"
        case forwardDiagonal = "Forward Diagonal"
        case backwardDiagonal = "Backward Diagonal"
        case cross = "Cross"
        case diagonalCross = "Diagonal Cross"
        case checkerboard = "Small Checker Board"

        // Both painting and erasing use coordinates measured from the top-left of the image.
        func usesPrimary(column: Int, row: Int) -> Bool {
            switch self {
            case .solid: return true
            case .horizontal: return row.isMultiple(of: 8)
            case .vertical: return column.isMultiple(of: 8)
            case .forwardDiagonal: return (column + row).isMultiple(of: 8)
            case .backwardDiagonal: return (column - row).isMultiple(of: 8)
            case .cross: return row.isMultiple(of: 8) || column.isMultiple(of: 8)
            case .diagonalCross:
                return (column + row).isMultiple(of: 8) || (column - row).isMultiple(of: 8)
            case .checkerboard: return (column / 4 + row / 4).isMultiple(of: 2)
            }
        }
    }

    enum Blend: Equatable {
        case layer(LayerBlendMode)
        case overwrite

        static let choices = LayerBlendMode.allCases.map(Self.layer) + [.overwrite]

        var title: String {
            switch self {
            case .layer(let mode): return mode.title
            case .overwrite: return "Overwrite"
            }
        }
    }

    var hardness = 100
    var spacing = 15
    var smoothed = true
    var antialiased = true
    var antialiasedSelection = true
    var pressureSensitive = true
    var pattern: Pattern = .solid
    var blend: Blend = .layer(.normal)
}

struct BrushPath {
    struct Sample: Equatable {
        let point: CGPoint
        let pressure: CGFloat

        func interpolated(to other: Self, by fraction: CGFloat) -> Self {
            let point = CGPoint(x: point.x + (other.point.x - point.x) * fraction,
                                y: point.y + (other.point.y - point.y) * fraction)
            return Self(point: point, pressure: pressure + (other.pressure - pressure) * fraction)
        }
    }

    private let distance: CGFloat
    private let smoothed: Bool
    private var raw: Sample?
    private var filtered: Sample?
    private var distanceToStamp: CGFloat

    init(diameter: CGFloat, options: BrushOptions) {
        distance = max(0.25, diameter * CGFloat(max(options.spacing, 1)) / 100)
        distanceToStamp = distance
        smoothed = options.smoothed
    }

    mutating func append(_ sample: Sample, stamp: (Sample) -> Void) {
        guard let previous = raw else {
            raw = sample
            filtered = sample
            distanceToStamp = spacing(at: sample)
            stamp(sample)
            return
        }
        guard sample != previous else { return }
        raw = sample
        advance(to: smoothed ? previous.interpolated(to: sample, by: 0.5) : sample, stamp: stamp)
    }

    mutating func finish(stamp: (Sample) -> Void) {
        if let raw { advance(to: raw, stamp: stamp) }
    }

    private mutating func advance(to end: Sample, stamp: (Sample) -> Void) {
        guard let start = filtered else { return }
        filtered = end
        let length = hypot(end.point.x - start.point.x, end.point.y - start.point.y)
        guard length > 0 else {
            if end.pressure > start.pressure { stamp(end) }
            return
        }
        while distanceToStamp <= length {
            let sample = start.interpolated(to: end, by: distanceToStamp / length)
            stamp(sample)
            distanceToStamp += spacing(at: sample)
        }
        distanceToStamp -= length
    }

    private func spacing(at sample: Sample) -> CGFloat {
        max(0.25, distance * sample.pressure)
    }
}
