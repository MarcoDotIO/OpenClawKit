import Foundation
import OpenClawProtocol

// OpenClaw skill manifest block: the JSON5 `metadata` frontmatter value keyed by `openclaw`
// (legacy `clawdbot`). Mirrors upstream `src/shared/frontmatter.ts` and
// `src/skills/loading/frontmatter.ts` (install spec validation) at OpenClaw 2026.9.6.

/// Runtime requirements declared by a skill manifest (`metadata.openclaw.requires`).
public struct SkillManifestRequirements: Codable, Sendable, Equatable {
    /// Binaries that must all be on `PATH`.
    public var bins: [String]
    /// Alternative binaries; any one satisfies the requirement.
    public var anyBins: [String]
    /// Environment variables that must be set.
    public var env: [String]
    /// Config dot-paths that must be truthy.
    public var config: [String]

    /// Creates requirements.
    /// - Parameters:
    ///   - bins: Required binaries.
    ///   - anyBins: Alternative binaries.
    ///   - env: Required environment variables.
    ///   - config: Required config paths.
    public init(bins: [String] = [], anyBins: [String] = [], env: [String] = [], config: [String] = []) {
        self.bins = bins
        self.anyBins = anyBins
        self.env = env
        self.config = config
    }

    /// Whether no requirement is declared.
    public var isEmpty: Bool {
        self.bins.isEmpty && self.anyBins.isEmpty && self.env.isEmpty && self.config.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case bins
        case anyBins
        case env
        case config
    }

    /// Decodes requirements; missing lists decode as empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bins = try container.decodeIfPresent([String].self, forKey: .bins) ?? []
        self.anyBins = try container.decodeIfPresent([String].self, forKey: .anyBins) ?? []
        self.env = try container.decodeIfPresent([String].self, forKey: .env) ?? []
        self.config = try container.decodeIfPresent([String].self, forKey: .config) ?? []
    }
}

/// Installer kind of a skill install spec.
public enum SkillInstallKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Homebrew formula or cask.
    case brew
    /// npm package.
    case node
    /// Go module.
    case go
    /// uv (Python) package.
    case uv
    /// Direct download.
    case download
}

/// One validated install recipe from a skill manifest (`metadata.openclaw.install[]`).
///
/// Invalid specs are dropped while parsing: unsafe brew formulas, npm/uv/go specs, non-http(s)
/// download URLs, a download `sha256` that is not 64 hex characters, and kinds missing their
/// required field.
public struct SkillInstallSpec: Codable, Sendable, Equatable {
    /// Optional stable identifier.
    public var id: String?
    /// Installer kind.
    public var kind: SkillInstallKind
    /// Human-facing label.
    public var label: String?
    /// Binaries expected after installation.
    public var bins: [String]?
    /// Platforms the recipe applies to.
    public var os: [String]?
    /// Homebrew formula (also filled from `cask`).
    public var formula: String?
    /// npm or uv package spec.
    public var package: String?
    /// Go module spec.
    public var module: String?
    /// Download URL (http/https only).
    public var url: String?
    /// Lowercase hex SHA-256 of the download (download specs only).
    public var sha256: String?
    /// Archive format hint.
    public var archive: String?
    /// Whether to extract the download.
    public var extract: Bool?
    /// Leading path components to strip when extracting.
    public var stripComponents: Int?
    /// Target directory for the download.
    public var targetDir: String?

    /// Creates an install spec.
    /// - Parameters:
    ///   - id: Identifier.
    ///   - kind: Installer kind.
    ///   - label: Label.
    ///   - bins: Binaries.
    ///   - os: Platforms.
    ///   - formula: Brew formula.
    ///   - package: Package spec.
    ///   - module: Go module.
    ///   - url: Download URL.
    ///   - sha256: Download digest.
    ///   - archive: Archive format.
    ///   - extract: Extract flag.
    ///   - stripComponents: Components to strip.
    ///   - targetDir: Target directory.
    public init(
        id: String? = nil,
        kind: SkillInstallKind,
        label: String? = nil,
        bins: [String]? = nil,
        os: [String]? = nil,
        formula: String? = nil,
        package: String? = nil,
        module: String? = nil,
        url: String? = nil,
        sha256: String? = nil,
        archive: String? = nil,
        extract: Bool? = nil,
        stripComponents: Int? = nil,
        targetDir: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.bins = bins
        self.os = os
        self.formula = formula
        self.package = package
        self.module = module
        self.url = url
        self.sha256 = sha256
        self.archive = archive
        self.extract = extract
        self.stripComponents = stripComponents
        self.targetDir = targetDir
    }
}

