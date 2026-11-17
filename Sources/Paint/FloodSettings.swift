import CoreGraphics
import Foundation

struct FloodSettings {
    enum Sampling: String, CaseIterable {
        case layer = "Layer"
        case image = "Image"
    }

    enum Flood: String, CaseIterable {
        case contiguous = "Contiguous"
        case global = "Global"
    }

    var tolerance = 50
    var sampling: Sampling = .layer
    var flood: Flood = .contiguous

    func select(in layer: PaintLayer, x: Int, y: Int, within mask: Data? = nil) -> SelectionOutline? {
        let width = layer.image.width, height = layer.image.height
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        let seedIndex = y * width + x
        if let mask, mask.count != width * height || mask[seedIndex] == 0 { return nil }
        if tolerance == 100 && mask == nil {
            return SelectionOutline(rect: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let pixels = layer.straightPixels else { return nil }

        var region = FloodRegion(width: width, height: height)
        pixels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let seed = Sample(bytes, at: seedIndex * 4)
            let maximum = tolerance * 255 * 255 / 100
            let limit = 4 * maximum * maximum
            region.select(x: x, y: y, flood: flood) { index in
                if let mask, mask[index] == 0 { return false }
                return seed.matches(Sample(bytes, at: index * 4), limit: limit)
            }
        }
        return region.outline()
    }

    private struct Sample {
        let blue: Int
        let green: Int
        let red: Int
        let alpha: Int

        init(_ bytes: UnsafeRawBufferPointer, at offset: Int) {
            let opacity = Int(bytes[offset + 3])
            blue = Int(bytes[offset]) * opacity
            green = Int(bytes[offset + 1]) * opacity
            red = Int(bytes[offset + 2]) * opacity
            alpha = opacity * 255
        }

        func matches(_ other: Self, limit: Int) -> Bool {
            // Compare premultiplied color and alpha, so hidden RGB in transparent pixels is ignored.
            let b = blue - other.blue, g = green - other.green
            let r = red - other.red, a = alpha - other.alpha
            return b * b + g * g + r * r + a * a <= limit
        }
    }
}

private struct FloodRegion {
    private enum Direction: Int, CaseIterable {
        case east, south, west, north

        var clockwise: Self { Self(rawValue: (rawValue + 1) % 4)! }
        var counterclockwise: Self { Self(rawValue: (rawValue + 3) % 4)! }
        var visited: UInt8 { 4 << rawValue }
    }

    private static let selected: UInt8 = 1
    private static let rejected: UInt8 = 2
    private let width: Int
    private let height: Int
    private let stride: Int
    private var cells: [UInt8]
    private var count = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        stride = width + 2
        // A rejected border lets the flood and contour walks inspect neighbors directly.
        cells = [UInt8](repeating: 0, count: stride * (height + 2))
        for column in 0..<stride {
            cells[column] = Self.rejected
            cells[(height + 1) * stride + column] = Self.rejected
        }
        for row in 1...height {
            cells[row * stride] = Self.rejected
            cells[row * stride + width + 1] = Self.rejected
        }
    }

    mutating func select(x: Int, y: Int, flood: FloodSettings.Flood, matches: (Int) -> Bool) {
        if flood == .global {
            for row in 0..<height {
                for column in 0..<width where matches(row * width + column) {
                    cells[(row + 1) * stride + column + 1] = Self.selected
                    count += 1
                }
            }
            return
        }

        let seed = (y + 1) * stride + x + 1
        cells[seed] = Self.selected
        count = 1
        var pending = [seed]
        let neighbors = [-stride, -1, 1, stride]
        while let cell = pending.popLast() {
            for offset in neighbors {
                let next = cell + offset
                guard cells[next] == 0 else { continue }
                let pixel = (next / stride - 1) * width + next % stride - 1
                if matches(pixel) {
                    cells[next] = Self.selected
                    count += 1
                    pending.append(next)
                } else {
                    cells[next] = Self.rejected
                }
            }
        }
    }

