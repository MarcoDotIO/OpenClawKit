#if canImport(AppIntents)
import AppIntents
import Foundation
import OpenClawKit

/// Stops the active OpenClaw run of a session.
public struct AbortOpenClawRunIntent: AppIntent {
    /// Intent title.
    public static let title: LocalizedStringResource = "Stop OpenClaw Run"

    /// Intent description.
    public static var description: IntentDescription? {
        IntentDescription("Stop the reply OpenClaw is currently working on.")
    }

    /// Parameter summary shown in Shortcuts.
    public static var parameterSummary: some ParameterSummary {
        Summary("Stop the OpenClaw run in \(\.$session)")
    }

    /// Session whose run to stop.
    @Parameter(title: "Session")
    public var session: OpenClawSessionAppEntity

    /// Creates an empty intent (required by App Intents).
    public init() {}

    /// Creates a configured intent.
    /// - Parameter session: Session whose run to stop.
    public init(session: OpenClawSessionAppEntity) {
        self.session = session
    }

    /// Sends the abort request.
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        await OpenClawIntentActions.abort(sessionKey: self.session.id)
        return .result(dialog: "Stopped the OpenClaw run.")
    }
}
#endif
