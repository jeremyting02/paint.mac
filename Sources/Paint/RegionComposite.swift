import CoreGraphics
import Foundation

/// A straight-alpha source window. The stride and offset are measured in pixels.
struct CompositeSource {
    var pixels: Data
    var stride: Int
    var offset: Int
    let mode: LayerBlendMode
    let opacity: UInt8

    func window(at origin: CGPoint) -> Self {
        var source = self
        source.offset += Int(origin.y) * stride + Int(origin.x)
        return source
    }
}

enum RegionComposite {
    // The pointer stays within Data's mutable borrow. Each worker owns a disjoint byte range.
    private struct FullOutput: @unchecked Sendable {
        let buffer: UnsafeMutableRawBufferPointer

        func blend(_ range: Range<Int>, sources: [CompositeSource]) {
            let bytes = UnsafeMutableRawBufferPointer(rebasing: buffer[range.lowerBound * 4..<range.upperBound * 4])
            let blockSize = min(range.count, 4096)
            var block = [SIMD4<Float>](repeating: .zero, count: blockSize)
            block.withUnsafeMutableBufferPointer { buffer in
                for first in stride(from: range.lowerBound, to: range.upperBound, by: blockSize) {
                    let count = min(blockSize, range.upperBound - first)
                    let target = UnsafeMutableBufferPointer(start: buffer.baseAddress, count: count)
                    for index in target.indices { target[index] = .zero }
                    for source in sources {
                        source.pixels.withUnsafeBytes {
                            source.mode.composite($0, startingAt: first, onto: target, opacity: source.opacity)
                        }
                    }
                    LayerBlendMode.storeComposite(UnsafeBufferPointer(target), in: bytes,
                                                   startingAt: first - range.lowerBound)
                }
            }
        }
    }

    /// Full-canvas sources are contiguous. Split at block boundaries while keeping layer order per pixel.
    static func fullPixels(count: Int, sources: [CompositeSource]) -> Data {
        guard let bottom = sources.first else { return Data(count: count * 4) }
        // Transparent results keep the bottom layer's RGB even when all contributing alphas are zero.
        var pixels = bottom.pixels
        let blocks = (count + 4095) / 4096
        let workers = min(8, ProcessInfo.processInfo.activeProcessorCount, blocks,
                          max(1, count * sources.count / 1_048_576))
        pixels.withUnsafeMutableBytes { buffer in
            let output = FullOutput(buffer: buffer)
            if workers <= 1 {
                output.blend(0..<count, sources: sources)
                return
            }
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                let first = worker * blocks / workers * 4096
                let end = min(count, (worker + 1) * blocks / workers * 4096)
                output.blend(first..<end, sources: sources)
            }
        }
        return pixels
    }

    static func pixels(width: Int, height: Int, sources: [CompositeSource]) -> Data {
        var output = Data(count: width * height * 4)
        guard let bottom = sources.first else { return output }
        var row = [SIMD4<Float>](repeating: .zero, count: width)
        output.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            row.withUnsafeMutableBufferPointer { row in
                for y in 0..<height {
                    let local = y * width
                    // Keep the bottom visible layer's RGB at zero alpha.
                    bottom.pixels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                        let start = (bottom.offset + y * bottom.stride) * 4
                        output.baseAddress!.advanced(by: local * 4).copyMemory(
                            from: bytes.baseAddress!.advanced(by: start), byteCount: width * 4
                        )
                    }
                    for x in row.indices { row[x] = .zero }
                    for source in sources {
                        source.pixels.withUnsafeBytes {
                            source.mode.composite($0, startingAt: source.offset + y * source.stride,
                                                  onto: row, opacity: source.opacity)
                        }
                    }
                    LayerBlendMode.storeComposite(UnsafeBufferPointer(row), in: output, startingAt: local)
                }
            }
        }
        return output
    }
}

/// Blend only dirty tiles while publishing one image for consistent interpolation at every zoom.
final class CanvasComposite {
    private let grid: RasterTileGrid
    private let colorSpace: CGColorSpace
    private let activeSource: Int?
    private var sources: [CompositeSource]
    private var dirty: Set<Int> = []
    private var missing: Set<Int> = []
    private var pixels: Data?
    private var image: CGImage?
    var renderedImage: CGImage? { dirty.isEmpty && missing.isEmpty ? image : nil }

