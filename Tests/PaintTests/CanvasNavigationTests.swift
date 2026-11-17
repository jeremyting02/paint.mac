import AppKit
import Testing
@testable import Paint

@MainActor
struct CanvasNavigationTests {
    @Test func zoomShortcutAndMouseButtonsStepAroundThePointer() throws {
        let (document, canvas, scroll) = try editor()
        defer { document.close() }
        canvas.setZoom(100)
        let pointer = windowPoint(in: canvas, scroll: scroll)
        let startingPoint = imageFraction(at: pointer, in: canvas)
        canvas.keyDown(with: try key("z", code: 6, in: canvas))
        #expect(canvas.tool == .zoom)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: pointer, in: canvas))
        #expect(canvas.zoomPercent == 150)
        let zoomed = imageFraction(at: pointer, in: canvas)
        #expect(abs(startingPoint.x - zoomed.x) < 0.003)
        #expect(abs(startingPoint.y - zoomed.y) < 0.003)
        canvas.rightMouseDown(with: try mouse(.rightMouseDown, at: pointer, in: canvas))
        #expect(canvas.zoomPercent == 100)
        #expect(document.historyEntries == ["New Image"])
    }

    @Test func panShortcutAndTemporarySpaceDragScrollWithoutEditing() throws {
        let (document, canvas, scroll) = try editor()
        defer { document.close() }
        canvas.setZoom(200)
        let original = scroll.contentView.bounds.origin
        let start = windowPoint(in: canvas, scroll: scroll)
        let finish = CGPoint(x: start.x + 24, y: start.y - 18)
        canvas.keyDown(with: try key("h", code: 4, in: canvas))
        #expect(canvas.tool == .pan)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: finish, in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: finish, in: canvas))
        let panned = scroll.contentView.bounds.origin
        #expect(abs(panned.x - (original.x - 24)) < 0.5)
        #expect(abs(panned.y - (original.y + 18)) < 0.5)

        canvas.keyDown(with: try key("p", code: 35, in: canvas))
        #expect(canvas.tool == .pencil)
        canvas.keyDown(with: try key(" ", code: 49, in: canvas))
        canvas.rightMouseDown(with: try mouse(.rightMouseDown, at: start, in: canvas))
        canvas.rightMouseDragged(with: try mouse(.rightMouseDragged, at: finish, in: canvas))
        canvas.keyUp(with: try key(" ", code: 49, type: .keyUp, in: canvas))
        canvas.rightMouseUp(with: try mouse(.rightMouseUp, at: finish, in: canvas))
        let temporaryPan = scroll.contentView.bounds.origin
        #expect(abs(temporaryPan.x - (panned.x - 24)) < 0.5)
        #expect(abs(temporaryPan.y - (panned.y + 18)) < 0.5)
        #expect(canvas.tool == .pencil)
        #expect(document.historyEntries == ["New Image"])
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: start, in: canvas))
        #expect(document.historyEntries.last == "Pencil")
    }

    private func editor() throws -> (PaintDocument, CanvasView, NSScrollView) {
        _ = NSApplication.shared
        let document = PaintDocument()
        document.makeWindowControllers()
        let editor = try #require(document.editor)
        editor.layoutSubtreeIfNeeded()
        let canvas = editor.canvas
        let scroll = try #require(canvas.enclosingScrollView)
        canvas.updateViewport()
        return (document, canvas, scroll)
    }

    private func windowPoint(in canvas: CanvasView, scroll: NSScrollView) -> CGPoint {
        let visible = scroll.contentView.bounds
        return canvas.convert(CGPoint(x: visible.midX + 37, y: visible.midY - 19), to: nil)
    }

    private func imageFraction(at windowPoint: CGPoint, in canvas: CanvasView) -> CGPoint {
        let point = canvas.convert(windowPoint, from: nil)
        let image = canvas.canvasImageRect
        return CGPoint(x: (point.x - image.minX) / image.width, y: (point.y - image.minY) / image.height)
    }

    private func key(_ value: String, code: UInt16, type: NSEvent.EventType = .keyDown, in canvas: CanvasView) throws -> NSEvent {
        let window = try #require(canvas.window)
        return try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: value,
                                            charactersIgnoringModifiers: value, isARepeat: false, keyCode: code))
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in canvas: CanvasView) throws -> NSEvent {
        let window = try #require(canvas.window)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: 1))
    }
}
