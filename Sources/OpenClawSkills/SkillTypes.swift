import Foundation

/// Source precedence buckets for discovered skills, lowest precedence first.
///
/// Upstream precedence (later wins by name): config `extraDirs`, plugin skill roots, bundled,
/// custodian, workshop, managed, personal `~/.agents/skills`, project `<ws>/.agents/skills`,
/// workspace `<ws>/skills`. ``upstreamID`` is the source string upstream reports in `skills.status`.
public enum SkillSource: String, Codable, Sendable, CaseIterable {
    /// Config `skills.load.extraDirs` (and the registry's `extraSkillDirs`).
    case extra
    /// Skill roots registered by plugins (reported upstream as `openclaw-extra`).
    case plugin
    /// Skills bundled with the host app.
    case bundled
    /// Custodian skills (only for the configured system agent; the SDK ships none).
    case custodian
    /// Per-agent workshop skills.
    case workshop
    /// Managed skills (`~/.openclaw/skills`, or Application Support on iOS-family platforms).
    case managed
    /// Personal `~/.agents/skills` (macOS/Linux).
    case personalAgents
    /// Project `<workspace>/.agents/skills`.
    case projectAgents
    /// Workspace `<workspace>/skills`.
    case workspace

    /// Source identifier upstream reports (`openclaw-bundled`, `agents-skills-project`, …).
    public var upstreamID: String {
        switch self {
        case .extra, .plugin:
            return "openclaw-extra"
        case .bundled:
            return "openclaw-bundled"
        case .custodian:
            return "openclaw-custodian"
        case .workshop:
            return "openclaw-workshop"
        case .managed:
            return "openclaw-managed"
        case .personalAgents:
            return "agents-skills-personal"
        case .projectAgents:
            return "agents-skills-project"
        case .workspace:
            return "openclaw-workspace"
        }
    }

    /// Precedence rank; higher wins when two sources define the same skill name.
    public var precedence: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    /// Whether upstream treats the source as bundled (`openclaw-bundled` or `openclaw-custodian`).
    public var isBundled: Bool {
        self == .bundled || self == .custodian
    }
}

/// Connector types supported by permissioned personal-data skills.
public enum SkillConnectorType: String, Codable, Sendable, CaseIterable, Equatable {
    case eventKit = "eventkit"
    case contacts = "contacts"
    case reminders = "reminders"
    case photos = "photos"
    case speech = "speech"
    case camera = "camera"
    case microphone = "microphone"
    case location = "location"
    case healthKit = "healthkit"
    case homeKit = "homekit"
    case fileBookmarks = "filebookmarks"
    case clipboard = "clipboard"
    case keychain = "keychain"
    case userDefaults = "userdefaults"
    case appIntents = "appintents"
}

/// Consent requirement level for connector-backed skills.
public enum ConnectorConsentRequirement: String, Codable, Sendable, Equatable {
    case none
    case session
    case explicit
}

/// Connector permission requirements declared by a skill.
public struct SkillConnectorPermission: Codable, Sendable, Equatable {
    public let connector: SkillConnectorType
    public let scopes: [String]
    public let consent: ConnectorConsentRequirement

    /// Creates connector permission requirements.
    /// - Parameters:
    ///   - connector: Connector type.
    ///   - scopes: Required permission scopes.
    ///   - consent: Consent requirement level.
    public init(connector: SkillConnectorType, scopes: [String], consent: ConnectorConsentRequirement) {
        self.connector = connector
        self.scopes = scopes
        self.consent = consent
    }
}

/// Parsed skill metadata fields.
///
/// `always`, `skillKey`, `primaryEnv`, `emoji`, `homepage`, `os`, `requires` and `install` come from
/// the upstream `metadata.openclaw` manifest (flat `always`/`skillKey`/`primaryEnv` keys are still
/// read). `connectors` is an OpenClawKit extension (`connectors`, `connectorScopes`,
/// `connectorConsent` frontmatter keys).
public struct SkillMetadata: Codable, Sendable, Equatable {
    /// Marks skill as always-active in prompt assembly.
    public var always: Bool?
    /// Optional unique skill key.
    public var skillKey: String?
    /// Optional primary environment hint.
    public var primaryEnv: String?
    /// Optional connector permission requirements.
    public var connectors: [SkillConnectorPermission]
    /// Display emoji.
    public var emoji: String?
    /// Homepage URL.
    public var homepage: String?
    /// Supported platform tokens (`darwin`, `linux`, …); empty means every platform.
    public var os: [String]
    /// Runtime requirements.
    public var requires: SkillManifestRequirements?
    /// Validated install recipes.
    public var install: [SkillInstallSpec]

