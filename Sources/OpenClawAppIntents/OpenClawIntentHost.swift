import Foundation
import OpenClawKit
#if canImport(AppIntents)
import AppIntents
#endif

/// Session row surfaced to App Intents (Siri, Shortcuts, Spotlight).
public struct OpenClawIntentSessionSummary: Sendable, Hashable {
    /// Gateway session key (entity identifier).
    public var sessionKey: String
    /// Display title.
    public var title: String
    /// Owning agent id, when known.
    public var agentId: String?
    /// Last update time, when known.
    public var updatedAt: Date?
    /// Whether the session is a group or channel conversation.
    public var isGroup: Bool

    /// Creates a session summary.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - title: Display title.
    ///   - agentId: Owning agent id.
    ///   - updatedAt: Last update time.
    ///   - isGroup: Whether the session is shared with other people.
    public init(sessionKey: String, title: String, agentId: String? = nil, updatedAt: Date? = nil, isGroup: Bool = false) {
        self.sessionKey = sessionKey
        self.title = title
        self.agentId = agentId
        self.updatedAt = updatedAt
        self.isGroup = isGroup
    }
}

/// Agent row surfaced to App Intents.
public struct OpenClawIntentAgentSummary: Sendable, Hashable {
    /// Agent id (entity identifier).
    public var agentId: String
    /// Display name.
    public var displayName: String
    /// Optional emoji badge.
    public var emoji: String?

    /// Creates an agent summary.
    /// - Parameters:
    ///   - agentId: Agent id.
    ///   - displayName: Display name.
    ///   - emoji: Optional emoji badge.
    public init(agentId: String, displayName: String, emoji: String? = nil) {
        self.agentId = agentId
        self.displayName = displayName
        self.emoji = emoji
    }
}

/// Progress event of an intent-driven run.
public struct OpenClawIntentRunEvent: Sendable, Equatable {
    /// Run phase (shared with ``OpenClawRunProgress``).
    public typealias Phase = OpenClawRunPhase

    /// Current phase.
    public var phase: Phase
    /// Completed fraction (0...1), when known.
    public var fractionCompleted: Double?
    /// Assistant text so far (cumulative, not a delta), when any.
    public var text: String?
    /// Run id, once the backend assigned one.
    public var runId: String?
    /// Session key the run belongs to.
    public var sessionKey: String?

    /// Creates a run event.
    /// - Parameters:
    ///   - phase: Current phase.
    ///   - fractionCompleted: Completed fraction.
    ///   - text: Cumulative assistant text.
    ///   - runId: Run id.
    ///   - sessionKey: Session key.
    public init(phase: Phase, fractionCompleted: Double? = nil, text: String? = nil, runId: String? = nil, sessionKey: String? = nil) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted
        self.text = text
        self.runId = runId
        self.sessionKey = sessionKey
    }
}

/// File passed along with an intent prompt (for example an `IntentFile` from Siri or Shortcuts).
public struct OpenClawIntentAttachment: Sendable, Hashable {
    /// File contents.
    public var data: Data
    /// MIME type (`application/octet-stream` when unknown).
    public var mimeType: String
    /// File name.
    public var fileName: String

    /// Creates an attachment.
    /// - Parameters:
    ///   - data: File contents.
    ///   - mimeType: MIME type.
    ///   - fileName: File name.
    public init(data: Data, mimeType: String, fileName: String) {
        self.data = data
        self.mimeType = mimeType.isEmpty ? "application/octet-stream" : mimeType
        self.fileName = fileName
    }

    /// Whether the attachment is an image (sent as `type: "image"` to `chat.send`).
    public var isImage: Bool {
        self.mimeType.lowercased().hasPrefix("image/")
    }

    /// `chat.send` attachment payload (`type`, `mimeType`, `fileName`, base64 `content`).
    public var chatSendPayload: [String: AnyCodable] {
        [
            "type": AnyCodable(self.isImage ? "image" : "file"),
            "mimeType": AnyCodable(self.mimeType),
            "fileName": AnyCodable(self.fileName),
            "content": AnyCodable(self.data.base64EncodedString()),
        ]
    }
}

/// Backend that App Intents entities and intents call into.
///
/// Register one at launch with ``OpenClawAppIntents/configure(host:)``. The SDK ships
/// ``GatewayOpenClawIntentHost`` (gateway WebSocket) and ``EmbeddedOpenClawIntentHost`` (in-process
/// runtime); apps can also adapt their own model layer.
public protocol OpenClawIntentHost: Sendable {
    /// Sessions whose title matches `query` (all recent sessions when `query` is `nil`).
    /// - Parameters:
    ///   - query: Case-insensitive search text.
    ///   - limit: Maximum rows.
    /// - Returns: Matching sessions, most recent first.
    func sessions(matching query: String?, limit: Int) async throws -> [OpenClawIntentSessionSummary]

    /// Sessions for specific keys (entity resolution).
    /// - Parameter keys: Session keys.
    /// - Returns: Sessions that could be resolved.
    func sessions(forKeys keys: [String]) async throws -> [OpenClawIntentSessionSummary]

    /// Selectable agents.
    /// - Returns: Agents in display order.
    func agents() async throws -> [OpenClawIntentAgentSummary]

