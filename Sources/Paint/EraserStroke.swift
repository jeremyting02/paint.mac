import CoreGraphics
import Foundation

final class EraserStroke {
    let coverage: CGContext
    private let layer: PaintLayer
    private let original: Data
    private let opacity: Int
    private let radius: CGFloat
    private var pixels: Data
    private var damage = CGRect.null
    private var cached: PaintLayer?

    init?(layer: PaintLayer, opacity: UInt8, diameter: CGFloat) {
        let width = layer.image.width, height = layer.image.height
        guard opacity != 0, let original = layer.straightPixels,
              let coverage = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        self.coverage = coverage
        self.layer = layer
        self.original = original
        pixels = original
        self.opacity = Int(opacity)
        radius = diameter / 2
        coverage.clear(CGRect(x: 0, y: 0, width: width, height: height))
    }

    func changed(from start: CGPoint, to end: CGPoint) {
        let margin = radius + 1
        let stroke = CGRect(x: min(start.x, end.x) - margin, y: min(start.y, end.y) - margin,
                            width: abs(end.x - start.x) + margin * 2, height: abs(end.y - start.y) + margin * 2)
        damage = damage.union(stroke.integral.intersection(CGRect(x: 0, y: 0, width: coverage.width, height: coverage.height)))
    }

    var preview: PaintLayer? {
        guard !damage.isEmpty, let mask = coverage.data?.assumingMemoryBound(to: UInt8.self) else { return cached }
        let area = damage
        damage = .null
        let source = original
        let width = coverage.width, height = coverage.height, stride = coverage.bytesPerRow
        let strength = opacity
        let changed = pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            var changed = false
            let rows = (height - Int(area.maxY))..<(height - Int(area.minY))
            for row in rows {
                for column in Int(area.minX)..<Int(area.maxX) {
                    let covered = Int(mask[row * stride + column])
                    guard covered != 0 else { continue }
                    let index = (row * width + column) * 4
                    let erased = strength * covered
                    let remaining = UInt8((Int(source[index + 3]) * (65_025 - erased) + 32_512) / 65_025)
                    if remaining == 0 && (source[index + 3] != 0 || erased == 65_025) {
                        if bytes.loadUnaligned(fromByteOffset: index, as: UInt32.self) != 0 {
                            bytes.storeBytes(of: UInt32(0), toByteOffset: index, as: UInt32.self)
                            changed = true
                        }
                    } else if bytes[index + 3] != remaining {
                        // Partially erased pixels retain their original unassociated RGB bytes.
                        bytes[index + 3] = remaining
                        changed = true
                    }
                }
            }
            return changed
        }
        if changed { cached = layer.withPixels(pixels) }
        return cached
    }
}
