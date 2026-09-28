import Foundation
import OpenClawProtocol

/// Route metadata associated with a session.
public struct SessionRoute: Codable, Sendable, Equatable {
    /// Channel identifier.
    public let channel: String
    /// Optional account identifier.
    public let accountID: String?
    /// Optional peer/channel identifier.
    public let peerID: String?

    /// Creates session route metadata.
    /// - Parameters:
    ///   - channel: Channel identifier.
    ///   - accountID: Optional account identifier.
    ///   - peerID: Optional peer identifier.
    public init(channel: String, accountID: String? = nil, peerID: String? = nil) {
        self.channel = channel
        self.accountID = accountID
        self.peerID = peerID
    }
}

/// Persisted session record.
///
/// 2026.3.0 adds the upstream 2026.9.6 session controls (``permissionMode``, ``traceLevel``,
/// ``toolOverrides``, display metadata, archive/pin/unread markers, ``goal``) and moves every
/// millisecond timestamp to `Int64` (32-bit watchOS cannot hold epoch milliseconds in `Int`).
///
/// The retired session ``execSecurity``/``execAsk`` overrides are still decoded from legacy files
/// but never encoded: on decode a restrictive legacy policy migrates to ``permissionMode``
/// (see ``SessionPermissionMode/migratingLegacyExecPolicy(security:ask:execHost:)``); a legacy
/// full-access policy is dropped so configuration applies, never converted into `full`.
public struct SessionRecord: Codable, Sendable, Equatable {
    /// Session key.
    public let key: String
    /// Agent identifier bound to this session.
    public var agentID: String
    /// Last updated timestamp in milliseconds since epoch.
    public var updatedAtMs: Int64
    /// Last observed route metadata.
    public var lastRoute: SessionRoute?
    /// Optional gateway/runtime session identifier (the transcript identity).
    public var sessionID: String?
    /// Optional user-facing session label.
    public var label: String?
    /// Optional model override.
    public var modelOverride: String?
    /// Optional session thinking override.
    public var thinkingLevel: ThinkLevel?
    /// Optional fast-mode preference (`true`, `false` or `auto`).
    public var fastModeSetting: FastModeSetting?
    /// Optional session verbosity override.
    public var verboseLevel: VerboseLevel?
    /// Optional session reasoning visibility override.
    public var reasoningLevel: ReasoningLevel?
    /// Optional response-usage display override.
    public var responseUsage: UsageDisplayLevel?
    /// Optional elevated execution override.
    public var elevatedLevel: ElevatedLevel?
    /// Optional group activation override.
    public var groupActivation: GroupActivation?
    /// Optional outbound send policy override.
    public var sendPolicy: SendPolicy?
    /// Optional execution host override.
    public var execHost: ExecHost?
    /// Retired execution security override (decoded from legacy files only; never encoded).
    ///
    /// Deprecated in 2026.3.0: use ``permissionMode``.
    public var execSecurity: ExecSecurity?
    /// Retired execution approval override (decoded from legacy files only; never encoded).
    ///
    /// Deprecated in 2026.3.0: use ``permissionMode``.
    public var execAsk: ExecAsk?
    /// Optional execution-node override.
    public var execNode: String?
    /// Parent session key for spawned sessions.
    public var spawnedBy: String?
    /// Workspace inherited by a spawned session.
    public var spawnedWorkspaceDir: String?
    /// Optional spawn depth for subagents.
    public var spawnDepth: Int?
    /// Optional provenance payload from the latest inbound/run context.
    public var inputProvenance: [String: AnyCodable]?
    /// Session permission mode (`nil` = configured default).
    public var permissionMode: SessionPermissionMode?
    /// Sandbox containment override (`"off"`); `nil` = configured containment.
    public var sandboxMode: String?
    /// Session trace level.
    public var traceLevel: TraceLevel?
    /// Sparse session tool overlay.
    public var toolOverrides: SessionToolOverrides?
    /// Automatic label (separate from explicit ``label`` renames).
    public var autoLabel: String?
    /// Sidebar icon identifier.
    public var icon: String?
    /// Sidebar tint identifier.
    public var color: String?
    /// User-defined organization bucket.
    public var category: String?
    /// Time the session was archived (ms); `nil` when active.
    public var archivedAtMs: Int64?
    /// Time the session was pinned (ms); `nil` when unpinned.
    public var pinnedAtMs: Int64?
    /// Explicit unread marker (ms).
    public var markedUnreadAtMs: Int64?
    /// Time the session was last marked read (ms).
    public var lastReadAtMs: Int64?
    /// Context-window override (for example `"1m"`).
    public var contextWindow: String?
    /// Explicit agent runtime for the selected model.
    public var agentRuntime: String?
    /// Durable session goal.
    public var goal: SessionGoal?
    /// Previous transcript session identifier after a reset rotated ``sessionID``.
    public var parentSessionID: String?
    /// Cumulative tokens used by runs of this session.
    public var totalTokens: Int64?
    /// Creation time (ms).
    public var createdAtMs: Int64?