/// Parsed `metadata.openclaw` manifest of a skill.
public struct OpenClawSkillManifest: Codable, Sendable, Equatable {
    /// Always treat the skill as eligible (runtime requirements are bypassed; `os` still applies).
    public var always: Bool?
    /// Stable skill key used for config entries (defaults to the skill name).
    public var skillKey: String?
    /// Environment variable the skill's API key maps to.
    public var primaryEnv: String?
    /// Display emoji.
    public var emoji: String?
    /// Homepage URL.
    public var homepage: String?
    /// Supported platforms (`darwin`, `linux`, `win32`; SDK extensions `ios`, `tvos`, `watchos`, `visionos`).
    public var os: [String]
    /// Runtime requirements.
    public var requires: SkillManifestRequirements?
    /// Validated install recipes.
    public var install: [SkillInstallSpec]

    /// Creates a manifest.
    /// - Parameters:
    ///   - always: Always flag.
    ///   - skillKey: Skill key.
    ///   - primaryEnv: Primary environment variable.
    ///   - emoji: Emoji.
    ///   - homepage: Homepage.
    ///   - os: Platforms.
    ///   - requires: Requirements.
    ///   - install: Install recipes.
    public init(
        always: Bool? = nil,
        skillKey: String? = nil,
        primaryEnv: String? = nil,
        emoji: String? = nil,
        homepage: String? = nil,
        os: [String] = [],
        requires: SkillManifestRequirements? = nil,
        install: [SkillInstallSpec] = []
    ) {
        self.always = always
        self.skillKey = skillKey
        self.primaryEnv = primaryEnv
        self.emoji = emoji
        self.homepage = homepage
        self.os = os
        self.requires = requires
        self.install = install
    }

    private enum CodingKeys: String, CodingKey {
        case always, skillKey, primaryEnv, emoji, homepage, os, requires, install
    }

    /// Decodes a manifest; missing lists decode as empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.always = try container.decodeIfPresent(Bool.self, forKey: .always)
        self.skillKey = try container.decodeIfPresent(String.self, forKey: .skillKey)
        self.primaryEnv = try container.decodeIfPresent(String.self, forKey: .primaryEnv)
        self.emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        self.homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        self.os = try container.decodeIfPresent([String].self, forKey: .os) ?? []
        self.requires = try container.decodeIfPresent(SkillManifestRequirements.self, forKey: .requires)
        self.install = try container.decodeIfPresent([SkillInstallSpec].self, forKey: .install) ?? []
    }
}

/// How a skill slash command forwards its arguments to a tool.
public enum SkillCommandArgMode: String, Codable, Sendable, Equatable {
    /// Forward the raw argument string as `{ "command": <args> }`.
    case raw
}

/// Tool dispatch declared by `command-dispatch: tool` frontmatter.
public struct SkillCommandDispatch: Codable, Sendable, Equatable {
    /// Tool invoked for the command (`command-tool`).
    public var toolName: String
    /// Argument forwarding mode (`command-arg-mode`; unknown values fall back to raw).
    public var argMode: SkillCommandArgMode

    /// Creates a command dispatch.
    /// - Parameters:
    ///   - toolName: Tool name.
    ///   - argMode: Argument mode.
    public init(toolName: String, argMode: SkillCommandArgMode = .raw) {
        self.toolName = toolName
        self.argMode = argMode
    }
}

/// Parses the JSON5 manifest block embedded in a skill's `metadata` frontmatter value.
public enum SkillManifestParser {
    /// Current manifest key.
    public static let manifestKey = "openclaw"
    /// Legacy manifest keys still read for older skill files.
    public static let legacyManifestKeys = ["clawdbot"]

    private static let brewFormulaPattern = "^[A-Za-z0-9][A-Za-z0-9@+._/-]*$"
    private static let goModulePattern = "^[A-Za-z0-9][A-Za-z0-9._~+\\-/]*(?:@[A-Za-z0-9][A-Za-z0-9._~+\\-/]*)?$"
    private static let uvPackagePattern = "^[A-Za-z0-9][A-Za-z0-9._\\-\\[\\]=<>!~+,]*$"
    private static let npmPackagePattern = "^(?:@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*(?:@[A-Za-z0-9._~^<>=|*+ -]+)?$"

    /// Parses a manifest from a frontmatter `metadata` value.
    /// - Parameter metadata: Raw `metadata` text (JSON or JSON5).
    /// - Returns: The manifest, or `nil` when absent or unparseable.
    public static func parse(metadata: String?) -> OpenClawSkillManifest? {
        guard let block = self.manifestBlock(metadata: metadata) else { return nil }
        return self.manifest(from: block)
    }

    /// Returns the raw `openclaw` (or legacy) object of a frontmatter `metadata` value.
    /// - Parameter metadata: Raw `metadata` text.
    /// - Returns: Manifest object, or `nil`.
    public static func manifestBlock(metadata: String?) -> [String: AnyCodable]? {
        guard let metadata, !metadata.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let parsed = try? FlowValueParser.parseDocument(metadata),
              let root = parsed.anyCodable.dictionaryValue
        else {
            return nil
        }
        for key in [self.manifestKey] + self.legacyManifestKeys {
            if let candidate = root[key]?.dictionaryValue {
                return candidate
            }
        }
        return nil
    }

