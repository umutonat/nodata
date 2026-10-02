import Foundation

final class ProtobufValueEncoder: Encoder {
    let box: ProtobufValueBox
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    init(box: ProtobufValueBox, codingPath: [CodingKey] = []) {
        self.box = box
        self.codingPath = codingPath
    }

    static func encode(_ value: some Encodable) throws -> [String: JSONValue] {
        let box = ProtobufValueBox()
        try value.encode(to: ProtobufValueEncoder(box: box))
        guard case let .object(fields) = try box.materialize() else { throw NoDataError.invalidDocument }
        return fields
    }

    func container<Key: CodingKey>(keyedBy _: Key.Type) -> KeyedEncodingContainer<Key> {
        box.object = [:]
        return KeyedEncodingContainer(ProtobufKeyedEncodingContainer(box: box, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        box.array = []
        return ProtobufUnkeyedEncodingContainer(box: box, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        ProtobufSingleValueEncodingContainer(box: box, codingPath: codingPath)
    }
}
