import AppKit
import ImageIO
import Testing
@testable import Paint

@MainActor struct ImageOperationTests {
    private func makeLayer(_ markers: [UInt8], width: Int, name: String = "Test") throws -> PaintLayer {
        let pixels = Data(markers.flatMap { [$0, $0, $0, $0] })
        let image = try #require(BGRA8.image(from: pixels, width: width, height: markers.count / width))
        return PaintLayer(name: name, image: image, pdnPixels: pixels)
    }

    private func markers(_ layer: PaintLayer) throws -> [UInt8] {
        let data = try #require(layer.pdnPixels)
        return stride(from: 0, to: data.count, by: 4).map { data[$0] }
    }

    @Test func testAllOrientationsMoveExactPixelsAndPreserveLayerProperties() throws {
        let bottom = try makeLayer([1, 2, 3, 4, 5, 6], width: 3, name: "Bottom")
        var top = try makeLayer([11, 12, 13, 14, 15, 16], width: 3, name: "Top")
        top.opacity = 77
        top.blendMode = .multiply
        top.isVisible = false
        let previous = LayerStack(layers: [bottom, top], active: 1)
        let expected: [ImageOrientationEdit: [UInt8]] = [
            .flipHorizontal: [3, 2, 1, 6, 5, 4], .flipVertical: [4, 5, 6, 1, 2, 3],
            .clockwise: [4, 1, 5, 2, 6, 3], .counterClockwise: [3, 6, 2, 5, 1, 4],
            .halfTurn: [6, 5, 4, 3, 2, 1]
        ]
        for edit in ImageOrientationEdit.allCases {
            let next = try previous.reoriented(edit)
            let expectedBottom = try #require(expected[edit])
            #expect(try markers(next.layers[0]) == expectedBottom)
            #expect(try markers(next.layers[1]) == expectedBottom.map { $0 + 10 })
            #expect(next.active == previous.active)
            #expect(next.activeLayer.name == top.name)
            #expect(next.activeLayer.opacity == top.opacity)
            #expect(next.activeLayer.blendMode == top.blendMode)
            #expect(!next.activeLayer.isVisible)
            #expect(next.activeLayer.image.width == (edit.swapsDimensions ? 2 : 3))
        }
        let layerOnly = try previous.reoriented(.flipHorizontal, activeOnly: true)
        #expect(layerOnly.layers[0].pdnPixels == bottom.pdnPixels)
        #expect(try markers(layerOnly.activeLayer) == [13, 12, 11, 16, 15, 14])
        #expect(try markers(previous.reoriented(.flipVertical, activeOnly: true).activeLayer) == [14, 15, 16, 11, 12, 13])
        #expect(try markers(previous.reoriented(.halfTurn, activeOnly: true).activeLayer) == [16, 15, 14, 13, 12, 11])
    }

    @Test func testCanvasResizePadsBottomLayerWithFillAndCropsUsingAnchor() throws {
        let bottom = try makeLayer([1, 2, 3, 4], width: 2, name: "Bottom")
        let top = try makeLayer([5, 6, 7, 8], width: 2, name: "Top")
        let stack = LayerStack(layers: [bottom, top], active: 1)
        let bigger = try stack.resizedCanvas(width: 3, height: 3, anchor: .bottomRight, fill: 0xff000063)
        #expect(try markers(bigger.layers[0]) == [99, 99, 99, 99, 1, 2, 99, 3, 4])
        #expect(try markers(bigger.layers[1]) == [0, 0, 0, 0, 5, 6, 0, 7, 8])
        let smaller = try bigger.resizedCanvas(width: 2, height: 2, anchor: .bottomRight)
        #expect(smaller.layers.map(\.pdnPixels) == stack.layers.map(\.pdnPixels))
        let centered = try stack.resizedCanvas(width: 4, height: 4, anchor: .center)
        #expect(try markers(centered.layers[0]) == [0, 0, 0, 0, 0, 1, 2, 0, 0, 3, 4, 0, 0, 0, 0, 0])
        #expect(throws: (any Error).self) { try stack.resizedCanvas(width: 4096, height: 4096, anchor: .center) }
    }

    @Test func testNearestResizePreservesStraightAlphaBytesAndDimensionsAcrossLayers() throws {
        let bottom = try makeLayer([1, 2, 3, 4], width: 2)
        let top = try makeLayer([5, 6, 7, 8], width: 2)
        let source = LayerStack(layers: [bottom, top], active: 1)
        let result = try source.resizedImage(width: 4, height: 2, sampling: .nearest, linearLight: true)
        #expect(try markers(result.layers[0]) == [1, 1, 2, 2, 3, 3, 4, 4])
        #expect(try markers(result.layers[1]) == [5, 5, 6, 6, 7, 7, 8, 8])
        #expect(result.activeLayer.image.width == 4)
        #expect(throws: (any Error).self) { try source.resizedImage(width: 0, height: 2, sampling: .nearest, linearLight: false) }
    }

