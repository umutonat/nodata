import Foundation

struct ProtobufSingleValueEncodingContainer: SingleValueEncodingContainer {
    let box: ProtobufValueBox
    let codingPath: [CodingKey]

    mutating func encodeNil() throws {
        box.scalar = .null
    }

    mutating func encode(_ value: Bool) throws {
        box.scalar = .bool(value)
    }

    mutating func encode(_ value: String) throws {
        box.scalar = .string(value)
    }

    mutating func encode(_ value: Double) throws {
        box.scalar = .number(value)
    }

    mutating func encode(_ value: Float) throws {
        box.scalar = .number(Double(value))
    }

    mutating func encode(_ value: Int) throws {
        box.scalar = .integer(Int64(value))
    }

    mutating func encode(_ value: Int8) throws {
        box.scalar = .integer(Int64(value))
    }

    mutating func encode(_ value: Int16) throws {
        box.scalar = .integer(Int64(value))
    }

    mutating func encode(_ value: Int32) throws {
        box.scalar = .integer(Int64(value))
    }

    mutating func encode(_ value: Int64) throws {
        box.scalar = .integer(value)
    }

    mutating func encode(_ value: UInt) throws {
        box.scalar = .unsignedInteger(UInt64(value))
    }

    mutating func encode(_ value: UInt8) throws {
        box.scalar = .unsignedInteger(UInt64(value))
    }

    mutating func encode(_ value: UInt16) throws {
        box.scalar = .unsignedInteger(UInt64(value))
    }

    mutating func encode(_ value: UInt32) throws {
        box.scalar = .unsignedInteger(UInt64(value))
    }

    mutating func encode(_ value: UInt64) throws {
        box.scalar = .unsignedInteger(value)
    }

    mutating func encode(_ value: some Encodable) throws {
        try value.encode(to: ProtobufValueEncoder(box: box, codingPath: codingPath))
    }
}
