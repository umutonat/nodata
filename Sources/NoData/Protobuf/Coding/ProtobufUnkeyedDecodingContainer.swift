import Foundation

struct ProtobufUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let items: [JSONValue]
    let codingPath: [CodingKey]
    var currentIndex = 0
    var count: Int? {
        items.count
    }

    var isAtEnd: Bool {
        currentIndex >= items.count
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { throw endError() }
        if items[currentIndex] == .null {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode<Value: Decodable>(_: Value.Type) throws -> Value {
        let item = try next()
        if let direct = item as? Value {
            return direct
        }
        return try Value(from: ProtobufValueDecoder(value: item, codingPath: codingPath))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        try ProtobufValueDecoder(value: next(), codingPath: codingPath).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        try ProtobufValueDecoder(value: next(), codingPath: codingPath).unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        try ProtobufValueDecoder(value: next(), codingPath: codingPath)
    }

    private mutating func next() throws -> JSONValue {
        guard !isAtEnd else { throw endError() }
        defer { currentIndex += 1 }
        return items[currentIndex]
    }

    private func endError() -> DecodingError {
        .valueNotFound(JSONValue.self, .init(codingPath: codingPath, debugDescription: "End of array"))
    }
}
