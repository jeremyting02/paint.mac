import AppKit
import Metal
import Testing
@testable import Paint

struct MetalMovePreviewTests {
    private func layer(width: Int, height: Int, seed: Int, mode: LayerBlendMode = .normal,
                       opacity: UInt8 = 255) throws -> PaintLayer {
        let bytes = Data((0..<(width * height * 4)).map { UInt8(truncatingIfNeeded: $0 * seed + $0 / 17) })
        let image = try #require(BGRA8.image(from: bytes, width: width, height: height))
        return PaintLayer(name: "Synthetic", image: image, opacity: opacity, blendMode: mode, pdnPixels: bytes)
    }

    @Test(arguments: MoveResampler.Mode.allCases)
    func metalRendersMaskedMovesCopiesAndPastes(_ sampling: MoveResampler.Mode) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let width = 290, height = 223
        let stack = LayerStack(layers: [
            try layer(width: width, height: height, seed: 23),
            try layer(width: width, height: height, seed: 113, mode: .overlay, opacity: 211),
            try layer(width: width, height: height, seed: 73, mode: .multiply, opacity: 192)
        ], active: 1)
        let selection = CGRect(x: 41, y: 33, width: 149, height: 127)
        let outline = CGRect(x: selection.minX, y: CGFloat(height) - selection.maxY,
                             width: selection.width, height: selection.height)
        let ellipse = try #require(SelectionOutline(path: CGPath(ellipseIn: outline, transform: nil)))
        let mask = try #require(ellipse.mask(in: selection, imageHeight: height))
        let cut = try #require(SelectedPixelsTransform(layer: stack.activeLayer, selection: selection, mask: mask))
        let pasted = try layer(width: 149, height: 127, seed: 73)
        let paste = try #require(SelectedPixelsTransform(layer: stack.activeLayer, pastedImage: pasted.image, at: selection))
        let visible = CGRect(x: 16, y: 12, width: 251, height: 200)
        let rotate = CGAffineTransform(translationX: 46, y: -31).rotated(by: 0.23)
        let scale = CGAffineTransform(translationX: 39.75, y: 6.25).scaledBy(x: 1.21, y: 0.91)
        for (pixels, transform, copy) in [(cut, rotate, false), (cut, scale, true), (paste, rotate, false)] {
            let metal = try #require(MetalMovePreview(stack: stack, pixels: pixels))
            let cpu = try #require(MoveTilePreview(stack: stack, pixels: pixels))
            let frame = try #require(metal.render(in: visible, by: transform, copy: copy, sampling: sampling))
            let actual = try #require(BGRA8.pixels(from: frame.image))
            let expected = try #require(cpu.compositedPixels(in: frame.region, by: transform, copy: copy, sampling: sampling))
            try #require(actual.count == expected.count)
            let differences = zip(actual, expected).map { abs(Int($0) - Int($1)) }
            // Rotated edges use GPU coverage samples. Most bytes should still agree to within one level.
            #expect(differences.filter { $0 > 1 }.count < actual.count / 100)
            #expect(differences.max() ?? 0 <= (transform == scale ? 2 : 30))
        }
    }

    @MainActor @Test func finishingAndUndoingAMetalPreviewUsesTheSamePixelsAsCPU() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        _ = NSApplication.shared
        let width = 384, height = 288
        let layer = try layer(width: width, height: height, seed: 43)
        let document = PaintDocument()
        try document.read(from: PDNFile.write(LayerStack(layers: [layer], active: 0)), ofType: "Paint.NET Project")
        document.showWindows()
        defer { document.close() }
        let editor = try #require(document.editor)
        editor.layoutSubtreeIfNeeded()
        let canvas = editor.canvas
        canvas.setZoom(nil)
        canvas.updateViewport()
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let outline = try #require(SelectionOutline(rect: bounds))
        let pixels = try #require(SelectedPixelsTransform(layer: layer, selection: bounds))
        let pivot = CGPoint(x: bounds.midX, y: bounds.midY)
        let initial = MoveGeometry(rect: bounds, pivot: pivot)
        var rotated = initial
        rotated.angle = 0.25
        let session = CanvasView.MoveSession(layerIndex: 0, pixels: pixels, outline: outline,
                                            initialGeometry: initial, geometry: rotated, recorded: true)
        let expected = try #require(session.renderedLayer()?.straightPixels)
        document.recordMove(from: nil, to: session, actionName: "Rotate")
        let visible = canvas.visibleRect
        let context = try #require(LayerStack.makeBitmap(width: Int(ceil(visible.width)), height: Int(ceil(visible.height))))
        context.translateBy(x: -visible.minX, y: -visible.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        canvas.draw(visible)
        NSGraphicsContext.restoreGraphicsState()
        #expect(canvas.metalMovePreviewDraws == 1)
        #expect(document.stack?.activeLayer.straightPixels == layer.straightPixels)
        canvas.finishSelection()
        #expect(document.stack?.activeLayer.straightPixels == expected)
        document.undoStroke(nil)
        #expect(document.stack?.activeLayer.straightPixels == layer.straightPixels)
        #expect(canvas.hasPendingMove)
        document.redoStroke(nil)
        #expect(document.stack?.activeLayer.straightPixels == expected)
    }
}
