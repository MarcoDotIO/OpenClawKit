import Foundation

/// One timeout race between an operation and an optional deadline.
///
/// The racers are unstructured tasks so the winner never has to join a loser that ignores
/// cancellation (for example a URLSession ping whose pong handler never fires). A task group
/// would wait for every child before returning, which is the keepalive wedge upstream fixed.
///
/// State is guarded by an `NSLock` rather than `Synchronization.Mutex`, which needs
/// iOS 18/macOS 15/tvOS 18/watchOS 11 and is above this package's deployment floors.
private final class AsyncTimeoutRace<T: Sendable>: @unchecked Sendable {
    private enum State {
        case pending
        case cancelledBeforeStart
        case running(CheckedContinuation<T, any Error>, [Task<Void, Never>])
        case resolved([Task<Void, Never>])
    }

    private let lock = NSLock()
    private var state = State.pending

    private func withLock<R>(_ body: (inout State) -> R) -> R {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body(&self.state)
    }

    func wait<C: Clock>(
        seconds: Double,
        clock: C,
        onTimeout: @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
        where C.Duration == Duration
    {
        try await withCheckedThrowingContinuation { continuation in
            let cancelled = self.withLock { state -> Bool in
                switch state {
                case .cancelledBeforeStart:
                    return true
                case .running, .resolved:
                    // A race has exactly one waiter; a second wait is a programming error.
                    // Fail the late waiter instead of trapping inside SDK code.
                    return true
                case .pending:
                    // Admission and handle installation share cancellation's lock.
                    // A cancelled caller cannot leave an unregistered operation running.
                    let operationTask = Task {
                        do {
                            let value = try await operation()
                            self.resolve(.success(value))
                        } catch {
                            self.resolveFailure(error)
                        }
                    }
                    var tasks = [operationTask]
                    if seconds > 0 {
                        tasks.append(Task {
                            do {
                                try await clock.sleep(for: .seconds(seconds))
                                self.resolveFailure(onTimeout())
                            } catch is CancellationError {
                                // The operation or caller resolved the race first.
                            } catch {
                                self.resolveFailure(error)
                            }
                        })
                    }
                    state = .running(continuation, tasks)
                    return false
                }
            }
            if cancelled {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func resolveFailure(_ error: @autoclosure () -> any Error) {
        self.resolve(.failure(error()))
    }

    private func resolve(_ outcome: @autoclosure () -> Result<T, any Error>) {
        let (continuation, tasks): (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) =
            self.withLock { state in
                switch state {
                case .pending:
                    // Only caller cancellation can precede atomic racer installation.
                    state = .cancelledBeforeStart
                    return (nil, [])
                case .cancelledBeforeStart:
                    return (nil, [])
                case let .running(continuation, tasks):
                    state = .resolved(tasks)
                    return (continuation, tasks)
                case let .resolved(tasks):
                    return (nil, tasks)
                }
            }
        guard !tasks.isEmpty else { return }
        // Handlers may reenter the race. Keep handles visible until cancellation is applied,
        // but cancel and resume outside the lock to avoid lock inversion with the runtime.
        tasks.forEach { $0.cancel() }
        self.withLock { $0 = .resolved([]) }
        if let continuation {
            // Only the winner consumes its factory; it may log or call back into a caller.
            continuation.resume(with: outcome())
        }
    }
}

/// Async timeout helpers shared by gateway, media, and command flows.
///
/// The operation and the deadline race as unstructured tasks: the caller resumes as soon as
/// either side wins, even when the losing operation ignores cancellation. Caller cancellation
/// resolves the race immediately with `CancellationError`. Callers still own cleanup of any
/// work the losing operation keeps doing and must treat its late results as stale.
public enum AsyncTimeout {
    /// Runs an async operation with a timeout expressed in seconds.
    ///
    /// - Parameters:
    ///   - seconds: Deadline in seconds. Zero or negative means no deadline; caller
    ///     cancellation still resolves the race with `CancellationError`.
    ///   - onTimeout: Builds the error thrown when the deadline wins.
    ///   - operation: Work to run.
    /// - Returns: The operation's value when it finishes before the deadline.
    public static func withTimeout<T: Sendable>(
        seconds: Double,
        onTimeout: @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await self.withTimeout(
            seconds: seconds,
            clock: ContinuousClock(),
            onTimeout: onTimeout,
            operation: operation)
    }

    /// Runs an async operation with a timeout measured on a caller-supplied clock.
    ///
    /// Use this overload with a test clock for deterministic deadline tests.
    /// - Parameters:
    ///   - seconds: Deadline in seconds. Zero or negative means no deadline.
    ///   - clock: Clock whose `sleep(for:)` measures the deadline.
    ///   - onTimeout: Builds the error thrown when the deadline wins.
    ///   - operation: Work to run.
    /// - Returns: The operation's value when it finishes before the deadline.
    public static func withTimeout<T: Sendable, C: Clock>(
        seconds: Double,
        clock: C,
        onTimeout: @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
        where C.Duration == Duration
    {
        // Unstructured racers avoid joining a cancellation-ignoring loser. Cancellation
        // marks every racer synchronously; callers still own cleanup and stale-result safety.
        let race = AsyncTimeoutRace<T>()
        let boundedSeconds = seconds.isFinite ? max(0, seconds) : 0
        return try await withTaskCancellationHandler {
            try await race.wait(
                seconds: boundedSeconds,
                clock: clock,
                onTimeout: onTimeout,
                operation: operation)
        } onCancel: {
            race.resolveFailure(CancellationError())
        }
    }

    /// Runs an async operation with a timeout expressed in milliseconds.
    ///
    /// - Parameters:
    ///   - timeoutMs: Deadline in milliseconds; zero or negative means no deadline.
    ///   - onTimeout: Builds the error thrown when the deadline wins.
    ///   - operation: Work to run.
    /// - Returns: The operation's value when it finishes before the deadline.
    public static func withTimeoutMs<T: Sendable>(
        timeoutMs: Int,
        onTimeout: @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        let clamped = max(0, timeoutMs)
        let seconds = Double(clamped) / 1000.0
        return try await self.withTimeout(seconds: seconds, onTimeout: onTimeout, operation: operation)
    }
}
