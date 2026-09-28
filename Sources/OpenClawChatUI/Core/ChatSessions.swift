import Foundation
import OpenClawProtocol

// Ported from upstream OpenClaw 2026.9.6 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatSessions.swift`.

/// Declared agent status note shown on a session row.
public struct OpenClawChatSessionAgentStatus: Codable, Sendable, Hashable {
    /// Status note.
    public let note: String
    /// Expiry timestamp in milliseconds.
    public let expiresAt: Double
    /// Attention request marker, when the agent needs the user.
    public let attention: String?

    /// Creates an agent status.
    public init(note: String, expiresAt: Double, attention: String? = nil) {
        self.note = note
        self.expiresAt = expiresAt
        self.attention = attention
    }
}

/// Session observer digest (live run headline and health).
public struct OpenClawChatSessionObserverDigest: Codable, Sendable, Hashable {
    /// Observed agent.
    public let agentId: String?
    /// Observed run.
    public let runId: String?
    /// Monotonic digest revision.
    public let revision: Int
    /// Update timestamp in milliseconds.
    public let updatedAt: Double
    /// Headline text.
    public let headline: String
    /// Health (`on-track`, `grinding`, `stuck`, `waiting-on-user`, `wrapping-up`, `done`, `failed`).
    public let health: String

    /// Creates an observer digest.
    public init(
        agentId: String? = nil,
        runId: String? = nil,
        revision: Int,
        updatedAt: Double,
        headline: String,
        health: String)
    {
        self.agentId = agentId
        self.runId = runId
        self.revision = revision
        self.updatedAt = updatedAt
        self.headline = headline
        self.health = health
    }

    /// Creates a digest from the generated `session.observer` event model.
    public init(_ digest: SessionObserverDigest) {
        self.init(
            agentId: digest.agentid,
            runId: digest.runid,
            revision: digest.revision,
            updatedAt: Double(digest.updatedat),
            headline: digest.headline,
            health: digest.health.rawValue)
    }
}

/// One gateway-advertised thinking level (`{id, label}`).
public struct OpenClawChatThinkingLevelOption: Codable, Identifiable, Sendable, Hashable {
    /// Level identifier (for example `high`, `xhigh`, `adaptive`, `max`).
    public let id: String
    /// Display label.
    public let label: String

    /// Creates a thinking level option.
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// Resolved thinking levels and default for the active session/model.
///
/// Only gateway-provided levels are shown; nothing is synthesized when the gateway omits metadata.
public struct OpenClawChatThinkingProfile: Sendable {
    /// Advertised levels.
    public let levels: [OpenClawChatThinkingLevelOption]?
    /// Default level.
    public let defaultLevel: String?

    /// Resolves the profile from the session row, then matching defaults, then the model choice.
    public static func resolve(
        session: OpenClawChatSessionEntry?,
        defaults: OpenClawChatSessionsDefaults?,
        model: OpenClawChatModelChoice?) -> Self?
    {
        if let profile = self.profile(
            levels: session?.thinkingLevels,
            legacyOptions: session?.thinkingOptions,
            defaultLevel: session?.thinkingDefault)
        {
            return profile
        }
        let defaultsMatch = (session?.modelProvider == nil || session?.modelProvider == defaults?.modelProvider) &&
            (session?.model == nil || session?.model == defaults?.model) &&
            self.routesMatch(session?.agentRuntime, defaults?.agentRuntime)
        if defaultsMatch, let profile = self.profile(
            levels: defaults?.thinkingLevels,
            legacyOptions: defaults?.thinkingOptions,
            defaultLevel: defaults?.thinkingDefault)
        {
            return profile
        }
        guard self.routesMatch(session?.agentRuntime, model?.agentRuntime) else { return nil }
        return self.profile(levels: model?.thinkingLevels, legacyOptions: nil, defaultLevel: model?.thinkingDefault)
    }

    private static func routesMatch(_ session: OpenClawChatAgentRuntime?, _ other: OpenClawChatAgentRuntime?) -> Bool {
        session?.id == nil || other?.id == nil || session?.id == other?.id
    }

    private static func profile(
        levels: [OpenClawChatThinkingLevelOption]?, legacyOptions: [String]?, defaultLevel: String?) -> Self?
    {
        guard levels != nil || legacyOptions != nil || defaultLevel != nil else { return nil }
        return Self(
            levels: levels ?? legacyOptions?.map { .init(id: $0.lowercased(), label: $0) },
            defaultLevel: defaultLevel)
    }
}

/// Session fast-mode setting; encodes `false`, `true`, or `"auto"`.
public enum OpenClawChatFastMode: Sendable, Equatable, Hashable, Codable {
    /// Fast mode disabled.
    case off
    /// Fast mode enabled.
    case on
    /// Gateway-chosen fast mode.
    case automatic

