import Foundation

// Ported from upstream OpenClaw 2026.9.6 `ChatComposerCapabilities.swift` (model types only; the
// observable loading state lives with the view model in `ChatViewModel+ComposerCapabilities.swift`).

/// Session permission mode (`read-only`, `guarded`, `workspace`, `full`).
public enum OpenClawChatPermissionMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Read-only tools.
    case readOnly = "read-only"
    /// Guarded (approval-gated) tools.
    case guarded
    /// Workspace-scoped tools.
    case workspace
    /// Unrestricted tools.
    case full

    /// Localized display name.
    public var displayName: String {
        switch self {
        case .readOnly: String(localized: "Read-only")
        case .guarded: String(localized: "Guarded")
        case .workspace: String(localized: "Workspace")
        case .full: String(localized: "Full")
        }
    }
}

/// Per-session tool overrides (web search, skills, MCP servers, denied MCP tools).
public struct OpenClawChatSessionToolOverrides: Codable, Hashable, Sendable {
    /// Web search override.
    public var webSearch: Bool?
    /// Skill enablement overrides keyed by skill.
    public var skills: [String: Bool]
    /// MCP server enablement overrides keyed by server.
    public var mcpServers: [String: Bool]
    /// Denied MCP tools keyed by server.
    public var mcpToolsDeny: [String: [String]]

    /// Creates tool overrides.
    public init(
        webSearch: Bool? = nil,
        skills: [String: Bool] = [:],
        mcpServers: [String: Bool] = [:],
        mcpToolsDeny: [String: [String]] = [:])
    {
        self.webSearch = webSearch
        self.skills = skills
        self.mcpServers = mcpServers
        self.mcpToolsDeny = mcpToolsDeny
    }

    /// Whether no override is set.
    public var isEmpty: Bool {
        self.webSearch == nil && self.skills.isEmpty && self.mcpServers.isEmpty && self.mcpToolsDeny.isEmpty
    }

    /// Number of individual overrides.
    public var overrideCount: Int {
        (self.webSearch == nil ? 0 : 1) + self.skills.count + self.mcpServers.count +
            self.mcpToolsDeny.values.reduce(0) { $0 + $1.count }
    }

    private enum CodingKeys: String, CodingKey {
        case webSearch
        case skills
        case mcpServers
        case mcpToolsDeny
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.webSearch = try container.decodeIfPresent(Bool.self, forKey: .webSearch)
        self.skills = try container.decodeIfPresent([String: Bool].self, forKey: .skills) ?? [:]
        self.mcpServers = try container.decodeIfPresent([String: Bool].self, forKey: .mcpServers) ?? [:]
        self.mcpToolsDeny = try container.decodeIfPresent([String: [String]].self, forKey: .mcpToolsDeny) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.webSearch, forKey: .webSearch)
        if !self.skills.isEmpty { try container.encode(self.skills, forKey: .skills) }
        if !self.mcpServers.isEmpty { try container.encode(self.mcpServers, forKey: .mcpServers) }
        if !self.mcpToolsDeny.isEmpty { try container.encode(self.mcpToolsDeny, forKey: .mcpToolsDeny) }
    }
}

/// Skill row in the composer capability catalog.
public struct OpenClawChatComposerSkill: Identifiable, Equatable, Sendable {
    /// Skill key.
    public let key: String
    /// Display name.
    public let name: String
    /// Whether enabled in gateway configuration.
    public let baseEnabled: Bool
    /// Whether dependencies are missing.
    public let missingDependencies: Bool
    /// Whether blocked by policy.
    public let blocked: Bool
    /// Whether filtered out for the agent.
    public let agentFiltered: Bool

    /// Skill key.
    public var id: String {
        self.key
    }

    /// Creates a composer skill.
    public init(
        key: String,
        name: String,
        baseEnabled: Bool,
        missingDependencies: Bool,
        blocked: Bool,
        agentFiltered: Bool = false)
    {
        self.key = key
        self.name = name
        self.baseEnabled = baseEnabled
        self.missingDependencies = missingDependencies
        self.blocked = blocked
        self.agentFiltered = agentFiltered
    }
}

/// Tool exposed by an MCP connector.
public struct OpenClawChatComposerTool: Identifiable, Equatable, Sendable {
    /// Tool name.
    public let name: String
    /// Display label.
    public let label: String
    /// Whether enabled by default.
    public let baseEnabled: Bool
    /// Whether denied for this session.
    public let sessionDenied: Bool

