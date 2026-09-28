import Foundation

/// Default alias used when a secret reference omits its provider.
public let DEFAULT_SECRET_PROVIDER_ALIAS = "default"
/// Sentinel file-secret ID used when a file contains one raw value instead of JSON.
public let SINGLE_VALUE_FILE_SECRET_REF_ID = "value"

/// Prefix of the retired `secretref-env:NAME` env marker (decode-only).
public let LEGACY_SECRETREF_ENV_MARKER_PREFIX = "secretref-env:"
/// Prefix of the older retired `__env__:NAME` env marker (decode-only).
public let LEGACY_DOUBLE_UNDERSCORE_ENV_MARKER_PREFIX = "__env__:"

enum SecretPatterns {
    static let envID = try! NSRegularExpression(pattern: "^[A-Z][A-Z0-9_]{0,127}$")
    static let envTemplate = try! NSRegularExpression(pattern: #"^\$\{([A-Z][A-Z0-9_]{0,127})\}$"#)
    static let envShorthand = try! NSRegularExpression(pattern: #"^\$([A-Z][A-Z0-9_]{0,127})$"#)
    static let providerAlias = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_-]{0,63}$")
    static let execID = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._:/#-]{0,255}$")
    static let integrationID = try! NSRegularExpression(pattern: "^.{1,128}$")

    static func matches(_ regex: NSRegularExpression, value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else {
            return false
        }
        return match.range.location != NSNotFound && match.range.length == range.length
    }

    static func envTemplateRef(_ value: String, provider: String = DEFAULT_SECRET_PROVIDER_ALIAS) -> SecretRef? {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for pattern in [self.envTemplate, self.envShorthand] {
            guard let match = pattern.firstMatch(in: value, range: range),
                  match.numberOfRanges == 2,
                  let idRange = Range(match.range(at: 1), in: value)
            else {
                continue
            }
            return SecretRef(source: .env, provider: provider, id: String(value[idRange]))
        }
        return nil
    }
}

/// Secret source kinds supported by OpenClaw parity config (upstream `SecretRefSource`).
///
/// - Note: 2026.3.0 added `store` (the host's shared secret store; in-process SDK gateways map it to
///   the platform ``CredentialStore``). Exhaustive `switch` statements need the new case.
public enum SecretRefSource: String, Codable, Sendable, Equatable, CaseIterable {
    case env
    case file
    case exec
    /// Shared host secret store. Ids use the environment-variable grammar.
    case store
}

/// Stable identifier for a secret stored in a configured provider.
public struct SecretRef: Codable, Sendable, Equatable {
    public var source: SecretRefSource
    public var provider: String
    public var id: String

    public init(
        source: SecretRefSource,
        provider: String = DEFAULT_SECRET_PROVIDER_ALIAS,
        id: String
    ) {
        self.source = source
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provider = trimmedProvider.isEmpty ? DEFAULT_SECRET_PROVIDER_ALIAS : trimmedProvider
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case provider
        case id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(SecretRefSource.self, forKey: .source)
        let provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? DEFAULT_SECRET_PROVIDER_ALIAS
        let id = try container.decode(String.self, forKey: .id)
        self.init(source: source, provider: provider, id: id)
    }

    public func normalized(using defaults: SecretDefaultsConfig = SecretDefaultsConfig()) -> SecretRef {
        let fallbackProvider = defaults.providerAlias(for: self.source)
        let trimmedProvider = self.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        return SecretRef(
            source: self.source,
            provider: trimmedProvider.isEmpty ? fallbackProvider : trimmedProvider,
            id: self.id
        )
    }

