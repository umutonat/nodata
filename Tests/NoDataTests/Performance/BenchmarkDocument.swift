struct BenchmarkDocument: Codable, Equatable, Sendable {
    let number: Int
    var title: String
    var category: String
    let payload: String
    let metadata: BenchmarkMetadata
}
