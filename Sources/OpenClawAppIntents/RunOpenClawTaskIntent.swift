import Foundation

#if compiler(>=6.4) && canImport(AppIntents)
import AppIntents
import OpenClawKit

/// Runs a longer OpenClaw task in the background with progress ("Run OpenClaw Task", OS 27).
///
/// A `LongRunningIntent`: the work continues through `performBackgroundTask` after the system UI
/// goes away, `progress` follows ``OpenClawRunProgress``, and cancelling the task sends `chat.abort`
/// through the host. It runs in the app process only (`allowedExecutionTargets == [.main]`) because
/// the gateway socket and keychain live there.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct RunOpenClawTaskIntent: LongRunningIntent, CancellableIntent {
    /// Intent title.
    public static let title: LocalizedStringResource = "Run OpenClaw Task"

    /// Intent description.
    public static var description: IntentDescription? {
        IntentDescription("Hand OpenClaw a task and let it keep working in the background.")
    }

    /// Runs in the app process (gateway connection and credentials live there).
    public static var allowedExecutionTargets: IntentExecutionTargets {
        [.main]
    }

    /// Parameter summary shown in Shortcuts.
    public static var parameterSummary: some ParameterSummary {
        Summary("Run OpenClaw task \(\.$prompt)") {
            \.$session
            \.$agent
        }
    }

    /// Task prompt.
    @Parameter(title: "Task")
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
    ///   - prompt: Task prompt.
    ///   - session: Target session.
    ///   - agent: Target agent.
    public init(prompt: String, session: OpenClawSessionAppEntity? = nil, agent: OpenClawAgentAppEntity? = nil) {
        self.prompt = prompt
        self.session = session
        self.agent = agent
    }

    /// Runs the task in the background and returns the final reply.
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let host = OpenClawAppIntents.host
        let prompt = self.prompt
        let requestedSession = self.session?.id
        let agentId = self.agent?.id
        let runProgress = OpenClawRunProgress()
        runProgress.attach(to: self.progress)
        let tracker = IntentRunSessionTracker(sessionKey: requestedSession)
        let options: LongRunningTaskOptions = host.prefersBackgroundGPU ? [.requiresGPU] : []
        do {
            let text = try await self.performBackgroundTask(
                options: options,
                operation: {
                    try await OpenClawIntentActions.ask(
                        prompt: prompt,
                        sessionKey: requestedSession,
                        agentId: agentId,
                        host: host,
                        progress: runProgress,
                        onEvent: { event in tracker.observe(event) })
                },
                onCancel: { _ in
                    guard let sessionKey = tracker.sessionKey else { return }
                    // The cancelled intent must not cancel its own cleanup: the abort helper sends
                    // chat.abort through CancellationShieldSupport so the gateway run actually stops.
                    Task { await OpenClawIntentActions.abort(sessionKey: sessionKey, host: host) }
                })
            return .result(value: text)
        } catch {
            throw OpenClawIntentError.presentable(error)
        }
    }
}
#endif

/// Remembers the session a run resolved to, so cancel handlers can abort it.
final class IntentRunSessionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var resolvedSessionKey: String?

    init(sessionKey: String?) {
        self.resolvedSessionKey = sessionKey
    }

    var sessionKey: String? {
        self.lock.withLock { self.resolvedSessionKey }
    }

    func observe(_ event: OpenClawIntentRunEvent) {
        guard let key = event.sessionKey, !key.isEmpty else { return }
        self.lock.withLock { self.resolvedSessionKey = key }
    }
}