    /// Creates skill metadata.
    /// - Parameters:
    ///   - always: Whether skill is always active.
    ///   - skillKey: Optional skill key.
    ///   - primaryEnv: Optional environment hint.
    ///   - connectors: Connector permission requirements.
    ///   - emoji: Display emoji.
    ///   - homepage: Homepage URL.
    ///   - os: Supported platforms.
    ///   - requires: Runtime requirements.
    ///   - install: Install recipes.
    public init(
        always: Bool? = nil,
        skillKey: String? = nil,
        primaryEnv: String? = nil,
        connectors: [SkillConnectorPermission] = [],
        emoji: String? = nil,
        homepage: String? = nil,
        os: [String] = [],
        requires: SkillManifestRequirements? = nil,
        install: [SkillInstallSpec] = []
    ) {
        self.always = always
        self.skillKey = skillKey
        self.primaryEnv = primaryEnv
        self.connectors = connectors
        self.emoji = emoji
        self.homepage = homepage
        self.os = os
        self.requires = requires
        self.install = install
    }

    private enum CodingKeys: String, CodingKey {
        case always, skillKey, primaryEnv, connectors, emoji, homepage, os, requires, install
    }

    /// Decodes metadata; fields added in 2026.3.0 default when absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.always = try container.decodeIfPresent(Bool.self, forKey: .always)
        self.skillKey = try container.decodeIfPresent(String.self, forKey: .skillKey)
        self.primaryEnv = try container.decodeIfPresent(String.self, forKey: .primaryEnv)
        self.connectors = try container.decodeIfPresent([SkillConnectorPermission].self, forKey: .connectors) ?? []
        self.emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        self.homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        self.os = try container.decodeIfPresent([String].self, forKey: .os) ?? []
        self.requires = try container.decodeIfPresent(SkillManifestRequirements.self, forKey: .requires)
        self.install = try container.decodeIfPresent([SkillInstallSpec].self, forKey: .install) ?? []
    }
}

/// Invocation policy flags parsed from skill frontmatter.
public struct SkillInvocationPolicy: Codable, Sendable, Equatable {
    /// Whether users may explicitly invoke the skill (`user-invocable`, default `true`).
    public var userInvocable: Bool
    /// Whether natural language inference should be disabled for this skill (OpenClawKit extension).
    public var requiresExplicitInvocation: Bool
    /// Whether skill should be excluded from model prompt injection (`disable-model-invocation`, default `false`).
    public var disableModelInvocation: Bool

    /// Creates invocation policy flags.
    /// - Parameters:
    ///   - userInvocable: Whether users can invoke the skill.
    ///   - requiresExplicitInvocation: Whether implicit/natural-language invocation is disabled.
    ///   - disableModelInvocation: Whether to exclude from model prompt assembly.
    public init(
        userInvocable: Bool = true,
        requiresExplicitInvocation: Bool = false,
        disableModelInvocation: Bool = false
    ) {
        self.userInvocable = userInvocable
        self.requiresExplicitInvocation = requiresExplicitInvocation
        self.disableModelInvocation = disableModelInvocation
    }
}

/// Fully parsed skill definition.
public struct SkillDefinition: Codable, Sendable, Equatable {
    /// Skill name.
    public let name: String
    /// Human-readable skill description.
    public let description: String
    /// Skill body/instructions.
    public let body: String
    /// Source file path.
    public let filePath: String
    /// Discovery source bucket.
    public let source: SkillSource
    /// Raw parsed frontmatter map.
    public let frontmatter: [String: String]
    /// Normalized metadata payload.
    public let metadata: SkillMetadata
    /// Invocation policy flags.
    public let invocation: SkillInvocationPolicy
    /// Title from the first Markdown `# H1` of the body, else the name.
    public let displayName: String
    /// Tool dispatch declared by `command-dispatch: tool`, if any.
    public let commandDispatch: SkillCommandDispatch?
    /// Recoverable frontmatter parse issues.
    public let frontmatterIssues: [SkillFrontmatterIssue]

    /// Creates a skill definition.
    /// - Parameters:
    ///   - name: Skill name.
    ///   - description: Human-readable description.
    ///   - body: Skill body/instructions.
    ///   - filePath: Source file path.
    ///   - source: Discovery source bucket.
    ///   - frontmatter: Raw parsed frontmatter.
    ///   - metadata: Normalized metadata payload.
    ///   - invocation: Invocation policy flags.
    ///   - displayName: Display title (defaults to `name`).
    ///   - commandDispatch: Optional tool dispatch.
    ///   - frontmatterIssues: Frontmatter parse issues.
    public init(
        name: String,
        description: String,
        body: String,
        filePath: String,
        source: SkillSource,
        frontmatter: [String: String] = [:],
        metadata: SkillMetadata = SkillMetadata(),
        invocation: SkillInvocationPolicy = SkillInvocationPolicy(),
        displayName: String? = nil,
        commandDispatch: SkillCommandDispatch? = nil,
        frontmatterIssues: [SkillFrontmatterIssue] = []
    ) {
        self.name = name
        self.description = description
        self.body = body
        self.filePath = filePath
        self.source = source
        self.frontmatter = frontmatter
        self.metadata = metadata
        self.invocation = invocation
        self.displayName = displayName ?? name
        self.commandDispatch = commandDispatch
        self.frontmatterIssues = frontmatterIssues
    }

