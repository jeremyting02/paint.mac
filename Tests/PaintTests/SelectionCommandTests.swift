import AppKit
import Testing
@testable import Paint

@MainActor
struct SelectionCommandTests {
    @Test func testSelectAllAndInvertAreUndoable() throws {
        let document = try makeDocument()
        defer { document.close() }
        let canvas = try #require(document.editor?.canvas)
        document.selectAllPixels(nil)
        #expect(canvas.selectionOutline?.bounds == CGRect(x: 0, y: 0, width: 2, height: 1))
        document.invertPixelSelection(nil)
        #expect(canvas.selectionOutline == nil)
        document.undoStroke(nil)
        #expect(canvas.selectionOutline?.bounds == CGRect(x: 0, y: 0, width: 2, height: 1))
        #expect(document.historyPosition == 1)
    }

    @Test func testFillKeepsSelectionAndEraseRestoresItOnUndo() throws {
        let document = try makeDocument()
        defer { document.close() }
        let canvas = try #require(document.editor?.canvas)
        let left = try #require(SelectionOutline(rect: CGRect(x: 0, y: 0, width: 1, height: 1)))
        document.commitSelection(left, actionName: "Rectangle Select")
        canvas.brushColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        document.fillSelectedPixels(nil)
        let filled = Data([0, 0, 255, 255, 40, 50, 60, 255])
        #expect(document.stack?.activeLayer.pdnPixels == filled)
        #expect(canvas.selectionOutline == left)
        document.eraseSelectedPixels(nil)
        #expect(document.stack?.activeLayer.pdnPixels == Data([0, 0, 0, 0, 40, 50, 60, 255]))
        #expect(canvas.selectionOutline == nil)
        document.undoStroke(nil)
        #expect(document.stack?.activeLayer.pdnPixels == filled)
        #expect(canvas.selectionOutline == left)
    }

    @Test func pasteSelectionCombinesWithCurrentOutlineAndUndoes() throws {
        let document = try makeDocument()
        defer { document.close() }
        let canvas = try #require(document.editor?.canvas)
        let left = try #require(SelectionOutline(rect: CGRect(x: 0, y: 0, width: 1, height: 1)))
        let right = try #require(SelectionOutline(rect: CGRect(x: 1, y: 0, width: 1, height: 1)))
        let incoming = try #require(right.clipboardText(imageHeight: 1))
        let region = CGRect(x: 0, y: 0, width: 2, height: 1)
        document.commitSelection(left, actionName: "Rectangle Select")
        document.pasteSelection(incoming, mode: .add)
        #expect(canvas.selectionOutline?.mask(in: region, imageHeight: 1) == Data([255, 255]))
        document.undoStroke(nil)
        #expect(canvas.selectionOutline == left)
        document.pasteSelection(incoming, mode: .intersect)
        #expect(canvas.selectionOutline == nil)
        document.undoStroke(nil)
        document.pasteSelection(incoming, mode: .replace)
        #expect(canvas.selectionOutline?.bounds == right.bounds)
    }

    private func makeDocument() throws -> PaintDocument {
        _ = NSApplication.shared
        let bytes = Data([10, 20, 30, 255, 40, 50, 60, 255])
        let image = try #require(BGRA8.image(from: bytes, width: 2, height: 1))
        let stack = LayerStack(layers: [PaintLayer(name: "Test", image: image, pdnPixels: bytes)], active: 0)
        let document = PaintDocument()
        try document.read(from: PDNFile.write(stack), ofType: "Paint.NET Project")
        document.makeWindowControllers()
        return document
    }
}
