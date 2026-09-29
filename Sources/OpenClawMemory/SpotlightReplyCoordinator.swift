#if canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
import Foundation

/// Routes replies from one shared, unicast reply stream (for example the structured search replies of the FoundationModels Spotlight tool)
/// to one invocation at a time.
///
/// A single long-lived pump task consumes the stream for the lifetime of the tool instance: cancelling a
/// task that iterates a unicast `AsyncStream` finishes the stream for good, so invocations never iterate
/// it themselves. Invocations run one after another (``withExclusiveAccess(_:)``); each one opens a slot
/// before starting its call, and the first complete reply that arrives while the slot is open answers it.
/// Replies that arrive while no slot is open are dropped.
final class SpotlightReplyCoordinator<Reply: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let isComplete: @Sendable (Reply) -> Bool
    private let mutex = SpotlightAsyncMutex()
    private var pump: Task<Void, Never>?
    private var open = false
    private var completed: Reply?
    private var waiter: CheckedContinuation<Reply?, Never>?

    /// Creates a coordinator.
    /// - Parameter isComplete: Whether a reply is the final one of a call.
    init(isComplete: @escaping @Sendable (Reply) -> Bool) {
        self.isComplete = isComplete
    }

    deinit {
        self.pump?.cancel()
    }

    /// Starts the pump once; `body` iterates the shared stream and hands every reply to `deliver`.
    func ensurePump(_ body: @escaping @Sendable (_ deliver: @escaping @Sendable (Reply) -> Void) async -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.pump == nil else { return }
        let deliver: @Sendable (Reply) -> Void = { [weak self] reply in self?.deliver(reply) }
        self.pump = Task {
            await body(deliver)
        }
    }

    /// Runs `body` while no other invocation holds the coordinator (FIFO).
    func withExclusiveAccess<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await self.mutex.lock()
        do {
            let value = try await body()
            await self.mutex.unlock()
            return value
        } catch {
            await self.mutex.unlock()
            throw error
        }
    }

    /// Opens the reply slot for the current invocation (call before starting the underlying call).
    func openSlot() {
        self.lock.lock()
        self.open = true
        self.completed = nil
        let stale = self.waiter
        self.waiter = nil
        self.lock.unlock()
        stale?.resume(returning: nil)
    }

    /// Closes the slot; later replies are dropped until the next ``openSlot()``.
    func closeSlot() {
        self.lock.lock()
        self.open = false
        self.completed = nil
        let waiter = self.waiter
        self.waiter = nil
        self.lock.unlock()
        waiter?.resume(returning: nil)
    }

    /// Waits for the complete reply of the open slot.
    /// - Parameter timeoutSeconds: Deadline (see ``SpotlightTimeoutRace``).
    /// - Returns: The complete reply, or `nil` on timeout or when the slot closed.
    func completeReply(timeoutSeconds: Double) async -> Reply? {
        await SpotlightTimeoutRace.first(
            timeoutSeconds: timeoutSeconds,
            onTimeout: { [weak self] in self?.closeSlot() },
            operation: { [weak self] () -> Reply? in
                guard let self else { return nil }
                return await withCheckedContinuation { (continuation: CheckedContinuation<Reply?, Never>) in
                    self.install(continuation)
                }
            }
        )
    }

    private func install(_ continuation: CheckedContinuation<Reply?, Never>) {
        self.lock.lock()
        if let completed = self.completed {
            self.completed = nil
            self.lock.unlock()
            continuation.resume(returning: completed)
            return
        }
        guard self.open else {
            self.lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        let stale = self.waiter
        self.waiter = continuation
        self.lock.unlock()
        stale?.resume(returning: nil)
    }

    private func deliver(_ reply: Reply) {
        guard self.isComplete(reply) else { return }
        self.lock.lock()
        guard self.open else {
            self.lock.unlock()
            return
        }
        self.open = false
        if let waiter = self.waiter {
            self.waiter = nil
            self.lock.unlock()
            waiter.resume(returning: reply)
        } else {
            self.completed = reply
            self.lock.unlock()
        }
    }
}

/// FIFO async mutex (waiters resume in arrival order).
actor SpotlightAsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquires the mutex, suspending while another holder has it.
    func lock() async {
        guard self.locked else {
            self.locked = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.waiters.append(continuation)
        }
    }

    /// Releases the mutex to the next waiter.
    func unlock() {
        if self.waiters.isEmpty {
            self.locked = false
        } else {
            self.waiters.removeFirst().resume()
        }
    }
}
#endif
