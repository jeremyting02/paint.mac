import Foundation

struct ImageResolution: Equatable {
    static let standard = Self(horizontal: 96, vertical: 96)!
    let horizontal: Double
    let vertical: Double

    init?(horizontal: Double, vertical: Double) {
        guard (0.01...100_000).contains(horizontal), (0.01...100_000).contains(vertical) else { return nil }
        self.horizontal = horizontal
        self.vertical = vertical
    }

    init?(metadata: [PDNMetadata]) {
        let tags = metadata.compactMap(ExifResolutionTag.init)
        let unit = tags.first { $0.id == .unit }?.unitValue
        // EXIF uses 2 for inches and 3 for centimeters.
        let scale = unit == 3 ? 2.54 : 1.0
        guard unit == nil || unit == 2 || unit == 3,
              let horizontal = tags.first(where: { $0.id == .horizontal })?.rationalValue,
              let vertical = tags.first(where: { $0.id == .vertical })?.rationalValue else { return nil }
        self.init(horizontal: horizontal * scale, vertical: vertical * scale)
    }

    var transposed: Self { Self(horizontal: vertical, vertical: horizontal)! }

    func updating(_ metadata: [PDNMetadata]) -> [PDNMetadata] {
        let updatedValues: [ExifResolutionTag.ID: ExifResolutionTag] = [
            .unit: ExifResolutionTag(id: .unit, data: ExifResolutionTag.littleEndianBytes(UInt16(2))),
            .horizontal: ExifResolutionTag(id: .horizontal, data: ExifResolutionTag.rationalBytes(horizontal)),
            .vertical: ExifResolutionTag(id: .vertical, data: ExifResolutionTag.rationalBytes(vertical))
        ]
        var found = Set<ExifResolutionTag.ID>()
        var updated = metadata.map { item in
            guard let tag = ExifResolutionTag(item), let replacement = updatedValues[tag.id] else { return item }
            found.insert(tag.id)
            return PDNMetadata(key: item.key, value: replacement.xml)
        }
        var keys = Set(metadata.map(\.key))
        var index = 1
        for id in ExifResolutionTag.ID.allCases where !found.contains(id) {
            var key = "$exif.tag\(index)[0]"
            while !keys.insert(key).inserted {
                index += 2
                key = "$exif.tag\(index)[0]"
            }
            updated.append(PDNMetadata(key: key, value: updatedValues[id]!.xml))
        }
        return updated
    }
}

private struct ExifResolutionTag {
    enum ID: Int, CaseIterable {
        case unit = 296, horizontal = 282, vertical = 283

        var fieldType: Int { self == .unit ? 3 : 5 }
        var byteCount: Int { self == .unit ? 2 : 8 }
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^<exif id="(282|283|296)" len="(2|8)" type="(3|5)" value="([A-Za-z0-9+/=]+)"\s*/>$"#)
    let id: ID
    let data: Data

    init(id: ID, data: Data) {
        self.id = id
        self.data = data
    }

    init?(_ item: PDNMetadata) {
        let source = item.value
        guard item.key.hasPrefix("$exif."), source.utf8.count <= 128,
              let match = Self.pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
        let attributes = (1...4).compactMap { Range(match.range(at: $0), in: source).map { String(source[$0]) } }
        guard attributes.count == 4, let rawID = Int(attributes[0]), let id = ID(rawValue: rawID),
              Int(attributes[1]) == id.byteCount, Int(attributes[2]) == id.fieldType,
              let data = Data(base64Encoded: attributes[3]), data.count == id.byteCount else { return nil }
        self.init(id: id, data: data)
    }

    var xml: String {
        "<exif id=\"\(id.rawValue)\" len=\"\(id.byteCount)\" type=\"\(id.fieldType)\" value=\"\(data.base64EncodedString())\" />"
    }

    var unitValue: UInt16? {
        guard id == .unit else { return nil }
        return data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
    }

    var rationalValue: Double? {
        guard id != .unit else { return nil }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let numerator = UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self))
            let denominator = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            return denominator == 0 ? nil : Double(numerator) / Double(denominator)
        }
    }

    static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func rationalBytes(_ dpi: Double) -> Data {
        let numerator = UInt32((dpi * 10_000).rounded())
        let denominator: UInt32 = 10_000
        var a = numerator, b = denominator
        while b > 0 { (a, b) = (b, a % b) }
        return littleEndianBytes(numerator / a) + littleEndianBytes(denominator / a)
    }
}

extension LayerStack {
    var resolution: ImageResolution? { ImageResolution(metadata: metadata) }
}
