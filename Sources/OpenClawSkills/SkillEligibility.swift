import Foundation
import OpenClawProtocol

/// Host platform tokens used for skill `os` requirements.
///
/// `darwin` (macOS) and `linux` are upstream tokens; `ios`, `tvos`, `watchos` and `visionos` are
/// OpenClawKit extensions, so a darwin-only skill is incompatible on iOS.
public enum SkillPlatform {
    /// Token of the current host.
    public static var current: String {
        #if os(macOS)
        return "darwin"
        #elseif os(iOS)
        return "ios"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(visionOS)
        return "visionos"
        #elseif os(Linux)
        return "linux"
        #elseif os(Windows)
        return "win32"
        #else
        return "unknown"
        #endif
    }

    /// Whether the host can run external binaries (macOS and Linux).
    public static var canSpawnProcesses: Bool {
        #if os(macOS) || os(Linux)
        return true
        #else
        return false
        #endif
    }

    /// Normalizes a platform token (`macos` is an alias of `darwin`).
    /// - Parameter token: Raw token.
    /// - Returns: Lowercased token.
    public static func normalize(_ token: String) -> String {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "macos" ? "darwin" : normalized
    }

    /// Looks a binary up on `PATH` (always `false` where processes cannot be spawned).
    /// - Parameters:
    ///   - name: Binary name or path.
    ///   - environment: Environment providing `PATH`.
    /// - Returns: `true` when an executable file is found.
    public static func hasBinary(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard self.canSpawnProcesses else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let fileManager = FileManager.default
        if trimmed.contains("/") {
            return fileManager.isExecutableFile(atPath: trimmed)
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(trimmed).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }
}

/// Inputs for evaluating skill eligibility on a host.
public struct SkillEligibilityContext: Sendable {
    /// Host platform token (see ``SkillPlatform``).
    public var platform: String
    /// Process environment used for `requires.env`.
    public var environment: [String: String]
    /// JSON form of the app config for `requires.config` dot-path checks (for example an encoded `OpenClawConfig`).
    public var config: AnyCodable?
    /// Skill settings (enabled flags, bundled allowlist, per-skill env/apiKey).
    public var skills: SkillsConfiguration
    /// Per-agent skill allowlist (`agents.entries.<id>.skills`); `nil` allows every skill.
    public var agentSkillFilter: [String]?
    /// Binary probe; defaults to a `PATH` lookup (always `false` on iOS-family platforms).
    public var hasBinary: @Sendable (String) -> Bool

    /// Creates an eligibility context.
    /// - Parameters:
    ///   - platform: Platform token.
    ///   - environment: Process environment.
    ///   - config: Config JSON.
    ///   - skills: Skill settings.
    ///   - agentSkillFilter: Agent skill filter.
    ///   - hasBinary: Binary probe.
    public init(
        platform: String = SkillPlatform.current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        config: AnyCodable? = nil,
        skills: SkillsConfiguration = SkillsConfiguration(),
        agentSkillFilter: [String]? = nil,
        hasBinary: (@Sendable (String) -> Bool)? = nil
    ) {
        self.platform = platform
        self.environment = environment
        self.config = config
        self.skills = skills
        self.agentSkillFilter = agentSkillFilter
        let env = environment
        self.hasBinary = hasBinary ?? { SkillPlatform.hasBinary($0, environment: env) }
    }

    /// Creates a context whose `requires.config` checks read an encodable config (for example `OpenClawConfig`).
    /// - Parameters:
    ///   - config: Encodable config.
    ///   - skills: Skill settings.
    ///   - agentSkillFilter: Agent skill filter.
    /// - Returns: The context.
    public static func encoding(
        _ config: some Encodable,
        skills: SkillsConfiguration = SkillsConfiguration(),
        agentSkillFilter: [String]? = nil
    ) -> SkillEligibilityContext {
        SkillEligibilityContext(config: try? AnyCodable(encoding: config), skills: skills, agentSkillFilter: agentSkillFilter)
    }
}

/// Eligibility of one skill on a host (upstream `buildSkillRequirements` + agent filter).
public struct SkillEligibility: Sendable, Equatable {
    /// Config key.
    public let skillKey: String
    /// Always flag.
    public let always: Bool
    /// Disabled by config.
    public let disabled: Bool
    /// Bundled skill blocked by `allowBundled`.
    public let blockedByAllowlist: Bool
    /// Blocked by the agent skill filter.
    public let blockedByAgentFilter: Bool
    /// The skill's `os` list excludes this host.
    public let platformIncompatible: Bool
    /// Declared requirements.
    public let requirements: SkillStatusRequirements
    /// Missing requirements (`always` clears everything but `os`).
    public let missing: SkillStatusRequirements
    /// Config checks.
    public let configChecks: [SkillRequirementConfigCheck]

