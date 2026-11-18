import AppKit
import Testing
@testable import Paint

struct MoveResamplingTests {
    @Test func integralWholeLayerMoveReusesImageAndClipsCommittedPixels() throws {
        let color: [UInt8] = [13, 65, 205, 192]
        let source = try makeLayer(width: 8, height: 8, points: [(0, 5, color), (7, 2, color)])
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let move = try #require(SelectedPixelsTransform(layer: source, selection: bounds))
        let translation = CGAffineTransform(translationX: 2, y: 1)
        #expect(move.retainedImageOffset(by: translation, copy: false) == CGPoint(x: 2, y: 1))
        #expect(move.retainedImageOffset(by: translation, copy: true) == nil)
        #expect(move.retainedImageOffset(by: CGAffineTransform(translationX: 0.5, y: 1), copy: false) == nil)
        let committed = try #require(move.transformed(by: translation)?.straightPixels)
        #expect(pixel(committed, width: 8, x: 2, y: 4) == color)
        #expect(committed.enumerated().filter { $0.offset % 4 == 3 && $0.element > 0 }.count == 1)
        let patch = try #require(move.renderedPixels(in: CGRect(x: 1, y: 3, width: 2, height: 2),
                                                      by: translation, copy: false, sampling: .bicubic))
        #expect(pixel(patch, width: 2, x: 1, y: 1) == color)
        let copied = try #require(move.transformed(by: translation, copy: true)?.straightPixels)
        #expect(pixel(copied, width: 8, x: 0, y: 5) == color)
    }

    @Test func parallelMovePreviewPublishesTheSameTilesAsSerialRendering() throws {
        let bounds = CGRect(x: 0, y: 0, width: 512, height: 384)
        let source = try makeLayer(width: 512, height: 384, points: [
            (96, 107, [13, 65, 205, 192]), (283, 247, [43, 90, 164, 221])
        ])
        let pixels = try #require(SelectedPixelsTransform(layer: source, selection: bounds))
        let preview = try #require(MoveTilePreview(stack: LayerStack(layers: [source], active: 0), pixels: pixels))
        for transform in [CGAffineTransform(translationX: 24, y: -18), CGAffineTransform(rotationAngle: 0.14)] {
            let tiles = preview.tiles(in: bounds, by: transform, copy: false, sampling: .bicubic)
            #expect(tiles.count == 12)
            for tile in tiles {
                let serial = preview.compositedPixels(in: tile.padded, by: transform, copy: false, sampling: .bicubic)
                let rendered = BGRA8.pixels(from: tile.image)
                #expect(rendered != nil)
                #expect(rendered == serial)
            }
        }
    }

    @Test(arguments: MoveResampler.Mode.allCases)
    func fractionalMovePreservesColorAndDistributesAlpha(_ mode: MoveResampler.Mode) throws {
        let color: [UInt8] = [13, 65, 205, 192]
        let source = try makeLayer(width: 8, height: 8, points: [(2, 2, color)])
        let move = try #require(SelectedPixelsTransform(layer: source, selection: CGRect(x: 2, y: 2, width: 1, height: 1)))
        let shifted = try #require(move.transformed(by: CGAffineTransform(translationX: 0.25, y: -0.5),
                                                     sampling: mode)?.straightPixels)
        for y in 2...3 {
            #expect(pixel(shifted, width: 8, x: 2, y: y) == [13, 65, 205, 72])
            #expect(pixel(shifted, width: 8, x: 3, y: y) == [13, 65, 205, 24])
        }
        #expect(pixel(shifted, width: 8, x: 4, y: 2) == [0, 0, 0, 0])
        #expect(source.straightPixels.map { pixel($0, width: 8, x: 2, y: 2) } == color)
    }

    @Test func scalingModesSampleTranslucentNeighborsDifferently() throws {
        let red: [UInt8] = [0, 0, 255, 128], blue: [UInt8] = [255, 0, 0, 64]
        let source = try makeLayer(width: 8, height: 8, points: [(2, 2, red), (3, 2, blue)])
        let move = try #require(SelectedPixelsTransform(layer: source, selection: CGRect(x: 2, y: 2, width: 2, height: 1)))
        let scale = CGAffineTransform(a: 2, b: 0, c: 0, d: 1, tx: -2, ty: 0)
        let nearest = try #require(move.transformed(by: scale, sampling: .antialiasedNearest)?.straightPixels)
        #expect((2...5).map { pixel(nearest, width: 8, x: $0, y: 2) } == [red, red, blue, blue])
        let cubic = try #require(move.transformed(by: scale)?.straightPixels)
        #expect(pixel(cubic, width: 8, x: 3, y: 2) == [29, 0, 226, 115])
        #expect(pixel(cubic, width: 8, x: 4, y: 2) == [169, 0, 86, 77])
    }

    @Test(arguments: MoveResampler.Mode.allCases)
    func rotationUsesTheSelectionCoverageAndClipsAtCanvasEdge(_ mode: MoveResampler.Mode) throws {
        let color: [UInt8] = [26, 79, 181, 176]
        let source = try makeLayer(width: 8, height: 8, points: [(0, 4, color), (1, 4, color),
                                                             (0, 5, color), (1, 5, color)])
        let move = try #require(SelectedPixelsTransform(layer: source, selection: CGRect(x: 0, y: 4, width: 2, height: 2)))
        let rotate = CGAffineTransform(translationX: 1, y: 3).rotated(by: .pi / 4).translatedBy(x: -1, y: -3)
        let rotated = try #require(move.transformed(by: rotate, sampling: mode)?.straightPixels)
        let samples = (0..<64).map { pixel(rotated, width: 8, x: $0 % 8, y: $0 / 8) }.filter { $0[3] > 0 }
        #expect(samples.count == 10)
        #expect(samples.allSatisfy { Array($0.prefix(3)) == Array(color.prefix(3)) })
        #expect(samples.contains { $0[3] < color[3] })
        #expect(samples.map { Int($0[3]) }.reduce(0, +) < 4 * Int(color[3]))
    }

    @Test func bicubicReflectionMatchesScaledPixelsWithClippingAndPaddedSource() throws {
        let stride = 28, canvasHeight = 8
        let source = Data((0..<(stride * canvasHeight)).map { UInt8(truncatingIfNeeded: $0 * 97) })
        let selection = CGRect(x: 2, y: 1, width: 3, height: 6)
        let start = stride + 8
        let scale = CGAffineTransform(a: 1.5, b: 0, c: 0, d: 1.25, tx: -0.75, ty: -1)
        let full = try #require(MoveResampler.sample(
            source, stride: stride, start: start, selection: selection, transform: scale,
            region: CGRect(x: 2, y: 0, width: 5, height: 8), canvasHeight: canvasHeight, mode: .bicubic
        ))
        let flip = CGAffineTransform(a: 1.5, b: 0, c: 0, d: -1.25, tx: -0.75, ty: 9)
        let clipped = try #require(MoveResampler.sample(
            source, stride: stride, start: start, selection: selection, transform: flip,
            region: CGRect(x: 3, y: 0, width: 4, height: 7), canvasHeight: canvasHeight, mode: .bicubic
        ))
        var expected = Data()
        for row in (1...7).reversed() {
            let offset = row * 20 + 4
            expected.append(full[offset..<(offset + 16)])
        }
        #expect(clipped == expected)
    }

    @MainActor @Test func changingSamplerUpdatesAndUndoesTheLivePreview() throws {
        _ = NSApplication.shared
        let source = try makeLayer(width: 8, height: 8, points: [(2, 2, [0, 0, 255, 128]), (3, 2, [255, 0, 0, 64])])
        let document = PaintDocument()
        try document.read(from: PDNFile.write(LayerStack(layers: [source], active: 0)), ofType: "Paint.NET Project")
        document.makeWindowControllers()
        defer { document.close() }
        let canvas = try #require(document.editor?.canvas)
        let initial = CGRect(x: 2, y: 5, width: 2, height: 1)
        let outline = try #require(SelectionOutline(rect: initial))
        canvas.setSelection(outline)
        let pixels = try #require(SelectedPixelsTransform(layer: source, selection: CGRect(x: 2, y: 2, width: 2, height: 1)))
        let expanded = CGRect(x: 2, y: 5, width: 4, height: 1)
        let session = CanvasView.MoveSession(layerIndex: 0, pixels: pixels, outline: outline,
                                            initialGeometry: MoveGeometry(rect: initial, pivot: CGPoint(x: 3, y: 5.5)),
                                            geometry: MoveGeometry(rect: expanded, pivot: CGPoint(x: 4, y: 5.5)),
                                            recorded: true)
        document.recordMove(from: nil, to: session, actionName: "Resize Selected Pixels")
        let cubic = try #require(canvas.copyableLayer?.straightPixels)
        canvas.setMoveSampling(.antialiasedNearest)
        let nearest = try #require(canvas.copyableLayer?.straightPixels)
        #expect(nearest != cubic)
        #expect(document.stack?.activeLayer.straightPixels == source.straightPixels)
        document.undoStroke(nil)
        #expect(canvas.moveSampling == .bicubic)
        #expect(canvas.copyableLayer?.straightPixels == cubic)
        document.redoStroke(nil)
        #expect(canvas.moveSampling == .antialiasedNearest)
        #expect(canvas.copyableLayer?.straightPixels == nearest)
        canvas.finishSelection()
        #expect(document.stack?.activeLayer.straightPixels == nearest)
    }

    @Test(arguments: MoveResampler.Mode.allCases)
    func moveTilesMatchFullCompositesAcrossBlendModes(_ sampling: MoveResampler.Mode) throws {
        let width = 290, height = 223
        let size = width * height * 4
        func layer(_ seed: Int, blendMode: LayerBlendMode = .normal, opacity: UInt8 = 255) throws -> PaintLayer {
            let pixels = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * seed + $0 / 17) })
            let image = try #require(BGRA8.image(from: pixels, width: width, height: height))
            return PaintLayer(name: "Synthetic", image: image, opacity: opacity, blendMode: blendMode, pdnPixels: pixels)
        }
        let stack = LayerStack(layers: [
            try layer(23), try layer(113, blendMode: .overlay, opacity: 211),
            try layer(73, blendMode: .multiply, opacity: 192)
        ], active: 1)
        let selection = CGRect(x: 92, y: 73, width: 149, height: 127)
        let outline = CGRect(x: selection.minX, y: CGFloat(height) - selection.maxY,
                             width: selection.width, height: selection.height)
        let ellipse = try #require(SelectionOutline(path: CGPath(ellipseIn: outline, transform: nil)))
        let mask = try #require(ellipse.mask(in: selection, imageHeight: height))
        let pixels = try #require(SelectedPixelsTransform(layer: stack.activeLayer, selection: selection, mask: mask))
        let preview = try #require(MoveTilePreview(stack: stack, pixels: pixels))
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let scenarios: [(CGAffineTransform, Bool)] = [
            (CGAffineTransform(translationX: 15, y: -38), false),
            (CGAffineTransform(translationX: 32.25, y: 40.5), true),
            (CGAffineTransform(translationX: 46, y: -31).rotated(by: 0.23).scaledBy(x: 1.21, y: 0.91), false),
            (CGAffineTransform(translationX: -180, y: 140), false),
        ]
        for (transform, copy) in scenarios {
            let moved = try #require(pixels.transformed(by: transform, copy: copy, sampling: sampling))
            var next = stack
            next.layers[next.active] = moved
            let full = try #require(next.blendComposite()?.pixels)
            var reconstructed = try #require(stack.blendComposite()?.pixels)
            for tile in preview.tiles(in: canvas, by: transform, copy: copy, sampling: sampling) {
                let patch = try #require(BGRA8.pixels(from: tile.image))
                let left = Int(tile.core.minX - tile.padded.minX)
                let top = Int(tile.core.minY - tile.padded.minY)
                let rowBytes = Int(tile.core.width) * 4
                for y in 0..<Int(tile.core.height) {
                    let source = ((top + y) * Int(tile.padded.width) + left) * 4
                    let destination = ((Int(tile.core.minY) + y) * width + Int(tile.core.minX)) * 4
                    reconstructed.replaceSubrange(destination..<(destination + rowBytes),
                                                  with: patch[source..<(source + rowBytes)])
                }
            }
            #expect(reconstructed == full)
        }
    }

    @MainActor @Test func moveTruncatesDragAndCommitsFinalPointerWithoutDrawing() throws {
        _ = NSApplication.shared
        let source = try makeLayer(width: 96, height: 80, points: [
            (25, 35, [23, 71, 191, 166]), (30, 41, [193, 67, 13, 221])
        ])
        let document = PaintDocument()
        try document.read(from: PDNFile.write(LayerStack(layers: [source], active: 0)), ofType: "Paint.NET Project")
        document.showWindows()
        defer { document.close() }
        let editor = try #require(document.editor)
        editor.layoutSubtreeIfNeeded()
        let canvas = editor.canvas
        canvas.setZoom(100)
        canvas.updateViewport()
        canvas.tool = .moveSelectedPixels
        canvas.setSelection(SelectionOutline(rect: CGRect(x: 16, y: 32, width: 40, height: 24)))
        let rect = canvas.canvasImageRect
        let scale = rect.width / CGFloat(source.image.width)
        let window = try #require(canvas.window)
        func event(_ type: NSEvent.EventType, dx: CGFloat, dy: CGFloat) throws -> NSEvent {
            let location = canvas.convert(CGPoint(x: rect.minX + (43 + dx) * scale,
                                                  y: rect.minY + (43 + dy) * scale), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let originalHistory = document.historyEntries
        canvas.mouseDown(with: try event(.leftMouseDown, dx: 0, dy: 0))
        canvas.mouseDragged(with: try event(.leftMouseDragged, dx: 0.75, dy: -0.75))
        #expect(canvas.move?.hasPixelPreview == false)
        canvas.mouseUp(with: try event(.leftMouseUp, dx: 0.75, dy: -0.75))
        #expect(canvas.move == nil)
        #expect(document.historyEntries == originalHistory)

        canvas.mouseDown(with: try event(.leftMouseDown, dx: 0, dy: 0))
        canvas.mouseDragged(with: try event(.leftMouseDragged, dx: 4.75, dy: -2.75))
        #expect(canvas.move?.transform == CGAffineTransform(translationX: 4, y: -2))
        canvas.mouseUp(with: try event(.leftMouseUp, dx: 9.75, dy: -3.75))
        let transform = CGAffineTransform(translationX: 9, y: -3)
        let pixels = try #require(SelectedPixelsTransform(layer: source,
                                                           selection: CGRect(x: 16, y: 24, width: 40, height: 24)))
        let expected = try #require(pixels.transformed(by: transform)?.straightPixels)
        #expect(canvas.move?.transform == transform)
        #expect(document.stack?.activeLayer.straightPixels == source.straightPixels)
        #expect(canvas.copyableLayer?.straightPixels == expected)
        document.undoStroke(nil)
        #expect(canvas.move == nil)
        document.redoStroke(nil)
        #expect(canvas.move?.transform == transform)
        canvas.finishSelection()
        #expect(document.stack?.activeLayer.straightPixels == expected)
        document.undoStroke(nil)
        #expect(canvas.copyableLayer?.straightPixels == expected)
        #expect(document.stack?.activeLayer.straightPixels == source.straightPixels)
    }

    @MainActor @Test(arguments: [false, true])
    func shiftResizeKeepsTheLiveAspectRatio(movesPixels: Bool) throws {
        _ = NSApplication.shared
        let source = try makeLayer(width: 96, height: 80, points: [(32, 40, [23, 71, 191, 255])])
        let document = PaintDocument()
        try document.read(from: PDNFile.write(LayerStack(layers: [source], active: 0)), ofType: "Paint.NET Project")
        document.showWindows()
        defer { document.close() }
        let editor = try #require(document.editor)
        editor.layoutSubtreeIfNeeded()
        let canvas = editor.canvas
        canvas.setZoom(200)
        canvas.updateViewport()
        canvas.tool = movesPixels ? .moveSelectedPixels : .moveSelection
        canvas.setSelection(SelectionOutline(rect: CGRect(x: 16, y: 24, width: 40, height: 32)))
        let imageRect = canvas.canvasImageRect
        let scale = imageRect.width / CGFloat(source.image.width)
        let window = try #require(canvas.window)
        func event(_ type: NSEvent.EventType, x: CGFloat, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let location = canvas.convert(CGPoint(x: imageRect.minX + x * scale,
                                                  y: imageRect.minY + 40 * scale), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1))
        }

        let originalHistory = document.historyEntries
        canvas.mouseDown(with: try event(.leftMouseDown, x: 56, modifiers: .shift))
        canvas.mouseUp(with: try event(.leftMouseUp, x: 56, modifiers: .shift))
        #expect(canvas.move == nil)
        #expect(document.historyEntries == originalHistory)

        canvas.mouseDown(with: try event(.leftMouseDown, x: 56))
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 66))
        let freeRect = try #require(canvas.move?.geometry.rect)
        #expect(freeRect == CGRect(x: 16, y: 24, width: 50, height: 32))
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 66, modifiers: .shift))
        #expect(canvas.move?.geometry.rect == freeRect)
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 91, modifiers: .shift))
        let constrainedRect = try #require(canvas.move?.geometry.rect)
        #expect(constrainedRect == CGRect(x: 16, y: 16, width: 75, height: 48))
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 91))
        #expect(canvas.move?.geometry.rect == constrainedRect)
        canvas.mouseUp(with: try event(.leftMouseUp, x: 94))
        #expect(canvas.move?.geometry.rect == CGRect(x: 16, y: 16, width: 78, height: 48))
        #expect(document.historyEntries.count == originalHistory.count + 1)
        document.undoStroke(nil)
        #expect(canvas.move == nil)
        document.redoStroke(nil)
        #expect(canvas.move?.geometry.rect == CGRect(x: 16, y: 16, width: 78, height: 48))
    }

    private func makeLayer(width: Int, height: Int, points: [(x: Int, y: Int, bgra: [UInt8])]) throws -> PaintLayer {
        var bytes = Data(count: width * height * 4)
        for point in points {
            let start = (point.y * width + point.x) * 4
            bytes.replaceSubrange(start..<(start + 4), with: point.bgra)
        }
        let image = try #require(BGRA8.image(from: bytes, width: width, height: height))
        return PaintLayer(name: "Synthetic translucent pixels", image: image, pdnPixels: bytes)
    }

    private func pixel(_ bytes: Data, width: Int, x: Int, y: Int) -> [UInt8] {
        let start = (y * width + x) * 4
        return Array(bytes[start..<(start + 4)])
    }
}
