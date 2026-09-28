import Foundation
import OpenClawProtocol

// `skills.status` wire models (upstream `src/skills/discovery/status.types.ts` and
// `src/shared/requirements.ts`, OpenClaw 2026.9.6). Names follow the upstream TypeScript types so
// they do not collide with the client-side decoding models in OpenClawKit (`SkillsStatusReport`,
// `SkillStatus`, …), which decode the same JSON.

/// Required or missing requirement lists of a skill.
public struct SkillStatusRequirements: Codable, Sendable, Equatable {
    /// Binaries.
    public var bins: [String]
    /// Alternative binaries.
    public var anyBins: [String]
    /// Environment variables.
    public var env: [String]
    /// Config paths.
    public var config: [String]
    /// Platforms.
    public var os: [String]

    /// Creates requirement lists.
    /// - Parameters:
    ///   - bins: Binaries.
    ///   - anyBins: Alternative binaries.
    ///   - env: Environment variables.
    ///   - config: Config paths.
    ///   - os: Platforms.
    public init(bins: [String] = [], anyBins: [String] = [], env: [String] = [], config: [String] = [], os: [String] = []) {
        self.bins = bins
        self.anyBins = anyBins
        self.env = env
        self.config = config
        self.os = os
    }

    /// Whether every list is empty.
    public var isEmpty: Bool {
        self.bins.isEmpty && self.anyBins.isEmpty && self.env.isEmpty && self.config.isEmpty && self.os.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case bins, anyBins, env, config, os
    }

    /// Decodes requirement lists; missing lists decode as empty (like the upstream Swift client).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bins = try container.decodeIfPresent([String].self, forKey: .bins) ?? []
        self.anyBins = try container.decodeIfPresent([String].self, forKey: .anyBins) ?? []
        self.env = try container.decodeIfPresent([String].self, forKey: .env) ?? []
        self.config = try container.decodeIfPresent([String].self, forKey: .config) ?? []
        self.os = try container.decodeIfPresent([String].self, forKey: .os) ?? []
    }
}

/// Result of one `requires.config` check.
public struct SkillRequirementConfigCheck: Codable, Sendable, Equatable {
    /// Config dot-path.
    public let path: String
    /// Resolved value (SDK extension; omitted upstream).
    public let value: AnyCodable?
    /// Whether the value is truthy.
    public let satisfied: Bool

    /// Creates a config check.
    /// - Parameters:
    ///   - path: Config path.
    ///   - value: Resolved value.
    ///   - satisfied: Whether satisfied.
    public init(path: String, value: AnyCodable? = nil, satisfied: Bool) {
        self.path = path
        self.value = value
        self.satisfied = satisfied
    }
}

/// Installer option offered for a skill (upstream `SkillInstallOption`).
public struct SkillStatusInstallOption: Codable, Sendable, Equatable {
    /// Option identifier (`<kind>-<index>` when the spec has no id).
    public let id: String
    /// Installer kind.
    public let kind: String
    /// Label.
    public let label: String
    /// Binaries provided.
    public let bins: [String]

    /// Creates an install option.
    /// - Parameters:
    ///   - id: Identifier.
    ///   - kind: Kind.
    ///   - label: Label.
    ///   - bins: Binaries.
    public init(id: String, kind: String, label: String, bins: [String]) {
        self.id = id
        self.kind = kind
        self.label = label
        self.bins = bins
    }
}

/// ClawHub provenance of an installed skill.
public struct ClawHubSkillStatusLink: Codable, Sendable, Equatable {
    /// Link status.
    public let status: String
    /// Whether the link is valid.
    public let valid: Bool
    /// Registry slug.
    public let slug: String?
    /// Owner handle.
    public let ownerHandle: String?
    /// Exact reference the skill was installed from.
    public let requestedReference: String?
    /// Installed version.
    public let installedVersion: String?
    /// Reason when invalid.
    public let reason: String?

    /// Creates a ClawHub link.
    /// - Parameters:
    ///   - status: Status.
    ///   - valid: Valid flag.
    ///   - slug: Slug.
    ///   - ownerHandle: Owner handle.
    ///   - requestedReference: Requested reference.
    ///   - installedVersion: Installed version.
    ///   - reason: Reason.
    public init(
        status: String,
        valid: Bool,
        slug: String? = nil,
        ownerHandle: String? = nil,
        requestedReference: String? = nil,
        installedVersion: String? = nil,
        reason: String? = nil
    ) {
        self.status = status
        self.valid = valid
        self.slug = slug
        self.ownerHandle = ownerHandle
        self.requestedReference = requestedReference
        self.installedVersion = installedVersion
        self.reason = reason
    }
}

