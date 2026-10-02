import Darwin
import Foundation

enum JournalBackup {
    static func create(from source: URL, to destination: URL, validate: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: destination.path) else { throw NoDataError.backupAlreadyExists }
        let pending = try JournalReplacement.prepare(for: destination)
        defer { try? fileManager.removeItem(atPath: pending.url.path + ".lock") }
        do {
            try copy(from: source, to: pending.handle)
            try pending.handle.synchronize()
            let copiedLength = try pending.handle.seekToEnd()
            try validate(pending.url)
            guard try pending.handle.seekToEnd() == copiedLength else { throw NoDataError.corruptLog }
            guard Darwin.link(pending.url.path, destination.path) == 0 else {
                if errno == EEXIST {
                    throw NoDataError.backupAlreadyExists
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            _ = Darwin.unlink(pending.url.path)
            do { try JournalReplacement.syncDirectory(at: destination) }
            catch { throw NoDataError.durabilityUncertain }
        } catch {
            JournalReplacement.discard(pending)
            throw error
        }
    }

    static func restore(from backup: URL, to destination: URL, validate: (URL) throws -> Void) throws {
        guard backup.standardizedFileURL != destination.standardizedFileURL else { throw NoDataError.invalidDocument }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destinationLock = try ExclusiveFileLock.acquire(for: destination)
        let backupLock = try ExclusiveFileLock.acquire(for: backup)
        let pending = try JournalReplacement.prepare(for: destination)
        defer { try? fileManager.removeItem(atPath: pending.url.path + ".lock") }
        do {
            try copy(from: backup, to: pending.handle)
            try pending.handle.synchronize()
            let copiedLength = try pending.handle.seekToEnd()
            try validate(pending.url)
            guard try pending.handle.seekToEnd() == copiedLength else { throw NoDataError.corruptLog }
            let restored = try JournalReplacement.commit(pending, replacing: destination)
            try? restored.handle.close()
            if !restored.directorySynced {
                throw NoDataError.durabilityUncertain
            }
        } catch {
            JournalReplacement.discard(pending)
            throw error
        }
        withExtendedLifetime(destinationLock) {}
        withExtendedLifetime(backupLock) {}
    }

    private static func copy(from source: URL, to destination: FileHandle) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try destination.write(contentsOf: chunk)
        }
    }
}
