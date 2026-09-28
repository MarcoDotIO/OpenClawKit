import Foundation
import OpenClawProtocol

extension OpenClawConfigDocument {
    /// Think-level vocabulary (`off` … `ultra`); decoding lowercases like upstream `normalizeThinkLevel`.
    public struct ThinkLevelValue: ConfigOpenEnum {
        /// Raw config string.
        public let rawValue: String
        /// Creates a value from its raw string.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Upstream lowercases think levels.
        public static var normalizesToLowercase: Bool { true }
        /// Every level upstream accepts (`ALL_THINKING_LEVELS`).
        public static let known: [Self] = ThinkLevel.allCases.map { Self(rawValue: $0.rawValue) }
        /// The SDK think level (aliases such as `none` normalize to `off`).
        public var thinkLevel: ThinkLevel? { ThinkLevel.normalize(self.rawValue) }
        /// Creates a value from an SDK think level.
        /// - Parameter level: Think level.
        public init(_ level: ThinkLevel) { self.rawValue = level.rawValue }
    }

    /// `agents`: roster and defaults (upstream `AgentsSchema`).
    ///
    /// Map order is not preserved by Swift dictionaries; ``entryOrder`` records the authored order
    /// when the document was parsed from text (or converted from the legacy ordered `agents.list`).
    public struct Agents: ConfigDocumentObject {
        /// `explicit` ownership (required for multi-agent rosters without a legacy `default` marker).
        public var ownership: String?
        /// Defaults inherited by every agent.
        public var defaults: AgentDefaults?
        /// Agents keyed by id (`^[a-z0-9_][a-z0-9_-]{0,63}$`, case-insensitive).
        public var entries: [String: AgentEntry]?
        /// Passthrough keys (the legacy `list` lands here when migration is disabled).
        public var additionalProperties: [String: AnyCodable] = [:]
        private var entryOrderHint = ConfigOrderHint()

        /// Creates an empty agents section.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("ownership", \.ownership), .init("defaults", \.defaults), .init("entries", \.entries)]
        }

        /// Entry ids in authored order (unrecorded ids follow alphabetically).
        public var entryOrder: [String] {
            get { self.entryOrderHint.ordered(self.entries.map { Array($0.keys) } ?? []) }
            set { self.entryOrderHint = ConfigOrderHint(newValue) }
        }

        /// Entry ids in ``entryOrder``.
        public var agentIDs: [String] {
            self.entryOrder
        }

        /// Default agent id: the legacy `default: true` marker, else the sole entry, else `nil`.
        ///
        /// Upstream throws `AgentSelectionRequiredError` for multi-agent rosters with explicit ownership;
        /// the SDK returns `nil` and leaves the choice to the caller (see ``agentIDs``).
        public var resolvedDefaultAgentID: String? {
            guard let entries, !entries.isEmpty else {
                return nil
            }
            let marked = self.entryOrder.filter { entries[$0]?.default == true }
            if self.ownership != "explicit", marked.count == 1 {
                return OpenClawConfigDocument.normalizeAgentID(marked[0])
            }
            if entries.count == 1, let only = entries.keys.first {
                return OpenClawConfigDocument.normalizeAgentID(only)
            }
            return nil
        }

