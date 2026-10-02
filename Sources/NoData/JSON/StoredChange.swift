struct StoredChange<Value: Encodable>: Encodable {
    let revision: UInt64
    let collection: String
    let id: String
    let fields: Value
}
