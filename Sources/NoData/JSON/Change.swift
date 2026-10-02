struct Change: Codable, Equatable, Sendable {
    let revision: UInt64
    let collection: String
    let id: String
    let fields: [String: JSONValue]?
}
