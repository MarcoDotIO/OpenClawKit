import Foundation
import Testing
@testable import OpenClawKit

private struct RaceTimeoutError: Error, Equatable {}

private final class RaceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        self.lock.lock()
        self.value += 1
        self.lock.unlock()
    }

    var total: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}

/// An operation that ignores cancellation entirely (the keepalive wedge): it parks on a checked
/// continuation until the test itself calls `open()`.
private final class RaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            guard !self.isOpen else {
                self.lock.unlock()
                continuation.resume()
                return
            }
            self.waiter = continuation
            self.lock.unlock()
        }
    }

    func open() {
        self.lock.lock()
        self.isOpen = true
        let waiter = self.waiter
        self.waiter = nil
        self.lock.unlock()
        waiter?.resume()
    }
}

@Suite("AsyncTimeout race")
struct AsyncTimeoutRaceTests {
    /// Only the 50 ms deadline can end the race: the operation stays parked until the test opens its
    /// gate. A race that joined its loser would hang and trip the time limit, whose cancellation opens
    /// the gate so the test body can end. No wall-clock bound: a saturated test pool can stall the run
    /// for seconds.
    @Test(.timeLimit(.minutes(1)))
    func operationThatIgnoresCancellationStillTimesOut() async {
        let gate = RaceGate()
        defer { gate.open() }
        await withTaskCancellationHandler {
            await #expect(throws: RaceTimeoutError.self) {
                try await AsyncTimeout.withTimeout(
                    seconds: 0.05,
                    onTimeout: { RaceTimeoutError() },
                    operation: { await gate.wait() })
            }
        } onCancel: {
            gate.open()
        }
    }

    @Test
    func operationWinsBeforeTheDeadline() async throws {
        let value = try await AsyncTimeout.withTimeoutMs(
            timeoutMs: 5000,
            onTimeout: { RaceTimeoutError() },
            operation: { 42 })
        #expect(value == 42)
    }

    @Test
    func callerCancelledBeforeStartThrowsCancellation() async {
        let started = RaceCounter()
        let task = Task {
            // Enter the race only once this task is already cancelled.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
            }
            return try await AsyncTimeout.withTimeout(
                seconds: 5,
                onTimeout: { RaceTimeoutError() },
                operation: {
                    started.increment()
                    return 1
                })
        }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(started.total == 0)
    }

    @Test
    func zeroSecondsMeansNoDeadlineButCancellationStillResolves() async {
        let task = Task {
            try await AsyncTimeout.withTimeout(
                seconds: 0,
                onTimeout: { RaceTimeoutError() },
                operation: {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                })
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test
    func timeoutFactoryRunsOnlyForTheWinner() async throws {
        let factoryCalls = RaceCounter()
        let value = try await AsyncTimeout.withTimeout(
            seconds: 0.2,
            onTimeout: {
                factoryCalls.increment()
                return RaceTimeoutError()
            },
            operation: { "done" })
        #expect(value == "done")
        try await Task.sleep(for: .milliseconds(300))
        #expect(factoryCalls.total == 0)

        await #expect(throws: RaceTimeoutError.self) {
            try await AsyncTimeout.withTimeout(
                seconds: 0.01,
                onTimeout: {
                    factoryCalls.increment()
                    return RaceTimeoutError()
                },
                operation: {
                    try await Task.sleep(for: .seconds(5))
                    return "late"
                })
        }
        #expect(factoryCalls.total == 1)
    }

    @Test
    func cancellationShieldRunsCleanupForACancelledCaller() async throws {
        let recorded = RaceCounter()
        let task = Task {
            // Wait until the caller is cancelled, then run cleanup that checks cancellation.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
            }
            try await CancellationShieldSupport.run {
                try Task.checkCancellation()
                recorded.increment()
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        try await task.value
        #expect(recorded.total == 1)
    }
}