    /// Whether fast mode is on or automatic.
    public var isEnabled: Bool {
        self != .off
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let enabled = try? container.decode(Bool.self) {
            self = enabled ? .on : .off
            return
        }
        if try container.decode(String.self).lowercased() == "auto" {
            self = .automatic
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid fast mode")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .off:
            try container.encode(false)
        case .on:
            try container.encode(true)
        case .automatic:
            try container.encode("auto")
        }
    }
}

/// Resolved fast-mode state for the active session/model.
public struct OpenClawChatFastModeProfile: Sendable, Equatable {
    /// Whether the selected model supports fast mode.
    public let supportsFastMode: Bool
    /// Session override.
    public let override: OpenClawChatFastMode?
    /// Effective mode.
    public let effective: OpenClawChatFastMode?

    /// Whether fast mode is effectively enabled.
    public var isEnabled: Bool {
        self.effective?.isEnabled == true
    }

    /// Whether the composer should show fast-mode controls.
    public var showsControls: Bool {
        self.supportsFastMode || self.override != nil
    }

    /// Resolves the profile from the session row and model choice.
    public static func resolve(
        session: OpenClawChatSessionEntry?,
        model: OpenClawChatModelChoice?) -> Self
    {
        Self(
            supportsFastMode: model?.supportsFastMode == true,
            override: session?.fastMode,
            effective: session?.effectiveFastMode ?? session?.fastMode ?? model?.effectiveFastMode)
    }
}

/// Model picker choice from `models.list`.
public struct OpenClawChatModelChoice: Identifiable, Codable, Sendable, Hashable {
    /// Provider-qualified selection identifier.
    public var id: String {
        self.selectionID
    }

    /// Model identifier.
    public let modelID: String
    /// Display name.
    public let name: String
    /// Provider identifier.
    public let provider: String
    /// Whether the model is currently available for this session.
    public let available: Bool?
    /// Whether the user may pick the model manually.
    public let manualSelectionAllowed: Bool?
    /// Unavailability reason (`missing-auth`, `auth-failed`, `cooldown`, ...).
    public let unavailableReason: String?
    /// Cooldown end timestamp.
    public let unavailableUntil: Int?
    /// Context window in tokens.
    public let contextWindow: Int?
    /// Whether the model reasons (drives the thinking picker).
    public let reasoning: Bool?
    /// Whether the model supports fast mode.
    public let supportsFastMode: Bool?
    /// Effective fast mode for the model.
    public let effectiveFastMode: OpenClawChatFastMode?
    /// Gateway-advertised thinking levels.
    public let thinkingLevels: [OpenClawChatThinkingLevelOption]?
    /// Default thinking level.
    public let thinkingDefault: String?
    /// Accepted input modalities.
    public let input: [String]?
    /// Agent runtime that owns the model route.
    public let agentRuntime: OpenClawChatAgentRuntime?

    /// Creates a model choice.
    public init(
        modelID: String,
        name: String,
        provider: String,
        available: Bool? = nil,
        manualSelectionAllowed: Bool? = nil,
        unavailableReason: String? = nil,
        unavailableUntil: Int? = nil,
        contextWindow: Int?,
        reasoning: Bool? = nil,
        supportsFastMode: Bool? = nil,
        effectiveFastMode: OpenClawChatFastMode? = nil,
        thinkingLevels: [OpenClawChatThinkingLevelOption]? = nil,
        thinkingDefault: String? = nil,
        input: [String]? = nil,
        agentRuntime: OpenClawChatAgentRuntime? = nil)
    {
        self.modelID = modelID
        self.name = name
        self.provider = provider
        self.available = available
        self.manualSelectionAllowed = manualSelectionAllowed
        self.unavailableReason = unavailableReason
        self.unavailableUntil = unavailableUntil
        self.contextWindow = contextWindow
        self.reasoning = reasoning
        self.supportsFastMode = supportsFastMode
        self.effectiveFastMode = effectiveFastMode
        self.thinkingLevels = thinkingLevels
        self.thinkingDefault = thinkingDefault
        self.input = input
        self.agentRuntime = agentRuntime
    }

    /// Provider-qualified model ref used for picker identity and selection tags.
    public var selectionID: String {
        let trimmedProvider = self.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProvider.isEmpty else { return self.modelID }
        let providerPrefix = "\(trimmedProvider)/"
        if self.modelID.hasPrefix(providerPrefix) {
            return self.modelID
        }
        return "\(trimmedProvider)/\(self.modelID)"
    }

    /// Picker label.
    public var displayLabel: String {
        self.selectionID
    }

    /// Parsed unavailability reason.
    public var availabilityReason: OpenClawChatModelUnavailableReason? {
        OpenClawChatModelUnavailableReason(rawValue: self.unavailableReason)
    }

    /// Non-text input modalities and route source, joined for picker subtitles.
    public var capabilityDescription: String {
        var labels = (self.input ?? []).filter { $0 != "text" }.map { input in
            switch input {
            case "image": String(localized: "Images")
            case "audio": String(localized: "Audio")
            case "video": String(localized: "Video")
            case "document": String(localized: "Documents")
            default: input
            }
        }
        if let route = self.agentRuntime, route.source == "model" || route.source == "provider" {
            labels.append(route.id)
        }
        return labels.joined(separator: " · ")
    }
}

/// Why a model is unavailable.
public enum OpenClawChatModelUnavailableReason: Sendable, Equatable, Hashable {
    /// No provider credential is configured.
    case missingAuth
    /// Authentication failed.
    case authFailed
    /// The provider is cooling down.
    case cooldown
    /// Another reason.
    case unknown(String)

