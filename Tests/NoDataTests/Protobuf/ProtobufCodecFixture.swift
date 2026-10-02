import Foundation

struct ProtobufCodecFixture: Codable, Equatable, Sendable {
    let data: Data
    let date: Date
    let note: Note?
    let absent: String?
}