    /// Compatibility alias for the canonical model override.
    public var model: String? {
        get { self.modelOverride }
        set { self.modelOverride = Self.normalizedText(newValue) }
    }

    /// Boolean fast-mode override (`nil` when unset or `auto`); setting it replaces ``fastModeSetting``.
    public var fastMode: Bool? {
        get { self.fastModeSetting?.boolValue }
        set { self.fastModeSetting = newValue.map(FastModeSetting.init) }
    }

    /// Whether the session is archived.
    public var archived: Bool {
        self.archivedAtMs != nil
    }

    /// Whether the session is pinned.
    public var pinned: Bool {
        self.pinnedAtMs != nil
    }

    /// Whether the session carries an explicit unread marker.
    public var unread: Bool {
        self.markedUnreadAtMs != nil
    }

    /// Whether the session is a spawned child (sub-agent) session, which cannot be pinned.
    public var isChildSession: Bool {
        self.spawnedBy != nil || SessionKey.isSubagentKey(self.key)
    }

    /// Creates a session record.
    /// - Parameters:
    ///   - key: Session key.
    ///   - agentID: Bound agent identifier.
    ///   - updatedAtMs: Last update timestamp in milliseconds.
    ///   - lastRoute: Optional route metadata.
    ///   - permissionMode: Optional session permission mode.
    ///   - traceLevel: Optional trace level.
    ///   - toolOverrides: Optional tool overlay.
    public init(
        key: String,
        agentID: String,
        updatedAtMs: Int64,
        lastRoute: SessionRoute? = nil,
        sessionID: String? = nil,
        label: String? = nil,
        modelOverride: String? = nil,
        thinkingLevel: ThinkLevel? = nil,
        fastMode: Bool? = nil,
        verboseLevel: VerboseLevel? = nil,
        reasoningLevel: ReasoningLevel? = nil,
        responseUsage: UsageDisplayLevel? = nil,
        elevatedLevel: ElevatedLevel? = nil,
        model: String? = nil,
        spawnedBy: String? = nil,
        spawnedWorkspaceDir: String? = nil,
        spawnDepth: Int? = nil,
        groupActivation: GroupActivation? = nil,
        sendPolicy: SendPolicy? = nil,
        execHost: ExecHost? = nil,
        execSecurity: ExecSecurity? = nil,
        execAsk: ExecAsk? = nil,
        execNode: String? = nil,
        inputProvenance: [String: AnyCodable]? = nil,
        permissionMode: SessionPermissionMode? = nil,
        traceLevel: TraceLevel? = nil,
        toolOverrides: SessionToolOverrides? = nil
    ) {
        self.key = key
        self.agentID = agentID
        self.updatedAtMs = updatedAtMs
        self.lastRoute = lastRoute
        self.sessionID = Self.normalizedText(sessionID)
        self.label = Self.normalizedText(label)
        self.modelOverride = Self.normalizedText(modelOverride ?? model)
        self.thinkingLevel = thinkingLevel
        self.fastModeSetting = fastMode.map(FastModeSetting.init)
        self.verboseLevel = verboseLevel
        self.reasoningLevel = reasoningLevel
        self.responseUsage = responseUsage
        self.elevatedLevel = elevatedLevel
        self.spawnedBy = Self.normalizedText(spawnedBy)
        self.spawnedWorkspaceDir = Self.normalizedText(spawnedWorkspaceDir)
        self.spawnDepth = spawnDepth
        self.groupActivation = groupActivation
        self.sendPolicy = sendPolicy
        self.execHost = execHost
        self.execSecurity = execSecurity
        self.execAsk = execAsk
        self.execNode = Self.normalizedText(execNode)
        self.inputProvenance = inputProvenance
        self.permissionMode = permissionMode
        self.traceLevel = traceLevel
        self.toolOverrides = toolOverrides?.normalized()
    }

