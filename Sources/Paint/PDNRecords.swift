import Foundation

enum PDNError: LocalizedError {
    case invalid, tooLarge, unsupported(String)

    var errorDescription: String? {
        failureReason
    }

    var failureReason: String? {
        switch self {
        case .invalid: return "The file is damaged or is not a supported Paint.NET project."
        case .tooLarge: return "Paint.NET projects can have up to eight layers and 4,096 pixels per side, with at most 8,388,608 pixels per layer."
        case let .unsupported(setting): return "This Paint.NET project uses an unsupported setting: \(setting)."
        }
    }
}

struct PDNBytes {
    let data: Data
    private(set) var offset = 0
    var remaining: Int { data.count - offset }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw PDNError.invalid }
        let start = data.startIndex + offset
        offset += count
        return data[start..<(start + count)]
    }

    mutating func byte() throws -> UInt8 {
        guard remaining > 0 else { throw PDNError.invalid }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func little<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        let bytes = try take(MemoryLayout<T>.size)
        return bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }

    mutating func int() throws -> Int { try Int(little(Int32.self)) }
    mutating func big() throws -> Int { try Int(UInt32(bigEndian: little(UInt32.self))) }

    mutating func string() throws -> String {
        var length = 0
        for shift in stride(from: 0, through: 28, by: 7) {
            let part = try byte()
            length |= Int(part & 127) << shift
            if part < 128 {
                guard length <= 1_048_576, let string = try String(data: take(length), encoding: .utf8)
                else { throw PDNError.invalid }
                return string
            }
        }
        throw PDNError.invalid
    }
}

// The PDN3 metadata is an NRBF graph. Parse records as plain values.
struct PDNRecords {
    enum Value {
        case null, integer(Int), string(String), reference(Int)
    }

    enum Object {
        case fields(String, [String: Value]), array([Value]), string(String)
    }

    private struct FieldType {
        let kind: UInt8
        var primitive: UInt8 = 0

        mutating func readDetail(from reader: inout PDNBytes) throws {
            switch kind {
            case 0, 7: primitive = try reader.byte()
            case 3: _ = try reader.string()
            case 4:
                _ = try reader.string()
                _ = try reader.int()
            case 1, 2, 5, 6: break
            default: throw PDNError.invalid
            }
        }
    }

    private struct Schema {
        let name: String
        let fields: [String]
        let types: [FieldType]
    }

    private(set) var root = 0
    private(set) var objects: [Int: Object] = [:]
    private(set) var memoryBlocks: [Int] = []
    private var schemas: [Int: Schema] = [:]
    private var arrayItems = 0

    init(from reader: inout PDNBytes) throws {
        guard try reader.byte() == 0 else { throw PDNError.invalid }
        root = try reader.int()
        _ = try reader.int()
        guard try reader.int() == 1, try reader.int() == 0 else { throw PDNError.invalid }
        while case let kind = try reader.byte(), kind != 11 {
            try record(kind, from: &reader, depth: 0)
        }
    }

    func fields(_ value: Value?, named expected: String? = nil) throws -> [String: Value] {
        guard case let .reference(id) = value, case let .fields(name, fields) = objects[id],
              expected == nil || name == expected else { throw PDNError.invalid }
        return fields
    }

    func array(_ value: Value?) throws -> [Value] {
        guard case let .reference(id) = value, case let .array(items) = objects[id] else { throw PDNError.invalid }
        return items
    }

    func string(_ value: Value?) throws -> String {
        if case let .string(text) = value { return text }
        guard case let .reference(id) = value, case let .string(text) = objects[id] else { throw PDNError.invalid }
        return text
    }

    static func integer(_ value: Value?) throws -> Int {
        guard case let .integer(number) = value else { throw PDNError.invalid }
        return number
    }

    private mutating func put(_ id: Int, _ object: Object) throws -> Value {
        guard id != 0, objects[id] == nil, objects.count < 8_192 else { throw PDNError.invalid }
        objects[id] = object
        return .reference(id)
    }