        /// The entry whose normalized id matches `id`.
        /// - Parameter id: Agent id (any casing).
        /// - Returns: The entry and its authored key.
        public func entry(for id: String) -> (key: String, entry: AgentEntry)? {
            let normalized = OpenClawConfigDocument.normalizeAgentID(id)
            for key in self.entryOrder where OpenClawConfigDocument.normalizeAgentID(key) == normalized {
                if let entry = self.entries?[key] {
                    return (key, entry)
                }
            }
            return nil
        }
    }

    /// `agents.entries.<id>` (upstream `AgentEntrySchema` without `id`, plus the legacy `default` marker).
    public struct AgentEntry: ConfigDocumentObject {
        /// Display name.
        public var name: String?
        /// Description.
        public var description: String?
        /// Workspace directory.
        public var workspace: String?
        /// Working directory.
        public var cwd: String?
        /// Agent state directory.
        public var agentDir: String?
        /// Primary model and fallbacks.
        public var model: ConfigModelSelection?
        /// Utility model (`provider/model`).
        public var utilityModel: String?
        /// Decision model (`provider/model`; empty string disables it).
        public var decisionModel: String?
        /// Per-model runtime settings keyed by `provider/model`.
        public var models: [String: ModelRuntimeEntry]?
        /// Model allowlist.
        public var modelPolicy: ModelPolicy?
        /// Default think level.
        public var thinkingDefault: ThinkLevelValue?
        /// `off`, `on` or `full`.
        public var verboseDefault: String?
        /// `explain` or `raw`.
        public var toolProgressDetail: String?
        /// `on`, `off` or `stream`.
        public var reasoningDefault: String?
        /// `true`, `false` or `"auto"`.
        public var fastModeDefault: ConfigBoolOrAuto?
        /// `always`, `continuation-skip` or `never`.
        public var contextInjection: String?
        /// Bootstrap file size cap.
        public var bootstrapMaxChars: Int?
        /// Bootstrap total size cap.
        public var bootstrapTotalMaxChars: Int?
        /// Experimental flags (`localModelLean`).
        public var experimental: AnyCodable?
        /// Skill allowlist.
        public var skills: [String]?
        /// Subagent delegation.
        public var subagents: Subagents?
        /// Embedded agent execution contract.
        public var embeddedAgent: AnyCodable?
        /// Provider parameters.
        public var params: [String: AnyCodable]?
        /// `{type: "embedded"}` or `{type: "acp", acp{…}}`.
        public var runtime: AnyCodable?
        /// Per-agent memory search.
        public var memory: AgentMemory?
        /// Human-like reply delay.
        public var humanDelay: AnyCodable?
        /// `never`, `instant`, `thinking` or `message`.
        public var typingMode: String?
        /// Per-agent TTS (adds `prefsPath`).
        public var tts: TTS?
        /// Skill prompt limits.
        public var skillsLimits: AnyCodable?
        /// Context limits.
        public var contextLimits: AnyCodable?
        /// Heartbeat.
        public var heartbeat: Heartbeat?
        /// Outbound identity.
        public var identity: Identity?
        /// Group-chat behavior (no `visibleReplies` at agent level).
        public var groupChat: AnyCodable?
        /// Sandbox.
        public var sandbox: Sandbox?
        /// Per-agent tool policy.
        public var tools: AgentTools?
        /// Legacy default marker (decode-only; upstream rejects it with explicit ownership).
        public var `default`: Bool?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty entry.
        public init() {}

        /// Typed fields in upstream order.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("name", \.name), .init("description", \.description), .init("workspace", \.workspace), .init("cwd", \.cwd),
                .init("agentDir", \.agentDir), .init("model", \.model), .init("utilityModel", \.utilityModel),
                .init("decisionModel", \.decisionModel), .init("models", \.models), .init("modelPolicy", \.modelPolicy),
                .init("thinkingDefault", \.thinkingDefault), .init("verboseDefault", \.verboseDefault),
                .init("toolProgressDetail", \.toolProgressDetail), .init("reasoningDefault", \.reasoningDefault),
                .init("fastModeDefault", \.fastModeDefault), .init("contextInjection", \.contextInjection),
                .init("bootstrapMaxChars", \.bootstrapMaxChars), .init("bootstrapTotalMaxChars", \.bootstrapTotalMaxChars),
                .init("experimental", \.experimental), .init("skills", \.skills), .init("subagents", \.subagents),
                .init("embeddedAgent", \.embeddedAgent), .init("params", \.params), .init("runtime", \.runtime),
                .init("memory", \.memory), .init("humanDelay", \.humanDelay), .init("typingMode", \.typingMode), .init("tts", \.tts),
                .init("skillsLimits", \.skillsLimits), .init("contextLimits", \.contextLimits), .init("heartbeat", \.heartbeat),
                .init("identity", \.identity), .init("groupChat", \.groupChat), .init("sandbox", \.sandbox), .init("tools", \.tools),
                .init("default", \.default),
            ]
        }
    }

    /// `agents.defaults` (upstream `AgentDefaultsSchema`); server-only tuning blocks pass through.
    public struct AgentDefaults: ConfigDocumentObject {
        /// Provider parameters.
        public var params: [String: AnyCodable]?
        /// Primary model and fallbacks.
        public var model: ConfigModelSelection?
        /// `session`, `agent` or `global`.
        public var modelSelectionScope: String?
        /// Utility model.
        public var utilityModel: String?
        /// Decision model.
        public var decisionModel: String?
        /// Image model.
        public var imageModel: ConfigToolModelSelection?
        /// Media generation models (`image`, `video`, `music`).
        public var mediaModels: [String: ConfigToolModelSelection]?
        /// Voice model.
        public var voiceModel: ConfigToolModelSelection?
        /// PDF model.
        public var pdfModel: ConfigToolModelSelection?
        /// PDF size cap in MB.
        public var pdfMaxMb: Double?
        /// PDF page cap.
        public var pdfMaxPages: Int?
        /// Per-model runtime settings.
        public var models: [String: ModelRuntimeEntry]?
        /// Model allowlist.
        public var modelPolicy: ModelPolicy?
        /// Default workspace.
        public var workspace: String?
        /// Default working directory.
        public var cwd: String?
        /// Skill allowlist.
        public var skills: [String]?
        /// Silent-reply policy.
        public var silentReply: SilentReplyPolicy?
        /// Repository root.
        public var repoRoot: String?
        /// Skip bootstrap files.
        public var skipBootstrap: Bool?
        /// Optional bootstrap files to skip.
        public var skipOptionalBootstrapFiles: [String]?
        /// Context injection mode.
        public var contextInjection: String?
        /// Bootstrap file size cap.
        public var bootstrapMaxChars: Int?
        /// Bootstrap total size cap.
        public var bootstrapTotalMaxChars: Int?
        /// Experimental flags.
        public var experimental: AnyCodable?
        /// User time zone.
        public var userTimezone: String?
        /// Startup context.
        public var startupContext: AnyCodable?
        /// Context pruning.
        public var contextPruning: AnyCodable?
        /// Compaction (typed subset; see ``Compaction``).
        public var compaction: Compaction?
        /// Embedded agent defaults.
        public var embeddedAgent: AnyCodable?
        /// Default think level.
        public var thinkingDefault: ThinkLevelValue?
        /// `true`, `false` or `"auto"`.
        public var fastModeDefault: ConfigBoolOrAuto?
        /// `off`, `on` or `full`.
        public var verboseDefault: String?
        /// `explain` or `raw`.
        public var toolProgressDetail: String?
        /// `on`, `off` or `stream`.
        public var reasoningDefault: String?
        /// `off`, `on`, `ask` or `full`.
        public var elevatedDefault: String?
        /// `off` or `on`.
        public var blockStreamingDefault: String?
        /// `text_end` or `message_end`.
        public var blockStreamingBreak: String?
        /// Run timeout in seconds.
        public var timeoutSeconds: Int?
        /// Media size cap in MB.
        public var mediaMaxMb: Double?
        /// Image max dimension in pixels.
        public var imageMaxDimensionPx: Int?
        /// `auto`, `efficient`, `balanced` or `high`.
        public var imageQuality: String?
        /// Typing indicator interval.
        public var typingIntervalSeconds: Int?
        /// System agent owner.
        public var systemAgent: AgentReference?
        /// Auth inheritance owner.
        public var authInheritance: AgentReference?
        /// Session store owner.
        public var sessionStore: AgentReference?
        /// Maximum concurrent runs.
        public var maxConcurrent: Int?
        /// Subagent defaults.
        public var subagents: Subagents?
        /// Context limits.
        public var contextLimits: AnyCodable?
        /// Block streaming chunking.
        public var blockStreamingChunk: AnyCodable?
        /// Block streaming coalescing.
        public var blockStreamingCoalesce: AnyCodable?
        /// Human-like reply delay.
        public var humanDelay: AnyCodable?
        /// Typing mode.
        public var typingMode: String?
        /// Heartbeat.
        public var heartbeat: Heartbeat?
        /// Sandbox.
        public var sandbox: Sandbox?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates empty defaults.
        public init() {}

        /// Typed fields in upstream order.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("params", \.params), .init("model", \.model), .init("modelSelectionScope", \.modelSelectionScope),
                .init("utilityModel", \.utilityModel), .init("decisionModel", \.decisionModel), .init("imageModel", \.imageModel),
                .init("mediaModels", \.mediaModels), .init("voiceModel", \.voiceModel), .init("pdfModel", \.pdfModel),
                .init("pdfMaxMb", \.pdfMaxMb), .init("pdfMaxPages", \.pdfMaxPages), .init("models", \.models),
                .init("modelPolicy", \.modelPolicy), .init("workspace", \.workspace), .init("cwd", \.cwd), .init("skills", \.skills),
                .init("silentReply", \.silentReply), .init("repoRoot", \.repoRoot), .init("skipBootstrap", \.skipBootstrap),
                .init("skipOptionalBootstrapFiles", \.skipOptionalBootstrapFiles), .init("contextInjection", \.contextInjection),
                .init("bootstrapMaxChars", \.bootstrapMaxChars), .init("bootstrapTotalMaxChars", \.bootstrapTotalMaxChars),
                .init("experimental", \.experimental), .init("userTimezone", \.userTimezone), .init("startupContext", \.startupContext),
                .init("contextPruning", \.contextPruning), .init("compaction", \.compaction), .init("embeddedAgent", \.embeddedAgent),
                .init("thinkingDefault", \.thinkingDefault), .init("fastModeDefault", \.fastModeDefault),
                .init("verboseDefault", \.verboseDefault), .init("toolProgressDetail", \.toolProgressDetail),
                .init("reasoningDefault", \.reasoningDefault), .init("elevatedDefault", \.elevatedDefault),
                .init("blockStreamingDefault", \.blockStreamingDefault), .init("blockStreamingBreak", \.blockStreamingBreak),
                .init("timeoutSeconds", \.timeoutSeconds), .init("mediaMaxMb", \.mediaMaxMb),
                .init("imageMaxDimensionPx", \.imageMaxDimensionPx), .init("imageQuality", \.imageQuality),
                .init("typingIntervalSeconds", \.typingIntervalSeconds), .init("systemAgent", \.systemAgent),
                .init("authInheritance", \.authInheritance), .init("sessionStore", \.sessionStore),
                .init("maxConcurrent", \.maxConcurrent), .init("subagents", \.subagents), .init("contextLimits", \.contextLimits),
                .init("blockStreamingChunk", \.blockStreamingChunk), .init("blockStreamingCoalesce", \.blockStreamingCoalesce),
                .init("humanDelay", \.humanDelay), .init("typingMode", \.typingMode), .init("heartbeat", \.heartbeat),
                .init("sandbox", \.sandbox),
            ]
        }
    }

    /// `{agentId}` reference (for example `agents.defaults.systemAgent`).
    public struct AgentReference: ConfigDocumentObject {
        /// Agent id.
        public var agentId: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty reference.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("agentId", \.agentId)] }
    }

    /// `models.<provider/model>` runtime entry under agents.
    public struct ModelRuntimeEntry: ConfigDocumentObject {
        /// Short alias.
        public var alias: String?
        /// Provider parameters.
        public var params: [String: AnyCodable]?
        /// Agent runtime (`{id}`).
        public var agentRuntime: AgentReferenceID?
        /// Model picker runtimes (≤ 8).
        public var pickerRuntimes: [String]?
        /// Code Mode for this model.
        public var codeMode: Bool?
        /// Streaming for this model.
        public var streaming: Bool?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty entry.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("alias", \.alias), .init("params", \.params), .init("agentRuntime", \.agentRuntime),
             .init("pickerRuntimes", \.pickerRuntimes), .init("codeMode", \.codeMode), .init("streaming", \.streaming)]
        }
    }

    /// `{id}` runtime reference.
    public struct AgentReferenceID: ConfigDocumentObject {
        /// Runtime id.
        public var id: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty reference.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("id", \.id)] }
    }

    /// `modelPolicy`: model allowlist.
    public struct ModelPolicy: ConfigDocumentObject {
        /// Allowed `provider/model` refs (globs allowed).
        public var allow: [String]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty policy.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("allow", \.allow)] }
    }

    /// Subagent delegation settings.
    public struct Subagents: ConfigDocumentObject {
        /// `suggest` or `prefer`.
        public var delegationMode: String?
        /// Agents that may be spawned.
        public var allowAgents: [String]?
        /// Maximum concurrent subagents (defaults only).
        public var maxConcurrent: Int?
        /// Maximum spawn depth 1...5 (default 5).
        public var maxSpawnDepth: Int?
        /// Maximum children per agent 1...20 (default 5).
        public var maxChildrenPerAgent: Int?
        /// Archive after minutes.
        public var archiveAfterMinutes: Int?
        /// Subagent model.
        public var model: ConfigModelSelection?
        /// Subagent think level.
        public var thinking: String?
        /// Run timeout in seconds.
        public var runTimeoutSeconds: Int?
        /// Announce timeout in milliseconds.
        public var announceTimeoutMs: Int?
        /// Require an explicit agent id.
        public var requireAgentId: Bool?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates empty settings.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("delegationMode", \.delegationMode), .init("allowAgents", \.allowAgents), .init("maxConcurrent", \.maxConcurrent),
                .init("maxSpawnDepth", \.maxSpawnDepth), .init("maxChildrenPerAgent", \.maxChildrenPerAgent),
                .init("archiveAfterMinutes", \.archiveAfterMinutes), .init("model", \.model), .init("thinking", \.thinking),
                .init("runTimeoutSeconds", \.runTimeoutSeconds), .init("announceTimeoutMs", \.announceTimeoutMs),
                .init("requireAgentId", \.requireAgentId),
            ]
        }
    }

    /// Agent heartbeat.
    public struct Heartbeat: ConfigDocumentObject {
        /// Interval (duration; bare numbers are minutes).
        public var every: ConfigDurationValue?
        /// Active hours window.
        public var activeHours: ActiveHours?
        /// Heartbeat model.
        public var model: String?
        /// Session key.
        public var session: String?
        /// Delivery target.
        public var target: String?
        /// `allow` or `block`.
        public var directPolicy: String?
        /// Delivery recipient.
        public var to: String?
        /// Account id.
        public var accountId: String?
        /// Prompt.
        public var prompt: String?
        /// Timeout in seconds.
        public var timeoutSeconds: Int?
        /// Use a light context.
        public var lightContext: Bool?
        /// Run in an isolated session.
        public var isolatedSession: Bool?
        /// Owning agent id (defaults only).
        public var agentId: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty heartbeat.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("every", \.every), .init("activeHours", \.activeHours), .init("model", \.model), .init("session", \.session),
                .init("target", \.target), .init("directPolicy", \.directPolicy), .init("to", \.to), .init("accountId", \.accountId),
                .init("prompt", \.prompt), .init("timeoutSeconds", \.timeoutSeconds), .init("lightContext", \.lightContext),
                .init("isolatedSession", \.isolatedSession), .init("agentId", \.agentId),
            ]
        }

        /// Heartbeat interval in milliseconds (bare numbers are minutes).
        public var everyMilliseconds: Int64? {
            self.every?.milliseconds(defaultUnit: .minutes)
        }

        /// Active hours (`HH:MM`; `24:00` allowed only for `end`).
        public struct ActiveHours: ConfigDocumentObject {
            /// Start time.
            public var start: String?
            /// End time.
            public var end: String?
            /// IANA time zone.
            public var timezone: String?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty window.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("start", \.start), .init("end", \.end), .init("timezone", \.timezone)]
            }
        }
    }

    /// Agent sandbox (docker/ssh/browser/prune pass through; they are server-only).
    public struct Sandbox: ConfigDocumentObject {
        /// `off`, `non-main` or `all`.
        public var mode: String?
        /// Sandbox backend.
        public var backend: String?
        /// `none`, `ro` or `rw`.
        public var workspaceAccess: String?
        /// `spawned` or `all`.
        public var sessionToolsVisibility: String?
        /// `session`, `agent` or `shared`.
        public var scope: String?
        /// Sandbox workspace root.
        public var workspaceRoot: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty sandbox.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("mode", \.mode), .init("backend", \.backend), .init("workspaceAccess", \.workspaceAccess),
             .init("sessionToolsVisibility", \.sessionToolsVisibility), .init("scope", \.scope), .init("workspaceRoot", \.workspaceRoot)]
        }
    }

    /// Agent identity.
    public struct Identity: ConfigDocumentObject {
        /// Name.
        public var name: String?
        /// Theme.
        public var theme: String?
        /// Emoji.
        public var emoji: String?
        /// Avatar.
        public var avatar: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty identity.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("name", \.name), .init("theme", \.theme), .init("emoji", \.emoji), .init("avatar", \.avatar)]
        }
    }

    /// `agents.entries.*.memory`.
    public struct AgentMemory: ConfigDocumentObject {
        /// Per-agent memory search.
        public var search: MemorySearch?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty value.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("search", \.search)] }
    }

    /// `agents.defaults.compaction` (typed subset; tuning keys pass through).
    public struct Compaction: ConfigDocumentObject {
        /// Enables compaction.
        public var enabled: Bool?
        /// `default` or `safeguard`.
        public var mode: String?
        /// Compaction provider.
        public var provider: String?
        /// Think level or `inherit`.
        public var thinkingLevel: String?
        /// Recent tokens kept verbatim.
        public var keepRecentTokens: Int?
        /// `strict` or `off`.
        public var identifierPolicy: String?
        /// Recent turns preserved (0...12).
        public var recentTurnsPreserve: Int?
        /// Compaction model.
        public var model: String?
        /// Timeout in seconds.
        public var timeoutSeconds: Int?
        /// Byte-triggered compaction threshold.
        public var maxActiveTranscriptBytes: ConfigByteSize?
        /// Notify the user when compacting.
        public var notifyUser: Bool?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty value.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("enabled", \.enabled), .init("mode", \.mode), .init("provider", \.provider),
                .init("thinkingLevel", \.thinkingLevel), .init("keepRecentTokens", \.keepRecentTokens),
                .init("identifierPolicy", \.identifierPolicy), .init("recentTurnsPreserve", \.recentTurnsPreserve),
                .init("model", \.model), .init("timeoutSeconds", \.timeoutSeconds),
                .init("maxActiveTranscriptBytes", \.maxActiveTranscriptBytes), .init("notifyUser", \.notifyUser),
            ]
        }
    }
}

