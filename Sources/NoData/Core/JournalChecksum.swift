import Foundation

enum JournalChecksum {
    private static let table: [UInt32] = (0 ..< 256).map { index in
        var value = UInt32(index)
        for _ in 0 ..< 8 {
            value = (value >> 1) ^ ((value & 1) == 0 ? 0 : 0xEDB8_8320)
        }
        return value
    }

    static func value(of data: Data) -> UInt32 {
        var checksum = UInt32.max
        for byte in data {
            checksum = table[Int((checksum ^ UInt32(byte)) & 0xFF)] ^ (checksum >> 8)
        }
        return ~checksum
    }

    static func jsonRecord(_ payload: Data) -> Data {
        var record = payload
        record.append(0x09)
        record.append(contentsOf: String(format: "%08x", value(of: payload)).utf8)
        record.append(0x0A)
        return record
    }

    static func jsonPayload(_ record: Data) throws -> Data {
        guard record.count >= 9, record[record.index(record.endIndex, offsetBy: -9)] == 0x09 else {
            throw NoDataError.corruptLog
        }
        let payload = Data(record.dropLast(9))
        guard let text = String(data: record.suffix(8), encoding: .ascii),
              let expected = UInt32(text, radix: 16), expected == value(of: payload)
        else {
            throw NoDataError.corruptLog
        }
        return payload
    }
}
