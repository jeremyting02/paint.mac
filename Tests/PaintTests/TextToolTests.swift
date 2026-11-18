import AppKit
import Testing
@testable import Paint

struct TextToolTests {
    @Test func dpiAndAlignmentKeepTheirAnchorAcrossLines() throws {
        var style = DrawingStyle()
        let resolution = try #require(ImageResolution(horizontal: 192, vertical: 192))
        #expect(TextMetric.points.pixelSize(18.75, resolution: resolution) == 50)
        #expect(TextMetric.fixed.pixelSize(18.75, resolution: resolution) == 25)

        style.text = "AA\r\nAA\n"
        style.textRendering = .smooth
        let anchor = CGPoint(x: 100, y: 80)
        let left = TextLayout(origin: anchor, style: style)
        #expect(left.caret(at: 0).minX == anchor.x)
        #expect(left.caret(at: 4).minX == anchor.x)
        #expect(left.caret(at: 4).minY < left.caret(at: 0).minY)
        #expect(left.caret(at: 7).minY < left.caret(at: 4).minY)
        style.alignment = .center
        let center = TextLayout(origin: anchor, style: style)
        #expect(abs(center.caret(at: 0).minX + center.caret(at: 2).minX - anchor.x * 2) < 0.001)
        style.alignment = .right
        let right = TextLayout(origin: anchor, style: style)
        #expect(abs(right.caret(at: 2).minX - anchor.x) < 0.001)
        #expect(abs(right.caret(at: 6).minX - anchor.x) < 0.001)
    }

    @Test func textRespectsAntialiasingAndSelectionClipping() throws {
        let width = 80
        let height = 55
        let bytes = Data(count: width * height * 4)
        let image = try #require(BGRA8.image(from: bytes, width: width, height: height))
        let layer = PaintLayer(name: "Text target", image: image, pdnPixels: bytes)
        var style = DrawingStyle()
        style.text = "AAA"
        style.fontSize = 24
        let drawing = VectorDrawing.text(CGPoint(x: 8, y: 46))
        style.antialiased = false
        let aliased = try #require(drawing.applying(to: layer, selection: nil, style: style)?.straightPixels)
        let alphas = stride(from: 3, to: aliased.count, by: 4).map { aliased[$0] }
        #expect(alphas.allSatisfy { $0 == 0 || $0 == 255 })
        let outline = try #require(SelectionOutline(path: CGPath(ellipseIn: CGRect(x: 3, y: 14, width: 50, height: 40),
                                                                  transform: nil)))
        let smooth = try #require(drawing.applying(to: layer, selection: outline, style: style)?.straightPixels)
        #expect(stride(from: 3, to: smooth.count, by: 4).contains { (1..<255).contains(smooth[$0]) })
        style.textAntialiasedSelection = false
        let snapped = try #require(drawing.applying(to: layer, selection: outline, style: style)?.straightPixels)
        #expect(stride(from: 3, to: snapped.count, by: 4).allSatisfy { snapped[$0] == 0 || snapped[$0] == 255 })
        #expect(snapped != smooth)
    }

    @Test func overwriteCanEraseGlyphsWithTransparentPrimaryColor() throws {
        let bytes = Data(repeating: 255, count: 64 * 40 * 4)
        let image = try #require(BGRA8.image(from: bytes, width: 64, height: 40))
        let layer = PaintLayer(name: "Text target", image: image, pdnPixels: bytes)
        let drawing = VectorDrawing.text(CGPoint(x: 4, y: 36))
        var style = DrawingStyle()
        style.text = "M"
        style.fontSize = 24
        style.antialiased = false
        style.textRendering = .smooth
        style.primary = NSColor(red: 1, green: 0, blue: 0, alpha: 0)
        #expect(drawing.applying(to: layer, selection: nil, style: style) == nil)

        style.textBlend = .overwrite
        let pixels = try #require(drawing.applying(to: layer, selection: nil, style: style)?.straightPixels)
        let erased = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 3] == 0 }
        #expect(!erased.isEmpty)
        #expect(erased.allSatisfy { Array(pixels[$0..<($0 + 4)]) == [0, 0, 255, 0] })
        #expect(pixels.prefix(4) == bytes.prefix(4))
    }

    @MainActor
    @Test func nativeInputMovesAndCommitsOneUndoableDraft() throws {
        _ = NSApplication.shared
        let document = try #require(PaintDocument.newImage(width: 200, height: 120, resolution: .standard))
        document.showWindows()
        defer { document.close() }
        let editor = try #require(document.editor)
        let canvas = editor.canvas
        let window = try #require(canvas.window)
        editor.layoutSubtreeIfNeeded()
        canvas.updateViewport()
        canvas.tool = .text

        let rect = canvas.canvasImageRect
        let origin = CGPoint(x: 20, y: 100)
        let location = CGPoint(x: rect.minX + rect.width * origin.x / 200,
                               y: rect.minY + rect.height * origin.y / 120)
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func key(_ characters: String, code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }

        let original = try #require(document.stack?.activeLayer.straightPixels)
        let history = document.historyEntries
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: location))
        let input = try #require(canvas.focusedTextInput)
        #expect(window.firstResponder === input)
        input.keyDown(with: try key("t", code: 17))
        input.keyDown(with: try key(" ", code: 49))
        input.keyDown(with: try key("c", code: 8))
        input.keyDown(with: try key("\r", code: 36))
        input.insertText("Second line", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(input.string == "t c\nSecond line")
        #expect(canvas.tool == .text)
        #expect(document.stack?.activeLayer.straightPixels == original)
        #expect(document.historyEntries == history)

        document.selectAllPixels(nil)
        #expect(input.selectedRange().length == (input.string as NSString).length)
        #expect(canvas.selectionOutline == nil)
        input.setSelectedRange(NSRange(location: (input.string as NSString).length, length: 0))
        let before = try #require(canvas.copyableLayer?.straightPixels)
        canvas.brushColor = .red
        let colored = try #require(canvas.copyableLayer?.straightPixels)
        #expect(colored != before)

        let handleFrame = try #require(canvas.textHandleFrame(imageWidth: 200))
        let handle = CGPoint(x: handleFrame.midX, y: handleFrame.midY)
        let destination = CGPoint(x: handle.x + 14, y: handle.y - 3)
        canvas.rightMouseDown(with: try mouse(.rightMouseDown, at: handle))
        canvas.rightMouseDragged(with: try mouse(.rightMouseDragged, at: destination))
        input.keyDown(with: try key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124))
        let moved = try #require(canvas.copyableLayer?.straightPixels)
        canvas.rightMouseUp(with: try mouse(.rightMouseUp, at: destination))
        #expect(moved != colored)
        #expect(canvas.copyableLayer?.straightPixels == moved)

        input.keyDown(with: try key("\u{1b}", code: 53))
        #expect(!canvas.hasPendingText)
        #expect(document.historyEntries == history + ["Text"])
        #expect(document.stack?.activeLayer.straightPixels == moved)
        document.undoStroke(nil)
        #expect(document.stack?.activeLayer.straightPixels == original)
        document.redoStroke(nil)
        #expect(document.stack?.activeLayer.straightPixels == moved)

        canvas.mouseDown(with: try mouse(.leftMouseDown, at: location))
        #expect(canvas.hasPendingText)
        canvas.finishLiveEdit()
        #expect(!canvas.hasPendingText)
        #expect(document.historyEntries == history + ["Text"])
    }
}
