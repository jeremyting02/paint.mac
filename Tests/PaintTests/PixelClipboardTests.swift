import AppKit
import Testing
@testable import Paint

@MainActor
struct PixelClipboardTests {
    @Test func cutAndPasteRestoresPixelsAtTheirOriginalLocation() throws {
        let document = try editor(width: 40, height: 30)
        defer { document.close() }
        let canvas = try #require(document.editor?.canvas)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let originalPixels = try #require(document.stack?.activeLayer.straightPixels)
        let selection = CGRect(x: 13, y: 9, width: 7, height: 4)
        canvas.setSelection(SelectionOutline(rect: selection))

        document.copyPixels(to: clipboard, cutting: true)
        #expect(canvas.selectionOutline == nil)
        #expect(document.stack?.activeLayer.straightPixels != originalPixels)
        #expect(document.historyEntries.last == "Cut")
        document.pastePixels(from: clipboard)
        #expect(canvas.move?.geometry.rect == selection)
        #expect(canvas.copyableLayer?.straightPixels == originalPixels)
        #expect(document.historyEntries.last == "Paste")
        canvas.finishSelection()
        #expect(document.stack?.activeLayer.straightPixels == originalPixels)
    }

    @Test(arguments: [false, true])
    func copyRetainsTopLeftImageCoordinatesInAnotherDocument(flattened: Bool) throws {
        let source = try editor(width: 40, height: 30)
        let destination = try editor(width: 50, height: 60)
        defer { source.close(); destination.close() }
        let sourceCanvas = try #require(source.editor?.canvas)
        let destinationCanvas = try #require(destination.editor?.canvas)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        sourceCanvas.setSelection(SelectionOutline(rect: CGRect(x: 13, y: 9, width: 7, height: 4)))
        destinationCanvas.setSelection(SelectionOutline(rect: CGRect(x: 0, y: 0, width: 2, height: 2)))

        source.copyPixels(to: clipboard, cutting: false, flattened: flattened)
        destination.pastePixels(from: clipboard, intoNewLayer: flattened)
        // The copy starts 17 pixels from the top, even though the destination is taller.
        #expect(destinationCanvas.move?.geometry.rect == CGRect(x: 13, y: 39, width: 7, height: 4))
        #expect(destination.stack?.layers.count == (flattened ? 2 : 1))
        destination.undoStroke(nil)
        #expect(destinationCanvas.move == nil)
        destination.redoStroke(nil)
        #expect(destinationCanvas.move?.geometry.rect == CGRect(x: 13, y: 39, width: 7, height: 4))
    }

    @Test func pasteMovesOnlyAsFarAsNeededToFitTheScrolledViewport() throws {
        let document = try editor(width: 800, height: 600)
        defer { document.close() }
        let canvas = try #require(document.editor?.canvas)
        let scroll = try #require(canvas.enclosingScrollView)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        canvas.setZoom(800)
        let view = canvas.canvasImageRect
        let scale = view.width / 800
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: view.minX + 160 * scale, y: view.maxY - 120 * scale - clip.bounds.height))
        scroll.reflectScrolledClipView(clip)
        let visible = canvas.visibleRect.intersection(view)
        let right = floor((visible.maxX - view.minX) / scale)
        #expect(right > 170 && right < 800)

        canvas.setSelection(SelectionOutline(rect: CGRect(x: right - 4, y: 440, width: 12, height: 10)))
        document.copyPixels(to: clipboard, cutting: false)
        document.pastePixels(from: clipboard)
        #expect(canvas.move?.geometry.rect == CGRect(x: right - 12, y: 440, width: 12, height: 10))
        #expect(canvas.visibleRect.intersection(view) == visible)
        canvas.finishSelection()

        canvas.setSelection(SelectionOutline(rect: CGRect(x: 0, y: 440, width: 800, height: 10)))
        document.copyPixels(to: clipboard, cutting: false)
        document.pastePixels(from: clipboard)
        let left = ceil((visible.minX - view.minX) / scale)
        #expect(canvas.move?.geometry.rect == CGRect(x: left, y: 440, width: 800, height: 10))
    }

    @Test func externalPNGAndInvalidOrUnrelatedMetadataUseTheVisibleOrigin() throws {
        let document = try editor(width: 40, height: 30)
        defer { document.close() }
        let canvas = try #require(document.editor?.canvas)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let image = try #require(BGRA8.image(from: Data([3, 2, 1, 255]), width: 1, height: 1))
        let png = try PaintFiles.pngData(image)
        let originType = NSPasteboard.PasteboardType("local.paintmac.pixel-origin")
        let pngItem = NSPasteboardItem()
        #expect(pngItem.setData(png, forType: .png))
        let unrelated = NSPasteboardItem()
        #expect(unrelated.setData(Data(#"{"x":10,"y":11}"#.utf8), forType: originType))
        clipboard.clearContents()
        #expect(clipboard.writeObjects([unrelated, pngItem]))
        document.pastePixels(from: clipboard)
        #expect(canvas.move?.geometry.rect == CGRect(x: 0, y: 29, width: 1, height: 1))
        canvas.finishSelection()

        let invalid = NSPasteboardItem()
        #expect(invalid.setData(png, forType: .png))
        #expect(invalid.setData(Data(#"{"x":9223372036854775807,"y":11}"#.utf8), forType: originType))
        clipboard.clearContents()
        #expect(clipboard.writeObjects([invalid]))
        document.pastePixels(from: clipboard)
        #expect(canvas.move?.geometry.rect == CGRect(x: 0, y: 29, width: 1, height: 1))
    }

    private func editor(width: Int, height: Int) throws -> PaintDocument {
        _ = NSApplication.shared
        let pixels = Data(repeating: 255, count: width * height * 4)
        let image = try #require(BGRA8.image(from: pixels, width: width, height: height))
        let layer = PaintLayer(name: "Clipboard test", image: image, pdnPixels: pixels)
        let document = PaintDocument()
        try document.read(from: PDNFile.write(LayerStack(layers: [layer], active: 0)), ofType: "Paint.NET Project")
        document.showWindows()
        document.editor?.layoutSubtreeIfNeeded()
        return document
    }
}