    mutating func outline() -> SelectionOutline? {
        if count == width * height {
            return SelectionOutline(rect: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let path = CGMutablePath()
        for row in 1...height {
            for column in 1...width {
                let cell = row * stride + column
                guard contains(cell) else { continue }
                if !contains(cell - stride), cells[cell] & Direction.east.visited == 0 {
                    trace(from: cell, toward: .east, into: path)
                }
                if !contains(cell + 1), cells[cell] & Direction.south.visited == 0 {
                    trace(from: cell + 1, toward: .south, into: path)
                }
                if !contains(cell + stride), cells[cell] & Direction.west.visited == 0 {
                    trace(from: cell + stride + 1, toward: .west, into: path)
                }
                if !contains(cell - 1), cells[cell] & Direction.north.visited == 0 {
                    trace(from: cell + stride, toward: .north, into: path)
                }
            }
        }
        return SelectionOutline(path: path)
    }

    private func contains(_ cell: Int) -> Bool { cells[cell] & Self.selected != 0 }

    private func point(at vertex: Int) -> CGPoint {
        CGPoint(x: vertex % stride - 1, y: height + 1 - vertex / stride)
    }

    // Trace the boundary with selected pixels on the right. Turning right first keeps
    // regions that touch only at a corner separate. Only emit vertices at turns.
    private mutating func trace(from start: Int, toward initialDirection: Direction, into path: CGMutablePath) {
        var vertex = start
        var direction = initialDirection
        path.move(to: point(at: vertex))
        repeat {
            switch direction {
            case .east:
                cells[vertex] |= direction.visited
                vertex += 1
            case .south:
                cells[vertex - 1] |= direction.visited
                vertex += stride
            case .west:
                cells[vertex - stride - 1] |= direction.visited
                vertex -= 1
            case .north:
                cells[vertex - stride] |= direction.visited
                vertex -= stride
            }
            if hasEdge(at: vertex, toward: direction.clockwise) {
                direction = direction.clockwise
            } else if hasEdge(at: vertex, toward: direction) {
                continue
            } else {
                direction = direction.counterclockwise
            }
            if vertex != start || direction != initialDirection { path.addLine(to: point(at: vertex)) }
        } while vertex != start || direction != initialDirection
        path.closeSubpath()
    }

    private func hasEdge(at vertex: Int, toward direction: Direction) -> Bool {
        switch direction {
        case .east: return contains(vertex) && !contains(vertex - stride)
        case .south: return contains(vertex - 1) && !contains(vertex)
        case .west: return contains(vertex - stride - 1) && !contains(vertex - 1)
        case .north: return contains(vertex - stride) && !contains(vertex - stride - 1)
        }
    }
}

extension PaintLayer {
    func filling(_ outline: SelectionOutline, blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8 = 255) -> PaintLayer? {
        let bounds = outline.bounds.integral
        let rect = CGRect(x: bounds.minX, y: CGFloat(image.height) - bounds.maxY,
                          width: bounds.width, height: bounds.height)
        guard let mask = outline.mask(in: rect, imageHeight: image.height),
              var pixels = straightPixels else { return nil }
        let width = Int(rect.width)
        let origin = Int(rect.minY) * image.width + Int(rect.minX)
        guard alpha != 0 else { return nil }
        let source = Int(alpha) * 255
        let channels = [blue, green, red]
        let changed = pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            var changed = false
            for index in mask.indices where mask[index] != 0 {
                let offset = (origin + index / width * image.width + index % width) * 4
                let backdrop = Int(target[offset + 3]) * (255 - Int(alpha))
                let total = source + backdrop
                var fill = UInt32((total + 127) / 255) << 24
                for (channel, value) in channels.enumerated() {
                    let sum = Int(value) * source + Int(target[offset + channel]) * backdrop
                    fill |= UInt32((sum + total / 2) / total) << (8 * channel)
                }
                fill = fill.littleEndian
                guard target.loadUnaligned(fromByteOffset: offset, as: UInt32.self) != fill else { continue }
                target.storeBytes(of: fill, toByteOffset: offset, as: UInt32.self)
                changed = true
            }
            return changed
        }
        return changed ? withPixels(pixels) : nil
    }
}