    public func validationError(using defaults: SecretDefaultsConfig = SecretDefaultsConfig()) -> String? {
        let normalized = self.normalized(using: defaults)
        guard SecretPatterns.matches(SecretPatterns.providerAlias, value: normalized.provider) else {
            return "Secret provider alias must match ^[a-z][a-z0-9_-]{0,63}$."
        }

        switch normalized.source {
        case .env:
            guard SecretPatterns.matches(SecretPatterns.envID, value: normalized.id) else {
                return "Environment SecretRef ids must match ^[A-Z][A-Z0-9_]{0,127}$."
            }
        case .store:
            guard SecretPatterns.matches(SecretPatterns.envID, value: normalized.id) else {
                return "Store SecretRef ids must match ^[A-Z][A-Z0-9_]{0,127}$."
            }
        case .file:
            guard Self.isValidFileSecretRefID(normalized.id) else {
                return #"File SecretRef ids must be "value" or a JSON pointer like "/providers/openai/apiKey"."#
            }
        case .exec:
            guard SecretPatterns.matches(SecretPatterns.execID, value: normalized.id) else {
                return "Exec SecretRef ids must match ^[A-Za-z0-9][A-Za-z0-9._:/#-]{0,255}$."
            }
            for segment in normalized.id.split(separator: "/", omittingEmptySubsequences: false) {
                if segment == "." || segment == ".." {
                    return #"Exec SecretRef ids must not include "." or ".." path segments."#
                }
            }
        }
        return nil
    }

    /// Parses the `${NAME}` template or the `$NAME` shorthand into an env SecretRef.
    /// - Parameters:
    ///   - value: Candidate string (trimmed before matching).
    ///   - provider: Provider alias for the resulting ref.
    /// - Returns: The env ref, or `nil` when `value` is not an env shorthand.
    public static func parseEnvTemplate(
        _ value: String,
        provider: String = DEFAULT_SECRET_PROVIDER_ALIAS
    ) -> SecretRef? {
        SecretPatterns.envTemplateRef(
            value.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider
        )
    }

    /// Whether `value` is a retired `secretref-env:NAME` or `__env__:NAME` marker string.
    /// - Parameter value: Candidate string.
    /// - Returns: `true` for either legacy prefix.
    public static func isLegacyEnvMarker(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(LEGACY_SECRETREF_ENV_MARKER_PREFIX) || trimmed.hasPrefix(LEGACY_DOUBLE_UNDERSCORE_ENV_MARKER_PREFIX)
    }

    /// Parses a retired env marker string into an env SecretRef (upstream only reads these during
    /// doctor migration; the SDK accepts them on decode and never writes them).
    /// - Parameters:
    ///   - value: Marker string such as `secretref-env:OPENAI_API_KEY`.
    ///   - provider: Provider alias for the resulting ref.
    /// - Returns: The env ref, or `nil` when the marker is malformed.
    public static func parseLegacyEnvMarker(
        _ value: String,
        provider: String = DEFAULT_SECRET_PROVIDER_ALIAS
    ) -> SecretRef? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        if trimmed.hasPrefix(LEGACY_SECRETREF_ENV_MARKER_PREFIX) {
            prefix = LEGACY_SECRETREF_ENV_MARKER_PREFIX
        } else if trimmed.hasPrefix(LEGACY_DOUBLE_UNDERSCORE_ENV_MARKER_PREFIX) {
            prefix = LEGACY_DOUBLE_UNDERSCORE_ENV_MARKER_PREFIX
        } else {
            return nil
        }
        let id = String(trimmed.dropFirst(prefix.count))
        guard SecretPatterns.matches(SecretPatterns.envID, value: id) else {
            return nil
        }
        return SecretRef(source: .env, provider: provider, id: id)
    }

    public static func isValidFileSecretRefID(_ value: String) -> Bool {
        if value == SINGLE_VALUE_FILE_SECRET_REF_ID {
            return true
        }
        guard value.hasPrefix("/") else {
            return false
        }
        let suffix = value.dropFirst()
        return suffix.split(separator: "/", omittingEmptySubsequences: false).allSatisfy(Self.isValidFileSegment)
    }

    private static func isValidFileSegment(_ segment: Substring) -> Bool {
        var index = segment.startIndex
        while index < segment.endIndex {
            let character = segment[index]
            guard character == "~" else {
                index = segment.index(after: index)
                continue
            }
            let escapedIndex = segment.index(after: index)
            guard escapedIndex < segment.endIndex else {
                return false
            }
            let escapedCharacter = segment[escapedIndex]
            guard escapedCharacter == "0" || escapedCharacter == "1" else {
                return false
            }
            index = segment.index(after: escapedIndex)
        }
        return true
    }
}

/// Secret-bearing config inputs accept either a plaintext string or a structured SecretRef.
public enum SecretInput: Codable, Sendable, Equatable {
    case string(String)
    case ref(SecretRef)

