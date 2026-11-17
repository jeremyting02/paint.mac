import CoreGraphics
import Foundation

struct RasterHistoryPatch {
    private struct Tile {
        let region: CGRect
        let bytes: Data
    }

    private let layerIndex: Int
    private let activeIndex: Int
    private let width: Int
    private let height: Int
    private let tiles: [Tile]

    init(layerIndex: Int, activeIndex: Int, width: Int, height: Int, regions: [CGRect], pixels: Data) {
        self.layerIndex = layerIndex
        self.activeIndex = activeIndex
        self.width = width
        self.height = height
        tiles = regions.map { Tile(region: $0, bytes: PixelRegion.read(pixels, width: width, region: $0)) }
    }

    func applying(to stack: LayerStack) -> (stack: LayerStack, inverse: Self)? {
        guard stack.layers.indices.contains(layerIndex), stack.layers.indices.contains(activeIndex) else { return nil }
        let layer = stack.layers[layerIndex]
        guard layer.image.width == width, layer.image.height == height, var pixels = layer.straightPixels,
              pixels.count == width * height * 4 else { return nil }
        let inverse = Self(layerIndex: layerIndex, activeIndex: stack.active, width: width, height: height,
                           regions: tiles.map(\.region), pixels: pixels)
        pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            for tile in tiles {
                PixelRegion.copy(tile.bytes, sourceWidth: Int(tile.region.width), sourceOrigin: .zero,
                                 to: target, targetWidth: width, targetOrigin: tile.region.origin,
                                 size: tile.region.size)
            }
        }
        guard let restored = layer.withPixels(pixels) else { return nil }
        var result = stack
        result.active = activeIndex
        result.layers[layerIndex] = restored
        return (result, inverse)
    }
}
