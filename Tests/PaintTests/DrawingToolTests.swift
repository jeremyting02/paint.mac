import AppKit
import Testing
@testable import Paint

struct DrawingToolTests {
    @Test func testPencilUsesOnePixelWidthAndClipsStrokeToSelection() throws {
        let layer = try transparentLayer(width: 5, height: 3)
        let selection = SelectionOutline(rect: CGRect(x: 1, y: 1, width: 3, height: 1))
        let stroke = try #require(RasterDrawing(layer: layer, operation: .pencil(DrawingColor(.red)),
                                               diameter: 12, selection: selection))
        stroke.append(CGPoint(x: 0.2, y: 1.2))
        stroke.append(CGPoint(x: 4.8, y: 1.2))
        let pixels = try #require(stroke.preview?.straightPixels)
        for row in 0..<3 {
            for column in 0..<5 {
                let index = (row * 5 + column) * 4
                let expected: [UInt8] = row == 1 && (1...3).contains(column) ? [0, 0, 255, 255] : [0, 0, 0, 0]
                #expect(Array(pixels[index..<(index + 4)]) == expected)
            }
        }
        #expect(nil == layer.straightPixels?.first(where: { $0 != 0 }))
    }

    @Test func testPickerAveragesSamplesAndKeepsStraightAlpha() throws {
        let layer = try layer(width: 3, height: 1, pixels: [0, 0, 255, 255, 0, 255, 0, 0, 255, 0, 0, 255])
        let color = try #require(DrawingColor.pick(from: layer, at: CGPoint(x: 1, y: 0), sampleSize: 3))
        #expect(abs(color.redComponent - (0.5)) < 0.01)
        #expect(abs(color.blueComponent - (0.5)) < 0.01)
        #expect(abs(color.greenComponent - (0)) < 0.01)
        #expect(abs(color.alphaComponent - (2.0 / 3)) < 0.01)
        #expect(nil == DrawingColor.pick(from: layer, at: CGPoint(x: -0.2, y: 0), sampleSize: 1))
    }

    @Test func testCloneUsesFrozenSourceWhenDestinationOverlapsSource() throws {
        let layer = try layer(width: 4, height: 1, pixels: [0, 0, 255, 255, 0, 255, 0, 255,
                                                            255, 0, 0, 255, 0, 0, 0, 0])
        let source = try #require(layer.straightPixels)
        let stroke = try #require(RasterDrawing(layer: layer,
                                               operation: .clone(source: source, offset: CGPoint(x: -1, y: 0),
                                                                 opacity: 255),
                                               diameter: 1, selection: nil))
        stroke.append(CGPoint(x: 1.5, y: 0.5))
        stroke.append(CGPoint(x: 3.5, y: 0.5))
        stroke.finish()
        let pixels = try #require(stroke.preview?.straightPixels)
        #expect(Array(pixels) == [0, 0, 255, 255, 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255])
    }

    @Test func testRecolorChangesMatchingPixelsAndKeepsTheirAlpha() throws {
        let layer = try layer(width: 2, height: 1, pixels: [0, 0, 255, 128, 0, 255, 0, 255])
        let stroke = try #require(RasterDrawing(layer: layer,
                                               operation: .recolor(from: DrawingColor(.red), to: DrawingColor(.blue),
                                                                   tolerance: 0),
                                               diameter: 1, selection: nil))
        stroke.append(CGPoint(x: 0.5, y: 0.5))
        stroke.append(CGPoint(x: 1.5, y: 0.5))
        stroke.finish()
        #expect(stroke.preview?.straightPixels == Data([255, 0, 0, 128, 0, 255, 0, 255]))
    }

    @Test func testLineGeometryReinterpretsTheSameFourHandles() throws {
        let layer = try transparentLayer(width: 24, height: 24)
        let points = [CGPoint(x: 2.5, y: 2.5), CGPoint(x: 5.5, y: 20.5),
                      CGPoint(x: 17.5, y: 20.5), CGPoint(x: 20.5, y: 2.5)]
        let drawing = VectorDrawing.line(points)
        var style = DrawingStyle()
        style.width = 2
        #expect(style.lineGeometry == .spline)
        let spline = try #require(drawing.applying(to: layer, selection: nil, style: style)?.straightPixels)
        style.lineGeometry = .straight
        let straight = try #require(drawing.applying(to: layer, selection: nil, style: style)?.straightPixels)
        style.lineGeometry = .bezier
        let bezier = try #require(drawing.applying(to: layer, selection: nil, style: style)?.straightPixels)
        func alpha(in pixels: Data, at point: CGPoint) -> UInt8 {
            let row = 23 - Int(point.y)
            return pixels[(row * 24 + Int(point.x)) * 4 + 3]
        }
        for point in points {
            #expect(alpha(in: spline, at: point) > 0)
            #expect(alpha(in: straight, at: point) > 0)
        }
        for point in points[1...2] {
            #expect(alpha(in: bezier, at: point) == 0)
        }
        let aboveStraightSegment = CGPoint(x: 11.5, y: 22.5)
        #expect(alpha(in: spline, at: aboveStraightSegment) > 0)
        #expect(alpha(in: straight, at: aboveStraightSegment) == 0)
        style.lineGeometry = .spline
        #expect(drawing.applying(to: layer, selection: nil, style: style)?.straightPixels == spline)
        #expect(nil == layer.straightPixels?.first(where: { $0 != 0 }))
    }

    @Test func testShapeFillAndSelectionClipping() throws {
        let layer = try transparentLayer(width: 12, height: 12)
        let drawing = VectorDrawing.shape(CGRect(x: 1, y: 1, width: 10, height: 10))
        let selection = SelectionOutline(rect: CGRect(x: 4, y: 4, width: 4, height: 4))
        var style = DrawingStyle()
        style.shape = .ellipse
        style.fill = .fill
        style.primary = .green
        let pixels = try #require(drawing.applying(to: layer, selection: selection, style: style)?.straightPixels)
        #expect(pixels[(5 * 12 + 5) * 4 + 3] == 255)
        #expect(pixels[(3 * 12 + 5) * 4 + 3] == 0)
        #expect(pixels[(5 * 12 + 3) * 4 + 3] == 0)
        for shape in DrawingShape.allCases {
            #expect(!shape.path(in: CGRect(x: 1, y: 1, width: 10, height: 10)).isEmpty)
        }
    }

    @Test func testTextRasterizesAtAnchorAndEmptyTextHasNoPreview() throws {
        let layer = try transparentLayer(width: 80, height: 40)
        let drawing = VectorDrawing.text(CGPoint(x: 4, y: 37))
        var style = DrawingStyle()
        #expect(nil == drawing.applying(to: layer, selection: nil, style: style))
        style.text = "Paint"
        style.bold = true
        #expect(nil != drawing.applying(to: layer, selection: nil, style: style))
        let distantSelection = SelectionOutline(rect: CGRect(x: 72, y: 0, width: 8, height: 8))
        #expect(nil == drawing.applying(to: layer, selection: distantSelection, style: style))
    }

    @Test func testBucketGlobalAndContiguousUsePaintOpacity() throws {
        let layer = try layer(width: 3, height: 1, pixels: [0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255])
        var settings = FloodSettings(tolerance: 0)
        let contiguous = try #require(settings.select(in: layer, x: 0, y: 0))
        let first = try #require(layer.filling(contiguous, blue: 255, green: 0, red: 0, alpha: 128)?.straightPixels)
        #expect(Array(first) == [128, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255])
        settings.flood = .global
        let global = try #require(settings.select(in: layer, x: 0, y: 0))
        let both = try #require(layer.filling(global, blue: 255, green: 0, red: 0, alpha: 128)?.straightPixels)
        #expect(Array(both) == [128, 0, 0, 255, 255, 255, 255, 255, 128, 0, 0, 255])
    }

    @Test func testGradientTransparencyChangesAlphaOnlyAndRespectsSelection() throws {
        let layer = try layer(width: 3, height: 1, pixels: [5, 10, 15, 255, 5, 10, 15, 200, 5, 10, 15, 255])
        let selection = SelectionOutline(rect: CGRect(x: 1, y: 0, width: 2, height: 1))
        let line = LinearGradient(start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 2.5, y: 0.5))
        let options = GradientOptions(transparency: true)
        let preview = try #require(line.applying(to: layer, primary: NSColor.black.cgColor,
                                                 secondary: NSColor.white.cgColor, selection: selection,
                                                 options: options))
        #expect(preview.straightPixels == Data([5, 10, 15, 255, 5, 10, 15, 100, 5, 10, 15, 0]))
        let reversed = try #require(line.applying(to: layer, primary: NSColor.black.cgColor,
                                                  secondary: NSColor.white.cgColor, selection: nil,
                                                  options: options, reversed: true))
        #expect(reversed.straightPixels == Data([5, 10, 15, 0, 5, 10, 15, 100, 5, 10, 15, 255]))
    }

    @Test func testGradientShapesAndRepeatModes() {
        #expect(GradientOptions(shape: .linear).position(x: 0.25, y: 0.5) == 0.25)
        #expect(GradientOptions(shape: .reflected).position(x: -0.25, y: 0.5) == 0.25)
        #expect(GradientOptions(shape: .diamond).position(x: -0.25, y: 0.5) == 0.75)
        #expect(abs(GradientOptions(shape: .radial).position(x: 0.3, y: 0.4) - (0.5)) < 0.0001)
        #expect(GradientOptions(shape: .conical).position(x: 0, y: 1) > GradientOptions(shape: .conical).position(x: 0, y: -1))
        #expect(GradientOptions(shape: .clockwise).position(x: 0.25, y: 0.25) > GradientOptions(shape: .anticlockwise).position(x: 0.25, y: 0.25))
        #expect(GradientOptions(repeats: .wrapped).position(x: -1.25, y: 0) == 0.75)
        #expect(GradientOptions(repeats: .reflected).position(x: 1.25, y: 0) == 0.75)
    }

    @MainActor
    @Test func pencilCommitsOnMouseUpAndLineRemainsEditableUntilFinish() throws {
        _ = NSApplication.shared
        let document = PaintDocument()
        let fixture = try transparentLayer(width: 10, height: 10)
        try document.read(from: PDNFile.write(LayerStack(layers: [fixture], active: 0)), ofType: "Paint.NET Project")
        document.showWindows()
        defer { document.close() }
        let editor = try #require(document.editor)
        let canvas = editor.canvas
        let window = try #require(canvas.window)
        editor.layoutSubtreeIfNeeded()
        canvas.updateViewport()
        let rect = canvas.canvasImageRect
        #expect(!rect.isEmpty)
        func click(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) throws -> NSEvent {
            let point = CGPoint(x: rect.minX + rect.width * x / 10, y: rect.minY + rect.height * y / 10)
            return try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                                                 modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let original = document.stack?.activeLayer.straightPixels
        canvas.tool = .pencil
        canvas.mouseDown(with: try click(.leftMouseDown, x: 1.5, y: 1.5))
        #expect(document.stack?.activeLayer.straightPixels == original)
        canvas.mouseUp(with: try click(.leftMouseUp, x: 3.5, y: 1.5))
        let drawn = try #require(document.stack?.activeLayer.straightPixels)
        #expect(document.historyEntries.last == "Pencil")
        #expect(drawn != original)
        document.undoStroke(nil)
        #expect(document.stack?.activeLayer.straightPixels == original)
        document.redoStroke(nil)
        #expect(document.stack?.activeLayer.straightPixels == drawn)

        canvas.tool = .lineCurve
        canvas.brushSize = 1
        canvas.mouseDown(with: try click(.leftMouseDown, x: 2, y: 6))
        canvas.mouseUp(with: try click(.leftMouseUp, x: 7, y: 8))
        #expect(canvas.hasPendingDrawing)
        #expect(document.stack?.activeLayer.straightPixels == drawn)

        let other = PaintDocument()
        defer { other.close() }
        other.showWindows()
        document.showWindows()
        #expect(canvas.hasPendingDrawing)
        #expect(document.stack?.activeLayer.straightPixels == drawn)

        canvas.finishLiveEdit()
        #expect(!canvas.hasPendingDrawing)
        #expect(document.historyEntries.last == "Line / Curve")
        #expect(document.stack?.activeLayer.straightPixels != drawn)
        document.undoStroke(nil)
        #expect(document.stack?.activeLayer.straightPixels == drawn)
    }

    private func transparentLayer(width: Int, height: Int) throws -> PaintLayer {
        try layer(width: width, height: height, pixels: Array(repeating: 0, count: width * height * 4))
    }

    private func layer(width: Int, height: Int, pixels: [UInt8]) throws -> PaintLayer {
        let bytes = Data(pixels)
        let image = try #require(BGRA8.image(from: bytes, width: width, height: height))
        return PaintLayer(name: "Test", image: image, pdnPixels: bytes)
    }
}