    /// Decodes a plaintext string, an env shorthand (`${NAME}` / `$NAME`), a retired env marker
    /// (`secretref-env:NAME`, `__env__:NAME`, recorded as a legacy-key issue) or a SecretRef object.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            let parsed = Self.parse(stringValue)
            if parsed.isLegacyMarker {
                ConfigDecodeIssueReporting.record(
                    "Retired env marker \"\(stringValue)\" decoded as an env SecretRef; write {source, provider, id} instead.",
                    kind: .legacyKey,
                    decoder: decoder
                )
            }
            self = parsed.input
            return
        }
        self = .ref(try container.decode(SecretRef.self))
    }

    /// Interprets a secret string: env shorthands and retired env markers become env refs.
    /// - Parameters:
    ///   - value: Raw string.
    ///   - envProvider: Provider alias for env refs (upstream `secrets.defaults.env`).
    /// - Returns: The input and whether a retired marker was used.
    public static func parse(
        _ value: String,
        envProvider: String = DEFAULT_SECRET_PROVIDER_ALIAS
    ) -> (input: SecretInput, isLegacyMarker: Bool) {
        if let envRef = SecretRef.parseEnvTemplate(value, provider: envProvider) {
            return (.ref(envRef), false)
        }
        if let markerRef = SecretRef.parseLegacyEnvMarker(value, provider: envProvider) {
            return (.ref(markerRef), true)
        }
        return (.string(value), false)
    }

    /// Whether the value is a plaintext `config.get` redaction marker (never a real secret).
    public var isRedacted: Bool {
        ConfigRedaction.isRedactedSecretValue(self.stringValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .ref(let ref):
            try container.encode(ref)
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    public var refValue: SecretRef? {
        guard case .ref(let value) = self else {
            return nil
        }
        return value
    }
}

public struct EnvSecretProviderConfig: Codable, Sendable, Equatable {
    public var source: SecretRefSource
    public var allowlist: [String]

    public init(
        source: SecretRefSource = .env,
        allowlist: [String] = []
    ) {
        self.source = source
        self.allowlist = allowlist
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case allowlist
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try container.decodeIfPresent(SecretRefSource.self, forKey: .source) ?? .env
        self.allowlist = try container.decodeIfPresent([String].self, forKey: .allowlist) ?? []
    }
}

public enum FileSecretProviderMode: String, Codable, Sendable, Equatable, CaseIterable {
    case singleValue
    case json
}

public struct FileSecretProviderConfig: Codable, Sendable, Equatable {
    public var source: SecretRefSource
    public var path: String
    public var mode: FileSecretProviderMode
    public var timeoutMs: Int
    public var maxBytes: Int

    public init(
        source: SecretRefSource = .file,
        path: String,
        mode: FileSecretProviderMode = .json,
        timeoutMs: Int = 5_000,
        maxBytes: Int = 1_048_576
    ) {
        self.source = source
        self.path = path
        self.mode = mode
        self.timeoutMs = max(1, timeoutMs)
        self.maxBytes = max(1, maxBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case path
        case mode
        case timeoutMs
        case maxBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try container.decodeIfPresent(SecretRefSource.self, forKey: .source) ?? .file,
            path: try container.decode(String.self, forKey: .path),
            mode: try container.decodeIfPresent(FileSecretProviderMode.self, forKey: .mode) ?? .json,
            timeoutMs: try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 5_000,
            maxBytes: try container.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 1_048_576
        )
    }

    /// Upstream schema checks: `timeoutMs` ≤ 120000 and `maxBytes` ≤ 20 MiB.
    /// - Returns: Human-readable problems (empty when valid).
    public func validationErrors() -> [String] {
        var errors: [String] = []
        if self.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("File secret provider path must not be empty.")
        }
        if self.timeoutMs > 120_000 {
            errors.append("File secret provider timeoutMs must be at most 120000 ms.")
        }
        if self.maxBytes > 20 * 1_024 * 1_024 {
            errors.append("File secret provider maxBytes must be at most 20 MiB.")
        }
        return errors
    }
}

/// `pluginIntegration` form of an exec secret provider: a plugin-owned integration resolves the refs.
public struct ExecSecretPluginIntegration: Codable, Sendable, Equatable {
    /// Plugin id (1...128 characters).
    public var pluginId: String
    /// Integration id inside the plugin (1...128 characters).
    public var integrationId: String

