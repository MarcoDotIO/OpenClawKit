import Foundation
import OpenClawProtocol

/// Lossless, upstream-shaped model of `openclaw.json` for OpenClaw 2026.9.6.
///
/// Use this type to read and write the file an upstream gateway loads (or the `config.get` snapshot a
/// gateway returns). It is separate from the SDK-native ``OpenClawConfig`` that ``ConfigStore``
/// persists: upstream validates every object strictly, so SDK-only keys must never be written here.
///
/// Decoding is lenient: unknown keys, unknown enum strings and mistyped optional leaves never fail
/// the document. They are kept in each object's `additionalProperties` (so encoding reproduces them)
/// and reported to an optional ``ConfigDecodeIssueCollector``. Sections the SDK uses are typed;
/// server-only sections (`browser`, `acp`, `transcripts`, …) pass through as JSON. Nothing is
/// synthesized: absent keys stay absent.
///
/// ``decode(_:allowJSON5:migrateLegacyKeys:issues:)`` runs the doctor-migration port
/// (``OpenClawConfigMigrator``) on a copy first, so typed views always see canonical shapes (for
/// example `agents.entries` instead of the legacy `agents.list`).
public struct OpenClawConfigDocument: ConfigDocumentObject {
    /// `$schema`: optional JSON-schema URL for editors.
    public var schemaURL: String?
    /// `meta`: writer metadata.
    @ConfigIndirect public var meta: Meta?
    /// `env`: shell-env import and inline environment variables.
    @ConfigIndirect public var env: Env?
    /// `wizard`: onboarding wizard state.
    @ConfigIndirect public var wizard: Wizard?
    /// `diagnostics`: diagnostics and OpenTelemetry export.
    @ConfigIndirect public var diagnostics: Diagnostics?
    /// `logging`: log levels, files and audit logging.
    @ConfigIndirect public var logging: Logging?
    /// `update`: self-update channel.
    @ConfigIndirect public var update: Update?
    /// `telemetry`: anonymous telemetry consent.
    @ConfigIndirect public var telemetry: Telemetry?
    /// `browser`: managed browser settings (server-only; passed through).
    public var browser: AnyCodable?
    /// `ui`: operator display preferences.
    @ConfigIndirect public var ui: UI?
    /// `secrets`: secret providers and defaults.
    @ConfigIndirect public var secrets: Secrets?
    /// `auth`: auth-profile metadata (secrets live in the gateway's auth stores, not here).
    @ConfigIndirect public var auth: Auth?
    /// `accessGroups`: named sender/channel audiences.
    public var accessGroups: [String: AccessGroup]?
    /// `acp`: agent client protocol settings (server-only; passed through).
    public var acp: AnyCodable?
    /// `models`: model providers and catalog refresh.
    @ConfigIndirect public var models: Models?
    /// `nodeHost`: CLI node-host settings.
    @ConfigIndirect public var nodeHost: NodeHost?
    /// `agents`: agent roster and defaults.
    @ConfigIndirect public var agents: Agents?
    /// `worktreeRoot`: absolute or `~` path for agent worktrees.
    public var worktreeRoot: String?
    /// `worktreeAcceleration`: copy-on-write worktree acceleration (default `true`).
    public var worktreeAcceleration: Bool?
    /// `tools`: tool policy and tool configuration.
    @ConfigIndirect public var tools: Tools?
    /// `security`: audit suppressions and install policy.
    @ConfigIndirect public var security: Security?
    /// `bindings`: ordered route and ACP bindings.
    public var bindings: [AgentBinding]?
    /// `broadcast`: multi-agent broadcast groups.
    @ConfigIndirect public var broadcast: Broadcast?
    /// `attachments`: attachment retention.
    @ConfigIndirect public var attachments: Attachments?
    /// `messages`: reply presentation, queueing and acknowledgements.
    @ConfigIndirect public var messages: Messages?
    /// `tts`: text-to-speech defaults.
    @ConfigIndirect public var tts: TTS?
    /// `commands`: slash-command settings.
    @ConfigIndirect public var commands: Commands?
    /// `approvals`: exec/plugin approval forwarding.
    @ConfigIndirect public var approvals: Approvals?
    /// `session`: session scoping, reset and maintenance.
    @ConfigIndirect public var session: Session?
    /// `cron`: scheduled jobs.
    @ConfigIndirect public var cron: Cron?
    /// `transcripts`: meeting transcript capture (metadata only).
    @ConfigIndirect public var transcripts: Transcripts?
    /// `hooks`: webhook ingress and internal hooks.
    @ConfigIndirect public var hooks: Hooks?
    /// `channels`: channel defaults and plugin-owned channel blocks.
    @ConfigIndirect public var channels: Channels?
    /// `discovery`: mDNS and wide-area discovery.
    @ConfigIndirect public var discovery: Discovery?
    /// `talk`: Talk speech and realtime settings.
    @ConfigIndirect public var talk: Talk?
    /// `gateway`: gateway listener, auth and control-plane settings.
    @ConfigIndirect public var gateway: Gateway?
    /// `cloudWorkers`: cloud worker profiles (metadata only).
    @ConfigIndirect public var cloudWorkers: CloudWorkers?
    /// `desktop`: remote desktop host (metadata only).
    @ConfigIndirect public var desktop: Desktop?
    /// `memory`: memory search.
    @ConfigIndirect public var memory: Memory?
    /// `mcp`: MCP servers.
    @ConfigIndirect public var mcp: MCP?
    /// `skills`: skill loading and entries.
    @ConfigIndirect public var skills: Skills?
    /// `plugins`: plugin loading and entries.
    @ConfigIndirect public var plugins: Plugins?
    /// `surfaces`: per-surface silent-reply policy.
    public var surfaces: [String: Surface]?
    /// `proxy`: operator-managed SSRF forward proxy.
    @ConfigIndirect public var proxy: Proxy?
    /// Root keys this type does not type (only keys present in the source).
    public var additionalProperties: [String: AnyCodable] = [:]

