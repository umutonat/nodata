import Foundation

struct ProtobufChange: Sendable, Equatable {
    let revision: UInt64
    let id: String
    let payload: Data?

    func decode<Value: Decodable>(as type: Value.Type) throws -> Value? {
        guard let payload else { return nil }
        return try ProtobufValueCodec.decode(type, from: payload)
    }
}
