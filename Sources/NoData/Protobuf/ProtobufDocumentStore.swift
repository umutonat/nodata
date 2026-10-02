import Foundation
import SwiftProtobuf

actor ProtobufDocumentStore<Value: Codable & Sendable> {
    private static var maximumFrameSize: Int {
        16 * 1024 * 1024
    }

    private let url: URL
    private var handle: FileHandle
    private let fileLock: ExclusiveFileLock
    private let collection: String
    private let maximumLiveDocuments: Int?
    private let failure: (@Sendable (JournalFaultPoint) throws -> Void)?
    private var locations: [String: RecordLocation] = [:]
    private var revision: UInt64 = 0
    private var historyFloor: UInt64 = 0
    private var cachedBatch: (offset: UInt64, batch: Nodata_Storage_Batch)?
    private let observers = ChangeObservers<NoDataChange<Value>>()

    static var defaultURL: URL {
        StorePaths.defaultURL(for: Value.self, fileName: "store.pbdb")
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
        let header = Self.header(for: collectionName)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (handle, lock) = try ExclusiveFileLock.open(at: url)
        self.handle = handle
        fileLock = lock
        if try handle.seekToEnd() == 0 {
            try handle.write(contentsOf: header)
            try handle.synchronize()
        }
        _ = try handle.seek(toOffset: 0)
        let storedHeader = try Self.read(handle, count: header.count)
        guard storedHeader.count == header.count else { throw NoDataError.corruptLog }
        guard storedHeader == header else { throw NoDataError.incompatibleType }

        var loadedLocations: [String: RecordLocation] = [:]
        var loadedRevision: UInt64 = 0
        var loadedFloor: UInt64 = 0
        var snapshotPhase = false
        let end = try handle.seekToEnd()
        var offset = UInt64(header.count)
        while offset < end {
            _ = try handle.seek(toOffset: offset)
            let prefix = try Self.read(handle, count: 8)
            guard prefix.count == 8 else { break }
            let size = Int(Data(prefix.prefix(4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            guard size > 0, size <= Self.maximumFrameSize else { throw NoDataError.corruptLog }
            let data = try Self.read(handle, count: size)
            guard data.count == size else { break }
            let checksum = Data(prefix.suffix(4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            guard JournalChecksum.value(of: data) == checksum else { throw NoDataError.corruptLog }
            let batch: Nodata_Storage_Batch
            do {
                batch = try Nodata_Storage_Batch(serializedBytes: data)
            } catch {
                throw NoDataError.corruptLog
            }
            if batch.checkpointRevision != 0 {
                guard offset == UInt64(header.count), batch.records.isEmpty, !batch.snapshot else {
                    throw NoDataError.corruptLog
                }
                loadedRevision = batch.checkpointRevision
                loadedFloor = batch.checkpointRevision
                snapshotPhase = true
            } else if batch.snapshot {
                guard snapshotPhase, !batch.records.isEmpty else { throw NoDataError.corruptLog }
                for (position, record) in batch.records.enumerated() {
                    guard !record.id.isEmpty, !record.deleted, record.revision > 0,
                          record.revision <= loadedFloor, loadedLocations[record.id] == nil
                    else {
                        throw NoDataError.corruptLog
                    }
                    if let maximumLiveDocuments, loadedLocations.count >= maximumLiveDocuments {
                        throw NoDataError.capacityExceeded
                    }
                    loadedLocations[record.id] = RecordLocation(
                        offset: offset + 8, length: size, position: position, revision: record.revision
                    )
                }
            } else {
                snapshotPhase = false
                guard !batch.records.isEmpty else { throw NoDataError.corruptLog }
                for (position, record) in batch.records.enumerated() {
                    guard !record.id.isEmpty, loadedRevision < UInt64.max,
                          record.revision == loadedRevision + 1 else { throw NoDataError.corruptLog }
                    loadedRevision = record.revision
                    if record.deleted {
                        loadedLocations[record.id] = nil
                    } else {
                        if let maximumLiveDocuments, loadedLocations[record.id] == nil,
                           loadedLocations.count >= maximumLiveDocuments
                        {
                            throw NoDataError.capacityExceeded
                        }
                        loadedLocations[record.id] = RecordLocation(
                            offset: offset + 8, length: size, position: position, revision: record.revision
                        )
                    }
                }
            }
            offset += UInt64(8 + size)
        }
        if offset != end {
            try handle.truncate(atOffset: offset)
        }
        locations = loadedLocations
        revision = loadedRevision
        historyFloor = loadedFloor
        _ = try handle.seekToEnd()
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
            _ = try ProtobufDocumentStore<Value>(at: temporary, maximumLiveDocuments: maximumLiveDocuments)
        }
    }

    @discardableResult
    func put(_ value: Value, id: String) throws -> WriteReceipt {
        let receipts = try append([(id: id, payload: encode(value), deleted: false)])
        return receipts[0]
    }

    @discardableResult
    func insert(_ entries: [(id: String, value: Value)]) throws -> [WriteReceipt] {
        guard !entries.isEmpty else { return [] }
        let ids = entries.map(\.id)
        try validateIDs(ids)
        guard ids.allSatisfy({ locations[$0] == nil }) else { throw NoDataError.documentAlreadyExists }
        let prepared = try entries.map { try (id: $0.id, payload: encode($0.value), deleted: false) }
        return try append(prepared)
    }

    func get(id: String) throws -> Value? {
        guard let location = locations[id] else { return nil }
        let batch = try readBatch(at: location)
        guard batch.records.indices.contains(location.position) else { throw NoDataError.corruptLog }
        let record = batch.records[location.position]
        guard record.id == id, record.revision == location.revision, !record.deleted else {
            throw NoDataError.corruptLog
        }
        return try decode(record.payload)
    }

    func all() async throws -> [Value] {
        try await query { _ in true }.map(\.value)
    }

    func query(where predicate: @escaping @Sendable (Value) -> Bool) async throws -> [(id: String, value: Value)] {
        let entries: [(id: String, location: RecordLocation)] = locations.map { (id: $0.key, location: $0.value) }
        let ordered = entries.sorted { first, second in
            if first.location.offset != second.location.offset {
                return first.location.offset < second.location.offset
            }
            return first.location.position < second.location.position
        }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
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
                var batchEntries: [(id: String, location: RecordLocation)] = []
                repeat {
                    batchEntries.append(ordered[index])
                    index += 1
                } while index < ordered.count && ordered[index].location.offset == location.offset
                let data = try Self.readBatchData(at: location, from: reader)
                group.addTask {
                    let batch = try Nodata_Storage_Batch(serializedBytes: data)
                    var partial: [(id: String, value: Value)] = []
                    for entry in batchEntries {
                        guard batch.records.indices.contains(entry.location.position) else { throw NoDataError.corruptLog }
                        let record = batch.records[entry.location.position]
                        guard record.id == entry.id, record.revision == entry.location.revision, !record.deleted else {
                            throw NoDataError.corruptLog
                        }
                        let value = try ProtobufValueCodec.decode(Value.self, from: record.payload)
                        if predicate(value) {
                            partial.append((id: entry.id, value: value))
                        }
                    }
                    return partial
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
    func update(id: String, mutate: @Sendable (inout Value) -> Void) throws -> Value {
        guard var value = try get(id: id) else { throw NoDataError.documentNotFound }
        mutate(&value)
        _ = try put(value, id: id)
        return value
    }

    @discardableResult
    func update(ids: [String], mutate: @Sendable (inout Value) -> Void) throws -> [Value] {
        try validateIDs(ids)
        let prepared = try ids.map { id -> (id: String, value: Value, payload: Data) in
            guard var value = try get(id: id) else { throw NoDataError.documentNotFound }
            mutate(&value)
            return try (id: id, value: value, payload: encode(value))
        }
        _ = try append(prepared.map { (id: $0.id, payload: $0.payload, deleted: false) })
        return prepared.map(\.value)
    }

    @discardableResult
    func update(_ entries: [(id: String, value: Value)]) throws -> [WriteReceipt] {
        try validateIDs(entries.map(\.id))
        guard entries.allSatisfy({ locations[$0.id] != nil }) else { throw NoDataError.documentNotFound }
        let prepared = try entries.map { try (id: $0.id, payload: encode($0.value), deleted: false) }
        return try append(prepared)
    }

    @discardableResult
    func delete(id: String) throws -> Bool {
        guard locations[id] != nil else { return false }
        _ = try append([(id: id, payload: Data(), deleted: true)])
        return true
    }

    @discardableResult
    func delete(ids: [String]) throws -> Int {
        try validateIDs(ids)
        let existing = ids.filter { locations[$0] != nil }
        _ = try append(existing.map { (id: $0, payload: Data(), deleted: true) })
        return existing.count
    }

    @discardableResult
    func deleteAll() throws -> Int {
        try deleteAll(batchSize: 10000)
    }

    func deleteAll(batchSize: Int) throws -> Int {
        guard batchSize > 0 else { throw NoDataError.invalidDocument }
        let ids = locations.keys.sorted()
        var deleted = 0
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            deleted += try deleteBatch(ids[start ..< min(start + batchSize, ids.count)])
        }
        return deleted
    }

    private func deleteBatch(_ ids: ArraySlice<String>) throws -> Int {
        do {
            return try delete(ids: Array(ids))
        } catch NoDataError.invalidDocument where ids.count > 1 {
            let midpoint = ids.startIndex + ids.count / 2
            return try deleteBatch(ids[..<midpoint]) + deleteBatch(ids[midpoint...])
        }
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
            let header = Self.header(for: collection)
            try pending.handle.write(contentsOf: header)
            offset += UInt64(header.count)

            var marker = Nodata_Storage_Batch()
            marker.checkpointRevision = revision
            let checkpoint = try Self.frame(marker.serializedData())
            try pending.handle.write(contentsOf: checkpoint)
            offset += UInt64(checkpoint.count)

            var snapshot: [Nodata_Storage_Record] = []
            var estimatedSize = 0
            for id in locations.keys.sorted() {
                guard let location = locations[id] else { continue }
                let batch = try readBatch(at: location)
                guard batch.records.indices.contains(location.position) else { throw NoDataError.corruptLog }
                let record = batch.records[location.position]
                guard record.id == id, record.revision == location.revision, !record.deleted else {
                    throw NoDataError.corruptLog
                }
                let cost = record.payload.count + id.utf8.count + 32
                if estimatedSize + cost > Self.maximumFrameSize / 2, !snapshot.isEmpty {
                    try Self.writeSnapshot(snapshot, to: pending.handle, offset: &offset, locations: &compactedLocations)
                    snapshot.removeAll(keepingCapacity: true)
                    estimatedSize = 0
                }
                snapshot.append(record)
                estimatedSize += cost
            }
            try Self.writeSnapshot(snapshot, to: pending.handle, offset: &offset, locations: &compactedLocations)

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

    private static func writeSnapshot(
        _ records: [Nodata_Storage_Record], to output: FileHandle,
        offset: inout UInt64, locations: inout [String: RecordLocation]
    ) throws {
        guard !records.isEmpty else { return }
        var batch = Nodata_Storage_Batch()
        batch.snapshot = true
        batch.records = records
        let data = try batch.serializedData()
        if data.count > maximumFrameSize, records.count > 1 {
            let midpoint = records.count / 2
            try writeSnapshot(Array(records[..<midpoint]), to: output, offset: &offset, locations: &locations)
            try writeSnapshot(Array(records[midpoint...]), to: output, offset: &offset, locations: &locations)
            return
        }
        let framed = try frame(data)
        try output.write(contentsOf: framed)
        for (position, record) in records.enumerated() {
            locations[record.id] = RecordLocation(
                offset: offset + 8, length: data.count, position: position, revision: record.revision
            )
        }
        offset += UInt64(framed.count)
    }

    func changes(after revision: UInt64, limit: Int? = nil) throws -> [ProtobufChange] {
        var result: [ProtobufChange] = []
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
                value: change.payload.map { try decode($0) }
            ))
        }
        return observers.stream(replaying: history)
    }

    @discardableResult
    func forEachChange(after revision: UInt64, visit: @Sendable (ProtobufChange) throws -> Void) throws -> Int {
        try scanChanges(after: revision, visit: visit)
    }

    private static func header(for typeName: String) -> Data {
        let typeData = Data(typeName.utf8)
        var header = Data("NDPB1".utf8)
        var size = UInt32(typeData.count).littleEndian
        withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
        header.append(typeData)
        return header
    }

    private static func read(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    private func scanChanges(after revision: UInt64, limit: Int? = nil, visit: (ProtobufChange) throws -> Void) throws -> Int {
        guard revision >= historyFloor else { throw NoDataError.historyPruned }
        if let limit, limit < 1 {
            throw NoDataError.invalidPageSize
        }
        var count = 0
        try scanBatches { batch, _ in
            if batch.checkpointRevision != 0 || batch.snapshot {
                return true
            }
            for record in batch.records where record.revision > revision {
                try visit(ProtobufChange(
                    revision: record.revision, id: record.id,
                    payload: record.deleted ? nil : record.payload
                ))
                count += 1
                if let limit, count >= limit {
                    return false
                }
            }
            return true
        }
        return count
    }

    private func scanBatches(_ visit: (Nodata_Storage_Batch, UInt64) throws -> Bool) throws {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let headerSize = Self.header(for: collection).count
        _ = try reader.seek(toOffset: UInt64(headerSize))
        var offset = UInt64(headerSize)
        while true {
            let prefix = try Self.read(reader, count: 8)
            if prefix.isEmpty {
                break
            }
            guard prefix.count == 8 else { throw NoDataError.corruptLog }
            let size = Int(Data(prefix.prefix(4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            guard size > 0, size <= Self.maximumFrameSize else { throw NoDataError.corruptLog }
            let data = try Self.read(reader, count: size)
            guard data.count == size else { throw NoDataError.corruptLog }
            let checksum = Data(prefix.suffix(4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            guard JournalChecksum.value(of: data) == checksum else { throw NoDataError.corruptLog }
            let batch: Nodata_Storage_Batch
            do {
                batch = try Nodata_Storage_Batch(serializedBytes: data)
            } catch {
                throw NoDataError.corruptLog
            }
            if try !visit(batch, offset) {
                return
            }
            offset += UInt64(8 + size)
        }
    }

    private func readBatch(at location: RecordLocation) throws -> Nodata_Storage_Batch {
        if let cachedBatch, cachedBatch.offset == location.offset {
            return cachedBatch.batch
        }
        let data = try Self.readBatchData(at: location, from: handle)
        let batch = try Nodata_Storage_Batch(serializedBytes: data)
        cachedBatch = (offset: location.offset, batch: batch)
        return batch
    }

    private static func readBatchData(at location: RecordLocation, from reader: FileHandle) throws -> Data {
        _ = try reader.seek(toOffset: location.offset - 4)
        let framed = try Self.read(reader, count: location.length + 4)
        guard framed.count == location.length + 4 else { throw NoDataError.corruptLog }
        let checksum = Data(framed.prefix(4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        let data = Data(framed.dropFirst(4))
        guard JournalChecksum.value(of: data) == checksum else { throw NoDataError.corruptLog }
        return data
    }

    private func encode(_ value: Value) throws -> Data {
        try ProtobufValueCodec.encode(ProtobufValueEncoder.encode(value))
    }

    private func decode(_ data: Data) throws -> Value {
        try ProtobufValueCodec.decode(Value.self, from: data)
    }

    private func visitValues(_ visit: (String, Value) throws -> Void) throws {
        let entries: [(id: String, location: RecordLocation)] = locations.map { (id: $0.key, location: $0.value) }
        let ordered = entries.sorted { first, second in
            if first.location.offset != second.location.offset {
                return first.location.offset < second.location.offset
            }
            return first.location.position < second.location.position
        }
        for entry in ordered {
            let batch = try readBatch(at: entry.location)
            guard batch.records.indices.contains(entry.location.position) else { throw NoDataError.corruptLog }
            let record = batch.records[entry.location.position]
            guard record.id == entry.id, record.revision == entry.location.revision, !record.deleted else {
                throw NoDataError.corruptLog
            }
            try visit(entry.id, decode(record.payload))
        }
    }

    private func validateIDs(_ ids: [String]) throws {
        guard ids.allSatisfy({ !$0.isEmpty }) else { throw NoDataError.invalidIdentifier }
        guard Set(ids).count == ids.count else { throw NoDataError.duplicateIdentifier }
    }

    private func append(_ entries: [(id: String, payload: Data, deleted: Bool)]) throws -> [WriteReceipt] {
        guard !entries.isEmpty else { return [] }
        guard entries.allSatisfy({ !$0.id.isEmpty }) else { throw NoDataError.invalidIdentifier }
        guard UInt64(entries.count) <= UInt64.max - revision else { throw NoDataError.revisionExhausted }
        if let maximumLiveDocuments {
            let newIDs = Set(entries.filter { !$0.deleted && locations[$0.id] == nil }.map(\.id))
            if newIDs.count > maximumLiveDocuments - locations.count {
                throw NoDataError.capacityExceeded
            }
        }
        let observedChanges: [NoDataChange<Value>] = if observers.hasSubscribers {
            try entries.enumerated().map { index, entry in
                try NoDataChange(
                    id: entry.id, revision: revision + UInt64(index) + 1,
                    value: entry.deleted ? nil : decode(entry.payload)
                )
            }
        } else {
            []
        }
        var batch = Nodata_Storage_Batch()
        batch.records = entries.enumerated().map { position, entry in
            var record = Nodata_Storage_Record()
            record.id = entry.id
            record.revision = revision + UInt64(position) + 1
            record.payload = entry.payload
            record.deleted = entry.deleted
            return record
        }
        let data = try batch.serializedData()
        let frame = try Self.frame(data)
        let offset = try handle.seekToEnd()
        do {
            try failure?(.beforeWrite)
            try handle.write(contentsOf: frame)
            try failure?(.beforeFileSync)
            try handle.synchronize()
        } catch {
            try? handle.truncate(atOffset: offset)
            throw error
        }
        for (position, record) in batch.records.enumerated() {
            if record.deleted {
                locations[record.id] = nil
            } else {
                locations[record.id] = RecordLocation(
                    offset: offset + 8, length: data.count, position: position, revision: record.revision
                )
            }
        }
        revision = batch.records[batch.records.count - 1].revision
        observers.publish(observedChanges)
        return batch.records.map { WriteReceipt(id: $0.id, revision: $0.revision) }
    }

    private static func frame(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumFrameSize else { throw NoDataError.invalidDocument }
        var size = UInt32(data.count).littleEndian
        var checksum = JournalChecksum.value(of: data).littleEndian
        var frame = Data()
        withUnsafeBytes(of: &size) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &checksum) { frame.append(contentsOf: $0) }
        frame.append(data)
        return frame
    }
}
