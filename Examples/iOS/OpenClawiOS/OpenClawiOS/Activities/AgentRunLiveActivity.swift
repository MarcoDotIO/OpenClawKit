import Foundation
import OpenClawKit
#if canImport(ActivityKit)
@preconcurrency import ActivityKit
#endif

#if canImport(ActivityKit)
@available(iOS 16.1, *)
struct AgentRunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var detail: String
        var progress: Double
        var updatedAt: Date
    }

    var runID: String
    var sessionKey: String
}
#endif

/// Bridges runtime diagnostics events to iOS Live Activities for long-running runs.
@MainActor
final class AgentRunLiveActivityCoordinator {
    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    private var activitiesByRunID: [String: Activity<AgentRunActivityAttributes>] = [:]
    #endif

    /// Handles one diagnostics event and updates Live Activity state if relevant.
    func handle(event: RuntimeDiagnosticEvent) async {
        guard event.subsystem == "runtime",
              let runID = event.runID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runID.isEmpty
        else {
            return
        }

        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else {
            return
        }

        switch event.name {
        case "run.started":
            await self.upsert(
                runID: runID,
                sessionKey: event.sessionKey ?? "default",
                phase: "Running",
                detail: "Preparing run",
                progress: 0.1,
                occurredAt: event.occurredAt
            )
        case "model.call.started":
            await self.upsert(
                runID: runID,
                sessionKey: event.sessionKey ?? "default",
                phase: "Calling model",
                detail: self.providerDetail(from: event, fallback: "Generating response"),
                progress: 0.45,
                occurredAt: event.occurredAt
            )
        case "model.call.completed":
            await self.upsert(
                runID: runID,
                sessionKey: event.sessionKey ?? "default",
                phase: "Finalizing",
                detail: self.providerDetail(from: event, fallback: "Finishing run"),
                progress: 0.8,
                occurredAt: event.occurredAt
            )
        case "run.completed":
            await self.complete(
                runID: runID,
                sessionKey: event.sessionKey ?? "default",
                phase: "Completed",
                detail: "Run completed",
                occurredAt: event.occurredAt,
                dismissalPolicy: .default
            )
        case "run.failed":
            let detail = event.metadata["error"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            await self.complete(
                runID: runID,
                sessionKey: event.sessionKey ?? "default",
                phase: "Failed",
                detail: detail?.isEmpty == false ? detail! : "Run failed",
                occurredAt: event.occurredAt,
                dismissalPolicy: .immediate
            )
        default:
            break
        }
        #endif
    }

    /// Ends all active run live activities.
    func stopAll() async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else {
            return
        }
        let active = self.activitiesByRunID.values
        self.activitiesByRunID.removeAll(keepingCapacity: true)
        for activity in active {
            let state = AgentRunActivityAttributes.ContentState(
                phase: "Stopped",
                detail: "Deployment stopped",
                progress: 1.0,
                updatedAt: Date()
            )
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
        #endif
    }

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    private func upsert(
        runID: String,
        sessionKey: String,
        phase: String,
        detail: String,
        progress: Double,
        occurredAt: Date
    ) async {
        let clampedProgress = min(1, max(0, progress))
        let content = ActivityContent(
            state: AgentRunActivityAttributes.ContentState(
                phase: phase,
                detail: detail,
                progress: clampedProgress,
                updatedAt: occurredAt
            ),
            staleDate: Date().addingTimeInterval(15 * 60)
        )

        if let activity = self.activitiesByRunID[runID] {
            await activity.update(content)
            return
        }

        do {
            let activity = try Activity<AgentRunActivityAttributes>.request(
                attributes: AgentRunActivityAttributes(
                    runID: runID,
                    sessionKey: sessionKey
                ),
                content: content,
                pushType: nil
            )
            self.activitiesByRunID[runID] = activity
        } catch {
            // Live Activities are best effort in the sample app.
        }
    }

    @available(iOS 16.1, *)
    private func complete(
        runID: String,
        sessionKey: String,
        phase: String,
        detail: String,
        occurredAt: Date,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        await self.upsert(
            runID: runID,
            sessionKey: sessionKey,
            phase: phase,
            detail: detail,
            progress: 1.0,
            occurredAt: occurredAt
        )
        guard let activity = self.activitiesByRunID.removeValue(forKey: runID) else {
            return
        }
        let content = ActivityContent(
            state: AgentRunActivityAttributes.ContentState(
                phase: phase,
                detail: detail,
                progress: 1.0,
                updatedAt: occurredAt
            ),
            staleDate: nil
        )
        await activity.end(content, dismissalPolicy: dismissalPolicy)
    }
    #endif

    private func providerDetail(from event: RuntimeDiagnosticEvent, fallback: String) -> String {
        let provider = event.metadata["providerID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !provider.isEmpty else {
            return fallback
        }
        return "Provider: \(provider)"
    }
}
