import Foundation
import OpenClawKit
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Background task identifiers used by the iOS example.
enum OpenClawBackgroundTaskIdentifiers {
    static let refresh = "io.marcodotio.OpenClawiOS.refresh"
    static let processing = "io.marcodotio.OpenClawiOS.processing"
    @available(iOS 26.0, *)
    static let continuedProcessingPattern = "io.marcodotio.OpenClawiOS.continued-processing.*"
    @available(iOS 26.0, *)
    static let continuedProcessingPrefix = "io.marcodotio.OpenClawiOS.continued-processing."
}

/// Registers and schedules Apple-approved background continuation work.
///
/// Submissions go through `OpenClawBackgroundTasks` from OpenClawKit: on iOS 27 it uses the async
/// `BGTaskScheduler.submitTaskRequest(_:)`, earlier systems use `submit(_:)`, and every error is
/// returned (and recorded in ``lastSubmissionFailures``) instead of being dropped with `try?`.
@MainActor
final class BackgroundContinuationManager {
    static let shared = BackgroundContinuationManager()

    /// Most recent submission failure per task label (`refresh`, `processing`, `continued`).
    private(set) var lastSubmissionFailures: [String: String] = [:]

    private var hasRegisteredHandlers = false
    /// Identifiers whose launch handler BGTaskScheduler accepted. The scheduler raises an exception
    /// when a request is submitted for a permitted identifier without a registered handler, so
    /// requests are only submitted after a successful registration.
    private var registeredIdentifiers: Set<String> = []
    private var hasScheduledInitialTasks = false
    private var automationTickHandler: (@Sendable () async -> Void)?

    private init() {}

