import CoreGraphics
import Foundation
import Testing
@testable import Paint

struct StraightAlphaPixelTests {
    @Test func decodedPNGPreservesHiddenAndLowAlphaRGB() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("reference-pixels/input.png")
        let image = try PaintFiles.readRaster(Data(contentsOf: url), expected: .png)
        let decoded = try #require(BGRA8.pixels(from: image))
        let samples = [
            (992, UInt8(0)), (993, 1), (994, 2), (1000, 96), (1015, 64), (1022, 254)
        ]
        for (index, alpha) in samples {
            #expect(decoded.subdata(in: index * 4..<(index + 1) * 4) == Data([67, 116, 201, alpha]))
        }
    }

    @Test func bgraImageRoundTripsFullyTransparentAndLowAlphaPixels() throws {
        let pixels = Data([67, 116, 201, 0, 11, 34, 179, 1, 56, 201, 79, 2, 200, 110, 20, 255])
        let image = try #require(BGRA8.image(from: pixels, width: 2, height: 2))
        #expect(BGRA8.pixels(from: image) == pixels)
    }

    @Test func croppedProviderKeepsOriginalRowSpacingAndPixelValues() throws {
        let source = Data(0..<48)
        let image = try #require(BGRA8.image(from: source, width: 4, height: 3))
        let crop = try #require(image.cropping(to: CGRect(x: 1, y: 1, width: 2, height: 2)))
        #expect(BGRA8.pixels(from: crop) == Data(20..<28) + Data(36..<44))
    }
}
