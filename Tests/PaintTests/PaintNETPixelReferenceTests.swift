import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Paint

struct PaintNETPixelReferenceTests {
    static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("reference-pixels", isDirectory: true)

    static let captureDirectory = ProcessInfo.processInfo.environment["PAINTNET_REFERENCE_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    @Test(arguments: [
        ("Black and White", "black-and-white"), ("Invert Colors", "invert-colors")
    ])
    func matchesPaintNET52Pixels(adjustment: String, output: String) throws {
        let source = try Self.loadPNG(Self.fixtureDirectory.appendingPathComponent("input.png"))
        let filter = try #require(RasterFilter.adjustments.first { $0.title == adjustment })
        let input = try #require(RasterFilter.Input(layer: PaintLayer(name: "Input", image: source), selection: nil))
        let rendered = try #require(input.render(filter, values: filter.controls.map(\.initial)))

        let referenceURL = try #require(Self.referenceFile(output + ".png"))
        let referenceSource = try #require(CGImageSourceCreateWithURL(referenceURL as CFURL, nil))
        let reference = try #require(CGImageSourceCreateImageAtIndex(referenceSource, 0, nil))
        try #require(rendered.image.width == reference.width && rendered.image.height == reference.height)
        let actual = try #require(rendered.straightPixels)
        // Read the known straight RGBA fixture layout without using the editor's pixel conversion.
        // A rendered comparison would hide shared rounding and RGB loss at very small alpha.
        let expected = try Self.storedBGRA(in: reference)
        let differences = Self.differences(actual: actual, expected: expected, width: reference.width)
        #expect(differences.count == 0, Comment(rawValue: differences.description))

        let exported = try PaintFiles.rasterData(rendered.image, as: .png)
        let exportSource = try #require(CGImageSourceCreateWithData(exported as CFData, nil))
        let exportImage = try #require(CGImageSourceCreateImageAtIndex(exportSource, 0, nil))
        let exportDifferences = Self.differences(actual: try Self.storedBGRA(in: exportImage),
                                               expected: expected, width: reference.width)
        #expect(exportDifferences.count == 0, Comment(rawValue: "Exported PNG: \(exportDifferences.description)"))
    }

    static func referenceFile(_ name: String) -> URL? {
        for directory in [captureDirectory, fixtureDirectory].compactMap({ $0 }) {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func loadPNG(_ url: URL) throws -> CGImage {
        try PaintFiles.readRaster(Data(contentsOf: url), expected: .png)
    }

    private static func storedBGRA(in image: CGImage) throws -> Data {
        try #require(image.bitsPerComponent == 8 && image.bitsPerPixel == 32 && image.alphaInfo == .last)
        try #require(image.bitmapInfo.intersection(.byteOrderMask) == .byteOrderDefault)
        try #require(image.colorSpace?.name == CGColorSpace.sRGB)
        let bytes = try #require(image.dataProvider?.data) as Data
        var bgra = Data()
        bgra.reserveCapacity(image.width * image.height * 4)
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = row * image.bytesPerRow + column * 4
                bgra.append(contentsOf: [bytes[offset + 2], bytes[offset + 1], bytes[offset], bytes[offset + 3]])
            }
        }
        return bgra
    }

    static func differences(actual: Data, expected: Data, width: Int) -> (count: Int, description: String) {
        precondition(actual.count == expected.count)
        var examples: [String] = []
        var count = 0
        var maximumDelta = 0
        for pixel in stride(from: 0, to: actual.count, by: 4) {
            let range = pixel..<(pixel + 4)
            let actualPixel = actual[range], expectedPixel = expected[range]
            guard actualPixel != expectedPixel else { continue }
            count += 1
            for (left, right) in zip(actualPixel, expectedPixel) {
                maximumDelta = max(maximumDelta, abs(Int(left) - Int(right)))
            }
            if examples.count < 6 {
                let x = pixel / 4 % width, y = pixel / 4 / width
                examples.append("(\(x), \(y)) expected BGRA \(Array(expectedPixel)), got \(Array(actualPixel))")
            }
        }
        let summary = "\(count) of \(actual.count / 4) pixels differ; maximum channel delta \(maximumDelta)"
        return (count, ([summary] + examples).joined(separator: "\n"))
    }
}
