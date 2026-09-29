import Foundation
import Testing
import OpenClawKit

@Suite("Background task submission")
struct BackgroundTaskSubmissionTests {
    private func schedulerError(_ code: Int) -> NSError {
        NSError(domain: OpenClawBackgroundTasks.schedulerErrorDomain, code: code)
    }

    /// Records submission attempts (true = queue strategy).
    final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        var all: [Bool] { self.lock.withLock { self.values } }
        func append(_ value: Bool) { self.lock.withLock { self.values.append(value) } }
    }

    @Test
    func classifiesSchedulerErrors() {
        typealias Failure = OpenClawBackgroundTasks.SubmissionFailure
        #expect(Failure(self.schedulerError(1)) == .unavailable)
        #expect(Failure(self.schedulerError(2)) == .tooManyPendingTaskRequests)
        #expect(Failure(self.schedulerError(3)) == .notPermitted)
        #expect(Failure(self.schedulerError(4)) == .immediateRunIneligible)
        #expect(Failure(self.schedulerError(9)) == .other(domain: OpenClawBackgroundTasks.schedulerErrorDomain, code: 9))
        #expect(Failure(NSError(domain: NSURLErrorDomain, code: -1)) == .other(domain: NSURLErrorDomain, code: -1))
        #expect(Failure.immediateRunIneligible.allowsQueueFallback)
        #expect(!Failure.notPermitted.allowsQueueFallback)
    }

    @Test
    func immediateRunIneligibleFallsBackToQueue() async {
        let attempts = Attempts()
        let error = await OpenClawBackgroundTasks.submitWithQueueFallback(preferImmediate: true) { useQueue in
            attempts.append(useQueue)
            return useQueue ? nil : self.schedulerError(4)
        }
        #expect(error == nil)
        #expect(attempts.all == [false, true])
    }

    @Test
    func nonRetryableErrorsAreSurfaced() async {
        let attempts = Attempts()
        let error = await OpenClawBackgroundTasks.submitWithQueueFallback(preferImmediate: true) { useQueue in
            attempts.append(useQueue)
            return self.schedulerError(3)
        }
        #expect((error as NSError?)?.code == 3)
        #expect(attempts.all == [false])
    }

    @Test
    func fallbackCanBeDisabledAndQueueStrategySubmitsOnce() async {
        let disabled = Attempts()
        let disabledError = await OpenClawBackgroundTasks.submitWithQueueFallback(
            preferImmediate: true,
            fallbackToQueue: false)
        { useQueue in
            disabled.append(useQueue)
            return self.schedulerError(4)
        }
        #expect((disabledError as NSError?)?.code == 4)
        #expect(disabled.all == [false])

        let queued = Attempts()
        let queuedError = await OpenClawBackgroundTasks.submitWithQueueFallback(preferImmediate: false) { useQueue in
            queued.append(useQueue)
            return nil
        }
        #expect(queuedError == nil)
        #expect(queued.all == [true])
    }
}
