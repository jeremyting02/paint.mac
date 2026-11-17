import AppKit
import Testing
@testable import Paint

struct RectangleSelectionTests {
    private let imageBounds = CGRect(x: 0, y: 0, width: 120, height: 80)

    @Test func rectangularDragRemainsFreeformUntilShiftConstrainsIt() {
        let settings = RectangleSelection()
        let start = CGPoint(x: 10, y: 75)
        let end = CGPoint(x: 45, y: 70)
        #expect(settings.bounds(from: start, to: end, canvas: imageBounds, resolution: .standard)
                == CGRect(x: 10, y: 70, width: 35, height: 5))
        #expect(settings.bounds(from: start, to: end, canvas: imageBounds, resolution: .standard, square: true)
                == CGRect(x: 10, y: 40, width: 35, height: 35))
    }

    @Test func fixedRatioFitsAtCanvasEdgeInEitherDragDirection() {
        let settings = RectangleSelection(sizing: .fixedRatio, ratio: CGSize(width: 4, height: 3))
        let southeast = settings.bounds(from: CGPoint(x: 16, y: 60), to: CGPoint(x: 220, y: -40),
                                        canvas: imageBounds, resolution: .standard)
        #expect(southeast == CGRect(x: 16, y: 0, width: 80, height: 60))
        let northwest = settings.bounds(from: CGPoint(x: 112, y: 20), to: CGPoint(x: -8, y: 160),
                                        canvas: imageBounds, resolution: .standard)
        #expect(northwest == CGRect(x: 32, y: 20, width: 80, height: 60))
    }

    @Test func fixedSizeClampsThePlacementWhileKeepingItsDimensions() {
        let settings = RectangleSelection(sizing: .fixedSize, size: CGSize(width: 24, height: 36))
        let origin = CGPoint(x: 20, y: 50)
        #expect(settings.bounds(from: origin, to: origin, canvas: imageBounds, resolution: .standard)
                == CGRect(x: 20, y: 14, width: 24, height: 36))
        #expect(settings.bounds(from: origin, to: CGPoint(x: 140, y: -10), canvas: imageBounds, resolution: .standard)
                == CGRect(x: 96, y: 0, width: 24, height: 36))
    }

    @Test func physicalUnitsUseEachAxisResolutionAndKeepDimensionsWhenSwitched() throws {
        let resolution = try #require(ImageResolution(horizontal: 60, vertical: 40))
        let pointer = CGPoint(x: 15, y: 70)
        var settings = RectangleSelection(sizing: .fixedSize, size: CGSize(width: 1, height: 1.25), unit: .inches)
        let bounds = settings.bounds(from: pointer, to: pointer, canvas: imageBounds, resolution: resolution)
        #expect(bounds.size == CGSize(width: 60, height: 50))
        for unit in [RectangleSelection.Unit.centimeters, .pixels, .inches] {
            settings.changeUnit(to: unit, resolution: resolution)
            #expect(settings.bounds(from: pointer, to: pointer, canvas: imageBounds, resolution: resolution) == bounds)
        }
    }

    @MainActor @Test func fixedSizePreviewMovesAndRecordsOneUndoableSelection() throws {
        let (document, canvas) = try makeEditor()
        defer { document.close() }
        canvas.rectangleSelection.sizing = .fixedSize
        canvas.rectangleSelection.size = CGSize(width: 64, height: 40)
        let start = CGPoint(x: 100, y: 100)
        let width = try #require(document.image?.width)
        let finish = CGPoint(x: width - 14, y: 7)
        let clamped = CGRect(x: width - 64, y: 0, width: 64, height: 40)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, in: canvas))
        #expect(canvas.selection == CGRect(x: 100, y: 60, width: 64, height: 40))
        #expect(document.historyEntries == ["New Image"])
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: finish, in: canvas))
        #expect(canvas.selection == clamped)
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: finish, in: canvas))
        #expect(document.historyEntries == ["New Image", "Rectangle Select"])
        document.undoStroke(nil)
        #expect(canvas.selectionOutline == nil)
        document.redoStroke(nil)
        #expect(canvas.selection == clamped)
    }

    @MainActor @Test func rightButtonAndModifierRoutesSelectionIntersection() throws {
        let (document, canvas) = try makeEditor()
        defer { document.close() }
        let original = try #require(SelectionOutline(rect: CGRect(x: 10, y: 20, width: 80, height: 60)))
        canvas.setSelection(original)
        let start = CGPoint(x: 40, y: 5)
        let finish = CGPoint(x: 100, y: 50)
        canvas.rightMouseDown(with: try mouse(.rightMouseDown, at: start, in: canvas, modifiers: .option))
        canvas.rightMouseDragged(with: try mouse(.rightMouseDragged, at: finish, in: canvas, modifiers: .option))
        #expect(canvas.selection == CGRect(x: 40, y: 20, width: 50, height: 30))
        canvas.rightMouseUp(with: try mouse(.rightMouseUp, at: finish, in: canvas, modifiers: .option))
        #expect(document.historyEntries.last == "Rectangle Select (Intersect)")
        #expect(canvas.selectionMode == .replace)
        document.undoStroke(nil)
        #expect(canvas.selectionOutline == original)
    }

    @MainActor private func makeEditor() throws -> (PaintDocument, CanvasView) {
        _ = NSApplication.shared
        let document = PaintDocument()
        document.makeWindowControllers()
        let editor = try #require(document.editor)
        editor.layoutSubtreeIfNeeded()
        let canvas = editor.canvas
        canvas.updateViewport()
        canvas.tool = .rectangleSelect
        return (document, canvas)
    }

    @MainActor private func mouse(_ type: NSEvent.EventType, at pixel: CGPoint, in canvas: CanvasView,
                                  modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let image = canvas.canvasImageRect
        let window = try #require(canvas.window)
        let document = try #require(window.windowController?.document as? PaintDocument)
        let raster = try #require(document.image)
        let point = CGPoint(x: image.minX + pixel.x * image.width / CGFloat(raster.width),
                            y: image.minY + pixel.y * image.height / CGFloat(raster.height))
        return try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: modifiers,
                                              timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
