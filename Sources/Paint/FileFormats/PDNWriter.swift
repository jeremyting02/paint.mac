import CZlib
import Foundation

struct PDNWriter {
    private enum MemberType {
        case primitive(UInt8), string, system(String), object(String, Int = 2), objectArray

        var tag: UInt8 {
            switch self {
            case .primitive: return 0
            case .string: return 1
            case .system: return 3
            case .object: return 4
            case .objectArray: return 5
            }
        }
    }

    private static let version = [5, 200, 9793, 3533]
    private static let pair = "System.Collections.Generic.KeyValuePair`2[[System.String, mscorlib, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089],[System.String, mscorlib, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089]]"
    private static let int = MemberType.primitive(8)
    private static let bool = MemberType.primitive(1)
    private static let metadataType = MemberType.system(pair + "[]")

    private(set) var data = Data("PDN3".utf8)
    private var nextID = 7

    init(width: Int, height: Int, stack: LayerStack) {
        let version = Self.version.map(String.init).joined(separator: ".")
        let count = stack.layers.count
        let header = Data("<pdnImage width=\"\(width)\" height=\"\(height)\" layers=\"\(count)\" savedWithVersion=\"\(version)\"><custom /></pdnImage>".utf8)
        for shift in [0, 8, 16] { data.append(UInt8(truncatingIfNeeded: header.count >> shift)) }
        data.append(header)
        data.append(contentsOf: [0, 1, 0])
        for value in [1, -1, 1, 0] { int(value) }
        for (id, name) in [(2, "Data"), (6, "Core")] {
            data.append(12)
            int(id)
            string("PaintDotNet.\(name), Version=\(version), Culture=neutral, PublicKeyToken=null")
        }

        let documentMetadata = id()
        let array = id()
        let layerIDs = stack.layers.map { _ in id() }
        object(1, "PaintDotNet.Document", fields: [
            ("isDisposed", Self.bool), ("layers", .object("PaintDotNet.LayerList")),
            ("width", Self.int), ("height", Self.int), ("savedWith", .system("System.Version")),
            ("userMetadataItems", Self.metadataType)
        ])
        data.append(0)
        reference(3)
        int(width)
        int(height)
        reference(4)
        reference(documentMetadata)

        object(3, "PaintDotNet.LayerList", fields: [
            ("parent", .object("PaintDotNet.Document")), ("ArrayList+_items", .objectArray),
            ("ArrayList+_size", Self.int), ("ArrayList+_version", Self.int)
        ])
        reference(1)
        reference(array)
        int(count)
        int(count)
        object(4, "System.Version", library: nil, fields: [
            ("_Major", Self.int), ("_Minor", Self.int), ("_Build", Self.int), ("_Revision", Self.int)
        ])
        for value in Self.version { int(value) }
        metadata(stack.metadata, id: documentMetadata)
        data.append(16)
        int(array)
        int(count)
        for id in layerIDs { reference(id) }
        for (id, layer) in zip(layerIDs, stack.layers) { bitmapLayer(layer, id: id, width: width, height: height) }
        data.append(11)
    }

