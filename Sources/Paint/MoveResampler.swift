import CoreGraphics
import Foundation

enum MoveResampler {
    enum Mode: String, CaseIterable {
        case bicubic = "Bicubic"
        case antialiasedNearest = "Nearest Neighbor (Antialiased)"
    }

    static func sample(_ source: Data, stride: Int, start: Int, selection: CGRect,
                       transform: CGAffineTransform, region: CGRect, canvasHeight: Int, mode: Mode) -> Data? {
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
        let inverse = transform.inverted()
        let height = CGFloat(canvasHeight)
        // Convert both ends of the transform to top-left pixel coordinates.
        let toSource = CGAffineTransform(a: inverse.a, b: -inverse.b, c: -inverse.c, d: inverse.d,
                                         tx: inverse.tx + inverse.c * height - selection.minX,
                                         ty: height * (1 - inverse.d) - inverse.ty - selection.minY)
        let sourceRect = CGRect(x: selection.minX, y: height - selection.maxY,
                                width: selection.width, height: selection.height)
        let width = Int(region.width), rows = Int(region.height)
        let coverage: Coverage
        if transform.b == 0 && transform.c == 0 {
            let rect = sourceRect.applying(transform)
            coverage = .rectangle(
                Self.coverages(from: rect.minX, to: rect.maxX, origin: region.minX, count: width),
                Self.coverages(from: height - rect.maxY, to: height - rect.minY, origin: region.minY, count: rows)
            )
        } else {
            guard let outline = SelectionOutline(rect: sourceRect)?.transformed(by: transform),
                  let mask = outline.mask(in: region, imageHeight: canvasHeight, antialiased: true) else { return nil }
            coverage = .mask(mask, width: width)
        }
        let texture = Texture(width: Int(selection.width), height: Int(selection.height), stride: stride, start: start)
        let transitionX = Float(min(1, hypot(toSource.a, toSource.c)))
        let transitionY = Float(min(1, hypot(toSource.b, toSource.d)))
        var result = Data(count: width * rows * 4)
        result.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            source.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for y in 0..<rows {
                    for x in 0..<width {
                        let mask = coverage[x, y]
                        guard mask > 0 else { continue }
                        let p = CGPoint(x: region.minX + CGFloat(x) + 0.5,
                                        y: region.minY + CGFloat(y) + 0.5).applying(toSource)
                        let sx = Float(p.x - 0.5), sy = Float(p.y - 0.5)
                        let value: SIMD4<Float>
                        switch mode {
                        case .bicubic:
                            value = texture.bicubic(source, x: sx, y: sy)
                        case .antialiasedNearest:
                            value = texture.antialiasedNearest(source, x: sx, y: sy,
                                                              transitionX: transitionX, transitionY: transitionY)
                        }
                        let alpha = byte(value.w * mask)
                        guard alpha > 0 else { continue }
                        let offset = (y * width + x) * 4
                        let straight = value / value.w
                        target[offset] = byte(straight.x)
                        target[offset + 1] = byte(straight.y)
                        target[offset + 2] = byte(straight.z)
                        target[offset + 3] = alpha
                    }
                }
            }
        }
        return result
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8((min(1, max(0, value)) * 255).rounded(.toNearestOrEven))
    }

    private static func coverages(from lower: CGFloat, to upper: CGFloat, origin: CGFloat, count: Int) -> [Float] {
        (0..<count).map { index in
            let edge = origin + CGFloat(index)
            return Float(max(0, min(upper, edge + 1) - max(lower, edge)))
        }
    }

    private enum Coverage {
        case rectangle([Float], [Float])
        case mask(Data, width: Int)

        subscript(x: Int, y: Int) -> Float {
            switch self {
            case .rectangle(let horizontal, let vertical): return horizontal[x] * vertical[y]
            case .mask(let data, let width): return Float(data[y * width + x]) / 255
            }
        }
    }

    private struct Texture {
        let width: Int
        let height: Int
        let stride: Int
        let start: Int

        func bicubic(_ source: UnsafeRawBufferPointer, x: Float, y: Float) -> SIMD4<Float> {
            let ix = Int(floor(x)), iy = Int(floor(y))
            let dx = x - Float(ix), dy = y - Float(iy)
            var value = SIMD4<Float>.zero
            for row in -1...2 {
                let wy = ImageResampler.bicubicWeight(abs(Float(row) - dy))
                var line = SIMD4<Float>.zero
                for column in -1...2 {
                    let wx = ImageResampler.bicubicWeight(abs(Float(column) - dx))
                    line += pixel(source, x: ix + column, y: iy + row) * wx
                }
                value += line * wy
            }
            return value
        }

        func antialiasedNearest(_ source: UnsafeRawBufferPointer, x: Float, y: Float,
                               transitionX: Float, transitionY: Float) -> SIMD4<Float> {
            let ix = Int(floor(x)), iy = Int(floor(y))
            // Blend across the nearest-neighbor boundary over one destination pixel.
            let wx = min(1, max(0, (x - Float(ix) - 0.5) / transitionX + 0.5))
            let wy = min(1, max(0, (y - Float(iy) - 0.5) / transitionY + 0.5))
            let top = pixel(source, x: ix, y: iy) * (1 - wx) + pixel(source, x: ix + 1, y: iy) * wx
            let bottom = pixel(source, x: ix, y: iy + 1) * (1 - wx) + pixel(source, x: ix + 1, y: iy + 1) * wx
            return top * (1 - wy) + bottom * wy
        }

        private func pixel(_ source: UnsafeRawBufferPointer, x: Int, y: Int) -> SIMD4<Float> {
            // The separate coverage mask clips the transformed selection. Extend its edge colors
            // here so the resampling kernel does not make partially covered edges transparent twice.
            let offset = start + min(height - 1, max(0, y)) * stride + min(width - 1, max(0, x)) * 4
            let alpha = Float(source[offset + 3]) / 255
            return SIMD4(Float(source[offset]) / 255 * alpha,
                         Float(source[offset + 1]) / 255 * alpha,
                         Float(source[offset + 2]) / 255 * alpha, alpha)
        }
    }
}
