import Foundation
@testable import NoData
import Testing

struct ProtobufCodableStoreTests {
    @Test func defaultPathSharesTypeDirectoryWithoutSharingDataFile() {
        let jsonURL = DocumentStore<BenchmarkDocument>.defaultURL
        let protobufURL = ProtobufDocumentStore<BenchmarkDocument>.defaultURL
        #expect(jsonURL.deletingLastPathComponent() == protobufURL.deletingLastPathComponent())
        #expect(jsonURL.lastPathComponent == "store.ndjson")
        #expect(protobufURL.lastPathComponent == "store.pbdb")
    }

    @Test func nestedStructsSurviveReopen() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let note = makeNote(title: "Nested")
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
            let receipt = try await store.put(note, id: "1")
            #expect(receipt == WriteReceipt(id: "1", revision: 1))
            let stored = try await store.get(id: "1")
            #expect(stored == note)
        }
        #expect(throws: NoDataError.incompatibleType) {
            try ProtobufDocumentStore<Note>(at: url)
        }
        let reopened = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        let stored = try await reopened.get(id: "1")
        #expect(stored == note)
        #expect(stored?.metadata.details.region == "eu-west")
        let count = await reopened.count
        #expect(count == 1)
    }

    @Test func concurrentWritersToOneFileAreRejected() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
            #expect(FileManager.default.fileExists(atPath: url.path + ".lock"))
            #expect(throws: NoDataError.storeAlreadyOpen) {
                try ProtobufDocumentStore<BenchmarkDocument>(at: url)
            }
            let receipt = try await store.put(makeNote(title: "First"), id: "1")
            #expect(receipt.revision == 1)
        }
        let reopened = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        let saved = try await reopened.get(id: "1")
        #expect(saved?.title == "First")
    }

    @Test(arguments: [JournalFaultPoint.beforeWrite, .beforeFileSync])
    func failedProtobufAppendDoesNotSurviveReopen(_ point: JournalFaultPoint) async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
            _ = try await store.put(makeNote(title: "Kept"), id: "1")
        }
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url) { triggered in
                guard triggered == point else { return }
                if point == .beforeWrite {
                    let writer = try FileHandle(forWritingTo: url)
                    _ = try writer.seekToEnd()
                    try writer.write(contentsOf: Data([0x01, 0x02, 0x03]))
                    try writer.close()
                }
                throw POSIXError(.EIO)
            }
            await #expect(throws: POSIXError.self) { try await store.put(makeNote(title: "Rejected"), id: "2") }
            #expect(await store.currentRevision == 1)
        }
        let reopened = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        #expect(await reopened.currentRevision == 1)
        #expect(try await reopened.get(id: "2") == nil)
        let next = try await reopened.put(makeNote(title: "Next"), id: "2")
        #expect(next.revision == 2)
    }

    @Test(arguments: [JournalFaultPoint.beforeRename, .beforeDirectorySync])
    func failedProtobufCompactionPreservesReopenState(_ point: JournalFaultPoint) async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
            _ = try await store.put(makeNote(title: "Kept"), id: "1")
        }
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url) { triggered in
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
        let reopened = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        #expect(await reopened.oldestAvailableRevision == (point == .beforeRename ? 0 : 1))
        #expect(try await reopened.get(id: "1")?.title == "Kept")
        let next = try await reopened.put(makeNote(title: "Next"), id: "2")
        #expect(next.revision == 2)
    }

    @Test func observerReceivesCommittedBinaryChanges() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        let stream = await store.observe()
        _ = try await store.insert([
            (id: "1", value: makeNote(title: "First")),
            (id: "2", value: makeNote(title: "Second")),
        ])
        _ = try await store.delete(id: "1")
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        let deleted = try await iterator.next()
        #expect(first?.revision == 1 && first?.id == "1")
        #expect(first?.value?.title == "First")
        #expect(second?.revision == 2 && second?.id == "2")
        #expect(deleted?.revision == 3 && deleted?.value == nil)
    }

    @Test func largeIntegerStructsRoundTrip() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let note = Note(
            title: "Large", tags: [],
            counters: ["signed": Int64.max], unsignedCounters: ["unsigned": UInt64.max]
        )
        do {
            let store = try ProtobufDocumentStore<Note>(at: url)
            _ = try await store.put(note, id: "1")
        }
        let reopened = try ProtobufDocumentStore<Note>(at: url)
        let stored = try await reopened.get(id: "1")
        #expect(stored == note)
    }

    @Test func incompleteFrameIsDiscardedOnReopen() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
            _ = try await store.put(makeNote(title: "First"), id: "1")
        }
        let writer = try FileHandle(forWritingTo: url)
        _ = try writer.seekToEnd()
        try writer.write(contentsOf: Data([16, 0, 0, 0, 1, 2]))
        try writer.close()
        let reopened = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        let next = try await reopened.put(makeNote(title: "Second"), id: "2")
        #expect(next.revision == 2)
        let first = try await reopened.get(id: "1")
        #expect(first?.title == "First")
    }

    @Test func batchInsertIsAtomicAndReturnsReceipts() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
            let receipts = try await store.insert([
                (id: "1", value: makeNote(title: "One")),
                (id: "2", value: makeNote(title: "Two")),
            ])
            #expect(receipts == [WriteReceipt(id: "1", revision: 1), WriteReceipt(id: "2", revision: 2)])
            await #expect(throws: NoDataError.documentAlreadyExists) {
                try await store.insert([
                    (id: "3", value: makeNote(title: "Three")),
                    (id: "1", value: makeNote(title: "Duplicate")),
                ])
            }
        }
        let reopened = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        let one = try await reopened.get(id: "1")
        let two = try await reopened.get(id: "2")
        let absent = try await reopened.get(id: "3")
        #expect(one?.title == "One")
        #expect(two?.title == "Two")
        #expect(absent == nil)
    }

    @Test func queriesUpdatesAndDeletesPersist() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
            _ = try await store.insert([
                (id: "1", value: makeNote(title: "One")),
                (id: "2", value: makeNote(title: "Two")),
            ])
            let matches = try await store.query { $0.metadata.details.region == "eu-west" }
            #expect(matches.map(\.id) == ["1", "2"])
            let updated = try await store.update(ids: ["1", "2"]) { $0.title = "Updated" }
            #expect(updated.map(\.title) == ["Updated", "Updated"])
            await #expect(throws: NoDataError.documentNotFound) {
                try await store.update(ids: ["1", "missing"]) { $0.title = "Invalid" }
            }
            let first = try await store.get(id: "1")
            #expect(first?.title == "Updated")
            let deleted = try await store.delete(ids: ["1", "missing"])
            #expect(deleted == 1)
            let remainder = try await store.deleteAll()
            #expect(remainder == 1)
            let empty = try await store.deleteAll()
            #expect(empty == 0)
        }
        let reopened = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        let count = await reopened.count
        #expect(count == 0)
        let receipt = try await reopened.put(makeNote(title: "Next"), id: "3")
        #expect(receipt.revision == 7)
        let changes = try await reopened.changes(after: 4)
        #expect(changes.map(\.revision) == [5, 6, 7])
        #expect(changes[0].payload == nil && changes[1].payload == nil)
        let changed = try changes[2].decode(as: BenchmarkDocument.self)
        #expect(changed?.title == "Next")
        let streamed = try await reopened.forEachChange(after: 4) { change in
            #expect(change.revision >= 5)
        }
        #expect(streamed == 3)
    }

    @Test func deleteAllCanReplayMultipleFrames() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
            _ = try await store.insert([
                (id: "1", value: makeNote(title: "One")),
                (id: "2", value: makeNote(title: "Two")),
                (id: "3", value: makeNote(title: "Three")),
            ])
            let deleted = try await store.deleteAll(batchSize: 1)
            #expect(deleted == 3)
            let changes = try await store.changes(after: 3)
            #expect(changes.map(\.revision) == [4, 5, 6])
            #expect(changes.allSatisfy { $0.payload == nil })
        }
        let reopened = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        let count = await reopened.count
        #expect(count == 0)
    }

    @Test func replacementBatchesAndSingleDeletePersist() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
            _ = try await store.put(makeNote(title: "Old One"), id: "1")
            _ = try await store.put(makeNote(title: "Old Two"), id: "2")
            await #expect(throws: NoDataError.documentNotFound) {
                try await store.update([
                    (id: "1", value: makeNote(title: "Invalid")),
                    (id: "missing", value: makeNote(title: "Missing")),
                ])
            }
            let receipts = try await store.update([
                (id: "1", value: makeNote(title: "New One")),
                (id: "2", value: makeNote(title: "New Two")),
            ])
            #expect(receipts.map(\.revision) == [3, 4])
            let deleted = try await store.delete(id: "1")
            let deletedAgain = try await store.delete(id: "1")
            #expect(deleted)
            #expect(!deletedAgain)
        }
        let reopened = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        let missing = try await reopened.get(id: "1")
        let remaining = try await reopened.get(id: "2")
        #expect(missing == nil)
        #expect(remaining?.title == "New Two")
        let next = try await reopened.put(makeNote(title: "Next"), id: "3")
        #expect(next.revision == 6)
    }

    @Test func malformedCompleteFrameIsRejected() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        let writer = try FileHandle(forWritingTo: url)
        _ = try writer.seekToEnd()
        try writer.write(contentsOf: Data([1, 0, 0, 0, 0, 0, 0, 0, 0xFF]))
        try writer.close()
        #expect(throws: NoDataError.corruptLog) {
            try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        }
    }

    @Test func parseableByteCorruptionIsRejected() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
            _ = try await store.put(makeNote(title: "First"), id: "1")
        }
        var bytes = try Data(contentsOf: url)
        let range = try #require(bytes.range(of: Data("First".utf8)))
        bytes[range.lowerBound] = 0x58
        try bytes.write(to: url)
        #expect(throws: NoDataError.corruptLog) {
            try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        }
    }

    @Test func compactionPreservesLivePayloadAndMonotonicRevisions() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
            _ = try await store.put(makeNote(title: "Old"), id: "1")
            _ = try await store.put(makeNote(title: "Deleted"), id: "2")
            _ = try await store.put(makeNote(title: "Current"), id: "1")
            _ = try await store.delete(id: "2")
            await #expect(throws: NoDataError.unacknowledgedChanges) { try await store.compact(through: 3) }
            try await store.compact(through: 4)
            let saved = try await store.get(id: "1")
            #expect(saved?.title == "Current")
            await #expect(throws: NoDataError.historyPruned) { try await store.changes(after: 3) }
            let next = try await store.put(makeNote(title: "Next"), id: "3")
            #expect(next.revision == 5)
        }
        let reopened = try ProtobufDocumentStore<BenchmarkDocument>(at: url)
        let saved = try await reopened.get(id: "1")
        #expect(saved?.title == "Current")
        let changes = try await reopened.changes(after: 4)
        #expect(changes.map(\.revision) == [5])
        await #expect(throws: NoDataError.historyPruned) { try await reopened.changes(after: 3) }
    }

    private func makeNote(title: String) -> BenchmarkDocument {
        BenchmarkDocument(
            number: 42, title: title, category: "segment-0", payload: "sample",
            metadata: BenchmarkMetadata(
                source: "watch", tags: ["swift", "local"],
                details: BenchmarkDetails(region: "eu-west", score: 3.5, flags: ["active": true])
            )
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("store.pbdb")
    }
}
