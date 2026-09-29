import Foundation

// OpenClawKit-owned gateway payloads.
//
// Everything in this file is SDK-local: these types back the in-process `GatewayServer`
// (OpenClawGateway) and the typed `GatewayClient` helpers. They are NOT generated from upstream
// OpenClaw and must never share a name with a type in the vendored GatewayModels.swift
// (Scripts/protocol-gen-swift.mjs enforces this with a collision guard).
//
// Overlapping upstream (OpenClaw 2026.9.6) equivalents, for callers that talk to a real gateway:
// - GatewayAgentRequest            <-> AgentParams (`agent`); the server also accepts AgentParams.
// - GatewayAgentAccepted           <-> `agent` accepted payload `{ runId, status, sessionKey, agentId, acceptedAt }`.
// - GatewayAgentWaitParams/Result  <-> AgentWaitParams (`agent.wait`, wire key `runId`; `startedAt`/`endedAt`).
// - GatewaySessionInfo             <-> SessionRow (rows carry both the legacy and the upstream keys).
// - GatewaySessionPatchParams      <-> SessionsPatchParams (`model`/`agentId` aliases are accepted).
// - GatewaySessionKeyParams        <-> SessionsResetParams / SessionsDeleteParams.
// - GatewaySessionMutationResult   <-> SessionsPatchResult / SessionsDeleteResult (`entry`, `archived`).
// - ChatEventFrame                 <-> the ChatEvent union (`chat` events, protocol v4).
// - GatewayModelsListResult        <-> ModelsListResult (`models.list` rows also carry ModelChoice keys).
// - GatewaySecret*                 <-> SecretsStore* (`secrets.store.*`); `secrets.*` stay SDK extensions.
// - GatewaySkill*                  <-> no core equivalent (`skills.list`/`skills.invoke` are SDK extensions).
// - GatewayBrowserRequestParams    <-> extensions/browser `browser.request` (plugin-owned upstream).

/// Empty request or response payload (`{}`).
public struct EmptyPayload: Codable, Sendable, Equatable {
    /// Creates an empty payload marker.
    public init() {}
}

/// JSON bridge used for encoding and decoding typed gateway payloads through `AnyCodable`.
public enum GatewayPayloadCodec {
    /// Encodes a typed payload into an `AnyCodable` JSON wrapper.
    /// - Parameter value: Encodable payload value.
    /// - Returns: Type-erased JSON payload.
    public static func encode<T: Encodable>(_ value: T) throws -> AnyCodable {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    /// Decodes a typed payload from an `AnyCodable` request/response payload.
    /// - Parameters:
    ///   - type: Target payload type.
    ///   - payload: Type-erased JSON payload.
    /// - Returns: Decoded typed payload.
    public static func decode<T: Decodable>(_ type: T.Type, from payload: AnyCodable?) throws -> T {
        let decoder = JSONDecoder()
        if let payload {
            let data = try JSONEncoder().encode(payload)
            return try decoder.decode(type, from: data)
        }
        if let emptyObject = "{}".data(using: .utf8), let decoded = try? decoder.decode(type, from: emptyObject) {
            return decoded
        }
        let nullPayload = Data("null".utf8)
        return try decoder.decode(type, from: nullPayload)
    }
}

/// Request payload for in-process agent execution.
///
/// The legacy SDK keys (`sessionKey`, `prompt`, `message`, `modelProviderID`, `modelID`,
/// `timeoutMs`, `deliver`) keep their spelling. Fields added in 2026.3.0 mirror upstream
/// `AgentParams` and use its wire keys (`agentId`, `sessionId`, `idempotencyKey`, …); the in-process
/// server fills them when an upstream-shaped `agent` request arrives.
public struct GatewayAgentRequest: Codable, Sendable, Equatable {
    /// Session key the run belongs to (upstream `sessionKey`, defaulting to `main`).
    public let sessionKey: String
    /// Legacy SDK prompt text.
    ///
    /// Deprecated in 2026.3.0: send `message` (upstream `AgentParams.message`) instead.
    public let prompt: String?
    /// User message text.
    public let message: String?
    /// Model provider override (upstream `provider`).
    public let modelProviderID: String?
    /// Model override (upstream `model`).
    public let modelID: String?
    /// Run timeout in milliseconds (upstream `timeout` is seconds and is converted).
    public let timeoutMs: Int?
    /// Channel delivery flag (accepted, ignored by the embedded runtime).
    public let deliver: Bool?
    /// Agent identifier (upstream `agentId`).
    public let agentID: String?
    /// Explicit transcript session identifier (upstream `sessionId`).
    public let sessionID: String?
    /// Thinking level override (upstream `thinking`).
    public let thinking: String?
    /// Extra system prompt appended for this run (upstream `extraSystemPrompt`).
    public let extraSystemPrompt: String?
    /// Session label to apply (upstream `label`).
    public let label: String?
    /// Prompt mode (`full`, `minimal` or `none`; upstream `promptMode`).
    public let promptMode: String?
    /// Bootstrap context mode (`full` or `lightweight`; upstream `bootstrapContextMode`).
    public let bootstrapContextMode: String?
    /// Working directory for the run (upstream `cwd`).
    public let cwd: String?
    /// Raw upstream attachments (upstream `attachments`).
    public let attachments: [AnyCodable]?
    /// Idempotency key: a retry with the same key returns the same run (upstream `idempotencyKey`).
    public let idempotencyKey: String?

