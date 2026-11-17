import Foundation
import Testing
@testable import Paint

struct ArtisticEffectTests {
    @Test func linocutQuantizesToInkAndPaper() throws {
        let input = try fixture(width: 2, height: 1, bytes: [16, 30, 46, 255, 179, 199, 213, 127])
        let result = try render("Linocut", input: input, values: [50, 7, 45])
        #expect(result == Data([0, 0, 0, 255, 255, 255, 255, 127]))
    }

    @Test func mosaicAveragesEachTileWithAlphaWeighting() throws {
        let input = try fixture(width: 4, height: 1, bytes: [
            0, 0, 255, 255, 255, 0, 0, 255, 0, 255, 0, 255, 255, 0, 0, 0
        ])
        let result = try render("Mosaic", input: input, values: [2, 0, 0, 0])
        #expect(result == Data([128, 0, 128, 255, 128, 0, 128, 255, 0, 255, 0, 255, 255, 0, 0, 0]))
    }

    @Test func oilPaintUsesDominantLocalIntensity() throws {
        let input = try fixture(width: 3, height: 1, bytes: [8, 10, 12, 255, 230, 240, 250, 255, 12, 14, 16, 255])
        let result = try render("Oil Painting", input: input, values: [1, 8])
        #expect(Array(result[4..<8]) == [10, 12, 14, 255])
    }

    @Test func pencilSketchDarkensDetailsAndPreservesTransparency() throws {
        let input = try fixture(width: 3, height: 1, bytes: [
            255, 255, 255, 255, 20, 30, 40, 128, 255, 255, 255, 255
        ])
        let result = try render("Pencil Sketch", input: input, values: [1, 0])
        #expect(result[0] == 255)
        #expect(result[4] < 100)
        #expect(result[4] == result[5] && result[5] == result[6])
        #expect(result[7] == 128)
    }

    @Test func stainedGlassProducesSeededLeadSeams() throws {
        let sample: [UInt8] = [160, 200, 240, 255]
        let bytes = Array(repeating: sample, count: 12 * 12).flatMap { $0 }
        let input = try fixture(width: 12, height: 12, bytes: bytes)
        let noLead = try render("Stained Glass", input: input, values: [4, 0, 17])
        let lead = try render("Stained Glass", input: input, values: [4, 2, 17])
        #expect(noLead == Data(bytes))
        #expect(lead != noLead)
        let same = try render("Stained Glass", input: input, values: [4, 2, 17])
        let different = try render("Stained Glass", input: input, values: [4, 2, 18])
        #expect(lead == same)
        #expect(lead != different)
        #expect(stride(from: 3, to: lead.count, by: 4).allSatisfy { lead[$0] == 255 })
    }

    private func fixture(width: Int, height: Int, bytes: [UInt8]) throws -> RasterFilter.Input {
        let pixels = Data(bytes)
        let image = try #require(BGRA8.image(from: pixels, width: width, height: height))
        let layer = PaintLayer(name: "Artistic Fixture", image: image, pdnPixels: pixels)
        return try #require(RasterFilter.Input(layer: layer, selection: nil))
    }

    private func render(_ name: String, input: RasterFilter.Input, values: [Double]) throws -> Data {
        let filter = try #require(RasterFilter.artisticEffects.first(where: { $0.title == name }))
        return try #require(input.render(filter, values: values)?.straightPixels)
    }
}