    @Test func testEveryResamplingModeKeepsAConstantColor() {
        let color: [UInt8] = [20, 80, 180, 110]
        let pixels = Data(Array(repeating: color, count: 12).flatMap { $0 })
        let expected = Data(Array(repeating: color, count: 10).flatMap { $0 })
        for mode in ImageResampler.Mode.allCases {
            let resampler = ImageResampler(sourceWidth: 4, sourceHeight: 3, width: 2, height: 5,
                                           mode: mode, linearLight: true)
            #expect(resampler.resample(pixels) == expected, "\(mode.rawValue)")
        }
    }

    @Test func testGammaCorrectionAndTransparentNeighborsDuringResize() {
        let ordinary = ImageResampler(sourceWidth: 2, sourceHeight: 1, width: 1, height: 1,
                                      mode: .fant, linearLight: false)
        let linear = ImageResampler(sourceWidth: 2, sourceHeight: 1, width: 1, height: 1,
                                    mode: .fant, linearLight: true)
        let blackAndWhite = Data([0, 0, 0, 255, 255, 255, 255, 255])
        #expect(ordinary.resample(blackAndWhite) == Data([128, 128, 128, 255]))
        #expect(linear.resample(blackAndWhite) == Data([188, 188, 188, 255]))
        #expect(ordinary.resample(Data([0, 0, 255, 255, 255, 0, 0, 0])) == Data([0, 0, 255, 128]))
    }

    @Test func cancelledResamplingDiscardsThePartialImage() {
        let source = Data(repeating: 255, count: 8 * 8 * 4)
        for mode in [ImageResampler.Mode.nearest, .bicubic] {
            let resampler = ImageResampler(sourceWidth: 8, sourceHeight: 8, width: 4, height: 4,
                                           mode: mode, linearLight: true)
            var checks = 0
            let result = resampler.resample(source) {
                checks += 1
                return checks >= 3
            }
            #expect(result == nil)
        }
    }

    @Test func testDocumentImageCommandsUndoAndRedoAsSingleEdits() throws {
        let layer = try makeLayer([1, 2, 3, 4, 5, 6], width: 3)
        let document = PaintDocument()
        try document.read(from: PDNFile.write(LayerStack(layers: [layer], active: 0)), ofType: "Paint.NET Project")
        document.undoManager?.groupsByEvent = false
        document.performOrientation(.clockwise)
        #expect(document.historyEntries == ["Open Image", "Rotate 90° Clockwise"])
        #expect(try document.stack.map { try markers($0.activeLayer) } == [4, 1, 5, 2, 6, 3])
        document.performResize(width: 3, height: 4, canvasOnly: true, anchor: .topLeft)
        #expect(document.image?.width == 3)
        document.undoStroke(nil)
        #expect(document.image?.width == 2)
        document.undoStroke(nil)
        #expect(document.stack?.activeLayer.pdnPixels == layer.pdnPixels)
        document.redoStroke(nil)
        document.redoStroke(nil)
        #expect(document.image?.height == 4)
        #expect(document.historyEntries.last == "Canvas Size")
        let saved = try document.data(ofType: "Paint.NET Project")
        let reopened = try PDNFile.read(saved)
        #expect(reopened.activeLayer.pdnPixels == document.stack?.activeLayer.pdnPixels)
    }