    /// Creates a session record from string-based protocol/runtime payloads.
    public init(
        key: String,
        agentID: String,
        updatedAtMs: Int64,
        lastRoute: SessionRoute? = nil,
        sessionID: String? = nil,
        label: String? = nil,
        thinkingLevel: String? = nil,
        fastMode: Bool? = nil,
        verboseLevel: String? = nil,
        reasoningLevel: String? = nil,
        responseUsage: String? = nil,
        elevatedLevel: String? = nil,
        model: String? = nil,
        spawnedBy: String? = nil,
        spawnedWorkspaceDir: String? = nil,
        spawnDepth: Int? = nil,
        sendPolicy: String? = nil,
        groupActivation: String? = nil,
        inputProvenance: [String: AnyCodable]? = nil
    ) {
        self.init(
            key: key,
            agentID: agentID,
            updatedAtMs: updatedAtMs,
            lastRoute: lastRoute,
            sessionID: sessionID,
            label: label,
            modelOverride: model,
            thinkingLevel: ThinkLevel.normalize(thinkingLevel),
            fastMode: fastMode,
            verboseLevel: VerboseLevel.normalize(verboseLevel),
            reasoningLevel: ReasoningLevel.normalize(reasoningLevel),
            responseUsage: UsageDisplayLevel.normalize(responseUsage),
            elevatedLevel: ElevatedLevel.normalize(elevatedLevel),
            spawnedBy: spawnedBy,
            spawnedWorkspaceDir: spawnedWorkspaceDir,
            spawnDepth: spawnDepth,
            groupActivation: Self.normalizeGroupActivation(groupActivation),
            sendPolicy: Self.normalizeSendPolicy(sendPolicy),
            inputProvenance: inputProvenance
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case agentID
        case updatedAtMs
        case lastRoute
        case sessionID = "sessionId"
        case label
        case modelOverride
        case thinkingLevel
        case fastMode
        case verboseLevel
        case reasoningLevel
        case responseUsage
        case elevatedLevel
        case spawnedBy
        case spawnedWorkspaceDir
        case spawnDepth
        case groupActivation
        case sendPolicy
        case execHost
        case execSecurity
        case execAsk
        case execNode
        case inputProvenance
        case permissionMode
        case sandboxMode
        case traceLevel
        case toolOverrides
        case autoLabel
        case icon
        case color
        case category
        case archivedAtMs
        case pinnedAtMs
        case markedUnreadAtMs
        case lastReadAtMs
        case contextWindow
        case agentRuntime
        case goal
        case parentSessionID = "parentSessionId"
        case totalTokens
        case createdAtMs
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case sessionID = "sessionID"
        case model
    }

    /// Decodes a record; unknown vocabulary values decode as `nil` and retired exec overrides migrate
    /// to ``permissionMode``.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            Self.normalizedText((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil)
        }

