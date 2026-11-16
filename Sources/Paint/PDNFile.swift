import CoreGraphics
import CZlib
import Foundation

struct PDNMetadata {
    let key: String
    let value: String
}

enum PDNFile {
    private static let byteLimit = 280 * 1024 * 1024
    private static let graphLimit = 4 * 1024 * 1024

    static func read(_ data: Data) throws -> LayerStack {
        guard data.count <= byteLimit else { throw PDNError.tooLarge }
        var reader = PDNBytes(data: data)
        guard try reader.take(4) == Data("PDN3".utf8) else { throw PDNError.invalid }
        let headerLength = try Int(reader.byte()) | Int(reader.byte()) << 8 | Int(reader.byte()) << 16
        _ = try reader.take(headerLength)
        guard try reader.little(UInt16.self) == 256 else { throw PDNError.invalid }

        let graphStart = data.startIndex + reader.offset
        let graphEnd = graphStart + min(reader.remaining, graphLimit)
        var records = PDNBytes(data: data[graphStart..<graphEnd])
        let graph = try PDNRecords(from: &records)
        _ = try reader.take(records.offset)
        let document = try graph.fields(.reference(graph.root), named: "PaintDotNet.Document")
        let width = try PDNRecords.integer(document["width"])
        let height = try PDNRecords.integer(document["height"])
        let list = try graph.fields(document["layers"], named: "PaintDotNet.LayerList")
        let count = try PDNRecords.integer(list["ArrayList+_size"])
        guard (1...4096).contains(width), (1...4096).contains(height),
              width * height <= 8_388_608, (1...LayerStack.limit).contains(count) else { throw PDNError.tooLarge }
        let items = try graph.array(list["ArrayList+_items"])
        guard items.count >= count else { throw PDNError.invalid }
        let documentMetadata = try metadata(document["userMetadataItems"], in: graph)
        if documentMetadata.contains(where: { $0.key.hasPrefix("$exif.") && $0.value.hasPrefix("<exif id=\"34675\"") }) {
            throw PDNError.unsupported("embedded color profile")
        }

        var surfaces: [Int: Int] = [:]
        let layers = try items.prefix(count).map { item in
            let layer = try graph.fields(item, named: "PaintDotNet.BitmapLayer")
            let props = try graph.fields(layer["Layer+properties"], named: "PaintDotNet.Layer+LayerProperties")
            let name = try graph.string(props["name"])
            let blendMode: LayerBlendMode?
            if let mode = props["blendMode"] {
                let blend = try graph.fields(mode, named: "PaintDotNet.LayerBlendMode")
                blendMode = try LayerBlendMode(rawValue: PDNRecords.integer(blend["value__"]))
            } else if let bitmapProperties = layer["properties"] {
                let legacy = try graph.fields(bitmapProperties, named: "PaintDotNet.BitmapLayer+BitmapLayerProperties")
                let legacyMode = try graph.className(legacy["blendOp"])
                blendMode = LayerBlendMode.allCases.first { $0.pdnClass == legacyMode }
            } else {
                blendMode = .normal
            }
            guard let blendMode else { throw PDNError.unsupported("blend mode on layer “\(name)”") }
            let surface = try graph.fields(layer["surface"], named: "PaintDotNet.Surface")
            let stride = try PDNRecords.integer(surface["stride"])
            let scan = try graph.fields(surface["scan0"], named: "PaintDotNet.MemoryBlock")
            guard case let .reference(block) = surface["scan0"],
                  try PDNRecords.integer(layer["Layer+width"]) == width,
                  try PDNRecords.integer(layer["Layer+height"]) == height,
                  try PDNRecords.integer(surface["width"]) == width,
                  try PDNRecords.integer(surface["height"]) == height,
                  stride == width * 4, try PDNRecords.integer(scan["length64"]) == stride * height,
                  try PDNRecords.integer(scan["deferred"]) == 1,
                  try PDNRecords.integer(scan["hasParent"]) == 0 else {
                throw PDNError.unsupported("pixel layout on layer “\(name)”")
            }
            let opacity = try PDNRecords.integer(props["opacity"])
            guard let alpha = UInt8(exactly: opacity) else { throw PDNError.invalid }
            surfaces[block] = stride * height
            return (block: block, name: name, alpha: alpha, blendMode: blendMode,
                    visible: try PDNRecords.integer(props["visible"]) != 0,
                    background: try PDNRecords.integer(props["isBackground"]) != 0,
                    metadata: try metadata(props["userMetadataItems"], in: graph))
        }

        var buffers: [Int: Data] = [:]
        for block in graph.memoryBlocks {
            guard let length = surfaces[block] else { throw PDNError.unsupported("extra pixel buffers") }
            buffers[block] = try readPixels(length: length, from: &reader)
        }
        guard reader.remaining == 0 else { throw PDNError.invalid }
        let images = try layers.map { layer in
            guard let pixels = buffers[layer.block],
                  let image = BGRA8.image(from: pixels, width: width, height: height) else { throw PDNError.invalid }
            return PaintLayer(name: layer.name, image: image, isVisible: layer.visible,
                              isBackground: layer.background, opacity: layer.alpha, blendMode: layer.blendMode,
                              metadata: layer.metadata, pdnPixels: pixels)
        }
        return LayerStack(layers: images, active: images.count - 1, metadata: documentMetadata)
    }