    /// Parses a wire reason.
    public init?(rawValue: String?) {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else { return nil }
        switch value {
        case "missing-auth": self = .missingAuth
        case "auth-failed": self = .authFailed
        case "cooldown": self = .cooldown
        default: self = .unknown(value)
        }
    }

    /// Picker description.
    public var pickerDescription: String {
        switch self {
        case .missingAuth: String(localized: "Sign-in needed")
        case .authFailed: String(localized: "Authentication failed")
        case .cooldown: String(localized: "Cooling down")
        case .unknown: String(localized: "Unavailable")
        }
    }

    /// Whether the reason blocks sending with the model.
    package var blocksSend: Bool {
        self == .missingAuth || self == .authFailed
    }
}

/// `sessions.patch` settings update.
///
/// For each field the outer optional means "unchanged" and the inner optional clears the override.
public struct OpenClawChatSessionSettingsPatch: Sendable, Equatable {
    /// Session identity the patch must still match.
    public let expectedSessionID: String?
    /// Permission mode the session must still have (compare-and-swap).
    public let expectedPermissionMode: OpenClawChatPermissionMode??
    /// Tool overrides the session must still have (compare-and-swap).
    public let expectedToolOverrides: OpenClawChatSessionToolOverrides??
    /// Model override.
    public let model: String??
    /// Thinking level override.
    public let thinkingLevel: String??
    /// Fast mode override.
    public let fastMode: OpenClawChatFastMode??
    /// Verbose level override.
    public let verboseLevel: String??
    /// Permission mode override.
    public let permissionMode: OpenClawChatPermissionMode??
    /// Tool overrides.
    public let toolOverrides: OpenClawChatSessionToolOverrides??

    /// Creates a settings patch.
    public init(
        expectedSessionID: String? = nil,
        expectedPermissionMode: OpenClawChatPermissionMode?? = nil,
        expectedToolOverrides: OpenClawChatSessionToolOverrides?? = nil,
        model: String?? = nil,
        thinkingLevel: String?? = nil,
        fastMode: OpenClawChatFastMode?? = nil,
        verboseLevel: String?? = nil,
        permissionMode: OpenClawChatPermissionMode?? = nil,
        toolOverrides: OpenClawChatSessionToolOverrides?? = nil)
    {
        self.expectedSessionID = expectedSessionID
        self.expectedPermissionMode = expectedPermissionMode
        self.expectedToolOverrides = expectedToolOverrides
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.fastMode = fastMode
        self.verboseLevel = verboseLevel
        self.permissionMode = permissionMode
        self.toolOverrides = toolOverrides
    }

    /// Returns a copy scoped to a session identity and optional compare-and-swap expectations.
    package func withExpectedSessionID(
        _ expectedSessionID: String,
        expectedPermissionMode: OpenClawChatPermissionMode?? = nil,
        expectedToolOverrides: OpenClawChatSessionToolOverrides?? = nil) -> Self
    {
        Self(
            expectedSessionID: expectedSessionID,
            expectedPermissionMode: expectedPermissionMode,
            expectedToolOverrides: expectedToolOverrides,
            model: self.model,
            thinkingLevel: self.thinkingLevel,
            fastMode: self.fastMode,
            verboseLevel: self.verboseLevel,
            permissionMode: self.permissionMode,
            toolOverrides: self.toolOverrides)
    }
}

/// Authority-bearing session settings a chat turn must still match at admission.
public struct OpenClawChatSessionSettingsExpectation: Codable, Hashable, Sendable {
    /// Expected permission mode.
    public let permissionMode: OpenClawChatPermissionMode?
    /// Expected tool overrides.
    public let toolOverrides: OpenClawChatSessionToolOverrides?

    /// Creates an expectation.
    public init(
        permissionMode: OpenClawChatPermissionMode?,
        toolOverrides: OpenClawChatSessionToolOverrides?)
    {
        self.permissionMode = permissionMode
        self.toolOverrides = toolOverrides
    }
}

/// Routing and settings fence for one `chat.send`.
public struct OpenClawChatSendTarget: Hashable, Sendable {
    /// Explicit owning agent for bare keys.
    public let agentID: String?
    /// Routing contract the gateway must still match.
    public let expectedSessionRoutingContract: String?
    /// Settings the session must still match.
    public let expectedSessionSettings: OpenClawChatSessionSettingsExpectation?

    /// Creates a send target.
    public init(
        agentID: String?,
        expectedSessionRoutingContract: String?,
        expectedSessionSettings: OpenClawChatSessionSettingsExpectation?)
    {
        self.agentID = agentID
        self.expectedSessionRoutingContract = expectedSessionRoutingContract
        self.expectedSessionSettings = expectedSessionSettings
    }
}

/// Authoritative model identity and thinking state returned by `sessions.patch`.
public struct OpenClawChatModelPatchResult: Decodable, Sendable, Equatable {
    /// Canonical session key.
    public let key: String?
    /// Resolved provider.
    public let modelProvider: String?
    /// Resolved model.
    public let model: String?
    /// Resolved thinking level.
    public let thinkingLevel: String?
    /// Thinking levels for the resolved model.
    public let thinkingLevels: [OpenClawChatThinkingLevelOption]?
    /// Fast mode override.
    public let fastMode: OpenClawChatFastMode?
    /// Effective fast mode.
    public let effectiveFastMode: OpenClawChatFastMode?
    /// Verbose level.
    public let verboseLevel: String?
    /// Permission mode.
    public let permissionMode: OpenClawChatPermissionMode?
    /// Tool overrides.
    public let toolOverrides: OpenClawChatSessionToolOverrides?

