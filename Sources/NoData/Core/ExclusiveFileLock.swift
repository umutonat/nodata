import Darwin
import Foundation

final class ExclusiveFileLock {
    private let handle: FileHandle

    private init(handle: FileHandle) throws {
        self.handle = handle
        if flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                throw NoDataError.storeAlreadyOpen
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    static func open(at url: URL) throws -> (handle: FileHandle, lock: ExclusiveFileLock) {
        let lock = try acquire(for: url)
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        return (handle, lock)
    }

    static func acquire(for url: URL) throws -> ExclusiveFileLock {
        let lockDescriptor = Darwin.open(url.path + ".lock", O_RDWR | O_CREAT, mode_t(S_IRUSR | S_IWUSR))
        guard lockDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try ExclusiveFileLock(handle: FileHandle(fileDescriptor: lockDescriptor, closeOnDealloc: true))
    }

    deinit {
        _ = flock(handle.fileDescriptor, LOCK_UN)
    }
}