    init?(stack: LayerStack) {
        let image = stack.activeLayer.image
        var sources: [CompositeSource] = []
        var activeSource: Int?
        for (index, layer) in stack.layers.enumerated() where layer.isVisible && layer.opacity > 0 {
            guard let pixels = layer.straightPixels, pixels.count == image.width * image.height * 4 else {
                return nil
            }
            if index == stack.active { activeSource = sources.count }
            sources.append(CompositeSource(pixels: pixels, stride: image.width, offset: 0,
                                           mode: layer.blendMode, opacity: layer.opacity))
        }
        self.sources = sources
        self.activeSource = activeSource
        grid = RasterTileGrid(width: image.width, height: image.height)
        colorSpace = stack.needsBlendComposite ? stack.workingColorSpace
            : (stack.layers.first { $0.isVisible && $0.opacity > 0 }?.workingColorSpace ?? stack.workingColorSpace)
    }

    /// A committed stroke has the same pixels as its last preview.
    func commitActivePixels(_ pixels: Data) {
        guard let activeSource else { return }
        sources[activeSource].pixels = pixels
    }

    func invalidate(_ region: CGRect) {
        guard activeSource != nil else { return }
        dirty.formUnion(grid.indices(in: region))
    }

    func render(stack: LayerStack, region: CGRect? = nil,
                activePixels: ((CGRect) -> Data?)? = nil) -> CGImage? {
        let canvasWidth = Int(grid.bounds.width), canvasHeight = Int(grid.bounds.height)
        let count = canvasWidth * canvasHeight
        if pixels == nil {
            if !stack.needsBlendComposite, let source = sources.first {
                pixels = source.pixels
                image = stack.layers.first { $0.isVisible && $0.opacity > 0 }?.image
            } else if let region, region.width * region.height < CGFloat(count) / 2 {
                pixels = Data(count: count * 4)
                missing = Set(grid.indices(in: grid.bounds))
            } else {
                pixels = RegionComposite.fullPixels(count: count, sources: sources)
            }
        } else if region == nil, activePixels == nil, !missing.isEmpty {
            // Fit needs the entire source for interpolation. Rebuild from committed sources in one pass.
            image = nil
            pixels = RegionComposite.fullPixels(count: count, sources: sources)
            missing.removeAll()
            dirty.removeAll()
        }
        let needed = if let region {
            grid.indices(in: region).filter { missing.contains($0) || dirty.contains($0) }
        } else {
            Array(missing.union(dirty))
        }
        if needed.isEmpty, let image { return image }
        // Release our image reference before mutation. Core Graphics may still retain a snapshot
        // for an in-flight draw, in which case Data preserves that snapshot via copy-on-write.
        image = nil
        if !needed.isEmpty {
            pixels?.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                for key in needed {
                    let rect = grid.rect(at: key)
                    let width = Int(rect.width)
                    let replacement = activePixels?(rect)
                    if sources.count == 1, sources[0].opacity == 255 {
                        PixelRegion.copy(replacement ?? sources[0].pixels,
                                         sourceWidth: replacement == nil ? canvasWidth : width,
                                         sourceOrigin: replacement == nil ? rect.origin : .zero,
                                         to: target, targetWidth: canvasWidth, targetOrigin: rect.origin,
                                         size: rect.size)
                        continue
                    }
                    var windows = sources.map { $0.window(at: rect.origin) }
                    if let activeSource, let replacement {
                        windows[activeSource].pixels = replacement
                        windows[activeSource].stride = width
                        windows[activeSource].offset = 0
                    }
                    let bytes = RegionComposite.pixels(width: width, height: Int(rect.height), sources: windows)
                    PixelRegion.copy(bytes, sourceWidth: width, sourceOrigin: .zero, to: target,
                                     targetWidth: canvasWidth, targetOrigin: rect.origin, size: rect.size)
                }
            }
            dirty.subtract(needed)
            missing.subtract(needed)
        }
        image = pixels.flatMap {
            BGRA8.image(from: $0, width: canvasWidth, height: canvasHeight, colorSpace: colorSpace)
        }
        return image
    }
}

struct RasterTileGrid {
    private static let tileSize = 128
    let bounds: CGRect
    private let columns: Int

    init(width: Int, height: Int) {
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        columns = (width + Self.tileSize - 1) / Self.tileSize
    }

    func index(column: Int, row: Int) -> Int {
        row / Self.tileSize * columns + column / Self.tileSize
    }

    func rect(at index: Int) -> CGRect {
        CGRect(x: index % columns * Self.tileSize, y: index / columns * Self.tileSize,
               width: Self.tileSize, height: Self.tileSize).intersection(bounds)
    }

    func indices(in region: CGRect) -> [Int] {
        let region = region.intersection(bounds)
        guard !region.isEmpty else { return [] }
        let size = CGFloat(Self.tileSize)
        let xs = Int(region.minX / size)..<Int(ceil(region.maxX / size))
        let ys = Int(region.minY / size)..<Int(ceil(region.maxY / size))
        return ys.flatMap { y in xs.map { x in y * columns + x } }
    }
}
