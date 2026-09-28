#if canImport(AppIntents)
import AppIntents
import Foundation
import OpenClawKit

/// Opens the app and starts a live voice conversation ("Start Live Voice").
///
/// Mirrors upstream iOS `StartLiveVoiceIntent`. Handled by ``OpenClawIntentRouter`` when the app set
/// `startLiveVoiceHandler`, otherwise by the host's `startTalk(sessionKey:)`. Pairing, provider setup,
/// microphone permission, unlock and foreground requirements still apply.
public struct StartOpenClawTalkIntent: AppIntent {
    /// Intent title.
    public static let title: LocalizedStringResource = "Start Live Voice"

    /// Intent description.
    public static var description: IntentDescription? {
        IntentDescription("Open the current chat in OpenClaw and start a voice conversation.")
    }

    /// Talk mode needs the app in the foreground.
    public static let openAppWhenRun: Bool = true

    /// Session to talk in (defaults to the current chat).
    @Parameter(title: "Session")
    public var session: OpenClawSessionAppEntity?

    /// Creates an empty intent (required by App Intents).
    public init() {}

    /// Creates a configured intent.
    /// - Parameter session: Session to talk in.
    public init(session: OpenClawSessionAppEntity?) {
        self.session = session
    }

    /// Starts live voice.
    @MainActor
    public func perform() async throws -> some IntentResult {
        do {
            try await OpenClawIntentActions.startTalk(sessionKey: self.session?.id)
        } catch {
            throw OpenClawIntentError.presentable(error)
        }
        return .result()
    }
}

/// Upstream name of ``StartOpenClawTalkIntent``.
public typealias OpenClawStartLiveVoiceIntent = StartOpenClawTalkIntent
#endif
