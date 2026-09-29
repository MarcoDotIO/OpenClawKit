import Foundation
import OpenClawKit

/// Shared, App Intents-independent implementations of the OpenClaw intents.
///
/// The intents call these with ``OpenClawAppIntents/host``; hosts and tests can call them directly.
public enum OpenClawIntentActions {
    /// Sends a prompt, waits for the run to finish, and returns the final assistant text.
    /// - Parameters:
    ///   - prompt: User prompt.
    ///   - sessionKey: Target session, or `nil` for the host default.
    ///   - agentId: Target agent, or `nil` for the default agent.
    ///   - host: Intent backend.
    ///   - progress: Optional run progress to drive from the event stream.
    ///   - onEvent: Optional observer for every run event.
    /// - Returns: Final assistant text (empty when the run produced none).
    /// - Throws: ``OpenClawIntentError/emptyPrompt``, ``OpenClawIntentError/aborted`` when the run was
    ///   aborted, or the host's error.
    public static func ask(
        prompt: String,
        sessionKey: String? = nil,
        agentId: String? = nil,
        host: any OpenClawIntentHost = OpenClawAppIntents.host,
        progress: OpenClawRunProgress? = nil,
        onEvent: (@Sendable (OpenClawIntentRunEvent) -> Void)? = nil) async throws -> String
    {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenClawIntentError.emptyPrompt }
        var last = ""
        var aborted = false
        for try await event in try await host.send(prompt: trimmed, sessionKey: sessionKey, agentId: agentId) {
            onEvent?(event)
            if let progress {
                if let fraction = event.fractionCompleted {
                    progress.advance(toFractionCompleted: fraction, phase: event.phase)
                } else {
                    progress.advance(to: event.phase)
                }
            }
            if let text = event.text {
                last = text
            }
            if event.phase == .aborted {
                aborted = true
            }
        }
        if aborted {
            throw OpenClawIntentError.aborted
        }
        progress?.advance(to: .completed)
        return last
    }

    /// Starts live voice: the router's handler when set, otherwise the host.
    /// - Parameters:
    ///   - sessionKey: Session to talk in, or `nil` for the current one.
    ///   - host: Intent backend used when no router handler is set.
    @MainActor
    public static func startTalk(sessionKey: String?, host: any OpenClawIntentHost = OpenClawAppIntents.host) async throws {
        if try await OpenClawIntentRouter.shared.startLiveVoice(sessionKey: sessionKey) {
            return
        }
        try await host.startTalk(sessionKey: sessionKey)
    }

    /// Aborts the active run of a session.
    ///
    /// The abort runs through a cancellation shield, so a cancelled caller (an intent's `onCancel`
    /// path or a cancelled `perform()`) still sends `chat.abort`.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - host: Intent backend.
    public static func abort(sessionKey: String, host: any OpenClawIntentHost = OpenClawAppIntents.host) async {
        _ = try? await IntentCancellationShield.run {
            await host.abort(sessionKey: sessionKey)
        }
    }

    /// Dialog text for a finished ask.
    /// - Parameter text: Final assistant text.
    /// - Returns: Text to speak or show.
    public static func dialogText(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "OpenClaw finished without a reply." : trimmed
    }
}

/// Main-actor router for intents that must reach the app's own controllers (for example talk mode).
///
/// Hosts set the handlers at launch; `openclaw://talk/start` (``talkStartURL``) is the matching deep link.
@MainActor
public final class OpenClawIntentRouter {
    /// Shared router.
    public static let shared = OpenClawIntentRouter()

    /// Deep link that starts live voice.
    nonisolated public static let talkStartURL = URL(string: "openclaw://talk/start")!

    /// Starts live voice in the given session (or the current one when `nil`).
    public var startLiveVoiceHandler: (@MainActor (String?) async throws -> Void)?

    private init() {}

    /// Runs the live-voice handler.
    /// - Parameter sessionKey: Session key, or `nil` for the current one.
    /// - Returns: Whether a handler was set.
    @discardableResult
    public func startLiveVoice(sessionKey: String? = nil) async throws -> Bool {
        guard let handler = self.startLiveVoiceHandler else { return false }
        try await handler(sessionKey)
        return true
    }

    /// Whether a URL is the live-voice deep link (`openclaw://talk/start`).
    /// - Parameter url: Incoming URL.
    /// - Returns: `true` for the talk-start link.
    nonisolated public static func isTalkStartURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "openclaw", url.host?.lowercased() == "talk" else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return path == "start"
    }
}
