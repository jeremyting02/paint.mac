import AppKit
import Testing
@testable import Paint

struct QuantizationEffectTests {
    @Test func posterizeBucketsRespectIndependentLevelsAndCanPreserveAlpha() throws {
        let bytes: [UInt8] = [63, 64, 127, 63, 64, 127, 128, 64, 191, 192, 255, 192]
        let source = try input(bytes, width: 3, height: 1)
        let filter = try #require(RasterFilter.adjustments.first { $0.title == "Posterize" })
        let rgba = try #require(source.render(filter, values: [4, 4, 4, 4])?.straightPixels)
        #expect(rgba == Data([0, 85, 85, 0, 85, 85, 170, 85, 170, 255, 255, 255]))
        let unlinked = try #require(source.render(filter, values: [2, 4, 8, 256])?.straightPixels)
        #expect(unlinked == Data([36, 85, 0, 63, 73, 85, 255, 64, 182, 255, 255, 192]))
    }

    @MainActor @Test func posterizePanelLinksRGBAndLeavesAlphaIndependent() throws {
        _ = NSApplication.shared
        let source = try input([1, 2, 3, 4], width: 1, height: 1)
        let filter = try #require(RasterFilter.adjustments.first { $0.title == "Posterize" })
        let panel = RasterFilterPanel(filter: filter, input: source)
        defer { panel.stopPreview() }
        let views = descendants(of: try #require(panel.contentView))
        let sliders = views.compactMap { $0 as? NSSlider }.sorted { $0.tag < $1.tag }
        try #require(sliders.count == 4)
        let link = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Linked" })

        sliders[0].doubleValue = 4
        NSApplication.shared.sendAction(try #require(sliders[0].action), to: sliders[0].target, from: sliders[0])
        #expect(panel.values == [4, 4, 4, 256])

        link.state = .off
        NSApplication.shared.sendAction(try #require(link.action), to: link.target, from: link)
        sliders[1].doubleValue = 8
        NSApplication.shared.sendAction(try #require(sliders[1].action), to: sliders[1].target, from: sliders[1])
        #expect(panel.values == [4, 8, 4, 256])
    }

    @Test func multisamplePixelateAveragesInLinearLight() throws {
        let row: [UInt8] = [0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255]
        let source = try input(row + row + row + row, width: 4, height: 4)
        let filter = PixelateEffect.filter
        let result = try #require(source.render(filter, values: [4, 2, 2])?.straightPixels)
        let expected: [UInt8] = [188, 188, 188, 255]
        #expect(result == Data(Array(repeating: expected, count: 16).flatMap { $0 }))
    }

    @Test func multisamplePixelateUsesTheTaggedDocumentTransferCurve() throws {
        let row: [UInt8] = [0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255]
        let source = Data(row + row + row + row)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.linearSRGB))
        let image = try #require(BGRA8.image(from: source, width: 4, height: 4, colorSpace: colorSpace))
        let layer = PaintLayer(name: "Linear RGB", image: image, pdnPixels: source)
        let input = try #require(RasterFilter.Input(layer: layer, selection: nil))
        let result = try #require(input.render(PixelateEffect.filter, values: [4, 2, 2]))
        let expected: [UInt8] = [128, 128, 128, 255]
        #expect(result.straightPixels == Data(Array(repeating: expected, count: 16).flatMap { $0 }))
        #expect(result.image.colorSpace == colorSpace)
    }

    @Test func nearestPixelateKeepsFixedCellBoundariesAtPartialEdges() throws {
        let levels: [UInt8] = [10, 20, 30, 40, 50]
        let pixels: [UInt8] = levels.flatMap { [$0, 0, 0, 255] }
        let source = try input(pixels, width: 5, height: 1)
        let filter = PixelateEffect.filter
        let result = try #require(source.render(filter, values: [3, 5, 2])?.straightPixels)
        #expect(result == Data([20, 0, 0, 255, 20, 0, 0, 255, 20, 0, 0, 255,
                                 50, 0, 0, 255, 50, 0, 0, 255]))
        #expect(source.render(filter, values: [1, 2, 2])?.straightPixels == Data(pixels))
    }

    @Test func squareBlurMirrorsEdgePixelsAndWeightsColorByAlpha() throws {
        let bytes: [UInt8] = [0, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255]
        let source = try input(bytes, width: 3, height: 1)
        let filter = SquareBlurEffect.filter
        let pixels = try #require(source.render(filter, values: [1, 0])?.straightPixels)
        #expect(pixels == Data([0, 0, 255, 170, 188, 188, 255, 170, 255, 255, 255, 170]))
        #expect(source.render(filter, values: [0, 0])?.straightPixels == Data(bytes))
    }

    private func input(_ bytes: [UInt8], width: Int, height: Int) throws -> RasterFilter.Input {
        let pixels = Data(bytes)
        let image = try #require(BGRA8.image(from: pixels, width: width, height: height))
        let layer = PaintLayer(name: "Test", image: image, pdnPixels: pixels)
        return try #require(RasterFilter.Input(layer: layer, selection: nil))
    }

    @MainActor private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