    /// Creates an empty document.
    public init() {}

    /// Typed root fields in upstream key order (`src/config/zod-schema.root-shape.ts`).
    public static var configFields: [ConfigField<Self>] {
        [
            .init("$schema", \.schemaURL), .init("meta", \.meta), .init("env", \.env), .init("wizard", \.wizard),
            .init("diagnostics", \.diagnostics), .init("logging", \.logging), .init("update", \.update),
            .init("telemetry", \.telemetry), .init("browser", \.browser), .init("ui", \.ui), .init("secrets", \.secrets),
            .init("auth", \.auth), .init("accessGroups", \.accessGroups), .init("acp", \.acp), .init("models", \.models),
            .init("nodeHost", \.nodeHost), .init("agents", \.agents), .init("worktreeRoot", \.worktreeRoot),
            .init("worktreeAcceleration", \.worktreeAcceleration), .init("tools", \.tools), .init("security", \.security),
            .init("bindings", \.bindings), .init("broadcast", \.broadcast), .init("attachments", \.attachments),
            .init("messages", \.messages), .init("tts", \.tts), .init("commands", \.commands), .init("approvals", \.approvals),
            .init("session", \.session), .init("cron", \.cron), .init("transcripts", \.transcripts), .init("hooks", \.hooks),
            .init("channels", \.channels), .init("discovery", \.discovery), .init("talk", \.talk), .init("gateway", \.gateway),
            .init("cloudWorkers", \.cloudWorkers), .init("desktop", \.desktop), .init("memory", \.memory), .init("mcp", \.mcp),
            .init("skills", \.skills), .init("plugins", \.plugins), .init("surfaces", \.surfaces), .init("proxy", \.proxy),
        ]
    }

    /// Upstream version the document model tracks (`meta.lastTouchedVersion` future-version guard).
    public static let upstreamParityVersion = "2026.9.6"

