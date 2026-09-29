import Foundation
import OpenClawProtocol

extension OpenClawConfigDocument {
    /// Tool-profile vocabulary (`minimal`, `coding`, `messaging`, `full`).
    public struct ToolProfile: ConfigOpenEnum {
        /// Raw config string.
        public let rawValue: String
        /// Creates a value from its raw string.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Minimal tools.
        public static let minimal = Self(rawValue: "minimal")
        /// Coding tools.
        public static let coding = Self(rawValue: "coding")
        /// Messaging tools.
        public static let messaging = Self(rawValue: "messaging")
        /// Every tool.
        public static let full = Self(rawValue: "full")
        /// Known values.
        public static let known: [Self] = [.minimal, .coding, .messaging, .full]
    }

    /// `profile`/`allow`/`alsoAllow`/`deny` tool policy (used by `byProvider`, sandbox and subagents).
    public struct ToolPolicy: ConfigDocumentObject {
        /// Tool profile.
        public var profile: ToolProfile?
        /// Allowed tools (replaces the profile's grants).
        public var allow: [String]?
        /// Extra tools on top of the profile.
        public var alsoAllow: [String]?
        /// Denied tools (deny wins).
        public var deny: [String]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty policy.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("profile", \.profile), .init("allow", \.allow), .init("alsoAllow", \.alsoAllow), .init("deny", \.deny)]
        }
    }

    /// `tools`: root tool policy and tool configuration (upstream `ToolsSchema`).
    public struct Tools: ConfigDocumentObject {
        /// Tool profile.
        public var profile: ToolProfile?
        /// Allowed tools.
        public var allow: [String]?
        /// Extra tools on top of the profile.
        public var alsoAllow: [String]?
        /// Denied tools.
        public var deny: [String]?
        /// Per-provider policy (`provider` or `provider/model`).
        public var byProvider: [String: ToolPolicy]?
        /// Per-sender policy.
        public var toolsBySender: [String: ToolPolicy]?
        /// Web search/fetch.
        public var web: Web?
        /// Managed GitHub identity.
        public var github: AnyCodable?
        /// Media understanding models (typed shallowly).
        public var media: Media?
        /// Link understanding.
        public var links: AnyCodable?
        /// Session tool visibility.
        public var sessions: Sessions?
        /// Loop detection.
        public var loopDetection: EnabledToggle?
        /// Tool search: `true`/`false` or settings.
        public var toolSearch: ConfigFlagOr<ToolSearch>?
        /// Code Mode: `true`/`false`/`"auto"` or settings.
        public var codeMode: ConfigCodeModeValue?
        /// Collector-mode subagents: `true`/`false` or settings.
        public var swarm: ConfigFlagOr<AnyCodable>?
        /// Message tool.
        public var message: MessageTool?
        /// Cross-agent session access.
        public var agentToAgent: AgentToAgent?
        /// Elevated mode.
        public var elevated: Elevated?
        /// Exec tool.
        public var exec: Exec?
        /// File-system tools (`workspaceOnly`).
        public var fs: AnyCodable?
        /// Subagent tool policy (`{tools: policy}`).
        public var subagents: AnyCodable?
        /// Sandbox tool policy (`{tools: policy}`).
        public var sandbox: AnyCodable?
        /// `sessions_spawn` attachments.
        public var sessionsSpawn: AnyCodable?
        /// Plan tool switch.
        public var updatePlan: Bool?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty tools section.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("profile", \.profile), .init("allow", \.allow), .init("alsoAllow", \.alsoAllow), .init("deny", \.deny),
                .init("byProvider", \.byProvider), .init("toolsBySender", \.toolsBySender), .init("web", \.web),
                .init("github", \.github), .init("media", \.media), .init("links", \.links), .init("sessions", \.sessions),
                .init("loopDetection", \.loopDetection), .init("toolSearch", \.toolSearch), .init("codeMode", \.codeMode),
                .init("swarm", \.swarm), .init("message", \.message), .init("agentToAgent", \.agentToAgent),
                .init("elevated", \.elevated), .init("exec", \.exec), .init("fs", \.fs), .init("subagents", \.subagents),
                .init("sandbox", \.sandbox), .init("sessions_spawn", \.sessionsSpawn), .init("updatePlan", \.updatePlan),
            ]
        }

        /// Whether web search is enabled (`tools.web.search.enabled`; upstream defaults to enabled).
        public var isWebSearchEnabled: Bool {
            self.web?.search?.enabled ?? true
        }

        /// The root scope's `profile`/`allow`/`alsoAllow`/`deny` policy.
        public var policy: ToolPolicy {
            var policy = ToolPolicy()
            policy.profile = self.profile
            policy.allow = self.allow
            policy.alsoAllow = self.alsoAllow
            policy.deny = self.deny
            return policy
        }
    }

    /// `agents.entries.*.tools`: per-agent tool policy.
    public struct AgentTools: ConfigDocumentObject {
        /// Tool profile.
        public var profile: ToolProfile?
        /// Allowed tools.
        public var allow: [String]?
        /// Extra tools.
        public var alsoAllow: [String]?
        /// Denied tools.
        public var deny: [String]?
        /// Per-provider policy.
        public var byProvider: [String: ToolPolicy]?
        /// Per-sender policy.
        public var toolsBySender: [String: ToolPolicy]?
        /// Code Mode.
        public var codeMode: ConfigCodeModeValue?
        /// Collector-mode subagents.
        public var swarm: ConfigFlagOr<AnyCodable>?
        /// Elevated mode.
        public var elevated: Elevated?
        /// Exec tool.
        public var exec: Exec?
        /// Managed GitHub identity.
        public var github: AnyCodable?
        /// File-system tools.
        public var fs: AnyCodable?
        /// Loop detection.
        public var loopDetection: EnabledToggle?
        /// Message tool.
        public var message: MessageTool?
        /// Sandbox tool policy.
        public var sandbox: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty policy.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("profile", \.profile), .init("allow", \.allow), .init("alsoAllow", \.alsoAllow), .init("deny", \.deny),
                .init("byProvider", \.byProvider), .init("toolsBySender", \.toolsBySender), .init("codeMode", \.codeMode),
                .init("swarm", \.swarm), .init("elevated", \.elevated), .init("exec", \.exec), .init("github", \.github),
                .init("fs", \.fs), .init("loopDetection", \.loopDetection), .init("message", \.message), .init("sandbox", \.sandbox),
            ]
        }

        /// The agent scope's `profile`/`allow`/`alsoAllow`/`deny` policy.
        public var policy: ToolPolicy {
            var policy = ToolPolicy()
            policy.profile = self.profile
            policy.allow = self.allow
            policy.alsoAllow = self.alsoAllow
            policy.deny = self.deny
            return policy
        }
    }

    /// `{enabled}` toggle.
    public struct EnabledToggle: ConfigDocumentObject {
        /// Enables the feature.
        public var enabled: Bool?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty toggle.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("enabled", \.enabled)] }
    }

    /// `tools.exec` (upstream exec schema).
    public struct Exec: ConfigDocumentObject {
        /// `auto`, `sandbox`, `gateway` or `node`.
        public var host: String?
        /// `deny`, `allowlist`, `ask`, `auto` or `full`.
        public var mode: String?
        /// Legacy `deny`, `allowlist` or `full` (never combined with `mode`).
        public var security: String?
        /// Legacy `off`, `on-miss` or `always` (never combined with `mode`).
        public var ask: String?
        /// Node id for `host = node`.
        public var node: String?
        /// Directories prepended to `PATH`.
        public var pathPrepend: [String]?
        /// Safe binaries.
        public var safeBins: [String]?
        /// Strict inline evaluation.
        public var strictInlineEval: Bool?
        /// Command highlighting.
        public var commandHighlighting: Bool?
        /// Grant expiry in days (1...3650).
        public var grantExpiryDays: Int?
        /// Trusted directories for safe binaries.
        public var safeBinTrustedDirs: [String]?
        /// Per-binary argument profiles.
        public var safeBinProfiles: AnyCodable?
        /// Auto-review reviewer model.
        public var reviewer: AnyCodable?
        /// Background threshold in milliseconds.
        public var backgroundMs: Int?
        /// Approval-running notice delay in milliseconds.
        public var approvalRunningNoticeMs: Int?
        /// Timeout in seconds (legacy `timeoutSec` is migrated).
        public var timeoutSeconds: Int?
        /// Cleanup delay in milliseconds.
        public var cleanupMs: Int?
        /// Notify on exit.
        public var notifyOnExit: Bool?
        /// Notify on empty successful exit.
        public var notifyOnExitEmptySuccess: Bool?
        /// `apply_patch` settings.
        public var applyPatch: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty exec section.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("host", \.host), .init("mode", \.mode), .init("security", \.security), .init("ask", \.ask),
                .init("node", \.node), .init("pathPrepend", \.pathPrepend), .init("safeBins", \.safeBins),
                .init("strictInlineEval", \.strictInlineEval), .init("commandHighlighting", \.commandHighlighting),
                .init("grantExpiryDays", \.grantExpiryDays), .init("safeBinTrustedDirs", \.safeBinTrustedDirs),
                .init("safeBinProfiles", \.safeBinProfiles), .init("reviewer", \.reviewer), .init("backgroundMs", \.backgroundMs),
                .init("approvalRunningNoticeMs", \.approvalRunningNoticeMs), .init("timeoutSeconds", \.timeoutSeconds),
                .init("cleanupMs", \.cleanupMs), .init("notifyOnExit", \.notifyOnExit),
                .init("notifyOnExitEmptySuccess", \.notifyOnExitEmptySuccess), .init("applyPatch", \.applyPatch),
            ]
        }

        /// The exec mode (case-insensitive, like upstream).
        public var execMode: ExecMode? {
            ExecMode.normalize(self.mode)
        }

        /// The exec host.
        public var execHost: ExecHost? {
            self.host.flatMap { ExecHost(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        }

        /// Effective security/ask policy: `mode` wins; otherwise the legacy pair with upstream defaults
        /// (`allowlist` / `on-miss`); `nil` when neither is set.
        public var effectivePolicy: ExecModePolicy? {
            if let mode = self.execMode {
                return mode.policy
            }
            let security = self.security.flatMap { ExecSecurity(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            let ask = self.ask.flatMap { ExecAsk(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            guard security != nil || ask != nil else {
                return nil
            }
            let resolvedSecurity = security ?? .allowlist
            let resolvedAsk = ask ?? .onMiss
            return ExecModePolicy(security: resolvedSecurity, ask: resolvedAsk, autoReview: false)
        }
    }

    /// `tools.web`.
    public struct Web: ConfigDocumentObject {
        /// Web search.
        public var search: Search?
        /// Web fetch.
        public var fetch: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("search", \.search), .init("fetch", \.fetch)] }

        /// `tools.web.search` (provider-specific keys pass through; legacy provider objects are issues).
        public struct Search: ConfigDocumentObject {
            /// Enables web search.
            public var enabled: Bool?
            /// Search provider id.
            public var provider: String?
            /// Maximum results.
            public var maxResults: Int?
            /// Timeout in seconds.
            public var timeoutSeconds: Int?
            /// Cache TTL in minutes.
            public var cacheTtlMinutes: Int?
            /// OpenAI Codex native search.
            public var openaiCodex: AnyCodable?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty section.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("enabled", \.enabled), .init("provider", \.provider), .init("maxResults", \.maxResults),
                 .init("timeoutSeconds", \.timeoutSeconds), .init("cacheTtlMinutes", \.cacheTtlMinutes),
                 .init("openaiCodex", \.openaiCodex)]
            }
        }
    }

    /// `tools.media` (typed shallowly; nested runtime fields pass through).
    public struct Media: ConfigDocumentObject {
        /// Capability-tagged media models.
        public var models: [MediaModel]?
        /// Concurrency.
        public var concurrency: Int?
        /// Image capability block.
        public var image: AnyCodable?
        /// Audio capability block.
        public var audio: AnyCodable?
        /// Video capability block.
        public var video: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("models", \.models), .init("concurrency", \.concurrency), .init("image", \.image), .init("audio", \.audio),
             .init("video", \.video)]
        }

        /// One `tools.media.models[]` entry.
        public struct MediaModel: ConfigDocumentObject {
            /// Provider id.
            public var provider: String?
            /// Model id.
            public var model: String?
            /// `image`, `audio` and/or `video`.
            public var capabilities: [String]?
            /// `provider` or `cli`.
            public var type: String?
            /// CLI command.
            public var command: String?
            /// CLI arguments.
            public var args: [String]?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty entry.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("provider", \.provider), .init("model", \.model), .init("capabilities", \.capabilities),
                 .init("type", \.type), .init("command", \.command), .init("args", \.args)]
            }
        }
    }

    /// `tools.sessions`.
    public struct Sessions: ConfigDocumentObject {
        /// `self`, `tree`, `agent` or `all` (default `all`).
        public var visibility: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("visibility", \.visibility)] }
    }

    /// `tools.toolSearch` settings.
    public struct ToolSearch: ConfigDocumentObject {
        /// Enables tool search.
        public var enabled: Bool?
        /// `code`, `tools` or `directory`.
        public var mode: String?
        /// Passthrough keys (limits).
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("enabled", \.enabled), .init("mode", \.mode)] }
    }

    /// `tools.codeMode` settings object.
    public struct CodeMode: ConfigDocumentObject {
        /// `true`, `false` or `"auto"`.
        public var enabled: ConfigBoolOrAuto?
        /// `node` or `quickjs`.
        public var executor: String?
        /// `only`.
        public var mode: String?
        /// Timeout in milliseconds.
        public var timeoutMs: Int?
        /// Passthrough keys (limits).
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("enabled", \.enabled), .init("executor", \.executor), .init("mode", \.mode), .init("timeoutMs", \.timeoutMs)]
        }
    }

    /// `tools.message`.
    public struct MessageTool: ConfigDocumentObject {
        /// Cross-context send policy.
        public var crossContext: AnyCodable?
        /// Allowed actions.
        public var actions: AnyCodable?
        /// Broadcast.
        public var broadcast: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("crossContext", \.crossContext), .init("actions", \.actions), .init("broadcast", \.broadcast)]
        }
    }

    /// `tools.agentToAgent`.
    public struct AgentToAgent: ConfigDocumentObject {
        /// Enables cross-agent session tools (default `true`).
        public var enabled: Bool?
        /// Agent id globs; requester and target must both match.
        public var allow: [String]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("enabled", \.enabled), .init("allow", \.allow)] }
    }

    /// `tools.elevated`.
    public struct Elevated: ConfigDocumentObject {
        /// Enables elevated mode (default `true`).
        public var enabled: Bool?
        /// Allowed senders per channel.
        public var allowFrom: [String: [ConfigStringOrNumber]]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("enabled", \.enabled), .init("allowFrom", \.allowFrom)] }
    }
}

/// `Bool | "auto" | object` Code Mode value (`tools.codeMode`).
public enum ConfigCodeModeValue: Codable, Sendable, Equatable {
    /// Boolean shorthand.
    case flag(Bool)
    /// `"auto"` shorthand.
    case auto
    /// Detailed settings.
    case settings(OpenClawConfigDocument.CodeMode)

    /// Whether Code Mode is enabled: flags map directly, `auto` and settings without `enabled`
    /// return `nil` (runtime decides).
    public var isEnabled: Bool? {
        switch self {
        case .flag(let flag):
            return flag
        case .auto:
            return nil
        case .settings(let settings):
            return settings.enabled?.boolValue
        }
    }

    /// Decodes a boolean, `"auto"` or a settings object.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else if let string = try? container.decode(String.self) {
            guard string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auto" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected true, false, \"auto\" or an object.")
            }
            self = .auto
        } else {
            self = .settings(try container.decode(OpenClawConfigDocument.CodeMode.self))
        }
    }

    /// Encodes the original form.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .flag(let flag):
            try container.encode(flag)
        case .auto:
            try container.encode("auto")
        case .settings(let settings):
            try container.encode(settings)
        }
    }
}
