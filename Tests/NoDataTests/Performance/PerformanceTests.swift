import Darwin
import Foundation
@testable import NoData
import Testing

struct PerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NODATA_SOAK_DIRECTORY"] != nil))
    func restartSoakCycle() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = try #require(environment["NODATA_SOAK_DIRECTORY"])
        let engineName = try #require(environment["NODATA_SOAK_ENGINE"])
        guard let cycle = Int(environment["NODATA_SOAK_CYCLE"] ?? ""), cycle >= 0,
              let documentCount = Int(environment["NODATA_SOAK_COUNT"] ?? "200"), documentCount >= 40
        else { throw NoDataError.invalidDocument }
        let engine: NoDataEngine = switch engineName {
        case "json": .json
        case "protobuf": .protobuf
        default: throw NoDataError.invalidDocument
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = folder.appendingPathComponent("\(engineName).store")
        let backup = folder.appendingPathComponent("\(engineName)-\(cycle).backup")
        let startingRevision = UInt64(cycle) * UInt64(documentCount + 60)
        let latestRevision = startingRevision + UInt64(documentCount + 60)
        let value = Note(title: "Cycle \(cycle)", tags: ["soak"], counters: [:], unsignedCounters: [:])

        do {
            let store = try NoData<Note>(engine, at: database)
            #expect(await store.currentRevision == startingRevision)
            #expect(await store.count == (cycle == 0 ? 0 : documentCount))
            for index in 0 ..< documentCount {
                _ = try await store.put(value, id: String(index))
            }
            let ids = (0 ..< 20).map(String.init)
            #expect(try await store.delete(ids: ids) == 20)
            _ = try await store.insert(ids.map { (id: $0, value: value) })
            _ = try await store.update(ids: (20 ..< 40).map(String.init)) { $0.title = "Updated \(cycle)" }
            #expect(await store.currentRevision == latestRevision)
            #expect(try await store.query { $0.tags.contains("soak") }.count == documentCount)

            var cursor = startingRevision
            while cursor < latestRevision {
                let page = try await store.changes(after: cursor, limit: 31)
                let last = try #require(page.last)
                #expect(page.count <= 31)
                #expect(page[0].revision == cursor + 1)
                cursor = last.revision
            }
            #expect(cursor == latestRevision)
            try await store.compact(through: latestRevision)
            try await store.backup(to: backup)
        }

        try NoData<Note>.restore(from: backup, engine: engine, at: database)
        let reopened = try NoData<Note>(engine, at: database)
        #expect(await reopened.currentRevision == latestRevision)
        #expect(await reopened.oldestAvailableRevision == latestRevision)
        #expect(await reopened.count == documentCount)
        #expect(try await reopened.get(id: "0")?.title == "Cycle \(cycle)")
        #expect(try await reopened.get(id: "20")?.title == "Updated \(cycle)")
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw POSIXError(.EIO) }
        print("Soak \(engineName) cycle \(cycle): \(documentCount) live, revision \(latestRevision), peak test-process RSS \(usage.ru_maxrss) bytes")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NODATA_QUERY_STORE"] != nil))
    func existingStoreQueryBenchmark() async throws {
        guard let path = ProcessInfo.processInfo.environment["NODATA_QUERY_STORE"] else { return }
        let clock = ContinuousClock()
        let store = try DocumentStore<BenchmarkDocument>(at: URL(fileURLWithPath: path))
        let start = clock.now
        let matches = try await store.query {
            $0.category == "segment-0" && $0.metadata.details.region == "region-0"
        }
        print("Existing store query: \(start.duration(to: clock.now)); matched \(matches.count) documents")
        #expect(!matches.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NODATA_PERFORMANCE_TEST"] == "1"))
    func millionDocumentBenchmark() async throws {
        let fileManager = FileManager.default
        let documentCount = Int(ProcessInfo.processInfo.environment["NODATA_BENCHMARK_COUNT"] ?? "") ?? 1_000_000
        let batchSize = 2000
        #expect(documentCount > 0)
        guard documentCount > 0 else { return }

        let outputDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".build/performance", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fixtureURL = outputDirectory.appendingPathComponent("documents.json")
        let storeURL = outputDirectory.appendingPathComponent("store.ndjson")
        let payload = String(repeating: "x", count: 128)
        let clock = ContinuousClock()
        let encoder = JSONEncoder()

        let fixtureStart = clock.now
        _ = fileManager.createFile(atPath: fixtureURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: fixtureURL)
        try writer.write(contentsOf: Data("[".utf8))
        for start in stride(from: 0, to: documentCount, by: batchSize) {
            var chunk = Data()
            for index in start ..< min(start + batchSize, documentCount) {
                if index > 0 {
                    chunk.append(0x2C)
                }
                try chunk.append(encoder.encode(makeDocument(index: index, payload: payload)))
            }
            try writer.write(contentsOf: chunk)
        }
        try writer.write(contentsOf: Data("]".utf8))
        try writer.synchronize()
        try writer.close()
        let fixtureDuration = fixtureStart.duration(to: clock.now)

        let sampleCount = min(1000, documentCount)
        let sampleIDs = (0 ..< sampleCount).map(String.init)
        let insertDuration: Duration
        let readDuration: Duration
        let queryDuration: Duration
        let updateDuration: Duration
        let deleteDuration: Duration
        do {
            let store = try DocumentStore<BenchmarkDocument>(at: storeURL)
            let insertStart = clock.now
            for start in stride(from: 0, to: documentCount, by: batchSize) {
                let entries = (start ..< min(start + batchSize, documentCount)).map { index in
                    (id: String(index), value: makeDocument(index: index, payload: payload))
                }
                _ = try await store.insert(entries)
            }
            insertDuration = insertStart.duration(to: clock.now)
            let nested = try await store.get(id: String(documentCount - 1))
            #expect(nested == makeDocument(index: documentCount - 1, payload: payload))

            let readStart = clock.now
            for id in sampleIDs {
                let document = try await store.get(id: id)
                #expect(document != nil)
            }
            readDuration = readStart.duration(to: clock.now)

            let queryStart = clock.now
            let matches = try await store.query {
                $0.category == "segment-0" && $0.metadata.details.region == "region-0"
            }
            queryDuration = queryStart.duration(to: clock.now)
            #expect(matches.count == (documentCount + 59) / 60)

            let updateStart = clock.now
            let updated = try await store.update(ids: sampleIDs, fields: ["category": .string("updated")])
            updateDuration = updateStart.duration(to: clock.now)
            #expect(updated.count == sampleCount)

            let deleteStart = clock.now
            let deleted = try await store.delete(ids: sampleIDs)
            deleteDuration = deleteStart.duration(to: clock.now)
            #expect(deleted == sampleCount)
        }

        let reopenStart = clock.now
        let reopened = try DocumentStore<BenchmarkDocument>(at: storeURL)
        let reopenDuration = reopenStart.duration(to: clock.now)
        let remaining = await reopened.count
        let missing = try await reopened.get(id: "0")
        #expect(remaining == documentCount - sampleCount)
        #expect(missing == nil)
        if sampleCount < documentCount {
            let surviving = try await reopened.get(id: String(sampleCount))
            #expect(surviving == makeDocument(index: sampleCount, payload: payload))
        }

        let fixtureSize = try (fileManager.attributesOfItem(atPath: fixtureURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let logSize = try (fileManager.attributesOfItem(atPath: storeURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        print("NoData benchmark: \(documentCount) documents, JSON \(fixtureSize) bytes, log \(logSize) bytes")
        print("Fixture: \(fixtureDuration); batch insert: \(insertDuration); 1K reads: \(readDuration)")
        print("Query: \(queryDuration); 1K updates: \(updateDuration); 1K deletes: \(deleteDuration); reopen: \(reopenDuration)")
        print("JSON fixture: \(fixtureURL.path)")
    }

    private func makeDocument(index: Int, payload: String) -> BenchmarkDocument {
        BenchmarkDocument(
            number: index,
            title: "Item \(index)",
            category: "segment-\(index % 20)",
            payload: payload,
            metadata: BenchmarkMetadata(
                source: "device-\(index % 5)",
                tags: ["tag-\(index % 10)", "batch"],
                details: BenchmarkDetails(
                    region: "region-\(index % 3)",
                    score: Double(index % 100) / 10,
                    flags: ["active": index.isMultiple(of: 2), "reviewed": index.isMultiple(of: 7)]
                )
            )
        )
    }
}