/// One skill in a `skills.status` report (upstream `SkillStatusEntry`).
public struct SkillStatusEntry: Codable, Sendable, Equatable {
    /// Skill name.
    public let name: String
    /// Description.
    public let description: String
    /// Upstream source identifier (``SkillSource/upstreamID``).
    public let source: String
    /// Whether the skill is bundled.
    public let bundled: Bool
    /// SKILL.md path.
    public let filePath: String
    /// Skill directory.
    public let baseDir: String
    /// Config key.
    public let skillKey: String
    /// Primary environment variable.
    public let primaryEnv: String?
    /// Emoji.
    public let emoji: String?
    /// Homepage.
    public let homepage: String?
    /// Always flag.
    public let always: Bool
    /// Disabled by `entries.<key>.enabled: false`.
    public let disabled: Bool
    /// Bundled skill blocked by `allowBundled`.
    public let blockedByAllowlist: Bool
    /// Blocked by the agent's skill filter.
    public let blockedByAgentFilter: Bool
    /// Eligible to run (enabled, allowed, requirements met).
    public let eligible: Bool
    /// The skill's `os` list excludes this host.
    public let platformIncompatible: Bool
    /// Listed in the model prompt.
    public let modelVisible: Bool
    /// Users may invoke it.
    public let userInvocable: Bool
    /// Offered as a slash command.
    public let commandVisible: Bool
    /// Declared requirements.
    public let requirements: SkillStatusRequirements
    /// Missing requirements.
    public let missing: SkillStatusRequirements
    /// Config checks.
    public let configChecks: [SkillRequirementConfigCheck]
    /// Installer options.
    public let install: [SkillStatusInstallOption]
    /// ClawHub provenance.
    public let clawhub: ClawHubSkillStatusLink?

    /// Creates a status entry.
    /// - Parameters:
    ///   - name: Name.
    ///   - description: Description.
    ///   - source: Source identifier.
    ///   - bundled: Bundled flag.
    ///   - filePath: File path.
    ///   - baseDir: Base directory.
    ///   - skillKey: Skill key.
    ///   - primaryEnv: Primary environment variable.
    ///   - emoji: Emoji.
    ///   - homepage: Homepage.
    ///   - always: Always flag.
    ///   - disabled: Disabled flag.
    ///   - blockedByAllowlist: Allowlist flag.
    ///   - blockedByAgentFilter: Agent filter flag.
    ///   - eligible: Eligible flag.
    ///   - platformIncompatible: Platform flag.
    ///   - modelVisible: Model visibility.
    ///   - userInvocable: User invocability.
    ///   - commandVisible: Command visibility.
    ///   - requirements: Requirements.
    ///   - missing: Missing requirements.
    ///   - configChecks: Config checks.
    ///   - install: Install options.
    ///   - clawhub: ClawHub link.
    public init(
        name: String,
        description: String,
        source: String,
        bundled: Bool,
        filePath: String,
        baseDir: String,
        skillKey: String,
        primaryEnv: String?,
        emoji: String?,
        homepage: String?,
        always: Bool,
        disabled: Bool,
        blockedByAllowlist: Bool,
        blockedByAgentFilter: Bool,
        eligible: Bool,
        platformIncompatible: Bool,
        modelVisible: Bool,
        userInvocable: Bool,
        commandVisible: Bool,
        requirements: SkillStatusRequirements,
        missing: SkillStatusRequirements,
        configChecks: [SkillRequirementConfigCheck],
        install: [SkillStatusInstallOption],
        clawhub: ClawHubSkillStatusLink? = nil
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.bundled = bundled
        self.filePath = filePath
        self.baseDir = baseDir
        self.skillKey = skillKey
        self.primaryEnv = primaryEnv
        self.emoji = emoji
        self.homepage = homepage
        self.always = always
        self.disabled = disabled
        self.blockedByAllowlist = blockedByAllowlist
        self.blockedByAgentFilter = blockedByAgentFilter
        self.eligible = eligible
        self.platformIncompatible = platformIncompatible
        self.modelVisible = modelVisible
        self.userInvocable = userInvocable
        self.commandVisible = commandVisible
        self.requirements = requirements
        self.missing = missing
        self.configChecks = configChecks
        self.install = install
        self.clawhub = clawhub
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, source, bundled, filePath, baseDir, skillKey, primaryEnv, emoji, homepage
        case always, disabled, blockedByAllowlist, blockedByAgentFilter, eligible, platformIncompatible
        case modelVisible, userInvocable, commandVisible, requirements, missing, configChecks, install, clawhub
    }

