import Foundation

public enum NoDataError: Error, Equatable, LocalizedError {
    case invalidIdentifier
    case invalidDocument
    case invalidCapacity
    case invalidPageSize
    case capacityExceeded
    case documentNotFound
    case documentAlreadyExists
    case duplicateIdentifier
    case incompatibleType
    case storeAlreadyOpen
    case backupAlreadyExists
    case durabilityUncertain
    case observerOverflow
    case historyPruned
    case unacknowledgedChanges
    case compactionBlocked
    case corruptLog
    case revisionExhausted

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "Document ID must not be empty."
        case .invalidDocument: "Document encoding or batch size is invalid."
        case .invalidCapacity: "Maximum live document count must be positive."
        case .invalidPageSize: "Change page size must be positive."
        case .capacityExceeded: "Maximum live document count reached."
        case .documentNotFound: "Document does not exist."
        case .documentAlreadyExists: "Document already exists."
        case .duplicateIdentifier: "Batch contains duplicate document IDs."
        case .incompatibleType: "Database file belongs to a different type or format."
        case .storeAlreadyOpen: "Database file is already open for writing."
        case .backupAlreadyExists: "Backup destination already exists."
        case .durabilityUncertain: "File replacement may have succeeded, but directory metadata was not synchronized."
        case .observerOverflow: "Observer fell behind; resume with changes(after:)."
        case .historyPruned: "Requested changes were pruned by compaction."
        case .unacknowledgedChanges: "Acknowledge the current revision before compacting."
        case .compactionBlocked: "Stop live observers before compacting their history."
        case .corruptLog: "Database log contains a corrupt record."
        case .revisionExhausted: "Database revision counter is exhausted."
        }
    }
}