    /// Root keys upstream still migrates, mapped to their canonical location.
    public static let migratableRootKeys: [String: String] = [
        "media": "attachments", "web": "channels.whatsapp.enabled", "audit": "logging.audit",
        "defaultModel": "agents.defaults.model", "memorySearch": "memory.search",
        "heartbeat": "agents.defaults.heartbeat", "canvasHost": "plugins.entries.canvas.config.host",
    ]

    /// Retired root keys upstream drops.
    public static let droppedRootKeys: Set<String> = ["cli", "crestodian", "audio", "tui", "worktrees"]

    /// Pre-multi-agent root keys upstream now rejects without a migration.
    public static let unmigratableRootKeys: Set<String> = ["routing", "agent", "identity"]

    // MARK: Decoding

    /// Decodes `openclaw.json` bytes (JSON or JSON5).
    /// - Parameters:
    ///   - data: File contents.
    ///   - allowJSON5: Accept JSON5 syntax (comments, trailing commas, unquoted keys, …).
    ///   - migrateLegacyKeys: Apply the doctor-migration port before typed decoding (default `true`).
    ///   - issues: Optional sink for lenient-decoding and legacy-key issues.
    /// - Returns: The decoded document.
    /// - Throws: ``OpenClawJSON5/ParseError`` for malformed input, or an error when the root is not an object.
    public static func decode(
        _ data: Data,
        allowJSON5: Bool = true,
        migrateLegacyKeys: Bool = true,
        issues: ConfigDecodeIssueCollector? = nil
    ) throws -> OpenClawConfigDocument {
        let parsed = try OpenClawJSON5.parseWithKeyOrder(data, allowJSON5: allowJSON5)
        guard let object = parsed.value.dictionaryValue else {
            throw OpenClawCoreError.invalidConfiguration("openclaw.json must contain a JSON object at the root")
        }
        return try self.decode(jsonObject: object, keyOrder: parsed.keyOrder, migrateLegacyKeys: migrateLegacyKeys, issues: issues)
    }

    /// Decodes a document from a JSON object tree.
    /// - Parameters:
    ///   - jsonObject: Raw config object.
    ///   - keyOrder: Optional authored key order (used for `agents.entries` order).
    ///   - migrateLegacyKeys: Apply the doctor-migration port before typed decoding.
    ///   - issues: Optional issue sink.
    /// - Returns: The decoded document.
    public static func decode(
        jsonObject: [String: AnyCodable],
        keyOrder: ConfigKeyOrder? = nil,
        migrateLegacyKeys: Bool = true,
        issues: ConfigDecodeIssueCollector? = nil
    ) throws -> OpenClawConfigDocument {
        var tree = jsonObject
        var order = keyOrder ?? ConfigKeyOrder()
        let changes: [ConfigMigrationChange]
        if migrateLegacyKeys {
            changes = OpenClawConfigMigrator.migrate(&tree, keyOrder: &order)
        } else {
            changes = OpenClawConfigMigrator.proposedChanges(for: tree)
        }
        if let issues {
            for issue in OpenClawConfigMigrator.issues(for: changes) {
                issues.record(issue)
            }
            for issue in OpenClawConfigMigrator.unportedIssues(in: tree) {
                issues.record(issue)
            }
        }
        var document = try ConfigTreeCoding.decode(OpenClawConfigDocument.self, from: AnyCodable(.object(tree)), issues: issues)
        if let entries = document.agents?.entries {
            let recorded = order.keys(at: ["agents", "entries"]) ?? []
            document.agents?.entryOrder = ConfigOrderHint(recorded).ordered(entries.keys)
        }
        return document
    }

    // MARK: Encoding