        self.init(
            key: try container.decode(String.self, forKey: .key),
            agentID: try container.decode(String.self, forKey: .agentID),
            updatedAtMs: Self.decodeInt64(container, forKey: .updatedAtMs) ?? 0,
            lastRoute: try container.decodeIfPresent(SessionRoute.self, forKey: .lastRoute),
            sessionID: try container.decodeIfPresent(String.self, forKey: .sessionID)
                ?? legacyContainer.decodeIfPresent(String.self, forKey: .sessionID),
            label: try container.decodeIfPresent(String.self, forKey: .label),
            modelOverride: try container.decodeIfPresent(String.self, forKey: .modelOverride)
                ?? legacyContainer.decodeIfPresent(String.self, forKey: .model),
            thinkingLevel: ThinkLevel.normalize(text(.thinkingLevel)),
            verboseLevel: VerboseLevel.normalize(text(.verboseLevel)),
            reasoningLevel: ReasoningLevel.normalize(text(.reasoningLevel)),
            responseUsage: UsageDisplayLevel.normalize(text(.responseUsage)),
            elevatedLevel: ElevatedLevel.normalize(text(.elevatedLevel)),
            spawnedBy: text(.spawnedBy),
            spawnedWorkspaceDir: text(.spawnedWorkspaceDir),
            spawnDepth: try? container.decodeIfPresent(Int.self, forKey: .spawnDepth),
            groupActivation: Self.normalizeGroupActivation(text(.groupActivation)),
            sendPolicy: Self.normalizeSendPolicy(text(.sendPolicy)),
            execHost: Self.normalizeExecHost(text(.execHost)),
            execSecurity: Self.normalizeExecSecurity(text(.execSecurity)),
            execAsk: Self.normalizeExecAsk(text(.execAsk)),
            execNode: text(.execNode),
            inputProvenance: try container.decodeIfPresent([String: AnyCodable].self, forKey: .inputProvenance),
            permissionMode: SessionPermissionMode.normalize(text(.permissionMode)),
            traceLevel: TraceLevel.normalize(text(.traceLevel)),
            toolOverrides: (try? container.decodeIfPresent(SessionToolOverrides.self, forKey: .toolOverrides)) ?? nil
        )
        self.fastModeSetting = (try? container.decodeIfPresent(FastModeSetting.self, forKey: .fastMode)) ?? nil
        self.sandboxMode = text(.sandboxMode)
        self.autoLabel = text(.autoLabel)
        self.icon = text(.icon)
        self.color = text(.color)
        self.category = text(.category)
        self.archivedAtMs = Self.decodeInt64(container, forKey: .archivedAtMs)
        self.pinnedAtMs = Self.decodeInt64(container, forKey: .pinnedAtMs)
        self.markedUnreadAtMs = Self.decodeInt64(container, forKey: .markedUnreadAtMs)
        self.lastReadAtMs = Self.decodeInt64(container, forKey: .lastReadAtMs)
        self.contextWindow = text(.contextWindow)
        self.agentRuntime = text(.agentRuntime)
        self.goal = (try? container.decodeIfPresent(SessionGoal.self, forKey: .goal)) ?? nil
        self.parentSessionID = text(.parentSessionID)
        self.totalTokens = Self.decodeInt64(container, forKey: .totalTokens)
        self.createdAtMs = Self.decodeInt64(container, forKey: .createdAtMs)
        if self.permissionMode == nil, self.execSecurity != nil || self.execAsk != nil {
            self.permissionMode = SessionPermissionMode.migratingLegacyExecPolicy(
                security: self.execSecurity,
                ask: self.execAsk,
                execHost: self.execHost
            )
        }
    }

    /// Encodes the record. The retired `execSecurity`/`execAsk` fields are never written.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.key, forKey: .key)
        try container.encode(self.agentID, forKey: .agentID)
        try container.encode(self.updatedAtMs, forKey: .updatedAtMs)
        try container.encodeIfPresent(self.lastRoute, forKey: .lastRoute)
        try container.encodeIfPresent(self.sessionID, forKey: .sessionID)
        try container.encodeIfPresent(self.label, forKey: .label)
        try container.encodeIfPresent(self.modelOverride, forKey: .modelOverride)
        try container.encodeIfPresent(self.thinkingLevel?.rawValue, forKey: .thinkingLevel)
        try container.encodeIfPresent(self.fastModeSetting, forKey: .fastMode)
        try container.encodeIfPresent(self.verboseLevel?.rawValue, forKey: .verboseLevel)
        try container.encodeIfPresent(self.reasoningLevel?.rawValue, forKey: .reasoningLevel)
        try container.encodeIfPresent(self.responseUsage?.rawValue, forKey: .responseUsage)
        try container.encodeIfPresent(self.elevatedLevel?.rawValue, forKey: .elevatedLevel)
        try container.encodeIfPresent(self.spawnedBy, forKey: .spawnedBy)
        try container.encodeIfPresent(self.spawnedWorkspaceDir, forKey: .spawnedWorkspaceDir)
        try container.encodeIfPresent(self.spawnDepth, forKey: .spawnDepth)
        try container.encodeIfPresent(self.groupActivation?.rawValue, forKey: .groupActivation)
        try container.encodeIfPresent(self.sendPolicy?.rawValue, forKey: .sendPolicy)
        try container.encodeIfPresent(self.execHost?.rawValue, forKey: .execHost)
        try container.encodeIfPresent(self.execNode, forKey: .execNode)
        try container.encodeIfPresent(self.inputProvenance, forKey: .inputProvenance)
        try container.encodeIfPresent(self.permissionMode, forKey: .permissionMode)
        try container.encodeIfPresent(self.sandboxMode, forKey: .sandboxMode)
        try container.encodeIfPresent(self.traceLevel, forKey: .traceLevel)
        try container.encodeIfPresent(self.toolOverrides, forKey: .toolOverrides)
        try container.encodeIfPresent(self.autoLabel, forKey: .autoLabel)
        try container.encodeIfPresent(self.icon, forKey: .icon)
        try container.encodeIfPresent(self.color, forKey: .color)
        try container.encodeIfPresent(self.category, forKey: .category)
        try container.encodeIfPresent(self.archivedAtMs, forKey: .archivedAtMs)
        try container.encodeIfPresent(self.pinnedAtMs, forKey: .pinnedAtMs)
        try container.encodeIfPresent(self.markedUnreadAtMs, forKey: .markedUnreadAtMs)
        try container.encodeIfPresent(self.lastReadAtMs, forKey: .lastReadAtMs)
        try container.encodeIfPresent(self.contextWindow, forKey: .contextWindow)
        try container.encodeIfPresent(self.agentRuntime, forKey: .agentRuntime)
        try container.encodeIfPresent(self.goal, forKey: .goal)
        try container.encodeIfPresent(self.parentSessionID, forKey: .parentSessionID)
        try container.encodeIfPresent(self.totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(self.createdAtMs, forKey: .createdAtMs)
    }

    private static func decodeInt64(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int64? {
        if let value = (try? container.decodeIfPresent(Int64.self, forKey: key)) ?? nil {
            return value
        }
        if let value = (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil, value.isFinite {
            return Int64(exactly: value.rounded()) ?? (value > 0 ? Int64.max : Int64.min)
        }
        return nil
    }

    static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizeSendPolicy(_ raw: String?) -> SendPolicy? {
        guard let raw = Self.normalizedText(raw)?.lowercased() else { return nil }
        return SendPolicy(rawValue: raw)
    }

    private static func normalizeGroupActivation(_ raw: String?) -> GroupActivation? {
        guard let raw = Self.normalizedText(raw)?.lowercased() else { return nil }
        return GroupActivation(rawValue: raw)
    }

    private static func normalizeExecHost(_ raw: String?) -> ExecHost? {
        guard let raw = Self.normalizedText(raw)?.lowercased() else { return nil }
        return ExecHost(rawValue: raw)
    }

    private static func normalizeExecSecurity(_ raw: String?) -> ExecSecurity? {
        guard let raw = Self.normalizedText(raw)?.lowercased().replacingOccurrences(of: "-", with: "") else { return nil }
        return ExecSecurity(rawValue: raw)
    }

    private static func normalizeExecAsk(_ raw: String?) -> ExecAsk? {
        guard let raw = Self.normalizedText(raw)?.lowercased().replacingOccurrences(of: "_", with: "-") else { return nil }
        return ExecAsk(rawValue: raw)
    }
}

/// Inputs used for deriving session keys.
public struct SessionRoutingContext: Sendable, Equatable {
    /// Channel identifier.
    public let channel: String
    /// Optional account identifier.
    public let accountID: String?
    /// Optional peer identifier.
    public let peerID: String?

    /// Creates routing context.
    /// - Parameters:
    ///   - channel: Channel identifier.
    ///   - accountID: Optional account identifier.
    ///   - peerID: Optional peer identifier.
    public init(channel: String, accountID: String? = nil, peerID: String? = nil) {
        self.channel = channel
        self.accountID = accountID
        self.peerID = peerID
    }
}

/// Session key derivation and resolution helpers.
///
/// The default ``SessionKeyFormat/legacy`` format joins `channel:account:peer`. The opt-in
/// ``SessionKeyFormat/canonical`` format produces upstream agent-scoped keys (see ``SessionKey``).
public enum SessionKeyResolver {
    /// Derives a session key from routing context and config flags.
    /// - Parameters:
    ///   - context: Routing context.
    ///   - config: Runtime configuration.
    /// - Returns: Sanitized derived session key.
    public static func derive(context: SessionRoutingContext, config: OpenClawConfig) -> String {
        let cleanChannel = config.routing.includeChannelID ? sanitizeOptional(context.channel) : nil
        let account = config.routing.includeAccountID ? sanitizeOptional(context.accountID) : nil
        let peer = config.routing.includePeerID ? sanitizeOptional(context.peerID) : nil

        let parts = [cleanChannel, account, peer].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return sanitize(config.routing.defaultSessionKey)
        }
        return parts.joined(separator: ":")
    }

    /// Derives a session key in the requested format.
    ///
    /// `.canonical` builds `agent:<agentId>:…` keys with ``SessionKey/peerKey(agentID:channel:accountID:peerKind:peerID:dmScope:groupScope:mainKey:)``
    /// using the `per-account-channel-peer` DM scope when account and peer ids are included, mirroring the legacy
    /// key's specificity; `.legacy` is ``derive(context:config:)``.
    /// - Parameters:
    ///   - context: Routing context.
    ///   - config: Runtime configuration.
    ///   - format: Key format.
    ///   - agentID: Agent id for canonical keys; defaults to `config.agents.defaultAgentID`.
    ///   - peerKind: Peer kind for canonical keys.
    /// - Returns: Derived session key.
    public static func derive(
        context: SessionRoutingContext,
        config: OpenClawConfig,
        format: SessionKeyFormat,
        agentID: String? = nil,
        peerKind: SessionPeerKind = .direct
    ) -> String {
        switch format {
        case .legacy:
            return Self.derive(context: context, config: config)
        case .canonical:
            let agent = agentID ?? config.agents.defaultAgentID
            let channel = config.routing.includeChannelID ? sanitizeOptional(context.channel) : nil
            let account = config.routing.includeAccountID ? sanitizeOptional(context.accountID) : nil
            let peer = config.routing.includePeerID ? sanitizeOptional(context.peerID) : nil
            guard let channel, let peer else {
                return SessionKey.toStoreKey(agentID: agent, requestKey: config.routing.defaultSessionKey)
            }
            let dmScope: SessionDMScope = account != nil ? .perAccountChannelPeer : .perChannelPeer
            return SessionKey.peerKey(
                agentID: agent,
                channel: channel,
                accountID: account,
                peerKind: peerKind,
                peerID: peer,
                dmScope: dmScope,
                groupScope: .perGroup
            )
        }
    }

    /// Resolves effective session key from explicit value or context fallback.
    /// - Parameters:
    ///   - explicit: Explicit key if provided.
    ///   - context: Optional routing context.
    ///   - config: Runtime configuration.
    /// - Returns: Sanitized resolved session key.
    public static func resolve(explicit: String?, context: SessionRoutingContext?, config: OpenClawConfig) -> String {
        if let explicit {
            let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return sanitize(trimmed)
            }
        }
        if let context {
            return derive(context: context, config: config)
        }
        return sanitize(config.routing.defaultSessionKey)
    }

    private static func sanitizeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = sanitize(value)
        return clean.isEmpty ? nil : clean
    }

    private static func sanitize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}

