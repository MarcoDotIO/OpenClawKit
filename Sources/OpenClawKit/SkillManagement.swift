import Foundation
import OpenClawProtocol

/// Decoded result of the `skills.status` gateway RPC.
public struct SkillsStatusReport: Codable, Sendable {
    /// Agent workspace directory.
    public let workspaceDir: String
    /// Directory holding managed (installed) skills.
    public let managedSkillsDir: String
    /// Per-skill status rows.
    public let skills: [SkillStatus]

    /// Creates a report.
    public init(workspaceDir: String, managedSkillsDir: String, skills: [SkillStatus]) {
        self.workspaceDir = workspaceDir
        self.managedSkillsDir = managedSkillsDir
        self.skills = skills
    }
}

/// Status of one skill as reported by `skills.status`.
public struct SkillStatus: Codable, Identifiable, Sendable {
    /// Skill display name.
    public let name: String
    /// Skill description.
    public let description: String
    /// Where the skill comes from (`bundled`, `managed`, `workspace`, …).
    public let source: String
    /// Whether the skill ships with the gateway.
    public let bundled: Bool?
    /// Path of the skill definition file.
    public let filePath: String
    /// Skill base directory.
    public let baseDir: String
    /// Stable skill key (also ``id``).
    public let skillKey: String
    /// Primary environment variable the skill needs, if any.
    public let primaryEnv: String?
    /// Display emoji.
    public let emoji: String?
    /// Homepage URL.
    public let homepage: String?
    /// Whether the skill is always loaded.
    public let always: Bool
    /// Whether the skill is disabled.
    public let disabled: Bool
    /// Whether an allowlist blocks the skill.
    public let blockedByAllowlist: Bool?
    /// Whether an agent filter blocks the skill.
    public let blockedByAgentFilter: Bool?
    /// Whether the skill cannot run on this platform.
    public let platformIncompatible: Bool?
    /// Whether the skill is currently eligible to run.
    public let eligible: Bool
    /// Declared requirements.
    public let requirements: SkillRequirements
    /// Requirements that are not met.
    public let missing: SkillMissing
    /// Config checks and their current values.
    public let configChecks: [SkillStatusConfigCheck]
    /// Install options for missing binaries.
    public let install: [SkillInstallOption]
    /// ClawHub install link, when installed from ClawHub.
    public let clawhub: ClawHubInstalledSkillLink?

    /// Stable identity (the skill key).
    public var id: String {
        self.skillKey
    }

    /// Creates a skill status row.
    public init(
        name: String,
        description: String,
        source: String,
        bundled: Bool? = nil,
        filePath: String,
        baseDir: String,
        skillKey: String,
        primaryEnv: String?,
        emoji: String?,
        homepage: String?,
        always: Bool,
        disabled: Bool,
        blockedByAllowlist: Bool? = nil,
        blockedByAgentFilter: Bool? = nil,
        platformIncompatible: Bool? = nil,
        eligible: Bool,
        requirements: SkillRequirements,
        missing: SkillMissing,
        configChecks: [SkillStatusConfigCheck],
        install: [SkillInstallOption],
        clawhub: ClawHubInstalledSkillLink? = nil)
    {
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
        self.platformIncompatible = platformIncompatible
        self.eligible = eligible
        self.requirements = requirements
        self.missing = missing
        self.configChecks = configChecks
        self.install = install
        self.clawhub = clawhub
    }
}

/// Requirements a skill declares. Older gateways omit `anyBins` and `os`; both default to `[]`.
public struct SkillRequirements: Codable, Sendable {
    /// Binaries that must all be present.
    public let bins: [String]
    /// Binaries of which at least one must be present.
    public let anyBins: [String]
    /// Required environment variables.
    public let env: [String]
    /// Required config paths.
    public let config: [String]
    /// Supported operating systems (empty means any).
    public let os: [String]

    /// Creates requirements.
    public init(
        bins: [String],
        anyBins: [String] = [],
        env: [String],
        config: [String],
        os: [String] = [])
    {
        self.bins = bins
        self.anyBins = anyBins
        self.env = env
        self.config = config
        self.os = os
    }

