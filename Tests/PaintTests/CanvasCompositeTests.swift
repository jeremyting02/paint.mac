import AppKit
import Testing
@testable import Paint

struct CanvasCompositeTests {
    @Test func brushReusesTheCompositeUntilDirtyAndKeepsCommittedPixels() throws {
        var stack = try makeStack()
        let compositor = try #require(CanvasComposite(stack: stack))
        let before = try #require(compositor.render(stack: stack))
        let originalPixels = try #require(stack.blendComposite()?.pixels)
        #expect(compositor.render(stack: stack) === before)
        let drawing = try #require(RasterDrawing(layer: stack.activeLayer, operation: .pencil(DrawingColor(.red)),
                                                 diameter: 1, selection: nil))
        drawing.append(CGPoint(x: 127, y: 31))
        let changed = drawing.takeDirtyBounds()
        #expect(changed == CGRect(x: 127, y: 119, width: 1, height: 1))
        #expect(drawing.takeDirtyBounds().isNull)
        compositor.invalidate(changed)
        #expect(compositor.renderedImage == nil)
        let preview = try #require(compositor.render(stack: stack, activePixels: drawing.pixels(in:)))
        stack.layers[stack.active] = try #require(drawing.preview)
        let flat = try #require(stack.blendComposite()?.pixels)
        #expect(BGRA8.pixels(from: preview) == flat)
        #expect(BGRA8.pixels(from: before) == originalPixels)
        compositor.commitActivePixels(try #require(stack.activeLayer.pdnPixels))
        #expect(compositor.render(stack: stack) === preview)
        compositor.invalidate(changed)
        let regenerated = try #require(compositor.render(stack: stack))
        #expect(BGRA8.pixels(from: regenerated) == flat)
    }

    @MainActor @Test(arguments: [100.0, 73.0, 14.0], [false, true])
    func incrementalCanvasMatchesFlattenedDisplay(zoom: Double, singleLayer: Bool) throws {
        _ = NSApplication.shared
        var original = try makeStack()
        if singleLayer {
            let flattened = try #require(original.flattenedLayer())
            original = LayerStack(layers: [flattened], active: 0)
        }
        var changed = original
        let drawing = try #require(RasterDrawing(layer: original.activeLayer, operation: .pencil(DrawingColor(.red)),
                                                 diameter: 1, selection: nil))
        drawing.append(CGPoint(x: 123.5, y: 30.5))
        drawing.append(CGPoint(x: 135.5, y: 30.5))
        changed.layers[changed.active] = try #require(drawing.preview)
        let flat = try #require(changed.flattenedLayer())
        let reference = LayerStack(layers: [flat], active: 0)
        let actual = try display(original, zoom: zoom, stroke: true)
        let expected = try display(reference, zoom: zoom)
        #expect(actual == expected)
    }

    @MainActor @Test func strokeHistoryRestoresMultipleTilesAndTheActiveLayer() throws {
        let stack = try makeStack()
        let document = try #require(PaintDocument.newImage(width: 285, height: 151, resolution: .standard))
        document.undoManager = UndoManager()
        document.undoManager?.groupsByEvent = false
        document.applyEdit(replacingStack: stack, actionName: "Setup")
        let drawing = try #require(RasterDrawing(layer: stack.activeLayer, operation: .pencil(DrawingColor(.red)),
                                                 diameter: 1, selection: nil))
        drawing.append(CGPoint(x: 123.5, y: 24.5))
        drawing.append(CGPoint(x: 135.5, y: 18.5))
        let result = try #require(drawing.preview)
        document.commitRasterDrawing(drawing, layer: result)
        document.selectLayer(2)

        document.undoStroke(nil)
        #expect(document.stack?.active == 1)
        #expect(document.stack?.layers.map(\.straightPixels) == stack.layers.map(\.straightPixels))
        document.redoStroke(nil)
        #expect(document.stack?.active == 2)
        #expect(document.stack?.layers[1].straightPixels == result.straightPixels)
        #expect(document.stack?.layers[1].blendMode == stack.layers[1].blendMode)
        #expect(document.stack?.layers[1].opacity == stack.layers[1].opacity)
    }

    @MainActor private func display(_ stack: LayerStack, zoom: Double, stroke: Bool = false) throws -> Data {
        let document = try #require(PaintDocument.newImage(width: 285, height: 151, resolution: .standard))
        document.applyEdit(replacingStack: stack, actionName: "Setup")
        let canvas = CanvasView(document: document)
        let extent = CGRect(x: 0, y: 0, width: 365, height: 230)
        let scroll = NSScrollView(frame: extent)
        scroll.documentView = canvas
        canvas.setZoom(zoom)
        let viewport = canvas.visibleRect
        func render() throws -> Data {
            try #require(BGRA8.render(width: 365, height: 230) { context in
                context.translateBy(x: -viewport.minX, y: -viewport.minY)
                let previous = NSGraphicsContext.current
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                defer { NSGraphicsContext.current = previous }
                canvas.draw(viewport)
            })
        }
        if stroke {
            canvas.tool = .pencil
            canvas.brushColor = .red
            _ = try render()
            let rect = canvas.canvasImageRect
            let scale = rect.width / 285
            func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
                let point = canvas.convert(CGPoint(x: rect.minX + x * scale, y: rect.minY + 30.5 * scale), to: nil)
                return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                       clickCount: 1, pressure: 1))
            }
            canvas.mouseDown(with: try event(.leftMouseDown, x: 123.5))
            canvas.mouseDragged(with: try event(.leftMouseDragged, x: 135.5))
        }
        return try render()
    }

    private func makeStack() throws -> LayerStack {
        let width = 285, height = 151
        let layers = try [0, 1, 2].map { index in
            var pixels = Data(count: width * height * 4)
            pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                for i in 0..<(width * height) {
                    target[i * 4] = UInt8(truncatingIfNeeded: i + index)
                    target[i * 4 + 1] = UInt8(truncatingIfNeeded: i / 2 + index)
                    target[i * 4 + 2] = UInt8(truncatingIfNeeded: i + index * 53)
                    target[i * 4 + 3] = i.isMultiple(of: 3) ? 0 : UInt8(truncatingIfNeeded: i + index)
                }
            }
            let image = try #require(BGRA8.image(from: pixels, width: width, height: height))
            return PaintLayer(name: "Layer", image: image, opacity: index == 0 ? 255 : 187,
                              blendMode: index == 1 ? .multiply : .normal, pdnPixels: pixels)
        }
        return LayerStack(layers: layers, active: 1)
    }
}
