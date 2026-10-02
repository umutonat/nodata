# Contributing

NoData is one SwiftPM library target with two storage formats. Keep public types stable and put each hand-written struct, enum, class, or actor in its own file.

## Layout

- [Sources/NoData/NoData.swift](Sources/NoData/NoData.swift) is the user-facing facade; [Sources/NoData/NoDataEngine.swift](Sources/NoData/NoDataEngine.swift) selects the backend.
- [Sources/NoData/JSON/DocumentStore.swift](Sources/NoData/JSON/DocumentStore.swift) owns the JSON journal and JSON-specific update APIs.
- [Sources/NoData/Protobuf/ProtobufDocumentStore.swift](Sources/NoData/Protobuf/ProtobufDocumentStore.swift) owns the binary journal. Its Codable bridge lives under [Sources/NoData/Protobuf/Coding/ProtobufValueCodec.swift](Sources/NoData/Protobuf/Coding/ProtobufValueCodec.swift).
- [Sources/NoData/Core/ExclusiveFileLock.swift](Sources/NoData/Core/ExclusiveFileLock.swift) and the other Core files provide shared persistence infrastructure.
- Internal schemas are under [Protos/nodata_value.proto](Protos/nodata_value.proto) and generated Swift messages under [Sources/NoData/Generated/nodata_value.pb.swift](Sources/NoData/Generated/nodata_value.pb.swift). Clients never generate messages.
- Tests are grouped under [Tests/NoDataTests/JSON/NoDataTests.swift](Tests/NoDataTests/JSON/NoDataTests.swift), [Tests/NoDataTests/Protobuf/ProtobufCodableStoreTests.swift](Tests/NoDataTests/Protobuf/ProtobufCodableStoreTests.swift), and [Tests/NoDataTests/Performance/PerformanceTests.swift](Tests/NoDataTests/Performance/PerformanceTests.swift). The facade has its own [Tests/NoDataTests/NoDataFacadeTests.swift](Tests/NoDataTests/NoDataFacadeTests.swift).

## Build and test

```sh
swift test
swift build -c release --target NoData
swift build --target NoData --triple arm64-apple-ios16.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
swift build --target NoData --triple arm64-apple-watchos9.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)"
```

Format hand-written sources and tests with `swiftformat Sources/NoData Tests/NoDataTests`. The root `.swiftformat` configuration excludes generated protobuf code. Do not hand-edit generated files.

The million-document benchmarks are opt-in; commands and current measurements are in [README.md](README.md). Use small `NODATA_BENCHMARK_COUNT` values during development.

## Restart soak test

Run the opt-in worker from a new directory. Each `swift test` invocation is a separate process that reopens the previous cycle's database, exercises writes, updates, deletes, paged history, compaction, backup, and restore, then reports peak test-process RSS:

```sh
soak_dir="$PWD/.build/soak-$(uuidgen)"
for engine in json protobuf; do
	for cycle in $(seq 0 29); do
		NODATA_SOAK_DIRECTORY="$soak_dir" NODATA_SOAK_ENGINE="$engine" \
		NODATA_SOAK_CYCLE="$cycle" NODATA_SOAK_COUNT=500 \
		swift test --filter restartSoakCycle || break 2
	done
done
```

Cycles for each engine must start at zero and run in order; use a fresh `soak_dir` to repeat. `NODATA_SOAK_COUNT` must be at least 40. Compare RSS across cycles for growth; it includes the test runner and is not a measure of the store alone. The run checks restart behavior, not actual power-loss durability. Files remain under the ignored `.build` directory for inspection.

## Regenerate internal messages

The runtime SwiftProtobuf dependency is written in Swift. `protoc` is only a contributor build tool. When changing a `.proto` schema, rebuild the matching generator and regenerate committed Swift sources:

```sh
swift build --product protoc-gen-swift
protoc -I Protos --plugin=protoc-gen-swift="$(swift build --show-bin-path)/protoc-gen-swift" --swift_out=Sources/NoData/Generated Protos/nodata_record.proto Protos/nodata_batch.proto Protos/nodata_value.proto Protos/nodata_array.proto Protos/nodata_object.proto
```

Do not hand-edit generated `.pb.swift` files. Keep one top-level protobuf message per schema file. If the binary format changes, cover existing-file rejection or migration explicitly in tests and update the user-facing compatibility notes.

## Storage invariants

- Only one writable actor may own a file at a time. Both stores use a persistent sidecar advisory lock, append synchronized records, and replace journals via a synced temporary file plus atomic rename.
- Failed batch validation must not append a partial transaction. Revisions must remain ordered, and deletes must remain visible as tombstones to future sync adapters.
- Live observers publish only after a durable commit. Keep buffers bounded, signal `observerOverflow` rather than dropping events silently, and cancel upstream observation when a consumer terminates.
- Reopening must discard only incomplete trailing records, not silently accept malformed complete records. Maintain separate JSON and protobuf data files for each stored type.
- JSON records and protobuf frames carry CRC32 checksums. Keep checksum validation at every disk-read boundary; test parseable byte flips and incomplete tail recovery in both formats. Corrupt complete records require restoring a known-good offline backup, never silent truncation.
- Compaction requires acknowledgement through the current revision, stops while observers are active, snapshots live documents in bounded batches, and rejects replay requests older than the checkpoint. Do not discard unacknowledged tombstones or reset the revision counter.
- Backups copy a synchronized journal under the owning actor, validate it, and publish without replacing existing backups. Offline restore locks both paths and validates a temporary copy before replacing the destination. Reject a validation that trims an incomplete tail rather than restoring a silently shortened backup. A directory-sync failure after publishing or renaming must report `durabilityUncertain`; callers must not interpret it as rollback.
- Keep storage failure hooks scoped to the owning store instance. Fault tests must check both in-memory state and reopen: failed partial writes and file syncs leave no acknowledged change; pre-rename failures preserve the old journal; post-rename directory-sync failures leave the new journal visible but report `durabilityUncertain`.
- Keep public change pages bounded by a positive limit and resumable with the last delivered local revision. Leave `forEachChange(after:visit:)` streaming and preserve `historyPruned` for cursors below the checkpoint floor.
- `query(where:)` sorts live record locations, pins a file handle, and decodes independent batches with bounded Swift task groups. A worker receives only its batch bytes and live locations; preserve snapshot semantics across actor reentrancy and compaction. Do not add an index to this predicate API or claim sublinear search.