    /// Creates an agent request.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - prompt: Legacy prompt text.
    ///   - message: User message text.
    ///   - modelProviderID: Model provider override.
    ///   - modelID: Model override.
    ///   - timeoutMs: Run timeout in milliseconds.
    ///   - deliver: Channel delivery flag.
    ///   - agentID: Agent identifier.
    ///   - sessionID: Explicit transcript session identifier.
    ///   - thinking: Thinking level override.
    ///   - extraSystemPrompt: Extra system prompt for this run.
    ///   - label: Session label.
    ///   - promptMode: Prompt mode.
    ///   - bootstrapContextMode: Bootstrap context mode.
    ///   - cwd: Working directory.
    ///   - attachments: Raw attachments.
    ///   - idempotencyKey: Idempotency key.
    public init(
        sessionKey: String,
        prompt: String? = nil,
        message: String? = nil,
        modelProviderID: String? = nil,
        modelID: String? = nil,
        timeoutMs: Int? = nil,
        deliver: Bool? = nil,
        agentID: String? = nil,
        sessionID: String? = nil,
        thinking: String? = nil,
        extraSystemPrompt: String? = nil,
        label: String? = nil,
        promptMode: String? = nil,
        bootstrapContextMode: String? = nil,
        cwd: String? = nil,
        attachments: [AnyCodable]? = nil,
        idempotencyKey: String? = nil
    ) {
        self.sessionKey = sessionKey
        self.prompt = prompt
        self.message = message
        self.modelProviderID = modelProviderID
        self.modelID = modelID
        self.timeoutMs = timeoutMs
        self.deliver = deliver
        self.agentID = agentID
        self.sessionID = sessionID
        self.thinking = thinking
        self.extraSystemPrompt = extraSystemPrompt
        self.label = label
        self.promptMode = promptMode
        self.bootstrapContextMode = bootstrapContextMode
        self.cwd = cwd
        self.attachments = attachments
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case sessionKey
        case prompt
        case message
        case modelProviderID
        case modelID
        case timeoutMs
        case deliver
        case agentID = "agentId"
        case sessionID = "sessionId"
        case thinking
        case extraSystemPrompt
        case label
        case promptMode
        case bootstrapContextMode
        case cwd
        case attachments
        case idempotencyKey
    }

    /// The run text: ``message`` when present, otherwise the legacy ``prompt``.
    public var text: String? {
        let candidates = [self.message, self.prompt]
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

/// Accepted gateway response for an agent run.
///
/// Encodes the upstream wire keys (`runId`, `status`, `sessionKey`, `agentId`, `acceptedAt`);
/// decoding also accepts the legacy SDK key `runID`.
public struct GatewayAgentAccepted: Codable, Sendable, Equatable {
    /// Identifier of the started run, used with `agent.wait`.
    public let runID: String
    /// Acceptance status (`accepted`).
    public let status: String
    /// Session key of the run.
    public let sessionKey: String?
    /// Agent that owns the run.
    public let agentID: String?
    /// Acceptance time (epoch milliseconds).
    public let acceptedAt: Int64?

    /// Creates an accepted-run payload.
    /// - Parameters:
    ///   - runID: Identifier of the started run.
    ///   - status: Acceptance status.
    ///   - sessionKey: Session key of the run.
    ///   - agentID: Agent that owns the run.
    ///   - acceptedAt: Acceptance time in epoch milliseconds.
    public init(runID: String, status: String = "accepted", sessionKey: String? = nil, agentID: String? = nil, acceptedAt: Int64? = nil) {
        self.runID = runID
        self.status = status
        self.sessionKey = sessionKey
        self.agentID = agentID
        self.acceptedAt = acceptedAt
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case status
        case sessionKey
        case agentID = "agentId"
        case acceptedAt
    }

    /// Decodes the payload, accepting both `runId` and the legacy `runID` key.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runID = try GatewayLegacyRunIDKey.decodeRunID(from: decoder, container: container, key: .runID)
        self.status = try container.decode(String.self, forKey: .status)
        self.sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
        self.agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
        self.acceptedAt = GatewayCompatDecoding.int64(container, .acceptedAt)
    }
}

/// Wait request payload for an in-flight agent run.
///
/// Encodes the upstream `AgentWaitParams` wire keys (`runId`, `timeoutMs`); decoding also accepts `runID`.
public struct GatewayAgentWaitParams: Codable, Sendable, Equatable {
    /// Identifier of the run to wait for.
    public let runID: String
    /// Optional wait timeout in milliseconds.
    public let timeoutMs: Int?

    /// Creates a wait request.
    /// - Parameters:
    ///   - runID: Identifier of the run to wait for.
    ///   - timeoutMs: Optional wait timeout in milliseconds.
    public init(runID: String, timeoutMs: Int? = nil) {
        self.runID = runID
        self.timeoutMs = timeoutMs
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case timeoutMs
    }

    /// Decodes the payload, accepting both `runId` and the legacy `runID` key.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runID = try GatewayLegacyRunIDKey.decodeRunID(from: decoder, container: container, key: .runID)
        self.timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
    }
}

/// Completion payload for an agent run wait request.
///
/// Encodes the upstream `agent.wait` wire keys (`runId`, `status`, `startedAt`, `endedAt`, `error`);
/// `sessionKey` and `output` are SDK extras. Decoding also accepts the legacy SDK key `runID`.
public struct GatewayAgentWaitResult: Codable, Sendable, Equatable {
    /// Identifier of the run.
    public let runID: String
    /// Terminal or interim status (`ok`, `error`, `timeout`).
    public let status: String
    /// Session key the run belongs to.
    public let sessionKey: String?
    /// Final assistant output when the run succeeded.
    public let output: String?
    /// Error message when the run failed.
    public let error: String?
    /// Run start time (epoch milliseconds).
    public let startedAt: Int64?
    /// Run end time (epoch milliseconds); `nil` while the run is still active.
    public let endedAt: Int64?

    /// Creates a wait result.
    /// - Parameters:
    ///   - runID: Identifier of the run.
    ///   - status: Run status.
    ///   - sessionKey: Session key the run belongs to.
    ///   - output: Final assistant output.
    ///   - error: Error message.
    ///   - startedAt: Run start time in epoch milliseconds.
    ///   - endedAt: Run end time in epoch milliseconds.
    public init(
        runID: String,
        status: String,
        sessionKey: String? = nil,
        output: String? = nil,
        error: String? = nil,
        startedAt: Int64? = nil,
        endedAt: Int64? = nil
    ) {
        self.runID = runID
        self.status = status
        self.sessionKey = sessionKey
        self.output = output
        self.error = error
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case status
        case sessionKey
        case output
        case error
        case startedAt
        case endedAt
    }

    /// Decodes the payload, accepting both `runId` and the legacy `runID` key.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runID = try GatewayLegacyRunIDKey.decodeRunID(from: decoder, container: container, key: .runID)
        self.status = try container.decode(String.self, forKey: .status)
        self.sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
        self.output = try container.decodeIfPresent(String.self, forKey: .output)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.startedAt = GatewayCompatDecoding.int64(container, .startedAt)
        self.endedAt = GatewayCompatDecoding.int64(container, .endedAt)
    }

