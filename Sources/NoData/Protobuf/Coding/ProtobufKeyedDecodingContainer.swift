import Foundation

struct ProtobufKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let fields: [String: JSONValue]
    let codingPath: [CodingKey]

    var allKeys: [Key] {
        fields.keys.compactMap { Key(stringValue: $0) }
    }

    func contains(_ key: Key) -> Bool {
        fields[key.stringValue] != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        fields[key.stringValue] == nil || fields[key.stringValue] == .null
    }

    func decode<Value: Decodable>(_: Value.Type, forKey key: Key) throws -> Value {
        let item = try value(forKey: key)
        if let direct = item as? Value {
            return direct
        }
        return try Value(from: ProtobufValueDecoder(value: item, codingPath: codingPath + [key]))
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try ProtobufValueDecoder(value: value(forKey: key), codingPath: codingPath + [key])
            .container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try ProtobufValueDecoder(value: value(forKey: key), codingPath: codingPath + [key])
            .unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        ProtobufValueDecoder(value: fields["super"] ?? .null, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        try ProtobufValueDecoder(value: value(forKey: key), codingPath: codingPath + [key])
    }

    private func value(forKey key: Key) throws -> JSONValue {
        guard let item = fields[key.stringValue] else {
            throw DecodingError.keyNotFound(
                key, .init(codingPath: codingPath, debugDescription: "Missing field \(key.stringValue)")
            )
        }
        return item
    }
}
