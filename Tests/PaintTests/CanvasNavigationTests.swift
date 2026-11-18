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
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: pointer, in: canvas))
        #expect(canvas.zoomPercent == 150)
        let zoomed = imageFraction(at: pointer, in: canvas)
        #expect(abs(startingPoint.x - zoomed.x) < 0.003)
        #expect(abs(startingPoint.y - zoomed.y) < 0.003)
        canvas.rightMouseDown(with: try mouse(.rightMouseDown, at: pointer, in: canvas))
        #expect(canvas.zoomPercent == 100)
        #expect(document.historyEntries == ["New Image"])
    }

    @Test func zoomMarqueeFitsAndCentersAnOffCenterRegion() throws {
        let (document, canvas, scroll) = try editor()
        defer { document.close() }
        canvas.tool = .zoom
        let image = canvas.canvasImageRect
        let a = CGPoint(x: image.minX + image.width / 6, y: image.minY + image.height / 4)
        let b = CGPoint(x: a.x + image.width / 3, y: a.y + image.height / 3)
        let start = canvas.convert(b, to: nil), end = canvas.convert(a, to: nil)
        let zoomBefore = canvas.displayedZoomPercent
        #expect(canvas.drawingCursor(at: a)?.image.accessibilityDescription == "Zoom")
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: end, in: canvas))
        #expect(canvas.displayedZoomPercent == zoomBefore)
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: end, in: canvas))
        let viewport = scroll.contentView.bounds
        let enlarged = canvas.canvasImageRect
        #expect(abs((viewport.midX - enlarged.minX) / enlarged.width - 1.0 / 3) < 0.003)
        #expect(abs((viewport.midY - enlarged.minY) / enlarged.height - 5.0 / 12) < 0.003)
        #expect(abs(max(enlarged.width / (3 * viewport.width), enlarged.height / (3 * viewport.height)) - 1) < 0.003)
        #expect(document.historyEntries == ["New Image"])
    }

    @Test func editableDraftsUseTheCursorForTheirNextDrag() throws {
        let (document, canvas, _) = try editor()
        defer { document.close() }
        let image = canvas.canvasImageRect
        let start = CGPoint(x: image.midX - 85, y: image.midY - 45)
        let end = CGPoint(x: image.midX + 65, y: image.midY + 45)
        func gesture(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try mouse(type, at: canvas.convert(point, to: nil), in: canvas)
        }
        func drawDraft(_ tool: CanvasView.Tool) throws {
            canvas.tool = tool
            canvas.mouseDown(with: try gesture(.leftMouseDown, start))
            #expect(canvas.drawingCursor(at: start) === NSCursor.crosshair)
            canvas.mouseUp(with: try gesture(.leftMouseUp, end))
            #expect(canvas.drawingCursor(at: start) === NSCursor.openHand)
        }
        try drawDraft(.lineCurve)
        let move = CGPoint(x: end.x + 16, y: end.y + 16)
        #expect(canvas.drawingCursor(at: move)?.image.accessibilityDescription == "Move")
        canvas.mouseDown(with: try gesture(.leftMouseDown, move))
        let moved = CGPoint(x: move.x, y: move.y + 24)
        canvas.mouseUp(with: try gesture(.leftMouseUp, moved))
        #expect(canvas.drawingCursor(at: CGPoint(x: start.x, y: start.y + 24)) === NSCursor.openHand)

        try drawDraft(.shapes)
        let pivot = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let inside = CGPoint(x: pivot.x + 28, y: pivot.y)
        let outside = CGPoint(x: end.x + 12, y: pivot.y)
        #expect(canvas.drawingCursor(at: inside)?.image.accessibilityDescription == "Move")
        #expect(canvas.drawingCursor(at: outside)?.image.accessibilityDescription == "Rotate")
        #expect(canvas.drawingCursor(at: pivot) === NSCursor.openHand)
        canvas.mouseDown(with: try gesture(.leftMouseDown, pivot))
        #expect(canvas.drawingCursor(at: pivot) === NSCursor.closedHand)
        let newPivot = CGPoint(x: pivot.x - 32, y: pivot.y - 18)
        canvas.mouseUp(with: try gesture(.leftMouseUp, newPivot))
        #expect(canvas.drawingCursor(at: newPivot) === NSCursor.openHand)
        #expect(canvas.drawingCursor(at: pivot)?.image.accessibilityDescription == "Move")
        canvas.mouseDown(with: try gesture(.leftMouseDown, outside))
        #expect(canvas.drawingCursor(at: outside)?.image.accessibilityDescription == "Rotate")
        func quarterTurn(_ point: CGPoint) -> CGPoint {
            CGPoint(x: newPivot.x - (point.y - newPivot.y), y: newPivot.y + (point.x - newPivot.x))
        }
        canvas.mouseUp(with: try gesture(.leftMouseUp, quarterTurn(outside)))
        #expect(canvas.drawingCursor(at: quarterTurn(start)) === NSCursor.openHand)
        #expect(canvas.drawingCursor(at: newPivot) === NSCursor.openHand)
        canvas.finishLiveEdit()
        #expect(canvas.drawingCursor(at: newPivot) === NSCursor.crosshair)

        try drawDraft(.gradient)
        canvas.mouseDown(with: try gesture(.leftMouseDown, start))
        #expect(canvas.drawingCursor(at: start) === NSCursor.closedHand)
        canvas.mouseUp(with: try gesture(.leftMouseUp, start))
        #expect(canvas.drawingCursor(at: start) === NSCursor.openHand)
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
        document.showWindows()
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
