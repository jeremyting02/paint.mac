import AppKit
import ImageIO
import Testing
@testable import Paint

struct ColorProfileTests {
    @Test func paintNETDisplayP3FixtureRetainsAssignedPixelsAndOriginalICCData() throws {
        let source = try PDNFile.read(Data(contentsOf: PaintNETPixelReferenceTests.fixtureDirectory
            .appendingPathComponent("display-p3-assigned.pdn")))
        let profile = try #require(source.colorProfile)
        let original = try PaintFiles.readRaster(Data(contentsOf: PaintNETPixelReferenceTests.fixtureDirectory
            .appendingPathComponent("input.png")))
        let bytes = try #require(BGRA8.pixels(from: original))
        #expect(profile.iccData.count == 516)
        #expect(profile.name.contains("Display P3"))
        #expect(source.activeLayer.straightPixels == bytes)
        #expect(source.activeLayer.image.colorSpace == profile.colorSpace)
        #expect(BGRA8.pixels(from: source.activeLayer.image) != bytes)

        let reopened = try PDNFile.read(PDNFile.write(source))
        #expect(reopened.colorProfile == profile)
        #expect(reopened.metadata.map(\.key) == source.metadata.map(\.key))
        #expect(reopened.metadata.map(\.value) == source.metadata.map(\.value))
        #expect(reopened.activeLayer.straightPixels == bytes)
        #expect(reopened.activeLayer.image.colorSpace == profile.colorSpace)
    }

    @Test func colorSpaceConversionPreservesAlphaAndHiddenColor() throws {
        let sample = Data([69, 80, 128, 0, 69, 80, 128, 1, 69, 80, 128, 255])
        let p3 = try displayP3()
        let converted = try #require(BGRA8.converted(sample, width: 3, height: 1,
                                                     from: p3.colorSpace, to: BGRA8.sRGB))
        let color = Array(converted[0..<3])
        #expect(color != Array(sample[0..<3]))
        #expect(color == Array(converted[4..<7]))
        #expect(color == Array(converted[8..<11]))
        #expect([converted[3], converted[7], converted[11]] == [0, 1, 255])
    }

    @Test func pngJPEGAndTIFFKeepTheExportedRGBProfile() throws {
        let profile = try displayP3()
        let pixels = Data(repeating: 149, count: 16 * 16 * 4)
        let image = try #require(BGRA8.image(from: pixels, width: 16, height: 16, colorSpace: profile.colorSpace))
        for format in [RasterFormat.png, .jpeg, .tiff] {
            let exported = try PaintFiles.decodeRaster(PaintFiles.rasterData(image, as: format))
            let embedded = try #require(exported.colorProfile)
            #expect(embedded.name.contains("Display P3"))
            if format == .png {
                #expect(BGRA8.pixels(from: exported.image, in: embedded.colorSpace) == pixels)
            }
        }
    }

    @Test func crossProfileLayerImportAndBlendingUseTheDocumentColorSpace() throws {
        let p3 = try displayP3()
        let base = try makeLayer([1, 40, 175, 255], width: 1, in: p3.colorSpace)
        var document = LayerStack(layers: [base], active: 0, colorProfile: p3)
        var overlay = try makeLayer([69, 80, 128, 128], width: 1, in: BGRA8.sRGB)
        overlay.blendMode = .additive
        let overlayPixels = try #require(overlay.straightPixels)
        let converted = try #require(BGRA8.converted(overlayPixels, width: 1, height: 1,
                                                     from: BGRA8.sRGB, to: p3.colorSpace))
        try document.importLayers([overlay])
        #expect(document.activeLayer.workingColorSpace == p3.colorSpace)
        #expect(document.activeLayer.straightPixels == converted)
        #expect(document.needsBlendComposite)
        var expected = try #require(base.straightPixels)
        overlay.blendMode.composite(converted, onto: &expected, opacity: overlay.opacity)
        let flattened = try #require(document.flattenedLayer())
        #expect(flattened.workingColorSpace == p3.colorSpace)
        #expect(flattened.straightPixels == expected)
    }

    @Test func grayscaleBitmapImportsUseTheUntaggedSRGBWorkingSpace() throws {
        let gray = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let bitmap = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.setFillColor(gray: 0.4, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(bitmap.makeImage())
        for format in [RasterFormat.png, .jpeg] {
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, format.rawValue as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            try #require(CGImageDestinationFinalize(destination))
            let input = try #require(CGImageSourceCreateWithData(data, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(input, 0, nil))
            #expect(decoded.colorSpace?.model == .monochrome)
            let expected = try #require(BGRA8.pixels(from: decoded))
            let raster = try PaintFiles.decodeRaster(data as Data)
            #expect(raster.colorProfile == nil)
            #expect(raster.image.colorSpace?.name == CGColorSpace.sRGB)
            #expect(BGRA8.pixels(from: raster.image) == expected)
        }
    }

    @MainActor @Test func assignAndConvertAreUndoableAndMalformedPDNLeavesDocumentIntact() throws {
        var seed = try #require(LayerStack.blank(width: 1, height: 1))
        let original = Data([69, 80, 128, 128])
        seed.layers[0] = try #require(seed.activeLayer.withPixels(original))
        let document = PaintDocument()
        document.undoManager?.groupsByEvent = false
        try document.read(from: PDNFile.write(seed), ofType: "Paint.NET Project")
        let p3 = try displayP3()
        try document.applyColorProfile(p3, converting: false)
        #expect(document.stack?.colorProfile == p3)
        #expect(document.stack?.activeLayer.straightPixels == original)
        #expect(document.historyEntries.last == "Assign Color Profile")
        let srgb = try #require(RGBColorProfile(colorSpace: BGRA8.sRGB))
        try document.applyColorProfile(srgb, converting: true)
        #expect(document.stack?.colorProfile == srgb)
        #expect(document.stack?.activeLayer.straightPixels != original)
        #expect(document.historyEntries.last == "Convert Color Profile")
        document.undoStroke(nil)
        #expect(document.stack?.colorProfile == p3)
        #expect(document.stack?.activeLayer.straightPixels == original)

        let malformed = PDNMetadata(key: "$exif.tag1[0]",
                                    value: "<exif id=\"34675\" len=\"200\" type=\"7\" value=\"AAAD\" />")
        seed.metadata.append(malformed)
        let malformedPDN = try PDNFile.write(seed)
        #expect(throws: PDNError.self) {
            try document.read(from: malformedPDN, ofType: "Paint.NET Project")
        }
        #expect(document.stack?.colorProfile == p3)
        #expect(document.stack?.activeLayer.straightPixels == original)
    }

    @Test func rejectsTruncatedAndOutOfBoundsICCTagTables() throws {
        let profile = try displayP3()
        #expect(RGBColorProfile(iccData: profile.iccData.dropLast()) == nil)
        var malformed = profile.iccData
        malformed.replaceSubrange(136..<140, with: [0xff, 0xff, 0xff, 0xff])
        #expect(RGBColorProfile(iccData: malformed) == nil)
    }

    private func displayP3() throws -> RGBColorProfile {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        return try #require(RGBColorProfile(colorSpace: space))
    }

    private func makeLayer(_ bytes: [UInt8], width: Int, in colorSpace: CGColorSpace) throws -> PaintLayer {
        let pixels = Data(bytes)
        let image = try #require(BGRA8.image(from: pixels, width: width, height: bytes.count / 4 / width,
                                             colorSpace: colorSpace))
        return PaintLayer(name: "Color Test", image: image, pdnPixels: pixels)
    }
}
