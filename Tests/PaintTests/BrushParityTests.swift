import AppKit
import Testing
@testable import Paint

@MainActor
struct BrushParityTests {
    @Test func eraserUsesEachColorOpacityAndPreservesStraightRGB() throws {
        let base: [UInt8] = [8, 31, 217, 255]
        let (document, canvas, pixels) = try makeEditor(color: base)
        defer { document.close() }
        canvas.tool = .eraser
        canvas.brushAntialiased = false
        canvas.brushSize = 3
        canvas.brushColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 60.0 / 255)
        canvas.secondaryColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 120.0 / 255)
        let center = CGPoint(x: 2.5, y: 2.5)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: center, in: canvas))
        #expect(document.stack?.activeLayer.straightPixels == pixels)
        #expect(pixel(in: canvas.copyableLayer?.straightPixels, x: 2, y: 2) == [8, 31, 217, 195])
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 3.5, y: 2.5), in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: center, in: canvas))
        #expect(document.historyEntries.last == "Eraser")
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 2, y: 2) == [8, 31, 217, 195])
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 2, y: 6) == base)
        document.undoStroke(nil)
        #expect(document.stack?.activeLayer.straightPixels == pixels)

        canvas.rightMouseDown(with: try mouse(.rightMouseDown, at: center, in: canvas))
        canvas.rightMouseUp(with: try mouse(.rightMouseUp, at: center, in: canvas))
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 2, y: 2) == [8, 31, 217, 135])
        document.undoStroke(nil)
        canvas.brushColor = .black
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: center, in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: center, in: canvas))
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 2, y: 2) == [0, 0, 0, 0])
        #expect(document.historyEntries.last == "Eraser")
    }

    @Test func fractionalBrushSizeSupportsBracketShortcutsAndAntialiasing() throws {
        let (document, canvas, _) = try makeEditor(color: [0, 0, 0, 0])
        defer { document.close() }
        canvas.tool = .brush
        canvas.brushSize = 6.5
        canvas.keyDown(with: try key("[", code: 33, in: canvas))
        #expect(canvas.brushSize == 5.5)
        canvas.keyDown(with: try key("]", code: 30, in: canvas, modifiers: .control))
        #expect(canvas.brushSize == 10.5)

        canvas.brushSize = 3.5
        let center = CGPoint(x: 4.5, y: 4.5)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: center, in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: center, in: canvas))
        let antialiased = try #require(document.stack?.activeLayer.straightPixels)
        #expect(stride(from: 3, to: antialiased.count, by: 4).contains { (1...254).contains(antialiased[$0]) })
        document.undoStroke(nil)

        canvas.brushAntialiased = false
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: center, in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: center, in: canvas))
        let aliased = try #require(document.stack?.activeLayer.straightPixels)
        #expect(stride(from: 3, to: aliased.count, by: 4).allSatisfy { aliased[$0] == 0 || aliased[$0] == 255 })
        #expect(aliased != antialiased)
    }

    @Test func brushPreservesStraightRGBOutsideItsCoverage() throws {
        let original: [UInt8] = [67, 116, 201, 1]
        let (document, canvas, pixels) = try makeEditor(color: original)
        defer { document.close() }
        canvas.tool = .brush
        canvas.brushAntialiased = false
        canvas.brushSize = 1
        canvas.brushColor = .black
        let center = CGPoint(x: 3.5, y: 3.5)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: center, in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: center, in: canvas))
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 3, y: 3) == [0, 0, 0, 255])
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 2, y: 3) == original)
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 0, y: 0) == original)
        document.undoStroke(nil)
        #expect(document.stack?.activeLayer.straightPixels == pixels)
    }

    private func makeEditor(color: [UInt8]) throws -> (PaintDocument, CanvasView, Data) {
        _ = NSApplication.shared
        let pixels = Data(Array(repeating: color, count: 8 * 8).flatMap { $0 })
        let image = try #require(BGRA8.image(from: pixels, width: 8, height: 8))
        let fixture = PaintLayer(name: "Brush Test", image: image, pdnPixels: pixels)
        let document = PaintDocument()
        try document.read(from: PDNFile.write(LayerStack(layers: [fixture], active: 0)), ofType: "Paint.NET Project")
        document.makeWindowControllers()
        let editor = try #require(document.editor)
        editor.layoutSubtreeIfNeeded()
        editor.canvas.updateViewport()
        return (document, editor.canvas, pixels)
    }

    private func pixel(in bytes: Data?, x: Int, y: Int) -> [UInt8]? {
        let index = ((7 - y) * 8 + x) * 4
        return bytes.map { Array($0[index..<index + 4]) }
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in canvas: CanvasView) throws -> NSEvent {
        let rect = canvas.canvasImageRect
        let location = CGPoint(x: rect.minX + rect.width * point.x / 8, y: rect.minY + rect.height * point.y / 8)
        let window = try #require(canvas.window)
        return try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(location, to: nil), modifierFlags: [],
                                              timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func key(_ value: String, code: UInt16, in canvas: CanvasView, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let window = try #require(canvas.window)
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: value,
                                            charactersIgnoringModifiers: value, isARepeat: false, keyCode: code))
    }
}