    /// Returns a copy with the run timestamps filled in when they are missing.
    /// - Parameters:
    ///   - startedAt: Run start time in epoch milliseconds.
    ///   - endedAt: Run end time in epoch milliseconds.
    /// - Returns: The completed result.
    public func stamped(startedAt: Int64?, endedAt: Int64?) -> GatewayAgentWaitResult {
        GatewayAgentWaitResult(
            runID: self.runID,
            status: self.status,
            sessionKey: self.sessionKey,
            output: self.output,
            error: self.error,
            startedAt: self.startedAt ?? startedAt,
            endedAt: self.endedAt ?? endedAt
        )
    }
}

/// Lenient decoding helpers for SDK-owned compat payloads.
enum GatewayCompatDecoding {
    /// Decodes an epoch-millisecond value that may arrive as an integer or a floating-point number.
    ///
    /// Fractions truncate toward zero; values outside `Int64` (including 2^63, which
    /// `Double(Int64.max)` rounds up to) answer `nil` instead of trapping.
    static func int64<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> Int64? {
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Self.int64(exactly: value)
        }
        return nil
    }

    /// Converts a wire number to `Int64` without trapping (truncating fractions; `nil` when out of range).
    static func int64(exactly value: Double) -> Int64? {
        guard value.isFinite else { return nil }
        return Int64(exactly: value.rounded(.towardZero))
    }

    /// Decodes a string, tolerating a type mismatch (returns `nil`).
    static func string<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> String? {
        try? container.decodeIfPresent(String.self, forKey: key)
    }

    /// Decodes a boolean, tolerating a type mismatch (returns `nil`).
    static func bool<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> Bool? {
        try? container.decodeIfPresent(Bool.self, forKey: key)
    }
}

/// Decoding helper for the legacy `runID` wire key used before OpenClawKit 2026.3.0.
private struct GatewayLegacyRunIDKey: CodingKey {
    static let legacy = GatewayLegacyRunIDKey(stringValue: "runID")

    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }

    static func decodeRunID<Key: CodingKey>(
        from decoder: Decoder,
        container: KeyedDecodingContainer<Key>,
        key: Key
    ) throws -> String {
        if let runID = try container.decodeIfPresent(String.self, forKey: key) {
            return runID
        }
        let legacy = try decoder.container(keyedBy: GatewayLegacyRunIDKey.self)
        return try legacy.decode(String.self, forKey: .legacy)
    }
}

/// Typed session summary returned by gateway session methods.
///
/// Encoding writes the legacy SDK keys (`agentID`, `updatedAtMs`, `accountID`, `peerID`,
/// `modelOverride`, …) and, for the same row, the upstream `SessionRow` keys (`agentId`,
/// `updatedAt`, `accountId`, `sessionId`, `kind`, `model`, `archived`, `pinned`, `unread`,
/// `permissionMode`, …), so both legacy SDK clients and upstream-shaped clients (ChatUI, Control UI)
/// decode it. Decoding accepts either spelling. Timestamps are epoch milliseconds (`Int64`).
public struct GatewaySessionInfo: Codable, Sendable, Equatable {
    /// Session key.
    public let key: String
    /// Agent bound to the session.
    public let agentID: String
    /// Last update time (epoch milliseconds).
    ///
    /// 2026.3.0: `Int64` (was `Int`, which trapped for millisecond timestamps on 32-bit watchOS).
    public let updatedAtMs: Int64
    /// Last route channel.
    public let channel: String?
    /// Last route account.
    public let accountID: String?
    /// Last route peer.
    public let peerID: String?
    /// Explicit session label.
    public let label: String?
    /// Model override (`provider/model`).
    public let modelOverride: String?
    /// Thinking level override.
    public let thinkingLevel: String?
    /// Verbose level override.
    public let verboseLevel: String?
    /// Reasoning visibility override.
    public let reasoningLevel: String?
    /// Response-usage display override.
    public let responseUsage: String?
    /// Elevated execution override.
    public let elevatedLevel: String?
    /// Group activation override.
    public let groupActivation: String?
    /// Outbound send policy override.
    public let sendPolicy: String?
    /// Execution host override.
    public let execHost: String?
    /// Retired execution security override (legacy rows only).
    public let execSecurity: String?
    /// Retired execution approval override (legacy rows only).
    public let execAsk: String?
    /// Execution node override.
    public let execNode: String?
    /// Transcript session identifier (upstream `sessionId`).
    public let sessionID: String?
    /// Upstream row kind (`direct`, `group`, `global` or `unknown`); derived from the key when `nil`.
    public let kind: String?
    /// Session permission mode (`read-only`, `guarded`, `workspace`, `full`).
    public let permissionMode: String?
    /// Sandbox containment override (`off`).
    public let sandboxMode: String?
    /// Trace level (`off`, `on`, `raw`).
    public let traceLevel: String?
    /// Fast-mode preference (`on`, `off` or `auto`; the wire form is `true`, `false` or `"auto"`).
    public let fastMode: String?
    /// Whether the session is archived.
    public let archived: Bool
    /// Whether the session is pinned.
    public let pinned: Bool
    /// Whether the session carries an explicit unread marker.
    public let unread: Bool
    /// Archive time (epoch milliseconds).
    public let archivedAtMs: Int64?
    /// Pin time (epoch milliseconds).
    public let pinnedAtMs: Int64?
    /// Explicit unread marker time (epoch milliseconds).
    public let markedUnreadAtMs: Int64?
    /// Last-read time (epoch milliseconds).
    public let lastReadAtMs: Int64?
    /// Creation time (epoch milliseconds).
    public let createdAtMs: Int64?
    /// Automatic label.
    public let autoLabel: String?
    /// Sidebar icon identifier.
    public let icon: String?
    /// Sidebar tint identifier.
    public let color: String?
    /// Organization group (upstream `category`; the group name of `sessions.groups.*`).
    public let category: String?
    /// Context-window override.
    public let contextWindow: String?
    /// Explicit agent runtime identifier (wire: `agentRuntime: {id}`).
    public let agentRuntime: String?
    /// Parent session key of a spawned session.
    public let spawnedBy: String?
    /// Spawn depth of a sub-agent session.
    public let spawnDepth: Int?
    /// Previous transcript session identifier after a reset (upstream `previousSessionId`).
    public let parentSessionID: String?
    /// Cumulative tokens used by the session.
    public let totalTokens: Int64?
    /// Sparse session tool overlay (`{mcpServers?, mcpToolsDeny?, skills?, webSearch?}`).
    public let toolOverrides: AnyCodable?

