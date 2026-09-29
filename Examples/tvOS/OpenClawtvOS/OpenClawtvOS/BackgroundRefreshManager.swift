import Foundation
import OpenClawKit
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Schedules a periodic background app refresh on Apple TV.
///
/// Submission goes through `OpenClawBackgroundTasks.submit(_:)`: tvOS 27 uses the async
/// `BGTaskScheduler.submitTaskRequest(_:)`, earlier systems `submit(_:)`, and the error is returned
/// (see ``lastSubmissionFailure``) instead of being dropped with `try?`.
@MainActor
final class BackgroundRefreshManager {
    static let shared = BackgroundRefreshManager()
    static let refreshIdentifier = "io.marcodotio.OpenClawtvOS.refresh"

    /// Most recent submission failure, if any.
    private(set) var lastSubmissionFailure: String?

    private var hasRegistered = false
    /// Whether BGTaskScheduler accepted the launch handler. Submitting a request for a permitted
    /// identifier without a registered handler raises an exception, so submission waits for it.
    private var isHandlerRegistered = false

    private init() {}

    /// Registers the refresh launch handler. Call once from the app initializer.
    func register() {
        #if canImport(BackgroundTasks)
        guard !self.hasRegistered else { return }
        self.hasRegistered = true
        // Launch handlers run on the main queue so they can use this main-actor state directly.
        self.isHandlerRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier,
            using: .main,
            launchHandler: { task in self.handleRefresh(task) }
        )
        #endif
    }

    #if canImport(BackgroundTasks)
    private func handleRefresh(_ task: BGTask) {
        task.expirationHandler = {}
        Task {
            await self.scheduleRefresh()
            task.setTaskCompleted(success: true)
        }
    }
    #endif

    /// Submits the next refresh request (at the earliest in 30 minutes).
    func scheduleRefresh() async {
        #if canImport(BackgroundTasks)
        guard self.isHandlerRegistered else {
            self.lastSubmissionFailure = "launch handler not registered for \(Self.refreshIdentifier)"
            return
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        if let error = await OpenClawBackgroundTasks.submit(request) {
            self.lastSubmissionFailure = "\(OpenClawBackgroundTasks.SubmissionFailure(error))"
        } else {
            self.lastSubmissionFailure = nil
        }
        #endif
    }
}
