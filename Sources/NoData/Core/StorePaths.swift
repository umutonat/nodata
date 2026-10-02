import Foundation

enum StorePaths {
    static func defaultURL(for type: (some Any).Type, fileName: String) -> URL {
        let typeDirectory = Data(String(reflecting: type).utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoData", isDirectory: true)
            .appendingPathComponent(typeDirectory, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