    /// Creates a patch result.
    public init(
        key: String? = nil,
        modelProvider: String?,
        model: String?,
        thinkingLevel: String?,
        thinkingLevels: [OpenClawChatThinkingLevelOption]? = nil,
        fastMode: OpenClawChatFastMode? = nil,
        effectiveFastMode: OpenClawChatFastMode? = nil,
        verboseLevel: String? = nil,
        permissionMode: OpenClawChatPermissionMode? = nil,
        toolOverrides: OpenClawChatSessionToolOverrides? = nil)
    {
        self.key = key
        self.modelProvider = modelProvider
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.thinkingLevels = thinkingLevels
        self.fastMode = fastMode
        self.effectiveFastMode = effectiveFastMode
        self.verboseLevel = verboseLevel
        self.permissionMode = permissionMode
        self.toolOverrides = toolOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case entry
        case resolved
    }

    private enum EntryKeys: String, CodingKey {
        case modelProvider
        case model
        case providerOverride
        case modelOverride
        case thinkingLevel
        case fastMode
        case effectiveFastMode
        case verboseLevel
        case permissionMode
        case toolOverrides
    }

    private enum ResolvedKeys: String, CodingKey {
        case modelProvider
        case model
        case thinkingLevel
        case thinkingLevels
        case fastMode
        case effectiveFastMode
        case verboseLevel
        case permissionMode
        case toolOverrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entry = try container.nestedContainer(keyedBy: EntryKeys.self, forKey: .entry)
        self.key = try container.decodeIfPresent(String.self, forKey: .key)
        let entryModelProvider = try entry.decodeIfPresent(String.self, forKey: .modelProvider)
            ?? entry.decodeIfPresent(String.self, forKey: .providerOverride)
        let entryModel = try entry.decodeIfPresent(String.self, forKey: .model)
            ?? entry.decodeIfPresent(String.self, forKey: .modelOverride)
        let entryThinkingLevel = try entry.decodeIfPresent(String.self, forKey: .thinkingLevel)
        let entryFastMode = try entry.decodeIfPresent(OpenClawChatFastMode.self, forKey: .fastMode)
        let entryEffectiveFastMode = try entry.decodeIfPresent(
            OpenClawChatFastMode.self,
            forKey: .effectiveFastMode)
        let entryVerboseLevel = try entry.decodeIfPresent(String.self, forKey: .verboseLevel)
        let entryPermissionMode = try entry.decodeIfPresent(
            OpenClawChatPermissionMode.self,
            forKey: .permissionMode)
        let entryToolOverrides = try entry.decodeIfPresent(
            OpenClawChatSessionToolOverrides.self,
            forKey: .toolOverrides)
        if container.contains(.resolved) {
            let resolved = try container.nestedContainer(keyedBy: ResolvedKeys.self, forKey: .resolved)
            self.modelProvider = try resolved.decodeIfPresent(String.self, forKey: .modelProvider)
                ?? entryModelProvider
            self.model = try resolved.decodeIfPresent(String.self, forKey: .model)
                ?? entryModel
            let resolvedThinkingLevel = try resolved.decodeIfPresent(String.self, forKey: .thinkingLevel)
            self.thinkingLevel = resolvedThinkingLevel ?? entryThinkingLevel
            self.thinkingLevels = try resolved.decodeIfPresent(
                [OpenClawChatThinkingLevelOption].self,
                forKey: .thinkingLevels)
            self.fastMode = try resolved.decodeIfPresent(OpenClawChatFastMode.self, forKey: .fastMode)
                ?? entryFastMode
            self.effectiveFastMode = try resolved.decodeIfPresent(
                OpenClawChatFastMode.self,
                forKey: .effectiveFastMode) ?? entryEffectiveFastMode
            self.verboseLevel = try resolved.decodeIfPresent(String.self, forKey: .verboseLevel)
                ?? entryVerboseLevel
            self.permissionMode = try resolved.decodeIfPresent(
                OpenClawChatPermissionMode.self,
                forKey: .permissionMode) ?? entryPermissionMode
            self.toolOverrides = try resolved.decodeIfPresent(
                OpenClawChatSessionToolOverrides.self,
                forKey: .toolOverrides) ?? entryToolOverrides
        } else {
            self.modelProvider = entryModelProvider
            self.model = entryModel
            self.thinkingLevel = entryThinkingLevel
            self.thinkingLevels = nil
            self.fastMode = entryFastMode
            self.effectiveFastMode = entryEffectiveFastMode
            self.verboseLevel = entryVerboseLevel
            self.permissionMode = entryPermissionMode
            self.toolOverrides = entryToolOverrides
        }
    }
}

/// `sessions.list` defaults block.
public struct OpenClawChatSessionsDefaults: Codable, Sendable {
    /// Default agent runtime.
    public let agentRuntime: OpenClawChatAgentRuntime?
    /// Default provider.
    public let modelProvider: String?
    /// Default model.
    public let model: String?
    /// What a model selection changes (`session`, `agent`, `global`).
    public let modelSelectionTarget: String?
    /// Default context window.
    public let contextTokens: Int?
    /// Default thinking levels.
    public let thinkingLevels: [OpenClawChatThinkingLevelOption]?
    /// Legacy thinking option labels.
    public let thinkingOptions: [String]?
    /// Default thinking level.
    public let thinkingDefault: String?
    /// Main session key.
    public let mainSessionKey: String?