    /// Creates a session summary.
    /// - Parameters:
    ///   - key: Session key.
    ///   - agentID: Agent bound to the session.
    ///   - updatedAtMs: Last update time in epoch milliseconds.
    ///   - channel: Last route channel.
    ///   - accountID: Last route account.
    ///   - peerID: Last route peer.
    ///   - label: Explicit label.
    ///   - modelOverride: Model override.
    ///   - thinkingLevel: Thinking level override.
    ///   - verboseLevel: Verbose level override.
    ///   - reasoningLevel: Reasoning visibility override.
    ///   - responseUsage: Response-usage display override.
    ///   - elevatedLevel: Elevated execution override.
    ///   - groupActivation: Group activation override.
    ///   - sendPolicy: Send policy override.
    ///   - execHost: Execution host override.
    ///   - execSecurity: Retired execution security override.
    ///   - execAsk: Retired execution approval override.
    ///   - execNode: Execution node override.
    ///   - sessionID: Transcript session identifier.
    ///   - kind: Upstream row kind.
    ///   - permissionMode: Permission mode.
    ///   - sandboxMode: Sandbox override.
    ///   - traceLevel: Trace level.
    ///   - fastMode: Fast-mode preference.
    ///   - archived: Whether the session is archived.
    ///   - pinned: Whether the session is pinned.
    ///   - unread: Whether the session is marked unread.
    ///   - archivedAtMs: Archive time.
    ///   - pinnedAtMs: Pin time.
    ///   - markedUnreadAtMs: Unread marker time.
    ///   - lastReadAtMs: Last-read time.
    ///   - createdAtMs: Creation time.
    ///   - autoLabel: Automatic label.
    ///   - icon: Icon identifier.
    ///   - color: Tint identifier.
    ///   - category: Organization group.
    ///   - contextWindow: Context-window override.
    ///   - agentRuntime: Agent runtime identifier.
    ///   - spawnedBy: Parent session key.
    ///   - spawnDepth: Spawn depth.
    ///   - parentSessionID: Previous transcript session identifier.
    ///   - totalTokens: Cumulative tokens.
    ///   - toolOverrides: Tool overlay.
    public init(
        key: String,
        agentID: String,
        updatedAtMs: Int64,
        channel: String? = nil,
        accountID: String? = nil,
        peerID: String? = nil,
        label: String? = nil,
        modelOverride: String? = nil,
        thinkingLevel: String? = nil,
        verboseLevel: String? = nil,
        reasoningLevel: String? = nil,
        responseUsage: String? = nil,
        elevatedLevel: String? = nil,
        groupActivation: String? = nil,
        sendPolicy: String? = nil,
        execHost: String? = nil,
        execSecurity: String? = nil,
        execAsk: String? = nil,
        execNode: String? = nil,
        sessionID: String? = nil,
        kind: String? = nil,
        permissionMode: String? = nil,
        sandboxMode: String? = nil,
        traceLevel: String? = nil,
        fastMode: String? = nil,
        archived: Bool = false,
        pinned: Bool = false,
        unread: Bool = false,
        archivedAtMs: Int64? = nil,
        pinnedAtMs: Int64? = nil,
        markedUnreadAtMs: Int64? = nil,
        lastReadAtMs: Int64? = nil,
        createdAtMs: Int64? = nil,
        autoLabel: String? = nil,
        icon: String? = nil,
        color: String? = nil,
        category: String? = nil,
        contextWindow: String? = nil,
        agentRuntime: String? = nil,
        spawnedBy: String? = nil,
        spawnDepth: Int? = nil,
        parentSessionID: String? = nil,
        totalTokens: Int64? = nil,
        toolOverrides: AnyCodable? = nil
    ) {
        self.key = key
        self.agentID = agentID
        self.updatedAtMs = updatedAtMs
        self.channel = channel
        self.accountID = accountID
        self.peerID = peerID
        self.label = label
        self.modelOverride = modelOverride
        self.thinkingLevel = thinkingLevel
        self.verboseLevel = verboseLevel
        self.reasoningLevel = reasoningLevel
        self.responseUsage = responseUsage
        self.elevatedLevel = elevatedLevel
        self.groupActivation = groupActivation
        self.sendPolicy = sendPolicy
        self.execHost = execHost
        self.execSecurity = execSecurity
        self.execAsk = execAsk
        self.execNode = execNode
        self.sessionID = sessionID
        self.kind = kind
        self.permissionMode = permissionMode
        self.sandboxMode = sandboxMode
        self.traceLevel = traceLevel
        self.fastMode = fastMode
        self.archived = archived
        self.pinned = pinned
        self.unread = unread
        self.archivedAtMs = archivedAtMs
        self.pinnedAtMs = pinnedAtMs
        self.markedUnreadAtMs = markedUnreadAtMs
        self.lastReadAtMs = lastReadAtMs
        self.createdAtMs = createdAtMs
        self.autoLabel = autoLabel
        self.icon = icon
        self.color = color
        self.category = category
        self.contextWindow = contextWindow
        self.agentRuntime = agentRuntime
        self.spawnedBy = spawnedBy
        self.spawnDepth = spawnDepth
        self.parentSessionID = parentSessionID
        self.totalTokens = totalTokens
        self.toolOverrides = toolOverrides
    }

