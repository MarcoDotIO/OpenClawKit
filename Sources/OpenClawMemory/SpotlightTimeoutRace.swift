#if canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
import Foundation

/// Non-joining timeout race for CoreSpotlight async sequences and completion-handler calls.
///
/// `withTaskGroup`-based timeouts wait for every child before returning, so a Spotlight stream that
/// ignores cancellation (for example `CSUserQuery.responses` stalling inside the system embedding
/// service) would still hang the caller after the timeout fires. This race resumes the caller with
/// whichever side finishes first and leaves the loser running unobserved; `onTimeout` lets callers
/// cancel the underlying query.
enum SpotlightTimeoutRace {
    /// Longest deadline honoured (one year); larger finite values are clamped to it.
    static let maxTimeoutSeconds: Double = 365 * 86_400
    /// Shortest deadline honoured.
    static let minTimeoutSeconds: Double = 0.05

    /// Deadline in nanoseconds, or `nil` for "no deadline" (`+infinity`).
    ///
    /// NaN and non-positive values use the 50 ms minimum; finite values above one year are clamped so
    /// the conversion to `UInt64` can never trap.
    static func deadlineNanoseconds(_ timeoutSeconds: Double) -> UInt64? {
        if timeoutSeconds == .infinity { return nil }
        let seconds = timeoutSeconds.isNaN ? self.minTimeoutSeconds : min(max(self.minTimeoutSeconds, timeoutSeconds), self.maxTimeoutSeconds)
        return UInt64(seconds * 1_000_000_000)
    }

    /// Runs `operation`, returning its value or `nil` once `timeoutSeconds` elapse.
    /// - Parameters:
    ///   - timeoutSeconds: Deadline in seconds (at least 50 ms, at most one year; `+infinity` waits
    ///     without a deadline).
    ///   - onTimeout: Called once when the deadline wins, before the caller resumes.
    ///   - operation: Work to race against the deadline.
    /// - Returns: The operation's value, or `nil` on timeout.
    static func first<T: Sendable>(
        timeoutSeconds: Double,
        onTimeout: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        guard let deadline = self.deadlineNanoseconds(timeoutSeconds) else {
            return await operation()
        }
        let gate = Gate<T?>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            gate.install(continuation)
            let work = Task {
                let value = await operation()
                gate.resume(with: value)
            }
            Task {
                try? await Task.sleep(nanoseconds: deadline)
                if gate.resume(with: nil) {
                    onTimeout()
                    work.cancel()
                }
            }
        }
    }

    /// Starts a completion-handler based CoreSpotlight call and waits for its completion or the deadline.
    ///
    /// `start` runs synchronously on the caller's isolation (so non-`Sendable` arguments such as
    /// `CSSearchableItem` never cross into another task) and must eventually call the completion it is
    /// given. A completion that arrives after the deadline is ignored.
    /// - Parameters:
    ///   - timeoutSeconds: Deadline in seconds (same clamping as ``first(timeoutSeconds:onTimeout:operation:)``).
    ///   - operation: Name used in the timeout error.
    ///   - start: Starts the call and hands its completion the resulting error, if any.
    /// - Throws: The call's error, or ``SpotlightTimeoutError`` when the deadline wins.
    static func completion(
        timeoutSeconds: Double,
        operation: String,
        _ start: (_ completion: @escaping @Sendable ((any Error)?) -> Void) -> Void
    ) async throws {
        let gate = Gate<Result<Void, any Error>>()
        let deadline = self.deadlineNanoseconds(timeoutSeconds)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, any Error>, Never>) in
            gate.install(continuation)
            start { error in
                gate.resume(with: error.map { .failure($0) } ?? .success(()))
            }
            if let deadline {
                Task {
                    try? await Task.sleep(nanoseconds: deadline)
                    gate.resume(with: .failure(SpotlightTimeoutError(operation: operation, seconds: timeoutSeconds)))
                }
            }
        }
        try result.get()
    }

    /// One-shot continuation guard shared by the operation and the deadline.
    private final class Gate<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?

        func install(_ continuation: CheckedContinuation<Value, Never>) {
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
        }

        /// Resumes the caller once; returns `true` for the side that won.
        @discardableResult
        func resume(with value: Value) -> Bool {
            self.lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            self.lock.unlock()
            continuation?.resume(returning: value)
            return continuation != nil
        }
    }
}

/// A CoreSpotlight index write or delete did not complete before its deadline (`corespotlightd` busy
/// or unavailable).
public struct SpotlightTimeoutError: Error, LocalizedError, Sendable, Equatable {
    /// Operation that timed out (for example `indexSearchableItems`).
    public let operation: String
    /// Deadline in seconds.
    public let seconds: Double

    /// Creates the error.
    /// - Parameters:
    ///   - operation: Operation name.
    ///   - seconds: Deadline in seconds.
    public init(operation: String, seconds: Double) {
        self.operation = operation
        self.seconds = seconds
    }

    /// Human-readable description.
    public var errorDescription: String? {
        "Spotlight \(self.operation) did not complete within \(self.seconds)s"
    }
}
#endif
