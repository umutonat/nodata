import Foundation
@testable import NoData
import Testing

struct ProtobufPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NODATA_PROTOBUF_PERFORMANCE_TEST"] == "1"))
    func millionProtobufDocuments() async throws {
        let fileManager = FileManager.default
        let documentCount = Int(ProcessInfo.processInfo.environment["NODATA_BENCHMARK_COUNT"] ?? "") ?? 1_000_000
        #expect(documentCount > 0)
        guard documentCount > 0 else { return }

        let outputDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".build/performance", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = outputDirectory.appendingPathComponent("store.pbdb")
        let payload = String(repeating: "x", count: 128)
        let batchSize = 2000
        let sampleCount = min(1000, documentCount)
        let sampleIDs = (0 ..< sampleCount).map(String.init)
        let clock = ContinuousClock()
        let insertDuration: Duration
        let readDuration: Duration
        let queryDuration: Duration
        let updateDuration: Duration
        let deleteDuration: Duration

        do {
            let store = try ProtobufDocumentStore<BenchmarkDocument>(at: storeURL)
            let insertStart = clock.now
            for start in stride(from: 0, to: documentCount, by: batchSize) {
                let entries = (start ..< min(start + batchSize, documentCount)).map { index in
                    (id: String(index), value: makeMessage(index: index, payload: payload))
                }
                _ = try await store.insert(entries)
            }
            insertDuration = insertStart.duration(to: clock.now)

            let readStart = clock.now
            for id in sampleIDs {
                let message = try await store.get(id: id)
                #expect(message != nil)
            }
            readDuration = readStart.duration(to: clock.now)

            let queryStart = clock.now
            let matches = try await store.query {
                $0.category == "segment-0" && $0.metadata.details.region == "region-0"
            }
            queryDuration = queryStart.duration(to: clock.now)
            #expect(matches.count == (documentCount + 59) / 60)

            let updateStart = clock.now
            let updated = try await store.update(ids: sampleIDs) { $0.category = "updated" }
            updateDuration = updateStart.duration(to: clock.now)
            #expect(updated.count == sampleCount)

            let deleteStart = clock.now
            let deleted = try await store.delete(ids: sampleIDs)
            deleteDuration = deleteStart.duration(to: clock.now)
            #expect(deleted == sampleCount)
        }

        let reopenStart = clock.now
        let reopened = try ProtobufDocumentStore<BenchmarkDocument>(at: storeURL)
        let reopenDuration = reopenStart.duration(to: clock.now)
        let remaining = await reopened.count
        #expect(remaining == documentCount - sampleCount)
        if sampleCount < documentCount {
            let survivor = try await reopened.get(id: String(sampleCount))
            #expect(survivor == makeMessage(index: sampleCount, payload: payload))
        }

        let logSize = try (fileManager.attributesOfItem(atPath: storeURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        print("NoData protobuf benchmark: \(documentCount) documents, binary log \(logSize) bytes")
        print("Batch insert: \(insertDuration); 1K reads: \(readDuration); query: \(queryDuration)")
        print("1K updates: \(updateDuration); 1K deletes: \(deleteDuration); reopen: \(reopenDuration)")
        print("Protobuf store: \(storeURL.path)")
    }

    private func makeMessage(index: Int, payload: String) -> BenchmarkDocument {
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
