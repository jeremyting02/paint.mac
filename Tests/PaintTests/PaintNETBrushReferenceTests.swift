import AppKit
import ImageIO
import Testing
@testable import Paint

struct PaintNETBrushReferenceTests {
    @Test func evenAliasedDabMatchesPaintNET52() throws {
        let directory = PaintNETPixelReferenceTests.fixtureDirectory
        let input = try PaintFiles.readRaster(Data(contentsOf: directory.appendingPathComponent("brush-dabs-input.png")),
                                              expected: .png)
        let color = DrawingColor(.black)
        let layer = PaintLayer(name: "Brush capture", image: input)
        var options = BrushOptions()
        options.antialiased = false
        let drawing = try #require(RasterDrawing(layer: layer, operation: .paint(primary: color, secondary: color),
                                                 diameter: 8, selection: nil, options: options))
        drawing.append(CGPoint(x: 40.5, y: 8.5))
        drawing.finish()
        let result = try #require(drawing.preview?.straightPixels)

        let referenceURL = try #require(PaintNETPixelReferenceTests.referenceFile("brush-dabs.png"))
        let referenceSource = try #require(CGImageSourceCreateWithURL(referenceURL as CFURL, nil))
        let reference = try #require(CGImageSourceCreateImageAtIndex(referenceSource, 0, nil))
        try #require(reference.width == input.width && reference.height == input.height)
        let bgra = try PaintNETPixelReferenceTests.storedBGRA(in: reference)
        let left = 32
        let width = reference.width - left
        var actual = Data()
        var expected = Data()
        for row in 0..<reference.height {
            let start = 4 * (row * reference.width + left)
            actual.append(contentsOf: result[start..<(start + width * 4)])
            expected.append(contentsOf: bgra[start..<(start + width * 4)])
        }
        let differences = PaintNETPixelReferenceTests.differences(actual: actual, expected: expected, width: width)
        #expect(differences.count == 0, Comment(rawValue: differences.description))
    }
}
