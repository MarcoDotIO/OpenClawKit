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
