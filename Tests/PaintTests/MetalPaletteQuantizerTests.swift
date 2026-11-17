import Foundation
import Metal
import Testing
@testable import Paint

struct MetalPaletteQuantizerTests {
    @Test func shardedHistogramCarriesColorSumsAbove32Bits() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let width = 1024, height = 1024
        let source = Data(repeating: 251, count: width * height * 4)
        let quantizer = try #require(MetalPaletteQuantizer(source: source, width: width, height: height))
        let histogram = try #require(quantizer.histogram(isCancelled: { false }))
        let index = 31 | (31 << 5) | (31 << 10)
        let weight = UInt64(width * height) * 251
        #expect(histogram[index] == SIMD4(weight * 251, weight * 251, weight * 251, weight))
        #expect(histogram.filter { $0.w > 0 }.count == 1)
    }

    @Test(arguments: [0.0, 0.63])
    func metalQuantizationMatchesTheCpuPaletteByteForByte(dither: Double) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let width = 349, height = 281
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            for index in 0..<(width * height) {
                let word = UInt32(index) &* 2_654_435_761
                raw.storeBytes(of: word.littleEndian, toByteOffset: index * 4, as: UInt32.self)
            }
        }
        let cpu = try #require(PaletteQuantizer.apply(pixels, width: width, height: height, count: 37, dither: dither,
                                                      useMetal: false, isCancelled: { false }))
        let gpu = try #require(PaletteQuantizer.apply(pixels, width: width, height: height, count: 37, dither: dither,
                                                      isCancelled: { false }))
        #expect(gpu == cpu)
    }
}
