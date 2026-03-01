import Foundation
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
@MainActor
final class BackgroundContinuationManager {
    static let shared = BackgroundContinuationManager()

    private var hasRegisteredHandlers = false
    private var hasScheduledInitialTasks = false
    private var automationTickHandler: (@Sendable () async -> Void)?

    private init() {}

    /// Registers all known background task launch handlers.
    func registerTaskHandlers() {
        #if canImport(BackgroundTasks)
        guard !self.hasRegisteredHandlers else { return }
        self.hasRegisteredHandlers = true

        BGTaskScheduler.shared.register(forTaskWithIdentifier: OpenClawBackgroundTaskIdentifiers.refresh, using: nil) { task in
            self.handleRefreshTask(task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: OpenClawBackgroundTaskIdentifiers.processing, using: nil) { task in
            self.handleProcessingTask(task)
        }
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: OpenClawBackgroundTaskIdentifiers.continuedProcessingPattern,
                using: nil
            ) { task in
                self.handleContinuedProcessingTask(task)
            }
        }
        #endif
    }

    /// Schedules one-shot startup background requests.
    func scheduleInitialTasksIfNeeded() {
        guard !self.hasScheduledInitialTasks else { return }
        self.hasScheduledInitialTasks = true
        self.scheduleMaintenanceTasks()
        if #available(iOS 26.0, *) {
            self.scheduleContinuedProcessing()
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
    func scheduleMaintenanceTasks() {
        #if canImport(BackgroundTasks)
        let scheduler = BGTaskScheduler.shared

        scheduler.cancel(taskRequestWithIdentifier: OpenClawBackgroundTaskIdentifiers.refresh)
        let refresh = BGAppRefreshTaskRequest(identifier: OpenClawBackgroundTaskIdentifiers.refresh)
        refresh.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? scheduler.submit(refresh)

        scheduler.cancel(taskRequestWithIdentifier: OpenClawBackgroundTaskIdentifiers.processing)
        let processing = BGProcessingTaskRequest(identifier: OpenClawBackgroundTaskIdentifiers.processing)
        processing.requiresNetworkConnectivity = false
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? scheduler.submit(processing)
        #endif
    }

    /// Schedules a continued-processing request on iOS 26+.
    @available(iOS 26.0, *)
    func scheduleContinuedProcessing() {
        #if canImport(BackgroundTasks)
        let identifier = OpenClawBackgroundTaskIdentifiers.continuedProcessingPrefix + UUID().uuidString
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "OpenClaw running task",
            subtitle: "Continue active work in background"
        )
        request.strategy = .queue
        request.requiredResources = []
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    #if canImport(BackgroundTasks)
    private func handleRefreshTask(_ task: BGTask) {
        task.expirationHandler = {}
        if let automationTickHandler = self.automationTickHandler {
            Task {
                await automationTickHandler()
            }
        }
        self.scheduleMaintenanceTasks()
        task.setTaskCompleted(success: true)
    }

    private func handleProcessingTask(_ task: BGTask) {
        task.expirationHandler = {}
        if let automationTickHandler = self.automationTickHandler {
            Task {
                await automationTickHandler()
            }
        }
        self.scheduleMaintenanceTasks()
        task.setTaskCompleted(success: true)
    }

    @available(iOS 26.0, *)
    private func handleContinuedProcessingTask(_ task: BGTask) {
        guard let continuedTask = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        continuedTask.expirationHandler = {}
        if let automationTickHandler = self.automationTickHandler {
            Task {
                await automationTickHandler()
            }
        }
        continuedTask.progress.totalUnitCount = 1
        continuedTask.progress.completedUnitCount = 1
        continuedTask.setTaskCompleted(success: true)
    }
    #endif
}
