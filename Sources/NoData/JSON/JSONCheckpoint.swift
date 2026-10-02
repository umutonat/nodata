struct JSONCheckpoint: Codable {
    let kind: String
    let revision: UInt64
    let collection: String?

    init(revision: UInt64, collection: String? = nil) {
        kind = "checkpoint"
        self.revision = revision
        self.collection = collection
    }
}
