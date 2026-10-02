# NoData

NoData is a Swift-only local document database for iOS 16+, watchOS 9+, and macOS 13+. Define a `Codable & Sendable` struct, choose a storage engine, and use the same typed API on each platform. No SQL engine or backend is required.

## Add the package

Requires Swift 6.4+. In Xcode, add this directory as a local package dependency and link the `NoData` library. In another Swift package, add `.package(path: "../nodata")` to `dependencies` and `.product(name: "NoData", package: "nodata")` to your target's dependencies; adjust the relative path for your project.

## Quick start

```swift
import NoData

struct Note: Codable, Sendable {
    var title: String
    let tags: [String]
}

let store = try NoData<Note>(.json) // Or .protobuf
let note = Note(title: "Ideas", tags: ["swift"])
let receipt = try await store.put(note, id: "note-1")
let saved = try await store.get(id: "note-1")
let inserted = try await store.insert([(id: "note-2", value: Note(title: "More", tags: ["swift"]))])
let matches = try await store.query { $0.tags.contains("swift") }
let updated = try await store.update(id: "note-1") { $0.title = "Ready" }
let changes = try await store.changes(after: 0)
let removed = try await store.delete(ids: ["note-1", "note-2"])
```

`NoData<Note>()` defaults to `.json`. Pass `.protobuf` to use the binary store instead. These are separate databases, not synchronized copies of each other. Both accept plain Swift structs; you do not need `.proto` files, generated types, or a direct SwiftProtobuf import.

## Operations

| Method | Behavior |
| --- | --- |
| `put(_:id:)` | Upsert one document; returns its ID and local revision. |
| `insert(_:)` | Insert an array of `(id, value)` pairs; rejects existing or duplicate IDs. |
| `get(id:)`, `all()` | Fetch one document or all documents as typed values. Missing IDs return `nil`. |
| `query(where:)` | Decode a full scan in bounded parallel batches; return matching `(id, value)` pairs in ID order. |
| `forEach(where:visit:)` | Process matches without retaining a result array. |
| `update(id:mutate:)`, `update(ids:mutate:)` | Mutate one or several typed values; batch updates validate before writing. |
| `delete(id:)`, `delete(ids:)`, `deleteAll()` | Remove documents and return whether/how many were deleted. |
| `changes(after:limit:)`, `forEachChange(after:visit:)` | Read typed changes by local revision; `value == nil` means deleted. Pages default to 256 changes; the visitor streams without accumulating a page. |
| `observe()` | Receive committed typed changes as a live `AsyncThrowingStream`. |
| `observe(after:)` | Atomically replay up to 256 pending revisions, then continue with live changes. |
| `compact(through:)` | Replace acknowledged history with a snapshot of live documents. |
| `backup(to:)` | Copy and validate a committed snapshot without overwriting an existing backup. |
| `NoData<T>.restore(from:engine:at:)` | Validate and replace a closed database file from a backup. |

Revisions are local ordering markers, not globally unique sync versions. Backend synchronization is not implemented.

## Read change pages

`changes(after:limit:)` returns at most `limit` changes (256 by default). Save the last processed revision as your cursor and request the next page after it. A zero or negative limit throws `NoDataError.invalidPageSize`.

```swift
var cursor: UInt64 = 0
while true {
    let page = try await store.changes(after: cursor, limit: 128)
    guard !page.isEmpty else { break }
    for change in page {
        try await process(change)
        cursor = change.revision
    }
}
```

A page with fewer than `limit` entries is not a permanent end of the feed; more writes may arrive later. Individual documents and protobuf batches still have their own size limits, so paging bounds the number of returned changes, not total bytes or scan time. `forEachChange(after:visit:)` streams historical changes when retaining even one page is undesirable.

## Observe changes

Subscribe before making writes to receive live updates on either engine:

```swift
let stream = await store.observe()
let observation = Task {
    do {
        for try await change in stream {
            print(change.id, change.revision, change.value as Any)
        }
    } catch {
        print(error)
    }
}
```

Keep the task for as long as the view or service needs updates, then call `observation.cancel()`. `observe()` is live-only. To resume without a gap after revision `cursor`, use `try await store.observe(after: cursor)`: it replays pending events and registers live delivery in one actor operation. An observer buffers at most 256 events. If the backlog or consumer lag exceeds that limit, the stream throws `NoDataError.observerOverflow`; use `changes(after:limit:)` or `forEachChange(after:visit:)` to catch up, then subscribe again from the last handled revision. Writes can arrive during catch-up; handle another overflow and retry as needed. If history was compacted past the cursor, `NoDataError.historyPruned` means you must rebuild state from `all()`. Events are local writes committed by this store, not backend synchronization.

## Compact acknowledged history

Compaction keeps the current documents and next revision while dropping earlier change history. Only call it after you no longer need **all** changes through the current revision, for example after an external sync adapter has acknowledged them:

```swift
let latest = await store.currentRevision
try await store.compact(through: latest)
```

Compaction requires exactly the current revision and no active live observers. It atomically replaces the journal with a checksummed snapshot and records `oldestAvailableRevision`. Calls to `changes(after:)` or `observe(after:)` below that floor throw `historyPruned`. New JSON checkpoints record the stored type even when no documents remain; older checkpoints without any live records lack that type marker. Compaction does not bound the live-ID index, which still grows with the number of live documents.

## Back up and restore

`backup(to:)` runs on the store actor, synchronizes committed writes, copies the journal in bounded chunks, and validates the copy. Choose a new destination path; an existing file returns `NoDataError.backupAlreadyExists` and is never replaced. Keep backups somewhere separate from the live file and retain a known-good copy before risky maintenance.