    /// Encodes the document as JSON text.
    ///
    /// Pretty output matches `JSON.stringify(value, null, 2)` so files written by the SDK and by the
    /// upstream CLI diff cleanly. Without `keyOrder`, keys are written alphabetically.
    /// - Parameters:
    ///   - prettyPrinted: Indent with two spaces.
    ///   - sortedKeys: Force alphabetical keys even when `keyOrder` is supplied.
    ///   - keyOrder: Optional authored key order to preserve.
    /// - Returns: UTF-8 JSON bytes.
    public func encoded(prettyPrinted: Bool = true, sortedKeys: Bool = false, keyOrder: ConfigKeyOrder? = nil) throws -> Data {
        var order = keyOrder ?? ConfigKeyOrder()
        if keyOrder == nil, let entryOrder = self.agents?.entryOrder, !entryOrder.isEmpty {
            order.set(entryOrder, at: ["agents", "entries"])
        }
        let tree = try AnyCodable(encoding: self)
        return Data(OpenClawJSON5.serialize(tree, keyOrder: order, sortedKeys: sortedKeys, prettyPrinted: prettyPrinted).utf8)
    }

    // MARK: Shared helpers

    /// Port of upstream `normalizeAgentId`: trims and lowercases; invalid characters become `-`;
    /// unrepresentable ids fall back to `main`.
    /// - Parameter value: Raw agent id.
    /// - Returns: Canonical agent id.
    public static func normalizeAgentID(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if Self.isValidAgentID(trimmed) {
            return lowered
        }
        var collapsed = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            let isAllowed = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-"
            if isAllowed {
                collapsed.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                collapsed.append("-")
                lastWasDash = true
            }
        }
        while collapsed.hasPrefix("-") {
            collapsed.removeFirst()
        }
        while collapsed.hasSuffix("-") {
            collapsed.removeLast()
        }
        let limited = String(collapsed.prefix(64))
        return limited.isEmpty ? "main" : limited
    }

    /// Whether `value` (trimmed) matches `^[a-z0-9][a-z0-9_-]{0,63}$` case-insensitively.
    /// - Parameter value: Candidate agent id.
    /// - Returns: `true` for canonical agent-id input.
    public static func isValidAgentID(_ value: String?) -> Bool {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first, trimmed.unicodeScalars.count <= 64 else {
            return false
        }
        func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        guard isAlphanumeric(first) else {
            return false
        }
        return trimmed.unicodeScalars.dropFirst().allSatisfy { isAlphanumeric($0) || $0 == "_" || $0 == "-" }
    }
}

// MARK: - Small root sections

