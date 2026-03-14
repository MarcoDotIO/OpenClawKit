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
public struct SessionRecord: Codable, Sendable, Equatable {
    /// Session key.
    public let key: String
    /// Agent identifier bound to this session.
    public var agentID: String
    /// Last updated timestamp in milliseconds since epoch.
    public var updatedAtMs: Int
    /// Last observed route metadata.
    public var lastRoute: SessionRoute?
    /// Optional gateway/runtime session identifier.
    public var sessionID: String?
    /// Optional user-facing session label.
    public var label: String?
    /// Optional model override.
    public var modelOverride: String?
    /// Optional session thinking override.
    public var thinkingLevel: ThinkLevel?
    /// Optional fast mode override.
    public var fastMode: Bool?
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
    /// Optional execution security override.
    public var execSecurity: ExecSecurity?
    /// Optional execution approval override.
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

    /// Compatibility alias for the canonical model override.
    public var model: String? {
        get { self.modelOverride }
        set { self.modelOverride = Self.normalizedText(newValue) }
    }

    /// Creates a session record.
    /// - Parameters:
    ///   - key: Session key.
    ///   - agentID: Bound agent identifier.
    ///   - updatedAtMs: Last update timestamp in milliseconds.
    ///   - lastRoute: Optional route metadata.
    public init(
        key: String,
        agentID: String,
        updatedAtMs: Int,
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
        inputProvenance: [String: AnyCodable]? = nil
    ) {
        self.key = key
        self.agentID = agentID
        self.updatedAtMs = updatedAtMs
        self.lastRoute = lastRoute
        self.sessionID = Self.normalizedText(sessionID)
        self.label = Self.normalizedText(label)
        self.modelOverride = Self.normalizedText(modelOverride ?? model)
        self.thinkingLevel = thinkingLevel
        self.fastMode = fastMode
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
    }

    /// Creates a session record from string-based protocol/runtime payloads.
    public init(
        key: String,
        agentID: String,
        updatedAtMs: Int,
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
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case sessionID = "sessionID"
        case model
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)

