import Foundation

struct ChangeHeader: Decodable {
    let revision: UInt64
    let collection: String
    let id: String
    let isDelete: Bool

    private enum CodingKeys: String, CodingKey {
        case revision
        case collection
        case id
        case fields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(UInt64.self, forKey: .revision)
        collection = try container.decode(String.self, forKey: .collection)
        id = try container.decode(String.self, forKey: .id)
        if container.contains(.fields) {
            isDelete = try container.decodeNil(forKey: .fields)
            if !isDelete {
                let fieldDecoder = try container.superDecoder(forKey: .fields)
                _ = try fieldDecoder.container(keyedBy: CodingKeys.self)
            }
        } else {
            isDelete = true
        }
    }
}