    /// Creates session defaults.
    public init(
        modelProvider: String? = nil,
        model: String?,
        contextTokens: Int?,
        thinkingLevels: [OpenClawChatThinkingLevelOption]? = nil,
        thinkingOptions: [String]? = nil,
        thinkingDefault: String? = nil,
        mainSessionKey: String? = nil,
        modelSelectionTarget: String? = nil,
        agentRuntime: OpenClawChatAgentRuntime? = nil)
    {
        self.modelProvider = modelProvider
        self.agentRuntime = agentRuntime
        self.model = model
        self.modelSelectionTarget = modelSelectionTarget
        self.contextTokens = contextTokens
        self.thinkingLevels = thinkingLevels
        self.thinkingOptions = thinkingOptions
        self.thinkingDefault = thinkingDefault
        self.mainSessionKey = mainSessionKey
    }
}

/// Worktree metadata attached to a work session.
public struct OpenClawChatSessionWorktree: Codable, Sendable, Hashable {
    /// Worktree identifier.
    public let id: String?
    /// Branch name.
    public let branch: String?
    /// Repository root.
    public let repoRoot: String?

    /// Creates worktree metadata.
    public init(id: String?, branch: String?, repoRoot: String?) {
        self.id = id
        self.branch = branch
        self.repoRoot = repoRoot
    }
}

/// Effective agent runtime metadata for a session or model route.
public struct OpenClawChatAgentRuntime: Codable, Sendable, Hashable {
    /// Runtime identifier.
    public let id: String
    /// Fallback runtime.
    public let fallback: String?
    /// Where the runtime was selected (`model`, `provider`, `agent`, ...).
    public let source: String?

    /// Creates agent runtime metadata.
    public init(id: String, fallback: String? = nil, source: String? = nil) {
        self.id = id
        self.fallback = fallback
        self.source = source
    }
}

/// One session group (sidebar category).
public struct OpenClawChatSessionGroup: Codable, Identifiable, Sendable, Hashable {
    /// Group name.
    public var id: String {
        self.name
    }

    /// Group name.
    public let name: String
    /// Sort position.
    public let position: Int

    /// Creates a session group.
    public init(name: String, position: Int) {
        self.name = name
        self.position = position
    }
}

/// `sessions.groups.list` response.
public struct OpenClawChatSessionGroupsResponse: Codable, Sendable, Equatable {
    /// Groups.
    public let groups: [OpenClawChatSessionGroup]

    /// Creates a groups response.
    public init(groups: [OpenClawChatSessionGroup]) {
        self.groups = groups
    }
}

/// `sessions.groups.put/rename/delete` response.
public struct OpenClawChatSessionGroupsMutationResponse: Codable, Sendable, Equatable {
    /// Whether the mutation succeeded.
    public let ok: Bool
    /// Resulting groups.
    public let groups: [OpenClawChatSessionGroup]
    /// Sessions whose category changed.
    public let updatedSessions: Int?

    /// Creates a mutation response.
    public init(ok: Bool, groups: [OpenClawChatSessionGroup], updatedSessions: Int? = nil) {
        self.ok = ok
        self.groups = groups
        self.updatedSessions = updatedSessions
    }
}

/// Agent choice from `agents.list`.
public struct OpenClawChatAgentChoice: Codable, Identifiable, Sendable, Hashable {
    /// Agent identifier.
    public let id: String
    /// Display name.
    public let name: String?
    /// Identity emoji.
    public let emoji: String?
    /// Whether the agent workspace is a git repository (enables worktree sessions).
    public let workspaceGit: Bool?

    /// Creates an agent choice.
    public init(id: String, name: String? = nil, emoji: String? = nil, workspaceGit: Bool? = nil) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.workspaceGit = workspaceGit
    }

    /// Name, or the identifier when the name is blank.
    public var displayName: String {
        let normalized = self.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return self.id }
        return normalized
    }
}

/// Normalized `agents.list` response.
public struct OpenClawChatAgentsListResponse: Codable, Sendable, Equatable {
    /// Default agent.
    public let defaultId: String
    /// Selectable agents.
    public let agents: [OpenClawChatAgentChoice]
    /// Routing contract (`scope|mainKey|defaultAgentId`).
    public let sessionRoutingContract: String?

