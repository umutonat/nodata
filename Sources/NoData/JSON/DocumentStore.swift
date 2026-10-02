import Foundation

actor DocumentStore<Value: Codable & Sendable> {
    private let url: URL
    private var handle: FileHandle
    private let fileLock: ExclusiveFileLock
    private let collection: String
    private let maximumLiveDocuments: Int?
    private let failure: (@Sendable (JournalFaultPoint) throws -> Void)?
    private var locations: [String: RecordLocation] = [:]
    private var revision: UInt64 = 0
    private var historyFloor: UInt64 = 0
    private var cachedBatch: (offset: UInt64, changes: [Change])?
    private let observers = ChangeObservers<NoDataChange<Value>>()

    static var defaultURL: URL {
        StorePaths.defaultURL(for: Value.self, fileName: "store.ndjson")
    }

    init() throws {
        try self.init(at: Self.defaultURL)
    }

    init(
        at url: URL, maximumLiveDocuments: Int? = nil,
        failure: (@Sendable (JournalFaultPoint) throws -> Void)? = nil
    ) throws {
        self.url = url
        self.maximumLiveDocuments = maximumLiveDocuments
        self.failure = failure
        let collectionName = String(reflecting: Value.self)
        collection = collectionName
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (handle, lock) = try ExclusiveFileLock.open(at: url)
        self.handle = handle
        fileLock = lock
        var loadedLocations: [String: RecordLocation] = [:]
        var loadedRevision: UInt64 = 0
        var loadedFloor: UInt64 = 0
        var snapshotPhase = false
        let validLength = try Self.scan(handle) { line, offset in
            let payload = try JournalChecksum.jsonPayload(line)
            if offset == 0, let checkpoint = try? JSONDecoder().decode(JSONCheckpoint.self, from: payload) {
                guard checkpoint.kind == "checkpoint" else { throw NoDataError.corruptLog }
                if let storedCollection = checkpoint.collection, storedCollection != collectionName {
                    throw NoDataError.incompatibleType
                }
                loadedRevision = checkpoint.revision
                loadedFloor = checkpoint.revision
                snapshotPhase = true
                return true
            }
            let changes: [ChangeHeader]
            do {
                changes = try Self.decodeHeaders(payload)
            } catch {
                throw NoDataError.corruptLog
            }
            guard !changes.isEmpty else { throw NoDataError.corruptLog }
            for (position, change) in changes.enumerated() {
                guard change.collection == collectionName else { throw NoDataError.incompatibleType }
                if snapshotPhase, change.revision <= loadedFloor {
                    guard !change.id.isEmpty, !change.isDelete, loadedLocations[change.id] == nil else {
                        throw NoDataError.corruptLog
                    }
                    if let maximumLiveDocuments, loadedLocations.count >= maximumLiveDocuments {
                        throw NoDataError.capacityExceeded
                    }
                    loadedLocations[change.id] = RecordLocation(
                        offset: offset, length: line.count, position: position, revision: change.revision
                    )
                    continue
                }
                snapshotPhase = false
                guard !change.id.isEmpty, loadedRevision < UInt64.max, change.revision == loadedRevision + 1 else {
                    throw NoDataError.corruptLog
                }
                loadedRevision = change.revision
                if !change.isDelete {
                    if let maximumLiveDocuments, loadedLocations[change.id] == nil,
                       loadedLocations.count >= maximumLiveDocuments
                    {
                        throw NoDataError.capacityExceeded
                    }
                    loadedLocations[change.id] = RecordLocation(
                        offset: offset, length: line.count, position: position, revision: change.revision
                    )
                } else {
                    loadedLocations[change.id] = nil
                }
            }
            return true
        }
        if try validLength != (handle.seekToEnd()) {
            try handle.truncate(atOffset: UInt64(validLength))
        }
        locations = loadedLocations
        revision = loadedRevision
        historyFloor = loadedFloor
        _ = try handle.seekToEnd()
    }

    @discardableResult
    func put(_ value: Value, id: String) throws -> Document {
        try putFields(encodeFields(value), id: id)
    }

    @discardableResult
    func insert(_ entries: [(id: String, value: Value)]) throws -> [WriteReceipt] {
        guard !entries.isEmpty else { return [] }
        let ids = entries.map(\.id)
        try validateIDs(ids)
        guard ids.allSatisfy({ locations[$0] == nil }) else { throw NoDataError.documentAlreadyExists }
        if let maximumLiveDocuments, entries.count > maximumLiveDocuments - locations.count {
            throw NoDataError.capacityExceeded
        }
        guard UInt64(entries.count) <= UInt64.max - revision else { throw NoDataError.revisionExhausted }
        let stored = entries.enumerated().map { index, entry in
            StoredChange(revision: revision + UInt64(index) + 1, collection: collection, id: entry.id, fields: entry.value)
        }
        let encoded = try JSONEncoder().encode(stored)
        let headers = try JSONDecoder().decode([ChangeHeader].self, from: encoded)
        guard headers.count == entries.count, headers.allSatisfy({ !$0.isDelete }) else {
            throw NoDataError.invalidDocument
        }
        var observedChanges: [NoDataChange<Value>] = []
        if observers.hasSubscribers {
            observedChanges = try JSONDecoder().decode([Change].self, from: encoded).map { change in
                try NoDataChange(id: change.id, revision: change.revision, value: change.fields.map { try decode($0) })
            }
        }
        let (offset, length) = try persist(encoded)
        for (position, header) in headers.enumerated() {
            locations[header.id] = RecordLocation(
                offset: offset, length: length, position: position, revision: header.revision
            )
        }
        revision = headers[headers.count - 1].revision
        observers.publish(observedChanges)
        return headers.map { WriteReceipt(id: $0.id, revision: $0.revision) }
    }

    private func putFields(_ fields: [String: JSONValue], id: String) throws -> Document {
        let change = try append(fields: fields, id: id)
        return Document(collection: collection, id: id, revision: change.revision, fields: fields)
    }

    func get(id: String) throws -> Value? {
        guard let document = try document(id: id) else { return nil }
        return try decode(document.fields)
    }

    func document(id: String) throws -> Document? {
        guard let location = locations[id] else { return nil }
        let changes = try readChanges(at: location)
        guard changes.indices.contains(location.position) else { throw NoDataError.corruptLog }
        let change = changes[location.position]
        guard change.id == id, change.revision == location.revision, let fields = change.fields else {
            throw NoDataError.corruptLog
        }
        return Document(collection: collection, id: id, revision: location.revision, fields: fields)
    }

    var count: Int {
        locations.count
    }

    var currentRevision: UInt64 {
        revision
    }

    var oldestAvailableRevision: UInt64 {
        historyFloor
    }

    func backup(to destination: URL) throws {
        try handle.synchronize()
        try JournalBackup.create(from: url, to: destination) { temporary in
            _ = try DocumentStore<Value>(at: temporary, maximumLiveDocuments: maximumLiveDocuments)
        }
    }

    func all() async throws -> [Value] {
        try await query { _ in true }.map(\.value)
    }

    func allDocuments() throws -> [Document] {
        var documents: [Document] = []
        try visitDocuments { documents.append($0) }
        return documents.sorted { $0.id < $1.id }
    }

    func query(where predicate: @escaping @Sendable (Value) -> Bool) async throws -> [(id: String, value: Value)] {
        let ordered = orderedLocations()
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let collectionName = collection
        #if os(watchOS)
            let workerCount = 1
        #else
            let workerCount = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        #endif
        return try await withThrowingTaskGroup(of: [(id: String, value: Value)].self) { group in
            var matches: [(id: String, value: Value)] = []
            var outstanding = 0
            var index = 0
            while index < ordered.count {
                let location = ordered[index].location
                var entries: [(id: String, location: RecordLocation)] = []
                repeat {
                    entries.append(ordered[index])
                    index += 1
                } while index < ordered.count && ordered[index].location.offset == location.offset
                let data = try Self.readRecord(at: location, from: reader)
                group.addTask {
                    try Self.matchBatch(data, entries: entries, collection: collectionName, predicate: predicate)
                }
                outstanding += 1
                if outstanding >= workerCount, let partial = try await group.next() {
                    matches.append(contentsOf: partial)
                    outstanding -= 1
                }
            }
            for try await partial in group {
                matches.append(contentsOf: partial)
            }
            return matches.sorted { $0.id < $1.id }
        }
    }

    @discardableResult
    func forEach(
        where predicate: @Sendable (Value) -> Bool,
        visit: @Sendable (String, Value) throws -> Void
    ) throws -> Int {
        var count = 0
        try visitValues { id, value in
            if predicate(value) {
                try visit(id, value)
                count += 1
            }
        }
        return count
    }

    @discardableResult
    func update(id: String, fields: [String: JSONValue]) throws -> Value {
        guard let document = try document(id: id) else { throw NoDataError.documentNotFound }
        guard !fields.isEmpty else { return try decode(document.fields) }
        let merged = document.fields.merging(fields) { _, replacement in replacement }
        guard merged != document.fields else { return try decode(document.fields) }
        let value = try decode(merged)
        _ = try putFields(merged, id: id)
        return value
    }

    @discardableResult
    func update(id: String, mutate: @Sendable (inout Value) -> Void) throws -> Value {
        guard let document = try document(id: id) else { throw NoDataError.documentNotFound }
        var value = try decode(document.fields)
        mutate(&value)
        let data = try JSONEncoder().encode(value)
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: data)
        guard fields != document.fields else { return value }
        let validated = try decode(fields)
        _ = try putFields(fields, id: id)
        return validated
    }

    @discardableResult
    func update(ids: [String], mutate: @Sendable (inout Value) -> Void) throws -> [Value] {
        try validateIDs(ids)
        let prepared = try ids.map { id -> (id: String, value: Value, fields: [String: JSONValue], original: [String: JSONValue]) in
            guard let document = try document(id: id) else { throw NoDataError.documentNotFound }
            var value = try decode(document.fields)
            mutate(&value)
            let fields = try encodeFields(value)
            return try (id: id, value: decode(fields), fields: fields, original: document.fields)
        }
        let changed = prepared.filter { $0.fields != $0.original }
        _ = try appendBatch(changed.map { (id: $0.id, fields: $0.fields) })
        return prepared.map(\.value)
    }

    @discardableResult
    func update(ids: [String], fields: [String: JSONValue]) throws -> [Value] {
        try update(ids.map { (id: $0, fields: fields) })
    }

    @discardableResult
    func update(_ entries: [(id: String, fields: [String: JSONValue])]) throws -> [Value] {
        guard !entries.isEmpty else { return [] }
        try validateIDs(entries.map(\.id))
        let prepared = try entries.map { entry -> (id: String, value: Value, fields: [String: JSONValue]) in
            guard let document = try document(id: entry.id) else { throw NoDataError.documentNotFound }
            let fields = document.fields.merging(entry.fields) { _, replacement in replacement }
            return try (id: entry.id, value: decode(fields), fields: fields)
        }
        let changed = try prepared.filter { entry in
            try document(id: entry.id)?.fields != entry.fields
        }
        _ = try appendBatch(changed.map { (id: $0.id, fields: $0.fields) })
        return prepared.map(\.value)
    }

    @discardableResult
    func delete(id: String) throws -> Bool {
        guard locations[id] != nil else { return false }
        _ = try append(fields: nil, id: id)
        return true
    }

    @discardableResult
    func delete(ids: [String]) throws -> Int {
        try validateIDs(ids)
        let existing = ids.filter { locations[$0] != nil }
        _ = try appendBatch(existing.map { (id: $0, fields: nil) })
        return existing.count
    }

    @discardableResult
    func deleteAll() throws -> Int {
        try delete(ids: locations.keys.sorted())
    }

    func compact(through acknowledgedRevision: UInt64) throws {
        guard acknowledgedRevision == revision else { throw NoDataError.unacknowledgedChanges }
        guard !observers.hasSubscribers else { throw NoDataError.compactionBlocked }
        guard revision > historyFloor else {
            do { try JournalReplacement.syncDirectory(at: url) }
            catch { throw NoDataError.durabilityUncertain }
            return
        }

        let pending = try JournalReplacement.prepare(for: url)
        var compactedLocations: [String: RecordLocation] = [:]
        var offset: UInt64 = 0
        var directorySynced = true
        do {
            let marker = try JournalChecksum.jsonRecord(JSONEncoder().encode(JSONCheckpoint(
                revision: revision, collection: collection
            )))
            try pending.handle.write(contentsOf: marker)
            offset += UInt64(marker.count)

            let ids = locations.keys.sorted()
            for start in stride(from: 0, to: ids.count, by: 1000) {
                var snapshot: [Change] = []
                for id in ids[start ..< min(start + 1000, ids.count)] {
                    guard let document = try document(id: id) else { throw NoDataError.corruptLog }
                    snapshot.append(Change(
                        revision: document.revision, collection: collection, id: id, fields: document.fields
                    ))
                }
                let record = try JournalChecksum.jsonRecord(JSONEncoder().encode(snapshot))
                try pending.handle.write(contentsOf: record)
                for (position, change) in snapshot.enumerated() {
                    compactedLocations[change.id] = RecordLocation(
                        offset: offset, length: record.count - 1, position: position, revision: change.revision
                    )
                }
                offset += UInt64(record.count)
            }

            let replacement = try JournalReplacement.commit(pending, replacing: url, failure: failure)
            try? handle.close()
            handle = replacement.handle
            locations = compactedLocations
            cachedBatch = nil
            historyFloor = revision
            directorySynced = replacement.directorySynced
        } catch {
            JournalReplacement.discard(pending)
            throw error
        }
        if !directorySynced {
            throw NoDataError.durabilityUncertain
        }
    }

    func changes(after revision: UInt64, limit: Int? = nil) throws -> [Change] {
        var result: [Change] = []
        _ = try scanChanges(after: revision, limit: limit) { result.append($0) }
        return result
    }

    func observe() -> AsyncThrowingStream<NoDataChange<Value>, Error> {
        observers.stream()
    }

    func observe(after revision: UInt64) throws -> AsyncThrowingStream<NoDataChange<Value>, Error> {
        var history: [NoDataChange<Value>] = []
        _ = try scanChanges(after: revision) { change in
            guard history.count < ChangeObservers<NoDataChange<Value>>.capacity else {
                throw NoDataError.observerOverflow
            }
            try history.append(NoDataChange(
                id: change.id, revision: change.revision,
                value: change.fields.map { try decode($0) }
            ))
        }
        return observers.stream(replaying: history)
    }

    @discardableResult
    func forEachChange(after revision: UInt64, visit: @Sendable (Change) throws -> Void) throws -> Int {
        try scanChanges(after: revision, visit: visit)
    }

    private func scanChanges(after revision: UInt64, limit: Int? = nil, visit: (Change) throws -> Void) throws -> Int {
        guard revision >= historyFloor else { throw NoDataError.historyPruned }
        if let limit, limit < 1 {
            throw NoDataError.invalidPageSize
        }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var count = 0
        _ = try Self.scan(reader) { line, _ in
            let payload = try JournalChecksum.jsonPayload(line)
            if let checkpoint = try? JSONDecoder().decode(JSONCheckpoint.self, from: payload) {
                guard checkpoint.kind == "checkpoint" else { throw NoDataError.corruptLog }
                if let storedCollection = checkpoint.collection, storedCollection != collection {
                    throw NoDataError.incompatibleType
                }
                return true
            }
            for change in try Self.decodeChanges(payload) where change.revision > revision {
                try visit(change)
                count += 1
                if let limit, count >= limit {
                    return false
                }
            }
            return true
        }
        return count
    }

    private static func scan(_ handle: FileHandle, visit: (Data, UInt64) throws -> Bool) throws -> UInt64 {
        _ = try handle.seek(toOffset: 0)
        var pending = Data()
        var offset: UInt64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            let previousCount = pending.count
            pending.append(chunk)
            var searchFrom = pending.startIndex + previousCount
            while let newline = pending[searchFrom...].firstIndex(of: 0x0A) {
                let continueScanning = try visit(Data(pending[..<newline]), offset)
                let consumed = newline - pending.startIndex + 1
                pending.removeFirst(consumed)
                offset += UInt64(consumed)
                if !continueScanning {
                    return offset
                }
                searchFrom = pending.startIndex
            }
        }
        return offset
    }

    private static func decodeChanges(_ data: Data) throws -> [Change] {
        let decoder = JSONDecoder()
        if let change = try? decoder.decode(Change.self, from: data) {
            return [change]
        }
        return try decoder.decode([Change].self, from: data)
    }

    private static func decodeHeaders(_ data: Data) throws -> [ChangeHeader] {
        let decoder = JSONDecoder()
        if let change = try? decoder.decode(ChangeHeader.self, from: data) {
            return [change]
        }
        return try decoder.decode([ChangeHeader].self, from: data)
    }

    private func encodeFields(_ value: Value) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(value))
    }

    private func decode(_ fields: [String: JSONValue]) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(fields))
    }

    private func readChanges(at location: RecordLocation) throws -> [Change] {
        if let cachedBatch, cachedBatch.offset == location.offset {
            return cachedBatch.changes
        }
        let changes = try Self.decodeChanges(readRecord(at: location))
        cachedBatch = (offset: location.offset, changes: changes)
        return changes
    }

    private func readRecord(at location: RecordLocation) throws -> Data {
        try Self.readRecord(at: location, from: handle)
    }

    private static func readRecord(at location: RecordLocation, from reader: FileHandle) throws -> Data {
        _ = try reader.seek(toOffset: location.offset)
        var data = Data()
        while data.count < location.length {
            guard let chunk = try reader.read(upToCount: location.length - data.count), !chunk.isEmpty else {
                throw NoDataError.corruptLog
            }
            data.append(chunk)
        }
        return try JournalChecksum.jsonPayload(data)
    }

    private func orderedLocations() -> [(id: String, location: RecordLocation)] {
        let entries: [(id: String, location: RecordLocation)] = locations.map { (id: $0.key, location: $0.value) }
        return entries.sorted { first, second in
            if first.location.offset != second.location.offset {
                return first.location.offset < second.location.offset
            }
            return first.location.position < second.location.position
        }
    }

    private func visitValues(_ visit: (String, Value) throws -> Void) throws {
        var cachedOffset: UInt64?
        var typed: [TypedChange<Value>]?
        var fallback: [Change] = []
        for entry in orderedLocations() {
            if cachedOffset != entry.location.offset {
                let data = try readRecord(at: entry.location)
                typed = try? Self.decodeTypedChanges(data)
                fallback = typed == nil ? try Self.decodeChanges(data) : []
                cachedOffset = entry.location.offset
            }
            if let typed {
                guard typed.indices.contains(entry.location.position) else { throw NoDataError.corruptLog }
                let change = typed[entry.location.position]
                guard change.id == entry.id, change.revision == entry.location.revision,
                      let value = change.fields else { throw NoDataError.corruptLog }
                try visit(entry.id, value)
            } else {
                guard fallback.indices.contains(entry.location.position) else { throw NoDataError.corruptLog }
                let change = fallback[entry.location.position]
                guard change.id == entry.id, change.revision == entry.location.revision,
                      let fields = change.fields else { throw NoDataError.corruptLog }
                try visit(entry.id, decode(fields))
            }
        }
    }

    private static func decodeTypedChanges(_ data: Data) throws -> [TypedChange<Value>] {
        let decoder = JSONDecoder()
        if let change = try? decoder.decode(TypedChange<Value>.self, from: data) {
            return [change]
        }
        return try decoder.decode([TypedChange<Value>].self, from: data)
    }

    private static func matchBatch(
        _ data: Data, entries: [(id: String, location: RecordLocation)], collection: String,
        predicate: @Sendable (Value) -> Bool
    ) throws -> [(id: String, value: Value)] {
        var matches: [(id: String, value: Value)] = []
        if let typed = try? decodeTypedChanges(data) {
            for entry in entries {
                guard typed.indices.contains(entry.location.position) else { throw NoDataError.corruptLog }
                let change = typed[entry.location.position]
                guard change.id == entry.id, change.revision == entry.location.revision,
                      change.collection == collection, let value = change.fields else { throw NoDataError.corruptLog }
                if predicate(value) {
                    matches.append((id: entry.id, value: value))
                }
            }
        } else {
            let changes = try decodeChanges(data)
            for entry in entries {
                guard changes.indices.contains(entry.location.position) else { throw NoDataError.corruptLog }
                let change = changes[entry.location.position]
                guard change.id == entry.id, change.revision == entry.location.revision,
                      change.collection == collection, let fields = change.fields else { throw NoDataError.corruptLog }
                let value = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(fields))
                if predicate(value) {
                    matches.append((id: entry.id, value: value))
                }
            }
        }
        return matches
    }

    private func visitDocuments(_ visit: (Document) throws -> Void) throws {
        var cachedOffset: UInt64?
        var changes: [Change] = []
        for entry in orderedLocations() {
            if cachedOffset != entry.location.offset {
                changes = try readChanges(at: entry.location)
                cachedOffset = entry.location.offset
            }
            guard changes.indices.contains(entry.location.position) else { throw NoDataError.corruptLog }
            let change = changes[entry.location.position]
            guard change.id == entry.id, change.revision == entry.location.revision, let fields = change.fields else {
                throw NoDataError.corruptLog
            }
            try visit(Document(collection: collection, id: entry.id, revision: change.revision, fields: fields))
        }
    }

    private func validateIDs(_ ids: [String]) throws {
        guard ids.allSatisfy({ !$0.isEmpty }) else { throw NoDataError.invalidIdentifier }
        guard Set(ids).count == ids.count else { throw NoDataError.duplicateIdentifier }
    }

    private func append(fields: [String: JSONValue]?, id: String) throws -> Change {
        guard !id.isEmpty else { throw NoDataError.invalidIdentifier }
        if let maximumLiveDocuments, fields != nil, locations[id] == nil,
           locations.count >= maximumLiveDocuments
        {
            throw NoDataError.capacityExceeded
        }
        guard revision < UInt64.max else { throw NoDataError.revisionExhausted }
        let change = Change(revision: revision + 1, collection: collection, id: id, fields: fields)
        let observedValue: Value? = if observers.hasSubscribers, let fields {
            try decode(fields)
        } else {
            nil
        }
        let (offset, length) = try persist(change)
        if fields != nil {
            locations[id] = RecordLocation(offset: offset, length: length, position: 0, revision: change.revision)
        } else {
            locations[id] = nil
        }
        revision = change.revision
        if observers.hasSubscribers {
            observers.publish([NoDataChange(id: id, revision: change.revision, value: observedValue)])
        }
        return change
    }

    private func appendBatch(_ entries: [(id: String, fields: [String: JSONValue]?)]) throws -> [Change] {
        guard !entries.isEmpty else { return [] }
        guard entries.allSatisfy({ !$0.id.isEmpty }) else { throw NoDataError.invalidIdentifier }
        guard UInt64(entries.count) <= UInt64.max - revision else { throw NoDataError.revisionExhausted }
        let changes = entries.enumerated().map { index, entry in
            Change(revision: revision + UInt64(index) + 1, collection: collection, id: entry.id, fields: entry.fields)
        }
        let observedChanges: [NoDataChange<Value>] = if observers.hasSubscribers {
            try changes.map { change in
                try NoDataChange(id: change.id, revision: change.revision, value: change.fields.map { try decode($0) })
            }
        } else {
            []
        }
        let (offset, length) = try persist(changes)
        index(changes, at: offset, length: length)
        observers.publish(observedChanges)
        return changes
    }

    private func index(_ changes: [Change], at offset: UInt64, length: Int) {
        for (position, change) in changes.enumerated() {
            if change.fields != nil {
                locations[change.id] = RecordLocation(
                    offset: offset, length: length, position: position, revision: change.revision
                )
            } else {
                locations[change.id] = nil
            }
        }
        revision = changes[changes.count - 1].revision
    }

    private func persist(_ record: some Encodable) throws -> (UInt64, Int) {
        try persist(JSONEncoder().encode(record))
    }

    private func persist(_ encoded: Data) throws -> (UInt64, Int) {
        let data = JournalChecksum.jsonRecord(encoded)
        let length = data.count - 1
        let offset = try handle.seekToEnd()
        do {
            try failure?(.beforeWrite)
            try handle.write(contentsOf: data)
            try failure?(.beforeFileSync)
            try handle.synchronize()
        } catch {
            try? handle.truncate(atOffset: offset)
            throw error
        }
        return (offset, length)
    }
}
