import Foundation

/// Main-actor bridge between App Intents entry points and live app state.
@MainActor
final class OpenClawIntentBridge {
    static let shared = OpenClawIntentBridge()

    private weak var appState: OpenClawAppState?

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

    /// Routes a quick prompt through the active runtime from an App Intent.
    func quickAskFromIntent(_ prompt: String) async -> String {
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
        return appState.messages.last?.text ?? "Quick Ask complete."
    }
}
