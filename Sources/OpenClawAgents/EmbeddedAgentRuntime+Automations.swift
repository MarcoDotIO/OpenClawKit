import Foundation
import OpenClawCore
import OpenClawProtocol

public extension EmbeddedAgentRuntime {
    /// Wires cron automations into the runtime.
    ///
    /// - The scheduler runs due jobs through ``EmbeddedAgentAutomationExecutor`` (agent turns in the
    ///   job's session; `systemEvent` jobs go to `systemEventSink`, or run as a turn without one).
    /// - The `automations` tool (alias `cron`) is registered; its `wake` action queues the text as an
    ///   internal event for the session's next run unless `systemEventSink` is given.
    /// - Scheduler changes emit the typed `cron_changed` hook on ``hookRegistry``.
    /// - Parameters:
    ///   - scheduler: Automation scheduler.
    ///   - systemEventSink: Optional sink for system events (for example a channel delivery path).
    ///   - workspaceRootPath: Workspace used for automation turns.
    ///   - defaultTimeoutMs: Turn timeout when a job does not set one.
    func installAutomations(
        scheduler: CronScheduler,
        systemEventSink: AutomationSystemEventSink? = nil,
        workspaceRootPath: String? = nil,
        defaultTimeoutMs: Int = 120_000
    ) async {
        let executor = EmbeddedAgentAutomationExecutor(
            runtime: self,
            systemEventSink: systemEventSink,
            workspaceRootPath: workspaceRootPath,
            defaultTimeoutMs: defaultTimeoutMs
        )
        await scheduler.setExecutor(executor.executor)
        let wakeSink: AutomationSystemEventSink = systemEventSink ?? { [weak self] sessionKey, text in
            await self?.enqueueInternalEvent(text, sessionKey: sessionKey)
        }
        await self.toolRegistry.register(AutomationsTool(scheduler: scheduler, systemEventSink: wakeSink, defaultAgentID: self.defaultAgentID))
        if let hookRegistry = self.hookRegistry {
            await scheduler.onChange { event in
                guard await hookRegistry.hasHandlers(for: .cronChanged) else { return }
                await hookRegistry.emitObserving(
                    .cronChanged,
                    event: event,
                    context: HookContext(runID: event.runId, sessionKey: event.sessionKey, agentID: event.agentId)
                )
            }
        }
    }
}