    /// Creates a plugin integration reference.
    /// - Parameters:
    ///   - pluginId: Plugin id.
    ///   - integrationId: Integration id.
    public init(pluginId: String, integrationId: String) {
        self.pluginId = pluginId
        self.integrationId = integrationId
    }
}

public struct ExecSecretProviderConfig: Codable, Sendable, Equatable {
    public var source: SecretRefSource
    /// Absolute path of the resolver command (empty for the ``pluginIntegration`` form).
    public var command: String
    /// Plugin-owned integration that resolves refs instead of a local command (2026.9.6).
    public var pluginIntegration: ExecSecretPluginIntegration?
    public var args: [String]
    public var timeoutMs: Int
    public var noOutputTimeoutMs: Int
    public var maxOutputBytes: Int
    public var jsonOnly: Bool
    public var env: [String: String]
    public var passEnv: [String]
    public var trustedDirs: [String]
    public var allowInsecurePath: Bool
    public var allowSymlinkCommand: Bool

    public init(
        source: SecretRefSource = .exec,
        command: String,
        args: [String] = [],
        timeoutMs: Int = 5_000,
        noOutputTimeoutMs: Int? = nil,
        maxOutputBytes: Int = 1_048_576,
        jsonOnly: Bool = true,
        env: [String: String] = [:],
        passEnv: [String] = [],
        trustedDirs: [String] = [],
        allowInsecurePath: Bool = false,
        allowSymlinkCommand: Bool = false,
        pluginIntegration: ExecSecretPluginIntegration? = nil
    ) {
        self.source = source
        self.command = command
        self.pluginIntegration = pluginIntegration
        self.args = args
        let normalizedTimeoutMs = max(1, timeoutMs)
        self.timeoutMs = normalizedTimeoutMs
        self.noOutputTimeoutMs = max(1, noOutputTimeoutMs ?? normalizedTimeoutMs)
        self.maxOutputBytes = max(1, maxOutputBytes)
        self.jsonOnly = jsonOnly
        self.env = env
        self.passEnv = passEnv
        self.trustedDirs = trustedDirs
        self.allowInsecurePath = allowInsecurePath
        self.allowSymlinkCommand = allowSymlinkCommand
    }

    /// Creates the plugin-integration form (no local command).
    /// - Parameter pluginIntegration: Plugin and integration ids.
    public init(pluginIntegration: ExecSecretPluginIntegration) {
        self.init(command: "", pluginIntegration: pluginIntegration)
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case command
        case pluginIntegration
        case args
        case timeoutMs
        case noOutputTimeoutMs
        case maxOutputBytes
        case jsonOnly
        case env
        case passEnv
        case trustedDirs
        case allowInsecurePath
        case allowSymlinkCommand
    }

