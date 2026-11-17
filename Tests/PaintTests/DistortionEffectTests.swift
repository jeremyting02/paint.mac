import Foundation
import Testing
@testable import Paint

struct DistortionEffectTests {
    @Test func dentsIsDeterministicAndRefractionCanBeDisabled() throws {
        let input = try fixture()
        let filter = try effect("Dents")
        var values = filter.controls.map(\.initial)
        let first = try output(filter, input: input, values: values)
        #expect(first != input.pixels)
        #expect(try output(filter, input: input, values: values) == first)
        values[6] += 1
        #expect(try output(filter, input: input, values: values) != first)
        values[1] = 0
        #expect(try output(filter, input: input, values: values) == input.pixels)
    }

    @Test func glassScatterUsesSeedAndPreservesOpaqueAlpha() throws {
        let input = try fixture()
        let filter = try effect("Frosted Glass")
        var values = filter.controls.map(\.initial)
        let first = try output(filter, input: input, values: values)
        #expect(first != input.pixels)
        #expect(stride(from: 3, to: first.count, by: 4).allSatisfy { first[$0] == 255 })
        #expect(try output(filter, input: input, values: values) == first)
        values[4] += 1
        #expect(try output(filter, input: input, values: values) != first)
        values[0] = 0
        #expect(try output(filter, input: input, values: values) == input.pixels)
    }

    @Test func polarInversionHandlesEdgesAndOnePixelImages() throws {
        let input = try fixture()
        let filter = try effect("Polar Inversion")
        var values = filter.controls.map(\.initial)
        values[3] = 1
        let clamped = try output(filter, input: input, values: values)
        values[3] = 2
        let reflected = try output(filter, input: input, values: values)
        values[3] = 3
        let wrapped = try output(filter, input: input, values: values)
        #expect(clamped != reflected)
        #expect(wrapped != reflected)
        values[0] = 0
        #expect(try output(filter, input: input, values: values) == input.pixels)
        values[0] = 1
        let one = try makeInput(width: 1, height: 1, pixels: Data([31, 27, 96, 255]))
        #expect(try output(filter, input: one, values: values) == one.pixels)
    }

    @Test func wavesModesProduceDistinctMapsAndHonorCancellation() throws {
        let input = try fixture()
        let filter = try effect("Waves")
        var values = filter.controls.map(\.initial)
        let outputs = try (1...4).map { mode in
            values[0] = Double(mode)
            return try output(filter, input: input, values: values)
        }
        #expect(Set(outputs).count == 4)
        var cancellationChecks = 0
        #expect(input.render(filter, values: values, isCancelled: {
            cancellationChecks += 1
            return cancellationChecks >= 3
        }) == nil)
        values[1] = 0
        #expect(try output(filter, input: input, values: values) == input.pixels)
    }

    @Test func outlineWhitesFlatAreasAndPreservesColoredEdges() throws {
        let pixels = Array(repeating: [UInt8(0), 0, 255, 255], count: 3)
            + Array(repeating: [UInt8(255), 255, 255, 255], count: 3)
        let input = try makeInput(width: 6, height: 1, pixels: Data(pixels.flatMap { $0 }))
        let filter = try effect("Outline")
        let result = try output(filter, input: input, values: [1, 100, 8])
        #expect(Array(result[0..<4]) == [255, 255, 255, 255])
        #expect(Array(result[8..<12]) == [0, 0, 255, 255])
        #expect(Array(result[20..<24]) == [255, 255, 255, 255])
        #expect(try output(filter, input: input, values: [0, 100, 8]) == input.pixels)
    }

    @Test func reliefChangesDirectionWithoutConvertingToGrayscale() throws {
        let input = try makeInput(width: 3, height: 1, pixels: Data([
            50, 100, 160, 255, 60, 120, 180, 255, 70, 140, 200, 255
        ]))
        let filter = try effect("Relief")
        let forward = try output(filter, input: input, values: [0])
        let reverse = try output(filter, input: input, values: [180])
        #expect(Array(forward[4..<8]) == [50, 100, 160, 255])
        #expect(Array(reverse[4..<8]) == [70, 140, 200, 255])
    }

    private func effect(_ title: String) throws -> RasterFilter {
        try #require(RasterFilter.distortionEffects.first { $0.title == title })
    }

    private func fixture() throws -> RasterFilter.Input {
        let side = 16
        let pixels = Data((0..<(side * side)).flatMap { index -> [UInt8] in
            [UInt8(index % side * 15), UInt8(index / side * 15), UInt8(index), 255]
        })
        return try makeInput(width: side, height: side, pixels: pixels)
    }

    private func makeInput(width: Int, height: Int, pixels: Data) throws -> RasterFilter.Input {
        let image = try #require(BGRA8.image(from: pixels, width: width, height: height))
        let layer = PaintLayer(name: "Fixture", image: image, pdnPixels: pixels)
        return try #require(RasterFilter.Input(layer: layer, selection: nil))
    }

    private func output(_ filter: RasterFilter, input: RasterFilter.Input, values: [Double]) throws -> Data {
        try #require(input.render(filter, values: values)?.straightPixels)
    }
}