    /// Registers all known background task launch handlers.
    func registerTaskHandlers() {
        #if canImport(BackgroundTasks)
        guard !self.hasRegisteredHandlers else { return }
        self.hasRegisteredHandlers = true

        // Launch handlers run on the main queue so they can use this main-actor state directly.
        if BGTaskScheduler.shared.register(
            forTaskWithIdentifier: OpenClawBackgroundTaskIdentifiers.refresh,
            using: .main,
            launchHandler: { task in self.handleRefreshTask(task) }
        ) {
            self.registeredIdentifiers.insert(OpenClawBackgroundTaskIdentifiers.refresh)
        }
        if BGTaskScheduler.shared.register(
            forTaskWithIdentifier: OpenClawBackgroundTaskIdentifiers.processing,
            using: .main,
            launchHandler: { task in self.handleProcessingTask(task) }
        ) {
            self.registeredIdentifiers.insert(OpenClawBackgroundTaskIdentifiers.processing)
        }
        if #available(iOS 26.0, *) {
            if BGTaskScheduler.shared.register(
                forTaskWithIdentifier: OpenClawBackgroundTaskIdentifiers.continuedProcessingPattern,
                using: .main,
                launchHandler: { task in self.handleContinuedProcessingTask(task) }
            ) {
                self.registeredIdentifiers.insert(OpenClawBackgroundTaskIdentifiers.continuedProcessingPattern)
            }
        }
        #endif
    }

    /// Schedules one-shot startup background requests.
    func scheduleInitialTasksIfNeeded() {
        guard !self.hasScheduledInitialTasks else { return }
        self.hasScheduledInitialTasks = true
        Task {
            await self.scheduleMaintenanceTasks()
            if #available(iOS 26.0, *) {
                await self.scheduleContinuedProcessing()
            }
        }
    }

    /// Binds an optional automation tick callback executed by background handlers.
    /// - Parameter handler: Async automation callback.
    func bindAutomationTickHandler(_ handler: (@Sendable () async -> Void)?) {
        self.automationTickHandler = handler
    }

    /// Executes bound automation hook for tests/debug validation.
    func runAutomationTickForTesting() async {
        guard let automationTickHandler = self.automationTickHandler else {
            return
        }
        await automationTickHandler()
    }

    /// Schedules refresh and processing maintenance requests.
    func scheduleMaintenanceTasks() async {
        #if canImport(BackgroundTasks)
        let scheduler = BGTaskScheduler.shared

        if self.isRegistered(OpenClawBackgroundTaskIdentifiers.refresh, label: "refresh") {
            scheduler.cancel(taskRequestWithIdentifier: OpenClawBackgroundTaskIdentifiers.refresh)
            let refresh = BGAppRefreshTaskRequest(identifier: OpenClawBackgroundTaskIdentifiers.refresh)
            refresh.earliestBeginDate = Date().addingTimeInterval(15 * 60)
            self.record(await OpenClawBackgroundTasks.submit(refresh), label: "refresh")
        }

        if self.isRegistered(OpenClawBackgroundTaskIdentifiers.processing, label: "processing") {
            scheduler.cancel(taskRequestWithIdentifier: OpenClawBackgroundTaskIdentifiers.processing)
            let processing = BGProcessingTaskRequest(identifier: OpenClawBackgroundTaskIdentifiers.processing)
            processing.requiresNetworkConnectivity = false
            processing.requiresExternalPower = false
            processing.earliestBeginDate = Date().addingTimeInterval(30 * 60)
            self.record(await OpenClawBackgroundTasks.submit(processing), label: "processing")
        }
        #endif
    }

    /// Schedules a continued-processing request on iOS 26+.
    @available(iOS 26.0, *)
    func scheduleContinuedProcessing() async {
        #if canImport(BackgroundTasks)
        guard self.isRegistered(OpenClawBackgroundTaskIdentifiers.continuedProcessingPattern, label: "continued") else {
            return
        }
        let identifier = OpenClawBackgroundTaskIdentifiers.continuedProcessingPrefix + UUID().uuidString
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "OpenClaw running task",
            subtitle: "Continue active work in background"
        )
        // `queue` waits for the system; a `fail`-strategy request would fall back to `queue` when the
        // system cannot start it immediately.
        request.strategy = .queue
        request.requiredResources = []
        self.record(await OpenClawBackgroundTasks.submitContinuedProcessing(request), label: "continued")
        #endif
    }

    /// Returns whether a launch handler is registered for `identifier`, recording a failure otherwise.
    private func isRegistered(_ identifier: String, label: String) -> Bool {
        guard self.registeredIdentifiers.contains(identifier) else {
            self.lastSubmissionFailures[label] = "launch handler not registered for \(identifier)"
            return false
        }
        return true
    }

    private func record(_ error: (any Error)?, label: String) {
        guard let error else {
            self.lastSubmissionFailures[label] = nil
            return
        }
        #if canImport(BackgroundTasks)
        self.lastSubmissionFailures[label] = "\(OpenClawBackgroundTasks.SubmissionFailure(error))"
        #else
        self.lastSubmissionFailures[label] = error.localizedDescription
        #endif
    }

    #if canImport(BackgroundTasks)
    private func handleRefreshTask(_ task: BGTask) {
        task.expirationHandler = {}
        self.runAutomationTickAndReschedule {
            task.setTaskCompleted(success: true)
        }
    }

    private func handleProcessingTask(_ task: BGTask) {
        task.expirationHandler = {}
        self.runAutomationTickAndReschedule {
            task.setTaskCompleted(success: true)
        }
    }

    @available(iOS 26.0, *)
    private func handleContinuedProcessingTask(_ task: BGTask) {
        guard let continuedTask = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        continuedTask.expirationHandler = {}
        continuedTask.progress.totalUnitCount = 1
        self.runAutomationTickAndReschedule {
            continuedTask.progress.completedUnitCount = 1
            continuedTask.setTaskCompleted(success: true)
        }
    }

    private func runAutomationTickAndReschedule(completion: @escaping @MainActor () -> Void) {
        let automationTickHandler = self.automationTickHandler
        Task {
            if let automationTickHandler {
                await automationTickHandler()
            }
            await self.scheduleMaintenanceTasks()
            completion()
        }
    }
    #endif
}
