import Foundation
import OpenClawProtocol

/// A secret-bearing config value that keeps its authored form (plaintext string, `${NAME}` /
/// `$NAME` shorthand, or `{source, provider, id}` object) so documents round-trip unchanged.
public struct ConfigSecretValue: Codable, Sendable, Equatable {
    /// Authored JSON value (string or SecretRef object).
    public var raw: AnyCodable

    /// Creates a value from an SDK ``SecretInput`` (strings stay strings, refs become objects).
    /// - Parameter input: Secret input.
    public init(_ input: SecretInput) {
        switch input {
        case .string(let value):
            self.raw = AnyCodable(.string(value))
        case .ref(let ref):
            self.raw = ConfigTreeCoding.encode(ref)
        }
    }

    /// Creates a plaintext (or shorthand) string value.
    /// - Parameter string: Authored string.
    public init(string: String) {
        self.raw = AnyCodable(.string(string))
    }

    /// The value as an SDK ``SecretInput`` (shorthands and retired markers become env refs).
    public var input: SecretInput? {
        if let string = self.raw.stringValue {
            return SecretInput.parse(string).input
        }
        if let object = self.raw.dictionaryValue {
            return (try? ConfigTreeCoding.decode(SecretRef.self, from: AnyCodable(.object(object)), issues: nil)).map(SecretInput.ref)
        }
        return nil
    }

    /// The structured reference, when the value is a ref or an env shorthand.
    public var ref: SecretRef? {
        self.input?.refValue
    }

    /// The plaintext secret, when the value is a literal string (not a shorthand or marker).
    public var plaintext: String? {
        guard case .string(let value)? = self.input else { return nil }
        return value
    }

    /// Whether the value is a `config.get` redaction marker.
    public var isRedacted: Bool {
        ConfigRedaction.isRedactedSecretValue(self.raw)
    }

    /// Decodes a string or an object.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let value = try AnyCodable(from: decoder)
        switch value.value {
        case .string, .object:
            self.raw = value
            if let string = value.stringValue, SecretRef.isLegacyEnvMarker(string) {
                ConfigDecodeIssueReporting.record(
                    "Retired env marker \"\(string)\"; upstream accepts only {source, provider, id} refs or ${NAME}.",
                    kind: .legacyKey,
                    decoder: decoder
                )
            }
        default:
            throw DecodingError.typeMismatch(
                ConfigSecretValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a secret string or SecretRef object.")
            )
        }
    }

    /// Encodes the authored form.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        try self.raw.encode(to: encoder)
    }
}

