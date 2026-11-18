import AppKit
import ImageIO
import Testing
@testable import Paint

struct PaintNETBrushReferenceTests {
    private struct CapturedPath: Decodable {
        struct Point: Decodable {
            let x: Double
            let y: Double
        }

        let spacing: Int
        let input: [Point]
        let centers: [Point]
    }

    @Test(arguments: [100, 25])
    func pathMatchesCapturedDabCentersAndShortStrokeSpacing(_ hardness: Int) throws {
        let url = try #require(PaintNETPixelReferenceTests.referenceFile("brush-paths.json"))
        let captures = try JSONDecoder().decode([CapturedPath].self, from: Data(contentsOf: url))
        let width = 40, height = 24
        let blank = Data(count: width * height * 4)
        let image = try #require(BGRA8.image(from: blank, width: width, height: height))
        let layer = PaintLayer(name: "Fixed brush path", image: image, pdnPixels: blank)
        let color = DrawingColor(.black)
        let operation = RasterDrawing.Operation.paint(primary: color, secondary: color)

        for capture in captures {
            var options = BrushOptions()
            options.hardness = hardness
            options.spacing = capture.spacing
            options.smoothed = false
            let stroke = try #require(RasterDrawing(layer: layer, operation: operation, diameter: 9,
                                                    selection: nil, options: options))
            var path = BrushPath(diameter: 9, options: options)
            var actualCenters: [CGPoint] = []
            for point in capture.input {
                let center = CGPoint(x: point.x, y: Double(height) - point.y)
                path.append(.init(point: center, pressure: 1)) { actualCenters.append($0.point) }
                stroke.append(center)
            }
            path.finish { actualCenters.append($0.point) }
            stroke.finish()
            try #require(actualCenters.count == capture.centers.count)
            for (actual, expected) in zip(actualCenters, capture.centers) {
                #expect(abs(actual.x - expected.x) < 0.000_01)
                #expect(abs(actual.y - (Double(height) - expected.y)) < 0.000_01)
            }

            // Verify that the complete stroke uses precisely the coverage of
            // those dabs, including the fractional edges and their overlaps.
            var expectedAlpha = [UInt8](repeating: 0, count: width * height)
            for center in capture.centers {
                let dab = try #require(RasterDrawing(layer: layer, operation: operation, diameter: 9,
                                                     selection: nil, options: options))
                dab.append(CGPoint(x: center.x, y: Double(height) - center.y))
                dab.finish()
                let pixels = try #require(dab.preview?.straightPixels)
                for index in expectedAlpha.indices {
                    expectedAlpha[index] = max(expectedAlpha[index], pixels[index * 4 + 3])
                }
            }
            let pixels = try #require(stroke.preview?.straightPixels)
            #expect(expectedAlpha.indices.allSatisfy {
                abs(Int(expectedAlpha[$0]) - Int(pixels[$0 * 4 + 3])) <= 1
            })
        }
    }

    @Test(arguments: [100, 25])
    func antialiasedDabCoverageApproximatesExistingPaintNETCapture(_ hardness: Int) throws {
        let (input, expected) = try loadDabs()
        let color = DrawingColor(.black)
        var options = BrushOptions()
        options.hardness = hardness
        let layer = PaintLayer(name: "Brush capture", image: input)
        let drawing = try #require(RasterDrawing(layer: layer, operation: .paint(primary: color, secondary: color),
                                                 diameter: 9, selection: nil, options: options))
        // The original click positions were not recorded. Estimate each center
        // from the alpha-weighted centroid of black pixels in the reference.
        let columns = hardness == 100 ? 0..<16 : 16..<32
        var sumX = 0.0, sumY = 0.0, mass = 0.0
        for y in 0..<input.height {
            for x in columns {
                let offset = (y * input.width + x) * 4
                guard expected[offset] == 0 && expected[offset + 1] == 0 && expected[offset + 2] == 0 else { continue }
                let alpha = Double(expected[offset + 3])
                sumX += alpha * (Double(x) + 0.5)
                sumY += alpha * (Double(y) + 0.5)
                mass += alpha
            }
        }
        try #require(mass > 0)
        drawing.append(CGPoint(x: sumX / mass, y: Double(input.height) - sumY / mass))
        drawing.finish()
        let actual = try #require(drawing.preview?.straightPixels)
        var squaredError = 0.0
        for y in 0..<input.height {
            for x in columns {
                let index = (y * input.width + x) * 4 + 3
                let delta = Double(actual[index]) - Double(expected[index])
                squaredError += delta * delta
            }
        }
        let rmse = sqrt(squaredError / Double(columns.count * input.height))
        let tolerance = hardness == 100 ? 3.7 : 1.5
        #expect(rmse <= tolerance, Comment(rawValue: "Alpha RMSE: \(rmse), tolerance: \(tolerance)"))
    }

    @Test func evenAliasedDabMatchesPaintNET52() throws {
        let (input, bgra) = try loadDabs()
        let color = DrawingColor(.black)
        let layer = PaintLayer(name: "Brush capture", image: input)
        var options = BrushOptions()
        options.antialiased = false
        let drawing = try #require(RasterDrawing(layer: layer, operation: .paint(primary: color, secondary: color),
                                                 diameter: 8, selection: nil, options: options))
        drawing.append(CGPoint(x: 40.5, y: 8.5))
        drawing.finish()
        let result = try #require(drawing.preview?.straightPixels)

        let left = 32
        let width = input.width - left
        var actual = Data()
        var expected = Data()
        for row in 0..<input.height {
            let start = 4 * (row * input.width + left)
            actual.append(contentsOf: result[start..<(start + width * 4)])
            expected.append(contentsOf: bgra[start..<(start + width * 4)])
        }
        let differences = PaintNETPixelReferenceTests.differences(actual: actual, expected: expected, width: width)
        #expect(differences.count == 0, Comment(rawValue: differences.description))
    }

    private func loadDabs() throws -> (CGImage, Data) {
        let directory = PaintNETPixelReferenceTests.fixtureDirectory
        let input = try PaintFiles.readRaster(Data(contentsOf: directory.appendingPathComponent("brush-dabs-input.png")),
                                              expected: .png)
        let url = try #require(PaintNETPixelReferenceTests.referenceFile("brush-dabs.png"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let reference = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try #require(reference.width == 49 && reference.height == 17)
        try #require(reference.width == input.width && reference.height == input.height)
        return (input, try PaintNETPixelReferenceTests.storedBGRA(in: reference))
    }
}
