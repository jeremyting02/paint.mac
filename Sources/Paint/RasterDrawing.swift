import AppKit

struct DrawingColor: Equatable {
    let blue: UInt8
    let green: UInt8
    let red: UInt8
    let alpha: UInt8

    init(_ color: NSColor, in colorSpace: CGColorSpace? = nil) {
        let srgb = color.usingColorSpace(.sRGB) ?? .black
        let profile = colorSpace.flatMap(NSColorSpace.init(cgColorSpace:))
        let color = profile.flatMap(srgb.usingColorSpace) ?? srgb
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
        let r = CGFloat(red) / divisor, g = CGFloat(green) / divisor, b = CGFloat(blue) / divisor
        let a = CGFloat(alpha) / CGFloat(count * 255)
        if let space = NSColorSpace(cgColorSpace: layer.workingColorSpace),
           space.colorSpaceModel == .rgb {
            let sampled = NSColor(colorSpace: space, components: [r, g, b, a], count: 4)
            return sampled.usingColorSpace(.sRGB)
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

final class RasterDrawing {
    enum Operation {
        case pencil(DrawingColor)
        case paint(primary: DrawingColor, secondary: DrawingColor)
        case erase(opacity: UInt8)
        case clone(source: Data, offset: CGPoint, opacity: UInt8)
        case recolor(from: DrawingColor, to: DrawingColor, tolerance: Int)

        var title: String {
            switch self {
            case .pencil: return "Pencil"
            case .paint: return "Paintbrush"
            case .erase: return "Eraser"
            case .clone: return "Clone Stamp"
            case .recolor: return "Recolor"
            }
        }
    }

    private let layer: PaintLayer
    private let original: Data
    private let operation: Operation
    private let radius: CGFloat
    private let options: BrushOptions
    private let mask: Data?
    private var pixels: Data
    private var coverage: [UInt8]
    private var path: BrushPath
    private var lastPencilPoint: CGPoint?
    private var cachedPreview: PaintLayer?
    private var changed = false
    var title: String { operation.title }

    init?(layer: PaintLayer, operation: Operation, diameter: CGFloat, selection: SelectionOutline?,
          options: BrushOptions = BrushOptions()) {
        guard diameter.isFinite, diameter > 0, diameter <= 4096, let pixels = layer.straightPixels else { return nil }
        if case .clone(let source, _, _) = operation, source.count != pixels.count { return nil }
        self.layer = layer
        original = pixels
        self.pixels = pixels
        self.operation = operation
        radius = diameter / 2
        self.options = options
        path = BrushPath(diameter: diameter, options: options)
        let width = layer.image.width, height = layer.image.height
        coverage = [UInt8](repeating: 0, count: width * height)
        mask = selection?.mask(in: CGRect(x: 0, y: 0, width: width, height: height),
                               imageHeight: height, antialiased: options.antialiasedSelection)
        if selection != nil && mask == nil { return nil }
    }

    var preview: PaintLayer? {
        if cachedPreview == nil, changed { cachedPreview = layer.withPixels(pixels) }
        return cachedPreview
    }

    func append(_ point: CGPoint, pressure: CGFloat = 1) {
        guard point.x.isFinite, point.y.isFinite else { return }
        let width = layer.image.width, height = layer.image.height
        // Cap out-of-canvas drags so a distant pointer cannot produce an unbounded line.
        let margin = if case .pencil = operation { CGFloat(1) } else { radius + 1 }
        let point = CGPoint(x: min(max(point.x, -margin), CGFloat(width) + margin),
                            y: min(max(point.y, -margin), CGFloat(height) + margin))
        if case .pencil = operation {
            pencil(to: point)
        } else {
            let pressure = options.pressureSensitive && pressure.isFinite ? min(1, max(0, pressure)) : 1
            path.append(BrushPath.Sample(point: point, pressure: pressure), stamp: stamp)
        }
    }

    func finish() {
        if case .pencil = operation { return }
        path.finish(stamp: stamp)
    }

    private func pencil(to point: CGPoint) {
        let width = layer.image.width, height = layer.image.height
        let start = lastPencilPoint ?? point
        lastPencilPoint = point
        var x = Int(floor(start.x)), y = Int(floor(start.y))
        let endX = Int(floor(point.x)), endY = Int(floor(point.y))
        let dx = abs(endX - x), dy = -abs(endY - y)
        let stepX = x < endX ? 1 : -1, stepY = y < endY ? 1 : -1
        var error = dx + dy
        pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            while true {
                if (0..<width).contains(x), (0..<height).contains(y) {
                    apply(to: target, column: x, row: height - 1 - y, coverage: 255)
                }
                if x == endX && y == endY { break }
                let doubled = 2 * error
                if doubled >= dy { error += dy; x += stepX }
                if doubled <= dx { error += dx; y += stepY }
            }
        }
    }

    private func stamp(_ sample: BrushPath.Sample) {
        let size = radius * sample.pressure
        guard size > 0 else { return }
        let width = layer.image.width, height = layer.image.height
        let x = options.antialiased ? sample.point.x : floor(sample.point.x) + 0.5
        let y = options.antialiased ? sample.point.y : floor(sample.point.y) + 0.5
        let reach = size + (options.antialiased ? 0.5 : 0)
        let core = size * CGFloat(min(max(options.hardness, 0), 100)) / 100
        let left = max(0, Int(floor(x - reach))), right = min(width - 1, Int(ceil(x + reach)))
        let bottom = max(0, Int(floor(y - reach))), top = min(height - 1, Int(ceil(y + reach)))
        guard left <= right, bottom <= top else { return }
        pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            for yPixel in bottom...top {
                let row = height - 1 - yPixel
                for column in left...right where coverage[row * width + column] < 255 {
                    let dx = CGFloat(column) + 0.5 - x, dy = CGFloat(yPixel) + 0.5 - y
                    let squared = dx * dx + dy * dy
                    guard squared <= reach * reach else { continue }
                    let fraction: CGFloat
                    if options.antialiased {
                        // High hardness limits falloff to the antialiased edge.
                        let falloff = min(1, (reach - sqrt(squared)) / (reach - max(0, core - 0.5)))
                        let strength = min(1, 4 * size * size)
                        fraction = falloff * strength
                    } else {
                        fraction = 1
                    }
                    let amount = UInt8(clamping: Int((fraction * 255).rounded()))
                    apply(to: target, column: column, row: row, coverage: amount)
                }
            }
        }
    }

    private func apply(to pixels: UnsafeMutableRawBufferPointer, column: Int, row: Int, coverage amount: UInt8) {
        let width = layer.image.width, height = layer.image.height
        let index = row * width + column
        let amount = (Int(amount) * Int(mask?[index] ?? 255) + 127) / 255
        guard amount > Int(coverage[index]) else { return }
        coverage[index] = UInt8(amount)
        let byte = index * 4
        let before = pixels.loadUnaligned(fromByteOffset: byte, as: UInt32.self)
        let target = UnsafeMutableRawBufferPointer(rebasing: pixels[byte..<(byte + 4)])
        // Each pixel is blended with the layer as it was at mouse-down. Overlapping stamps expand coverage
        // without applying the color or eraser repeatedly in a single stroke.
        for channel in 0..<4 { target[channel] = original[byte + channel] }
        switch operation {
        case .pencil(let color):
            blend(color.blue, color.green, color.red, color.alpha, coverage: amount, into: target)
        case let .paint(primary, secondary):
            let color = options.pattern.usesPrimary(column: column, row: row) ? primary : secondary
            blend(color.blue, color.green, color.red, color.alpha, coverage: amount, into: target)
        case .erase(let opacity):
            if options.pattern.usesPrimary(column: column, row: row) {
                let erased = Int(opacity) * amount
                let remaining = UInt8((Int(target[3]) * (65_025 - erased) + 32_512) / 65_025)
                if remaining == 0 && (target[3] != 0 || erased == 65_025) {
                    target.storeBytes(of: UInt32(0), toByteOffset: 0, as: UInt32.self)
                } else {
                    target[3] = remaining
                }
            }
        case let .clone(source, offset, opacity):
            let sourceX = column + Int(offset.x), sourceRow = row - Int(offset.y)
            if (0..<width).contains(sourceX), (0..<height).contains(sourceRow) {
                let start = (sourceRow * width + sourceX) * 4
                let alpha = UInt8((Int(source[start + 3]) * Int(opacity) + 127) / 255)
                blend(source[start], source[start + 1], source[start + 2], alpha, coverage: amount, into: target)
            }
        case let .recolor(from, to, tolerance):
            recolor(target, from: from, to: to, tolerance: tolerance, coverage: amount)
        }
        if target.loadUnaligned(as: UInt32.self) != before {
            cachedPreview = nil
            changed = true
        }
    }

    private func blend(_ blue: UInt8, _ green: UInt8, _ red: UInt8, _ alpha: UInt8,
                       coverage: Int, into target: UnsafeMutableRawBufferPointer) {
        switch options.blend {
        case .layer(let mode):
            let source = SIMD4(blue, green, red, alpha)
            withUnsafeBytes(of: source) { mode.composite($0, onto: target, opacity: UInt8(coverage)) }
        case .overwrite:
            let foreground = Int(alpha) * coverage
            let backdrop = Int(target[3]) * (255 - coverage)
            let total = foreground + backdrop
            let source = SIMD3(blue, green, red)
            for channel in 0..<3 {
                let value = Int(source[channel]), old = Int(target[channel])
                target[channel] = if total == 0 {
                    UInt8((value * coverage + old * (255 - coverage) + 127) / 255)
                } else {
                    UInt8((value * foreground + old * backdrop + total / 2) / total)
                }
            }
            target[3] = UInt8((total + 127) / 255)
        }
    }

    private func recolor(_ target: UnsafeMutableRawBufferPointer, from: DrawingColor, to: DrawingColor,
                         tolerance: Int, coverage: Int) {
        let source = SIMD3(from.blue, from.green, from.red)
        let destination = SIMD3(to.blue, to.green, to.red)
        let limit = 255 * tolerance / 100
        guard target[3] != 0, (0..<3).allSatisfy({ abs(Int(target[$0]) - Int(source[$0])) <= limit })
        else { return }
        let amount = Int(to.alpha) * coverage
        for channel in 0..<3 {
            let delta = (Int(destination[channel]) - Int(source[channel])) * amount / 65_025
            target[channel] = UInt8(clamping: Int(target[channel]) + delta)
        }
    }
}
