import CoreGraphics
import Foundation

final class MoveTilePreview {
    private struct Source {
        // The active layer's bytes come from the transformed tile.
        let pixels: Data?
        let mode: LayerBlendMode
        let opacity: UInt8
    }

    private struct Tile: Hashable {
        static let size = 128
        let x: Int
        let y: Int

        var bounds: CGRect {
            CGRect(x: x * Self.size, y: y * Self.size, width: Self.size, height: Self.size)
        }
    }

    private struct Frame: Equatable {
        let transform: CGAffineTransform
        let copy: Bool
        let sampling: MoveResampler.Mode
    }

    private struct TileRequest {
        let tile: Tile
        let core: CGRect
        let padded: CGRect
        let movesPixels: Bool
        let cached: CGImage?
    }

    // Only published results are shared. Each worker renders its own tile buffers.
    private final class TileResults: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [CGImage?]

        init(count: Int) { images = Array(repeating: nil, count: count) }

        func set(_ image: CGImage?, at index: Int) {
            lock.lock()
            images[index] = image
            lock.unlock()
        }

        func take() -> [CGImage?] {
            lock.lock()
            defer { lock.unlock() }
            return images
        }
    }

    private let pixels: SelectedPixelsTransform
    private let sources: [Source]
    private let bounds: CGRect
    private let colorSpace: CGColorSpace
    private let stack: LayerStack
    private let residentStack: MetalMovePreview?
    private lazy var metal = residentStack.flatMap { MetalMovePreview(reusing: $0, stack: stack, pixels: pixels) }
        ?? MetalMovePreview(stack: stack, pixels: pixels)
    private(set) var metalDraws = 0
    private var frame: Frame?
    private var frameTiles: [Tile: CGImage] = [:]
    private var clearedTiles: [Tile: CGImage] = [:]

    init?(stack: LayerStack, pixels: SelectedPixelsTransform, residentStack: MetalMovePreview? = nil) {
        let image = stack.activeLayer.image
        let byteCount = image.width * image.height * 4
        var sources: [Source] = []
        for (index, layer) in stack.layers.enumerated() where layer.isVisible && layer.opacity > 0 {
            let bytes: Data?
            if index == stack.active {
                bytes = nil
            } else {
                guard let source = layer.straightPixels, source.count == byteCount else { return nil }
                bytes = source
            }
            sources.append(Source(pixels: bytes, mode: layer.blendMode, opacity: layer.opacity))
        }
        self.pixels = pixels
        self.sources = sources
        self.stack = stack
        self.residentStack = residentStack
        bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        colorSpace = stack.needsBlendComposite ? stack.workingColorSpace : stack.activeLayer.workingColorSpace
    }

    func metalFrame(in visible: CGRect, by transform: CGAffineTransform, copy: Bool,
                    sampling: MoveResampler.Mode) -> (region: CGRect, image: CGImage)? {
        guard let preview = metalRenderer(in: visible, by: transform)?.render(in: visible, by: transform,
                                                                             copy: copy, sampling: sampling)
        else { return nil }
        metalDraws += 1
        return preview
    }

    func metalRenderer(in visible: CGRect, by transform: CGAffineTransform) -> MetalMovePreview? {
        let destination = pixels.destinationRegion(by: transform).intersection(visible)
        guard !destination.isEmpty, destination.width * destination.height >= 65_536 else { return nil }
        return metal
    }

    func tiles(in visible: CGRect, by transform: CGAffineTransform, copy: Bool, sampling: MoveResampler.Mode)
        -> [(core: CGRect, padded: CGRect, image: CGImage)] {
        let visible = visible.intersection(bounds)
        guard !visible.isEmpty else { return [] }
        let next = Frame(transform: transform, copy: copy, sampling: sampling)
        if next != frame {
            frameTiles.removeAll(keepingCapacity: true)
            frame = next
        }
        let destination = pixels.destinationRegion(by: transform)
        let cleared = pixels.clearedRegion(by: transform, copy: copy)
        let destinationEdge = destination.insetBy(dx: -1, dy: -1)
        let clearedEdge = cleared.insetBy(dx: -1, dy: -1)
        let size = CGFloat(Tile.size)
        let columns = Int(visible.minX / size)..<Int(ceil(visible.maxX / size))
        let rows = Int(visible.minY / size)..<Int(ceil(visible.maxY / size))
        var requests: [TileRequest] = []
        for y in rows {
            for x in columns {
                let tile = Tile(x: x, y: y)
                let movedPart = tile.bounds.intersection(destinationEdge)
                let clearedPart = tile.bounds.intersection(clearedEdge)
                let core = movedPart.union(clearedPart).intersection(bounds)
                guard !core.isEmpty, core.intersects(visible) else { continue }
                // Keep neighboring pixels available for scaling at the tile boundary.
                let padded = core.insetBy(dx: -2, dy: -2).intersection(bounds)
                let movesPixels = padded.intersects(destination)
                requests.append(TileRequest(tile: tile, core: core, padded: padded, movesPixels: movesPixels,
                                            cached: movesPixels ? frameTiles[tile] : clearedTiles[tile]))
            }
        }
        let missing = requests.compactMap { $0.cached == nil ? $0.padded : nil }
        var rendered = render(missing, frame: next).makeIterator()
        return requests.compactMap { request in
            if let cached = request.cached { return (request.core, request.padded, cached) }
            guard let image = rendered.next() ?? nil else { return nil }
            if request.movesPixels {
                frameTiles[request.tile] = image
            } else if clearedTiles.count < 64 {
                clearedTiles[request.tile] = image
            }
            return (request.core, request.padded, image)
        }
    }

    private func render(_ regions: [CGRect], frame: Frame) -> [CGImage?] {
        // Avoid dispatch overhead for small updates. Bound workers for large zoomed-out previews.
        let workers = min(8, ProcessInfo.processInfo.activeProcessorCount, regions.count / 4)
        guard workers > 1 else { return regions.map { render($0, frame: frame) } }
        let results = TileResults(count: regions.count)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for index in stride(from: worker, to: regions.count, by: workers) {
                results.set(render(regions[index], frame: frame), at: index)
            }
        }
        return results.take()
    }

    private func render(_ region: CGRect, frame: Frame) -> CGImage? {
        guard let bytes = compositedPixels(in: region, by: frame.transform, copy: frame.copy,
                                          sampling: frame.sampling) else { return nil }
        return BGRA8.image(from: bytes, width: Int(region.width), height: Int(region.height), colorSpace: colorSpace)
    }

    func compositedPixels(in region: CGRect, by transform: CGAffineTransform, copy: Bool,
                          sampling: MoveResampler.Mode) -> Data? {
        guard let active = pixels.renderedPixels(in: region, by: transform, copy: copy,
                                                 sampling: sampling) else { return nil }
        if sources.count == 1, let only = sources.first, only.pixels == nil, only.opacity == 255 {
            return active
        }
        let width = Int(region.width), stride = Int(bounds.width)
        let windows = sources.map { source in
            if let pixels = source.pixels {
                return CompositeSource(pixels: pixels, stride: stride, offset: 0,
                                       mode: source.mode, opacity: source.opacity).window(at: region.origin)
            }
            return CompositeSource(pixels: active, stride: width, offset: 0,
                                   mode: source.mode, opacity: source.opacity)
        }
        return RegionComposite.pixels(width: width, height: Int(region.height), sources: windows)
    }
}
