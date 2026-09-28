import Foundation
#if canImport(BackgroundTasks) && (os(iOS) || os(tvOS))
import BackgroundTasks
#endif

/// Background-task submission helpers that surface every scheduler error.
///
/// On iOS/tvOS 27 submission goes through the async `BGTaskScheduler.submitTaskRequest(_:)`, which
/// reports errors the deprecated synchronous `submit(_:)` could not (for example
/// ``SubmissionFailure/immediateRunIneligible``). Earlier systems use `submit(_:)`. Either way the
/// error is returned instead of being dropped with `try?`, so hosts can log it or show it in a
/// diagnostics view.
///
/// Call the submission helpers from a background context: they are `nonisolated async` and the
/// scheduler documents that submission must not run on the main thread.
public enum OpenClawBackgroundTasks {
    /// `BGTaskSchedulerErrorDomain`.
    public static let schedulerErrorDomain = "BGTaskSchedulerErrorDomain"

    /// Classified background-task submission failure.
    public enum SubmissionFailure: Sendable, Equatable {
        /// Background work is unavailable (refresh disabled, Simulator, unsupported extension).
        case unavailable
        /// Too many pending requests of this type.
        case tooManyPendingTaskRequests
        /// Identifier not permitted, unsupported resources, or background launches denied.
        case notPermitted
        /// A continued-processing request with the `fail` strategy could not start immediately.
        case immediateRunIneligible
        /// Any other error.
        case other(domain: String, code: Int)

        /// Classifies an error returned by the scheduler.
        /// - Parameter error: Submission error.
        public init(_ error: any Error) {
            let nsError = error as NSError
            guard nsError.domain == OpenClawBackgroundTasks.schedulerErrorDomain else {
                self = .other(domain: nsError.domain, code: nsError.code)
                return
            }
            switch nsError.code {
            case 1: self = .unavailable
            case 2: self = .tooManyPendingTaskRequests
            case 3: self = .notPermitted
            case 4: self = .immediateRunIneligible
            default: self = .other(domain: nsError.domain, code: nsError.code)
            }
        }

        /// Whether retrying with the `queue` strategy may succeed.
        public var allowsQueueFallback: Bool {
            switch self {
            case .immediateRunIneligible, .tooManyPendingTaskRequests:
                return true
            case .unavailable, .notPermitted, .other:
                return false
            }
        }
    }

    /// Runs a continued-processing submission with a `queue` fallback.
    ///
    /// Submits with the `fail` strategy first when `preferImmediate` is true. When that fails with
    /// ``SubmissionFailure/immediateRunIneligible`` (or too many pending requests) and
    /// `fallbackToQueue` is true, resubmits with the `queue` strategy.
    /// - Parameters:
    ///   - preferImmediate: Whether the first attempt uses the `fail` strategy.
    ///   - fallbackToQueue: Whether to resubmit with the `queue` strategy after an eligible failure.
    ///   - submit: Performs one submission; the argument is `true` for the `queue` strategy.
    /// - Returns: The final error, or `nil` on success.
    public static func submitWithQueueFallback(
        preferImmediate: Bool,
        fallbackToQueue: Bool = true,
        submit: (_ useQueueStrategy: Bool) async -> (any Error)?) async -> (any Error)?
    {
        guard preferImmediate else {
            return await submit(true)
        }
        guard let error = await submit(false) else {
            return nil
        }
        guard fallbackToQueue, SubmissionFailure(error).allowsQueueFallback else {
            return error
        }
        return await submit(true)
    }

    #if canImport(BackgroundTasks) && (os(iOS) || os(tvOS))
    /// Submits a background task request and returns any error.
    /// - Parameters:
    ///   - request: Refresh, processing, or continued-processing request.
    ///   - scheduler: Scheduler to submit to.
    /// - Returns: The submission error, or `nil` on success.
    public static func submit(_ request: BGTaskRequest, scheduler: BGTaskScheduler = .shared) async -> (any Error)? {
        #if compiler(>=6.4)
        if #available(iOS 27.0, tvOS 27.0, *) {
            do {
                try await scheduler.submitTaskRequest(request)
                return nil
            } catch {
                return error
            }
        }
        #endif
        // The synchronous API is deprecated from iOS/tvOS 27; it is only reached on earlier systems.
        do {
            try scheduler.submit(request)
            return nil
        } catch {
            return error
        }
    }

    /// Submits a background task request, throwing any error.
    /// - Parameters:
    ///   - request: Task request.
    ///   - scheduler: Scheduler to submit to.
    public static func submitOrThrow(_ request: BGTaskRequest, scheduler: BGTaskScheduler = .shared) async throws {
        if let error = await Self.submit(request, scheduler: scheduler) {
            throw error
        }
    }
    #endif

    #if canImport(BackgroundTasks) && os(iOS) && !targetEnvironment(macCatalyst)
    /// Submits a continued-processing request, falling back to the `queue` strategy when the
    /// system cannot run a `fail`-strategy request immediately.
    /// - Parameters:
    ///   - request: Continued-processing request; its `strategy` selects the first attempt.
    ///   - fallbackToQueue: Whether to resubmit with the `queue` strategy after an eligible failure.
    ///   - scheduler: Scheduler to submit to.
    /// - Returns: The final error, or `nil` on success.
    @available(iOS 26.0, *)
    public static func submitContinuedProcessing(
        _ request: BGContinuedProcessingTaskRequest,
        fallbackToQueue: Bool = true,
        scheduler: BGTaskScheduler = .shared) async -> (any Error)?
    {
        let preferImmediate = request.strategy == .fail
        return await Self.submitWithQueueFallback(
            preferImmediate: preferImmediate,
            fallbackToQueue: fallbackToQueue)
        { useQueue in
            request.strategy = useQueue ? .queue : .fail
            return await Self.submit(request, scheduler: scheduler)
        }
    }
    #endif
}
