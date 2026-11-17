import AppKit
import Testing
@testable import Paint

@MainActor
struct NewImageTests {
    @Test func customSizeAndResolutionCreateAWhiteUnsavedDocument() throws {
        let resolution = try #require(ImageResolution(horizontal: 144, vertical: 300))
        let document = try #require(PaintDocument.newImage(width: 3, height: 2, resolution: resolution))
        #expect(document.fileURL == nil)
        #expect(document.historyEntries == ["New Image"])
        #expect(document.image?.width == 3)
        #expect(document.image?.height == 2)
        let encoded = try document.data(ofType: "Paint.NET Project")
        let reopened = try PDNFile.read(encoded)
        #expect(reopened.resolution == resolution)
        #expect(reopened.layers.map(\.name) == ["Background"])
        #expect(reopened.activeLayer.pdnPixels == Data(repeating: 255, count: 24))
    }

    @Test func invalidCanvasDimensionsAreRejectedBeforeCreatingADocument() {
        #expect(PaintDocument.newImage(width: 0, height: 1, resolution: .standard) == nil)
        #expect(PaintDocument.newImage(width: 4096, height: 4096, resolution: .standard) == nil)
    }
}
