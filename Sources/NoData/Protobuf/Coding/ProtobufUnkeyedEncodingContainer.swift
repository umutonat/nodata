import Foundation

struct ProtobufUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let box: ProtobufValueBox
    let codingPath: [CodingKey]
    var count: Int {
        box.array?.count ?? 0
    }

    mutating func encodeNil() throws {
        let child = ProtobufValueBox()
        child.scalar = .null
        box.array?.append(child)
    }

    mutating func encode(_ value: some Encodable) throws {
        let child = ProtobufValueBox()
        try value.encode(to: ProtobufValueEncoder(box: child, codingPath: codingPath))
        box.array?.append(child)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let child = ProtobufValueBox()
        box.array?.append(child)
        return ProtobufValueEncoder(box: child, codingPath: codingPath).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let child = ProtobufValueBox()
        box.array?.append(child)
        return ProtobufValueEncoder(box: child, codingPath: codingPath).unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder {
        let child = ProtobufValueBox()
        box.array?.append(child)
        return ProtobufValueEncoder(box: child, codingPath: codingPath)
    }
}
