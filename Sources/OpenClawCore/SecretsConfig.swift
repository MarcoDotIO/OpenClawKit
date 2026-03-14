import Foundation

public let DEFAULT_SECRET_PROVIDER_ALIAS = "default"
public let SINGLE_VALUE_FILE_SECRET_REF_ID = "value"

private enum SecretPatterns {
    static let envID = try! NSRegularExpression(pattern: "^[A-Z][A-Z0-9_]{0,127}$")
    static let envTemplate = try! NSRegularExpression(pattern: #"^\$\{([A-Z][A-Z0-9_]{0,127})\}$"#)
    static let providerAlias = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_-]{0,63}$")
    static let execID = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$")

    static func matches(_ regex: NSRegularExpression, value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else {
            return false
        }
        return match.range.location != NSNotFound && match.range.length == range.length
    }

    static func envTemplateRef(_ value: String, provider: String = DEFAULT_SECRET_PROVIDER_ALIAS) -> SecretRef? {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = self.envTemplate.firstMatch(in: value, range: range),
              match.numberOfRanges == 2,
              let idRange = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return SecretRef(source: .env, provider: provider, id: String(value[idRange]))
    }
}

/// Secret source kinds supported by OpenClaw parity config.
public enum SecretRefSource: String, Codable, Sendable, Equatable, CaseIterable {
    case env
    case file
    case exec
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
        case .file:
            guard Self.isValidFileSecretRefID(normalized.id) else {
                return #"File SecretRef ids must be "value" or a JSON pointer like "/providers/openai/apiKey"."#
            }
        case .exec:
            guard SecretPatterns.matches(SecretPatterns.execID, value: normalized.id) else {
                return "Exec SecretRef ids must match ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$."
            }
            for segment in normalized.id.split(separator: "/", omittingEmptySubsequences: false) {
                if segment == "." || segment == ".." {
                    return #"Exec SecretRef ids must not include "." or ".." path segments."#
                }
            }
        }
        return nil
    }

    public static func parseEnvTemplate(
        _ value: String,
        provider: String = DEFAULT_SECRET_PROVIDER_ALIAS
    ) -> SecretRef? {
        SecretPatterns.envTemplateRef(
            value.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider
        )
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            if let envRef = SecretRef.parseEnvTemplate(stringValue) {
                self = .ref(envRef)
            } else {
                self = .string(stringValue)
            }
            return
        }
        self = .ref(try container.decode(SecretRef.self))
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
}

public struct ExecSecretProviderConfig: Codable, Sendable, Equatable {
    public var source: SecretRefSource
    public var command: String
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
        allowSymlinkCommand: Bool = false
    ) {
        self.source = source
        self.command = command
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

    private enum CodingKeys: String, CodingKey {
        case source
        case command
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 5_000
        self.init(
            source: try container.decodeIfPresent(SecretRefSource.self, forKey: .source) ?? .exec,
            command: try container.decode(String.self, forKey: .command),
            args: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
            timeoutMs: timeoutMs,
            noOutputTimeoutMs: try container.decodeIfPresent(Int.self, forKey: .noOutputTimeoutMs) ?? timeoutMs,
            maxOutputBytes: try container.decodeIfPresent(Int.self, forKey: .maxOutputBytes) ?? 1_048_576,
            jsonOnly: try container.decodeIfPresent(Bool.self, forKey: .jsonOnly) ?? true,
            env: try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
            passEnv: try container.decodeIfPresent([String].self, forKey: .passEnv) ?? [],
            trustedDirs: try container.decodeIfPresent([String].self, forKey: .trustedDirs) ?? [],
            allowInsecurePath: try container.decodeIfPresent(Bool.self, forKey: .allowInsecurePath) ?? false,
            allowSymlinkCommand: try container.decodeIfPresent(Bool.self, forKey: .allowSymlinkCommand) ?? false
        )
    }
}

public enum SecretProviderConfig: Codable, Sendable, Equatable {
    case env(EnvSecretProviderConfig)
    case file(FileSecretProviderConfig)
    case exec(ExecSecretProviderConfig)

    public var source: SecretRefSource {
        switch self {
        case .env(let config):
            return config.source
        case .file(let config):
            return config.source
        case .exec(let config):
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
        }
    }
}

public struct SecretDefaultsConfig: Codable, Sendable, Equatable {
    public var env: String
    public var file: String?
    public var exec: String?

    public init(
        env: String = DEFAULT_SECRET_PROVIDER_ALIAS,
        file: String? = nil,
        exec: String? = nil
    ) {
        self.env = env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DEFAULT_SECRET_PROVIDER_ALIAS : env.trimmingCharacters(in: .whitespacesAndNewlines)
        self.file = file?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.exec = exec?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func providerAlias(for source: SecretRefSource) -> String {
        switch source {
        case .env:
            return self.env
        case .file:
            return self.file?.isEmpty == false ? self.file! : DEFAULT_SECRET_PROVIDER_ALIAS
        case .exec:
            return self.exec?.isEmpty == false ? self.exec! : DEFAULT_SECRET_PROVIDER_ALIAS
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

/// Canonical top-level secrets config aligned with OpenClaw secret-provider docs.
public struct SecretsConfig: Codable, Sendable, Equatable {
    public var providers: [String: SecretProviderConfig]
    public var defaults: SecretDefaultsConfig
    public var resolution: SecretResolutionConfig

    public init(
        providers: [String: SecretProviderConfig] = [:],
        defaults: SecretDefaultsConfig = SecretDefaultsConfig(),
        resolution: SecretResolutionConfig = SecretResolutionConfig()
    ) {
        self.providers = providers
        self.defaults = defaults
        self.resolution = resolution
    }

    private enum CodingKeys: String, CodingKey {
        case providers
        case defaults
        case resolution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.providers = try container.decodeIfPresent([String: SecretProviderConfig].self, forKey: .providers) ?? [:]
        self.defaults = try container.decodeIfPresent(SecretDefaultsConfig.self, forKey: .defaults) ?? SecretDefaultsConfig()
        self.resolution = try container.decodeIfPresent(SecretResolutionConfig.self, forKey: .resolution) ?? SecretResolutionConfig()
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
