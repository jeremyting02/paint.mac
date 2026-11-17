import AppKit
import Metal
import Testing
@testable import Paint

struct MetalRasterGeometryTests {
    private func pixels(width: Int, height: Int) -> Data {
        var result = Data(count: width * height * 4)
        result.withUnsafeMutableBytes { raw in
            for index in 0..<(width * height) {
                let mixed = UInt32(index) &* 2_654_435_761
                raw.storeBytes(of: mixed.littleEndian, toByteOffset: index * 4, as: UInt32.self)
            }
        }
        return result
    }

    @Test(arguments: ImageResampler.Mode.allCases)
    func resizeMatchesCPUAcrossModesAndColorSpaces(_ mode: ImageResampler.Mode) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let width = 301, height = 247
        let input = pixels(width: width, height: height)
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        for (targetWidth, targetHeight, linear, profile) in [
            (279, 263, false, BGRA8.sRGB),
            (317, 214, true, BGRA8.sRGB),
            (266, 279, true, p3)
        ] {
            let resampler = ImageResampler(sourceWidth: width, sourceHeight: height, width: targetWidth,
                                           height: targetHeight, mode: mode, linearLight: linear, colorSpace: profile)
            let expected = try #require(resampler.resample(input, useMetal: false))
            let preview = try #require(resampler.resampleOnMetal(input))
            let difference = zip(preview, expected).enumerated().first { $0.element.0 != $0.element.1 }
            #expect(difference == nil, "\(targetWidth)x\(targetHeight), linear: \(linear), first difference: \(String(describing: difference))")
        }
    }

    @Test func layerProjectionPreservesCanonicalApplyAndAcceleratesPreview() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let width = 384, height = 288
        let source = pixels(width: width, height: height)
        let image = try #require(BGRA8.image(from: source, width: width, height: height))
        let layer = PaintLayer(name: "Projection", image: image, pdnPixels: source)
        let input = try #require(RasterFilter.Input(layer: layer, selection: nil))
        let values: [Double] = [17.3, 28.5, 26, 3.25, -4.25, 108.5, 3, 2, 0]
        let direct = try #require(LayerRotateZoom.renderOnMetal(source, width, height, values, { false }))
        let preview = try #require(input.render(LayerRotateZoom.filter, values: values, preview: true)?.pdnPixels)
        let canonical = try #require(input.render(LayerRotateZoom.filter, values: values)?.pdnPixels)
        let expected = try #require(LayerRotateZoom.render(source, width, height, values, { false }))
        #expect(preview == direct)
        #expect(canonical == expected)
        let difference = zip(direct, canonical).filter { abs(Int($0) - Int($1)) > 1 }.count
        #expect(difference < direct.count / 1_000)
        #expect(LayerRotateZoom.renderOnMetal(source, width, height, values, { true }) == nil)
    }
}