    /// Decodes the manual (`command`) or `pluginIntegration` form.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 5_000
        let pluginIntegration = container.decodeLenient(ExecSecretPluginIntegration.self, forKey: .pluginIntegration)
        let command: String
        if pluginIntegration != nil {
            command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        } else {
            command = try container.decode(String.self, forKey: .command)
        }
        self.init(
            source: try container.decodeIfPresent(SecretRefSource.self, forKey: .source) ?? .exec,
            command: command,
            args: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
            timeoutMs: timeoutMs,
            noOutputTimeoutMs: try container.decodeIfPresent(Int.self, forKey: .noOutputTimeoutMs) ?? timeoutMs,
            maxOutputBytes: try container.decodeIfPresent(Int.self, forKey: .maxOutputBytes) ?? 1_048_576,
            jsonOnly: try container.decodeIfPresent(Bool.self, forKey: .jsonOnly) ?? true,
            env: try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
            passEnv: try container.decodeIfPresent([String].self, forKey: .passEnv) ?? [],
            trustedDirs: try container.decodeIfPresent([String].self, forKey: .trustedDirs) ?? [],
            allowInsecurePath: try container.decodeIfPresent(Bool.self, forKey: .allowInsecurePath) ?? false,
            allowSymlinkCommand: try container.decodeIfPresent(Bool.self, forKey: .allowSymlinkCommand) ?? false,
            pluginIntegration: pluginIntegration
        )
    }

    /// Encodes the provider. Under ``Swift/CodingUserInfoKey/openClawUpstreamProjection`` the retired
    /// `allowInsecurePath`/`allowSymlinkCommand` keys are omitted and the plugin form writes only
    /// `source` and `pluginIntegration`, matching the strict upstream schema.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let projection = encoder.userInfo[.openClawUpstreamProjection] as? Bool == true
        try container.encode(self.source, forKey: .source)
        if let pluginIntegration = self.pluginIntegration {
            try container.encode(pluginIntegration, forKey: .pluginIntegration)
            if projection {
                return
            }
        }
        if !(projection && self.command.isEmpty) {
            try container.encode(self.command, forKey: .command)
        }
        try container.encode(self.args, forKey: .args)
        try container.encode(self.timeoutMs, forKey: .timeoutMs)
        try container.encode(self.noOutputTimeoutMs, forKey: .noOutputTimeoutMs)
        try container.encode(self.maxOutputBytes, forKey: .maxOutputBytes)
        try container.encode(self.jsonOnly, forKey: .jsonOnly)
        try container.encode(self.env, forKey: .env)
        try container.encode(self.passEnv, forKey: .passEnv)
        try container.encode(self.trustedDirs, forKey: .trustedDirs)
        if !projection {
            try container.encode(self.allowInsecurePath, forKey: .allowInsecurePath)
            try container.encode(self.allowSymlinkCommand, forKey: .allowSymlinkCommand)
        }
    }

    /// Upstream schema checks: absolute command path (manual form) or a valid plugin integration,
    /// `args` ≤ 128, `timeoutMs` ≤ 120000, `maxOutputBytes` ≤ 20 MiB, `passEnv` env ids (≤ 128),
    /// absolute `trustedDirs` (≤ 64).
    /// - Returns: Human-readable problems (empty when valid).
    public func validationErrors() -> [String] {
        var errors: [String] = []
        if let integration = self.pluginIntegration {
            for (label, value) in [("pluginId", integration.pluginId), ("integrationId", integration.integrationId)]
            where value.isEmpty || value.count > 128 {
                errors.append("Exec secret provider pluginIntegration.\(label) must be 1-128 characters.")
            }
            return errors
        }
        if !self.command.hasPrefix("/") {
            errors.append("Exec secret provider command must be an absolute path.")
        }
        if self.args.count > 128 {
            errors.append("Exec secret provider args must contain at most 128 entries.")
        }
        if self.timeoutMs > 120_000 || self.noOutputTimeoutMs > 120_000 {
            errors.append("Exec secret provider timeouts must be at most 120000 ms.")
        }
        if self.maxOutputBytes > 20 * 1_024 * 1_024 {
            errors.append("Exec secret provider maxOutputBytes must be at most 20 MiB.")
        }
        if self.passEnv.count > 128 || self.passEnv.contains(where: { !SecretPatterns.matches(SecretPatterns.envID, value: $0) }) {
            errors.append("Exec secret provider passEnv must contain at most 128 env ids matching ^[A-Z][A-Z0-9_]{0,127}$.")
        }
        if self.trustedDirs.count > 64 || self.trustedDirs.contains(where: { !$0.hasPrefix("/") }) {
            errors.append("Exec secret provider trustedDirs must contain at most 64 absolute paths.")
        }
        return errors
    }
}

/// Config for a `store` secret provider (upstream `{ source: "store" }`, no other fields).
public struct StoreSecretProviderConfig: Codable, Sendable, Equatable {
    /// Provider source; always ``SecretRefSource/store``.
    public var source: SecretRefSource

    /// Creates a store secret provider config.
    public init() {
        self.source = .store
    }

    private enum CodingKeys: String, CodingKey {
        case source
    }

    /// Decodes a store provider; the `source` field is implied.
    public init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: CodingKeys.self)
        self.source = .store
    }
}

/// - Note: 2026.3.0 added the `store` case. Exhaustive `switch` statements need the new case.
public enum SecretProviderConfig: Codable, Sendable, Equatable {
    case env(EnvSecretProviderConfig)
    case file(FileSecretProviderConfig)
    case exec(ExecSecretProviderConfig)
    /// Shared host secret store provider.
    case store(StoreSecretProviderConfig)

