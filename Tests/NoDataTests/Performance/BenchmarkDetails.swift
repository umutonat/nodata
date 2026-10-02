struct BenchmarkDetails: Codable, Equatable, Sendable {
    let region: String
    let score: Double
    let flags: [String: Bool]
}