    /// Decodes an entry, tolerating flags and lists older gateways omit.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        self.bundled = try container.decodeIfPresent(Bool.self, forKey: .bundled) ?? false
        self.filePath = try container.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        self.baseDir = try container.decodeIfPresent(String.self, forKey: .baseDir) ?? ""
        self.skillKey = try container.decodeIfPresent(String.self, forKey: .skillKey) ?? self.name
        self.primaryEnv = try container.decodeIfPresent(String.self, forKey: .primaryEnv)
        self.emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        self.homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        self.always = try container.decodeIfPresent(Bool.self, forKey: .always) ?? false
        self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        self.blockedByAllowlist = try container.decodeIfPresent(Bool.self, forKey: .blockedByAllowlist) ?? false
        self.blockedByAgentFilter = try container.decodeIfPresent(Bool.self, forKey: .blockedByAgentFilter) ?? false
        self.eligible = try container.decodeIfPresent(Bool.self, forKey: .eligible) ?? false
        self.platformIncompatible = try container.decodeIfPresent(Bool.self, forKey: .platformIncompatible) ?? false
        self.modelVisible = try container.decodeIfPresent(Bool.self, forKey: .modelVisible) ?? false
        self.userInvocable = try container.decodeIfPresent(Bool.self, forKey: .userInvocable) ?? true
        self.commandVisible = try container.decodeIfPresent(Bool.self, forKey: .commandVisible) ?? false
        self.requirements = try container.decodeIfPresent(SkillStatusRequirements.self, forKey: .requirements) ?? SkillStatusRequirements()
        self.missing = try container.decodeIfPresent(SkillStatusRequirements.self, forKey: .missing) ?? SkillStatusRequirements()
        self.configChecks = try container.decodeIfPresent([SkillRequirementConfigCheck].self, forKey: .configChecks) ?? []
        self.install = try container.decodeIfPresent([SkillStatusInstallOption].self, forKey: .install) ?? []
        self.clawhub = try container.decodeIfPresent(ClawHubSkillStatusLink.self, forKey: .clawhub)
    }
}

/// `skills.status` result (upstream `SkillStatusReport`).
public struct SkillStatusReport: Codable, Sendable, Equatable {
    /// Workspace directory.
    public let workspaceDir: String
    /// Managed skills directory.
    public let managedSkillsDir: String
    /// Agent the report was computed for.
    public let agentId: String?
    /// Agent skill filter, when one applies.
    public let agentSkillFilter: [String]?
    /// Every discovered skill (disabled and ineligible included).
    public let skills: [SkillStatusEntry]

    /// Creates a report.
    /// - Parameters:
    ///   - workspaceDir: Workspace directory.
    ///   - managedSkillsDir: Managed directory.
    ///   - agentId: Agent identifier.
    ///   - agentSkillFilter: Agent filter.
    ///   - skills: Entries.
    public init(workspaceDir: String, managedSkillsDir: String, agentId: String? = nil, agentSkillFilter: [String]? = nil, skills: [SkillStatusEntry]) {
        self.workspaceDir = workspaceDir
        self.managedSkillsDir = managedSkillsDir
        self.agentId = agentId
        self.agentSkillFilter = agentSkillFilter
        self.skills = skills
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceDir, managedSkillsDir, agentId, agentSkillFilter, skills
    }

    /// Decodes a report; a missing `skills` list decodes as empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.workspaceDir = try container.decodeIfPresent(String.self, forKey: .workspaceDir) ?? ""
        self.managedSkillsDir = try container.decodeIfPresent(String.self, forKey: .managedSkillsDir) ?? ""
        self.agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        self.agentSkillFilter = try container.decodeIfPresent([String].self, forKey: .agentSkillFilter)
        self.skills = try container.decodeIfPresent([SkillStatusEntry].self, forKey: .skills) ?? []
    }
}