    /// Tool name.
    public var id: String {
        self.name
    }

    /// Creates a composer tool.
    public init(
        name: String,
        label: String,
        baseEnabled: Bool = true,
        sessionDenied: Bool = false)
    {
        self.name = name
        self.label = label
        self.baseEnabled = baseEnabled
        self.sessionDenied = sessionDenied
    }
}

/// MCP connector in the composer capability catalog.
public struct OpenClawChatComposerConnector: Identifiable, Equatable, Sendable {
    /// Server name.
    public let name: String
    /// Whether enabled by default.
    public let baseEnabled: Bool
    /// Tools.
    public let tools: [OpenClawChatComposerTool]
    /// Connector notice.
    public let notice: String?

    /// Server name.
    public var id: String {
        self.name
    }

    /// Creates a composer connector.
    public init(
        name: String,
        baseEnabled: Bool,
        tools: [OpenClawChatComposerTool],
        notice: String? = nil)
    {
        self.name = name
        self.baseEnabled = baseEnabled
        self.tools = tools
        self.notice = notice
    }
}

/// Capability catalog assembled from `skills.status`, `tools.effective`, and `config.get`.
public struct OpenClawChatComposerCapabilityCatalog: Equatable, Sendable {
    /// Whether session settings controls are available.
    public let sessionSettingsAvailable: Bool
    /// Whether the model may be changed.
    public let modelMutationAvailable: Bool
    /// Whether thinking/fast/verbose may be changed.
    public let effortMutationAvailable: Bool
    /// Whether web search is enabled in configuration.
    public let webSearchBaseEnabled: Bool
    /// Whether web search exists on the gateway.
    public let webSearchAvailable: Bool
    /// Skills.
    public let skills: [OpenClawChatComposerSkill]
    /// Connectors.
    public let connectors: [OpenClawChatComposerConnector]
    /// Whether skills loaded.
    public let skillsAvailable: Bool
    /// Whether connectors loaded.
    public let connectorsAvailable: Bool
    /// Whether tool access loaded.
    public let toolAccessAvailable: Bool
    /// Whether the permission mode may be changed.
    public let permissionMutationAvailable: Bool
    /// Whether the gateway supports settings compare-and-swap.
    public let sessionSettingsCASAvailable: Bool
    /// Whether tool overrides may be changed.
    public let toolOverrideMutationAvailable: Bool
    /// Whether tool overrides need a newer gateway.
    public let toolOverrideMutationRequiresGatewayUpgrade: Bool
    /// Whether `full` permission may be selected.
    public let canSelectFullPermission: Bool
    /// Partial-load failure message.
    public let loadFailureMessage: String?

    /// Creates a capability catalog (all capabilities off by default).
    public init(
        sessionSettingsAvailable: Bool = false,
        modelMutationAvailable: Bool = false,
        effortMutationAvailable: Bool = false,
        webSearchBaseEnabled: Bool = true,
        webSearchAvailable: Bool = false,
        skills: [OpenClawChatComposerSkill] = [],
        connectors: [OpenClawChatComposerConnector] = [],
        skillsAvailable: Bool = false,
        connectorsAvailable: Bool = false,
        toolAccessAvailable: Bool = false,
        permissionMutationAvailable: Bool = false,
        sessionSettingsCASAvailable: Bool = false,
        toolOverrideMutationAvailable: Bool = false,
        toolOverrideMutationRequiresGatewayUpgrade: Bool = false,
        canSelectFullPermission: Bool = false,
        loadFailureMessage: String? = nil)
    {
        self.sessionSettingsAvailable = sessionSettingsAvailable
        self.modelMutationAvailable = modelMutationAvailable
        self.effortMutationAvailable = effortMutationAvailable
        self.webSearchBaseEnabled = webSearchBaseEnabled
        self.webSearchAvailable = webSearchAvailable
        self.skills = skills
        self.connectors = connectors
        self.skillsAvailable = skillsAvailable
        self.connectorsAvailable = connectorsAvailable
        self.toolAccessAvailable = toolAccessAvailable
        self.permissionMutationAvailable = permissionMutationAvailable
        self.sessionSettingsCASAvailable = sessionSettingsCASAvailable
        self.toolOverrideMutationAvailable = toolOverrideMutationAvailable
        self.toolOverrideMutationRequiresGatewayUpgrade = toolOverrideMutationRequiresGatewayUpgrade
        self.canSelectFullPermission = canSelectFullPermission
        self.loadFailureMessage = loadFailureMessage
    }
}
