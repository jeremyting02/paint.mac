import Metal
import Testing
@testable import Paint

struct MetalRasterEffectsTests {
    private let width = 320, height = 224

    private var pixels: Data {
        Data((0..<(width * height * 4)).map { UInt8(truncatingIfNeeded: $0 * 137 + $0 / 13) })
    }

    private func input(_ pixels: Data) throws -> RasterFilter.Input {
        let image = try #require(BGRA8.image(from: pixels, width: width, height: height))
        return try #require(RasterFilter.Input(layer: PaintLayer(name: "Synthetic", image: image, pdnPixels: pixels),
                                               selection: nil))
    }

    @Test func histogramCountsMaskedAndTransparentPixelsExactly() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let pixels = pixels
        let mask = Data((0..<(width * height)).map { $0 % 7 == 0 ? UInt8(0) : 128 })
        for mask in [nil, mask] {
            let expected = MetalRasterEffects.$enabled.withValue(false) { ChannelHistogram(pixels: pixels, mask: mask).bins }
            let accelerated = try #require(MetalRasterEffects.histogram(pixels, mask: mask, isCancelled: { false }))
            #expect(accelerated == expected)
            #expect(ChannelHistogram(pixels: pixels, mask: mask).bins == expected)
        }
    }

    @Test func tonalCurvesAndDitherPreserveCPUBytes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let pixels = pixels
        let input = try input(pixels)
        var levels = LevelSettings()
        levels.set(.gamma, to: 1.37, channels: [.green, .blue])
        var curves = CurveSettings()
        curves.luminosity.setPoint(.init(input: 106, output: 178))
        var rgb = curves
        rgb.mode = .rgb
        rgb.rgb[0].setPoint(.init(input: 103, output: 171))
        let ordered = try #require(RasterFilter.renderEffects.first { $0.title == "Ordered Dither" })
        let posterize = try #require(RasterFilter.adjustments.first { $0.title == "Posterize" })
        let filters: [(RasterFilter, [Double])] = [
            (levels.filter(), []), (curves.filter(), []), (rgb.filter(), []), (RasterFilter.autoLevel, []),
            (posterize, [3, 16, 23, 7]), (ordered, [8]),
            (try #require(RasterFilter.distortionEffects.first { $0.title == "Outline" }), [3, 50, 8])
        ] + ["Black and White", "Brightness / Contrast", "Invert Alpha", "Invert Colors"].map { title in
            (RasterFilter.adjustments.first { $0.title == title }!, title == "Brightness / Contrast" ? [23, 19] : [])
        }
        try #require(MetalRasterEffects.tables(Array(levels.tables.reversed()), to: pixels, isCancelled: { false }) != nil)
        try #require(MetalRasterEffects.luminosity(curves.luminosity.table, to: pixels, isCancelled: { false }) != nil)
        try #require(MetalRasterEffects.orderedDither(pixels, width: width, levels: 7, isCancelled: { false }) != nil)
        for (filter, values) in filters {
            let expected = try #require(MetalRasterEffects.$enabled.withValue(false) {
                input.render(filter, values: values)?.straightPixels
            })
            let accelerated = try #require(input.render(filter, values: values)?.straightPixels)
            #expect(accelerated == expected, "\(filter.title)")
        }
    }

    @Test func effectPreviewsStayCloseWhileCommittedOutputUsesCanonicalCPU() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let pixels = pixels
        let input = try input(pixels)
        let filters = [SquareBlurEffect.filter, PixelateEffect.filter] + RasterFilter.renderEffects.filter { $0.title != "Ordered Dither" }
            + RasterFilter.distortionEffects.filter { $0.title != "Outline" } + RasterFilter.blurEffects
        for filter in filters {
            let values: [Double]
            switch filter.title {
            case "Square Blur": values = [16, 0.32]
            case "Pixelate": values = [4, 2, 2]
            default: values = filter.controls.map(\.initial)
            }
            let committed = try #require(input.render(filter, values: values)?.straightPixels)
            let expected = try #require(MetalRasterEffects.$enabled.withValue(false) {
                input.render(filter, values: values)?.straightPixels
            })
            let preview = try #require(input.render(filter, values: values, preview: true)?.straightPixels)
            #expect(filter.hasPreviewRenderer, "\(filter.title)")
            #expect(committed == expected, "\(filter.title)")
            let differences = zip(preview, expected).filter { abs(Int($0) - Int($1)) > 1 }.count
            #expect(differences < pixels.count / 100, "\(filter.title)")
        }
    }
}
