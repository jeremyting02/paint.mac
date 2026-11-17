import Foundation
import Testing
@testable import Paint

struct SquareBlurTests {
    @Test func gammaBoostChangesTheAveragingSpaceAndPreservesAlpha() throws {
        // Each reflected radius-one window contains one white pixel and two black pixels.
        let source = try input([0, 0, 0, 128, 255, 255, 255, 128, 0, 0, 0, 128], width: 3)
        let neutral = try #require(source.render(SquareBlurEffect.filter, values: [1, 0])?.straightPixels)
        let fractional = try #require(source.render(SquareBlurEffect.filter, values: [1, 0.5])?.straightPixels)
        let boosted = try #require(source.render(SquareBlurEffect.filter, values: [1, 1])?.straightPixels)
        let reduced = try #require(source.render(SquareBlurEffect.filter, values: [1, -0.5])?.straightPixels)

        #expect(neutral == Data([156, 156, 156, 128, 156, 156, 156, 128, 156, 156, 156, 128]))
        #expect(fractional == Data([184, 184, 184, 128, 184, 184, 184, 128, 184, 184, 184, 128]))
        #expect(boosted == Data([200, 200, 200, 128, 200, 200, 200, 128, 200, 200, 200, 128]))
        #expect(reduced == Data([94, 94, 94, 128, 94, 94, 94, 128, 94, 94, 94, 128]))
    }

    @Test func gammaBoostLeavesConstantColorsAndZeroRadiusUnchanged() throws {
        let pixel: [UInt8] = [49, 112, 201, 128]
        let uniform = try input(pixel, width: 1)
        #expect(uniform.render(SquareBlurEffect.filter, values: [4, 1])?.straightPixels == Data(pixel))

        let hidden: [UInt8] = [200, 100, 50, 0]
        let transparent = try input(hidden, width: 1)
        #expect(transparent.render(SquareBlurEffect.filter, values: [0, 1])?.straightPixels == Data(hidden))
    }

    @Test func maximumRadiusAndGammaBoostStillSampleTheWholeReflectedWindow() throws {
        let black: [UInt8] = [0, 0, 0, 255]
        let white: [UInt8] = [255, 255, 255, 255]
        let pixels = Array(repeating: black, count: 100) + Array(repeating: white, count: 100)
        let source = try input(pixels.flatMap { $0 }, width: 200)
        let blurred = try #require(source.render(SquareBlurEffect.filter, values: [300, 2])?.straightPixels)
        // Reflection yields 400 white samples on the left and 201 on the right, out of 601.
        #expect(Array(blurred.prefix(4)) == [240, 240, 240, 255])
        #expect(Array(blurred.suffix(4)) == [217, 217, 217, 255])
    }

    private func input(_ bytes: [UInt8], width: Int) throws -> RasterFilter.Input {
        let pixels = Data(bytes)
        let image = try #require(BGRA8.image(from: pixels, width: width, height: 1))
        let layer = PaintLayer(name: "Square Blur test", image: image, pdnPixels: pixels)
        return try #require(RasterFilter.Input(layer: layer, selection: nil))
    }
}
