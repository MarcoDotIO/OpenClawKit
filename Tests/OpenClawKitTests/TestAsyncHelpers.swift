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
/// that calls this carries a `.timeLimit`, whose cancellation ends the wait with
/// ``AsyncWaitTimeoutError``.
func waitUntil(
    _ label: String,
    pollMs: UInt64 = 10,
    _ condition: @escaping @Sendable () async -> Bool) async throws
{
    while !Task.isCancelled {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: pollMs * 1_000_000)
    }
    // Swift Testing drops errors thrown after a time-limit cancellation, so record which wait hung.
    let timeout = AsyncWaitTimeoutError(label: label)
    Issue.record(timeout)
    throw timeout
}