    @discardableResult
    private mutating func record(_ kind: UInt8, from reader: inout PDNBytes, depth: Int) throws -> Value {
        guard depth < 48 else { throw PDNError.invalid }
        switch kind {
        case 1:
            let id = try reader.int()
            guard let schema = try schemas[reader.int()] else { throw PDNError.invalid }
            return try fields(id, schema, from: &reader, depth: depth)
        case 4, 5:
            let id = try reader.int()
            let name = try reader.string()
            let count = try reader.int()
            guard (0...128).contains(count) else { throw PDNError.invalid }
            let names = try (0..<count).map { _ in try reader.string() }
            var types = try (0..<count).map { _ in FieldType(kind: try reader.byte()) }
            for index in types.indices { try types[index].readDetail(from: &reader) }
            if kind == 5 { _ = try reader.int() }
            let schema = Schema(name: name, fields: names, types: types)
            schemas[id] = schema
            return try fields(id, schema, from: &reader, depth: depth)
        case 6:
            return try put(reader.int(), .string(reader.string()))
        case 7, 15, 16, 17:
            return try array(kind, from: &reader, depth: depth)
        case 8:
            let code = try reader.byte()
            return try Self.primitive(code, from: &reader)
        case 9: return try .reference(reader.int())
        case 10: return .null
        case 12:
            _ = try reader.int()
            _ = try reader.string()
            return .null
        default: throw PDNError.invalid
        }
    }

    private mutating func fields(_ id: Int, _ schema: Schema, from reader: inout PDNBytes, depth: Int) throws -> Value {
        if schema.name == "PaintDotNet.MemoryBlock" { memoryBlocks.append(id) }
        var fields: [String: Value] = [:]
        for (name, type) in zip(schema.fields, schema.types) {
            if type.kind == 0 {
                fields[name] = try Self.primitive(type.primitive, from: &reader)
            } else {
                var kind = try reader.byte()
                while kind == 12 {
                    try record(kind, from: &reader, depth: depth + 1)
                    kind = try reader.byte()
                }
                fields[name] = try record(kind, from: &reader, depth: depth + 1)
            }
        }
        return try put(id, .fields(schema.name, fields))
    }

    private mutating func array(_ kind: UInt8, from reader: inout PDNBytes, depth: Int) throws -> Value {
        let id = try reader.int()
        let count: Int
        var type = FieldType(kind: 2)
        if kind == 7 {
            let shape = try reader.byte()
            guard shape == 0 || shape == 1, try reader.int() == 1 else { throw PDNError.invalid }
            count = try reader.int()
            type = FieldType(kind: try reader.byte())
            try type.readDetail(from: &reader)
        } else {
            count = try reader.int()
            if kind == 15 { type = FieldType(kind: 0, primitive: try reader.byte()) }
        }
        guard (0...1_048_576).contains(count) else { throw PDNError.invalid }
        // Primitive byte arrays can hold a color profile or other opaque metadata.
        if type.kind == 0, type.primitive == 2 {
            _ = try reader.take(count)
            return try put(id, .array(count == 0 ? [] : [.null]))
        }
        arrayItems += count
        guard arrayItems <= 65_536 else { throw PDNError.invalid }
        var items: [Value] = []
        while items.count < count {
            if type.kind == 0 {
                items.append(try Self.primitive(type.primitive, from: &reader))
                continue
            }
            let item = try reader.byte()
            switch item {
            case 12: try record(item, from: &reader, depth: depth + 1)
            case 13, 14:
                let run = try item == 13 ? Int(reader.byte()) : reader.int()
                guard run > 0, run <= count - items.count else { throw PDNError.invalid }
                items.append(contentsOf: repeatElement(.null, count: run))
            default:
                items.append(try record(item, from: &reader, depth: depth + 1))
            }
        }
        return try put(id, .array(items))
    }

    private static func primitive(_ kind: UInt8, from reader: inout PDNBytes) throws -> Value {
        switch kind {
        case 1, 2: return try .integer(Int(reader.byte()))
        case 7: return try .integer(Int(reader.little(Int16.self)))
        case 8: return try .integer(reader.int())
        case 9, 12, 13: return try .integer(Int(reader.little(Int64.self)))
        case 10: return try .integer(Int(Int8(bitPattern: reader.byte())))
        case 14: return try .integer(Int(reader.little(UInt16.self)))
        case 6, 16: return try .integer(Int(truncatingIfNeeded: reader.little(UInt64.self)))
        case 11, 15: return try .integer(Int(reader.little(UInt32.self)))
        case 5, 18: return try .string(reader.string())
        default: throw PDNError.invalid
        }
    }
}
