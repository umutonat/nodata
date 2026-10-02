public struct NoDataChange<Value: Sendable>: Sendable {
    public let id: String
    public let revision: UInt64
    public let value: Value?
}
