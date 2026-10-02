import Foundation

struct ProtobufSingleValueDecodingContainer: SingleValueDecodingContainer {
    let value: JSONValue
    let codingPath: [CodingKey]

    func decodeNil() -> Bool {
        value == .null
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case let .bool(item) = value else { throw mismatch(type) }
        return item
    }

    func decode(_ type: String.Type) throws -> String {
        guard case let .string(item) = value else { throw mismatch(type) }
        return item
    }

    func decode(_ type: Double.Type) throws -> Double {
        switch value {
        case let .number(item): return item
        case let .integer(item): return Double(item)
        case let .unsignedInteger(item): return Double(item)
        default: throw mismatch(type)
        }
    }

    func decode(_: Float.Type) throws -> Float {
        try Float(decode(Double.self))
    }

    func decode(_ type: Int.Type) throws -> Int {
        try integer(type)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        try integer(type)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        try integer(type)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        try integer(type)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try integer(type)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        try integer(type)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try integer(type)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try integer(type)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try integer(type)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try integer(type)
    }

    func decode<Value: Decodable>(_: Value.Type) throws -> Value {
        if let direct = value as? Value {
            return direct
        }
        return try Value(from: ProtobufValueDecoder(value: value, codingPath: codingPath))
    }

    private func integer<Integer: FixedWidthInteger>(_ type: Integer.Type) throws -> Integer {
        let result: Integer? = switch value {
        case let .integer(item): Integer(exactly: item)
        case let .unsignedInteger(item): Integer(exactly: item)
        case let .number(item): Integer(exactly: item)
        default: nil
        }
        guard let result else { throw mismatch(type) }
        return result
    }

    private func mismatch(_ type: (some Any).Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Unexpected protobuf value"))
    }
}
