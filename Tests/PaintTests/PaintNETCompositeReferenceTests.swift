import AppKit
import ImageIO
import Testing
@testable import Paint

struct PaintNETCompositeReferenceTests {
    @MainActor @Test(arguments: LayerBlendMode.allCases)
    func stackExportAndClipboardMatchPaintNET52(_ mode: LayerBlendMode) throws {
        _ = NSApplication.shared
        let input = try #require(PaintNETPixelReferenceTests.referenceFile("composite-normal.pdn"))
        var stack = try PDNFile.read(Data(contentsOf: input))
        stack.layers[1].blendMode = mode
        stack.layers[2].blendMode = mode

        let name = mode.title.lowercased().replacingOccurrences(of: " ", with: "-")
        let url = try #require(PaintNETPixelReferenceTests.referenceFile("composite-\(name).png"))
        let reference = try decodePNG(Data(contentsOf: url))
        let expected = try PaintNETPixelReferenceTests.storedBGRA(in: reference)
        let document = PaintDocument()
        let original = try PDNFile.write(stack)
        try document.read(from: original, ofType: "Paint.NET Project")
        document.makeWindowControllers()
        defer { document.close() }

        let flattened = try #require(stack.flattenedLayer()?.straightPixels)
        compare(flattened, expected, width: reference.width, operation: "Layer composite")

        let exported = try PaintFiles.rasterData(try #require(document.stack), as: .png)
        compare(try PaintNETPixelReferenceTests.storedBGRA(in: decodePNG(exported)),
                expected, width: reference.width, operation: "PNG export")

        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        document.copyPixels(to: clipboard, cutting: false, flattened: true)
        let copiedPNG = try #require(clipboard.data(forType: .png))
        compare(try PaintNETPixelReferenceTests.storedBGRA(in: decodePNG(copiedPNG)),
                expected, width: reference.width, operation: "Copy Flattened")

        let canvas = try #require(document.editor?.canvas)
        canvas.setSelection(SelectionOutline(rect: CGRect(x: 1, y: reference.height - 2, width: 3, height: 2)))
        document.copyPixels(to: clipboard, cutting: false, flattened: true)
        let cropped = try decodePNG(try #require(clipboard.data(forType: .png)))
        #expect(cropped.width == 3 && cropped.height == 2)
        let stride = reference.width * 4
        var expectedCrop = Data(expected[4..<16])
        expectedCrop.append(expected[(stride + 4)..<(stride + 16)])
        compare(try PaintNETPixelReferenceTests.storedBGRA(in: cropped), expectedCrop,
                width: 3, operation: "Copy Flattened with selection")

        let saved = try document.data(ofType: "Paint.NET Project")
        #expect(saved == original)
        #expect(document.historyEntries == ["Open Image"])
    }

    private func decodePNG(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func compare(_ actual: Data, _ expected: Data, width: Int, operation: String) {
        guard actual.count == expected.count else {
            Issue.record("\(operation) returned \(actual.count) bytes, expected \(expected.count).")
            return
        }
        let difference = PaintNETPixelReferenceTests.differences(actual: actual, expected: expected, width: width)
        #expect(difference.count == 0, Comment(rawValue: "\(operation): \(difference.description)"))
    }
}
