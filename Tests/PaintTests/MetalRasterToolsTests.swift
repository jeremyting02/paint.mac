import AppKit
import Metal
import Testing
@testable import Paint

struct MetalRasterToolsTests {
    private let width = 544
    private let height = 336

    private func pixels(_ seed: UInt32) -> Data {
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: UInt32.self)
            for index in output.indices { output[index] = UInt32(index) &* seed }
        }
        return bytes
    }

    @Test func fillsClearsAndBlendsAreByteIdentical() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let source = pixels(2_654_435_761)
        let overlay = pixels(1_610_612_741)
        let image = try #require(BGRA8.image(from: source, width: width, height: height))
        let layer = PaintLayer(name: "Synthetic", image: image, pdnPixels: source)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let rect = bounds.insetBy(dx: 8, dy: 12)
        let outline = try #require(SelectionOutline(path: CGPath(ellipseIn: rect, transform: nil)))
        let mask = try #require(outline.mask(in: rect, imageHeight: height))
        let color = SIMD4<UInt8>(73, 186, 21, 127)
        let expected = try #require(layer.filling(outline, blue: color.x, green: color.y, red: color.z,
                                                  alpha: color.w, allowsMetal: false)?.straightPixels)
        let filled = try #require(MetalRasterTools.fill(source, width: width, rect: rect, mask: mask, color: color))
        #expect(filled == expected)
        let cleared = try #require(MetalRasterTools.clear(source, width: width, rect: rect, mask: mask))
        #expect(cleared == layer.clearing(rect, mask: mask, from: source, allowsMetal: false))
        for mode in LayerBlendMode.allCases {
            var reference = source
            mode.composite(overlay, onto: &reference, opacity: 255)
            let composited = try #require(MetalRasterTools.composite(overlay, on: source, width: width,
                                                                     rect: bounds, mode: mode))
            #expect(composited == reference)
        }
    }

    @Test func globalColorMatchPreservesTransparentRGBAndSelectionMask() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let source = pixels(2_654_435_761)
        var mask = Data(repeating: 255, count: width * height)
        for index in stride(from: 1, to: mask.count, by: 76) { mask[index] = 0 }
        let seed = 31, tolerance = 63
        let maximum = tolerance * 255 * 255 / 100
        let limit = 4 * maximum * maximum
        let actual = try #require(MetalRasterTools.floodMask(pixels: source, seedIndex: seed, limit: limit, within: mask))
        let expected = source.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func comparisonColor(_ index: Int) -> SIMD4<Int> {
                let offset = index * 4, alpha = Int(bytes[offset + 3])
                return SIMD4(Int(bytes[offset]) * alpha, Int(bytes[offset + 1]) * alpha,
                             Int(bytes[offset + 2]) * alpha, 255 * alpha)
            }
            let comparison = comparisonColor(seed)
            return Data((0..<(width * height)).map { index in
                let delta = comparisonColor(index) &- comparison
                let sum = (0..<4).reduce(0) { $0 + delta[$1] * delta[$1] }
                return mask[index] != 0 && sum <= limit ? UInt8(1) : 0
            })
        }
        #expect(actual == expected)
    }

    @Test(arguments: [false, true])
    func largeBrushesPreservePreviewBytesAndDirtyBounds(antialiased: Bool) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let source = pixels(2_654_435_761)
        let image = try #require(BGRA8.image(from: source, width: width, height: height))
        let layer = PaintLayer(name: "Synthetic", image: image, pdnPixels: source)
        let first = DrawingColor(.red), second = DrawingColor(.cyan)
        var options = BrushOptions()
        options.antialiased = antialiased
        options.smoothed = false
        options.pattern = .diagonalCross
        options.blend = .overwrite
        let operations: [RasterDrawing.Operation] = [
            .paint(primary: first, secondary: second), .erase(opacity: 201),
            .clone(source: source, offset: CGPoint(x: -45, y: 27), opacity: 121),
            .recolor(from: first, to: second, tolerance: 100)
        ]
        for operation in operations {
            let cpu = try #require(RasterDrawing(layer: layer, operation: operation, diameter: 513,
                                                 selection: nil, options: options, allowsMetal: false))
            let metal = try #require(RasterDrawing(layer: layer, operation: operation, diameter: 513,
                                                   selection: nil, options: options))
            for (point, pressure) in [(CGPoint(x: 156.7, y: 72.1), CGFloat(0.81)),
                                      (CGPoint(x: 390.8, y: 270.1), CGFloat(0.123))] {
                cpu.append(point, pressure: pressure)
                metal.append(point, pressure: pressure)
                #expect(cpu.takeDirtyBounds() == metal.takeDirtyBounds())
            }
            cpu.finish()
            metal.finish()
            #expect(metal.metalStamps > 0)
            let cpuPixels = try #require(cpu.preview?.straightPixels)
            #expect(metal.preview?.straightPixels == cpuPixels)
        }
    }
}