    /// Creates an eligibility result.
    /// - Parameters:
    ///   - skillKey: Skill key.
    ///   - always: Always flag.
    ///   - disabled: Disabled flag.
    ///   - blockedByAllowlist: Allowlist flag.
    ///   - blockedByAgentFilter: Agent filter flag.
    ///   - platformIncompatible: Platform flag.
    ///   - requirements: Requirements.
    ///   - missing: Missing requirements.
    ///   - configChecks: Config checks.
    public init(
        skillKey: String,
        always: Bool,
        disabled: Bool,
        blockedByAllowlist: Bool,
        blockedByAgentFilter: Bool,
        platformIncompatible: Bool,
        requirements: SkillStatusRequirements,
        missing: SkillStatusRequirements,
        configChecks: [SkillRequirementConfigCheck]
    ) {
        self.skillKey = skillKey
        self.always = always
        self.disabled = disabled
        self.blockedByAllowlist = blockedByAllowlist
        self.blockedByAgentFilter = blockedByAgentFilter
        self.platformIncompatible = platformIncompatible
        self.requirements = requirements
        self.missing = missing
        self.configChecks = configChecks
    }

    /// Requirements are satisfied (`os` always applies; `always` bypasses the rest).
    public var requirementsSatisfied: Bool {
        self.missing.isEmpty
    }

    /// Upstream `eligible`: enabled, allowed, and requirements satisfied (the agent filter is separate).
    public var eligible: Bool {
        !self.disabled && !self.blockedByAllowlist && self.requirementsSatisfied
    }

    /// Eligible and not blocked by the agent filter.
    public var availableToAgent: Bool {
        self.eligible && !self.blockedByAgentFilter
    }
}

/// Evaluates skill eligibility (upstream `src/shared/requirements.ts` and `src/skills/loading/config.ts`).
public enum SkillEligibilityEvaluator {
    /// Config paths that default to `true` when unset (upstream `DEFAULT_CONFIG_VALUES`).
    public static let defaultConfigValues: [String: Bool] = [
        "browser.enabled": true,
        "browser.evaluateEnabled": true,
    ]

    /// Evaluates one skill.
    /// - Parameters:
    ///   - skill: Skill definition.
    ///   - context: Host context.
    /// - Returns: Eligibility.
    public static func evaluate(_ skill: SkillDefinition, context: SkillEligibilityContext) -> SkillEligibility {
        let skillKey = skill.skillKey
        let entry = context.skills.entry(for: skillKey)
        let disabled = entry?.enabled == false
        let blockedByAllowlist = !self.isBundledSkillAllowed(skill, allowlist: context.skills.allowBundled)
        let blockedByAgentFilter = context.agentSkillFilter.map { !Set($0).contains(skill.name) } ?? false
        let always = skill.metadata.always == true
        let requires = skill.metadata.requires ?? SkillManifestRequirements()
        let required = SkillStatusRequirements(
            bins: requires.bins,
            anyBins: requires.anyBins,
            env: requires.env,
            config: requires.config,
            os: skill.metadata.os
        )

        let missingBins = required.bins.filter { !context.hasBinary($0) }
        let missingAnyBins = required.anyBins.isEmpty || required.anyBins.contains(where: context.hasBinary) ? [] : required.anyBins
        var missingOS: [String] = []
        if !required.os.isEmpty {
            let host = SkillPlatform.normalize(context.platform)
            if !Set(required.os.map(SkillPlatform.normalize)).contains(host) {
                missingOS = required.os
            }
        }
        let missingEnv = required.env.filter { envName in
            self.isEnvSatisfied(envName, entry: entry, primaryEnv: skill.metadata.primaryEnv, environment: context.environment) == false
        }
        let configChecks = required.config.map { path in
            let value = self.resolveConfigPath(context.config, path: path)
            return SkillRequirementConfigCheck(path: path, value: value, satisfied: self.isConfigPathTruthy(context.config, path: path))
        }
        let missingConfig = configChecks.filter { !$0.satisfied }.map(\.path)
        let missing = SkillStatusRequirements(
            bins: always ? [] : missingBins,
            anyBins: always ? [] : missingAnyBins,
            env: always ? [] : missingEnv,
            config: always ? [] : missingConfig,
            os: missingOS
        )
        return SkillEligibility(
            skillKey: skillKey,
            always: always,
            disabled: disabled,
            blockedByAllowlist: blockedByAllowlist,
            blockedByAgentFilter: blockedByAgentFilter,
            platformIncompatible: !missingOS.isEmpty,
            requirements: required,
            missing: missing,
            configChecks: configChecks
        )
    }

