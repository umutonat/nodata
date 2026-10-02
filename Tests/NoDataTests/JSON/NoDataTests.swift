import Foundation
@testable import NoData
import Testing

struct NoDataTests {
    @Test func batchInsertReplaysWithSingleChanges() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            let store = try DocumentStore<[String: JSONValue]>(at: url)
            _ = try await store.put(["title": .string("First")], id: "1")
            let inserted = try await store.insert([
                (id: "2", value: ["title": .string("Second")]),
                (id: "3", value: ["title": .string("Third")]),
            ])
            #expect(inserted.map(\.revision) == [2, 3])
            await #expect(throws: NoDataError.documentAlreadyExists) {
                try await store.insert([(id: "4", value: ["title": .string("Fourth")]),
                                        (id: "1", value: ["title": .string("Existing")])])
            }
        }

        let reopened = try DocumentStore<[String: JSONValue]>(at: url)
        let changes = try await reopened.changes(after: 1)
        #expect(changes.map(\.revision) == [2, 3])
        #expect(try await reopened.get(id: "4") == nil)
        #expect(try await reopened.get(id: "3") == ["title": .string("Third")])
    }

    @Test func concurrentWritersToOneFileAreRejected() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try DocumentStore<Note>(at: url)
        #expect(NoDataError.storeAlreadyOpen.localizedDescription.contains("open for writing"))
        #expect(throws: NoDataError.storeAlreadyOpen) {
            try DocumentStore<Note>(at: url)
        }
        let value = Note(title: "Safe", tags: [], counters: [:], unsignedCounters: [:])
        let saved = try await store.put(value, id: "1")
        #expect(saved.revision == 1)
    }

    @Test func atomicReplacementKeepsTheWriterLock() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (original, lock) = try ExclusiveFileLock.open(at: url)
        try original.write(contentsOf: Data("old".utf8))
        let pending = try JournalReplacement.prepare(for: url)
        try pending.handle.write(contentsOf: Data("new".utf8))
        let committed = try JournalReplacement.commit(pending, replacing: url)
        #expect(committed.directorySynced)
        #expect(try Data(contentsOf: url) == Data("new".utf8))
        _ = withExtendedLifetime(lock) {
            #expect(throws: NoDataError.storeAlreadyOpen) {
                try ExclusiveFileLock.open(at: url)
            }
        }
    }

    @Test func injectedReplacementFailuresDistinguishRenameFromDirectorySync() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: url)
        let pending = try JournalReplacement.prepare(for: url)
        try pending.handle.write(contentsOf: Data("new".utf8))
        #expect(throws: POSIXError.self) {
            try JournalReplacement.commit(pending, replacing: url) { point in
                if case .beforeRename = point {
                    throw POSIXError(.EIO)
                }
            }
        }
        JournalReplacement.discard(pending)
        #expect(try Data(contentsOf: url) == Data("old".utf8))

        let next = try JournalReplacement.prepare(for: url)
        try next.handle.write(contentsOf: Data("new".utf8))
        let committed = try JournalReplacement.commit(next, replacing: url) { point in
            if case .beforeDirectorySync = point {
                throw POSIXError(.EIO)
            }
        }
        #expect(!committed.directorySynced)
        #expect(try Data(contentsOf: url) == Data("new".utf8))
    }

    @Test(arguments: [JournalFaultPoint.beforeWrite, .beforeFileSync])
    func failedJSONAppendDoesNotSurviveReopen(_ point: JournalFaultPoint) async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try DocumentStore<Note>(at: url)
            _ = try await store.put(Note(title: "Kept", tags: [], counters: [:], unsignedCounters: [:]), id: "1")
        }
        do {
            let store = try DocumentStore<Note>(at: url) { triggered in
                guard triggered == point else { return }
                if point == .beforeWrite {
                    let writer = try FileHandle(forWritingTo: url)
                    _ = try writer.seekToEnd()
                    try writer.write(contentsOf: Data([0x01, 0x02, 0x03]))
                    try writer.close()
                }
                throw POSIXError(.EIO)
            }
            await #expect(throws: POSIXError.self) {
                try await store.put(Note(title: "Rejected", tags: [], counters: [:], unsignedCounters: [:]), id: "2")
            }
            #expect(await store.currentRevision == 1)
        }
        let reopened = try DocumentStore<Note>(at: url)
        #expect(await reopened.currentRevision == 1)
        #expect(try await reopened.get(id: "2") == nil)
        let next = try await reopened.put(Note(title: "Next", tags: [], counters: [:], unsignedCounters: [:]), id: "2")
        #expect(next.revision == 2)
    }

    @Test(arguments: [JournalFaultPoint.beforeRename, .beforeDirectorySync])
    func failedJSONCompactionPreservesReopenState(_ point: JournalFaultPoint) async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try DocumentStore<Note>(at: url)
            _ = try await store.put(Note(title: "Kept", tags: [], counters: [:], unsignedCounters: [:]), id: "1")
        }
        do {
            let store = try DocumentStore<Note>(at: url) { triggered in
                if triggered == point {
                    throw POSIXError(.EIO)
                }
            }
            if point == .beforeRename {
                await #expect(throws: POSIXError.self) { try await store.compact(through: 1) }
            } else {
                await #expect(throws: NoDataError.durabilityUncertain) { try await store.compact(through: 1) }
            }
            #expect(await store.oldestAvailableRevision == (point == .beforeRename ? 0 : 1))
        }
        let reopened = try DocumentStore<Note>(at: url)
        #expect(await reopened.oldestAvailableRevision == (point == .beforeRename ? 0 : 1))
        #expect(try await reopened.get(id: "1")?.title == "Kept")
        let next = try await reopened.put(Note(title: "Next", tags: [], counters: [:], unsignedCounters: [:]), id: "2")
        #expect(next.revision == 2)
    }

    @Test func observerReceivesCommittedChangesInOrder() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try DocumentStore<[String: JSONValue]>(at: url)
        let stream = await store.observe()
        _ = try await store.put(["title": .string("First")], id: "1")
        _ = try await store.insert([
            (id: "2", value: ["title": .string("Second")]),
            (id: "3", value: ["title": .string("Third")]),
        ])
        _ = try await store.delete(id: "1")
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        let third = try await iterator.next()
        let fourth = try await iterator.next()
        #expect(first?.revision == 1 && first?.value?["title"] == .string("First"))
        #expect(second?.revision == 2 && second?.value?["title"] == .string("Second"))
        #expect(third?.revision == 3 && third?.value?["title"] == .string("Third"))
        #expect(fourth?.revision == 4 && fourth?.value == nil)
    }

    @Test func batchInsertReturnsReceiptsWithoutLosingDocuments() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try DocumentStore<Note>(at: url)
            let note = Note(title: "Fast", tags: ["local"], counters: [:], unsignedCounters: [:])
            let receipts = try await store.insert([(id: "1", value: note), (id: "2", value: note)])
            #expect(receipts == [WriteReceipt(id: "1", revision: 1), WriteReceipt(id: "2", revision: 2)])
            let saved = try await store.get(id: "2")
            #expect(saved == note)
            await #expect(throws: NoDataError.documentAlreadyExists) {
                try await store.insert([(id: "3", value: note), (id: "1", value: note)])
            }
        }
        let reopened = try DocumentStore<Note>(at: url)
        let documents = try await reopened.all()
        #expect(documents.count == 2)
        let changes = try await reopened.changes(after: 0)
        #expect(changes.map(\.revision) == [1, 2])
    }

    @Test func batchInsertRejectsNonObjectDocumentsWithoutWriting() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try DocumentStore<[Int]>(at: url)
            await #expect(throws: DecodingError.self) {
                try await store.insert([(id: "1", value: [1, 2])])
            }
            let count = await store.count
            #expect(count == 0)
        }
        let reopened = try DocumentStore<[Int]>(at: url)
        let changes = try await reopened.changes(after: 0)
        #expect(changes.isEmpty)
    }

    @Test func queryAndBatchUpdatesAreValidatedBeforeWriting() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try DocumentStore<Note>(at: url)
        let first = Note(title: "First", tags: ["swift"], counters: [:], unsignedCounters: [:])
        let second = Note(title: "Second", tags: ["other"], counters: [:], unsignedCounters: [:])
        _ = try await store.insert([(id: "1", value: first), (id: "2", value: second)])

        let matches = try await store.query { $0.tags.contains("swift") }
        #expect(matches.map(\.id) == ["1"])
        let visited = try await store.forEach(where: { $0.tags.contains("swift") }) { id, value in
            #expect(id == "1")
            #expect(value.title == "First")
        }
        #expect(visited == 1)
        let updated = try await store.update(ids: ["1", "2"], fields: ["title": .string("Updated")])
        #expect(updated.map(\.title) == ["Updated", "Updated"])
        let individuallyUpdated = try await store.update([
            (id: "1", fields: ["title": .string("One")]),
            (id: "2", fields: ["title": .string("Two")]),
        ])
        #expect(individuallyUpdated.map(\.title) == ["One", "Two"])
        await #expect(throws: DecodingError.self) {
            try await store.update([
                (id: "1", fields: ["title": .string("Bad batch")]),
                (id: "2", fields: ["tags": .string("not an array")]),
            ])
        }
        await #expect(throws: NoDataError.documentNotFound) {
            try await store.update(ids: ["1", "missing"], fields: ["title": .string("Bad batch")])
        }
        let unchanged = try await store.get(id: "1")
        #expect(unchanged?.title == "One")
        let changes = try await store.changes(after: 0)
        #expect(changes.map(\.revision) == [1, 2, 3, 4, 5, 6])
    }

    @Test func querySkipsStaleSchemaIncompatibleValues() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let note = Note(title: "Live", tags: ["swift"], counters: [:], unsignedCounters: [:])
        let validFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note))
        let collection = String(reflecting: Note.self)
        let records: [[String: Any]] = [
            ["revision": 1, "collection": collection, "id": "stale", "fields": ["tags": "old schema"]],
            ["revision": 2, "collection": collection, "id": "live", "fields": validFields],
        ]
        let data = try JournalChecksum.jsonRecord(JSONSerialization.data(withJSONObject: records))
        try data.write(to: url)

        let store = try DocumentStore<Note>(at: url)
        _ = try await store.put(note, id: "stale")
        let matches = try await store.query { $0.tags.contains("swift") }
        #expect(matches.map(\.id) == ["live", "stale"])
        #expect(matches.allSatisfy { $0.value == note })
    }

    @Test func batchDeletesPersistTombstones() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try DocumentStore<[String: JSONValue]>(at: url)
            _ = try await store.insert([
                (id: "1", value: ["name": .string("One")]),
                (id: "2", value: ["name": .string("Two")]),
                (id: "3", value: ["name": .string("Three")]),
            ])
            let deleted = try await store.delete(ids: ["1", "3", "missing"])
            #expect(deleted == 2)
            await #expect(throws: NoDataError.duplicateIdentifier) {
                try await store.delete(ids: ["2", "2"])
            }
        }
        let reopened = try DocumentStore<[String: JSONValue]>(at: url)
        let remaining = try await reopened.allDocuments()
        #expect(remaining.map(\.id) == ["2"])
        let changes = try await reopened.changes(after: 3)
        #expect(changes.map(\.revision) == [4, 5])
        #expect(changes.allSatisfy { $0.fields == nil })
        let streamed = try await reopened.forEachChange(after: 3) { change in
            #expect(change.fields == nil)
        }
        #expect(streamed == 2)
    }

    @Test func deleteAllPersistsAndDoesNotRecordEmptyDeletes() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try DocumentStore<[String: JSONValue]>(at: url)
            _ = try await store.insert([
                (id: "2", value: ["name": .string("Two")]),
                (id: "1", value: ["name": .string("One")]),
            ])
            let deleted = try await store.deleteAll()
            #expect(deleted == 2)
            let deletedAgain = try await store.deleteAll()
            #expect(deletedAgain == 0)
            let changes = try await store.changes(after: 2)
            #expect(changes.map(\.id) == ["1", "2"])
            #expect(changes.map(\.revision) == [3, 4])
            #expect(changes.allSatisfy { $0.fields == nil })
        }

        let reopened = try DocumentStore<[String: JSONValue]>(at: url)
        let documents = try await reopened.allDocuments()
        #expect(documents.isEmpty)
        let next = try await reopened.put(["name": .string("Next")], id: "3")
        #expect(next.revision == 5)
    }

    @Test func automaticDirectoryPersistsPerType() async throws {
        let url = DocumentStore<AutomaticStoreFixture>.defaultURL
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "NoData")
        #expect(url != DocumentStore<Note>.defaultURL)

        let value = AutomaticStoreFixture(title: "Automatic")
        do {
            let store = try DocumentStore<AutomaticStoreFixture>()
            _ = try await store.put(value, id: "1")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        let reopened = try DocumentStore<AutomaticStoreFixture>()
        let saved = try await reopened.get(id: "1")
        #expect(saved == value)
    }

    @Test func codableStructsSurviveReopen() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let note = Note(
            title: "Ideas", tags: ["swift", "local"],
            counters: ["views": Int64.max], unsignedCounters: ["likes": UInt64.max]
        )
        let updatedNote = Note(
            title: "Updated", tags: ["swift", "local"],
            counters: ["views": Int64.max], unsignedCounters: ["likes": UInt64.max]
        )
        let renamedNote = Note(
            title: "Renamed", tags: ["swift", "local"],
            counters: ["views": Int64.max], unsignedCounters: ["likes": UInt64.max]
        )

        do {
            let store = try DocumentStore<Note>(at: url)
            let document = try await store.put(note, id: "note-1")
            #expect(document.revision == 1)
            let fetched = try await store.get(id: "note-1")
            #expect(fetched == note)
            let updated = try await store.update(id: "note-1", fields: ["title": .string("Updated")])
            #expect(updated == updatedNote)
            let renamed = try await store.update(id: "note-1") { $0.title = "Renamed" }
            #expect(renamed == renamedNote)
        }

        #expect(throws: NoDataError.incompatibleType) {
            try DocumentStore<[String: JSONValue]>(at: url)
        }
        let reopened = try DocumentStore<Note>(at: url)
        let fetched = try await reopened.get(id: "note-1")
        #expect(fetched == renamedNote)
        let notes = try await reopened.all()
        #expect(notes == [renamedNote])
        let missing = try await reopened.get(id: "missing")
        #expect(missing == nil)
        let unchanged = try await reopened.update(id: "note-1", fields: ["title": .string("Renamed")])
        #expect(unchanged == renamedNote)
        await #expect(throws: DecodingError.self) {
            try await reopened.update(id: "note-1", fields: ["tags": .string("invalid")])
        }
        await #expect(throws: NoDataError.documentNotFound) {
            try await reopened.update(id: "missing", fields: ["title": .string("Missing")])
        }
        let stillStored = try await reopened.get(id: "note-1")
        #expect(stillStored == renamedNote)
        let changes = try await reopened.changes(after: 0)
        #expect(changes.count == 3)
        #expect(changes.last?.fields?["title"] == .string("Renamed"))
    }

    @Test func documentsAndChangeHistorySurviveReopen() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            let store = try DocumentStore<[String: JSONValue]>(at: url)
            let first = try await store.put(["name": .string("Ada"), "active": .bool(true)], id: "1")
            #expect(first.revision == 1)
            let second = try await store.put(["name": .string("Grace")], id: "2")
            #expect(second.revision == 2)
            let updated = try await store.put(["name": .string("Ada L")], id: "1")
            #expect(updated.revision == 3)
            let ids = try await store.allDocuments().map(\.id)
            let other = try await store.get(id: "missing")
            let deleted = try await store.delete(id: "2")
            let deletedAgain = try await store.delete(id: "2")
            #expect(ids == ["1", "2"])
            #expect(other == nil)
            #expect(deleted)
            #expect(!deletedAgain)
        }

        let reopened = try DocumentStore<[String: JSONValue]>(at: url)
        let document = try await reopened.document(id: "1")
        #expect(document?.fields == ["name": .string("Ada L")])
        #expect(document?.revision == 3)
        let removed = try await reopened.get(id: "2")
        #expect(removed == nil)
        let changes = try await reopened.changes(after: 2)
        #expect(changes.map(\.revision) == [3, 4])
        #expect(changes.last?.id == "2")
        #expect(changes.last?.fields == nil)
    }

    @Test func emptyCheckpointStillRejectsDifferentType() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try DocumentStore<Note>(at: url)
            _ = try await store.put(Note(title: "Deleted", tags: [], counters: [:], unsignedCounters: [:]), id: "1")
            _ = try await store.delete(id: "1")
            try await store.compact(through: 2)
        }
        #expect(throws: NoDataError.incompatibleType) {
            try DocumentStore<[String: JSONValue]>(at: url)
        }
        let reopened = try DocumentStore<Note>(at: url)
        #expect(await reopened.count == 0)
        #expect(await reopened.currentRevision == 2)
    }

    @Test func incompleteFinalRecordIsDiscardedBeforeNextWrite() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            let store = try DocumentStore<[String: JSONValue]>(at: url)
            _ = try await store.put(["value": .number(1)], id: "a")
        }
        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"revision\":2".utf8))
        try handle.close()

        do {
            let reopened = try DocumentStore<[String: JSONValue]>(at: url)
            let next = try await reopened.put(["value": .number(2)], id: "b")
            #expect(next.revision == 2)
        }
        let batchHandle = try FileHandle(forWritingTo: url)
        _ = try batchHandle.seekToEnd()
        try batchHandle.write(contentsOf: Data("[{\"revision\":3".utf8))
        try batchHandle.close()

        let recovered = try DocumentStore<[String: JSONValue]>(at: url)
        let next = try await recovered.put(["value": .number(3)], id: "c")
        #expect(next.revision == 3)
        let changes = try await recovered.changes(after: 0)
        #expect(changes.map(\.revision) == [1, 2, 3])
    }

    @Test func parseableByteCorruptionIsRejected() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try DocumentStore<Note>(at: url)
            let note = Note(title: "First", tags: [], counters: [:], unsignedCounters: [:])
            _ = try await store.put(note, id: "1")
        }
        var bytes = try Data(contentsOf: url)
        let range = try #require(bytes.range(of: Data("First".utf8)))
        bytes[range.lowerBound] = 0x58
        try bytes.write(to: url)
        #expect(throws: NoDataError.corruptLog) {
            try DocumentStore<Note>(at: url)
        }
    }

    @Test func checkpointRetainsLiveDocumentsAndPrunesHistory() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let collection = String(reflecting: [String: JSONValue].self)
        let snapshot = [Change(revision: 2, collection: collection, id: "1", fields: ["title": .string("Kept")])]
        var bytes = try JournalChecksum.jsonRecord(JSONEncoder().encode(JSONCheckpoint(revision: 3)))
        try bytes.append(JournalChecksum.jsonRecord(JSONEncoder().encode(snapshot)))
        try bytes.write(to: url)

        let store = try DocumentStore<[String: JSONValue]>(at: url)
        let saved = try await store.get(id: "1")
        #expect(saved?["title"] == .string("Kept"))
        await #expect(throws: NoDataError.historyPruned) { try await store.changes(after: 2) }
        let next = try await store.put(["title": .string("Next")], id: "2")
        #expect(next.revision == 4)
    }

    @Test func compactionPersistsLiveValuesAndKeepsRevisionOrder() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try DocumentStore<[String: JSONValue]>(at: url)
            _ = try await store.put(["title": .string("Old")], id: "1")
            _ = try await store.put(["title": .string("Deleted")], id: "2")
            _ = try await store.put(["title": .string("Current")], id: "1")
            _ = try await store.delete(id: "2")
            await #expect(throws: NoDataError.unacknowledgedChanges) { try await store.compact(through: 3) }
            try await store.compact(through: 4)
            let current = try await store.get(id: "1")
            #expect(current?["title"] == .string("Current"))
            await #expect(throws: NoDataError.historyPruned) { try await store.changes(after: 3) }
            let next = try await store.put(["title": .string("Next")], id: "3")
            #expect(next.revision == 5)
        }
        let reopened = try DocumentStore<[String: JSONValue]>(at: url)
        let count = await reopened.count
        #expect(count == 2)
        let changes = try await reopened.changes(after: 4)
        #expect(changes.map(\.revision) == [5])
        await #expect(throws: NoDataError.historyPruned) { try await reopened.changes(after: 3) }
    }

    @Test func corruptCompleteRecordIsRejected() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid\n".utf8).write(to: url)

        #expect(throws: NoDataError.corruptLog) {
            try DocumentStore<Note>(at: url)
        }
    }

    @Test func jsonValuesRoundTripAndInvalidIdentifiers() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try DocumentStore<[String: JSONValue]>(at: url)
        let fields: [String: JSONValue] = [
            "nested": .object(["array": .array([.null, .bool(false), .number(3.5), .string("a\nb")])]),
        ]
        _ = try await store.put(fields, id: "1")
        let stored = try await store.get(id: "1")
        #expect(stored == fields)

        await #expect(throws: NoDataError.invalidIdentifier) {
            try await store.put([:], id: "")
        }
        let changes = try await store.changes(after: 0)
        #expect(changes.count == 1)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("store.ndjson")
    }
}