// MARK: - Bindings

extension OpenClawConfigDocument {
    /// One `bindings[]` entry: a route binding, an ACP binding, or an unknown future type.
    public enum AgentBinding: Codable, Sendable, Equatable {
        /// `type: "route"` (or no type).
        case route(RouteBinding)
        /// `type: "acp"`.
        case acp(ACPBinding)
        /// Any other `type` (kept verbatim).
        case unknown(AnyCodable)

        /// Decodes by the `type` discriminator.
        /// - Parameter decoder: Source decoder.
        public init(from decoder: Decoder) throws {
            let raw = try AnyCodable(from: decoder)
            guard let object = raw.dictionaryValue else {
                throw DecodingError.typeMismatch(
                    AgentBinding.self,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a binding object.")
                )
            }
            switch object["type"]?.stringValue {
            case nil, "route":
                self = .route(try RouteBinding(from: decoder))
            case "acp":
                self = .acp(try ACPBinding(from: decoder))
            default:
                self = .unknown(raw)
            }
        }

        /// Encodes the binding.
        /// - Parameter encoder: Target encoder.
        public func encode(to encoder: Encoder) throws {
            switch self {
            case .route(let binding):
                try binding.encode(to: encoder)
            case .acp(let binding):
                try binding.encode(to: encoder)
            case .unknown(let raw):
                try raw.encode(to: encoder)
            }
        }

