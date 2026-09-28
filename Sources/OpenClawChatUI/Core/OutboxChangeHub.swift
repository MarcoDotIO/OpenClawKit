import Foundation

/// Fan-out hub for outbox change notifications shared by every store facade over one database.
package final class OutboxChangeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<OpenClawChatOutboxChange>.Continuation] = [:]

    /// Creates an empty hub.
    package init() {}

    /// Returns a new subscriber stream.
    package func stream() -> AsyncStream<OpenClawChatOutboxChange> {
        let id = UUID()
        let pair = AsyncStream<OpenClawChatOutboxChange>.makeStream()
        self.lock.lock()
        self.continuations[id] = pair.continuation
        self.lock.unlock()
        pair.continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return pair.stream
    }

    /// Delivers a change to every subscriber.
    package func yield(_ change: OpenClawChatOutboxChange) {
        self.lock.lock()
        let continuations = Array(self.continuations.values)
        self.lock.unlock()
        for continuation in continuations {
            continuation.yield(change)
        }
    }

    /// Finishes every subscriber stream.
    package func finish() {
        self.lock.lock()
        let continuations = Array(self.continuations.values)
        self.continuations.removeAll()
        self.lock.unlock()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        self.lock.lock()
        self.continuations.removeValue(forKey: id)
        self.lock.unlock()
    }
}
