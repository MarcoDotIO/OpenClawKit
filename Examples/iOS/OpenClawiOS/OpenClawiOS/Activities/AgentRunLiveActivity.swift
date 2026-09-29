import Foundation
import OpenClawKit
#if canImport(ActivityKit)
@preconcurrency import ActivityKit
#endif

/// Bridges runtime diagnostics events to iOS Live Activities for long-running runs.
///
/// Uses the SDK's shared schema (`OpenClawAgentRunActivityAttributes`) and the pure
/// `OpenClawAgentRunActivityReducer` state machine, so a widget extension can render the same
/// content state without duplicating the attribute type.
@MainActor
final class AgentRunLiveActivityCoordinator {
    private var reducer = OpenClawAgentRunActivityReducer()
    #if canImport(ActivityKit)
    private var activitiesByRunID: [String: Activity<OpenClawAgentRunActivityAttributes>] = [:]
    #endif

    /// Handles one diagnostics event and updates Live Activity state if relevant.
    func handle(event: RuntimeDiagnosticEvent) async {
        guard let action = self.reducer.reduce(event) else {
            return
        }
        #if canImport(ActivityKit)
        switch action {
        case let .upsert(runID, sessionKey, state):
            await self.upsert(runID: runID, sessionKey: sessionKey, state: state)
        case let .end(runID, sessionKey, state, immediately):
            await self.upsert(runID: runID, sessionKey: sessionKey, state: state)
            guard let activity = self.activitiesByRunID.removeValue(forKey: runID) else {
                return
            }
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: immediately ? .immediate : .default
            )
        }
        #endif
    }

    /// Ends all active run live activities.
    func stopAll() async {
        self.reducer = OpenClawAgentRunActivityReducer()
        #if canImport(ActivityKit)
        let active = self.activitiesByRunID.values
        self.activitiesByRunID.removeAll(keepingCapacity: true)
        for activity in active {
            let state = OpenClawAgentRunActivityContentState(
                phase: .aborted,
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
    private func upsert(
        runID: String,
        sessionKey: String,
        state: OpenClawAgentRunActivityContentState
    ) async {
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(15 * 60)
        )

        if let activity = self.activitiesByRunID[runID] {
            await activity.update(content)
            return
        }

        do {
            let activity = try Activity<OpenClawAgentRunActivityAttributes>.request(
                attributes: OpenClawAgentRunActivityAttributes(
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
    #endif
}
