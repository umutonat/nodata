import Foundation

struct ProtobufKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let box: ProtobufValueBox
    let codingPath: [CodingKey]

    mutating func encodeNil(forKey key: Key) throws {
        let child = ProtobufValueBox()
        child.scalar = .null
        box.object?[key.stringValue] = child
    }

    mutating func encode(_ value: some Encodable, forKey key: Key) throws {
        let child = ProtobufValueBox()
        try value.encode(to: ProtobufValueEncoder(box: child, codingPath: codingPath + [key]))
        box.object?[key.stringValue] = child
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = ProtobufValueBox()
        box.object?[key.stringValue] = child
        return ProtobufValueEncoder(box: child, codingPath: codingPath + [key]).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = ProtobufValueBox()
        box.object?[key.stringValue] = child
        return ProtobufValueEncoder(box: child, codingPath: codingPath + [key]).unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder {
        let child = ProtobufValueBox()
        box.object?["super"] = child
        return ProtobufValueEncoder(box: child, codingPath: codingPath)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        let child = ProtobufValueBox()
        box.object?[key.stringValue] = child
        return ProtobufValueEncoder(box: child, codingPath: codingPath + [key])
    }
}
