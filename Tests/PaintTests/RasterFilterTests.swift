import AppKit
import Testing
@testable import Paint

struct RasterFilterTests {
    private func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual == expected, Comment(rawValue: name), sourceLocation: sourceLocation)
    }

    private func makeLayer(_ bytes: [UInt8], width: Int) throws -> PaintLayer {
        let pixels = Data(bytes)
        let image = try #require(BGRA8.image(from: pixels, width: width, height: bytes.count / (4 * width)))
        return PaintLayer(name: "Test", image: image, pdnPixels: pixels)
    }

    @Test func testPointAdjustmentsKeepStraightAlpha() throws {
        let layer = try makeLayer([10, 20, 30, 40, 11, 22, 33, 0], width: 2)
        let input = try #require(RasterFilter.Input(layer: layer, selection: nil))
        let invert = try #require(RasterFilter.adjustments.first { $0.title == "Invert Colors" })
        let invertAlpha = try #require(RasterFilter.adjustments.first { $0.title == "Invert Alpha" })
        equal(input.render(invert, values: [])?.pdnPixels, Data([245, 235, 225, 40, 244, 233, 222, 0]))
        equal(input.render(invertAlpha, values: [])?.pdnPixels, Data([10, 20, 30, 215, 11, 22, 33, 255]))
        equal(input.layer.pdnPixels, layer.pdnPixels)
    }

    @Test func testFilterIsRestrictedToSelectionAndRepeatedPreviewsUseOriginal() throws {
        let layer = try makeLayer([10, 20, 30, 255, 10, 20, 30, 255,
                                   10, 20, 30, 255, 10, 20, 30, 255], width: 2)
        let outline = try #require(SelectionOutline(rect: CGRect(x: 1, y: 1, width: 1, height: 1)))
        let input = try #require(RasterFilter.Input(layer: layer, selection: outline))
        let brightness = try #require(RasterFilter.adjustments.first { $0.title == "Brightness / Contrast" })
        let preview = try #require(input.render(brightness, values: [100, 0]))
        equal(preview.pdnPixels, Data([10, 20, 30, 255, 255, 255, 255, 255,
                                               10, 20, 30, 255, 10, 20, 30, 255]))
        let reset = try #require(input.render(brightness, values: [0, 0]))
        #expect(reset.image === layer.image)
    }

    @Test func testEveryBuiltInFilterRendersAtDefaultsAndKeepsExtent() throws {
        #expect(Set(RasterFilter.adjustments.map(\.title)).count == 13)
        let byCategory = Dictionary(grouping: RasterFilter.effects) { $0.category ?? "" }
        #expect(byCategory.mapValues { Set($0.map(\.title)).count } == [
            "Artistic": 7, "Blurs": 10, "Color": 2, "Distort": 11, "Noise": 2,
            "Object": 1, "Photo": 6, "Render": 4, "Stylize": 5
        ])
        var bytes: [UInt8] = []
        for pixel in 0..<64 {
            bytes += [UInt8(pixel * 3), UInt8(255 - pixel * 4), UInt8(pixel), 255]
        }
        let layer = try makeLayer(bytes, width: 8)
        let input = try #require(RasterFilter.Input(layer: layer, selection: nil))
        for filter in RasterFilter.adjustments + RasterFilter.effects {
            guard let result = input.render(filter, values: filter.controls.map(\.initial)) else {
                Issue.record("Could not render \(filter.title)")
                continue
            }
            equal(result.image.width, 8, filter.title)
            equal(result.image.height, 8, filter.title)
            equal(result.pdnPixels?.count, bytes.count, filter.title)
        }
    }

    @Test func quantizeHonorsPaletteSizeAndPreservesTransparency() throws {
        let bytes: [UInt8] = [0, 5, 10, 255, 246, 250, 255, 240, 1, 20, 15, 120, 6, 7, 8, 0]
        let layer = try makeLayer(bytes, width: 4)
        let input = try #require(RasterFilter.Input(layer: layer, selection: nil))
        let filter = try #require(RasterFilter.effects.first { $0.title == "Quantize / Dither" })
        let pixels = try #require(input.render(filter, values: [2, 0])?.pdnPixels)
        let colors = Set([Data(pixels[0..<3]), Data(pixels[4..<7]), Data(pixels[8..<11])])
        #expect(colors.count == 2)
        #expect([pixels[3], pixels[7], pixels[11]] == [255, 240, 120])
        #expect(Data(pixels[12..<16]) == Data(bytes[12..<16]))
    }

    @Test func renderedNoiseIsDeterministicAndCancellationDiscardsIt() throws {
        let sample: [UInt8] = [45, 50, 55, 255]
        let seedPixels = Array(repeating: sample, count: 64).flatMap { $0 }
        let layer = try makeLayer(seedPixels, width: 8)
        let input = try #require(RasterFilter.Input(layer: layer, selection: nil))
        let filter = try #require(RasterFilter.effects.first { $0.title == "Add Noise" })
        let defaultNoise: [Double] = [70, 40, 100, 0]
        let first = input.render(filter, values: defaultNoise)?.pdnPixels
        #expect(first != layer.pdnPixels)
        #expect(first == input.render(filter, values: defaultNoise)?.pdnPixels)
        #expect(first != input.render(filter, values: [70, 40, 100, 1])?.pdnPixels)
        #expect(layer.pdnPixels == input.render(filter, values: [70, 40, 0, 1])?.pdnPixels)
        #expect(input.render(filter, values: [70, 40, 100, 0], isCancelled: { true }) == nil)
    }

    @MainActor @Test func testApplyCommitsOneUndoAndRedoTransaction() throws {
        let layer = try makeLayer([10, 20, 30, 255], width: 1)
        let stack = LayerStack(layers: [layer], active: 0)
        let document = PaintDocument()
        try document.read(from: PDNFile.write(stack), ofType: "Paint.NET Project")
        document.undoManager?.groupsByEvent = false
        let input = try #require(document.filterInput())
        let filter = try #require(RasterFilter.adjustments.first { $0.title == "Invert Colors" })
        let preview = try #require(input.render(filter, values: []))
        equal(document.stack?.activeLayer.pdnPixels, layer.pdnPixels)
        equal(document.historyEntries, ["Open Image"])

        document.commitFilter(filter, input: input, layer: preview, values: [])
        equal(document.historyEntries, ["Open Image", "Invert Colors"])
        equal(document.stack?.activeLayer.pdnPixels, preview.pdnPixels)
        document.undoStroke(nil)
        equal(document.historyPosition, 0)
        equal(document.stack?.activeLayer.pdnPixels, layer.pdnPixels)
        document.redoStroke(nil)
        equal(document.historyPosition, 1)
        equal(document.stack?.activeLayer.pdnPixels, preview.pdnPixels)
    }

    @MainActor @Test func effectPreviewCommitUndoRedoAndPDNRoundTrip() async throws {
        _ = NSApplication.shared
        let layer = try makeLayer([10, 20, 30, 255, 180, 190, 200, 255], width: 2)
        var base = layer
        base.name = "Base"
        var editable = layer
        editable.name = "Editable"
        editable.opacity = 128
        let document = PaintDocument()
        let stack = LayerStack(layers: [base, editable], active: 1)
        try document.read(from: PDNFile.write(stack), ofType: "Paint.NET Project")
        document.makeWindowControllers()
        defer { document.close() }
        let outline = try #require(SelectionOutline(rect: CGRect(x: 1, y: 0, width: 1, height: 1)))
        document.commitSelection(outline, actionName: "Rectangle Select")
        let filter = try #require(RasterFilter.effects.first { $0.title == "Ordered Dither" })
        let input = try #require(document.filterInput())
        let panel = RasterFilterPanel(filter: filter, input: input)
        panel.updatePreview()
        for _ in 0..<100 where panel.result == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let preview = try #require(panel.result)
        #expect(preview.pdnPixels == Data([10, 20, 30, 255, 255, 255, 255, 255]))
        panel.stopPreview()
        #expect(document.stack?.activeLayer.pdnPixels == editable.pdnPixels)
        #expect(document.historyEntries == ["Open Image", "Rectangle Select"])
        document.commitFilter(filter, input: input, layer: preview, values: panel.values)
        #expect(document.historyEntries == ["Open Image", "Rectangle Select", "Ordered Dither"])
        document.undoStroke(nil)
        #expect(document.stack?.activeLayer.pdnPixels == editable.pdnPixels)
        document.redoStroke(nil)
        let reopened = try PDNFile.read(document.data(ofType: "Paint.NET Project"))
        #expect(reopened.layers.map(\.name) == ["Base", "Editable"])
        #expect(reopened.layers[0].pdnPixels == base.pdnPixels)
        #expect(reopened.layers[1].pdnPixels == preview.pdnPixels)
        #expect(reopened.layers[1].opacity == 128)
    }
}
