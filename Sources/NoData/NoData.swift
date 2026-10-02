import Foundation

public actor NoData<Value: Codable & Sendable> {
    private let backend: NoDataBackend<Value>

    public init(_ engine: NoDataEngine = .json, at url: URL? = nil, maximumLiveDocuments: Int? = nil) throws {
        if let maximumLiveDocuments, maximumLiveDocuments < 1 {
            throw NoDataError.invalidCapacity
        }
        switch engine {
        case .json:
            backend = try .json(DocumentStore(
                at: url ?? DocumentStore<Value>.defaultURL, maximumLiveDocuments: maximumLiveDocuments
            ))
        case .protobuf:
            backend = try .protobuf(ProtobufDocumentStore(
                at: url ?? ProtobufDocumentStore<Value>.defaultURL, maximumLiveDocuments: maximumLiveDocuments
            ))
        }
    }

    @discardableResult
    public func put(_ value: Value, id: String) async throws -> WriteReceipt {
        switch backend {
        case let .json(store):
            let document = try await store.put(value, id: id)
            return WriteReceipt(id: document.id, revision: document.revision)
        case let .protobuf(store):
            return try await store.put(value, id: id)
        }
    }

    @discardableResult
    public func insert(_ entries: [(id: String, value: Value)]) async throws -> [WriteReceipt] {
        switch backend {
        case let .json(store): try await store.insert(entries)
        case let .protobuf(store): try await store.insert(entries)
        }
    }

    public func get(id: String) async throws -> Value? {
        switch backend {
        case let .json(store): try await store.get(id: id)
        case let .protobuf(store): try await store.get(id: id)
        }
    }

    public var count: Int {
        get async {
            switch backend {
            case let .json(store): await store.count
            case let .protobuf(store): await store.count
            }
        }
    }

    public var currentRevision: UInt64 {
        get async {
            switch backend {
            case let .json(store): await store.currentRevision
            case let .protobuf(store): await store.currentRevision
            }
        }
    }

    public var oldestAvailableRevision: UInt64 {
        get async {
            switch backend {
            case let .json(store): await store.oldestAvailableRevision
            case let .protobuf(store): await store.oldestAvailableRevision
            }
        }
    }

    public func compact(through acknowledgedRevision: UInt64) async throws {
        switch backend {
        case let .json(store): try await store.compact(through: acknowledgedRevision)
        case let .protobuf(store): try await store.compact(through: acknowledgedRevision)
        }
    }

    public func backup(to destination: URL) async throws {
        switch backend {
        case let .json(store): try await store.backup(to: destination)
        case let .protobuf(store): try await store.backup(to: destination)
        }
    }

    public static func restore(from backup: URL, engine: NoDataEngine = .json, at destination: URL? = nil) throws {
        let path: URL = switch engine {
        case .json: destination ?? DocumentStore<Value>.defaultURL
        case .protobuf: destination ?? ProtobufDocumentStore<Value>.defaultURL
        }
        try JournalBackup.restore(from: backup, to: path) { temporary in
            switch engine {
            case .json: _ = try DocumentStore<Value>(at: temporary)
            case .protobuf: _ = try ProtobufDocumentStore<Value>(at: temporary)
            }
        }
    }

    public func all() async throws -> [Value] {
        switch backend {
        case let .json(store): try await store.all()
        case let .protobuf(store): try await store.all()
        }
    }

    public func query(where predicate: @escaping @Sendable (Value) -> Bool) async throws -> [(id: String, value: Value)] {
        switch backend {
        case let .json(store): try await store.query(where: predicate)
        case let .protobuf(store): try await store.query(where: predicate)
        }
    }

    @discardableResult
    public func forEach(
        where predicate: @Sendable (Value) -> Bool,
        visit: @Sendable (String, Value) throws -> Void
    ) async throws -> Int {
        switch backend {
        case let .json(store): try await store.forEach(where: predicate, visit: visit)
        case let .protobuf(store): try await store.forEach(where: predicate, visit: visit)
        }
    }

    @discardableResult
    public func update(id: String, mutate: @Sendable (inout Value) -> Void) async throws -> Value {
        switch backend {
        case let .json(store): try await store.update(id: id, mutate: mutate)
        case let .protobuf(store): try await store.update(id: id, mutate: mutate)
        }
    }

    @discardableResult
    public func update(ids: [String], mutate: @Sendable (inout Value) -> Void) async throws -> [Value] {
        switch backend {
        case let .json(store): try await store.update(ids: ids, mutate: mutate)
        case let .protobuf(store): try await store.update(ids: ids, mutate: mutate)
        }
    }

    @discardableResult
    public func delete(id: String) async throws -> Bool {
        switch backend {
        case let .json(store): try await store.delete(id: id)
        case let .protobuf(store): try await store.delete(id: id)
        }
    }

    @discardableResult
    public func delete(ids: [String]) async throws -> Int {
        switch backend {
        case let .json(store): try await store.delete(ids: ids)
        case let .protobuf(store): try await store.delete(ids: ids)
        }
    }

    @discardableResult
    public func deleteAll() async throws -> Int {
        switch backend {
        case let .json(store): try await store.deleteAll()
        case let .protobuf(store): try await store.deleteAll()
        }
    }

    public func changes(after revision: UInt64, limit: Int = 256) async throws -> [NoDataChange<Value>] {
        guard limit > 0 else { throw NoDataError.invalidPageSize }
        switch backend {
        case let .json(store):
            return try await store.changes(after: revision, limit: limit).map { try Self.decode($0) }
        case let .protobuf(store):
            return try await store.changes(after: revision, limit: limit).map { try Self.decode($0) }
        }
    }

    public func observe() async -> AsyncThrowingStream<NoDataChange<Value>, Error> {
        switch backend {
        case let .json(store):
            await store.observe()
        case let .protobuf(store):
            await store.observe()
        }
    }

    public func observe(after revision: UInt64) async throws -> AsyncThrowingStream<NoDataChange<Value>, Error> {
        switch backend {
        case let .json(store): try await store.observe(after: revision)
        case let .protobuf(store): try await store.observe(after: revision)
        }
    }

    @discardableResult
    public func forEachChange(
        after revision: UInt64,
        visit: @Sendable (NoDataChange<Value>) throws -> Void
    ) async throws -> Int {
        switch backend {
        case let .json(store):
            try await store.forEachChange(after: revision) { change in
                try visit(Self.decode(change))
            }
        case let .protobuf(store):
            try await store.forEachChange(after: revision) { change in
                try visit(Self.decode(change))
            }
        }
    }

    private static func decode(_ change: Change) throws -> NoDataChange<Value> {
        let value: Value? = if let fields = change.fields {
            try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(fields))
        } else {
            nil
        }
        return NoDataChange(id: change.id, revision: change.revision, value: value)
    }

    private static func decode(_ change: ProtobufChange) throws -> NoDataChange<Value> {
        try NoDataChange(id: change.id, revision: change.revision, value: change.decode(as: Value.self))
    }
}