    public var source: SecretRefSource {
        switch self {
        case .env(let config):
            return config.source
        case .file(let config):
            return config.source
        case .exec(let config):
            return config.source
        case .store(let config):
            return config.source
        }
    }

    private enum CodingKeys: String, CodingKey {
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(SecretRefSource.self, forKey: .source)
        switch source {
        case .env:
            self = .env(try EnvSecretProviderConfig(from: decoder))
        case .file:
            self = .file(try FileSecretProviderConfig(from: decoder))
        case .exec:
            self = .exec(try ExecSecretProviderConfig(from: decoder))
        case .store:
            self = .store(try StoreSecretProviderConfig(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .env(let config):
            try config.encode(to: encoder)
        case .file(let config):
            try config.encode(to: encoder)
        case .exec(let config):
            try config.encode(to: encoder)
        case .store(let config):
            try config.encode(to: encoder)
        }
    }
}

public struct SecretDefaultsConfig: Codable, Sendable, Equatable {
    public var env: String
    public var file: String?
    public var exec: String?
    /// Default provider alias for `store` secret refs.
    public var store: String?

    public init(
        env: String = DEFAULT_SECRET_PROVIDER_ALIAS,
        file: String? = nil,
        exec: String? = nil,
        store: String? = nil
    ) {
        let normalizedEnv = env.trimmingCharacters(in: .whitespacesAndNewlines)
        self.env = normalizedEnv.isEmpty ? DEFAULT_SECRET_PROVIDER_ALIAS : normalizedEnv
        self.file = file?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.exec = exec?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.store = store?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func providerAlias(for source: SecretRefSource) -> String {
        switch source {
        case .env:
            return self.env
        case .file:
            return self.file?.isEmpty == false ? self.file! : DEFAULT_SECRET_PROVIDER_ALIAS
        case .exec:
            return self.exec?.isEmpty == false ? self.exec! : DEFAULT_SECRET_PROVIDER_ALIAS
        case .store:
            return self.store?.isEmpty == false ? self.store! : DEFAULT_SECRET_PROVIDER_ALIAS
        }
    }
}

public struct SecretResolutionConfig: Codable, Sendable, Equatable {
    public var maxProviderConcurrency: Int
    public var maxRefsPerProvider: Int
    public var maxBatchBytes: Int

    public init(
        maxProviderConcurrency: Int = 4,
        maxRefsPerProvider: Int = 512,
        maxBatchBytes: Int = 256 * 1024
    ) {
        self.maxProviderConcurrency = max(1, maxProviderConcurrency)
        self.maxRefsPerProvider = max(1, maxRefsPerProvider)
        self.maxBatchBytes = max(1, maxBatchBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case maxProviderConcurrency
        case maxRefsPerProvider
        case maxBatchBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxProviderConcurrency: try container.decodeIfPresent(Int.self, forKey: .maxProviderConcurrency) ?? 4,
            maxRefsPerProvider: try container.decodeIfPresent(Int.self, forKey: .maxRefsPerProvider) ?? 512,
            maxBatchBytes: try container.decodeIfPresent(Int.self, forKey: .maxBatchBytes) ?? 256 * 1024
        )
    }
}

/// `secrets.egressProxy`: host allowlists for the gateway-side secret egress proxy (server behavior;
/// the SDK only decodes it).
public struct SecretEgressProxyConfig: Codable, Sendable, Equatable {
    /// Enables the egress proxy.
    public var enabled: Bool?
    /// Exact hostnames secrets may be sent to (max 256).
    public var allowedHosts: [String]?
    /// Exact hostnames that bypass the proxy (max 256).
    public var bypassHosts: [String]?

    /// Creates an egress proxy config.
    /// - Parameters:
    ///   - enabled: Enables the proxy.
    ///   - allowedHosts: Allowed exact hosts.
    ///   - bypassHosts: Bypassed exact hosts.
    public init(enabled: Bool? = nil, allowedHosts: [String]? = nil, bypassHosts: [String]? = nil) {
        self.enabled = enabled
        self.allowedHosts = allowedHosts
        self.bypassHosts = bypassHosts
    }
}

/// Canonical top-level secrets config aligned with OpenClaw secret-provider docs.
///
/// - Note: `resolution` is retired upstream (2026.9.6). The SDK keeps it as a local runtime knob but
///   never writes it into an upstream projection (see ``Swift/CodingUserInfoKey/openClawUpstreamProjection``).
public struct SecretsConfig: Codable, Sendable, Equatable {
    public var providers: [String: SecretProviderConfig]
    public var defaults: SecretDefaultsConfig
    public var resolution: SecretResolutionConfig
    /// `secrets.egressProxy` (metadata only).
    public var egressProxy: SecretEgressProxyConfig?