    /// Config key of the skill (`metadata.openclaw.skillKey`, else the name).
    public var skillKey: String {
        let key = self.metadata.skillKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? self.name : key
    }

    /// Directory containing `SKILL.md`.
    public var baseDir: String {
        URL(fileURLWithPath: self.filePath).deletingLastPathComponent().path
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, body, filePath, source, frontmatter, metadata, invocation
        case displayName, commandDispatch, frontmatterIssues
    }

    /// Decodes a definition; fields added in 2026.3.0 default when absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
            body: try container.decodeIfPresent(String.self, forKey: .body) ?? "",
            filePath: try container.decode(String.self, forKey: .filePath),
            source: try container.decode(SkillSource.self, forKey: .source),
            frontmatter: try container.decodeIfPresent([String: String].self, forKey: .frontmatter) ?? [:],
            metadata: try container.decodeIfPresent(SkillMetadata.self, forKey: .metadata) ?? SkillMetadata(),
            invocation: try container.decodeIfPresent(SkillInvocationPolicy.self, forKey: .invocation) ?? SkillInvocationPolicy(),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            commandDispatch: try container.decodeIfPresent(SkillCommandDispatch.self, forKey: .commandDispatch),
            frontmatterIssues: try container.decodeIfPresent([SkillFrontmatterIssue].self, forKey: .frontmatterIssues) ?? []
        )
    }
}

/// Environment requirements of one prompt-visible skill (upstream `SkillSnapshot.skills[]`).
public struct SkillPromptSnapshotEntry: Codable, Sendable, Equatable {
    /// Skill name.
    public let name: String
    /// Config key.
    public let skillKey: String
    /// Primary environment variable.
    public let primaryEnv: String?
    /// Required environment variables.
    public let requiredEnv: [String]?

    /// Creates a snapshot entry.
    /// - Parameters:
    ///   - name: Skill name.
    ///   - skillKey: Config key.
    ///   - primaryEnv: Primary environment variable.
    ///   - requiredEnv: Required environment variables.
    public init(name: String, skillKey: String, primaryEnv: String? = nil, requiredEnv: [String]? = nil) {
        self.name = name
        self.skillKey = skillKey
        self.primaryEnv = primaryEnv
        self.requiredEnv = requiredEnv
    }
}

/// How skills are rendered into the model prompt.
public enum SkillPromptMode: String, Codable, Sendable, Equatable {
    /// Upstream v6 `<available_skills>` catalog: the model reads SKILL.md itself through a `read` tool.
    case catalog
    /// Legacy `## Skills` section with each skill body inlined (for models without tool calling).
    case inlineBodies

    /// Picks the mode: the catalog needs tool calling and a file-read tool, otherwise bodies are inlined.
    /// - Parameters:
    ///   - supportsToolCalling: Whether the model can call tools.
    ///   - hasReadTool: Whether a path-jailed `read` tool is registered.
    /// - Returns: The prompt mode.
    public static func resolve(supportsToolCalling: Bool, hasReadTool: Bool) -> SkillPromptMode {
        supportsToolCalling && hasReadTool ? .catalog : .inlineBodies
    }
}

/// Snapshot containing composed skill prompt text and source skills.
public struct SkillPromptSnapshot: Sendable, Equatable {
    /// Upstream `WORKSPACE_SKILLS_PROMPT_FORMAT_VERSION` of the catalog format.
    public static let currentPromptFormatVersion = 6

    /// Composed prompt text to inject into model requests.
    public let prompt: String
    /// Loaded skills used to produce prompt.
    public let skills: [SkillDefinition]
    /// Prompt-visible skills with their environment requirements.
    public let entries: [SkillPromptSnapshotEntry]
    /// Agent skill filter applied, if any.
    public let skillFilter: [String]?
    /// Prompt format version (6 for the `<available_skills>` catalog, 0 for inline bodies).
    public let promptFormatVersion: Int
    /// Mode used to render ``prompt``.
    public let mode: SkillPromptMode

    /// Creates a prompt snapshot.
    /// - Parameters:
    ///   - prompt: Composed prompt text.
    ///   - skills: Loaded skills.
    ///   - entries: Prompt-visible skill entries.
    ///   - skillFilter: Agent skill filter.
    ///   - promptFormatVersion: Prompt format version.
    ///   - mode: Render mode.
    public init(
        prompt: String,
        skills: [SkillDefinition],
        entries: [SkillPromptSnapshotEntry] = [],
        skillFilter: [String]? = nil,
        promptFormatVersion: Int = 0,
        mode: SkillPromptMode = .inlineBodies
    ) {
        self.prompt = prompt
        self.skills = skills
        self.entries = entries
        self.skillFilter = skillFilter
        self.promptFormatVersion = promptFormatVersion
        self.mode = mode
    }
}
