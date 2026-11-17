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

    private let pixels: SelectedPixelsTransform
    private let sources: [Source]
    private let bounds: CGRect
    private let colorSpace: CGColorSpace
    private var frame: Frame?
    private var frameTiles: [Tile: CGImage] = [:]
    private var clearedTiles: [Tile: CGImage] = [:]

    init?(stack: LayerStack, pixels: SelectedPixelsTransform) {
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
        bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        colorSpace = stack.needsBlendComposite ? stack.workingColorSpace : stack.activeLayer.workingColorSpace
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
        var tiles: [(CGRect, CGRect, CGImage)] = []
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
                let cached = movesPixels ? frameTiles[tile] : clearedTiles[tile]
                guard let image = cached ?? render(padded, frame: next) else { continue }
                if movesPixels {
                    frameTiles[tile] = image
                } else if clearedTiles.count < 64 {
                    clearedTiles[tile] = image
                }
                tiles.append((core, padded, image))
            }
        }
        return tiles
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
        let width = Int(region.width)
        let canvasWidth = Int(bounds.width)
        let firstPixel = Int(region.minY) * canvasWidth + Int(region.minX)
        var output = Data(count: active.count)
        var row = [SIMD4<Float>](repeating: .zero, count: width)
        output.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            row.withUnsafeMutableBufferPointer { row in
                for y in 0..<Int(region.height) {
                    let local = y * width
                    let canvas = firstPixel + y * canvasWidth
                    for x in row.indices { row[x] = .zero }
                    for (index, source) in sources.enumerated() {
                        let start = source.pixels == nil ? local : canvas
                        (source.pixels ?? active).withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                            // Preserve the bottom visible layer's RGB at zero alpha, as in blendComposite().
                            if index == 0 {
                                output.baseAddress!.advanced(by: local * 4).copyMemory(
                                    from: bytes.baseAddress!.advanced(by: start * 4), byteCount: width * 4
                                )
                            }
                            source.mode.composite(bytes, startingAt: start, onto: row, opacity: source.opacity)
                        }
                    }
                    LayerBlendMode.storeComposite(UnsafeBufferPointer(row), in: output, startingAt: local)
                }
            }
        }
        return output
    }
}
