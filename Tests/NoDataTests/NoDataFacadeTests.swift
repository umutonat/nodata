import Foundation
import NoData
import Testing

struct NoDataFacadeTests {
    @Test func omittedEngineDefaultsToJSON() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let note = Note(title: "Default", tags: [], counters: [:], unsignedCounters: [:])
        do {
            let store = try NoData<Note>(at: url)
            _ = try await store.put(note, id: "1")
        }
        let jsonStore = try NoData<Note>(.json, at: url)
        let fetched = try await jsonStore.get(id: "1")
        #expect(fetched == note)
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func typedReadsAndWritesUseSelectedEngine(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let note = Note(title: "Hello", tags: ["swift"], counters: [:], unsignedCounters: [:])
        do {
            let store = try NoData<Note>(engine, at: url)
            let receipt = try await store.put(note, id: "1")
            #expect(receipt.id == "1" && receipt.revision == 1)
            let inserted = try await store.insert([(id: "2", value: note)])
            #expect(inserted.map(\.revision) == [2])
            let fetched = try await store.get(id: "1")
            #expect(fetched == note)
        }
        let reopened = try NoData<Note>(engine, at: url)
        let fetched = try await reopened.get(id: "2")
        #expect(fetched == note)
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func backupCapturesCommittedStateWithoutOverwriting(_ engine: NoDataEngine) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("store")
        let backup = directory.appendingPathComponent("backup")
        let first = Note(title: "Saved", tags: [], counters: [:], unsignedCounters: [:])
        do {
            let store = try NoData<Note>(engine, at: source)
            _ = try await store.put(first, id: "1")
            try await store.backup(to: backup)
            _ = try await store.put(Note(title: "Later", tags: [], counters: [:], unsignedCounters: [:]), id: "2")
            await #expect(throws: NoDataError.backupAlreadyExists) { try await store.backup(to: backup) }
        }
        let archived = try NoData<Note>(engine, at: backup)
        let saved = try await archived.get(id: "1")
        let later = try await archived.get(id: "2")
        #expect(saved == first)
        #expect(later == nil)
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func restoreValidatesBackupBeforeReplacingDestination(_ engine: NoDataEngine) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("store")
        let backup = directory.appendingPathComponent("backup")
        let note = Note(title: "Saved", tags: [], counters: [:], unsignedCounters: [:])
        do {
            let store = try NoData<Note>(engine, at: source)
            _ = try await store.put(note, id: "1")
            try await store.backup(to: backup)
            _ = try await store.put(Note(title: "Later", tags: [], counters: [:], unsignedCounters: [:]), id: "2")
            #expect(throws: NoDataError.storeAlreadyOpen) {
                try NoData<Note>.restore(from: backup, engine: engine, at: source)
            }
        }
        try NoData<Note>.restore(from: backup, engine: engine, at: source)
        let restored = try NoData<Note>(engine, at: source)
        let saved = try await restored.get(id: "1")
        let removed = try await restored.get(id: "2")
        #expect(saved == note)
        #expect(removed == nil)
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func corruptBackupDoesNotReplaceExistingData(_ engine: NoDataEngine) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("store")
        let backup = directory.appendingPathComponent("backup")
        do {
            let store = try NoData<Note>(engine, at: source)
            _ = try await store.put(Note(title: "Saved", tags: [], counters: [:], unsignedCounters: [:]), id: "1")
            try await store.backup(to: backup)
            _ = try await store.put(Note(title: "Current", tags: [], counters: [:], unsignedCounters: [:]), id: "1")
        }
        var bytes = try Data(contentsOf: backup)
        let range = try #require(bytes.range(of: Data("Saved".utf8)))
        bytes[range.lowerBound] = 0x58
        try bytes.write(to: backup)
        #expect(throws: NoDataError.corruptLog) {
            try NoData<Note>.restore(from: backup, engine: engine, at: source)
        }
        let current = try NoData<Note>(engine, at: source)
        let saved = try await current.get(id: "1")
        #expect(saved?.title == "Current")
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func truncatedBackupDoesNotReplaceExistingData(_ engine: NoDataEngine) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("store")
        let backup = directory.appendingPathComponent("backup")
        do {
            let store = try NoData<Note>(engine, at: source)
            _ = try await store.put(Note(title: "Saved", tags: [], counters: [:], unsignedCounters: [:]), id: "1")
            _ = try await store.put(Note(title: "Archived", tags: [], counters: [:], unsignedCounters: [:]), id: "1")
            try await store.backup(to: backup)
            _ = try await store.put(Note(title: "Current", tags: [], counters: [:], unsignedCounters: [:]), id: "1")
        }
        var bytes = try Data(contentsOf: backup)
        bytes.removeLast(2)
        try bytes.write(to: backup)
        #expect(throws: NoDataError.corruptLog) {
            try NoData<Note>.restore(from: backup, engine: engine, at: source)
        }
        #expect(try Data(contentsOf: backup) == bytes)
        let current = try NoData<Note>(engine, at: source)
        let saved = try await current.get(id: "1")
        #expect(saved?.title == "Current")
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func queriesUpdatesAndDeletesUseSelectedEngine(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(engine, at: url)
        let note = Note(title: "First", tags: ["swift"], counters: [:], unsignedCounters: [:])
        _ = try await store.insert([(id: "1", value: note), (id: "2", value: note)])
        let count = await store.count
        #expect(count == 2)
        let results = try await store.query { $0.tags.contains("swift") }
        #expect(results.map(\.id) == ["1", "2"])
        let visited = try await store.forEach(where: { $0.title == "First" }) { _, value in
            #expect(value.title == "First")
        }
        #expect(visited == 2)
        let updated = try await store.update(id: "1") { $0.title = "Updated" }
        #expect(updated.title == "Updated")
        let deleted = try await store.delete(ids: ["2", "missing"])
        #expect(deleted == 1)
        let all = try await store.all()
        #expect(all.map(\.title) == ["Updated"])
        let remainder = try await store.deleteAll()
        #expect(remainder == 1)
        let empty = try await store.delete(id: "1")
        #expect(!empty)
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func sequentialQuerySkipsStaleRecordsBeforeAndAfterCompaction(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(engine, at: url)
        let note = Note(title: "Old", tags: [], counters: [:], unsignedCounters: [:])
        _ = try await store.insert([(id: "a", value: note), (id: "b", value: note)])
        _ = try await store.update(id: "a") { $0.title = "Current" }
        _ = try await store.delete(id: "b")
        let before = try await store.query { $0.title == "Current" }
        #expect(before.map(\.id) == ["a"])
        try await store.compact(through: 4)
        let after = try await store.query { $0.title == "Current" }
        #expect(after.map(\.id) == ["a"])
        _ = try await store.put(Note(title: "Current", tags: [], counters: [:], unsignedCounters: [:]), id: "c")
        let later = try await store.query { $0.title == "Current" }
        #expect(later.map(\.id) == ["a", "c"])
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func batchMutationsValidateAllDocuments(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(engine, at: url)
        let note = Note(title: "First", tags: [], counters: [:], unsignedCounters: [:])
        _ = try await store.insert([(id: "1", value: note), (id: "2", value: note)])
        await #expect(throws: NoDataError.documentNotFound) {
            try await store.update(ids: ["1", "missing"]) { $0.title = "Invalid" }
        }
        let original = try await store.get(id: "1")
        #expect(original?.title == "First")
        let updated = try await store.update(ids: ["1", "2"]) { $0.title = "Batch" }
        #expect(updated.map(\.title) == ["Batch", "Batch"])
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func acknowledgedCompactionKeepsTheLiveCollection(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let note = Note(title: "Kept", tags: [], counters: [:], unsignedCounters: [:])
        do {
            let store = try NoData<Note>(engine, at: url)
            _ = try await store.put(note, id: "1")
            _ = try await store.put(note, id: "2")
            _ = try await store.delete(id: "2")
            let revision = await store.currentRevision
            #expect(revision == 3)
            await #expect(throws: NoDataError.unacknowledgedChanges) { try await store.compact(through: 2) }
            try await store.compact(through: revision)
            let floor = await store.oldestAvailableRevision
            #expect(floor == revision)
            let saved = try await store.get(id: "1")
            #expect(saved == note)
        }
        let reopened = try NoData<Note>(engine, at: url)
        let floor = await reopened.oldestAvailableRevision
        #expect(floor == 3)
        await #expect(throws: NoDataError.historyPruned) { try await reopened.changes(after: 2) }
        await #expect(throws: NoDataError.historyPruned) { try await reopened.changes(after: 2, limit: 1) }
        await #expect(throws: NoDataError.historyPruned) { try await reopened.observe(after: 2) }
        let atFloor = try await reopened.changes(after: floor, limit: 1)
        #expect(atFloor.isEmpty)
        let receipt = try await reopened.put(note, id: "3")
        #expect(receipt.revision == 4)
        let nextPage = try await reopened.changes(after: floor, limit: 1)
        #expect(nextPage.map(\.revision) == [4])
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func compactionShrinksRepeatedUpdates(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(engine, at: url)
        for index in 0 ..< 100 {
            let note = Note(title: "Revision \(index)", tags: [], counters: [:], unsignedCounters: [:])
            _ = try await store.put(note, id: "1")
        }
        let before = try #require((FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue)
        let revision = await store.currentRevision
        try await store.compact(through: revision)
        let after = try #require((FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue)
        #expect(after < before)
        let saved = try await store.get(id: "1")
        #expect(saved?.title == "Revision 99")
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func liveDocumentLimitIsEnforcedOnWritesAndReopen(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let note = Note(title: "Limited", tags: [], counters: [:], unsignedCounters: [:])
        do {
            let store = try NoData<Note>(engine, at: url, maximumLiveDocuments: 2)
            _ = try await store.insert([(id: "1", value: note), (id: "2", value: note)])
            await #expect(throws: NoDataError.capacityExceeded) {
                try await store.insert([(id: "3", value: note)])
            }
            let count = await store.count
            #expect(count == 2)
        }
        #expect(throws: NoDataError.capacityExceeded) {
            try NoData<Note>(engine, at: url, maximumLiveDocuments: 1)
        }
        let reopened = try NoData<Note>(engine, at: url, maximumLiveDocuments: 2)
        let count = await reopened.count
        #expect(count == 2)
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func liveDocumentLimitAppliesToCompactedSnapshots(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let note = Note(title: "Snapshot", tags: [], counters: [:], unsignedCounters: [:])
        do {
            let store = try NoData<Note>(engine, at: url, maximumLiveDocuments: 2)
            _ = try await store.insert([(id: "1", value: note), (id: "2", value: note)])
            try await store.compact(through: 2)
        }
        #expect(throws: NoDataError.capacityExceeded) {
            try NoData<Note>(engine, at: url, maximumLiveDocuments: 1)
        }
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func compactionDoesNotPruneActiveObservers(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(engine, at: url)
        let note = Note(title: "Live", tags: [], counters: [:], unsignedCounters: [:])
        _ = try await store.put(note, id: "1")
        let stream = await store.observe()
        await #expect(throws: NoDataError.compactionBlocked) { try await store.compact(through: 1) }
        _ = try await store.put(note, id: "2")
        var iterator = stream.makeAsyncIterator()
        let change = try await iterator.next()
        #expect(change?.revision == 2)
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func boundedHistoryReplayCanResumeFromNewCursor(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(engine, at: url)
        let note = Note(title: "Catch up", tags: [], counters: [:], unsignedCounters: [:])
        _ = try await store.insert((0 ..< 257).map { (id: String($0), value: note) })
        await #expect(throws: NoDataError.observerOverflow) { try await store.observe(after: 0) }
        let stream = try await store.observe(after: 256)
        _ = try await store.put(note, id: "next")
        var iterator = stream.makeAsyncIterator()
        let replayed = try await iterator.next()
        let live = try await iterator.next()
        #expect(replayed?.revision == 257)
        #expect(live?.revision == 258)
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func changeFeedUsesTypedValuesAndTombstones(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(engine, at: url)
        let note = Note(title: "Synced", tags: [], counters: [:], unsignedCounters: [:])
        _ = try await store.insert([(id: "1", value: note), (id: "2", value: note)])
        _ = try await store.delete(id: "2")

        let changes = try await store.changes(after: 0)
        #expect(changes.map(\.revision) == [1, 2, 3])
        #expect(changes[0].value == note)
        #expect(changes[2].value == nil)
        let streamed = try await store.forEachChange(after: 1) { change in
            #expect(change.revision > 1)
        }
        #expect(streamed == 2)
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func changePagesResumeWithoutGaps(_ engine: NoDataEngine) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NoData<Note>(engine, at: directory.appendingPathComponent("database"))
        let note = Note(title: "Paged", tags: [], counters: [:], unsignedCounters: [:])
        _ = try await store.insert((0 ..< 5).map { (id: String($0), value: note) })
        let first = try await store.changes(after: 0, limit: 2)
        let second = try await store.changes(after: 2, limit: 2)
        let third = try await store.changes(after: 4, limit: 2)
        #expect(first.map(\.revision) == [1, 2])
        #expect(second.map(\.revision) == [3, 4])
        #expect(third.map(\.revision) == [5])
        await #expect(throws: NoDataError.invalidPageSize) { try await store.changes(after: 0, limit: 0) }
        await #expect(throws: NoDataError.invalidPageSize) { try await store.changes(after: 0, limit: -1) }
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func observerYieldsLiveTypedChanges(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(engine, at: url)
        let stream = await store.observe()
        let note = Note(title: "First", tags: [], counters: [:], unsignedCounters: [:])
        _ = try await store.put(note, id: "1")
        _ = try await store.insert([(id: "2", value: note), (id: "3", value: note)])
        _ = try await store.update(id: "1") { $0.title = "Updated" }
        _ = try await store.delete(id: "2")

        var iterator = stream.makeAsyncIterator()
        var changes: [NoDataChange<Note>] = []
        for _ in 0 ..< 5 {
            if let change = try await iterator.next() {
                changes.append(change)
            }
        }
        #expect(changes.map(\.revision) == [1, 2, 3, 4, 5])
        #expect(changes[3].value?.title == "Updated")
        #expect(changes[4].value == nil)
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func observationReplaysHistoryBeforeLiveEvents(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(engine, at: url)
        let note = Note(title: "Past", tags: [], counters: [:], unsignedCounters: [:])
        _ = try await store.put(note, id: "1")
        let stream = try await store.observe(after: 0)
        _ = try await store.put(note, id: "2")
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        #expect(first?.revision == 1 && first?.id == "1")
        #expect(second?.revision == 2 && second?.id == "2")
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func observerOverflowCanResumeFromJournal(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(engine, at: url)
        let stream = await store.observe()
        let note = Note(title: "Queued", tags: [], counters: [:], unsignedCounters: [:])
        let entries = (0 ..< 300).map { (id: String($0), value: note) }
        _ = try await store.insert(entries)

        var iterator = stream.makeAsyncIterator()
        var lastRevision: UInt64 = 0
        do {
            while let change = try await iterator.next() {
                lastRevision = change.revision
            }
            Issue.record("Expected a bounded observer overflow")
        } catch {
            #expect(error as? NoDataError == .observerOverflow)
        }
        var remaining: [NoDataChange<Note>] = []
        var cursor = lastRevision
        while true {
            let page = try await store.changes(after: cursor, limit: 64)
            guard let last = page.last else { break }
            remaining.append(contentsOf: page)
            cursor = last.revision
        }
        #expect(remaining.count == 300 - Int(lastRevision))
        #expect(remaining.first?.revision == lastRevision + 1)
        #expect(remaining.last?.revision == 300)
        let count = await store.count
        #expect(count == 300)
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func observerIgnoresRejectedWrites(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(engine, at: url)
        let stream = await store.observe()
        let note = Note(title: "First", tags: [], counters: [:], unsignedCounters: [:])
        _ = try await store.put(note, id: "1")
        await #expect(throws: NoDataError.documentAlreadyExists) {
            try await store.insert([(id: "1", value: note)])
        }
        _ = try await store.delete(id: "1")
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        #expect(first?.revision == 1 && first?.value == note)
        #expect(second?.revision == 2 && second?.value == nil)
    }

    @Test func cancelledObserverStopsWaiting() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(at: url)
        let stream = await store.observe()
        let task = Task { () -> Bool in
            do {
                for try await _ in stream {}
                return true
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        let finished = await task.value
        #expect(finished)
        try await store.compact(through: 0)
    }

    @Test(arguments: [NoDataEngine.json, .protobuf])
    func droppedObserverReleasesSubscription(_ engine: NoDataEngine) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("database")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try NoData<Note>(engine, at: url)
        do {
            let stream = await store.observe()
            withExtendedLifetime(stream) {}
        }
        try await store.compact(through: 0)
    }
}
