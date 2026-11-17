import Foundation
import Testing
@testable import Paint

struct PaintNETPDNInteroperabilityTests {
    private static let writerTags: Set<String> = [
        #"<exif id="305" len="14" type="2" value="UGFpbnQuTkVUIDUuMgA=" />"#, // Software: Paint.NET 5.2
        #"<exif id="40961" len="2" type="3" value="AQA=" />"#                  // ColorSpace: sRGB
    ]

    @Test func paintNETResavePreservesMacEdits() throws {
        let source = try Self.read(#require(PaintNETPixelReferenceTests.referenceFile("mac-edited.pdn")))
        let resaved = try Self.read(#require(PaintNETPixelReferenceTests.referenceFile("paintnet-resaved.pdn")))
        #expect(resaved.resolution == source.resolution)
        #expect(Set(resaved.metadata.map(\.value)).isSuperset(of: Self.writerTags))
        let retainedMetadata = resaved.metadata.filter { !Self.writerTags.contains($0.value) }
        #expect(Self.metadata(retainedMetadata) == Self.metadata(source.metadata))
        try #require(resaved.layers.count == source.layers.count)
        for (index, layers) in zip(source.layers, resaved.layers).enumerated() {
            let (expected, actual) = layers
            let label = Comment(rawValue: "Layer \(index): \(expected.name)")
            #expect(actual.name == expected.name, label)
            #expect(actual.opacity == expected.opacity, label)
            #expect(actual.isVisible == expected.isVisible, label)
            #expect(actual.isBackground == expected.isBackground, label)
            #expect(actual.blendMode == expected.blendMode, label)
            #expect(Self.metadata(actual.metadata) == Self.metadata(expected.metadata), label)
            try #require(actual.image.width == expected.image.width && actual.image.height == expected.image.height, label)
            let pixels = try #require(actual.pdnPixels)
            let sourcePixels = try #require(expected.pdnPixels)
            let difference = PaintNETPixelReferenceTests.differences(actual: pixels, expected: sourcePixels,
                                                                     width: expected.image.width)
            #expect(difference.count == 0, Comment(rawValue: "\(label.rawValue)\n\(difference.description)"))
        }
    }

    private static func read(_ url: URL) throws -> LayerStack {
        try PDNFile.read(Data(contentsOf: url))
    }

    private static func metadata(_ entries: [PDNMetadata]) -> [String: [String]] {
        Dictionary(grouping: entries) { entry in
            // Paint.NET renumbers EXIF entries when saving. Compare their directory and values.
            if entry.key.hasPrefix("$exif.tag"), let directory = entry.key.firstIndex(of: "[") {
                return "$exif" + entry.key[directory...]
            }
            return entry.key
        }.mapValues { $0.map(\.value).sorted() }
    }
}
