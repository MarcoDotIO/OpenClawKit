import Foundation
import OpenClawKit

/// Main-actor bridge between App Intents entry points and live app state.
@MainActor
final class OpenClawIntentBridge {
    static let shared = OpenClawIntentBridge()

    private weak var appState: OpenClawAppState?
    private let sdk = OpenClawSDK.shared

    private init() {}

    /// Binds the live app state so intents can route actions through the app.
    func bind(_ appState: OpenClawAppState) {
        self.appState = appState
    }

    /// Clears the currently bound app state. Intended for tests.
    func unbindForTesting() {
        self.appState = nil
    }

    /// Starts deployment from an App Intent entrypoint.
    func deployFromIntent() async -> String {
        guard let appState else {
            return "OpenClaw is not ready yet. Open the app and try again."
        }
        await appState.deploy()
        return appState.statusText
    }

    /// Stops deployment from an App Intent entrypoint.
    func stopFromIntent() async -> String {
        guard let appState else {
            return "OpenClaw is not ready yet. Open the app and try again."
        }
        await appState.stopDeployment()
        return appState.statusText
    }

    /// Routes a quick prompt through the intent-graph runtime surface.
    func quickAskFromIntent(
        _ prompt: String,
        focusNodeKind: IntentGraphNodeKind? = nil
    ) async -> String {
        guard let appState else {
            return "OpenClaw is not ready yet. Open the app and try again."
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return "Prompt is empty."
        }
        guard appState.deploymentState == .running else {
            return "Deploy the agent before using Quick Ask."
        }
        await appState.sendMessage(trimmedPrompt)
        let graph = await self.sdk.makeIntentGraph(
            for: AgentRunRequest(
                sessionKey: "app-intents",
                prompt: trimmedPrompt
            )
        )
        let graphSummary = Self.intentGraphSummary(graph, focusNodeKind: focusNodeKind)
        let output = appState.messages.last?.text ?? "Quick Ask complete."
        if graphSummary.isEmpty {
            return output
        }
        return "\(output)\n\n\(graphSummary)"
    }

    /// Builds a graph-only preview summary for a prompt.
    func previewIntentGraphFromIntent(
        _ prompt: String,
        focusNodeKind: IntentGraphNodeKind? = nil
    ) async -> String {
        guard let appState else {
            return "OpenClaw is not ready yet. Open the app and try again."
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return "Prompt is empty."
        }
        guard appState.deploymentState == .running else {
            return "Deploy the agent before previewing intent graph."
        }
        let graph = await self.sdk.makeIntentGraph(
            for: AgentRunRequest(
                sessionKey: "app-intents-preview",
                prompt: trimmedPrompt
            )
        )
        return Self.intentGraphSummary(
            graph,
            focusNodeKind: focusNodeKind
        )
    }

    private static func intentGraphSummary(
        _ graph: IntentGraph,
        focusNodeKind: IntentGraphNodeKind?
    ) -> String {
        var parts: [String] = [
            "Intent Graph: \(graph.nodes.count) node(s), \(graph.edges.count) edge(s).",
        ]
        if let focusNodeKind {
            let matchingCount = graph.nodes.filter { $0.kind == focusNodeKind }.count
            parts.append("Focus (\(focusNodeKind.rawValue)): \(matchingCount) node(s).")
        }
        return parts.joined(separator: " ")
    }
}
