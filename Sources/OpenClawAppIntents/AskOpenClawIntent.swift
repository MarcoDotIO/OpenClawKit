#if canImport(AppIntents)
import AppIntents
import Foundation
import OpenClawKit

/// Sends a prompt to OpenClaw and returns the reply ("Ask OpenClaw").
public struct AskOpenClawIntent: AppIntent {
    /// Intent title.
    public static let title: LocalizedStringResource = "Ask OpenClaw"

    /// Intent description.
    public static var description: IntentDescription? {
        IntentDescription("Send a prompt to OpenClaw and get the reply.")
    }

    /// Parameter summary shown in Shortcuts.
    public static var parameterSummary: some ParameterSummary {
        Summary("Ask OpenClaw \(\.$prompt)") {
            \.$session
            \.$agent
        }
    }

    /// Prompt to send.
    @Parameter(title: "Prompt")
    public var prompt: String

    /// Target session (defaults to the host's default session).
    @Parameter(title: "Session")
    public var session: OpenClawSessionAppEntity?

    /// Target agent (defaults to the default agent).
    @Parameter(title: "Agent")
    public var agent: OpenClawAgentAppEntity?

    /// Creates an empty intent (required by App Intents).
    public init() {}

    /// Creates a configured intent.
    /// - Parameters:
    ///   - prompt: Prompt to send.
    ///   - session: Target session.
    ///   - agent: Target agent.
    public init(prompt: String, session: OpenClawSessionAppEntity? = nil, agent: OpenClawAgentAppEntity? = nil) {
        self.prompt = prompt
        self.session = session
        self.agent = agent
    }

    /// Runs the prompt and returns the final reply as value and dialog.
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            let text = try await OpenClawIntentActions.ask(
                prompt: self.prompt,
                sessionKey: self.session?.id,
                agentId: self.agent?.id)
            return .result(value: text, dialog: IntentDialog(stringLiteral: OpenClawIntentActions.dialogText(for: text)))
        } catch {
            throw OpenClawIntentError.presentable(error)
        }
    }
}
#endif
