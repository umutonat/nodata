struct Note: Codable, Equatable, Sendable {
    var title: String
    let tags: [String]
    let counters: [String: Int64]
    let unsignedCounters: [String: UInt64]
}
