import Foundation
import OpenClawCore

/// One proactive automation execution outcome.
public struct AutomationExecutionOutcome: Sendable, Equatable {
    /// Rule identifier.
    public let ruleID: String
    /// Run identifier when execution reached runtime dispatch.
    public let runID: String?
    /// Execution success state.
    public let succeeded: Bool
    /// Error description when execution failed.
    public let errorDescription: String?

    /// Creates one automation execution outcome.
    /// - Parameters:
    ///   - ruleID: Rule identifier.
    ///   - runID: Run identifier.
    ///   - succeeded: Success state.
    ///   - errorDescription: Optional failure detail.
    public init(
        ruleID: String,
        runID: String?,
        succeeded: Bool,
        errorDescription: String? = nil
    ) {
        self.ruleID = ruleID
        self.runID = runID
        self.succeeded = succeeded
        self.errorDescription = errorDescription
    }
}

/// Executes proactive automation rules against the embedded runtime.
public actor AutomationRunner {
    private let runtime: EmbeddedAgentRuntime
    private let ruleStore: AutomationRuleStore
    private let diagnosticsSink: RuntimeDiagnosticSink?

    /// Creates an automation runner.
    /// - Parameters:
    ///   - runtime: Runtime used for proactive execution.
    ///   - ruleStore: Rule store used for due-rule resolution.
    ///   - diagnosticsSink: Optional diagnostics sink for automation events.
    public init(
        runtime: EmbeddedAgentRuntime,
        ruleStore: AutomationRuleStore,
        diagnosticsSink: RuntimeDiagnosticSink? = nil
    ) {
        self.runtime = runtime
        self.ruleStore = ruleStore
        self.diagnosticsSink = diagnosticsSink
    }

    /// Executes due interval rules.
    /// - Parameter date: Current timestamp.
    /// - Returns: Execution outcomes.
    public func runDueAutomations(at date: Date = Date()) async -> [AutomationExecutionOutcome] {
        await self.run(matching: nil, at: date)
    }

    /// Executes rules triggered by one diagnostics event.
    /// - Parameters:
    ///   - event: Triggering diagnostics event.
    ///   - date: Current timestamp.
    /// - Returns: Execution outcomes.
    public func handle(event: RuntimeDiagnosticEvent, at date: Date = Date()) async -> [AutomationExecutionOutcome] {
        await self.run(matching: event, at: date)
    }

    private func run(
        matching event: RuntimeDiagnosticEvent?,
        at date: Date
    ) async -> [AutomationExecutionOutcome] {
        let due = await self.ruleStore.dueRules(at: date, matching: event)
        guard !due.isEmpty else {
            return []
        }

        var outcomes: [AutomationExecutionOutcome] = []
        var attemptedRuleIDs: [String] = []
        for rule in due {
            attemptedRuleIDs.append(rule.id)
            let runRequest = AgentRunRequest(
                sessionKey: rule.sessionKey,
                prompt: rule.prompt,
                modelProviderID: rule.modelProviderID
            )
            do {
                let result = try await self.runtime.run(runRequest)
                outcomes.append(
                    AutomationExecutionOutcome(
                        ruleID: rule.id,
                        runID: result.runID,
                        succeeded: true
                    )
                )
                await self.publishDiagnostics(
                    RuntimeDiagnosticEvent(
                        subsystem: "automation",
                        name: "rule.executed",
                        runID: result.runID,
                        sessionKey: result.sessionKey,
                        metadata: [
                            "ruleID": rule.id,
                            "ruleName": rule.name,
                            "triggerType": rule.trigger.type.rawValue,
                        ]
                    )
                )
            } catch {
                outcomes.append(
                    AutomationExecutionOutcome(
                        ruleID: rule.id,
                        runID: runRequest.runID,
                        succeeded: false,
                        errorDescription: String(describing: error)
                    )
                )
                await self.publishDiagnostics(
                    RuntimeDiagnosticEvent(
                        subsystem: "automation",
                        name: "rule.failed",
                        runID: runRequest.runID,
                        sessionKey: runRequest.sessionKey,
                        metadata: [
                            "ruleID": rule.id,
                            "ruleName": rule.name,
                            "triggerType": rule.trigger.type.rawValue,
                            "error": String(describing: error),
                        ]
                    )
                )
            }
        }

        await self.ruleStore.markAttempted(ruleIDs: attemptedRuleIDs, at: date)
        try? await self.ruleStore.save()
        return outcomes
    }

    private func publishDiagnostics(_ event: RuntimeDiagnosticEvent) async {
        guard let diagnosticsSink else {
            return
        }
        await diagnosticsSink(event)
    }
}
