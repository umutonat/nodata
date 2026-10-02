import Foundation

final class ProtobufValueDecoder: Decoder {
    let value: JSONValue
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    init(value: JSONValue, codingPath: [CodingKey] = []) {
        self.value = value
        self.codingPath = codingPath
    }

    static func decode<Value: Decodable>(_: Value.Type, fields: [String: JSONValue]) throws -> Value {
        try Value(from: ProtobufValueDecoder(value: .object(fields)))
    }

    func container<Key: CodingKey>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case let .object(fields) = value else {
            throw DecodingError.typeMismatch(
                [String: JSONValue].self,
                .init(codingPath: codingPath, debugDescription: "Expected an object")
            )
        }
        return KeyedDecodingContainer(ProtobufKeyedDecodingContainer(fields: fields, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case let .array(items) = value else {
            throw DecodingError.typeMismatch(
                [JSONValue].self,
                .init(codingPath: codingPath, debugDescription: "Expected an array")
            )
        }
        return ProtobufUnkeyedDecodingContainer(items: items, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        ProtobufSingleValueDecodingContainer(value: value, codingPath: codingPath)
    }
}