        /// Target agent id.
        public var agentId: String? {
            switch self {
            case .route(let binding):
                return binding.agentId
            case .acp(let binding):
                return binding.agentId
            case .unknown(let raw):
                return raw.dictionaryValue?["agentId"]?.stringValue
            }
        }

        /// Match rule.
        public var match: BindingMatch? {
            switch self {
            case .route(let binding):
                return binding.match
            case .acp(let binding):
                return binding.match
            case .unknown:
                return nil
            }
        }
    }

    /// Route binding (`type: "route"` or omitted).
    public struct RouteBinding: ConfigDocumentObject {
        /// `"route"` (optional).
        public var type: String?
        /// Target agent id.
        public var agentId: String?
        /// Free-form comment.
        public var comment: String?
        /// Match rule.
        public var match: BindingMatch?
        /// Session scoping override (`dmScope`, `groupScope`).
        public var session: BindingSession?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty binding.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("type", \.type), .init("agentId", \.agentId), .init("comment", \.comment), .init("match", \.match),
             .init("session", \.session)]
        }
    }

    /// ACP binding (`type: "acp"`); requires `match.peer.id`.
    public struct ACPBinding: ConfigDocumentObject {
        /// `"acp"`.
        public var type: String?
        /// Target agent id.
        public var agentId: String?
        /// Free-form comment.
        public var comment: String?
        /// Match rule.
        public var match: BindingMatch?
        /// ACP session options (`mode`, `label`, `cwd`, `backend`).
        public var acp: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty binding.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("type", \.type), .init("agentId", \.agentId), .init("comment", \.comment), .init("match", \.match), .init("acp", \.acp)]
        }
    }

    /// Binding match rule.
    public struct BindingMatch: ConfigDocumentObject {
        /// Channel id (required).
        public var channel: String?
        /// Account: omitted/empty = the channel's default account; `*` = all accounts.
        public var accountId: String?
        /// Peer (`kind`: `direct`, `group` or `channel`; legacy `dm` is migrated to `direct`).
        public var peer: Peer?
        /// Discord guild id.
        public var guildId: String?
        /// Microsoft Teams team id.
        public var teamId: String?
        /// Required roles.
        public var roles: [String]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty match.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("channel", \.channel), .init("accountId", \.accountId), .init("peer", \.peer), .init("guildId", \.guildId),
             .init("teamId", \.teamId), .init("roles", \.roles)]
        }

        /// Binding peer.
        public struct Peer: ConfigDocumentObject {
            /// `direct`, `group` or `channel`.
            public var kind: String?
            /// Peer id.
            public var id: String?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty peer.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("kind", \.kind), .init("id", \.id)] }
        }
    }

    /// Binding session override.
    public struct BindingSession: ConfigDocumentObject {
        /// `main`, `per-peer`, `per-channel-peer` or `per-account-channel-peer`.
        public var dmScope: String?
        /// `main` or `per-group`.
        public var groupScope: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty override.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("dmScope", \.dmScope), .init("groupScope", \.groupScope)] }
    }
}