    /// Upstream row kind for a session key (`global`, `unknown`, `group` for group/channel peers,
    /// otherwise `direct`).
    /// - Parameter key: Session key.
    /// - Returns: The row kind.
    public static func kind(forKey key: String) -> String {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "global":
            return "global"
        case "unknown":
            return "unknown"
        default:
            let parts = normalized.split(separator: ":").map(String.init)
            return parts.contains("group") || parts.contains("channel") ? "group" : "direct"
        }
    }

    /// Resolved row kind (``kind`` or the key-derived default).
    public var resolvedKind: String {
        self.kind ?? Self.kind(forKey: self.key)
    }

    private enum LegacyKeys: String, CodingKey {
        case key, agentID, updatedAtMs, channel, accountID, peerID, label, modelOverride, thinkingLevel
        case verboseLevel, reasoningLevel, responseUsage, elevatedLevel, groupActivation, sendPolicy
        case execHost, execSecurity, execAsk, execNode
    }

    private enum UpstreamKeys: String, CodingKey {
        case agentID = "agentId"
        case updatedAt
        case accountID = "accountId"
        case sessionID = "sessionId"
        case kind
        case model
        case modelProvider
        case permissionMode
        case sandboxMode
        case traceLevel
        case fastMode
        case archived
        case pinned
        case unread
        case archivedAt
        case pinnedAt
        case markedUnreadAt
        case lastReadAt
        case createdAt
        case autoLabel
        case icon
        case color
        case category
        case contextWindow
        case agentRuntime
        case spawnedBy
        case spawnDepth
        case previousSessionID = "previousSessionId"
        case totalTokens
        case toolOverrides
    }

    private enum AgentRuntimeKeys: String, CodingKey {
        case id
    }

    /// Decodes a legacy SDK row or an upstream `SessionRow`.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let upstream = try decoder.container(keyedBy: UpstreamKeys.self)
        self.key = try legacy.decode(String.self, forKey: .key)
        self.agentID = GatewayCompatDecoding.string(legacy, .agentID) ?? GatewayCompatDecoding.string(upstream, .agentID) ?? "main"
        self.updatedAtMs = GatewayCompatDecoding.int64(legacy, .updatedAtMs) ?? GatewayCompatDecoding.int64(upstream, .updatedAt) ?? 0
        self.channel = GatewayCompatDecoding.string(legacy, .channel)
        self.accountID = GatewayCompatDecoding.string(legacy, .accountID) ?? GatewayCompatDecoding.string(upstream, .accountID)
        self.peerID = GatewayCompatDecoding.string(legacy, .peerID)
        self.label = GatewayCompatDecoding.string(legacy, .label)
        if let override = GatewayCompatDecoding.string(legacy, .modelOverride) {
            self.modelOverride = override
        } else if let model = GatewayCompatDecoding.string(upstream, .model) {
            let provider = GatewayCompatDecoding.string(upstream, .modelProvider)
            self.modelOverride = provider.map { model.hasPrefix("\($0)/") ? model : "\($0)/\(model)" } ?? model
        } else {
            self.modelOverride = nil
        }
        self.thinkingLevel = GatewayCompatDecoding.string(legacy, .thinkingLevel)
        self.verboseLevel = GatewayCompatDecoding.string(legacy, .verboseLevel)
        self.reasoningLevel = GatewayCompatDecoding.string(legacy, .reasoningLevel)
        self.responseUsage = GatewayCompatDecoding.string(legacy, .responseUsage)
        self.elevatedLevel = GatewayCompatDecoding.string(legacy, .elevatedLevel)
        self.groupActivation = GatewayCompatDecoding.string(legacy, .groupActivation)
        self.sendPolicy = GatewayCompatDecoding.string(legacy, .sendPolicy)
        self.execHost = GatewayCompatDecoding.string(legacy, .execHost)
        self.execSecurity = GatewayCompatDecoding.string(legacy, .execSecurity)
        self.execAsk = GatewayCompatDecoding.string(legacy, .execAsk)
        self.execNode = GatewayCompatDecoding.string(legacy, .execNode)
        self.sessionID = GatewayCompatDecoding.string(upstream, .sessionID)
        self.kind = GatewayCompatDecoding.string(upstream, .kind)
        self.permissionMode = GatewayCompatDecoding.string(upstream, .permissionMode)
        self.sandboxMode = GatewayCompatDecoding.string(upstream, .sandboxMode)
        self.traceLevel = GatewayCompatDecoding.string(upstream, .traceLevel)
        if let flag = GatewayCompatDecoding.bool(upstream, .fastMode) {
            self.fastMode = flag ? "on" : "off"
        } else {
            self.fastMode = GatewayCompatDecoding.string(upstream, .fastMode)
        }
        self.archivedAtMs = GatewayCompatDecoding.int64(upstream, .archivedAt)
        self.pinnedAtMs = GatewayCompatDecoding.int64(upstream, .pinnedAt)
        self.markedUnreadAtMs = GatewayCompatDecoding.int64(upstream, .markedUnreadAt)
        self.lastReadAtMs = GatewayCompatDecoding.int64(upstream, .lastReadAt)
        self.createdAtMs = GatewayCompatDecoding.int64(upstream, .createdAt)
        self.archived = GatewayCompatDecoding.bool(upstream, .archived) ?? (self.archivedAtMs != nil)
        self.pinned = GatewayCompatDecoding.bool(upstream, .pinned) ?? (self.pinnedAtMs != nil)
        self.unread = GatewayCompatDecoding.bool(upstream, .unread) ?? false
        self.autoLabel = GatewayCompatDecoding.string(upstream, .autoLabel)
        self.icon = GatewayCompatDecoding.string(upstream, .icon)
        self.color = GatewayCompatDecoding.string(upstream, .color)
        self.category = GatewayCompatDecoding.string(upstream, .category)
        self.contextWindow = GatewayCompatDecoding.string(upstream, .contextWindow)
        if let runtime = GatewayCompatDecoding.string(upstream, .agentRuntime) {
            self.agentRuntime = runtime
        } else if let nested = try? upstream.nestedContainer(keyedBy: AgentRuntimeKeys.self, forKey: .agentRuntime) {
            self.agentRuntime = GatewayCompatDecoding.string(nested, .id)
        } else {
            self.agentRuntime = nil
        }
        self.spawnedBy = GatewayCompatDecoding.string(upstream, .spawnedBy)
        if let depth = GatewayCompatDecoding.int64(upstream, .spawnDepth) {
            self.spawnDepth = Int(exactly: depth)
        } else {
            self.spawnDepth = nil
        }
        self.parentSessionID = GatewayCompatDecoding.string(upstream, .previousSessionID)
        self.totalTokens = GatewayCompatDecoding.int64(upstream, .totalTokens)
        self.toolOverrides = try? upstream.decodeIfPresent(AnyCodable.self, forKey: .toolOverrides)
    }

    /// Encodes the legacy SDK keys and the upstream `SessionRow` keys.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var legacy = encoder.container(keyedBy: LegacyKeys.self)
        try legacy.encode(self.key, forKey: .key)
        try legacy.encode(self.agentID, forKey: .agentID)
        try legacy.encode(self.updatedAtMs, forKey: .updatedAtMs)
        try legacy.encodeIfPresent(self.channel, forKey: .channel)
        try legacy.encodeIfPresent(self.accountID, forKey: .accountID)
        try legacy.encodeIfPresent(self.peerID, forKey: .peerID)
        try legacy.encodeIfPresent(self.label, forKey: .label)
        try legacy.encodeIfPresent(self.modelOverride, forKey: .modelOverride)
        try legacy.encodeIfPresent(self.thinkingLevel, forKey: .thinkingLevel)
        try legacy.encodeIfPresent(self.verboseLevel, forKey: .verboseLevel)
        try legacy.encodeIfPresent(self.reasoningLevel, forKey: .reasoningLevel)
        try legacy.encodeIfPresent(self.responseUsage, forKey: .responseUsage)
        try legacy.encodeIfPresent(self.elevatedLevel, forKey: .elevatedLevel)
        try legacy.encodeIfPresent(self.groupActivation, forKey: .groupActivation)
        try legacy.encodeIfPresent(self.sendPolicy, forKey: .sendPolicy)
        try legacy.encodeIfPresent(self.execHost, forKey: .execHost)
        try legacy.encodeIfPresent(self.execSecurity, forKey: .execSecurity)
        try legacy.encodeIfPresent(self.execAsk, forKey: .execAsk)
        try legacy.encodeIfPresent(self.execNode, forKey: .execNode)

        var upstream = encoder.container(keyedBy: UpstreamKeys.self)
        try upstream.encode(self.agentID, forKey: .agentID)
        try upstream.encode(self.updatedAtMs, forKey: .updatedAt)
        try upstream.encodeIfPresent(self.accountID, forKey: .accountID)
        try upstream.encodeIfPresent(self.sessionID, forKey: .sessionID)
        try upstream.encode(self.resolvedKind, forKey: .kind)
        if let modelOverride {
            let parts = modelOverride.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                try upstream.encode(parts[0], forKey: .modelProvider)
                try upstream.encode(parts[1], forKey: .model)
            } else {
                try upstream.encode(modelOverride, forKey: .model)
            }
        }
        try upstream.encodeIfPresent(self.permissionMode, forKey: .permissionMode)
        try upstream.encodeIfPresent(self.sandboxMode, forKey: .sandboxMode)
        try upstream.encodeIfPresent(self.traceLevel, forKey: .traceLevel)
        switch self.fastMode {
        case "on":
            try upstream.encode(true, forKey: .fastMode)
        case "off":
            try upstream.encode(false, forKey: .fastMode)
        case "auto":
            try upstream.encode("auto", forKey: .fastMode)
        default:
            break
        }
        try upstream.encode(self.archived, forKey: .archived)
        try upstream.encode(self.pinned, forKey: .pinned)
        try upstream.encode(self.unread, forKey: .unread)
        try upstream.encodeIfPresent(self.archivedAtMs, forKey: .archivedAt)
        try upstream.encodeIfPresent(self.pinnedAtMs, forKey: .pinnedAt)
        try upstream.encodeIfPresent(self.markedUnreadAtMs, forKey: .markedUnreadAt)
        try upstream.encodeIfPresent(self.lastReadAtMs, forKey: .lastReadAt)
        try upstream.encodeIfPresent(self.createdAtMs, forKey: .createdAt)
        try upstream.encodeIfPresent(self.autoLabel, forKey: .autoLabel)
        try upstream.encodeIfPresent(self.icon, forKey: .icon)
        try upstream.encodeIfPresent(self.color, forKey: .color)
        try upstream.encodeIfPresent(self.category, forKey: .category)
        try upstream.encodeIfPresent(self.contextWindow, forKey: .contextWindow)
        if let agentRuntime {
            var nested = upstream.nestedContainer(keyedBy: AgentRuntimeKeys.self, forKey: .agentRuntime)
            try nested.encode(agentRuntime, forKey: .id)
        }
        try upstream.encodeIfPresent(self.spawnedBy, forKey: .spawnedBy)
        try upstream.encodeIfPresent(self.spawnDepth, forKey: .spawnDepth)
        try upstream.encodeIfPresent(self.parentSessionID, forKey: .previousSessionID)
        try upstream.encodeIfPresent(self.totalTokens, forKey: .totalTokens)
        try upstream.encodeIfPresent(self.toolOverrides, forKey: .toolOverrides)
    }
}

