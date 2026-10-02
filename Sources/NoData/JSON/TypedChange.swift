struct TypedChange<Value: Decodable>: Decodable {
    let revision: UInt64
    let collection: String
    let id: String
    let fields: Value?
}
