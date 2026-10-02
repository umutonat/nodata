import Foundation

final class ChangeObservers<Element: Sendable>: @unchecked Sendable {
    static var capacity: Int {
        256
    }

    private let lock = NSLock()
    private var continuations: [UUID: AsyncThrowingStream<Element, Error>.Continuation] = [:]

    var hasSubscribers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !continuations.isEmpty
    }

    func stream(replaying history: [Element] = []) -> AsyncThrowingStream<Element, Error> {
        let id = UUID()
        let pair = AsyncThrowingStream<Element, Error>.makeStream(bufferingPolicy: .bufferingOldest(Self.capacity))
        for change in history {
            _ = pair.continuation.yield(change)
        }
        pair.continuation.onTermination = { [weak self] _ in self?.remove(id) }
        lock.lock()
        continuations[id] = pair.continuation
        lock.unlock()
        return pair.stream
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }

    func publish(_ elements: [Element]) {
        lock.lock()
        var active = continuations
        lock.unlock()
        for element in elements {
            var terminated: [UUID] = []
            for (id, continuation) in active {
                switch continuation.yield(element) {
                case .enqueued:
                    break
                case .dropped:
                    continuation.finish(throwing: NoDataError.observerOverflow)
                    terminated.append(id)
                case .terminated:
                    terminated.append(id)
                @unknown default:
                    continuation.finish(throwing: NoDataError.observerOverflow)
                    terminated.append(id)
                }
            }
            for id in terminated {
                active[id] = nil
                remove(id)
            }
        }
    }
}
