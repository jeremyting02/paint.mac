import AppKit

struct DrawingColor: Equatable {
    let blue: UInt8
    let green: UInt8
    let red: UInt8
    let alpha: UInt8

    init(_ color: NSColor) {
        let color = color.usingColorSpace(.sRGB) ?? .black
        func byte(_ value: CGFloat) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        blue = byte(color.blueComponent)
        green = byte(color.greenComponent)
        red = byte(color.redComponent)
        alpha = byte(color.alphaComponent)
    }

    static func pick(from layer: PaintLayer, at point: CGPoint, sampleSize: Int) -> NSColor? {
        let width = layer.image.width, height = layer.image.height
        let x = Int(floor(point.x)), y = height - 1 - Int(floor(point.y))
        guard (0..<width).contains(x), (0..<height).contains(y), let pixels = layer.straightPixels else { return nil }
        let radius = sampleSize / 2
        var red = 0, green = 0, blue = 0, alpha = 0, count = 0
        for row in max(0, y - radius)...min(height - 1, y + radius) {
            for column in max(0, x - radius)...min(width - 1, x + radius) {
                let index = (row * width + column) * 4
                let opacity = Int(pixels[index + 3])
                blue += Int(pixels[index]) * opacity
                green += Int(pixels[index + 1]) * opacity
                red += Int(pixels[index + 2]) * opacity
                alpha += opacity
                count += 1
            }
        }
        let divisor = CGFloat(max(alpha, 1) * 255)
        return NSColor(srgbRed: CGFloat(red) / divisor, green: CGFloat(green) / divisor,
                       blue: CGFloat(blue) / divisor, alpha: CGFloat(alpha) / CGFloat(count * 255))
    }
}

final class RasterDrawing {
    enum Operation {
        case pencil(DrawingColor)
        case clone(source: Data, offset: CGPoint, opacity: UInt8)
        case recolor(from: DrawingColor, to: DrawingColor, tolerance: Int)
    }

    private let layer: PaintLayer
    private let original: Data
    private let operation: Operation
    private let radius: CGFloat
    private let mask: Data?
    private var pixels: Data
    private var visited = Set<Int>()
    private var lastPoint: CGPoint?
    private var cachedPreview: PaintLayer?
    private var changed = false

    init?(layer: PaintLayer, operation: Operation, diameter: CGFloat, selection: SelectionOutline?) {
        guard let pixels = layer.straightPixels else { return nil }
        self.layer = layer
        original = pixels
        self.pixels = pixels
        self.operation = operation
        if case .pencil = operation { radius = 0 }
        else { radius = max(0.5, diameter / 2) }
        mask = selection?.mask(in: CGRect(x: 0, y: 0, width: layer.image.width, height: layer.image.height),
                               imageHeight: layer.image.height)
        if selection != nil && mask == nil { return nil }
    }

    var preview: PaintLayer? {
        if cachedPreview == nil, changed { cachedPreview = layer.withPixels(pixels) }
        return cachedPreview
    }

    func append(_ point: CGPoint) {
        let width = layer.image.width, height = layer.image.height
        // Cap out-of-canvas drags so a distant pointer cannot produce an unbounded line.
        let point = CGPoint(x: min(max(point.x, -radius - 1), CGFloat(width) + radius),
                            y: min(max(point.y, -radius - 1), CGFloat(height) + radius))
        let start = lastPoint ?? point
        lastPoint = point
        var x = Int(floor(start.x)), y = Int(floor(start.y))
        let endX = Int(floor(point.x)), endY = Int(floor(point.y))
        let dx = abs(endX - x), dy = -abs(endY - y)
        let stepX = x < endX ? 1 : -1, stepY = y < endY ? 1 : -1
        var error = dx + dy
        while true {
            stamp(x: x, y: y, width: width, height: height)
            if x == endX && y == endY { break }
            let doubled = 2 * error
            if doubled >= dy { error += dy; x += stepX }
            if doubled <= dx { error += dx; y += stepY }
        }
    }

    private func stamp(x: Int, y: Int, width: Int, height: Int) {
        let reach = Int(radius)
        let left = max(0, x - reach), right = min(width - 1, x + reach)
        let bottom = max(0, y - reach), top = min(height - 1, y + reach)
        guard left <= right, bottom <= top else { return }
        for row in bottom...top {
            for column in left...right {
                let dx = CGFloat(column - x), dy = CGFloat(row - y)
                guard dx * dx + dy * dy <= radius * radius else { continue }
                let index = (height - 1 - row) * width + column
                guard mask?[index] != 0, visited.insert(index).inserted else { continue }
                let byte = index * 4
                switch operation {
                case .pencil(let color):
                    blend(blue: color.blue, green: color.green, red: color.red, alpha: color.alpha, at: byte)
                case .clone(let source, let offset, let opacity):
                    let sourceX = column + Int(offset.x), sourceY = row + Int(offset.y)
                    guard (0..<width).contains(sourceX), (0..<height).contains(sourceY) else { continue }
                    let start = ((height - 1 - sourceY) * width + sourceX) * 4
                    let alpha = UInt8((Int(source[start + 3]) * Int(opacity) + 127) / 255)
                    blend(blue: source[start], green: source[start + 1], red: source[start + 2], alpha: alpha, at: byte)
                case .recolor(let from, let to, let tolerance):
                    recolor(at: byte, from: from, to: to, tolerance: tolerance)
                }
            }
        }
    }

    private func blend(blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8, at index: Int) {
        guard alpha > 0 else { return }
        let source = Int(alpha) * 255
        let backdrop = Int(original[index + 3]) * (255 - Int(alpha))
        let total = source + backdrop
        for (channel, value) in [blue, green, red].enumerated() {
            let sum = Int(value) * source + Int(original[index + channel]) * backdrop
            replace(at: index + channel, with: UInt8((sum + total / 2) / total))
        }
        replace(at: index + 3, with: UInt8((total + 127) / 255))
    }

    private func recolor(at index: Int, from: DrawingColor, to: DrawingColor, tolerance: Int) {
        let source = [from.blue, from.green, from.red]
        let destination = [to.blue, to.green, to.red]
        let limit = 255 * tolerance / 100
        guard original[index + 3] != 0,
              source.enumerated().allSatisfy({ abs(Int(original[index + $0.offset]) - Int($0.element)) <= limit })
        else { return }
        let amount = Int(to.alpha)
        for (channel, value) in destination.enumerated() {
            let delta = (Int(value) - Int(source[channel])) * amount / 255
            replace(at: index + channel, with: UInt8(clamping: Int(original[index + channel]) + delta))
        }
    }

    private func replace(at index: Int, with value: UInt8) {
        guard pixels[index] != value else { return }
        cachedPreview = nil
        changed = true
        pixels[index] = value
    }
}
