import Foundation
import OpenClawProtocol

extension OpenClawConfigDocument {
    /// `memory`: citations and memory search (the SDK's `runtime.memoryGraph` is SDK-only and unrelated).
    public struct Memory: ConfigDocumentObject {
        /// `auto`, `on` or `off`.
        public var citations: String?
        /// Memory search.
        public var search: MemorySearch?
        /// Passthrough keys (the retired `backend`/`qmd` until migrated).
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("citations", \.citations), .init("search", \.search)] }
    }

    /// Memory search settings (root `memory.search` and `agents.entries.*.memory.search`).
    public struct MemorySearch: ConfigDocumentObject {
        /// Enables memory search.
        public var enabled: Bool?
        /// Remember across conversations.
        public var rememberAcrossConversations: Bool?
        /// `memory` and/or `sessions`.
        public var sources: [String]?
        /// Extra paths (`path` strings or `{path, pattern}` objects).
        public var extraPaths: [AnyCodable]?
        /// Multimodal indexing.
        public var multimodal: AnyCodable?
        /// Experimental flags.
        public var experimental: AnyCodable?
        /// Embedding provider id.
        public var provider: String?
        /// Remote embedding endpoint.
        public var remote: Remote?
        /// Fallback provider.
        public var fallback: String?
        /// Embedding model.
        public var model: String?
        /// Input type.
        public var inputType: String?
        /// Query input type.
        public var queryInputType: String?
        /// Document input type.
        public var documentInputType: String?
        /// Output dimensionality.
        public var outputDimensionality: Int?
        /// Local model (`modelPath`).
        public var local: AnyCodable?
        /// Index store options.
        public var store: AnyCodable?
        /// Query options (`maxResults`, `minScore`).
        public var query: AnyCodable?
        /// Cache (`enabled`).
        public var cache: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates empty settings.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("enabled", \.enabled), .init("rememberAcrossConversations", \.rememberAcrossConversations),
                .init("sources", \.sources), .init("extraPaths", \.extraPaths), .init("multimodal", \.multimodal),
                .init("experimental", \.experimental), .init("provider", \.provider), .init("remote", \.remote),
                .init("fallback", \.fallback), .init("model", \.model), .init("inputType", \.inputType),
                .init("queryInputType", \.queryInputType), .init("documentInputType", \.documentInputType),
                .init("outputDimensionality", \.outputDimensionality), .init("local", \.local), .init("store", \.store),
                .init("query", \.query), .init("cache", \.cache),
            ]
        }

        /// Remote embedding endpoint.
        public struct Remote: ConfigDocumentObject {
            /// Endpoint base URL.
            public var baseUrl: String?
            /// API key (secret).
            public var apiKey: ConfigSecretValue?
            /// Extra headers.
            public var headers: [String: String]?
            /// Batch embedding (`enabled`).
            public var batch: AnyCodable?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty endpoint.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("baseUrl", \.baseUrl), .init("apiKey", \.apiKey), .init("headers", \.headers), .init("batch", \.batch)]
            }
        }
    }

    /// `skills`: skill loading, limits, workshop and entries.
    public struct Skills: ConfigDocumentObject {
        /// Bundled-skill allowlist.
        public var allowBundled: [String]?
        /// Loading (`extraDirs`, `allowSymlinkTargets`, `watch`).
        public var load: AnyCodable?
        /// Installer settings (server-only).
        public var install: AnyCodable?
        /// Limits.
        public var limits: Limits?
        /// Skill Workshop.
        public var workshop: AnyCodable?
        /// Per-skill entries.
        public var entries: [String: SkillEntry]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("allowBundled", \.allowBundled), .init("load", \.load), .init("install", \.install), .init("limits", \.limits),
             .init("workshop", \.workshop), .init("entries", \.entries)]
        }

        /// Whether `skillID` is enabled (entries with `enabled: false` are disabled).
        /// - Parameter skillID: Skill id.
        /// - Returns: `false` only when explicitly disabled.
        public func isSkillEnabled(_ skillID: String) -> Bool {
            self.entries?[skillID]?.enabled != false
        }

        /// `skills.limits`.
        public struct Limits: ConfigDocumentObject {
            /// Candidate directories per root.
            public var maxCandidatesPerRoot: Int?
            /// Skills loaded per source.
            public var maxSkillsLoadedPerSource: Int?
            /// Skills in the model-facing prompt.
            public var maxSkillsInPrompt: Int?
            /// Characters of the skills prompt block.
            public var maxSkillsPromptChars: Int?
            /// `SKILL.md` size cap.
            public var maxSkillFileBytes: Int?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates empty limits.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("maxCandidatesPerRoot", \.maxCandidatesPerRoot), .init("maxSkillsLoadedPerSource", \.maxSkillsLoadedPerSource),
                 .init("maxSkillsInPrompt", \.maxSkillsInPrompt), .init("maxSkillsPromptChars", \.maxSkillsPromptChars),
                 .init("maxSkillFileBytes", \.maxSkillFileBytes)]
            }
        }

        /// `skills.entries.<id>`.
        public struct SkillEntry: ConfigDocumentObject {
            /// Disable the skill without removing it.
            public var enabled: Bool?
            /// Skill API key (secret).
            public var apiKey: ConfigSecretValue?
            /// Environment overrides.
            public var env: [String: String]?
            /// Skill config.
            public var config: [String: AnyCodable]?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty entry.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("enabled", \.enabled), .init("apiKey", \.apiKey), .init("env", \.env), .init("config", \.config)]
            }
        }
    }

    /// `plugins`: plugin loading, slots and entries. Many provider, channel and web-search settings
    /// live under `plugins.entries.<id>.config`.
    public struct Plugins: ConfigDocumentObject {
        /// Enables plugin loading.
        public var enabled: Bool?
        /// Plugin allowlist.
        public var allow: [String]?
        /// Plugin denylist.
        public var deny: [String]?
        /// Extra load paths (server-only).
        public var load: AnyCodable?
        /// Slots (`memory`, `contextEngine`; `none` disables memory plugins).
        public var slots: AnyCodable?
        /// Per-plugin entries.
        public var entries: [String: PluginEntry]?
        /// Passthrough keys (the retired `installs` until the gateway imports it).
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("enabled", \.enabled), .init("allow", \.allow), .init("deny", \.deny), .init("load", \.load),
             .init("slots", \.slots), .init("entries", \.entries)]
        }

        /// `plugins.entries.<id>`.
        public struct PluginEntry: ConfigDocumentObject {
            /// Enables the plugin.
            public var enabled: Bool?
            /// Hook permissions and timeouts.
            public var hooks: AnyCodable?
            /// Subagent model override permissions.
            public var subagent: AnyCodable?
            /// LLM completion permissions.
            public var llm: AnyCodable?
            /// Plugin-owned config (opaque JSON).
            public var config: [String: AnyCodable]?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty entry.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("enabled", \.enabled), .init("hooks", \.hooks), .init("subagent", \.subagent), .init("llm", \.llm),
                 .init("config", \.config)]
            }
        }
    }

    /// `mcp`: MCP servers and MCP apps.
    public struct MCP: ConfigDocumentObject {
        /// Reserved server name (upstream rejects it).
        public static let reservedServerName = "__proto__"

        /// Idle session TTL in milliseconds.
        public var sessionIdleTtlMs: Double?
        /// Servers keyed by name.
        public var servers: [String: MCPServer]?
        /// MCP apps (`enabled`, `sandboxOrigin`, `sandboxPort`).
        public var apps: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("sessionIdleTtlMs", \.sessionIdleTtlMs), .init("servers", \.servers), .init("apps", \.apps)]
        }

        /// Enabled state per server (`servers.*.enabled`, default `true`), as the upstream iOS composer reads it.
        public var serverEnabledStates: [String: Bool] {
            (self.servers ?? [:]).mapValues { $0.enabled ?? true }
        }
    }

    /// One `mcp.servers.<name>` entry (catchall passthrough).
    public struct MCPServer: ConfigDocumentObject {
        /// Enables the server.
        public var enabled: Bool?
        /// stdio command.
        public var command: String?
        /// stdio arguments.
        public var args: [String]?
        /// stdio environment (string, number or boolean values).
        public var env: [String: AnyCodable]?
        /// Working directory (legacy `workingDirectory` is migrated).
        public var cwd: String?
        /// HTTP(S) URL.
        public var url: String?
        /// `stdio`, `sse` or `streamable-http`.
        public var transport: String?
        /// HTTP headers.
        public var headers: [String: AnyCodable]?
        /// Connection timeout in milliseconds.
        public var connectionTimeoutMs: Double?
        /// Request timeout in milliseconds.
        public var requestTimeoutMs: Double?
        /// Parallel tool calls.
        public var supportsParallelToolCalls: Bool?
        /// `oauth`.
        public var auth: String?
        /// OAuth settings.
        public var oauth: AnyCodable?
        /// TLS verification.
        public var sslVerify: Bool?
        /// Client certificate path.
        public var clientCert: String?
        /// Client key path.
        public var clientKey: String?
        /// Tool filter (`include`, `exclude`).
        public var toolFilter: AnyCodable?
        /// Codex-specific settings.
        public var codex: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty server.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("enabled", \.enabled), .init("command", \.command), .init("args", \.args), .init("env", \.env),
                .init("cwd", \.cwd), .init("url", \.url), .init("transport", \.transport), .init("headers", \.headers),
                .init("connectionTimeoutMs", \.connectionTimeoutMs), .init("requestTimeoutMs", \.requestTimeoutMs),
                .init("supportsParallelToolCalls", \.supportsParallelToolCalls), .init("auth", \.auth), .init("oauth", \.oauth),
                .init("sslVerify", \.sslVerify), .init("clientCert", \.clientCert), .init("clientKey", \.clientKey),
                .init("toolFilter", \.toolFilter), .init("codex", \.codex),
            ]
        }

        /// Canonical transport: explicit `transport`, else the CLI `type` alias (`http` → `streamable-http`),
        /// else `stdio` when a command is set and `streamable-http` when only a URL is set.
        public var canonicalTransport: String? {
            if let transport = ConfigValueSupport.nonEmpty(self.transport) {
                return ConfigMigrationRules.cliMCPTypeToTransport[transport.lowercased()] ?? transport
            }
            if let type = self.additionalProperties["type"]?.stringValue,
               let mapped = ConfigMigrationRules.cliMCPTypeToTransport[type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
            {
                return mapped
            }
            if ConfigValueSupport.nonEmpty(self.command) != nil {
                return "stdio"
            }
            if ConfigValueSupport.nonEmpty(self.url) != nil {
                return "streamable-http"
            }
            return nil
        }
    }
}
