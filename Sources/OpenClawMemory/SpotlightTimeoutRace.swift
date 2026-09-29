#if canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
import Foundation

/// Non-joining timeout race for CoreSpotlight async sequences.
///
/// `withTaskGroup`-based timeouts wait for every child before returning, so a Spotlight stream that
/// ignores cancellation (for example `CSUserQuery.responses` stalling inside the system embedding
/// service) would still hang the caller after the timeout fires. This race resumes the caller with
/// whichever side finishes first and leaves the loser running unobserved; `onTimeout` lets callers
/// cancel the underlying query.
enum SpotlightTimeoutRace {
    /// Runs `operation`, returning its value or `nil` once `timeoutSeconds` elapse.
    /// - Parameters:
    ///   - timeoutSeconds: Deadline in seconds (clamped to at least 50 ms).
    ///   - onTimeout: Called once when the deadline wins, before the caller resumes.
    ///   - operation: Work to race against the deadline.
    /// - Returns: The operation's value, or `nil` on timeout.
    static func first<T: Sendable>(
        timeoutSeconds: Double,
        onTimeout: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        let gate = Gate<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            gate.install(continuation)
            let work = Task {
                let value = await operation()
                gate.resume(with: value)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, timeoutSeconds) * 1_000_000_000))
                if gate.resume(with: nil) {
                    onTimeout()
                    work.cancel()
                }
            }
        }
    }

    /// One-shot continuation guard shared by the operation and the deadline.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?

        func install(_ continuation: CheckedContinuation<T?, Never>) {
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
        }

        /// Resumes the caller once; returns `true` for the side that won.
        @discardableResult
        func resume(with value: T?) -> Bool {
            self.lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            self.lock.unlock()
            continuation?.resume(returning: value)
            return continuation != nil
        }
    }
}
#endif
