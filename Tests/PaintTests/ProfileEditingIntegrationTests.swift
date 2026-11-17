import AppKit
import CoreImage
import Testing
@testable import Paint

struct ProfileEditingIntegrationTests {
    @Test func rotationAndNearestResizePreserveEncodedWideGamutPixels() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let pixels = Data([4, 11, 245, 0, 50, 129, 240, 1])
        let image = try #require(BGRA8.image(from: pixels, width: 2, height: 1, colorSpace: space))
        let layer = PaintLayer(name: "Wide Gamut", image: image, pdnPixels: pixels)
        let stack = LayerStack(layers: [layer], active: 0)
        let rotated = try stack.reoriented(.clockwise)
        #expect(rotated.activeLayer.image.colorSpace == space)
        #expect(rotated.activeLayer.image.width == 1)
        #expect(rotated.activeLayer.image.height == 2)
        #expect(rotated.activeLayer.straightPixels == pixels)

        let resized = try stack.resizedImage(width: 4, height: 1, sampling: .nearest, linearLight: false)
        let doubled = Data([4, 11, 245, 0, 4, 11, 245, 0, 50, 129, 240, 1, 50, 129, 240, 1])
        #expect(resized.activeLayer.image.colorSpace == space)
        #expect(resized.activeLayer.straightPixels == doubled)
    }

    @Test func gradientsAndVectorFillConvertSRGBToolColorsToDocumentProfile() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let image = try #require(BGRA8.image(from: Data(count: 4 * 4 * 4), width: 4, height: 4, colorSpace: space))
        let layer = PaintLayer(name: "Wide Gamut", image: image)
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let converted = try #require(red.converted(to: space, intent: .defaultIntent, options: nil)?.components)
        let expected = [converted[2], converted[1], converted[0], converted[3]].map { Int(($0 * 255).rounded()) }

        let gradient = LinearGradient(start: .zero, end: CGPoint(x: 4, y: 0))
        let linear = try #require(gradient.applying(to: layer, primary: red, secondary: red, selection: nil))
        var radialOptions = GradientOptions()
        radialOptions.shape = .radial
        let radial = try #require(gradient.applying(to: layer, primary: red, secondary: red,
                                                    selection: nil, options: radialOptions))
        var style = DrawingStyle()
        style.primary = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        style.fill = .fill
        let shape = VectorDrawing.shape(CGRect(x: 0, y: 0, width: 4, height: 4))
        let vector = try #require(shape.applying(to: layer, selection: nil, style: style))

        for edited in [linear, radial, vector] {
            #expect(edited.image.colorSpace == space)
            let encoded = try #require(edited.straightPixels)
            let middle = encoded[20..<24].map(Int.init)
            #expect(zip(middle, expected).allSatisfy { abs($0 - $1) <= 1 })
        }
    }

    @Test func gammaCorrectResizingUsesAdobeRGBTransfer() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.adobeRGB1998))
        let pixels = Data([0, 0, 0, 255, 255, 255, 255, 255])
        let image = try #require(BGRA8.image(from: pixels, width: 2, height: 1, colorSpace: space))
        let stack = LayerStack(layers: [PaintLayer(name: "Adobe RGB", image: image)], active: 0)
        let resize = try stack.resizedImage(width: 1, height: 1, sampling: .bilinear, linearLight: true)
        let linear = try #require(CGColorSpaceCreateLinearized(space))
        let midtone = try #require(CGColor(colorSpace: linear, components: [0.5, 0.5, 0.5, 1]))
        let expected = try #require(midtone.converted(to: space, intent: .relativeColorimetric, options: nil)?.components)
        let bytes = try #require(resize.activeLayer.straightPixels)
        #expect(resize.activeLayer.image.colorSpace == space)
        #expect(bytes[3] == 255)
        #expect(zip(bytes.prefix(3), expected.prefix(3).reversed()).allSatisfy {
            abs(Int($0) - Int(($1 * 255).rounded())) <= 1
        })
    }

    @Test func coreImageFilterReceivesTheLayerWorkingColorSpace() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let pixels = Data([20, 90, 230, 255])
        let image = try #require(BGRA8.image(from: pixels, width: 1, height: 1, colorSpace: space))
        let layer = PaintLayer(name: "Wide Gamut", image: image, pdnPixels: pixels)
        let input = try #require(RasterFilter.Input(layer: layer, selection: nil))
        let probe = RasterFilter.coreImage("Working color-space probe") { image, _ in
            image.colorSpace == space ? image : image.applyingFilter("CIColorInvert")
        }
        let result = try #require(input.render(probe, values: []))
        #expect(result.image === layer.image)
        #expect(result.straightPixels == pixels)
    }

    @MainActor @Test func pasteIntoNewImageKeepsItsWideGamutProfile() throws {
        _ = NSApplication.shared
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let pixels = Data([33, 129, 226, 255, 50, 120, 238, 128])
        let image = try #require(BGRA8.image(from: pixels, width: 2, height: 1, colorSpace: space))
        let document = try #require(PaintDocument.makePastedImage(from: image))
        defer { document.close() }
        #expect(document.stack?.colorProfile?.name.contains("Display P3") == true)
        let canvas = try #require(document.editor?.canvas)
        canvas.finishSelection()
        let output = try PDNFile.read(document.data(ofType: "Paint.NET Project"))
        #expect(output.colorProfile == document.stack?.colorProfile)
        #expect(output.activeLayer.straightPixels == pixels)
    }
}
