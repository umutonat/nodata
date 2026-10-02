struct RecordLocation: Sendable {
    let offset: UInt64
    let length: Int
    let position: Int
    let revision: UInt64
}