    @Test func testStaticImageCodecsOpenInDocumentAndImportAsLayers() throws {
        let color: [UInt8] = [31, 90, 200, 255]
        let pixels = Data(Array(repeating: color, count: 64 * 64).flatMap { $0 })
        let image = try #require(BGRA8.image(from: pixels, width: 64, height: 64))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for format in RasterFormat.writable where RasterFormat.readable.contains(format) {
            guard let data = try? PaintFiles.rasterData(image, as: format, quality: 1) else {
                Issue.record("Image I/O advertised but failed to encode \(format.rawValue).")
                continue
            }
            let document = PaintDocument()
            try document.read(from: data, ofType: "Bitmap Image")
            #expect(document.image?.width == 64, "\(format.rawValue)")
            #expect(document.image?.height == 64, "\(format.rawValue)")
            let url = directory.appendingPathComponent("Fixture").appendingPathExtension(format.filenameExtension)
            try data.write(to: url)
            let layers = try PaintFiles.layersForImport(from: url)
            #expect(layers.first?.name == "Fixture: Background")
            #expect(layers.first?.image.height == 64)
            if [.png, .tiff, .bmp, .gif, .tga].contains(format) {
                #expect(document.image.flatMap { BGRA8.pixels(from: $0) } == pixels, "\(format.rawValue)")
            }
        }
    }

    @Test func testOpenAppliesExifOrientationAndPreservesDocumentOnDecodeFailure() throws {
        let image = try #require(BGRA8.image(from: Data(repeating: 255, count: 8), width: 2, height: 1))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, RasterFormat.jpeg.rawValue as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let document = PaintDocument()
        try document.read(from: encoded as Data, ofType: RasterFormat.jpeg.rawValue)
        #expect(document.image?.width == 1)
        #expect(document.image?.height == 2)
        #expect(throws: (any Error).self) { try document.read(from: encoded as Data, ofType: RasterFormat.png.rawValue) }
        #expect(throws: (any Error).self) { try document.read(from: Data([1, 2, 3]), ofType: "Bitmap Image") }
        #expect(document.image?.height == 2)
    }

    @Test func testAnimatedGIFOpensItsFirstFrame() throws {
        let first = try #require(BGRA8.image(from: Data([0, 0, 0, 255]), width: 1, height: 1))
        let second = try #require(BGRA8.image(from: Data([255, 255, 255, 255]), width: 1, height: 1))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, RasterFormat.gif.rawValue as CFString, 2, nil))
        CGImageDestinationAddImage(destination, first, nil)
        CGImageDestinationAddImage(destination, second, nil)
        #expect(CGImageDestinationFinalize(destination))
        let image = try PaintFiles.readRaster(encoded as Data)
        #expect(BGRA8.pixels(from: image) == Data([0, 0, 0, 255]))
    }

    @Test func testCopyFlattenedUsesVisibleLayersAndDoesNotAlterSource() throws {
        var bottom = try makeLayer([255], width: 1, name: "Bottom")
        bottom.isVisible = false
        var top = try makeLayer([255], width: 1, name: "Top")
        top.opacity = 128
        let stack = LayerStack(layers: [bottom, top], active: 1)
        let flattened = try #require(stack.copyingFlattened(preview: top))
        #expect(flattened.straightPixels == Data([255, 255, 255, 128]))
        #expect(stack.layers.count == 2)
        #expect(stack.activeLayer.opacity == 128)
    }

    @Test func testPasteIntoNewLayerStartsAboveActiveLayerAndUndoRemovesIt() throws {
        _ = NSApplication.shared
        let bottom = try makeLayer([255], width: 1, name: "Bottom")
        let top = try makeLayer([40], width: 1, name: "Top")
        let document = PaintDocument()
        try document.read(from: PDNFile.write(LayerStack(layers: [top, bottom], active: 1)), ofType: "Paint.NET Project")
        document.makeWindowControllers()
        defer { document.close() }
        document.selectLayer(0)
        document.performPaste(bottom.image, intoNewLayer: true, expand: false)
        #expect(document.stack?.layers.map(\.name) == ["Top", "Layer 1", "Bottom"])
        #expect(document.stack?.active == 1)
        #expect(document.editor?.canvas.move?.isPaste == true)
        #expect(document.historyEntries == ["Open Image", "Paste into New Layer"])
        document.undoStroke(nil)
        #expect(document.stack?.layers.map(\.name) == ["Top", "Bottom"])
        #expect(document.stack?.active == 0)
        document.redoStroke(nil)
        #expect(document.stack?.layers.count == 3)
        #expect(document.editor?.canvas.move?.isPaste == true)
    }

    @Test func testLargerPasteCanExpandCanvasAndUndoItTogether() throws {
        _ = NSApplication.shared
        let source = try makeLayer([255], width: 1)
        let pasted = try makeLayer([125, 155, 185], width: 3)
        let document = PaintDocument()
        try document.read(from: PDNFile.write(LayerStack(layers: [source], active: 0)), ofType: "Paint.NET Project")
        document.makeWindowControllers()
        defer { document.close() }
        document.performPaste(pasted.image, intoNewLayer: false, expand: true)
        #expect(document.image?.width == 3)
        #expect(document.editor?.canvas.move?.geometry.rect == CGRect(x: 0, y: 0, width: 3, height: 1))
        #expect(document.historyEntries == ["Open Image", "Paste"])
        document.undoStroke(nil)
        #expect(document.image?.width == 1)
        #expect(document.editor?.canvas.move == nil)
    }

    @Test func testPasteNewImageCreatesADocumentMatchingTheDecodedImageSize() throws {
        _ = NSApplication.shared
        let image = try makeLayer([255, 128, 64, 200, 100, 50], width: 3).image
        let png = try PaintFiles.pngData(image)
        let clipboardImage = try #require(PaintFiles.readClipboardImage(png))
        let result = try #require(PaintDocument.makePastedImage(from: clipboardImage))
        defer { result.close() }
        #expect(result.image?.width == 3)
        #expect(result.image?.height == 2)
        #expect(result.editor?.canvas.move?.preview?.image.width == 3)
        #expect(result.historyEntries == ["New Image", "Paste into New Image"])
    }
}
