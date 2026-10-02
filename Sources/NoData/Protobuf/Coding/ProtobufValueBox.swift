import Foundation

final class ProtobufValueBox {
    var scalar: JSONValue?
    var object: [String: ProtobufValueBox]?
    var array: [ProtobufValueBox]?

    func materialize() throws -> JSONValue {
        if let scalar {
            return scalar
        }
        if let object {
            return try .object(object.mapValues { try $0.materialize() })
        }
        if let array {
            return try .array(array.map { try $0.materialize() })
        }
        throw NoDataError.invalidDocument
    }
}
