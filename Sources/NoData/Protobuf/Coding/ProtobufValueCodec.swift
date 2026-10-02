import Foundation
import SwiftProtobuf

enum ProtobufValueCodec {
    static func encode(_ fields: [String: JSONValue]) throws -> Data {
        var object = Nodata_Storage_Object()
        object.fields = try fields.mapValues { try encodeValue($0).serializedData() }
        return try object.serializedData()
    }

    static func decode(_ data: Data) throws -> [String: JSONValue] {
        let object = try Nodata_Storage_Object(serializedBytes: data)
        return try object.fields.mapValues { try decodeValue(Nodata_Storage_Value(serializedBytes: $0)) }
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let fields = try decode(data)
        do {
            return try ProtobufValueDecoder.decode(type, fields: fields)
        } catch {
            return try JSONDecoder().decode(type, from: JSONEncoder().encode(fields))
        }
    }

    private static func encodeValue(_ value: JSONValue) throws -> Nodata_Storage_Value {
        var encoded = Nodata_Storage_Value()
        switch value {
        case .null:
            encoded.isNull = true
        case let .bool(item):
            encoded.boolValue = item
        case let .number(item):
            encoded.doubleValue = item
        case let .integer(item):
            encoded.int64Value = item
        case let .unsignedInteger(item):
            encoded.uint64Value = item
        case let .string(item):
            encoded.stringValue = item
        case let .array(items):
            var array = Nodata_Storage_Array()
            array.values = try items.map { try encodeValue($0).serializedData() }
            encoded.arrayValue = try array.serializedData()
        case let .object(fields):
            encoded.objectValue = try encode(fields)
        }
        return encoded
    }

    private static func decodeValue(_ value: Nodata_Storage_Value) throws -> JSONValue {
        switch value.kind {
        case .isNull(true):
            return .null
        case let .boolValue(item):
            return .bool(item)
        case let .doubleValue(item):
            return .number(item)
        case let .int64Value(item):
            return .integer(item)
        case let .uint64Value(item):
            return .unsignedInteger(item)
        case let .stringValue(item):
            return .string(item)
        case let .arrayValue(data):
            let array = try Nodata_Storage_Array(serializedBytes: data)
            return try .array(array.values.map { try decodeValue(Nodata_Storage_Value(serializedBytes: $0)) })
        case let .objectValue(data):
            return try .object(decode(data))
        case .none, .isNull(false):
            throw NoDataError.corruptLog
        }
    }
}
