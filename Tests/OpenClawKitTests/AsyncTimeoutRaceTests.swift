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

@Suite("AsyncTimeout race")
struct AsyncTimeoutRaceTests {
    @Test
    func operationThatIgnoresCancellationStillTimesOut() async {
        let start = ContinuousClock.now
        await #expect(throws: RaceTimeoutError.self) {
            try await AsyncTimeout.withTimeout(
                seconds: 0.05,
                onTimeout: { RaceTimeoutError() },
                operation: {
                    // A never-resumed continuation ignores cancellation entirely (the keepalive wedge).
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                })
        }
        #expect(ContinuousClock.now - start < .seconds(5))
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
