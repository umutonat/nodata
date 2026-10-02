struct Document: Equatable, Sendable {
    let collection: String
    let id: String
    let revision: UInt64
    let fields: [String: JSONValue]
}