    /// Sends a prompt and streams run progress until a terminal phase.
    /// - Parameters:
    ///   - prompt: User prompt.
    ///   - sessionKey: Target session, or `nil` for the host default.
    ///   - agentId: Target agent, or `nil` for the default agent.
    /// - Returns: Stream of run events; it finishes after the terminal event or throws on failure.
    func send(prompt: String, sessionKey: String?, agentId: String?) async throws -> AsyncThrowingStream<OpenClawIntentRunEvent, any Error>

    /// Sends a prompt with attachments and streams run progress until a terminal phase.
    /// - Parameters:
    ///   - prompt: User prompt.
    ///   - sessionKey: Target session, or `nil` for the host default.
    ///   - agentId: Target agent, or `nil` for the default agent.
    ///   - attachments: Files to send with the prompt.
    /// - Returns: Stream of run events.
    func send(
        prompt: String,
        sessionKey: String?,
        agentId: String?,
        attachments: [OpenClawIntentAttachment]) async throws -> AsyncThrowingStream<OpenClawIntentRunEvent, any Error>

    /// Aborts the active run of a session (best effort).
    /// - Parameter sessionKey: Session key.
    func abort(sessionKey: String) async

    /// Starts talk (live voice) mode in the app.
    /// - Parameter sessionKey: Session to talk in, or `nil` for the current one.
    func startTalk(sessionKey: String?) async throws

    /// Whether long-running (OS 27) intent runs need background GPU time, for example embedded runs
    /// on local models. Requires the continued-processing GPU entitlement.
    var prefersBackgroundGPU: Bool { get }
}

extension OpenClawIntentHost {
    /// Default: no background GPU.
    public var prefersBackgroundGPU: Bool { false }

    /// Default: attachments are not supported and are dropped.
    public func send(
        prompt: String,
        sessionKey: String?,
        agentId: String?,
        attachments: [OpenClawIntentAttachment]) async throws -> AsyncThrowingStream<OpenClawIntentRunEvent, any Error>
    {
        try await self.send(prompt: prompt, sessionKey: sessionKey, agentId: agentId)
    }

    /// Default: talk mode is not supported by this host.
    public func startTalk(sessionKey: String?) async throws {
        throw OpenClawIntentError.unsupported("Live voice is not available in this app.")
    }
}

/// Host used before ``OpenClawAppIntents/configure(host:)`` ran: every call fails with
/// ``OpenClawIntentError/hostNotConfigured``.
public struct UnconfiguredOpenClawIntentHost: OpenClawIntentHost {
    /// Creates the placeholder host.
    public init() {}

    /// Throws ``OpenClawIntentError/hostNotConfigured``.
    public func sessions(matching query: String?, limit: Int) async throws -> [OpenClawIntentSessionSummary] {
        throw OpenClawIntentError.hostNotConfigured
    }

    /// Throws ``OpenClawIntentError/hostNotConfigured``.
    public func sessions(forKeys keys: [String]) async throws -> [OpenClawIntentSessionSummary] {
        throw OpenClawIntentError.hostNotConfigured
    }

    /// Throws ``OpenClawIntentError/hostNotConfigured``.
    public func agents() async throws -> [OpenClawIntentAgentSummary] {
        throw OpenClawIntentError.hostNotConfigured
    }

    /// Throws ``OpenClawIntentError/hostNotConfigured``.
    public func send(prompt: String, sessionKey: String?, agentId: String?) async throws
        -> AsyncThrowingStream<OpenClawIntentRunEvent, any Error>
    {
        throw OpenClawIntentError.hostNotConfigured
    }

    /// Does nothing.
    public func abort(sessionKey: String) async {}

    /// Throws ``OpenClawIntentError/hostNotConfigured``.
    public func startTalk(sessionKey: String?) async throws {
        throw OpenClawIntentError.hostNotConfigured
    }
}

extension OpenClawAppIntents {
    private static let hostStorage = IntentHostStorage()

    /// The configured intent host (``UnconfiguredOpenClawIntentHost`` until configured).
    public static var host: any OpenClawIntentHost {
        self.hostStorage.host
    }

    /// Registers the backend used by every OpenClaw entity query and intent.
    ///
    /// Call once at launch, before the system can run intents (for example in the `App` initializer).
    /// The host is registered with `AppDependencyManager.shared` so `@AppDependency` resolves it in
    /// every intent, and stored for SDK helpers that run outside App Intents.
    /// - Parameter host: Intent backend.
    public static func configure(host: any OpenClawIntentHost) {
        self.hostStorage.host = host
        #if canImport(AppIntents)
        AppDependencyManager.shared.add(dependency: host)
        #endif
    }

    /// Resets the configured host to the placeholder (tests).
    public static func resetHostForTesting() {
        self.hostStorage.host = UnconfiguredOpenClawIntentHost()
    }
}

private final class IntentHostStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: any OpenClawIntentHost = UnconfiguredOpenClawIntentHost()

    var host: any OpenClawIntentHost {
        get { self.lock.withLock { self.storage } }
        set { self.lock.withLock { self.storage = newValue } }
    }
}
