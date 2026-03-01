import AppIntents

/// Starts the OpenClaw runtime deployment from Siri or Shortcuts.
struct DeployOpenClawIntent: AppIntent {
    static let title: LocalizedStringResource = "Deploy OpenClaw Agent"
    static let description = IntentDescription("Start the OpenClaw runtime in the iOS example app.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = await OpenClawIntentBridge.shared.deployFromIntent()
        return .result(dialog: IntentDialog(stringLiteral: status))
    }
}

/// Stops the OpenClaw runtime deployment from Siri or Shortcuts.
struct StopOpenClawIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop OpenClaw Deployment"
    static let description = IntentDescription("Stop the running OpenClaw runtime in the iOS example app.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = await OpenClawIntentBridge.shared.stopFromIntent()
        return .result(dialog: IntentDialog(stringLiteral: status))
    }
}

/// Sends a quick prompt through a running OpenClaw deployment.
struct QuickAskOpenClawIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Ask OpenClaw"
    static let description = IntentDescription("Send a prompt through the currently deployed OpenClaw runtime.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Prompt")
    var prompt: String

    @Parameter(title: "Focus Node Kind")
    var focusNode: IntentGraphNodeKindEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask OpenClaw: \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = await OpenClawIntentBridge.shared.quickAskFromIntent(
            self.prompt,
            focusNodeKind: self.focusNode?.kind.protocolKind
        )
        return .result(dialog: IntentDialog(stringLiteral: status))
    }
}

/// Builds a graph preview for a prompt without executing model generation.
struct PreviewOpenClawIntentGraphIntent: AppIntent {
    static let title: LocalizedStringResource = "Preview OpenClaw Intent Graph"
    static let description = IntentDescription("Preview the SDK intent graph that would be used for a prompt.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Prompt")
    var prompt: String

    @Parameter(title: "Focus Node Kind")
    var focusNode: IntentGraphNodeKindEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Preview OpenClaw graph for \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = await OpenClawIntentBridge.shared.previewIntentGraphFromIntent(
            self.prompt,
            focusNodeKind: self.focusNode?.kind.protocolKind
        )
        return .result(dialog: IntentDialog(stringLiteral: summary))
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
        AppShortcut(
            intent: PreviewOpenClawIntentGraphIntent(),
            phrases: [
                "Preview \(.applicationName) intent graph",
                "Show \(.applicationName) graph plan",
            ],
            shortTitle: "Preview Graph",
            systemImageName: "point.bottomleft.forward.to.point.topright.scurvepath"
        )
    }
}