    /// Builds a manifest from a raw manifest object.
    /// - Parameter block: Manifest object.
    /// - Returns: Normalized manifest.
    public static func manifest(from block: [String: AnyCodable]) -> OpenClawSkillManifest {
        let requires = block["requires"]?.dictionaryValue.map { raw in
            SkillManifestRequirements(
                bins: self.stringList(raw["bins"]),
                anyBins: self.stringList(raw["anyBins"]),
                env: self.stringList(raw["env"]),
                config: self.stringList(raw["config"])
            )
        }
        let install = (block["install"]?.arrayValue ?? []).compactMap(self.installSpec(from:))
        let skillKey = block["skillKey"]?.stringValue
        return OpenClawSkillManifest(
            always: block["always"]?.boolValue,
            skillKey: (skillKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? skillKey : nil,
            primaryEnv: block["primaryEnv"]?.stringValue,
            emoji: block["emoji"]?.stringValue,
            homepage: block["homepage"]?.stringValue,
            os: self.stringList(block["os"]),
            requires: requires,
            install: install
        )
    }

    /// Parses and validates one install spec (upstream `parseInstallSpec`).
    /// - Parameter value: Raw install entry.
    /// - Returns: The spec, or `nil` when invalid.
    public static func installSpec(from value: AnyCodable) -> SkillInstallSpec? {
        guard let raw = value.dictionaryValue else { return nil }
        let kindRaw = (raw["kind"]?.stringValue ?? raw["type"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let kind = SkillInstallKind(rawValue: kindRaw) else { return nil }
        var spec = SkillInstallSpec(kind: kind)
        if let id = raw["id"]?.stringValue, !id.isEmpty { spec.id = id }
        if let label = raw["label"]?.stringValue, !label.isEmpty { spec.label = label }
        let bins = self.stringList(raw["bins"])
        if !bins.isEmpty { spec.bins = bins }
        let os = self.stringList(raw["os"])
        if !os.isEmpty { spec.os = os }
        spec.formula = self.safeBrewFormula(raw["formula"]?.stringValue) ?? self.safeBrewFormula(raw["cask"]?.stringValue)
        switch kind {
        case .node:
            spec.package = self.safeNpmSpec(raw["package"]?.stringValue)
        case .uv:
            spec.package = self.safePackageSpec(raw["package"]?.stringValue, pattern: self.uvPackagePattern)
        default:
            break
        }
        spec.module = self.safePackageSpec(raw["module"]?.stringValue, pattern: self.goModulePattern)
        spec.url = self.safeDownloadURL(raw["url"]?.stringValue)
        if kind == .download, let rawDigest = raw["sha256"] {
            guard let digest = rawDigest.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            else {
                return nil
            }
            spec.sha256 = digest
        }
        spec.archive = raw["archive"]?.stringValue
        spec.extract = raw["extract"]?.boolValue
        if case .int(let value) = raw["stripComponents"]?.value {
            spec.stripComponents = value
        } else if case .double(let value) = raw["stripComponents"]?.value, value.rounded() == value {
            spec.stripComponents = Int(value)
        }
        spec.targetDir = raw["targetDir"]?.stringValue
        switch kind {
        case .brew where spec.formula == nil,
             .node where spec.package == nil,
             .go where spec.module == nil,
             .uv where spec.package == nil,
             .download where spec.url == nil:
            return nil
        default:
            return spec
        }
    }

    /// Normalizes a comma-separated string or string array into a trimmed list (upstream `normalizeStringList`).
    /// - Parameter value: Raw value.
    /// - Returns: Trimmed non-empty entries.
    public static func stringList(_ value: AnyCodable?) -> [String] {
        guard let value else { return [] }
        if let array = value.arrayValue {
            return array.compactMap { entry -> String? in
                guard let text = entry.stringValue ?? entry.intValue.map(String.init) else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        if let text = value.stringValue {
            return text.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private static func safeBrewFormula(_ raw: String?) -> String? {
        guard let formula = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !formula.isEmpty,
              !formula.hasPrefix("-"), !formula.contains("\\"), !formula.contains(".."),
              formula.range(of: self.brewFormulaPattern, options: .regularExpression) != nil
        else {
            return nil
        }
        return formula
    }

    private static func safeNpmSpec(_ raw: String?) -> String? {
        guard let spec = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !spec.isEmpty, !spec.hasPrefix("-"),
              !spec.contains("://"), !spec.contains("\\"), !spec.contains(".."),
              spec.range(of: self.npmPackagePattern, options: .regularExpression) != nil
        else {
            return nil
        }
        return spec
    }

    private static func safePackageSpec(_ raw: String?, pattern: String) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, !value.hasPrefix("-"),
              !value.contains("\\"), !value.contains("://"),
              value.range(of: pattern, options: .regularExpression) != nil
        else {
            return nil
        }
        return value
    }

    private static func safeDownloadURL(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else {
            return nil
        }
        return url.absoluteString
    }
}