extension OpenClawConfigDocument {
    /// `meta`: writer metadata stamped by config writes.
    public struct Meta: ConfigDocumentObject {
        /// Version of the OpenClaw build that last wrote the file.
        public var lastTouchedVersion: String?
        /// One-time doctor migration markers (literal `true` flags; never unset them).
        public var migrations: Migrations?
        /// Passthrough keys (for example the retired `lastTouchedAt`, which writers strip).
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates empty metadata.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("lastTouchedVersion", \.lastTouchedVersion), .init("migrations", \.migrations)]
        }

        /// `meta.migrations` markers.
        public struct Migrations: ConfigDocumentObject {
            /// The model-policy allowlist migration ran.
            public var modelPolicyAllowlist: Bool?
            /// The utility-model separation migration ran.
            public var utilityModelSeparation: Bool?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]

            /// Creates empty markers.
            public init() {}

            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("modelPolicyAllowlist", \.modelPolicyAllowlist), .init("utilityModelSeparation", \.utilityModelSeparation)]
            }
        }
    }

    /// `env`: environment import and inline variables.
    public struct Env: ConfigDocumentObject {
        /// `env.shellEnv`: import the login shell environment.
        public var shellEnv: ShellEnv?
        /// `env.vars`: inline environment variables.
        public var vars: [String: String]?
        /// Passthrough keys; legacy string-valued keys are shorthand env vars (see ``effectiveVariables``).
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty env section.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("shellEnv", \.shellEnv), .init("vars", \.vars)]
        }

        /// `vars` merged with legacy string-valued sugar keys (`vars` wins).
        public var effectiveVariables: [String: String] {
            var result: [String: String] = [:]
            for (key, value) in self.additionalProperties {
                if let string = value.stringValue {
                    result[key] = string
                }
            }
            for (key, value) in self.vars ?? [:] {
                result[key] = value
            }
            return result
        }

        /// `env.shellEnv`.
        public struct ShellEnv: ConfigDocumentObject {
            /// Import the login shell environment.
            public var enabled: Bool?
            /// Import timeout in milliseconds.
            public var timeoutMs: Int?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]

            /// Creates an empty value.
            public init() {}

            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("enabled", \.enabled), .init("timeoutMs", \.timeoutMs)]
            }
        }
    }

    /// `wizard`: onboarding wizard state.
    public struct Wizard: ConfigDocumentObject {
        /// `full` or `guarded`.
        public var accessMode: AccessMode?
        /// Whether app recommendations are shown.
        public var appRecommendations: Bool?
        /// ISO timestamp of the last wizard run.
        public var lastRunAt: String?
        /// Version of the last wizard run.
        public var lastRunVersion: String?
        /// Commit of the last wizard run.
        public var lastRunCommit: String?
        /// Command that ran the wizard.
        public var lastRunCommand: String?
        /// `local` or `remote`.
        public var lastRunMode: String?
        /// ISO timestamp of the security acknowledgement.
        public var securityAcknowledgedAt: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates empty wizard state.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("accessMode", \.accessMode), .init("appRecommendations", \.appRecommendations), .init("lastRunAt", \.lastRunAt),
                .init("lastRunVersion", \.lastRunVersion), .init("lastRunCommit", \.lastRunCommit),
                .init("lastRunCommand", \.lastRunCommand), .init("lastRunMode", \.lastRunMode),
                .init("securityAcknowledgedAt", \.securityAcknowledgedAt),
            ]
        }

        /// `wizard.accessMode` vocabulary.
        public struct AccessMode: ConfigOpenEnum {
            /// Raw config string.
            public let rawValue: String
            /// Creates a value from its raw string.
            public init(rawValue: String) { self.rawValue = rawValue }
            /// Full access.
            public static let full = Self(rawValue: "full")
            /// Guarded access.
            public static let guarded = Self(rawValue: "guarded")
            /// Known values.
            public static let known: [Self] = [.full, .guarded]
        }
    }

    /// `discovery`: gateway discovery.
    public struct Discovery: ConfigDocumentObject {
        /// `discovery.wideArea`.
        public var wideArea: WideArea?
        /// `discovery.mdns`.
        public var mdns: MDNS?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty value.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("wideArea", \.wideArea), .init("mdns", \.mdns)]
        }

        /// Wide-area (DNS-SD) discovery; a domain enables it.
        public struct WideArea: ConfigDocumentObject {
            /// DNS-SD domain.
            public var domain: String?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("domain", \.domain)] }
        }

        /// mDNS advertisement.
        public struct MDNS: ConfigDocumentObject {
            /// `off`, `minimal` or `full`.
            public var mode: String?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("mode", \.mode)] }
        }
    }

    /// `attachments`: attachment retention.
    public struct Attachments: ConfigDocumentObject {
        /// Retention in hours (1...168).
        public var ttlHours: Int?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty value.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("ttlHours", \.ttlHours)] }
    }

    /// `surfaces.<id>`: per-surface reply policy.
    public struct Surface: ConfigDocumentObject {
        /// `silentReply`: whether `NO_REPLY` is allowed per chat kind.
        public var silentReply: SilentReplyPolicy?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty value.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("silentReply", \.silentReply)] }
    }

    /// `silentReply` policy (`group`, `internal`: `allow` | `disallow`).
    public struct SilentReplyPolicy: ConfigDocumentObject {
        /// Group-chat policy.
        public var group: String?
        /// Internal-surface policy.
        public var `internal`: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty value.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("group", \.group), .init("internal", \.internal)] }
    }
}