        self.init(
            key: try container.decode(String.self, forKey: .key),
            agentID: try container.decode(String.self, forKey: .agentID),
            updatedAtMs: try container.decode(Int.self, forKey: .updatedAtMs),
            lastRoute: try container.decodeIfPresent(SessionRoute.self, forKey: .lastRoute),
            sessionID: try container.decodeIfPresent(String.self, forKey: .sessionID)
                ?? legacyContainer.decodeIfPresent(String.self, forKey: .sessionID),
            label: try container.decodeIfPresent(String.self, forKey: .label),
            modelOverride: try container.decodeIfPresent(String.self, forKey: .modelOverride)
                ?? legacyContainer.decodeIfPresent(String.self, forKey: .model),
            thinkingLevel: ThinkLevel.normalize(try container.decodeIfPresent(String.self, forKey: .thinkingLevel)),
            fastMode: try container.decodeIfPresent(Bool.self, forKey: .fastMode),
            verboseLevel: VerboseLevel.normalize(try container.decodeIfPresent(String.self, forKey: .verboseLevel)),
            reasoningLevel: ReasoningLevel.normalize(
                try container.decodeIfPresent(String.self, forKey: .reasoningLevel)
            ),
            responseUsage: UsageDisplayLevel.normalize(
                try container.decodeIfPresent(String.self, forKey: .responseUsage)
            ),
            elevatedLevel: ElevatedLevel.normalize(
                try container.decodeIfPresent(String.self, forKey: .elevatedLevel)
            ),
            spawnedBy: try container.decodeIfPresent(String.self, forKey: .spawnedBy),
            spawnedWorkspaceDir: try container.decodeIfPresent(String.self, forKey: .spawnedWorkspaceDir),
            spawnDepth: try container.decodeIfPresent(Int.self, forKey: .spawnDepth),
            groupActivation: Self.normalizeGroupActivation(
                try container.decodeIfPresent(String.self, forKey: .groupActivation)
            ),
            sendPolicy: Self.normalizeSendPolicy(try container.decodeIfPresent(String.self, forKey: .sendPolicy)),
            execHost: Self.normalizeExecHost(try container.decodeIfPresent(String.self, forKey: .execHost)),
            execSecurity: Self.normalizeExecSecurity(
                try container.decodeIfPresent(String.self, forKey: .execSecurity)
            ),
            execAsk: Self.normalizeExecAsk(try container.decodeIfPresent(String.self, forKey: .execAsk)),
            execNode: try container.decodeIfPresent(String.self, forKey: .execNode),
            inputProvenance: try container.decodeIfPresent([String: AnyCodable].self, forKey: .inputProvenance)
        )
    }

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
        try container.encodeIfPresent(self.fastMode, forKey: .fastMode)
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
        try container.encodeIfPresent(self.execSecurity?.rawValue, forKey: .execSecurity)
        try container.encodeIfPresent(self.execAsk?.rawValue, forKey: .execAsk)
        try container.encodeIfPresent(self.execNode, forKey: .execNode)
        try container.encodeIfPresent(self.inputProvenance, forKey: .inputProvenance)
    }

    private static func normalizedText(_ value: String?) -> String? {
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
        guard let raw = Self.normalizedText(raw)?.lowercased() else { return nil }
        return ExecSecurity(rawValue: raw)
    }

    private static func normalizeExecAsk(_ raw: String?) -> ExecAsk? {
        guard let raw = Self.normalizedText(raw)?.lowercased() else { return nil }
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
    private var records: [String: SessionRecord] = [:]

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
        try FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(self.records)
        try data.write(to: self.fileURL, options: [.atomic])
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
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - defaultAgentID: Default agent identifier for new sessions.
    ///   - route: Optional route metadata.
    /// - Returns: Existing or newly created session record.
    public func resolveOrCreate(
        sessionKey: String,
        defaultAgentID: String,
        route: SessionRoute?,
        defaults: AgentsConfig? = nil
    ) -> SessionRecord {
        if var existing = self.records[sessionKey] {
            existing.updatedAtMs = nowMs()
            if let route {
                existing.lastRoute = route
            }
            self.records[sessionKey] = existing
            return existing
        }

        let created = SessionRecord(
            key: sessionKey,
            agentID: defaultAgentID,
            updatedAtMs: nowMs(),
            lastRoute: route
        )
        var seeded = created
        if let defaults {
            seeded.applyDefaults(from: defaults)
        }
        self.records[sessionKey] = seeded
        return seeded
    }

    /// Applies a gateway session patch to an existing session record.
    /// - Parameter patch: Gateway protocol session patch payload.
    /// - Returns: Updated session record when the key exists.
    @discardableResult
    public func applyGatewayPatch(_ patch: SessionsPatchParams) -> SessionRecord? {
        guard var existing = self.records[patch.key] else {
            return nil
        }

        existing.updatedAtMs = nowMs()
        existing.label = Self.stringValue(from: patch.label) ?? existing.label
        existing.thinkingLevel = ThinkLevel.normalize(Self.stringValue(from: patch.thinkinglevel)) ?? existing.thinkingLevel
        existing.fastMode = Self.boolValue(from: patch.fastmode) ?? existing.fastMode
        existing.verboseLevel = VerboseLevel.normalize(Self.stringValue(from: patch.verboselevel)) ?? existing.verboseLevel
        existing.reasoningLevel = ReasoningLevel.normalize(Self.stringValue(from: patch.reasoninglevel))
            ?? existing.reasoningLevel
        existing.responseUsage = UsageDisplayLevel.normalize(Self.stringValue(from: patch.responseusage))
            ?? existing.responseUsage
        existing.elevatedLevel = ElevatedLevel.normalize(Self.stringValue(from: patch.elevatedlevel))
            ?? existing.elevatedLevel
        existing.model = Self.stringValue(from: patch.model) ?? existing.model
        existing.spawnedBy = Self.stringValue(from: patch.spawnedby) ?? existing.spawnedBy
        existing.spawnedWorkspaceDir = Self.stringValue(from: patch.spawnedworkspacedir) ?? existing.spawnedWorkspaceDir
        existing.spawnDepth = Self.intValue(from: patch.spawndepth) ?? existing.spawnDepth
        existing.sendPolicy = Self.sendPolicyValue(from: patch.sendpolicy) ?? existing.sendPolicy
        existing.groupActivation = Self.groupActivationValue(from: patch.groupactivation) ?? existing.groupActivation
        existing.execHost = Self.execHostValue(from: patch.exechost) ?? existing.execHost
        existing.execSecurity = Self.execSecurityValue(from: patch.execsecurity) ?? existing.execSecurity
        existing.execAsk = Self.execAskValue(from: patch.execask) ?? existing.execAsk
        existing.execNode = Self.stringValue(from: patch.execnode) ?? existing.execNode
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
        existing.updatedAtMs = nowMs()
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

    private static func stringValue(from value: AnyCodable?) -> String? {
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

    private static func intValue(from value: AnyCodable?) -> Int? {
        guard let value else {
            return nil
        }
        if case .int(let intValue) = value.value {
            return intValue
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

    private static func execSecurityValue(from value: AnyCodable?) -> ExecSecurity? {
        guard let raw = Self.stringValue(from: value)?.lowercased() else {
            return nil
        }
        return ExecSecurity(rawValue: raw)
    }

    private static func execAskValue(from value: AnyCodable?) -> ExecAsk? {
        guard let raw = Self.stringValue(from: value)?.lowercased() else {
            return nil
        }
        return ExecAsk(rawValue: raw)
    }
}

private func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
}