    private enum CodingKeys: String, CodingKey {
        case bins
        case anyBins
        case env
        case config
        case os
    }

    /// Decodes requirements, tolerating a missing `anyBins` or `os`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bins = try container.decode([String].self, forKey: .bins)
        self.anyBins = try container.decodeIfPresent([String].self, forKey: .anyBins) ?? []
        self.env = try container.decode([String].self, forKey: .env)
        self.config = try container.decode([String].self, forKey: .config)
        self.os = try container.decodeIfPresent([String].self, forKey: .os) ?? []
    }
}

/// Unmet requirements of a skill. Older gateways omit `anyBins` and `os`; both default to `[]`.
public struct SkillMissing: Codable, Sendable {
    /// Missing binaries.
    public let bins: [String]
    /// Binary groups with none present.
    public let anyBins: [String]
    /// Missing environment variables.
    public let env: [String]
    /// Missing config paths.
    public let config: [String]
    /// Unsupported operating systems.
    public let os: [String]

    /// Creates missing requirements.
    public init(
        bins: [String],
        anyBins: [String] = [],
        env: [String],
        config: [String],
        os: [String] = [])
    {
        self.bins = bins
        self.anyBins = anyBins
        self.env = env
        self.config = config
        self.os = os
    }

    private enum CodingKeys: String, CodingKey {
        case bins
        case anyBins
        case env
        case config
        case os
    }

    /// Decodes missing requirements, tolerating a missing `anyBins` or `os`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bins = try container.decode([String].self, forKey: .bins)
        self.anyBins = try container.decodeIfPresent([String].self, forKey: .anyBins) ?? []
        self.env = try container.decode([String].self, forKey: .env)
        self.config = try container.decode([String].self, forKey: .config)
        self.os = try container.decodeIfPresent([String].self, forKey: .os) ?? []
    }
}

/// One config check of a skill.
public struct SkillStatusConfigCheck: Codable, Identifiable, Sendable {
    /// Config path.
    public let path: String
    /// Current value, if set.
    public let value: OpenClawProtocol.AnyCodable?
    /// Whether the check is satisfied.
    public let satisfied: Bool

    /// Stable identity (the config path).
    public var id: String {
        self.path
    }

    /// Creates a config check.
    public init(path: String, value: OpenClawProtocol.AnyCodable?, satisfied: Bool) {
        self.path = path
        self.value = value
        self.satisfied = satisfied
    }
}

/// An install option for a skill's missing binaries.
public struct SkillInstallOption: Codable, Identifiable, Sendable {
    /// Option identifier.
    public let id: String
    /// Installer kind (for example `brew`).
    public let kind: String
    /// Display label.
    public let label: String
    /// Binaries the option installs.
    public let bins: [String]

    /// Creates an install option.
    public init(id: String, kind: String, label: String, bins: [String]) {
        self.id = id
        self.kind = kind
        self.label = label
        self.bins = bins
    }
}

/// Link between an installed skill and its ClawHub listing.
public struct ClawHubInstalledSkillLink: Codable, Sendable {
    /// Link status.
    public let status: String
    /// Whether the link is valid.
    public let valid: Bool
    /// ClawHub slug.
    public let slug: String?
    /// Owner handle.
    public let ownerHandle: String?
    /// Exact reference this skill was installed from. The Gateway records the canonical slug and
    /// this separately, so an install-only source stays identifiable after install.
    public let requestedReference: String?
    /// Installed version.
    public let installedVersion: String?
    /// Reason when the link is invalid.
    public let reason: String?

    /// Creates a ClawHub link.
    public init(
        status: String,
        valid: Bool,
        slug: String? = nil,
        ownerHandle: String? = nil,
        requestedReference: String? = nil,
        installedVersion: String? = nil,
        reason: String? = nil)
    {
        self.status = status
        self.valid = valid
        self.slug = slug
        self.ownerHandle = ownerHandle
        self.requestedReference = requestedReference
        self.installedVersion = installedVersion
        self.reason = reason
    }
}