/// List response for gateway session enumeration.
public struct GatewaySessionListResult: Codable, Sendable, Equatable {
    public let sessions: [GatewaySessionInfo]

    public init(sessions: [GatewaySessionInfo]) {
        self.sessions = sessions
    }
}

/// Lookup request for one session.
public struct GatewaySessionGetParams: Codable, Sendable, Equatable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

/// Lookup response for one session.
public struct GatewaySessionGetResult: Codable, Sendable, Equatable {
    public let session: GatewaySessionInfo?

    public init(session: GatewaySessionInfo?) {
        self.session = session
    }
}

/// Patch request for session mutation.
public struct GatewaySessionPatchParams: Codable, Sendable, Equatable {
    public let key: String
    public let agentID: String?
    public let label: String?
    public let modelOverride: String?
    public let thinkingLevel: String?
    public let verboseLevel: String?
    public let reasoningLevel: String?
    public let responseUsage: String?
    public let elevatedLevel: String?
    public let groupActivation: String?
    public let sendPolicy: String?
    public let execHost: String?
    public let execSecurity: String?
    public let execAsk: String?
    public let execNode: String?

    public init(
        key: String,
        agentID: String? = nil,
        label: String? = nil,
        modelOverride: String? = nil,
        thinkingLevel: String? = nil,
        verboseLevel: String? = nil,
        reasoningLevel: String? = nil,
        responseUsage: String? = nil,
        elevatedLevel: String? = nil,
        groupActivation: String? = nil,
        sendPolicy: String? = nil,
        execHost: String? = nil,
        execSecurity: String? = nil,
        execAsk: String? = nil,
        execNode: String? = nil
    ) {
        self.key = key
        self.agentID = agentID
        self.label = label
        self.modelOverride = modelOverride
        self.thinkingLevel = thinkingLevel
        self.verboseLevel = verboseLevel
        self.reasoningLevel = reasoningLevel
        self.responseUsage = responseUsage
        self.elevatedLevel = elevatedLevel
        self.groupActivation = groupActivation
        self.sendPolicy = sendPolicy
        self.execHost = execHost
        self.execSecurity = execSecurity
        self.execAsk = execAsk
        self.execNode = execNode
    }
}

