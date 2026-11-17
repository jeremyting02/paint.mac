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
    private final class StrokeTile {
        let index: Int
        let rect: CGRect
        let left: Int
        let top: Int
        let right: Int
        let width: Int
        let mask: Data?
        var pixels: Data
        var coverage: [UInt8]

        init(index: Int, rect: CGRect, pixels: Data, mask: Data?) {
            self.index = index
            self.rect = rect
            left = Int(rect.minX)
            top = Int(rect.minY)
            right = Int(rect.maxX) - 1
            width = Int(rect.width)
            self.pixels = pixels
            self.mask = mask
            coverage = [UInt8](repeating: 0, count: pixels.count / 4)
        }

        func offset(column: Int, row: Int) -> Int {
            (row - top) * width + column - left
        }
    }

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
    private let tip: BrushTip?
    private let selection: SelectionOutline?
    private let grid: RasterTileGrid
    private var tiles: [Int: StrokeTile] = [:]
    private var lastTile: StrokeTile?
    private var path: BrushPath
    private var lastPencilPoint: CGPoint?
    private var cachedPreview: PaintLayer?
    private var dirtyLeft = Int.max, dirtyTop = Int.max
    private var dirtyRight = -1, dirtyBottom = -1
    private var lastChangedTile = -1
    private var changedTiles: Set<Int> = []
    private(set) var changed = false
    var title: String { operation.title }

    init?(layer: PaintLayer, operation: Operation, diameter: CGFloat, selection: SelectionOutline?,
          options: BrushOptions = BrushOptions()) {
        guard diameter.isFinite, diameter > 0, diameter <= 4096, let pixels = layer.straightPixels else { return nil }
        if case .clone(let source, _, _) = operation, source.count != pixels.count { return nil }
        self.layer = layer
        original = pixels
        self.operation = operation
        radius = diameter / 2
        self.options = options
        if case .paint = operation, options.antialiased {
            tip = BrushTip(radius: diameter / 2, hardness: options.hardness)
        } else {
            tip = nil
        }
        path = BrushPath(diameter: diameter, options: options)
        let width = layer.image.width, height = layer.image.height
        grid = RasterTileGrid(width: width, height: height)
        self.selection = selection
    }

    var preview: PaintLayer? {
        if cachedPreview == nil, let pixels = pixels(in: grid.bounds) { cachedPreview = layer.withPixels(pixels) }
        return cachedPreview
    }

    /// Return a replacement for a compositing region only when it includes edited pixels.
    func pixels(in region: CGRect) -> Data? {
        guard changed else { return nil }
        let coveringTiles = grid.indices(in: region).compactMap { changedTiles.contains($0) ? tiles[$0] : nil }
        guard !coveringTiles.isEmpty else { return nil }
        let width = layer.image.width
        var pixels = region == grid.bounds ? original : PixelRegion.read(original, width: width, region: region)
        pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            for tile in coveringTiles {
                let overlap = region.intersection(tile.rect)
                let source = CGPoint(x: overlap.minX - tile.rect.minX, y: overlap.minY - tile.rect.minY)
                let destination = CGPoint(x: overlap.minX - region.minX, y: overlap.minY - region.minY)
                PixelRegion.copy(tile.pixels, sourceWidth: tile.width, sourceOrigin: source,
                                 to: target, targetWidth: Int(region.width), targetOrigin: destination, size: overlap.size)
            }
        }
        return pixels
    }

    private func tile(column: Int, row: Int) -> StrokeTile {
        let index = grid.index(column: column, row: row)
        if let lastTile, lastTile.index == index { return lastTile }
        if let tile = tiles[index] {
            lastTile = tile
            return tile
        }
        let rect = grid.rect(at: index)
        let pixels = PixelRegion.read(original, width: layer.image.width, region: rect)
        let mask = selection.flatMap {
            $0.mask(in: rect, imageHeight: layer.image.height, antialiased: options.antialiasedSelection)
                ?? Data(count: pixels.count / 4)
        }
        let tile = StrokeTile(index: index, rect: rect, pixels: pixels, mask: mask)
        tiles[index] = tile
        lastTile = tile
        return tile
    }

    /// Return the changes since the last display invalidation in top-left pixel coordinates.
    func takeDirtyBounds() -> CGRect {
        guard dirtyRight >= 0 else { return .null }
        let rect = CGRect(x: dirtyLeft, y: dirtyTop,
                          width: dirtyRight - dirtyLeft + 1, height: dirtyBottom - dirtyTop + 1)
        dirtyLeft = Int.max
        dirtyTop = Int.max
        dirtyRight = -1
        dirtyBottom = -1
        return rect
    }

    func undoPatch(layerIndex: Int) -> RasterHistoryPatch {
        RasterHistoryPatch(layerIndex: layerIndex, activeIndex: layerIndex,
                           width: layer.image.width, height: layer.image.height,
                           regions: changedTiles.sorted().map { grid.rect(at: $0) }, pixels: original)
    }

    func append(_ point: CGPoint, pressure: CGFloat = 1) {
        guard point.x.isFinite, point.y.isFinite else { return }
        let width = layer.image.width, height = layer.image.height
        // Cap out-of-canvas drags so a distant pointer cannot produce an unbounded line.
        let margin = if case .pencil = operation { CGFloat(1) } else { (tip?.reach(radius: radius) ?? radius) + 1 }
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
        while true {
            if (0..<width).contains(x), (0..<height).contains(y) {
                let row = height - 1 - y
                let tile = tile(column: x, row: row)
                tile.pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                    apply(to: target, tile: tile, column: x, row: row, coverage: 255)
                }
            }
            if x == endX && y == endY { break }
            let doubled = 2 * error
            if doubled >= dy { error += dy; x += stepX }
            if doubled <= dx { error += dx; y += stepY }
        }
    }

    private func stamp(_ sample: BrushPath.Sample) {
        let requestedRadius = radius * sample.pressure
        guard requestedRadius > 0 else { return }
        let width = layer.image.width, height = layer.image.height
        let size: CGFloat
        let center: CGPoint
        if options.antialiased {
            size = requestedRadius
            center = sample.point
        } else {
            let diameter = max(1, (requestedRadius * 2).rounded())
            size = diameter / 2
            // Odd tips center on a pixel. Even tips center on the intersection of four pixels.
            // Snap in top-left image coordinates so ties choose the same direction on both axes.
            let phase: CGFloat = diameter.truncatingRemainder(dividingBy: 2) == 0 ? 0 : 0.5
            func snap(_ coordinate: CGFloat) -> CGFloat {
                floor(coordinate + 0.5 - phase) + phase
            }
            center = CGPoint(x: snap(sample.point.x), y: CGFloat(height) - snap(CGFloat(height) - sample.point.y))
        }
        let x = center.x, y = center.y
        let reach = tip?.reach(radius: size) ?? (size + (options.antialiased ? 0.5 : 0))
        let core = size * CGFloat(min(100, max(0, options.hardness))) / 100
        let left = max(0, Int(floor(x - reach))), right = min(width - 1, Int(ceil(x + reach)))
        let bottom = max(0, Int(floor(y - reach))), top = min(height - 1, Int(ceil(y + reach)))
        guard left <= right, bottom <= top else { return }
        for yPixel in bottom...top {
            let row = height - 1 - yPixel
            var start = left
            while start <= right {
                let tile = tile(column: start, row: row)
                let end = min(right, tile.right)
                tile.pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                    for column in start...end where tile.coverage[tile.offset(column: column, row: row)] < 255 {
                        let dx = CGFloat(column) + 0.5 - x, dy = CGFloat(yPixel) + 0.5 - y
                        let squared = dx * dx + dy * dy
                        guard squared <= reach * reach else { continue }
                        let amount: UInt8
                        if let tip {
                            amount = tip.coverage(distance: sqrt(squared), radius: size)
                        } else if options.antialiased {
                            let falloff = min(1, (reach - sqrt(squared)) / (reach - max(0, core - 0.5)))
                            let strength = min(1, 4 * size * size)
                            amount = UInt8(clamping: Int((falloff * strength * 255).rounded()))
                        } else {
                            amount = 255
                        }
                        apply(to: target, tile: tile, column: column, row: row, coverage: amount)
                    }
                }
                start = end + 1
            }
        }
    }

    private func apply(to pixels: UnsafeMutableRawBufferPointer, tile: StrokeTile,
                       column: Int, row: Int, coverage amount: UInt8) {
        let width = layer.image.width, height = layer.image.height
        let index = tile.offset(column: column, row: row)
        let amount = (Int(amount) * Int(tile.mask?[index] ?? 255) + 127) / 255
        guard amount > Int(tile.coverage[index]) else { return }
        tile.coverage[index] = UInt8(amount)
        let byte = index * 4
        let before = pixels.loadUnaligned(fromByteOffset: byte, as: UInt32.self)
        let target = UnsafeMutableRawBufferPointer(rebasing: pixels[byte..<(byte + 4)])
        // Each pixel is blended with the layer as it was at mouse-down. Overlapping stamps expand coverage
        // without applying the color or eraser repeatedly in a single stroke.
        let originalOffset = (row * width + column) * 4
        for channel in 0..<4 { target[channel] = original[originalOffset + channel] }
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
            dirtyLeft = min(dirtyLeft, column)
            dirtyRight = max(dirtyRight, column)
            dirtyTop = min(dirtyTop, row)
            dirtyBottom = max(dirtyBottom, row)
            if tile.index != lastChangedTile {
                changedTiles.insert(tile.index)
                lastChangedTile = tile.index
            }
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