    /// Creates an agents list response.
    public init(
        defaultId: String,
        agents: [OpenClawChatAgentChoice],
        sessionRoutingContract: String? = nil)
    {
        self.defaultId = defaultId
        self.agents = agents
        self.sessionRoutingContract = sessionRoutingContract
    }
}

/// One `sessions.list` row.
public struct OpenClawChatSessionEntry: Codable, Identifiable, Sendable, Hashable {
    /// Session key.
    public var id: String {
        self.key
    }

    /// Session key.
    public var key: String
    /// Session kind.
    public var kind: String?
    /// Generated display name.
    public var displayName: String?
    /// Derived title.
    public var derivedTitle: String?
    /// Non-sensitive facts derived by the Gateway from the canonical session route.
    public var classification: String?
    /// Board face.
    public var boardFace: String?
    /// Owning agent.
    public var agentId: String?
    /// Channel account.
    public var accountId: String?
    /// Peer kind.
    public var peerKind: String?
    /// Whether this is the agent's main session.
    public var isMain: Bool?
    /// Whether this is a background session.
    public var isBackground: Bool?
    /// Explicit label.
    public var label: String?
    /// Automatic device label; explicit labels and generated display names take precedence.
    public var autoLabel: String?
    /// Group/category.
    public var category: String?
    /// Color tag.
    public var color: String?
    /// Whether pinned.
    public var pinned: Bool?
    /// Pin timestamp.
    public var pinnedAt: Double?
    /// Whether archived.
    public var archived: Bool?
    /// Archive timestamp.
    public var archivedAt: Double?
    /// Whether marked unread.
    public var unread: Bool?
    /// Declared agent status.
    public var agentStatus: OpenClawChatSessionAgentStatus?
    /// Observer digest.
    public var observerDigest: OpenClawChatSessionObserverDigest?
    /// Surface.
    public var surface: String?
    /// Subject.
    public var subject: String?
    /// Room.
    public var room: String?
    /// Space.
    public var space: String?
    /// Update timestamp.
    public var updatedAt: Double?
    /// Last-read timestamp.
    public var lastReadAt: Double?
    /// Marked-unread timestamp.
    public var markedUnreadAt: Double?
    /// Last interaction timestamp.
    public var lastInteractionAt: Double?
    /// Last activity timestamp.
    public var lastActivityAt: Double?
    /// Session identifier.
    public var sessionId: String?

    /// Parent session key.
    public var parentSessionKey: String?
    /// Spawning session key.
    public var spawnedBy: String?
    /// Child session keys.
    public var childSessions: [String]?
    /// Run status (`running`, `queued`, `done`, `failed`, ...).
    public var status: String?
    /// Last run error.
    public var lastRunError: String?
    /// Whether a run is active.
    public var hasActiveRun: Bool?
    /// Active run identifiers.
    public var activeRunIds: [String]?
    /// Whether a subagent run is active.
    public var hasActiveSubagentRun: Bool?
    /// Subagent run state.
    public var subagentRunState: String?
    /// Swarm group.
    public var swarmGroupId: String?
    /// Swarm phase.
    public var swarmPhase: String?
    /// Swarm phase rank.
    public var swarmPhaseRank: Int?
    /// Swarm narrator log.
    public var swarmLog: String?
    /// Worktree metadata.
    public var worktree: OpenClawChatSessionWorktree?
    /// Run start timestamp.
    public var startedAt: Double?
    /// Run end timestamp.
    public var endedAt: Double?
    /// Run duration in milliseconds.
    public var runtimeMs: Double?
    /// Effective agent runtime.
    public var agentRuntime: OpenClawChatAgentRuntime?

    /// Whether the system prompt was sent.
    public var systemSent: Bool?
    /// Whether the last run aborted.
    public var abortedLastRun: Bool?
    /// Thinking level override.
    public var thinkingLevel: String?
    /// Verbose level override.
    public var verboseLevel: String?
    /// Fast mode override.
    public var fastMode: OpenClawChatFastMode?
    /// Effective fast mode.
    public var effectiveFastMode: OpenClawChatFastMode?
    /// Permission mode.
    public var permissionMode: OpenClawChatPermissionMode?
    /// Tool overrides.
    public var toolOverrides: OpenClawChatSessionToolOverrides?

    /// Input tokens.
    public var inputTokens: Int?
    /// Output tokens.
    public var outputTokens: Int?
    /// Total tokens.
    public var totalTokens: Int?
    /// Whether ``totalTokens`` is fresh.
    public var totalTokensFresh: Bool?

    /// Provider.
    public var modelProvider: String?
    /// Model.
    public var model: String?
    /// Context window.
    public var contextTokens: Int?
    /// Thinking levels for the session model.
    public var thinkingLevels: [OpenClawChatThinkingLevelOption]?
    /// Legacy thinking option labels.
    public var thinkingOptions: [String]?
    /// Default thinking level.
    public var thinkingDefault: String?

