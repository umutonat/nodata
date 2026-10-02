enum NoDataBackend<Value: Codable & Sendable> {
    case json(DocumentStore<Value>)
    case protobuf(ProtobufDocumentStore<Value>)
}
