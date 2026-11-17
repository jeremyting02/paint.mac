import AppKit
import Testing
@testable import Paint

struct ImageResolutionTests {
    @Test func paintDotNetFixtureReadsItsResolutionAndRoundTripsMetadataExactly() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Layers52.pdn")
        let source = try PDNFile.read(Data(contentsOf: fixture))
        #expect(source.resolution == .standard)
        let reopened = try PDNFile.read(PDNFile.write(source))
        #expect(reopened.metadata.map(\.key) == source.metadata.map(\.key))
        #expect(reopened.metadata.map(\.value) == source.metadata.map(\.value))
    }

    @Test func centimeterResolutionConvertsToInchesAndUpdatesOnlyResolutionTags() throws {
        func tag(_ key: String, _ id: Int, _ type: Int, _ bytes: [UInt8]) -> PDNMetadata {
            let value = "<exif id=\"\(id)\" len=\"\(bytes.count)\" type=\"\(type)\" value=\"\(Data(bytes).base64EncodedString())\" />"
            return PDNMetadata(key: key, value: value)
        }
        let metadata = [
            tag("$exif.tag1[0]", 296, 3, [3, 0]),
            tag("$exif.tag3[0]", 282, 5, [100, 0, 0, 0, 1, 0, 0, 0]),
            tag("$exif.tag5[0]", 283, 5, [50, 0, 0, 0, 1, 0, 0, 0]),
            PDNMetadata(key: "Comment", value: "Keep this exact string")
        ]
        let imported = try #require(ImageResolution(metadata: metadata))
        #expect(imported.horizontal == 254)
        #expect(imported.vertical == 127)
        let next = try #require(ImageResolution(horizontal: 300.25, vertical: 150.5))
        let updated = next.updating(metadata)
        #expect(updated.map(\.key) == metadata.map(\.key))
        #expect(updated.last?.value == metadata.last?.value)
        #expect(ImageResolution(metadata: updated) == next)

        let invalid = [metadata[0], metadata[1], tag("$exif.tag5[0]", 283, 5, [1, 0, 0, 0, 0, 0, 0, 0])]
        #expect(ImageResolution(metadata: invalid) == nil)
    }

    @MainActor @Test func resolutionEditIsUndoableWithoutResamplingAndSavesToPDN() throws {
        let canvas = try #require(LayerStack.blank(width: 3, height: 4))
        let document = PaintDocument()
        try document.read(from: PDNFile.write(canvas), ofType: "Paint.NET Project")
        document.undoManager?.groupsByEvent = false
        let pixels = document.image
        let resolution = try #require(ImageResolution(horizontal: 300, vertical: 150))
        document.performResize(width: 3, height: 4, resolution: resolution)
        #expect(document.stack?.resolution == resolution)
        #expect(document.image === pixels)
        #expect(document.historyEntries == ["Open Image", "Set Resolution"])
        let reopened = try PDNFile.read(document.data(ofType: "Paint.NET Project"))
        #expect(reopened.resolution == resolution)
        #expect(try reopened.reoriented(.clockwise).resolution == resolution.transposed)
        document.undoStroke(nil)
        #expect(document.stack?.resolution == nil)
        document.redoStroke(nil)
        #expect(document.stack?.resolution == resolution)
    }

    @MainActor @Test func pngAndTiffCarryResolutionThroughBitmapAndDocumentReads() throws {
        let image = try #require(LayerStack.blank(width: 3, height: 4)?.activeLayer.image)
        let resolution = try #require(ImageResolution(horizontal: 300, vertical: 150))
        for format in [RasterFormat.png, .tiff, .jpeg] {
            let encoded = try PaintFiles.rasterData(image, as: format, resolution: resolution)
            let raster = try PaintFiles.decodeRaster(encoded)
            let fromBitmap = try #require(raster.resolution, "\(format.rawValue)")
            #expect(abs(fromBitmap.horizontal - resolution.horizontal) <= 0.06, "\(format.rawValue)")
            #expect(abs(fromBitmap.vertical - resolution.vertical) <= 0.06, "\(format.rawValue)")
            let document = PaintDocument()
            try document.read(from: encoded, ofType: format.rawValue)
            let fromDocument = try #require(document.stack?.resolution, "\(format.rawValue)")
            #expect(abs(fromDocument.horizontal - resolution.horizontal) <= 0.06, "\(format.rawValue)")
            #expect(abs(fromDocument.vertical - resolution.vertical) <= 0.06, "\(format.rawValue)")
        }
    }
}
