import Foundation
import Testing
@testable import Paint

struct LayerCapacityTests {
    @Test func smallCanvasRoundTripsMoreThanEightLayers() throws {
        var stack = try #require(LayerStack.blank(width: 2, height: 1))
        for _ in 1..<16 { try stack.insertBlankLayer() }
        let pixels = Data([255, 7, 8, 1, 0, 44, 0, 255])
        let top = try #require(stack.activeLayer.withPixels(pixels))
        stack.layers[stack.active] = top
        stack.layers[stack.active].name = "Sixteenth layer"
        let encoded = try PDNFile.write(stack)
        let reopened = try PDNFile.read(encoded)
        #expect(reopened.layers.count == 16)
        #expect(reopened.activeLayer.name == "Sixteenth layer")
        #expect(reopened.activeLayer.pdnPixels == pixels)
    }

    @Test func maximumLayerCountAlsoRespectsDocumentPixelBudget() throws {
        #expect(LayerStack.layerCapacity(width: 2, height: 2) == 128)
        #expect(LayerStack.layerCapacity(width: 4096, height: 2048) == 8)
        let single = try #require(LayerStack.blank(width: 1, height: 1))
        let layers = Array(repeating: single.activeLayer, count: 9)
        let stack = LayerStack(layers: layers, active: 8)
        #expect(throws: PDNError.self) {
            try stack.resizedCanvas(width: 4096, height: 2048, anchor: .center)
        }
        #expect(throws: PDNError.self) {
            try stack.resizedImage(width: 4096, height: 2048, sampling: .nearest, linearLight: false)
        }
    }
}
