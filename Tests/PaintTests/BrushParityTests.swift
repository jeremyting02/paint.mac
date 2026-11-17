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

    @Test func hardnessControlsEdgeFalloffOnlyWhenAntialiasingIsOn() throws {
        let (document, canvas, _) = try makeEditor(color: [0, 0, 0, 0])
        defer { document.close() }
        canvas.brushSize = 6
        let center = CGPoint(x: 4.5, y: 4.5)
        canvas.brushOptions.hardness = 100
        try click(center, in: canvas)
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 6, y: 4)?[3] == 255)
        document.undoStroke(nil)

        canvas.brushOptions.hardness = 0
        try click(center, in: canvas)
        let softAlpha = try #require(pixel(in: document.stack?.activeLayer.straightPixels, x: 6, y: 4)?[3])
        #expect((1...254).contains(softAlpha))
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 4, y: 4)?[3] == 255)
        document.undoStroke(nil)

        canvas.brushAntialiased = false
        try click(center, in: canvas)
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 6, y: 4)?[3] == 255)
    }

    @Test func spacingIsMeasuredAcrossEventsAndCreatesOneUndoEntry() throws {
        let (document, canvas, original) = try makeEditor(color: [0, 0, 0, 0])
        defer { document.close() }
        canvas.brushSize = 2
        canvas.brushOptions.antialiased = false
        canvas.brushOptions.smoothed = false
        canvas.brushOptions.spacing = 200
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 0.5, y: 3.5), in: canvas))
        for x in [1.5, 2.5, 3.5, 4.5, 6.5] {
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: x, y: 3.5), in: canvas))
        }
        #expect(document.stack?.activeLayer.straightPixels == original)
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 7.5, y: 3.5), in: canvas))
        let result = document.stack?.activeLayer.straightPixels
        #expect(pixel(in: result, x: 0, y: 3)?[3] == 255)
        #expect(pixel(in: result, x: 2, y: 3)?[3] == 0)
        #expect(pixel(in: result, x: 4, y: 3)?[3] == 255)
        #expect(pixel(in: result, x: 7, y: 3)?[3] == 0)
        #expect(document.historyEntries == ["Open Image", "Paintbrush"])
        document.undoStroke(nil)
        #expect(document.stack?.activeLayer.straightPixels == original)
    }

    @Test func patternedPaintSwapsColorsAndOverwritePreservesHiddenRGB() throws {
        let (document, canvas, original) = try makeEditor(color: [130, 100, 70, 255])
        defer { document.close() }
        canvas.brushSize = 8
        canvas.brushOptions.antialiased = false
        canvas.brushOptions.pattern = .horizontal
        canvas.brushOptions.blend = .overwrite
        canvas.brushColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0)
        canvas.secondaryColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let point = CGPoint(x: 4.5, y: 4.5)
        try click(point, in: canvas)
        var pixels = document.stack?.activeLayer.straightPixels
        #expect(pixel(in: pixels, x: 4, y: 7) == [0, 0, 255, 0])
        #expect(pixel(in: pixels, x: 4, y: 6) == [0, 255, 0, 255])
        document.undoStroke(nil)
        #expect(document.stack?.activeLayer.straightPixels == original)
        canvas.rightMouseDown(with: try mouse(.rightMouseDown, at: point, in: canvas))
        canvas.rightMouseUp(with: try mouse(.rightMouseUp, at: point, in: canvas))
        pixels = document.stack?.activeLayer.straightPixels
        #expect(pixel(in: pixels, x: 4, y: 7) == [0, 255, 0, 255])
        #expect(pixel(in: pixels, x: 4, y: 6) == [0, 0, 255, 0])
    }

    @Test func patternedEraserLeavesTheBackgroundOfTheMaskUntouched() throws {
        let original: [UInt8] = [130, 100, 70, 220]
        let (document, canvas, _) = try makeEditor(color: original)
        defer { document.close() }
        canvas.tool = .eraser
        canvas.brushSize = 8
        canvas.brushOptions.antialiased = false
        canvas.brushOptions.pattern = .horizontal
        canvas.brushColor = .black
        try click(CGPoint(x: 4.5, y: 4.5), in: canvas)
        let pixels = document.stack?.activeLayer.straightPixels
        #expect(pixel(in: pixels, x: 4, y: 7) == [0, 0, 0, 0])
        #expect(pixel(in: pixels, x: 4, y: 6) == original)
    }

    @Test func multiplyBrushUsesUnchangedLayerAtOverlappingStamps() throws {
        let (document, canvas, _) = try makeEditor(color: [100, 120, 200, 255])
        defer { document.close() }
        canvas.brushSize = 3
        canvas.brushOptions.antialiased = false
        canvas.brushOptions.blend = .layer(.multiply)
        canvas.brushColor = NSColor(srgbRed: 128.0 / 255, green: 128.0 / 255, blue: 128.0 / 255, alpha: 1)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 4.5, y: 4.5), in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 5.5, y: 4.5), in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 4.5, y: 4.5), in: canvas))
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 4, y: 4) == [50, 60, 100, 255])
    }

    @Test func pressureScalesTipDiameterAndCanBeDisabled() throws {
        let (document, canvas, _) = try makeEditor(color: [0, 0, 0, 0])
        defer { document.close() }
        let layer = try #require(document.stack?.activeLayer)
        let center = CGPoint(x: 4.5, y: 4.5)
        var options = BrushOptions()
        options.antialiased = false
        let color = DrawingColor(.black)
        let operation = RasterDrawing.Operation.paint(primary: color, secondary: color)
        let pen = try #require(RasterDrawing(layer: layer, operation: operation, diameter: 6,
                                             selection: nil, options: options))
        pen.append(center, pressure: 0.25)
        #expect(pixel(in: pen.preview?.straightPixels, x: 6, y: 4)?[3] == 0)
        #expect(pixel(in: pen.preview?.straightPixels, x: 4, y: 4)?[3] == 255)
        options.pressureSensitive = false
        let full = try #require(RasterDrawing(layer: layer, operation: operation, diameter: 6,
                                              selection: nil, options: options))
        full.append(center, pressure: 0.25)
        #expect(pixel(in: full.preview?.straightPixels, x: 6, y: 4)?[3] == 255)
        canvas.brushSize = 6
        canvas.brushAntialiased = false
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: center, in: canvas, pressure: 0.25))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: center, in: canvas, pressure: 0))
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 6, y: 4)?[3] == 255)
    }

    @Test func smoothingRoundsCornersAndFinishesNearButtonRelease() {
        func stamps(smoothed: Bool) -> [CGPoint] {
            var options = BrushOptions()
            options.smoothed = smoothed
            options.spacing = 50
            var path = BrushPath(diameter: 2, options: options)
            var points: [CGPoint] = []
            for point in [CGPoint.zero, CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 5)] {
                path.append(.init(point: point, pressure: 1)) { points.append($0.point) }
            }
            path.finish { points.append($0.point) }
            return points
        }
        let corner = CGPoint(x: 5, y: 0)
        #expect(stamps(smoothed: false).contains(corner))
        let smooth = stamps(smoothed: true)
        #expect(!smooth.contains(corner))
        #expect(smooth.first == .zero)
        #expect((smooth.last?.y ?? 0) > 4)
    }

    @Test func selectionClippingCanBeSmoothedIndependentlyOfTheBrushTip() throws {
        let (document, canvas, _) = try makeEditor(color: [0, 0, 0, 0])
        defer { document.close() }
        let selection = try #require(SelectionOutline(rect: CGRect(x: 3.5, y: 1, width: 4, height: 6)))
        canvas.setSelection(selection)
        canvas.brushSize = 8
        canvas.brushOptions.antialiased = false
        let center = CGPoint(x: 4.5, y: 4.5)
        try click(center, in: canvas)
        let smooth = try #require(pixel(in: document.stack?.activeLayer.straightPixels, x: 3, y: 4)?[3])
        #expect((1...254).contains(smooth))
        #expect(pixel(in: document.stack?.activeLayer.straightPixels, x: 2, y: 4)?[3] == 0)
        document.undoStroke(nil)
        canvas.brushOptions.antialiasedSelection = false
        try click(center, in: canvas)
        let aliased = try #require(pixel(in: document.stack?.activeLayer.straightPixels, x: 3, y: 4)?[3])
        #expect(aliased == 0 || aliased == 255)
    }

    @Test func drawingColorAndPickerCrossBetweenSwatchesAndDocumentProfile() throws {
        let profile = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let source = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)
        let color = DrawingColor(source, in: profile)
        #expect(color.red < 255)
        #expect(color.green > 0)
        #expect(color.alpha == 128)
        let bytes = Data([color.blue, color.green, color.red, color.alpha])
        let image = try #require(BGRA8.image(from: bytes, width: 1, height: 1, colorSpace: profile))
        let layer = PaintLayer(name: "Profile swatch", image: image, pdnPixels: bytes)
        let picked = try #require(DrawingColor.pick(from: layer, at: CGPoint(x: 0.5, y: 0.5), sampleSize: 1))
        #expect(abs(picked.redComponent - source.redComponent) < 0.015)
        #expect(abs(picked.greenComponent - source.greenComponent) < 0.015)
        #expect(abs(picked.blueComponent - source.blueComponent) < 0.015)
    }

    @Test func toolbarAppliesNumericOptionsAndRestoresThemWhenSwitchingTools() throws {
        let (document, canvas, _) = try makeEditor(color: [0, 0, 0, 0])
        defer { document.close() }
        let toolbar = ToolOptionsView()
        toolbar.configure(canvas: canvas)
        let hardness = try #require(toolbar.arrangedSubviews.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Brush hardness percent" })
        let spacing = try #require(toolbar.arrangedSubviews.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Brush spacing percent" })
        let antialias = try #require(toolbar.arrangedSubviews.compactMap { $0 as? NSButton }
            .first { $0.title == "Antialias" && !$0.isHidden })
        hardness.integerValue = 25
        #expect(hardness.sendAction(hardness.action, to: hardness.target))
        spacing.integerValue = 200
        #expect(spacing.sendAction(spacing.action, to: spacing.target))
        #expect(canvas.brushOptions.hardness == 25)
        #expect(canvas.brushOptions.spacing == 200)
        antialias.performClick(nil)
        #expect(!hardness.isEnabled)
        canvas.tool = .eraser
        toolbar.update()
        #expect(hardness.isEnabled)
        #expect(spacing.integerValue == 15)
        canvas.tool = .brush
        toolbar.update()
        #expect(!hardness.isEnabled)
        #expect(spacing.integerValue == 200)
    }

    private func click(_ point: CGPoint, in canvas: CanvasView) throws {
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: point, in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: point, in: canvas))
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

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in canvas: CanvasView,
                       pressure: Float = 1) throws -> NSEvent {
        let rect = canvas.canvasImageRect
        let location = CGPoint(x: rect.minX + rect.width * point.x / 8, y: rect.minY + rect.height * point.y / 8)
        let window = try #require(canvas.window)
        return try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(location, to: nil), modifierFlags: [],
                                              timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: pressure))
    }

    private func key(_ value: String, code: UInt16, in canvas: CanvasView, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let window = try #require(canvas.window)
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: value,
                                            charactersIgnoringModifiers: value, isARepeat: false, keyCode: code))
    }
}