    /// Creates a session row.
    public init(
        key: String,
        kind: String?,
        displayName: String?,
        classification: String? = nil,
        boardFace: String? = nil,
        agentId: String? = nil,
        accountId: String? = nil,
        peerKind: String? = nil,
        isMain: Bool? = nil,
        isBackground: Bool? = nil,
        surface: String?,
        subject: String?,
        room: String?,
        space: String?,
        updatedAt: Double?,
        sessionId: String?,
        systemSent: Bool?,
        abortedLastRun: Bool?,
        thinkingLevel: String?,
        verboseLevel: String?,
        inputTokens: Int?,
        outputTokens: Int?,
        totalTokens: Int?,
        totalTokensFresh: Bool? = nil,
        modelProvider: String?,
        model: String?,
        contextTokens: Int?,
        thinkingLevels: [OpenClawChatThinkingLevelOption]? = nil,
        thinkingOptions: [String]? = nil,
        thinkingDefault: String? = nil,
        label: String? = nil,
        autoLabel: String? = nil,
        category: String? = nil,
        color: String? = nil,
        pinned: Bool? = nil,
        pinnedAt: Double? = nil,
        archived: Bool? = nil,
        archivedAt: Double? = nil,
        unread: Bool? = nil,
        agentStatus: OpenClawChatSessionAgentStatus? = nil,
        observerDigest: OpenClawChatSessionObserverDigest? = nil,
        lastReadAt: Double? = nil,
        markedUnreadAt: Double? = nil,
        lastInteractionAt: Double? = nil,
        lastActivityAt: Double? = nil,
        parentSessionKey: String? = nil,
        spawnedBy: String? = nil,
        childSessions: [String]? = nil,
        status: String? = nil,
        lastRunError: String? = nil,
        hasActiveRun: Bool? = nil,
        activeRunIds: [String]? = nil,
        hasActiveSubagentRun: Bool? = nil,
        subagentRunState: String? = nil,
        swarmGroupId: String? = nil,
        swarmPhase: String? = nil,
        swarmPhaseRank: Int? = nil,
        swarmLog: String? = nil,
        worktree: OpenClawChatSessionWorktree? = nil,
        fastMode: OpenClawChatFastMode? = nil,
        effectiveFastMode: OpenClawChatFastMode? = nil,
        permissionMode: OpenClawChatPermissionMode? = nil,
        toolOverrides: OpenClawChatSessionToolOverrides? = nil,
        startedAt: Double? = nil,
        endedAt: Double? = nil,
        runtimeMs: Double? = nil,
        agentRuntime: OpenClawChatAgentRuntime? = nil,
        derivedTitle: String? = nil)
    {
        self.key = key
        self.kind = kind
        self.displayName = displayName
        self.derivedTitle = derivedTitle
        self.classification = classification
        self.boardFace = boardFace
        self.agentId = agentId
        self.accountId = accountId
        self.peerKind = peerKind
        self.isMain = isMain
        self.isBackground = isBackground
        self.label = label
        self.autoLabel = autoLabel
        self.category = category
        self.color = color
        self.pinned = pinned
        self.pinnedAt = pinnedAt
        self.archived = archived
        self.archivedAt = archivedAt
        self.unread = unread
        self.agentStatus = agentStatus
        self.observerDigest = observerDigest
        self.surface = surface
        self.subject = subject
        self.room = room
        self.space = space
        self.updatedAt = updatedAt
        self.lastReadAt = lastReadAt
        self.markedUnreadAt = markedUnreadAt
        self.lastInteractionAt = lastInteractionAt
        self.lastActivityAt = lastActivityAt
        self.sessionId = sessionId
        self.parentSessionKey = parentSessionKey
        self.spawnedBy = spawnedBy
        self.childSessions = childSessions
        self.status = status
        self.lastRunError = lastRunError
        self.hasActiveRun = hasActiveRun
        self.activeRunIds = activeRunIds
        self.hasActiveSubagentRun = hasActiveSubagentRun
        self.subagentRunState = subagentRunState
        self.swarmGroupId = swarmGroupId
        self.swarmPhase = swarmPhase
        self.swarmPhaseRank = swarmPhaseRank
        self.swarmLog = swarmLog
        self.worktree = worktree
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.runtimeMs = runtimeMs
        self.agentRuntime = agentRuntime
        self.systemSent = systemSent
        self.abortedLastRun = abortedLastRun
        self.thinkingLevel = thinkingLevel
        self.verboseLevel = verboseLevel
        self.fastMode = fastMode
        self.effectiveFastMode = effectiveFastMode
        self.permissionMode = permissionMode
        self.toolOverrides = toolOverrides
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.totalTokensFresh = totalTokensFresh
        self.modelProvider = modelProvider
        self.model = model
        self.contextTokens = contextTokens
        self.thinkingLevels = thinkingLevels
        self.thinkingOptions = thinkingOptions
        self.thinkingDefault = thinkingDefault
    }

    /// Minimal row used while a freshly selected session has not appeared in `sessions.list` yet.
    package static func placeholder(key: String) -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: key,
            kind: nil,
            displayName: nil,
            surface: nil,
            subject: nil,
            room: nil,
            space: nil,
            updatedAt: nil,
            sessionId: nil,
            systemSent: nil,
            abortedLastRun: nil,
            thinkingLevel: nil,
            verboseLevel: nil,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            modelProvider: nil,
            model: nil,
            contextTokens: nil)
    }

    /// Whether the row is pinned.
    public var isPinned: Bool {
        self.pinned == true
    }

    /// Whether the row is archived.
    public var isArchived: Bool {
        self.archived == true
    }
}

