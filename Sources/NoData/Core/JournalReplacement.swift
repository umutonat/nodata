import Darwin
import Foundation

enum JournalReplacement {
    static func prepare(for url: URL) throws -> (url: URL, handle: FileHandle) {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_RDWR | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return (temporary, FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }

    static func commit(
        _ pending: (url: URL, handle: FileHandle), replacing url: URL,
        failure: (@Sendable (JournalFaultPoint) throws -> Void)? = nil
    ) throws -> JournalCommit {
        try pending.handle.synchronize()
        _ = try pending.handle.seekToEnd()
        try failure?(.beforeRename)
        guard Darwin.rename(pending.url.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directorySynced: Bool
        do {
            try failure?(.beforeDirectorySync)
            try syncDirectory(at: url)
            directorySynced = true
        } catch {
            directorySynced = false
        }
        return JournalCommit(handle: pending.handle, directorySynced: directorySynced)
    }

    static func syncDirectory(at url: URL) throws {
        let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(directory) }
        let result = Darwin.fsync(directory)
        let code = errno
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }

    static func discard(_ pending: (url: URL, handle: FileHandle)) {
        try? pending.handle.close()
        try? FileManager.default.removeItem(at: pending.url)
    }
}