```swift
let backupURL = archiveDirectory.appendingPathComponent("notes-backup.ndjson")
try await store.backup(to: backupURL)
```

To restore, release every store using the destination and backup files first, then call the static API **before** opening a replacement store. Restore validates a temporary copy against the requested engine and Swift type before replacing the destination; a corrupt or incomplete backup leaves the previous database intact. Unlike ordinary reopen, restore rejects backups that would need to discard an incomplete trailing write. Restoring an older backup rolls back subsequent writes. Keep the original backup for future recovery.

```swift
try NoData<Note>.restore(from: backupURL, engine: .json, at: databaseURL)
let restored = try NoData<Note>(.json, at: databaseURL)
```

Omit `at:` to restore to that type's default path. Match `engine:` to the backup's engine (the default is `.json`). A live writer on either path causes `NoDataError.storeAlreadyOpen`.

`NoDataError.durabilityUncertain` means a backup, restore, or compaction may already have completed its file replacement, but the parent directory could not be synchronized. Do not assume the operation rolled back or blindly retry it; inspect the resulting file and reopen it to determine the state. File and directory synchronization improve crash durability but cannot promise survival of every power loss or storage failure.

## Storage and limits

- Each Swift type gets an Application Support directory under `NoData/<encoded type>/`. JSON uses `store.ndjson`; protobuf uses `store.pbdb`. Pass `at: URL` to choose a file yourself. Renaming or moving a Swift type changes its storage identity, even with an explicit file URL. Plan a caller-managed migration while the old type remains available: read its documents and write the new type into a separate store. Backup/restore does not rename a stored type.
- Writes are actor-serialized and synchronized to disk. Opening a second writer for the same file throws `NoDataError.storeAlreadyOpen`; external programs that ignore advisory locks are not supported.
- Document bodies load on demand, while an index of live IDs and recently decoded batches remain in memory. Opening replays the append-only log. Predicate queries decode independent batches in parallel (up to four workers on macOS/iOS, one on watchOS) but still scan every live document; there are no secondary indexes. `forEach(where:visit:)` remains a single-worker streaming scan. Acknowledged history can be compacted as described above.
- To bound the live-ID index on memory-constrained devices, pass `maximumLiveDocuments:` when creating `NoData<T>`. It must be positive, and the limit is enforced on both writes and reopen, including compacted snapshots. The default is unlimited; a limit does not bound payload size or the result returned by `all()`.
- Deletes leave revisioned tombstones. Protobuf `deleteAll()` may commit multiple bounded batches, so an I/O failure can leave a partial deletion; calling it again safely finishes the remainder. Each protobuf batch is limited to 16 MiB.
- Each committed JSON record and protobuf frame includes a CRC32 checksum. Reopening discards an incomplete trailing write; a complete record with a bad checksum throws `NoDataError.corruptLog` rather than returning altered data. To recover, close every store using that file and restore a known-good backup at the same path. Do not remove a corrupt record by hand: later revisions and tombstones may depend on it. CRC32 detects accidental corruption, not malicious tampering.

## License

NoData is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).

## Performance benchmark

The performance test is opt-in; ordinary `swift test` runs stay quick. Run a small smoke test or the full 1,000,000-document test from the package root:

```sh
NODATA_PERFORMANCE_TEST=1 NODATA_BENCHMARK_COUNT=1000 swift test --filter millionDocumentBenchmark
NODATA_PERFORMANCE_TEST=1 swift test -c release --filter millionDocumentBenchmark
NODATA_PROTOBUF_PERFORMANCE_TEST=1 NODATA_BENCHMARK_COUNT=1000 swift test --filter millionProtobufDocuments
NODATA_PROTOBUF_PERFORMANCE_TEST=1 swift test -c release --filter millionProtobufDocuments
NODATA_QUERY_STORE="$PWD/.build/performance/<run-id>/store.ndjson" swift test -c release --filter existingStoreQueryBenchmark
```

The benchmarks exercise the concrete stores directly, not the `NoData<T>` wrapper. JSON runs write a valid JSON array to `.build/performance/<run-id>/documents.json` and a `store.ndjson` database file; protobuf runs write `store.pbdb` under their own run directory. Both use the same deterministic `BenchmarkDocument` with nested `BenchmarkMetadata` and `BenchmarkDetails` structs, inserting in batches of 2,000. JSON fixture generation is timed separately from database insertion. Both runs report 1,000 point reads, a full predicate query through nested details, 1,000 field updates, 1,000 deletions, and reopening. The query-only command reuses a previously generated JSON database. Results are hardware- and build-configuration-dependent, with no time-based pass/fail threshold.

### One million documents (release mode, checksummed records)

Measured on October 2, 2026 with Apple Swift 6.4 on the same Apple Silicon machine. Each column is one run, rounded as shown; the values are not performance guarantees.

| Operation | JSON store | Protobuf store |
| --- | ---: | ---: |
| Batch insert (s) | 10.46 | 9.55 |
| 1,000 point reads (s) | 0.119 | 0.014 |
| Nested-field query (s) | 4.23 | 5.90 |
| 1,000 updates (s) | 0.028 | 0.022 |
| 1,000 deletes (s) | 0.00134 | 0.00041 |
| Reopen (s) | 5.44 | 1.31 |
| Database log (MB) | 435.7 | 400.7 |

Both runs used the same nested `BenchmarkDocument` with the default, unlimited live-document count. The JSON run also generated a separate 347 MB fixture in 5.93s; fixture generation is excluded. Compaction is not included in these timings. Parallel decoding speeds full predicate scans, but queries still inspect every live document. Protobuf reopens and reads faster; JSON completed this particular scan faster. Run artifacts are ignored by Git under `.build/performance/<run-id>`; remove old runs when no longer needed.