    public init(
        providers: [String: SecretProviderConfig] = [:],
        defaults: SecretDefaultsConfig = SecretDefaultsConfig(),
        resolution: SecretResolutionConfig = SecretResolutionConfig(),
        egressProxy: SecretEgressProxyConfig? = nil
    ) {
        self.providers = providers
        self.defaults = defaults
        self.resolution = resolution
        self.egressProxy = egressProxy
    }

    private enum CodingKeys: String, CodingKey {
        case providers
        case defaults
        case resolution
        case egressProxy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A provider with an unknown source is dropped (and recorded as an issue) instead of failing the config.
        self.providers = container.decodeLossyDictionaryIfPresent(SecretProviderConfig.self, forKey: .providers) ?? [:]
        self.defaults = try container.decodeIfPresent(SecretDefaultsConfig.self, forKey: .defaults) ?? SecretDefaultsConfig()
        self.resolution = try container.decodeIfPresent(SecretResolutionConfig.self, forKey: .resolution) ?? SecretResolutionConfig()
        self.egressProxy = container.decodeLenient(SecretEgressProxyConfig.self, forKey: .egressProxy)
    }

    /// Encodes the config; the upstream projection omits the retired `resolution` block.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let projection = encoder.userInfo[.openClawUpstreamProjection] as? Bool == true
        if !(projection && self.providers.isEmpty) {
            try container.encode(self.providers, forKey: .providers)
        }
        try container.encode(self.defaults, forKey: .defaults)
        if !projection {
            try container.encode(self.resolution, forKey: .resolution)
        }
        try container.encodeIfPresent(self.egressProxy, forKey: .egressProxy)
    }

    /// Provider alias that resolves `ref`: an explicit alias wins; the implicit `default` alias
    /// falls back to `secrets.defaults.<source>` when no provider named `default` is configured for
    /// that source (upstream fills a missing provider from the defaults).
    /// - Parameter ref: Secret reference.
    /// - Returns: Provider alias to use.
    public func effectiveProviderAlias(for ref: SecretRef) -> String {
        let provider = ref.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.isEmpty || provider == DEFAULT_SECRET_PROVIDER_ALIAS else {
            return provider
        }
        if self.providers[DEFAULT_SECRET_PROVIDER_ALIAS]?.source == ref.source {
            return DEFAULT_SECRET_PROVIDER_ALIAS
        }
        return self.defaults.providerAlias(for: ref.source)
    }

    /// Validation problems across providers and the egress proxy (upstream schema bounds).
    /// - Returns: Human-readable problems keyed by config path.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        for (name, provider) in self.providers.sorted(by: { $0.key < $1.key }) {
            if !SecretPatterns.matches(SecretPatterns.providerAlias, value: name) {
                errors.append("secrets.providers.\(name): provider alias must match ^[a-z][a-z0-9_-]{0,63}$.")
            }
            switch provider {
            case .file(let file):
                errors.append(contentsOf: file.validationErrors().map { "secrets.providers.\(name): \($0)" })
            case .exec(let exec):
                errors.append(contentsOf: exec.validationErrors().map { "secrets.providers.\(name): \($0)" })
            case .env, .store:
                break
            }
        }
        if let proxy = self.egressProxy {
            if (proxy.allowedHosts?.count ?? 0) > 256 || (proxy.bypassHosts?.count ?? 0) > 256 {
                errors.append("secrets.egressProxy host lists must contain at most 256 entries.")
            }
        }
        return errors
    }

    public func defaultProviderAlias(for source: SecretRefSource) -> String {
        if source == .env {
            return self.defaults.providerAlias(for: .env)
        }
        for (providerName, providerConfig) in self.providers {
            if providerConfig.source == source {
                return providerName
            }
        }
        return self.defaults.providerAlias(for: source)
    }
}
