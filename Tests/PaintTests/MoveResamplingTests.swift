import AppKit
import Testing
@testable import Paint

struct MoveResamplingTests {
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
        var session = CanvasView.MoveSession(layerIndex: 0, pixels: pixels, outline: outline,
                                            initialGeometry: MoveGeometry(rect: initial, pivot: CGPoint(x: 3, y: 5.5)),
                                            geometry: MoveGeometry(rect: expanded, pivot: CGPoint(x: 4, y: 5.5)),
                                            recorded: true)
        session.preview = pixels.transformed(by: session.transform)
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
