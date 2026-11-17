import CoreGraphics
import ColorSync
import Foundation

struct RGBColorProfile: Equatable {
    static let maximumBytes = 2 * 1024 * 1024
    let colorSpace: CGColorSpace
    let iccData: Data

    init?(iccData: Data) {
        guard Self.hasValidRGBHeader(iccData),
              let colorSpace = CGColorSpace(iccData: iccData as CFData), colorSpace.model == .rgb,
              colorSpace.supportsOutput
        else { return nil }
        self.colorSpace = colorSpace
        self.iccData = iccData
    }

    init?(colorSpace: CGColorSpace) {
        guard colorSpace.model == .rgb, let data = colorSpace.copyICCData() as Data? else { return nil }
        self.init(iccData: data)
    }

    static func usefulProfile(for colorSpace: CGColorSpace?) -> Self? {
        guard let colorSpace, colorSpace.name != CGColorSpace.sRGB else { return nil }
        return Self(colorSpace: colorSpace)
    }

    var name: String {
        guard let profile = ColorSyncProfileCreate(iccData as CFData, nil)?.takeRetainedValue(),
              let description = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue()
        else { return "Embedded RGB Profile" }
        return description as String
    }

    static func == (left: Self, right: Self) -> Bool { left.iccData == right.iccData }

    private static func hasValidRGBHeader(_ data: Data) -> Bool {
        guard data.count >= 132, data.count <= maximumBytes else { return false }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func uint32(_ offset: Int) -> UInt32 {
                UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }

            let declaredSize = Int(uint32(0))
            let tagCount = Int(uint32(128))
            guard declaredSize == data.count,
                  uint32(16) == 0x52474220, // RGB with the trailing space.
                  uint32(36) == 0x61637370, // ICC profile signature.
                  tagCount > 0, tagCount <= (declaredSize - 132) / 12
            else { return false }

            let tableEnd = 132 + tagCount * 12
            for index in 0..<tagCount {
                let entry = 132 + index * 12
                let start = Int(uint32(entry + 4)), length = Int(uint32(entry + 8))
                guard start >= tableEnd, start <= declaredSize, length > 0, length <= declaredSize - start
                else { return false }
            }
            return true
        }
    }
}

extension RGBColorProfile {
    private static let iccTagID = "34675"
    private static let colorSpaceTagID = "40961"
    private static let attributes = try! NSRegularExpression(pattern: #"([A-Za-z]+)="([^"]*)""#)

    private static func isExifTag(_ item: PDNMetadata, id: String) -> Bool {
        item.key.hasPrefix("$exif.") && item.value.hasPrefix("<exif ") && item.value.contains(" id=\"\(id)\"")
    }

    static func read(from metadata: [PDNMetadata]) throws -> Self? {
        let tags = metadata.filter { isExifTag($0, id: iccTagID) }
        guard let tag = tags.first else { return nil }
        guard tags.count == 1, let data = profileData(from: tag.value), let profile = Self(iccData: data) else {
            throw PDNError.unsupported("malformed or non-RGB embedded color profile")
        }
        return profile
    }

    private static func profileData(from value: String) -> Data? {
        guard value.utf8.count <= 4 * (maximumBytes + 2) / 3 + 128,
              value.hasSuffix("/>") else { return nil }
        var fields: [String: String] = [:]
        for match in attributes.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let name = Range(match.range(at: 1), in: value),
                  let field = Range(match.range(at: 2), in: value) else { return nil }
            guard fields.updateValue(String(value[field]), forKey: String(value[name])) == nil else { return nil }
        }
        guard fields["id"] == iccTagID, fields["type"] == "7",
              let encoded = fields["value"], let claimedLength = fields["len"].flatMap(Int.init),
              (132...maximumBytes).contains(claimedLength), encoded.utf8.count == 4 * ((claimedLength + 2) / 3),
              let data = Data(base64Encoded: encoded), data.count == claimedLength
        else { return nil }
        return data
    }

    func embedding(in metadata: [PDNMetadata]) -> [PDNMetadata] {
        if metadata.filter({ Self.isExifTag($0, id: Self.iccTagID) }).count == 1,
           let prior = metadata.first(where: { Self.isExifTag($0, id: Self.iccTagID) }),
           Self.profileData(from: prior.value) == iccData { return metadata }
        var result = metadata.filter {
            !Self.isExifTag($0, id: Self.iccTagID) && !Self.isExifTag($0, id: Self.colorSpaceTagID)
        }
        let keys = Set(result.map(\.key))
        var index = 1
        while keys.contains("$exif.tag\(index)[0]") { index += 2 }
        result.append(PDNMetadata(
            key: "$exif.tag\(index)[0]",
            value: "<exif id=\"\(Self.iccTagID)\" len=\"\(iccData.count)\" type=\"7\" value=\"\(iccData.base64EncodedString())\" />"
        ))
        return result
    }
}