extension OpenClawConfigDocument {
    /// `secrets`: secret providers, defaults and the egress proxy.
    public struct Secrets: ConfigDocumentObject {
        /// `secrets.providers`: named providers.
        public var providers: [String: SecretProvider]?
        /// `secrets.defaults`: provider alias per source.
        public var defaults: Defaults?
        /// `secrets.egressProxy` (server-side behavior; metadata only).
        public var egressProxy: SecretEgressProxyConfig?
        /// Passthrough keys (the retired `resolution` lands here until migrated).
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty secrets section.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("providers", \.providers), .init("defaults", \.defaults), .init("egressProxy", \.egressProxy)]
        }

        /// The SDK-native view (providers that fail SDK validation are dropped).
        public var sdkConfig: SecretsConfig {
            (try? ConfigTreeCoding.decode(SecretsConfig.self, from: AnyCodable(.object(self.jsonObject)), issues: nil)) ?? SecretsConfig()
        }

        /// `secrets.defaults`.
        public struct Defaults: ConfigDocumentObject {
            /// Default env provider alias.
            public var env: String?
            /// Default file provider alias.
            public var file: String?
            /// Default exec provider alias.
            public var exec: String?
            /// Default store provider alias.
            public var store: String?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]

            /// Creates empty defaults.
            public init() {}

            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("env", \.env), .init("file", \.file), .init("exec", \.exec), .init("store", \.store)]
            }
        }

        /// One `secrets.providers.<alias>` entry (every source's fields; unused ones stay `nil`).
        public struct SecretProvider: ConfigDocumentObject {
            /// `env`, `file`, `exec` or `store`.
            public var source: String?
            /// env: allowed variable names.
            public var allowlist: [String]?
            /// file: path of the secrets file.
            public var path: String?
            /// file: `singleValue` or `json`.
            public var mode: String?
            /// file/exec: timeout in milliseconds (≤ 120000).
            public var timeoutMs: Int?
            /// file: maximum bytes read (≤ 20 MiB).
            public var maxBytes: Int?
            /// exec: absolute command path (manual form).
            public var command: String?
            /// exec: command arguments.
            public var args: [String]?
            /// exec: no-output timeout in milliseconds.
            public var noOutputTimeoutMs: Int?
            /// exec: maximum output bytes (≤ 20 MiB).
            public var maxOutputBytes: Int?
            /// exec: require a JSON response.
            public var jsonOnly: Bool?
            /// exec: environment for the command.
            public var env: [String: String]?
            /// exec: environment variables passed through.
            public var passEnv: [String]?
            /// exec: trusted command directories.
            public var trustedDirs: [String]?
            /// exec: plugin-owned integration form.
            public var pluginIntegration: ExecSecretPluginIntegration?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]

            /// Creates an empty provider.
            public init() {}

            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [
                    .init("source", \.source), .init("allowlist", \.allowlist), .init("path", \.path), .init("mode", \.mode),
                    .init("timeoutMs", \.timeoutMs), .init("maxBytes", \.maxBytes), .init("command", \.command),
                    .init("args", \.args), .init("noOutputTimeoutMs", \.noOutputTimeoutMs),
                    .init("maxOutputBytes", \.maxOutputBytes), .init("jsonOnly", \.jsonOnly), .init("env", \.env),
                    .init("passEnv", \.passEnv), .init("trustedDirs", \.trustedDirs), .init("pluginIntegration", \.pluginIntegration),
                ]
            }

            /// The SDK-native provider config, when the entry is valid for its source.
            public var sdkConfig: SecretProviderConfig? {
                try? ConfigTreeCoding.decode(SecretProviderConfig.self, from: AnyCodable(.object(self.jsonObject)), issues: nil)
            }
        }
    }

    /// `auth`: auth-profile metadata. Credentials live in the gateway's auth stores; `auth.cooldowns`
    /// is retired upstream (SDK-local only, see ``AuthConfig``).
    public struct Auth: ConfigDocumentObject {
        /// `auth.profiles`: profile metadata by profile id.
        public var profiles: [String: Profile]?
        /// `auth.order`: preferred profile order per provider id.
        public var order: [String: [String]]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty auth section.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("profiles", \.profiles), .init("order", \.order)]
        }

        /// One `auth.profiles.<id>` entry.
        public struct Profile: ConfigDocumentObject {
            /// Provider id (required upstream).
            public var provider: String?
            /// Credential mode (required upstream).
            public var mode: Mode?
            /// Account email.
            public var email: String?
            /// Display name.
            public var displayName: String?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]

            /// Creates an empty profile.
            public init() {}

            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("provider", \.provider), .init("mode", \.mode), .init("email", \.email), .init("displayName", \.displayName)]
            }

            /// `auth.profiles.*.mode` vocabulary.
            public struct Mode: ConfigOpenEnum {
                /// Raw config string.
                public let rawValue: String
                /// Creates a value from its raw string.
                public init(rawValue: String) { self.rawValue = rawValue }
                /// API key.
                public static let apiKey = Self(rawValue: "api_key")
                /// AWS SDK default credential chain (no stored secret).
                public static let awsSDK = Self(rawValue: "aws-sdk")
                /// OAuth.
                public static let oauth = Self(rawValue: "oauth")
                /// Static token.
                public static let token = Self(rawValue: "token")
                /// Known values.
                public static let known: [Self] = [.apiKey, .awsSDK, .oauth, .token]
            }
        }
    }
}