/// Session key payload used by reset/delete methods.
public struct GatewaySessionKeyParams: Codable, Sendable, Equatable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

/// Mutation response for gateway session operations.
///
/// Carries the legacy SDK `session` summary plus the upstream keys: `entry` (the full session row
/// as an object, kept for compatibility with 2026.3.0 pre-releases that returned the raw record)
/// and `archived` (`sessions.delete`, upstream `SessionsDeleteResult`).
public struct GatewaySessionMutationResult: Codable, Sendable, Equatable {
    /// Whether the mutation succeeded.
    public let ok: Bool
    /// Session key.
    public let key: String
    /// Updated session summary.
    public let session: GatewaySessionInfo?
    /// Whether a session was deleted (`sessions.delete`).
    public let deleted: Bool?
    /// Full session row object (upstream `entry`).
    public let entry: AnyCodable?
    /// Keys whose transcripts were archived by the mutation (upstream `SessionsDeleteResult.archived`).
    public let archived: [String]?

    /// Creates a mutation result.
    /// - Parameters:
    ///   - ok: Whether the mutation succeeded.
    ///   - key: Session key.
    ///   - session: Updated session summary.
    ///   - deleted: Whether a session was deleted.
    ///   - entry: Full session row object.
    ///   - archived: Archived transcript keys.
    public init(
        ok: Bool = true,
        key: String,
        session: GatewaySessionInfo? = nil,
        deleted: Bool? = nil,
        entry: AnyCodable? = nil,
        archived: [String]? = nil
    ) {
        self.ok = ok
        self.key = key
        self.session = session
        self.deleted = deleted
        self.entry = entry
        self.archived = archived
    }
}

/// Protocol-v4 `chat` event payload: the upstream `ChatEventSchema` union keyed on `state`.
///
/// Wraps the generated `ChatStatusEvent`, `ChatDeltaEvent`, `ChatFinalEvent`, `ChatAbortedEvent` and
/// `ChatErrorEvent` models. States this SDK version does not know (or members whose fields do not
/// match the generated model) decode as ``unknown(state:payload:)`` instead of failing the frame.
///
/// v4 semantics: `delta` frames carry `deltaText` to append (or, with `replace: true`, the full
/// buffer) plus an optional full `message` snapshot; terminal frames (`final`, `aborted`, `error`)
/// carry `stopReason`, `yielded` (final) and `errorMessage`/`errorKind`/`errorDetail` (error).
public enum ChatEventFrame: Codable, Sendable {
    /// Transient startup status (non-terminal).
    case status(ChatStatusEvent)
    /// Incremental assistant output.
    case delta(ChatDeltaEvent)
    /// Successful terminal event.
    case final(ChatFinalEvent)
    /// Cancellation terminal event.
    case aborted(ChatAbortedEvent)
    /// Failure terminal event.
    case error(ChatErrorEvent)
    /// A state (or member shape) this SDK version does not decode.
    case unknown(state: String, payload: [String: AnyCodable])

    /// Wire `state` discriminator.
    public var state: String {
        switch self {
        case .status: return "status"
        case .delta: return "delta"
        case .final: return "final"
        case .aborted: return "aborted"
        case .error: return "error"
        case .unknown(let state, _): return state
        }
    }

    /// Run identifier (`runId`).
    public var runID: String? {
        switch self {
        case .status(let event): return event.runid
        case .delta(let event): return event.runid
        case .final(let event): return event.runid
        case .aborted(let event): return event.runid
        case .error(let event): return event.runid
        case .unknown(_, let payload): return payload["runId"]?.stringValue
        }
    }

    /// Session key (`sessionKey`).
    public var sessionKey: String? {
        switch self {
        case .status(let event): return event.sessionkey
        case .delta(let event): return event.sessionkey
        case .final(let event): return event.sessionkey
        case .aborted(let event): return event.sessionkey
        case .error(let event): return event.sessionkey
        case .unknown(_, let payload): return payload["sessionKey"]?.stringValue
        }
    }

    /// Event sequence number (`seq`).
    public var seq: Int? {
        switch self {
        case .status(let event): return event.seq
        case .delta(let event): return event.seq
        case .final(let event): return event.seq
        case .aborted(let event): return event.seq
        case .error(let event): return event.seq
        case .unknown(_, let payload): return payload["seq"]?.intValue
        }
    }

    /// Whether the event ends the run (`final`, `aborted`, `error`).
    public var isTerminal: Bool {
        switch self {
        case .final, .aborted, .error: return true
        case .status, .delta, .unknown: return false
        }
    }

