import AppKit
import Testing
@testable import Paint

struct RasterBlurTests {
    private func input(_ brightness: [UInt8], width: Int) throws -> RasterFilter.Input {
        let bytes = Data(brightness.flatMap { [$0, $0, $0, 255] })
        let image = try #require(BGRA8.image(from: bytes, width: width, height: brightness.count / width))
        let layer = PaintLayer(name: "Test", image: image, pdnPixels: bytes)
        return try #require(RasterFilter.Input(layer: layer, selection: nil))
    }

    private func render(_ title: String, _ input: RasterFilter.Input, values: [Double]) throws -> [UInt8] {
        let filter = try #require(RasterFilter.blurEffects.first { $0.title == title })
        let layer = try #require(input.render(filter, values: values))
        let bytes = try #require(layer.pdnPixels)
        return stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }
    }

    @Test func fragmentDistanceAndRotationControlReplicaOffsets() throws {
        let input = try input([0, 0, 255, 0, 0], width: 5)
        #expect(try render("Fragment Blur", input, values: [2, 1, 0]) == [0, 85, 85, 85, 0])
        #expect(try render("Fragment Blur", input, values: [2, 1, 90]) == [0, 0, 255, 0, 0])
        #expect(try render("Fragment Blur", input, values: [4, 0, 45]) == [0, 0, 255, 0, 0])
    }

    @Test func motionBlurCentersTheTrailAndAddressesEachCanvasEdge() throws {
        let samples: [UInt8] = [0, 0, 255, 0, 0]
        let impulse = try input(samples, width: 5)
        #expect(try render("Motion Blur", impulse, values: [0, 2, 1, 0]) == [0, 85, 85, 85, 0])
        #expect(try render("Motion Blur", impulse, values: [0, 2, 0, 0]) == [0, 0, 85, 85, 85])
        #expect(try render("Motion Blur", impulse, values: [180, 2, 0, 0]) == [85, 85, 85, 0, 0])
        #expect(try render("Motion Blur", impulse, values: [0, 0, 0, 3]) == samples)

        let edges = try input([30, 90, 240], width: 3)
        #expect(try render("Motion Blur", edges, values: [0, 2, 0, 0]) == [30, 50, 120])
        #expect(try render("Motion Blur", edges, values: [0, 2, 0, 1]) == [120, 120, 120])
        #expect(try render("Motion Blur", edges, values: [0, 2, 0, 2]) == [50, 50, 120])
        let filter = try #require(RasterFilter.blurEffects.first { $0.title == "Motion Blur" })
        let transparent = try #require(edges.render(filter, values: [0, 2, 0, 3])?.straightPixels)
        #expect(Array(transparent) == [30, 30, 30, 85, 60, 60, 60, 170, 120, 120, 120, 255])
    }

    @Test func radialBlurKeepsCenterStillAndSpreadsAnOffsetFeature() throws {
        let samples: [UInt8] = [0, 255, 0, 0, 100, 0, 0, 0, 0]
        let input = try input(samples, width: 3)
        #expect(try render("Radial Blur", input, values: [0, 50, 50, 4]) == samples)
        let changed = try render("Radial Blur", input, values: [90, 50, 50, 4])
        #expect(changed[4] == 100)
        #expect(changed[1] < 255)
        #expect(changed[0] > 0)
        #expect(try render("Radial Blur", input, values: [90, 50, 0, 4])[1] == 255)
    }

    @Test func surfaceThresholdSmoothsNoiseButRetainsHardEdges() throws {
        let samples: [UInt8] = [10, 30, 220, 240]
        let input = try input(samples, width: 4)
        #expect(try render("Surface Blur", input, values: [1, 10]) == samples)
        let changed = try render("Surface Blur", input, values: [2, 60])
        #expect((11...29).contains(Int(changed[0])))
        #expect((11...29).contains(Int(changed[1])))
        #expect((221...239).contains(Int(changed[2])))
        #expect((221...239).contains(Int(changed[3])))
    }

    @Test func medianAndSketchPercentilesBiasLocalBrightness() throws {
        let input = try input([15, 120, 230, 250, 8], width: 5)
        for title in ["Median Blur", "Sketch Blur"] {
            #expect(try render(title, input, values: [1, 0, 3])[1] == 15)
            #expect(try render(title, input, values: [1, 100, 3])[1] == 230)
            #expect(try render(title, input, values: [0, 50, 3]) == [15, 120, 230, 250, 8])
        }
    }

    @Test func everyAddedBlurHonorsCancellationDuringRendering() throws {
        let input = try input(Array(repeating: 255, count: 512), width: 256)
        for filter in RasterFilter.blurEffects {
            var checks = 0
            let result = input.render(filter, values: filter.controls.map(\.initial)) {
                checks += 1
                return checks >= 3
            }
            #expect(checks >= 3, "\(filter.title)")
            #expect(result == nil, "\(filter.title)")
        }
    }
}