    /// Upstream `isBundledSkillAllowed`: non-bundled skills are always allowed.
    /// - Parameters:
    ///   - skill: Skill definition.
    ///   - allowlist: Bundled allowlist.
    /// - Returns: `true` when allowed.
    public static func isBundledSkillAllowed(_ skill: SkillDefinition, allowlist: [String]?) -> Bool {
        let normalized = (allowlist ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !normalized.isEmpty, skill.source.isBundled else { return true }
        let set = Set(normalized)
        return set.contains(skill.skillKey) || set.contains(skill.name)
    }

    /// Upstream `isSkillEnvRequirementSatisfied`.
    /// - Parameters:
    ///   - envName: Variable name.
    ///   - entry: Skill settings.
    ///   - primaryEnv: The skill's primary environment variable.
    ///   - environment: Process environment.
    /// - Returns: `true` when satisfied.
    public static func isEnvSatisfied(
        _ envName: String,
        entry: SkillsConfiguration.Entry?,
        primaryEnv: String?,
        environment: [String: String]
    ) -> Bool {
        if let value = environment[envName], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let value = entry?.env?[envName], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return primaryEnv == envName && entry?.hasConfiguredAPIKey == true
    }

    /// Resolves a dot-path in a JSON config.
    /// - Parameters:
    ///   - config: Config JSON.
    ///   - path: Dot-path.
    /// - Returns: The value, or `nil`.
    public static func resolveConfigPath(_ config: AnyCodable?, path: String) -> AnyCodable? {
        var current = config
        for part in path.split(separator: ".") where !part.isEmpty {
            let key = String(part)
            if key == "__proto__" || key == "constructor" || key == "prototype" { return nil }
            guard let object = current?.dictionaryValue else { return nil }
            current = object[key]
        }
        return current
    }

    /// Upstream `isConfigPathTruthyWithDefaults`.
    /// - Parameters:
    ///   - config: Config JSON.
    ///   - path: Dot-path.
    /// - Returns: `true` when the value is truthy (or unset with a `true` default).
    public static func isConfigPathTruthy(_ config: AnyCodable?, path: String) -> Bool {
        let value = self.resolveConfigPath(config, path: path)
        guard let value else {
            return self.defaultConfigValues[path] ?? false
        }
        switch value.value {
        case .null:
            return false
        case .bool(let flag):
            return flag
        case .int(let number):
            return number != 0
        case .double(let number):
            return number != 0
        case .string(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .object, .array:
            return true
        }
    }

    /// Upstream `normalizeInstallOptions` (brew preferred when available, else uv, node, go, download).
    /// - Parameters:
    ///   - skill: Skill definition.
    ///   - context: Host context.
    ///   - preferBrew: Prefer brew when available.
    ///   - nodeManager: Node package manager label.
    /// - Returns: Offered install options.
    public static func installOptions(
        for skill: SkillDefinition,
        context: SkillEligibilityContext,
        preferBrew: Bool = true,
        nodeManager: String = "npm"
    ) -> [SkillStatusInstallOption] {
        let platform = SkillPlatform.normalize(context.platform)
        let requiredOS = skill.metadata.os.map(SkillPlatform.normalize)
        if !requiredOS.isEmpty, !requiredOS.contains(platform) { return [] }
        let install = skill.metadata.install
        guard !install.isEmpty else { return [] }
        let supports: (SkillInstallSpec) -> Bool = { spec in
            let list = (spec.os ?? []).map(SkillPlatform.normalize)
            return list.isEmpty || list.contains(platform)
        }
        let filtered = install.filter(supports)
        guard !filtered.isEmpty else { return [] }
        let toOption: (SkillInstallSpec, Int) -> SkillStatusInstallOption = { spec, index in
            let id = (spec.id ?? "\(spec.kind.rawValue)-\(index)").trimmingCharacters(in: .whitespacesAndNewlines)
            var label = (spec.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if spec.kind == .node, let package = spec.package {
                label = "Install \(package) (\(nodeManager))"
            }
            if label.isEmpty {
                switch spec.kind {
                case .brew where spec.formula != nil:
                    label = "Install \(spec.formula!) (brew)"
                case .go where spec.module != nil:
                    label = "Install \(spec.module!) (go)"
                case .uv where spec.package != nil:
                    label = "Install \(spec.package!) (uv)"
                case .download where spec.url != nil:
                    let url = spec.url!.trimmingCharacters(in: .whitespacesAndNewlines)
                    let last = url.split(separator: "/").last.map(String.init) ?? ""
                    label = "Download \(last.isEmpty ? url : last)"
                default:
                    label = "Run installer"
                }
            }
            return SkillStatusInstallOption(id: id, kind: spec.kind.rawValue, label: label, bins: spec.bins ?? [])
        }
        if filtered.allSatisfy({ $0.kind == .download }) {
            return install.enumerated().filter { supports($0.element) }.map { toOption($0.element, $0.offset) }
        }
        let find: (SkillInstallKind) -> SkillInstallSpec? = { kind in filtered.first { $0.kind == kind } }
        let brew = find(.brew)
        let brewAvailable = brew != nil && context.hasBinary("brew")
        let preferred = (preferBrew && brewAvailable ? brew : nil)
            ?? find(.uv)
            ?? find(.node)
            ?? (brewAvailable ? brew : nil)
            ?? find(.go)
            ?? find(.download)
            ?? brew
            ?? install.first
        guard let preferred, let index = install.firstIndex(of: preferred) else { return [] }
        return [toOption(preferred, index)]
    }
}