/// Actor-backed persisted session store.
public actor SessionStore {
    private let fileURL: URL
    var records: [String: SessionRecord] = [:]

    /// Creates a session store.
    /// - Parameter fileURL: Session store JSON file URL.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads session records from disk.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            self.records = [:]
            return
        }
        let data = try Data(contentsOf: self.fileURL)
        self.records = try JSONDecoder().decode([String: SessionRecord].self, from: data)
    }

    /// Saves current records to disk atomically.
    public func save() throws {
        try OpenClawFileSystem.ensurePrivateDirectory(self.fileURL.deletingLastPathComponent())
        let data = try JSONEncoder().encode(self.records)
        try data.write(to: self.fileURL, options: [.atomic])
        OpenClawFileSystem.restrictToOwner(self.fileURL)
    }

    /// Inserts or replaces a session record.
    /// - Parameter record: Session record.
    public func upsert(_ record: SessionRecord) {
        self.records[record.key] = record
    }

    /// Returns a session record by key.
    /// - Parameter key: Session key.
    /// - Returns: Matching record when present.
    public func recordForKey(_ key: String) -> SessionRecord? {
        self.records[key]
    }

    /// Deletes one session record by key.
    /// - Parameter key: Session key to remove.
    /// - Returns: `true` when a record existed and was removed.
    @discardableResult
    public func deleteRecord(forKey key: String) -> Bool {
        self.records.removeValue(forKey: key) != nil
    }

    /// Returns all session records sorted by key.
    public func allRecords() -> [SessionRecord] {
        self.records.values.sorted { $0.key < $1.key }
    }

    /// Resolves an existing session or creates a new one.
    ///
    /// Sessions get a transcript identity (``SessionRecord/sessionID``, a UUID) on first resolve.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - defaultAgentID: Default agent identifier for new sessions.
    ///   - route: Optional route metadata.
    ///   - defaults: Optional agent defaults seeded into new sessions.
    /// - Returns: Existing or newly created session record.
    public func resolveOrCreate(
        sessionKey: String,
        defaultAgentID: String,
        route: SessionRoute?,
        defaults: AgentsConfig? = nil
    ) -> SessionRecord {
        let now = sessionStoreNowMs()
        if var existing = self.records[sessionKey] {
            existing.updatedAtMs = now
            if let route {
                existing.lastRoute = route
            }
            if existing.sessionID == nil {
                existing.sessionID = Self.makeSessionID()
            }
            self.records[sessionKey] = existing
            return existing
        }

        var seeded = SessionRecord(
            key: sessionKey,
            agentID: defaultAgentID,
            updatedAtMs: now,
            lastRoute: route,
            sessionID: Self.makeSessionID()
        )
        seeded.createdAtMs = now
        if let defaults {
            seeded.applyDefaults(from: defaults)
        }
        self.records[sessionKey] = seeded
        return seeded
    }

    /// Applies a typed gateway session patch to an existing session record.
    ///
    /// Lenient legacy semantics: unknown values keep the current value. The retired `execSecurity`/
    /// `execAsk` fields are ignored (the in-process `sessions.patch` handler rejects them; see
    /// ``applyPatch(_:defaultAgentID:grantedScopes:)``).
    /// - Parameter patch: Gateway protocol session patch payload.
    /// - Returns: Updated session record when the key exists.
    @discardableResult
    public func applyGatewayPatch(_ patch: SessionsPatchParams) -> SessionRecord? {
        guard var existing = self.records[patch.key] else {
            return nil
        }

        let now = sessionStoreNowMs()
        existing.updatedAtMs = now
        existing.label = Self.stringValue(from: patch.label) ?? existing.label
        existing.autoLabel = Self.stringValue(from: patch.autolabel) ?? existing.autoLabel
        existing.icon = Self.stringValue(from: patch.icon) ?? existing.icon
        existing.color = Self.stringValue(from: patch.color) ?? existing.color
        existing.category = Self.stringValue(from: patch.category) ?? existing.category
        existing.thinkingLevel = ThinkLevel.normalize(Self.stringValue(from: patch.thinkinglevel)) ?? existing.thinkingLevel
        if let fastMode = Self.boolValue(from: patch.fastmode) {
            existing.fastModeSetting = FastModeSetting(fastMode)
        } else if let setting = FastModeSetting.normalize(Self.stringValue(from: patch.fastmode)) {
            existing.fastModeSetting = setting
        }
        existing.verboseLevel = VerboseLevel.normalize(Self.stringValue(from: patch.verboselevel)) ?? existing.verboseLevel
        existing.traceLevel = TraceLevel.normalize(Self.stringValue(from: patch.tracelevel)) ?? existing.traceLevel
        existing.reasoningLevel = ReasoningLevel.normalize(Self.stringValue(from: patch.reasoninglevel))
            ?? existing.reasoningLevel
        existing.responseUsage = UsageDisplayLevel.normalize(Self.stringValue(from: patch.responseusage))
            ?? existing.responseUsage
        existing.elevatedLevel = ElevatedLevel.normalize(Self.stringValue(from: patch.elevatedlevel))
            ?? existing.elevatedLevel
        existing.model = Self.stringValue(from: patch.model) ?? existing.model
        existing.sendPolicy = Self.sendPolicyValue(from: patch.sendpolicy) ?? existing.sendPolicy
        existing.groupActivation = Self.groupActivationValue(from: patch.groupactivation) ?? existing.groupActivation
        existing.execHost = Self.execHostValue(from: patch.exechost) ?? existing.execHost
        existing.execNode = Self.stringValue(from: patch.execnode) ?? existing.execNode
        existing.permissionMode = SessionPermissionMode.normalize(Self.stringValue(from: patch.permissionmode))
            ?? existing.permissionMode
        if Self.stringValue(from: patch.sandboxmode) == "off" {
            existing.sandboxMode = "off"
        }
        existing.contextWindow = Self.stringValue(from: patch.contextwindow) ?? existing.contextWindow
        existing.agentRuntime = Self.stringValue(from: patch.agentruntime) ?? existing.agentRuntime
        if let overrides = patch.tooloverrides.flatMap({ try? GatewayPayloadCodecLite.decode(SessionToolOverrides.self, from: $0) }) {
            existing.toolOverrides = overrides.normalized()
        }
        if let archived = patch.archived {
            if archived {
                existing.archivedAtMs = existing.archivedAtMs ?? now
                existing.pinnedAtMs = nil
            } else {
                existing.archivedAtMs = nil
            }
        }
        if let pinned = patch.pinned, !existing.archived, !existing.isChildSession {
            existing.pinnedAtMs = pinned ? (existing.pinnedAtMs ?? now) : nil
        }
        if let unread = patch.unread {
            if unread {
                existing.markedUnreadAtMs = max(now, (existing.markedUnreadAtMs ?? 0) + 1)
            } else {
                existing.lastReadAtMs = now
                existing.markedUnreadAtMs = nil
            }
        }
        self.records[patch.key] = existing
        return existing
    }

    /// Updates runtime-facing session metadata for one session.
    /// - Parameters:
    ///   - sessionKey: Session key to mutate.
    ///   - inputProvenance: Optional normalized provenance payload.
    ///   - fastMode: Optional fast mode override.
    ///   - spawnedWorkspaceDir: Optional spawned workspace path.
    /// - Returns: Updated session record when present.
    @discardableResult
    public func updateRuntimeState(
        sessionKey: String,
        inputProvenance: [String: AnyCodable]? = nil,
        fastMode: Bool? = nil,
        spawnedWorkspaceDir: String? = nil
    ) -> SessionRecord? {
        guard var existing = self.records[sessionKey] else {
            return nil
        }
        existing.updatedAtMs = sessionStoreNowMs()
        if let inputProvenance {
            existing.inputProvenance = inputProvenance
        }
        if let fastMode {
            existing.fastMode = fastMode
        }
        if let spawnedWorkspaceDir {
            existing.spawnedWorkspaceDir = spawnedWorkspaceDir
        }
        self.records[sessionKey] = existing
        return existing
    }

    /// Rotates a session to a new transcript identity (used by `sessions.reset`).
    ///
    /// The previous ``SessionRecord/sessionID`` becomes ``SessionRecord/parentSessionID``; session
    /// preferences are cleared as in the legacy reset (only the agent and route are kept).
    /// - Parameter key: Session key.
    /// - Returns: The rotated record, or `nil` when the key is unknown.
    @discardableResult
    public func rotateSession(forKey key: String) -> SessionRecord? {
        guard let existing = self.records[key] else {
            return nil
        }
        let now = sessionStoreNowMs()
        var rotated = SessionRecord(
            key: existing.key,
            agentID: existing.agentID,
            updatedAtMs: now,
            lastRoute: existing.lastRoute,
            sessionID: Self.makeSessionID()
        )
        rotated.parentSessionID = existing.sessionID
        rotated.createdAtMs = existing.createdAtMs ?? now
        self.records[key] = rotated
        return rotated
    }

    /// Mutates one record in place.
    /// - Parameters:
    ///   - key: Session key.
    ///   - body: Mutation applied to the record.
    /// - Returns: The updated record, or `nil` when the key is unknown.
    @discardableResult
    public func update(forKey key: String, _ body: @Sendable (inout SessionRecord) -> Void) -> SessionRecord? {
        guard var record = self.records[key] else {
            return nil
        }
        body(&record)
        record.updatedAtMs = max(record.updatedAtMs, sessionStoreNowMs())
        self.records[key] = record
        return record
    }

    /// Adds run token usage to a session and to its active goal.
    /// - Parameters:
    ///   - tokens: Tokens used by a run.
    ///   - key: Session key.
    /// - Returns: The updated record, or `nil` when the key is unknown.
    @discardableResult
    public func recordUsage(tokens: Int64, forKey key: String) -> SessionRecord? {
        guard tokens > 0, var record = self.records[key] else {
            return self.records[key]
        }
        let now = sessionStoreNowMs()
        record.totalTokens = (record.totalTokens ?? 0) + tokens
        record.goal?.recordUsage(tokens, nowMs: now)
        record.updatedAtMs = now
        self.records[key] = record
        return record
    }

    static func makeSessionID() -> String {
        UUID().uuidString.lowercased()
    }

    static func stringValue(from value: AnyCodable?) -> String? {
        guard let value else {
            return nil
        }
        if case .string(let stringValue) = value.value {
            let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        return nil
    }

    private static func boolValue(from value: AnyCodable?) -> Bool? {
        guard let value else {
            return nil
        }
        if case .bool(let boolValue) = value.value {
            return boolValue
        }
        return nil
    }

    private static func sendPolicyValue(from value: AnyCodable?) -> SendPolicy? {
        guard let raw = Self.stringValue(from: value)?.lowercased() else {
            return nil
        }
        return SendPolicy(rawValue: raw)
    }

    private static func groupActivationValue(from value: AnyCodable?) -> GroupActivation? {
        guard let raw = Self.stringValue(from: value)?.lowercased() else {
            return nil
        }
        return GroupActivation(rawValue: raw)
    }

    private static func execHostValue(from value: AnyCodable?) -> ExecHost? {
        guard let raw = Self.stringValue(from: value)?.lowercased() else {
            return nil
        }
        return ExecHost(rawValue: raw)
    }
}

/// Minimal AnyCodable-to-type decoding used by session helpers.
enum GatewayPayloadCodecLite {
    static func decode<T: Decodable>(_ type: T.Type, from value: AnyCodable) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }
}

/// Current time in epoch milliseconds as `Int64` (safe on 32-bit watchOS).
func sessionStoreNowMs() -> Int64 {
    OpenClawClock.nowMs()
}
