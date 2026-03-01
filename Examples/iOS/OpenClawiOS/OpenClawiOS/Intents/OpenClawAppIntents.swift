import AppIntents

/// Starts the OpenClaw runtime deployment from Siri or Shortcuts.
struct DeployOpenClawIntent: AppIntent {
    static let title: LocalizedStringResource = "Deploy OpenClaw Agent"
    static let description = IntentDescription("Start the OpenClaw runtime in the iOS example app.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await OpenClawIntentBridge.shared.deployFromIntent()
        return .result()
    }
}

/// Stops the OpenClaw runtime deployment from Siri or Shortcuts.
struct StopOpenClawIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop OpenClaw Deployment"
    static let description = IntentDescription("Stop the running OpenClaw runtime in the iOS example app.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await OpenClawIntentBridge.shared.stopFromIntent()
        return .result()
    }
}

/// Sends a quick prompt through a running OpenClaw deployment.
struct QuickAskOpenClawIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Ask OpenClaw"
    static let description = IntentDescription("Send a prompt through the currently deployed OpenClaw runtime.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Prompt")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask OpenClaw: \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await OpenClawIntentBridge.shared.quickAskFromIntent(self.prompt)
        return .result()
    }
}

/// App Shortcut catalog for core OpenClaw controls.
struct OpenClawAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DeployOpenClawIntent(),
            phrases: [
                "Deploy \(.applicationName) agent",
                "Start \(.applicationName) runtime",
            ],
            shortTitle: "Deploy Agent",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: StopOpenClawIntent(),
            phrases: [
                "Stop \(.applicationName) deployment",
                "Shut down \(.applicationName)",
            ],
            shortTitle: "Stop Deployment",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: QuickAskOpenClawIntent(),
            phrases: [
                "Quick ask \(.applicationName)",
            ],
            shortTitle: "Quick Ask",
            systemImageName: "message"
        )
    }
}
