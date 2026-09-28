import Foundation
import OpenClawProtocol

/// Skill loading and eligibility settings (the upstream `skills` config section subset the SDK honors).
///
/// Decodes the upstream JSON shape (`allowBundled`, `load.extraDirs`, `load.allowSymlinkTargets`,
/// `load.watch`, `entries.<skillKey>.{enabled, env, apiKey, config}`, `limits.maxSkillsInPrompt`,
/// `limits.maxSkillsPromptChars`), so an app can decode it straight from `openclaw.json`'s `skills`
/// object. Unknown keys are ignored.
public struct SkillsConfiguration: Codable, Sendable, Equatable {
    /// Loader settings.
    public struct Load: Codable, Sendable, Equatable {
        /// Extra skill roots with the lowest precedence (`~` expands to the home directory).
        public var extraDirs: [String]
        /// Directories that symlinked skill folders may point into.
        public var allowSymlinkTargets: [String]
        /// Whether to watch skill roots for changes (informational in the SDK).
        public var watch: Bool?

        /// Creates loader settings.
        /// - Parameters:
        ///   - extraDirs: Extra roots.
        ///   - allowSymlinkTargets: Allowed symlink targets.
        ///   - watch: Watch flag.
        public init(extraDirs: [String] = [], allowSymlinkTargets: [String] = [], watch: Bool? = nil) {
            self.extraDirs = extraDirs
            self.allowSymlinkTargets = allowSymlinkTargets
            self.watch = watch
        }

        private enum CodingKeys: String, CodingKey {
            case extraDirs, allowSymlinkTargets, watch
        }

        /// Decodes loader settings; missing lists decode as empty.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.extraDirs = try container.decodeIfPresent([String].self, forKey: .extraDirs) ?? []
            self.allowSymlinkTargets = try container.decodeIfPresent([String].self, forKey: .allowSymlinkTargets) ?? []
            self.watch = try container.decodeIfPresent(Bool.self, forKey: .watch)
        }
    }

    /// Per-skill settings keyed by skill key.
    public struct Entry: Codable, Sendable, Equatable {
        /// `false` disables the skill.
        public var enabled: Bool?
        /// Extra environment made available to the skill (also satisfies `requires.env`).
        public var env: [String: String]?
        /// API key (string or SecretRef object); satisfies `requires.env` for the skill's `primaryEnv`.
        public var apiKey: AnyCodable?
        /// Free-form skill config.
        public var config: [String: AnyCodable]?

        /// Creates per-skill settings.
        /// - Parameters:
        ///   - enabled: Enabled flag.
        ///   - env: Environment.
        ///   - apiKey: API key.
        ///   - config: Skill config.
        public init(enabled: Bool? = nil, env: [String: String]? = nil, apiKey: AnyCodable? = nil, config: [String: AnyCodable]? = nil) {
            self.enabled = enabled
            self.env = env
            self.apiKey = apiKey
            self.config = config
        }

        /// Whether ``apiKey`` holds a configured secret (non-empty string or a SecretRef object).
        public var hasConfiguredAPIKey: Bool {
            guard let apiKey else { return false }
            if let text = apiKey.stringValue {
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if let object = apiKey.dictionaryValue {
                return object["id"]?.stringValue?.isEmpty == false || object["source"] != nil
            }
            return false
        }
    }

    /// Prompt limits.
    public struct Limits: Codable, Sendable, Equatable {
        /// Maximum skills listed in the prompt (upstream default 150).
        public var maxSkillsInPrompt: Int?
        /// Maximum characters of the skills catalog (upstream default 18000).
        public var maxSkillsPromptChars: Int?

        /// Creates prompt limits.
        /// - Parameters:
        ///   - maxSkillsInPrompt: Maximum skills.
        ///   - maxSkillsPromptChars: Maximum characters.
        public init(maxSkillsInPrompt: Int? = nil, maxSkillsPromptChars: Int? = nil) {
            self.maxSkillsInPrompt = maxSkillsInPrompt
            self.maxSkillsPromptChars = maxSkillsPromptChars
        }
    }

    /// When set, only these bundled skills (by key or name) are allowed.
    public var allowBundled: [String]?
    /// Loader settings.
    public var load: Load
    /// Per-skill settings keyed by skill key.
    public var entries: [String: Entry]
    /// Prompt limits.
    public var limits: Limits

    /// Creates skill settings.
    /// - Parameters:
    ///   - allowBundled: Bundled allowlist.
    ///   - load: Loader settings.
    ///   - entries: Per-skill settings.
    ///   - limits: Prompt limits.
    public init(allowBundled: [String]? = nil, load: Load = Load(), entries: [String: Entry] = [:], limits: Limits = Limits()) {
        self.allowBundled = allowBundled
        self.load = load
        self.entries = entries
        self.limits = limits
    }

    private enum CodingKeys: String, CodingKey {
        case allowBundled, load, entries, limits
    }

    /// Decodes skill settings; missing sections use defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.allowBundled = try container.decodeIfPresent([String].self, forKey: .allowBundled)
        self.load = try container.decodeIfPresent(Load.self, forKey: .load) ?? Load()
        self.entries = try container.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        self.limits = try container.decodeIfPresent(Limits.self, forKey: .limits) ?? Limits()
    }

    /// Settings for one skill key.
    /// - Parameter skillKey: Skill key.
    /// - Returns: The entry, if configured.
    public func entry(for skillKey: String) -> Entry? {
        self.entries[skillKey]
    }
}
