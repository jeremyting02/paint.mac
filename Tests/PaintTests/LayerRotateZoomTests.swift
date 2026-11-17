import AppKit
import Testing
@testable import Paint

struct LayerRotateZoomTests {
    private let filter = LayerRotateZoom.filter

    private func layer(_ markers: [UInt8], width: Int) throws -> PaintLayer {
        let data = Data(markers.flatMap { [$0, $0, $0, 255] })
        let image = try #require(BGRA8.image(from: data, width: width, height: markers.count / width))
        return PaintLayer(name: "Test", image: image, pdnPixels: data)
    }

    private func render(_ layer: PaintLayer, rotation: Double = 0, direction: Double = 0, tilt: Double = 0,
                        x: Double = 0, y: Double = 0, zoom: Double = 100, quality: Double = 1,
                        tiling: Double = 0, nearest: Bool = true, selection: SelectionOutline? = nil) throws -> Data {
        let input = try #require(RasterFilter.Input(layer: layer, selection: selection))
        let output = try #require(input.render(filter, values: [rotation, direction, tilt, x, y, zoom, quality, tiling, nearest ? 1 : 0]))
        return try #require(output.pdnPixels)
    }

    private func markers(_ bytes: Data) -> [UInt8] {
        stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }
    }

    @Test func layerRotationAndZoomUseTheCanvasCenter() throws {
        let image = try layer([10, 20, 30, 40, 50, 60], width: 3)
        #expect(try render(image) == image.pdnPixels)
        #expect(try markers(render(image, rotation: 180)) == [60, 50, 40, 30, 20, 10])
        let line = try layer([10, 20, 30, 40, 50], width: 5)
        #expect(try markers(render(line, zoom: 250)) == [20, 30, 30, 30, 40])
    }

    @Test func layerPanningUsesTheChosenTilingMode() throws {
        let image = try layer([10, 20, 30, 40], width: 4)
        #expect(try markers(render(image, x: 25)) == [0, 10, 20, 30])
        #expect(try markers(render(image, x: 25, tiling: 1)) == [40, 10, 20, 30])
        #expect(try markers(render(image, x: 25, tiling: 2)) == [10, 10, 20, 30])
        #expect(LayerRotateZoom.filter.controls[7].choices == ["Transparent", "Repeat", "Mirror"])
    }

    @Test func selectionClipsThePreviewAndBilinearPanAntialiases() throws {
        let image = try layer([100, 200, 40, 80], width: 4)
        let selection = try #require(SelectionOutline(rect: CGRect(x: 1, y: 0, width: 1, height: 1)))
        #expect(try markers(render(image, x: 25, selection: selection)) == [100, 100, 40, 80])
        let interpolated = try render(image, x: 12.5, nearest: false)
        #expect(Array(interpolated.prefix(4)) == [100, 100, 100, 128])
        #expect(markers(interpolated) == [100, 150, 120, 60])
        #expect(LayerRotateZoom.filter.controls.last?.choices == ["Bilinear", "Nearest Neighbor"])
    }

    @Test func tiltDirectionChangesThePerspectiveAndEdgeOnTiltIsTransparent() throws {
        let image = try layer(Array(repeating: 150, count: 25), width: 5)
        let horizontal = try render(image, tilt: 65)
        let vertical = try render(image, direction: 90, tilt: 65)
        #expect(horizontal != vertical)
        #expect(horizontal[12 * 4] == 150)
        #expect(try render(image, tilt: 90) == Data(count: 25 * 4))
    }

    @Test func renderStopsAfterCancellation() throws {
        let image = try layer(Array(repeating: 150, count: 128), width: 128)
        let input = try #require(RasterFilter.Input(layer: image, selection: nil))
        var polls = 0
        let rendered = input.render(filter, values: [3, 20, 30, 0, 0, 100, 4, 0, 0]) {
            polls += 1
            return polls >= 3
        }
        #expect(rendered == nil)
        #expect(polls == 3)
    }

    @MainActor @Test func committingRotateZoomOnlyEditsTheActiveLayerAndIsUndoable() throws {
        let bottom = try layer([30, 10, 20, 40], width: 4)
        let top = try layer([10, 20, 30, 40], width: 4)
        let document = PaintDocument()
        try document.read(from: PDNFile.write(LayerStack(layers: [bottom, top], active: 1)), ofType: "Paint.NET Project")
        document.undoManager?.groupsByEvent = false
        let input = try #require(document.filterInput())
        let values: [Double] = [0, 0, 0, 25, 0, 100, 1, 0, 1]
        let preview = try #require(input.render(filter, values: values))
        #expect(document.stack?.activeLayer.pdnPixels == top.pdnPixels)
        document.commitFilter(filter, input: input, layer: preview, values: values)
        #expect(document.stack?.layers.first?.pdnPixels == bottom.pdnPixels)
        #expect(document.stack?.activeLayer.pdnPixels == preview.pdnPixels)
        #expect(document.historyEntries == ["Open Image", "Rotate / Zoom"])
        document.undoStroke(nil)
        #expect(document.stack?.activeLayer.pdnPixels == top.pdnPixels)
        document.redoStroke(nil)
        #expect(document.stack?.activeLayer.pdnPixels == preview.pdnPixels)
    }
}