    private static func metadata(_ value: PDNRecords.Value?, in graph: PDNRecords) throws -> [PDNMetadata] {
        switch value {
        case nil, .null: return []
        default:
            return try graph.array(value).map { record in
                let pair = try graph.fields(record)
                let key = try graph.string(pair["key"])
                return PDNMetadata(key: key, value: try graph.string(pair["value"]))
            }
        }
    }

    private static func readPixels(length: Int, from reader: inout PDNBytes) throws -> Data {
        let format = try reader.byte()
        let stride = try reader.big()
        guard (format == 0 || format == 1), stride > 0 else { throw PDNError.invalid }
        let count = (length - 1) / stride + 1
        guard count <= 8192, count <= reader.remaining / 8 else { throw PDNError.invalid }
        var pixels = Data(count: length)
        var seen = Set<Int>()
        for _ in 0..<count {
            let index = try reader.big()
            let size = try reader.big()
            guard index < count, seen.insert(index).inserted else { throw PDNError.invalid }
            let offset = index * stride
            let expected = min(length - offset, stride)
            let input = try reader.take(size)
            let range = offset..<(offset + expected)
            if format == 0 {
                try pixels.withUnsafeMutableBytes { output in
                    try unzip(input, into: UnsafeMutableRawBufferPointer(rebasing: output[range]))
                }
            } else {
                guard size == expected else { throw PDNError.invalid }
                pixels.replaceSubrange(range, with: input)
            }
        }
        return pixels
    }

    private static func unzip(_ input: Data, into output: UnsafeMutableRawBufferPointer) throws {
        guard !input.isEmpty else { throw PDNError.invalid }
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw PDNError.invalid }
        defer { inflateEnd(&stream) }
        try input.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(input.count)
            stream.next_out = output.bindMemory(to: UInt8.self).baseAddress
            stream.avail_out = UInt32(output.count)
            guard inflate(&stream, Z_FINISH) == Z_STREAM_END, stream.avail_in == 0, stream.avail_out == 0
            else { throw PDNError.invalid }
        }
    }

    static func write(_ stack: LayerStack) throws -> Data {
        let width = stack.activeLayer.image.width
        let height = stack.activeLayer.image.height
        var writer = PDNWriter(width: width, height: height, stack: stack)
        guard writer.data.count <= graphLimit else { throw PDNError.unsupported("oversized project metadata") }
        for layer in stack.layers {
            guard let pixels = layer.pdnPixels ?? BGRA8.pixels(from: layer.image) else { throw CocoaError(.fileWriteUnknown) }
            try writer.pixels(pixels)
        }
        return writer.data
    }
}
