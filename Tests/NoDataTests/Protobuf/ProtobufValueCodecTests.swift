import Foundation
@testable import NoData
import Testing

struct ProtobufValueCodecTests {
    @Test func nestedValuesAndLargeIntegersRoundTrip() throws {
        let fields: [String: JSONValue] = [
            "details": .object([
                "items": .array([.null, .bool(false), .number(3.5), .string("a\nb")]),
                "signed": .integer(Int64.min),
                "unsigned": .unsignedInteger(UInt64.max),
                "empty": .object([:]),
            ]),
        ]
        let data = try ProtobufValueCodec.encode(fields)
        #expect(try ProtobufValueCodec.decode(data) == fields)
    }

    @Test func directlyEncodesNestedSwiftStructs() throws {
        let value = Note(
            title: "Direct", tags: ["swift", "local"],
            counters: ["views": Int64.max], unsignedCounters: ["likes": UInt64.max]
        )
        let fields = try ProtobufValueEncoder.encode(value)
        #expect(fields["title"] == .string("Direct"))
        #expect(fields["tags"] == .array([.string("swift"), .string("local")]))
        #expect(fields["counters"] == .object(["views": .integer(Int64.max)]))
        #expect(try ProtobufValueCodec.decode(ProtobufValueCodec.encode(fields)) == fields)
        #expect(try ProtobufValueDecoder.decode(Note.self, fields: fields) == value)
    }

    @Test func directlyDecodesNestedMetadataAndRawValues() throws {
        let value = BenchmarkDocument(
            number: 42, title: "Nested", category: "swift", payload: "data",
            metadata: BenchmarkMetadata(
                source: "device", tags: ["fast", "local"],
                details: BenchmarkDetails(region: "eu-west", score: 3.5, flags: ["active": false])
            )
        )
        let fields = try ProtobufValueEncoder.encode(value)
        #expect(try ProtobufValueDecoder.decode(BenchmarkDocument.self, fields: fields) == value)
        let raw: [String: JSONValue] = ["exact": .integer(Int64.max), "values": .array([.null, .bool(false)])]
        #expect(try ProtobufValueDecoder.decode([String: JSONValue].self, fields: raw) == raw)
    }

    @Test func bridgedAndDirectCodablePayloadsRemainReadable() throws {
        let note = Note(title: "Saved", tags: ["ios"], counters: [:], unsignedCounters: [:])
        let value = ProtobufCodecFixture(
            data: Data([0, 1, 254]), date: Date(timeIntervalSinceReferenceDate: 12345.5),
            note: note, absent: nil
        )
        let direct = try ProtobufValueCodec.encode(ProtobufValueEncoder.encode(value))
        #expect(try ProtobufValueCodec.decode(ProtobufCodecFixture.self, from: direct) == value)

        let bridgedFields = try JSONDecoder().decode(
            [String: JSONValue].self, from: JSONEncoder().encode(value)
        )
        let bridged = try ProtobufValueCodec.encode(bridgedFields)
        #expect(try ProtobufValueCodec.decode(ProtobufCodecFixture.self, from: bridged) == value)
    }
}
