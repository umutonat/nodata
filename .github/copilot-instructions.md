# NoData workspace

- This is a Swift Package Manager library with separate JSON and SwiftProtobuf local NoSQL stores. Clients provide only Codable structs; the library owns all protobuf schemas and generated messages. Do not introduce SQLite, SQL, C runtime dependencies, or a backend into the local core.
- Support iOS, watchOS, and macOS minimum versions declared in Package.swift.
- Keep the persisted revisioned change format and delete tombstones suitable for a future transport-agnostic sync adapter. Do not assume local revisions are global versions.
- Keep each struct, enum, class, and actor in its own Swift source file.
- Put the public NoData facade at the source root, JSON internals under Sources/NoData/JSON, protobuf internals under Sources/NoData/Protobuf, shared infrastructure under Core, and generated messages under Generated.
- NoData<T>, NoDataEngine, NoDataChange, WriteReceipt, and NoDataError are the public API. Concrete JSON/protobuf stores and format-specific records stay internal.
- Keep one protobuf message per `.proto` schema file; generated `.pb.swift` sources are committed, and clients do not need `protoc` at runtime.
- Prefer focused Swift Testing cases in Tests/NoDataTests and run `swift test` after changes.
- Keep README.md user-facing: installation, API usage, behavior, limitations, and benchmark results. Put internal layout, generation, and contributor workflows in CONTRIBUTING.md.