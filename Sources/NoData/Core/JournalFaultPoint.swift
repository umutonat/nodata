enum JournalFaultPoint: Equatable, Sendable {
    case beforeWrite
    case beforeFileSync
    case beforeRename
    case beforeDirectorySync
}
