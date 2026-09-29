import Foundation

/// Non-joining timeout race used by ``MCPClient``.
///
/// A `withThrowingTaskGroup` timeout waits for every child before returning, so an operation that
/// ignores cancellation (for example a legacy SSE handshake that never receives its `endpoint` event)
/// would keep the caller waiting after the deadline. This race resumes the caller with whichever side
/// finishes first, cancels the loser, and does not wait for it.
enum MCPTimeoutRace {
    /// Longest wait honoured (Int32.max milliseconds, about 24.8 days), so the conversion to
    /// nanoseconds can never overflow.
    static let maxMilliseconds = Int(Int32.max)

    /// Nanoseconds for a millisecond timeout, clamped to `1...maxMilliseconds`.
    static func nanoseconds(milliseconds: Int) -> UInt64 {
        UInt64(min(max(1, milliseconds), self.maxMilliseconds)) * 1_000_000
    }

    /// Runs `operation`, throwing ``MCPTransportError/timeout(method:milliseconds:)`` once the deadline
    /// passes (without waiting for the operation to notice its cancellation).
    /// - Parameters:
    ///   - milliseconds: Deadline.
    ///   - method: Method name reported in the timeout error.
    ///   - operation: Work to run.
    static func run(milliseconds: Int, method: String, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        let gate = Gate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard gate.install(continuation) else { return }
                let work = Task {
                    do {
                        try await operation()
                        gate.resume(with: .success(()))
                    } catch {
                        gate.resume(with: .failure(error))
                    }
                }
                gate.setWork(work)
                Task {
                    try? await Task.sleep(nanoseconds: self.nanoseconds(milliseconds: milliseconds))
                    if gate.resume(with: .failure(MCPTransportError.timeout(method: method, milliseconds: milliseconds))) {
                        work.cancel()
                    }
                }
            }
        } onCancel: {
            if gate.resume(with: .failure(CancellationError())) {
                gate.cancelWork()
            }
        }
    }

    /// One-shot continuation guard shared by the operation, the deadline and caller cancellation.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var early: Result<Void, Error>?
        private var done = false
        private var work: Task<Void, Never>?

        /// Installs the caller's continuation; returns `false` (after resuming it) when the race was
        /// already decided, for example by an early cancellation.
        func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
            self.lock.lock()
            if self.done, let early = self.early {
                self.early = nil
                self.lock.unlock()
                continuation.resume(with: early)
                return false
            }
            self.continuation = continuation
            self.lock.unlock()
            return true
        }

        func setWork(_ work: Task<Void, Never>) {
            self.lock.lock()
            self.work = work
            self.lock.unlock()
        }

        func cancelWork() {
            self.lock.lock()
            let work = self.work
            self.lock.unlock()
            work?.cancel()
        }

        /// Resumes the caller once (remembering a result that arrives before the continuation is
        /// installed, for example an early cancellation); returns `true` for the side that won.
        @discardableResult
        func resume(with result: Result<Void, Error>) -> Bool {
            self.lock.lock()
            guard !self.done else {
                self.lock.unlock()
                return false
            }
            self.done = true
            guard let continuation = self.continuation else {
                self.early = result
                self.lock.unlock()
                return true
            }
            self.continuation = nil
            self.lock.unlock()
            continuation.resume(with: result)
            return true
        }
    }
}
