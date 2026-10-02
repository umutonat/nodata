struct BenchmarkMetadata: Codable, Equatable, Sendable {
    let source: String
    let tags: [String]
    let details: BenchmarkDetails
}
