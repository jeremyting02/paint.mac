import AppKit
import Testing
@testable import Paint

@MainActor
func waitForDocumentJob(_ document: PaintDocument) async throws {
    for _ in 0..<200 {
        if !document.hasBackgroundJob { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!document.hasBackgroundJob, "Timed out waiting for the document operation")
}

@MainActor
struct DocumentJobTests {
    @Test func resizeCommitsAllLayersAndSelectionTogether() async throws {
        let document = try #require(PaintDocument.newImage(width: 8, height: 6, resolution: .standard))
        document.makeWindowControllers()
        var stack = try #require(document.stack)
        try stack.insertBlankLayer()
        document.applyEdit(replacingStack: stack, actionName: "Setup")
        let canvas = try #require(document.editor?.canvas)
        let selection = CGRect(x: 2, y: 2, width: 4, height: 2)
        canvas.setSelection(SelectionOutline(rect: selection))
        let expected = try stack.resizedImage(width: 4, height: 3, sampling: .bicubic, linearLight: false)

        document.performResize(width: 4, height: 3)
        #expect(document.hasBackgroundJob)
        #expect(document.image?.width == 8)
        try await waitForDocumentJob(document)
        #expect(document.stack?.layers.map(\.straightPixels) == expected.layers.map(\.straightPixels))
        #expect(canvas.selectionOutline?.bounds == CGRect(x: 1, y: 1, width: 2, height: 1))
        #expect(document.historyEntries.last == "Resize")
        document.undoStroke(nil)
        #expect(document.image?.width == 8)
        #expect(canvas.selectionOutline?.bounds == selection)
    }

    @Test func repeatEffectCommitsTheMaskedResultOnce() async throws {
        let document = try #require(PaintDocument.newImage(width: 8, height: 6, resolution: .standard))
        document.makeWindowControllers()
        let canvas = try #require(document.editor?.canvas)
        canvas.setSelection(SelectionOutline(rect: CGRect(x: 1, y: 1, width: 3, height: 3)))
        let effect = try #require(RasterFilter.effects.first { $0.title == "Add Noise" })
        let settings = effect.controls.map(\.initial)
        let input = try #require(document.filterInput())
        let expected = try #require(input.render(effect, values: settings))
        document.commitFilter(effect, input: input, layer: input.layer, values: settings)

        document.repeatEffect(nil)
        #expect(document.hasBackgroundJob)
        #expect(document.image === input.layer.image)
        document.repeatEffect(nil)
        try await waitForDocumentJob(document)
        #expect(document.stack?.activeLayer.straightPixels == expected.straightPixels)
        #expect(document.historyEntries == ["New Image", "Add Noise"])
        document.undoStroke(nil)
        #expect(document.image === input.layer.image)
    }

    @Test func exportWritesTheSnapshotAndPreservesTheDocument() async throws {
        let document = try #require(PaintDocument.newImage(width: 8, height: 6, resolution: .standard))
        var stack = try #require(document.stack)
        try stack.insertBlankLayer()
        document.applyEdit(replacingStack: stack, actionName: "Setup")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let history = document.historyEntries

        document.export(stack, to: url, as: .png, quality: 0.9)
        #expect(document.hasBackgroundJob)
        try await waitForDocumentJob(document)
        let png = try Data(contentsOf: url)
        let image = try PaintFiles.readRaster(png, expected: .png)
        #expect(image.width == 8 && image.height == 6)
        #expect(document.stack?.layers.count == 2)
        #expect(document.historyEntries == history)
    }
}