    private mutating func bitmapLayer(_ layer: PaintLayer, id layerID: Int, width: Int, height: Int) {
        let legacy = id(), surface = id(), properties = id(), blendOp = id(), memory = id(), layerMetadata = id()
        let blendClass = layer.blendMode.pdnClass
        object(layerID, "PaintDotNet.BitmapLayer", fields: [
            ("properties", .object("PaintDotNet.BitmapLayer+BitmapLayerProperties")),
            ("surface", .object("PaintDotNet.Surface", 6)), ("Layer+isDisposed", Self.bool),
            ("Layer+width", Self.int), ("Layer+height", Self.int),
            ("Layer+properties", .object("PaintDotNet.Layer+LayerProperties"))
        ])
        reference(legacy)
        reference(surface)
        data.append(0)
        int(width)
        int(height)
        reference(properties)

        object(legacy, "PaintDotNet.BitmapLayer+BitmapLayerProperties", fields: [
            ("blendOp", .object(blendClass))
        ])
        reference(blendOp)
        object(blendOp, blendClass, fields: [])
        object(surface, "PaintDotNet.Surface", library: 6, fields: [
            ("width", Self.int), ("height", Self.int), ("stride", Self.int),
            ("scan0", .object("PaintDotNet.MemoryBlock", 6))
        ])
        int(width)
        int(height)
        int(width * 4)
        reference(memory)
        object(memory, "PaintDotNet.MemoryBlock", library: 6, fields: [
            ("length64", .primitive(9)), ("hasParent", Self.bool), ("deferred", Self.bool)
        ])
        append(Int64(width * height * 4).littleEndian)
        data.append(contentsOf: [0, 1])

        object(properties, "PaintDotNet.Layer+LayerProperties", fields: [
            ("name", .string), ("userMetadataItems", Self.metadataType), ("visible", Self.bool),
            ("isBackground", Self.bool), ("opacity", .primitive(2)), ("blendMode", .object("PaintDotNet.LayerBlendMode"))
        ])
        objectString(layer.name)
        reference(layerMetadata)
        data.append(contentsOf: [layer.isVisible ? 1 : 0, layer.isBackground ? 1 : 0, layer.opacity])
        let blend = -id()
        object(blend, "PaintDotNet.LayerBlendMode", fields: [("value__", Self.int)])
        int(layer.blendMode.rawValue)
        metadata(layer.metadata, id: layerMetadata)
    }

    private mutating func metadata(_ items: [PDNMetadata], id arrayID: Int) {
        data.append(7)
        int(arrayID)
        data.append(0)
        int(1)
        int(items.count)
        data.append(3)
        string(Self.pair)
        for item in items {
            let itemID = -id()
            object(itemID, Self.pair, library: nil, fields: [("key", .string), ("value", .string)])
            objectString(item.key)
            objectString(item.value)
        }
    }

    private mutating func object(_ id: Int, _ name: String, library: Int? = 2, fields: [(String, MemberType)]) {
        data.append(library == nil ? 4 : 5)
        int(id)
        string(name)
        int(fields.count)
        for (key, _) in fields { string(key) }
        for (_, type) in fields { data.append(type.tag) }
        for (_, type) in fields {
            switch type {
            case let .primitive(code): data.append(code)
            case let .system(name): string(name)
            case let .object(name, library):
                string(name)
                int(library)
            case .string, .objectArray: break
            }
        }
        if let library { int(library) }
    }

    private mutating func objectString(_ value: String) {
        data.append(6)
        let stringID = id()
        int(stringID)
        string(value)
    }

    private mutating func reference(_ id: Int) {
        data.append(9)
        int(id)
    }

    private mutating func id() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private mutating func int(_ value: Int) { append(Int32(value).littleEndian) }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    private mutating func string(_ value: String) {
        let utf8 = value.utf8
        var length = utf8.count
        while length >= 128 {
            data.append(UInt8(truncatingIfNeeded: length) | 128)
            length >>= 7
        }
        data.append(UInt8(length))
        data.append(contentsOf: utf8)
    }

    mutating func pixels(_ pixels: Data) throws {
        let chunkSize = 256 * 1024
        data.append(0)
        append(UInt32(chunkSize).bigEndian)
        for (index, offset) in stride(from: 0, to: pixels.count, by: chunkSize).enumerated() {
            let start = pixels.startIndex + offset
            let end = start + min(chunkSize, pixels.count - offset)
            let compressed = try Self.gzip(pixels[start..<end])
            append(UInt32(index).bigEndian)
            append(UInt32(compressed.count).bigEndian)
            data.append(compressed)
        }
    }

    private static func gzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_BEST_SPEED, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw CocoaError(.fileWriteUnknown) }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, UInt(input.count))))
        try input.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            try output.withUnsafeMutableBytes { (compressed: UnsafeMutableRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = UInt32(bytes.count)
                stream.next_out = compressed.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = UInt32(compressed.count)
                guard deflate(&stream, Z_FINISH) == Z_STREAM_END else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        return output.prefix(Int(stream.total_out))
    }
}
