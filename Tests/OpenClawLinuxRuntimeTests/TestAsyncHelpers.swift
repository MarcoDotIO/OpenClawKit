import Testing

struct AsyncWaitTimeoutError: Error, CustomStringConvertible {
    let label: String
    var description: String {
        "Timeout waiting for: \(self.label)"
    }
}

/// Polls `condition` until it holds.
///
/// There is no wall-clock deadline: a saturated test pool must only slow the wait down. Every suite
/// or test that calls this carries a `.timeLimit`, whose cancellation ends the wait with
/// ``AsyncWaitTimeoutError``.
func waitUntil(
    _ label: String,
    pollMs: UInt64 = 10,
    _ condition: @Sendable () async -> Bool) async throws
{
    while !Task.isCancelled {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: pollMs * 1_000_000)
    }
    throw recordedWaitTimeout(label)
}

/// Records which wait hung and returns the error to throw. Swift Testing drops errors thrown after a
/// time-limit cancellation, so the recorded issue is what names the wait.
func recordedWaitTimeout(_ label: String) -> AsyncWaitTimeoutError {
    let timeout = AsyncWaitTimeoutError(label: label)
    Issue.record(timeout)
    return timeout
}

/// Awaits `operation` in its own task, so a time-limit cancellation ends the wait even when the
/// operation ignores cancellation.
///
/// Product waits such as `EmbeddedAgentRuntime.wait(runID:)`, the gateway's `agent.wait` and the
/// approval and question brokers park on a continuation that only their own timer or the awaited
/// event resumes. Wrapping them here lets a test wait without a timeout: a regression shows up as a
/// hang, and the time limit turns it into an ``AsyncWaitTimeoutError`` naming `label`.
func awaitCancellable<T: Sendable>(_ label: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let (results, continuation) = AsyncStream<Result<T, any Error>>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let task = Task {
        do {
            continuation.yield(.success(try await operation()))
        } catch {
            continuation.yield(.failure(error))
        }
        continuation.finish()
    }
    defer { task.cancel() }
    for await result in results {
        return try result.get()
    }
    throw recordedWaitTimeout(label)
}