    /// Decodes the union by its `state` discriminator.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let raw = try [String: AnyCodable](from: decoder)
        let state = raw["state"]?.stringValue ?? ""
        let payload = AnyCodable(raw)
        func typed<T: Decodable>(_ type: T.Type) -> T? {
            try? GatewayPayloadCodec.decode(type, from: payload)
        }
        switch state {
        case "status":
            self = typed(ChatStatusEvent.self).map(ChatEventFrame.status) ?? .unknown(state: state, payload: raw)
        case "delta":
            self = typed(ChatDeltaEvent.self).map(ChatEventFrame.delta) ?? .unknown(state: state, payload: raw)
        case "final":
            self = typed(ChatFinalEvent.self).map(ChatEventFrame.final) ?? .unknown(state: state, payload: raw)
        case "aborted":
            self = typed(ChatAbortedEvent.self).map(ChatEventFrame.aborted) ?? .unknown(state: state, payload: raw)
        case "error":
            self = typed(ChatErrorEvent.self).map(ChatEventFrame.error) ?? .unknown(state: state, payload: raw)
        default:
            self = .unknown(state: state, payload: raw)
        }
    }

    /// Encodes the wrapped union member.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .status(let event): try event.encode(to: encoder)
        case .delta(let event): try event.encode(to: encoder)
        case .final(let event): try event.encode(to: encoder)
        case .aborted(let event): try event.encode(to: encoder)
        case .error(let event): try event.encode(to: encoder)
        case .unknown(_, let payload): try payload.encode(to: encoder)
        }
    }

    /// Decodes a `chat` event frame payload.
    /// - Parameter payload: `EventFrame.payload` of a `chat` event.
    /// - Throws: `DecodingError` when the payload is not an object.
    public init(payload: AnyCodable?) throws {
        self = try GatewayPayloadCodec.decode(ChatEventFrame.self, from: payload)
    }

    /// The event as an `EventFrame` payload.
    /// - Returns: JSON payload.
    /// - Throws: Encoding errors.
    public func payload() throws -> AnyCodable {
        try GatewayPayloadCodec.encode(self)
    }

    /// Assistant message snapshot used by `delta` and terminal frames:
    /// `{role: "assistant", content: [{type: "text", text}], timestamp}`.
    /// - Parameters:
    ///   - text: Visible assistant text.
    ///   - timestampMs: Message time in epoch milliseconds.
    /// - Returns: The message object.
    public static func assistantMessage(text: String, timestampMs: Int64) -> AnyCodable {
        AnyCodable([
            "role": AnyCodable("assistant"),
            "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable(text)])]),
            "timestamp": AnyCodable(timestampMs),
        ])
    }

    /// Computes the v4 delta for a new buffer: the appended suffix, or the full text with
    /// `replace: true` when the new buffer does not extend the previously broadcast one.
    /// - Parameters:
    ///   - text: Full buffered text.
    ///   - previous: Previously broadcast text.
    /// - Returns: `nil` when nothing changed.
    public static func broadcastDelta(text: String, previous: String) -> (deltaText: String, replace: Bool)? {
        guard text != previous else { return nil }
        if text.hasPrefix(previous) {
            return (String(text.dropFirst(previous.count)), false)
        }
        return (text, true)
    }
}

/// Catalog entry returned by `models.list`.
public struct GatewayModelCatalogEntry: Codable, Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public let displayName: String
    public let api: String?
    public let authMode: String?

    public init(
        providerID: String,
        modelID: String,
        displayName: String,
        api: String? = nil,
        authMode: String? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
        self.api = api
        self.authMode = authMode
    }
}

/// Response payload for `models.list`.
public struct GatewayModelsListResult: Codable, Sendable, Equatable {
    public let models: [GatewayModelCatalogEntry]

    public init(models: [GatewayModelCatalogEntry]) {
        self.models = models
    }
}

/// Skill summary returned by `skills.list`.
public struct GatewaySkillDescriptor: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let source: String
    public let entrypoint: String?
    public let userInvocable: Bool

    public init(
        name: String,
        description: String,
        source: String,
        entrypoint: String? = nil,
        userInvocable: Bool
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.entrypoint = entrypoint
        self.userInvocable = userInvocable
    }
}

/// Response payload for `skills.list`.
public struct GatewaySkillsListResult: Codable, Sendable, Equatable {
    public let skills: [GatewaySkillDescriptor]

    public init(skills: [GatewaySkillDescriptor]) {
        self.skills = skills
    }
}

/// Request payload for `skills.invoke`.
public struct GatewaySkillInvokeParams: Codable, Sendable, Equatable {
    public let name: String
    public let input: String

    public init(name: String, input: String) {
        self.name = name
        self.input = input
    }
}

/// Response payload for `skills.invoke`.
public struct GatewaySkillInvokeResult: Codable, Sendable, Equatable {
    public let skillName: String
    public let output: String
    public let executorID: String?
    public let durationMs: Int?

    public init(skillName: String, output: String, executorID: String? = nil, durationMs: Int? = nil) {
        self.skillName = skillName
        self.output = output
        self.executorID = executorID
        self.durationMs = durationMs
    }
}

/// Secret descriptor returned by `secrets.list`.
public struct GatewaySecretDescriptor: Codable, Sendable, Equatable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

/// Response payload for `secrets.list`.
public struct GatewaySecretsListResult: Codable, Sendable, Equatable {
    public let secrets: [GatewaySecretDescriptor]

    public init(secrets: [GatewaySecretDescriptor]) {
        self.secrets = secrets
    }
}

/// Mutation request payload for `secrets.set`.
public struct GatewaySecretSetParams: Codable, Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Mutation request payload for `secrets.delete`.
public struct GatewaySecretDeleteParams: Codable, Sendable, Equatable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

/// Mutation result payload returned by secret mutation methods.
public struct GatewaySecretMutationResult: Codable, Sendable, Equatable {
    public let ok: Bool
    public let key: String
    public let deleted: Bool?

    public init(ok: Bool = true, key: String, deleted: Bool? = nil) {
        self.ok = ok
        self.key = key
        self.deleted = deleted
    }
}

/// Typed request for `browser.request`.
public struct GatewayBrowserRequestParams: Codable, Sendable, Equatable {
    public let method: String
    public let path: String
    public let query: [String: String]?
    public let body: AnyCodable?
    public let timeoutMs: Int?
    public let workspaceRoot: String?
    public let spawnedWorkspaceRoot: String?

    public init(
        method: String,
        path: String,
        query: [String: String]? = nil,
        body: AnyCodable? = nil,
        timeoutMs: Int? = nil,
        workspaceRoot: String? = nil,
        spawnedWorkspaceRoot: String? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.timeoutMs = timeoutMs
        self.workspaceRoot = workspaceRoot
        self.spawnedWorkspaceRoot = spawnedWorkspaceRoot
    }
}

/// Typed response for `browser.request`.
public struct GatewayBrowserResponse: Codable, Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: AnyCodable?

    public init(status: Int, headers: [String: String] = [:], body: AnyCodable? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}