/// Client-side session list policy shared by every session list surface.
/// Ordering mirrors the gateway (`pinnedAt` desc, `updatedAt` desc, key) so
/// cached/offline lists render in the same order as server responses.
public enum OpenClawChatSessionListOrganizer {
    /// Sorts rows by pin time, update time, then key.
    public static func organize(_ sessions: [OpenClawChatSessionEntry]) -> [OpenClawChatSessionEntry] {
        sessions.sorted { lhs, rhs in
            let lhsPinnedAt = lhs.pinnedAt ?? (lhs.isPinned ? .greatestFiniteMagnitude : 0)
            let rhsPinnedAt = rhs.pinnedAt ?? (rhs.isPinned ? .greatestFiniteMagnitude : 0)
            if lhsPinnedAt != rhsPinnedAt {
                return lhsPinnedAt > rhsPinnedAt
            }
            let lhsUpdatedAt = lhs.updatedAt ?? 0
            let rhsUpdatedAt = rhs.updatedAt ?? 0
            if lhsUpdatedAt != rhsUpdatedAt {
                return lhsUpdatedAt > rhsUpdatedAt
            }
            return lhs.key < rhs.key
        }
    }

    /// Local fallback for the server-side `sessions.list` search when the
    /// gateway is unreachable and only cached entries are available.
    public static func filter(
        _ sessions: [OpenClawChatSessionEntry],
        search: String) -> [OpenClawChatSessionEntry]
    {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            [session.displayName, session.label, session.subject, session.sessionId, session.category, session.key]
                .contains { $0?.lowercased().contains(query) == true }
        }
    }
}

/// Collects every child row across `sessions.list` pages with bounded retries and request counts.
public enum OpenClawChatChildSessionPager {
    private static let maxCollectedSessions = 100_000
    private static let maxPageRequests = 100

    /// Fetches pages by offset until the gateway reports no more rows, then returns the union by key.
    public static func collect(
        fetchPage: (Int) async throws -> OpenClawChatSessionsListResponse) async throws
        -> [OpenClawChatSessionEntry]
    {
        var rowsByKey: [String: OpenClawChatSessionEntry] = [:]
        var remainingPageRequests = Self.maxPageRequests
        for _ in 0..<4 {
            let rowsBeforePass = rowsByKey.count
            var expectedTotal: Int?
            var seenOffsets = Set<Int>()
            var offset = 0
            while remainingPageRequests > 0,
                  rowsByKey.count < Self.maxCollectedSessions,
                  seenOffsets.insert(offset).inserted
            {
                remainingPageRequests -= 1
                let page = try await fetchPage(offset)
                expectedTotal = page.totalCount
                for row in page.sessions {
                    rowsByKey[row.key] = row
                    if rowsByKey.count >= Self.maxCollectedSessions {
                        break
                    }
                }
                if rowsByKey.count >= Self.maxCollectedSessions {
                    return Array(rowsByKey.values)
                }
                let hasMore = page.hasMore ?? expectedTotal.map { offset + page.sessions.count < $0 } ?? false
                let nextOffset = page.nextOffset ?? (offset + page.sessions.count)
                guard hasMore, !page.sessions.isEmpty, nextOffset > offset else { break }
                offset = nextOffset
            }
            let added = rowsByKey.count - rowsBeforePass
            if remainingPageRequests == 0 ||
                added == 0 ||
                expectedTotal.map({ rowsByKey.count >= $0 }) != false
            {
                break
            }
        }
        return Array(rowsByKey.values)
    }
}

/// `sessions.list` response, including paging/truncation metadata.
public struct OpenClawChatSessionsListResponse: Codable, Sendable {
    /// Server timestamp.
    public let ts: Double?
    /// Store path.
    public let path: String?
    /// Rows in this page.
    public let count: Int?
    /// Total rows matching the query (bounded responses report truncation through this).
    public let totalCount: Int?
    /// Offset of this page.
    public let offset: Int?
    /// Offset of the next page.
    public let nextOffset: Int?
    /// Whether more rows exist.
    public let hasMore: Bool?
    /// Defaults block.
    public let defaults: OpenClawChatSessionsDefaults?
    /// Rows.
    public let sessions: [OpenClawChatSessionEntry]

    /// Creates a sessions list response.
    public init(
        ts: Double?,
        path: String?,
        count: Int?,
        totalCount: Int? = nil,
        offset: Int? = nil,
        nextOffset: Int? = nil,
        hasMore: Bool? = nil,
        defaults: OpenClawChatSessionsDefaults?,
        sessions: [OpenClawChatSessionEntry])
    {
        self.ts = ts
        self.path = path
        self.count = count
        self.totalCount = totalCount
        self.offset = offset
        self.nextOffset = nextOffset
        self.hasMore = hasMore
        self.defaults = defaults
        self.sessions = sessions
    }

    /// Whether the gateway returned fewer rows than exist (bounded default responses).
    public var isTruncated: Bool {
        if self.hasMore == true { return true }
        guard let totalCount else { return false }
        return (self.offset ?? 0) + self.sessions.count < totalCount
    }
}
