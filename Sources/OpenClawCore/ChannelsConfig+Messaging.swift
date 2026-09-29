import Foundation
import OpenClawProtocol

/// Direct-message admission policy (upstream `DmPolicy`).
public enum ChannelDMPolicy: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Unknown senders receive a pairing code; the owner approves them (upstream default).
    case pairing
    /// Only `allowFrom` senders are admitted.
    case allowlist
    /// Everyone matching `allowFrom` is admitted; `open` still requires `"*"` or a match.
    case open
    /// Direct messages are ignored.
    case disabled
}

/// Group admission policy (upstream `GroupPolicy`).
public enum ChannelGroupPolicy: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Every group sender is admitted.
    case open
    /// Group messages are ignored.
    case disabled
    /// Only `groupAllowFrom` (falling back to `allowFrom`) senders are admitted (upstream default).
    case allowlist
}

/// History/context visibility mode (upstream `ContextVisibilityMode`).
public enum ChannelContextVisibility: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// All history is visible.
    case all
    /// Only allowlisted senders' history is visible.
    case allowlist
    /// Allowlisted senders plus quoted messages.
    case allowlistQuote = "allowlist_quote"
}

/// Outbound chunking mode (upstream `TextChunkMode`).
public enum ChannelTextChunkMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Split only when a message exceeds the chunk limit.
    case length
    /// Prefer paragraph boundaries before splitting by length.
    case newline
}

/// Native reply threading mode (upstream `ReplyToMode`).
public enum ChannelReplyToMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Never reply natively.
    case off
    /// Only the first chunk replies to the inbound message.
    case first
    /// Every chunk replies to the inbound message.
    case all
    /// Batched replies.
    case batched
}

/// Markdown table rendering mode (upstream `MarkdownTableMode`).
public enum ChannelMarkdownTableMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Tables pass through unchanged.
    case off
    /// Tables render as bullet lists.
    case bullets
    /// Tables render as code blocks.
    case code
    /// Tables render as native blocks.
    case block
}

/// Scope of inbound acknowledgement reactions (upstream `AckReactionScope`).
public enum ChannelAckReactionScope: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Every inbound message, including ambient room events.
    case all
    /// Direct messages only.
    case direct
    /// Every group message.
    case groupAll = "group-all"
    /// Group messages that mention the bot (upstream default).
    case groupMentions = "group-mentions"
    /// Never.
    case off
    /// Never (alias of ``off``).
    case none
}

/// Typing indicator mode (upstream `TypingMode`).
public enum ChannelTypingMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Never send typing indicators.
    case never
    /// Start typing as soon as the message is accepted.
    case instant
    /// Start typing when the model starts thinking.
    case thinking
    /// Start typing when the reply message starts.
    case message
}

/// Whether messages from other bots are admitted (upstream `allowBots`: Bool or `"mentions"`).
public enum ChannelAllowBots: Sendable, Equatable, Hashable, Codable {
    /// Bot messages are ignored.
    case disabled
    /// Bot messages are admitted.
    case enabled
    /// Bot messages are admitted only when they mention this bot.
    case mentions

    /// Whether any bot message can be admitted.
    public var admitsBots: Bool {
        self != .disabled
    }

    /// Decodes `true`, `false` or `"mentions"`.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = flag ? .enabled : .disabled
            return
        }
        let raw = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "mentions":
            self = .mentions
        case "true":
            self = .enabled
        case "false":
            self = .disabled
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "allowBots must be a boolean or \"mentions\"")
        }
    }

    /// Encodes `true`, `false` or `"mentions"`.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .disabled:
            try container.encode(false)
        case .enabled:
            try container.encode(true)
        case .mentions:
            try container.encode("mentions")
        }
    }
}

/// Block-streaming coalescing thresholds (upstream `BlockStreamingCoalesce`).
public struct ChannelBlockStreamingCoalesceConfig: Codable, Sendable, Equatable, Hashable {
    /// Minimum characters per flushed block.
    public var minChars: Int?
    /// Maximum characters per flushed block.
    public var maxChars: Int?
    /// Idle flush timeout in milliseconds.
    public var idleMs: Int?

    /// Creates coalescing thresholds.
    /// - Parameters:
    ///   - minChars: Minimum characters per block.
    ///   - maxChars: Maximum characters per block.
    ///   - idleMs: Idle flush timeout in milliseconds.
    public init(minChars: Int? = nil, maxChars: Int? = nil, idleMs: Int? = nil) {
        self.minChars = minChars
        self.maxChars = maxChars
        self.idleMs = idleMs
    }
}

/// Block streaming settings (upstream `ChannelStreamingBlock`).
public struct ChannelStreamingBlockConfig: Codable, Sendable, Equatable, Hashable {
    /// Whether block streaming is enabled.
    public var enabled: Bool?
    /// Coalescing thresholds.
    public var coalesce: ChannelBlockStreamingCoalesceConfig?

    /// Creates block streaming settings.
    /// - Parameters:
    ///   - enabled: Whether block streaming is enabled.
    ///   - coalesce: Coalescing thresholds.
    public init(enabled: Bool? = nil, coalesce: ChannelBlockStreamingCoalesceConfig? = nil) {
        self.enabled = enabled
        self.coalesce = coalesce
    }
}

/// Nested streaming settings (upstream `ChannelDeliveryStreamingConfig` / preview streaming).
public struct ChannelStreamingConfig: Codable, Sendable, Equatable, Hashable {
    /// Preview streaming mode (`off`, `partial`, `block`, `progress`) for channels that support it.
    public var mode: String?
    /// Chunking mode.
    public var chunkMode: ChannelTextChunkMode?
    /// Block streaming settings.
    public var block: ChannelStreamingBlockConfig?
    /// Plugin-owned preview/progress keys preserved losslessly.
    public var additionalProperties: [String: AnyCodable]

    /// Creates streaming settings.
    /// - Parameters:
    ///   - mode: Preview streaming mode.
    ///   - chunkMode: Chunking mode.
    ///   - block: Block streaming settings.
    ///   - additionalProperties: Passthrough keys.
    public init(
        mode: String? = nil,
        chunkMode: ChannelTextChunkMode? = nil,
        block: ChannelStreamingBlockConfig? = nil,
        additionalProperties: [String: AnyCodable] = [:]
    ) {
        self.mode = mode
        self.chunkMode = chunkMode
        self.block = block
        self.additionalProperties = additionalProperties
    }

    /// Whether no field is set.
    public var isEmpty: Bool {
        self.mode == nil && self.chunkMode == nil && self.block == nil && self.additionalProperties.isEmpty
    }

    /// Decodes streaming settings, keeping unknown keys.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.mode = reader.value(String.self, "mode")
        self.chunkMode = reader.value(ChannelTextChunkMode.self, "chunkMode")
        self.block = reader.value(ChannelStreamingBlockConfig.self, "block")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes streaming settings.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encodeIfPresent(self.mode, "mode")
        try writer.encodeIfPresent(self.chunkMode, "chunkMode")
        try writer.encodeIfPresent(self.block, "block")
        try writer.encodePassthrough(self.additionalProperties, skipping: ["mode", "chunkMode", "block"])
    }
}

/// Markdown rendering settings (upstream `MarkdownConfig`).
public struct ChannelMarkdownConfig: Codable, Sendable, Equatable, Hashable {
    /// Table rendering mode.
    public var tables: ChannelMarkdownTableMode?

    /// Creates markdown settings.
    /// - Parameter tables: Table rendering mode.
    public init(tables: ChannelMarkdownTableMode? = nil) {
        self.tables = tables
    }
}

/// Implicit mention policy (upstream `ChannelImplicitMentionsConfig`).
public struct ChannelImplicitMentionsConfig: Codable, Sendable, Equatable, Hashable {
    /// Replies to the bot count as mentions (default `true`).
    public var replyToBot: Bool?
    /// Quoting the bot counts as a mention (default `true`).
    public var quotedBot: Bool?
    /// Participating in a bot thread counts as a mention (default `true`).
    public var threadParticipation: Bool?

    /// Creates implicit mention settings.
    /// - Parameters:
    ///   - replyToBot: Replies to the bot count as mentions.
    ///   - quotedBot: Quoting the bot counts as a mention.
    ///   - threadParticipation: Bot-thread participation counts as a mention.
    public init(replyToBot: Bool? = nil, quotedBot: Bool? = nil, threadParticipation: Bool? = nil) {
        self.replyToBot = replyToBot
        self.quotedBot = quotedBot
        self.threadParticipation = threadParticipation
    }

    /// Merges a narrower override over broader defaults (non-nil override values win).
    /// - Parameter override: Narrower settings.
    /// - Returns: Merged settings.
    public func merged(with override: ChannelImplicitMentionsConfig?) -> ChannelImplicitMentionsConfig {
        guard let override else { return self }
        return ChannelImplicitMentionsConfig(
            replyToBot: override.replyToBot ?? self.replyToBot,
            quotedBot: override.quotedBot ?? self.quotedBot,
            threadParticipation: override.threadParticipation ?? self.threadParticipation
        )
    }
}

/// Bot-to-bot loop guard settings (upstream `ChannelBotLoopProtectionConfig`).
///
/// Defaults are `enabled: true`, 20 events per 60 second window and a 60 second cooldown.
public struct ChannelBotLoopProtectionConfig: Codable, Sendable, Equatable, Hashable {
    /// Built-in defaults (upstream `DEFAULT_PAIR_LOOP_GUARD_CONFIG`).
    public static let builtInDefaults = ChannelBotLoopProtectionConfig(
        enabled: true,
        maxEventsPerWindow: 20,
        windowSeconds: 60,
        cooldownSeconds: 60
    )

    /// Whether the guard is enabled.
    public var enabled: Bool?
    /// Events allowed per window before the cooldown starts.
    public var maxEventsPerWindow: Int?
    /// Rolling window in seconds.
    public var windowSeconds: Int?
    /// Suppression cooldown in seconds.
    public var cooldownSeconds: Int?

    /// Creates loop guard settings.
    /// - Parameters:
    ///   - enabled: Whether the guard is enabled.
    ///   - maxEventsPerWindow: Events per window.
    ///   - windowSeconds: Window size in seconds.
    ///   - cooldownSeconds: Cooldown in seconds.
    public init(enabled: Bool? = nil, maxEventsPerWindow: Int? = nil, windowSeconds: Int? = nil, cooldownSeconds: Int? = nil) {
        self.enabled = enabled
        self.maxEventsPerWindow = maxEventsPerWindow
        self.windowSeconds = windowSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    /// Merges configs from broad to narrow; later non-nil, positive values win
    /// (upstream `mergePairLoopGuardConfig`).
    /// - Parameter configs: Configs ordered from broadest to narrowest.
    /// - Returns: Merged config, or `nil` when every input is `nil`.
    public static func merge(_ configs: [ChannelBotLoopProtectionConfig?]) -> ChannelBotLoopProtectionConfig? {
        var merged = ChannelBotLoopProtectionConfig()
        var hasValue = false
        for config in configs.compactMap({ $0 }) {
            if let enabled = config.enabled {
                merged.enabled = enabled
                hasValue = true
            }
            if let value = config.maxEventsPerWindow {
                merged.maxEventsPerWindow = value
                hasValue = true
            }
            if let value = config.windowSeconds {
                merged.windowSeconds = value
                hasValue = true
            }
            if let value = config.cooldownSeconds {
                merged.cooldownSeconds = value
                hasValue = true
            }
        }
        return hasValue ? merged : nil
    }
}

/// Heartbeat visibility settings (upstream `ChannelHeartbeatVisibilityConfig`).
public struct ChannelHeartbeatVisibilityConfig: Codable, Sendable, Equatable, Hashable {
    /// Show successful heartbeats.
    public var showOk: Bool?
    /// Show heartbeat alerts.
    public var showAlerts: Bool?
    /// Use an indicator instead of a message.
    public var useIndicator: Bool?

    /// Creates heartbeat visibility settings.
    /// - Parameters:
    ///   - showOk: Show successful heartbeats.
    ///   - showAlerts: Show alerts.
    ///   - useIndicator: Use an indicator.
    public init(showOk: Bool? = nil, showAlerts: Bool? = nil, useIndicator: Bool? = nil) {
        self.showOk = showOk
        self.showAlerts = showAlerts
        self.useIndicator = useIndicator
    }
}

/// Per-group (or per-room) overrides keyed by platform group id or `"*"`.
public struct ChannelGroupConfig: Codable, Sendable, Equatable, Hashable {
    /// When `false`, the bot ignores this group.
    public var enabled: Bool?
    /// Whether group messages must mention the bot.
    public var requireMention: Bool?
    /// Group-specific admission policy.
    public var groupPolicy: ChannelGroupPolicy?
    /// Group-specific sender allowlist.
    public var allowFrom: [String]?
    /// Group-specific loop guard settings.
    public var botLoopProtection: ChannelBotLoopProtectionConfig?
    /// Group-specific implicit mention settings.
    public var implicitMentions: ChannelImplicitMentionsConfig?
    /// Plugin-owned keys (topics, tools, skills, system prompts, ...) preserved losslessly.
    public var additionalProperties: [String: AnyCodable]

    /// Creates group overrides.
    /// - Parameters:
    ///   - enabled: When `false`, the group is ignored.
    ///   - requireMention: Whether messages must mention the bot.
    ///   - groupPolicy: Group-specific policy.
    ///   - allowFrom: Group-specific sender allowlist.
    ///   - botLoopProtection: Group-specific loop guard.
    ///   - implicitMentions: Group-specific implicit mentions.
    ///   - additionalProperties: Passthrough keys.
    public init(
        enabled: Bool? = nil,
        requireMention: Bool? = nil,
        groupPolicy: ChannelGroupPolicy? = nil,
        allowFrom: [String]? = nil,
        botLoopProtection: ChannelBotLoopProtectionConfig? = nil,
        implicitMentions: ChannelImplicitMentionsConfig? = nil,
        additionalProperties: [String: AnyCodable] = [:]
    ) {
        self.enabled = enabled
        self.requireMention = requireMention
        self.groupPolicy = groupPolicy
        self.allowFrom = allowFrom
        self.botLoopProtection = botLoopProtection
        self.implicitMentions = implicitMentions
        self.additionalProperties = additionalProperties
    }

    private static let typedKeys: Set<String> = [
        "enabled", "requireMention", "groupPolicy", "allowFrom", "botLoopProtection", "implicitMentions",
    ]

    /// Decodes group overrides, keeping unknown keys.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled")
        self.requireMention = reader.value(Bool.self, "requireMention")
        self.groupPolicy = reader.value(ChannelGroupPolicy.self, "groupPolicy")
        self.allowFrom = reader.stringList("allowFrom")
        self.botLoopProtection = reader.value(ChannelBotLoopProtectionConfig.self, "botLoopProtection")
        self.implicitMentions = reader.value(ChannelImplicitMentionsConfig.self, "implicitMentions")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes group overrides.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encodeIfPresent(self.enabled, "enabled")
        try writer.encodeIfPresent(self.requireMention, "requireMention")
        try writer.encodeIfPresent(self.groupPolicy, "groupPolicy")
        try writer.encodeIfPresent(self.allowFrom, "allowFrom")
        try writer.encodeIfPresent(self.botLoopProtection, "botLoopProtection")
        try writer.encodeIfPresent(self.implicitMentions, "implicitMentions")
        try writer.encodePassthrough(self.additionalProperties, skipping: Self.typedKeys)
    }
}

/// Shared messaging policy keys decoded flat from each `channels.<id>` object
/// (upstream `CommonChannelAccountSchema` plus reaction, bot and mention leaves).
///
/// Every field is optional so account overrides can merge per key; the ``effective…`` accessors
/// apply upstream's root defaults (`dmPolicy: pairing`, `groupPolicy: allowlist`).
public struct ChannelMessagingPolicyConfig: Codable, Sendable, Equatable, Hashable {
    /// Account display name.
    public var name: String?
    /// Whether setup/doctor flows may write this config.
    public var configWrites: Bool?
    /// Direct-message policy (default ``ChannelDMPolicy/pairing``).
    public var dmPolicy: ChannelDMPolicy?
    /// Sender allowlist (numbers are stringified).
    public var allowFrom: [String]?
    /// Group policy (default ``ChannelGroupPolicy/allowlist``).
    public var groupPolicy: ChannelGroupPolicy?
    /// Group sender allowlist; falls back to ``allowFrom`` when unset. An explicit `[]` blocks all.
    public var groupAllowFrom: [String]?
    /// Default delivery target.
    public var defaultTo: String?
    /// Outbound text chunk limit.
    public var textChunkLimit: Int?
    /// Streaming settings (legacy flat `chunkMode`/`blockStreaming`/`blockStreamingCoalesce` map here).
    public var streaming: ChannelStreamingConfig?
    /// Media size limit in megabytes.
    public var mediaMaxMb: Double?
    /// Native reply threading mode.
    public var replyToMode: ChannelReplyToMode?
    /// Outbound response prefix (`""` disables; `"auto"` derives `[identity.name]`).
    public var responsePrefix: String?
    /// Group history limit.
    public var historyLimit: Int?
    /// Direct-message history limit.
    public var dmHistoryLimit: Int?
    /// Context visibility mode.
    public var contextVisibility: ChannelContextVisibility?
    /// Markdown rendering settings.
    public var markdown: ChannelMarkdownConfig?
    /// Implicit mention settings.
    public var implicitMentions: ChannelImplicitMentionsConfig?
    /// Bot loop guard settings.
    public var botLoopProtection: ChannelBotLoopProtectionConfig?
    /// Whether bot messages are admitted.
    public var allowBots: ChannelAllowBots?
    /// Acknowledgement reaction emoji (default `👀`).
    public var ackReaction: String?
    /// Acknowledgement reaction scope (default ``ChannelAckReactionScope/groupMentions``).
    public var ackReactionScope: ChannelAckReactionScope?
    /// Reaction notification mode (channel-specific vocabulary).
    public var reactionNotifications: String?
    /// Agent reaction level (channel-specific vocabulary).
    public var reactionLevel: String?
    /// Post a room introduction when joining a group (default `true` where supported).
    public var joinIntro: Bool?
    /// Whether group messages must mention the bot (default `true`).
    public var requireMention: Bool?
    /// Per-group overrides keyed by group id or `"*"`.
    public var groups: [String: ChannelGroupConfig]?
    /// Mention patterns (a string list or a `{mode, allowIn, denyIn}` policy), kept raw.
    public var mentionPatterns: AnyCodable?
    /// Heartbeat visibility.
    public var heartbeatVisibility: ChannelHeartbeatVisibilityConfig?
    /// Typing indicator mode (SDK extension; upstream sets it per agent).
    public var typingMode: ChannelTypingMode?
    /// Typing keepalive interval in milliseconds (SDK extension).
    public var typingIntervalMs: Int?

    /// Creates messaging policy settings; every field defaults to `nil` (upstream defaults apply).
    /// - Parameters:
    ///   - dmPolicy: Direct-message policy.
    ///   - allowFrom: Sender allowlist.
    ///   - groupPolicy: Group policy.
    ///   - groupAllowFrom: Group sender allowlist.
    ///   - requireMention: Whether group messages must mention the bot.
    ///   - textChunkLimit: Outbound chunk limit.
    ///   - streaming: Streaming settings.
    ///   - ackReaction: Acknowledgement reaction emoji.
    ///   - ackReactionScope: Acknowledgement reaction scope.
    ///   - allowBots: Whether bot messages are admitted.
    ///   - botLoopProtection: Loop guard settings.
    ///   - groups: Per-group overrides.
    public init(
        dmPolicy: ChannelDMPolicy? = nil,
        allowFrom: [String]? = nil,
        groupPolicy: ChannelGroupPolicy? = nil,
        groupAllowFrom: [String]? = nil,
        requireMention: Bool? = nil,
        textChunkLimit: Int? = nil,
        streaming: ChannelStreamingConfig? = nil,
        ackReaction: String? = nil,
        ackReactionScope: ChannelAckReactionScope? = nil,
        allowBots: ChannelAllowBots? = nil,
        botLoopProtection: ChannelBotLoopProtectionConfig? = nil,
        groups: [String: ChannelGroupConfig]? = nil
    ) {
        self.dmPolicy = dmPolicy
        self.allowFrom = allowFrom
        self.groupPolicy = groupPolicy
        self.groupAllowFrom = groupAllowFrom
        self.requireMention = requireMention
        self.textChunkLimit = textChunkLimit
        self.streaming = streaming
        self.ackReaction = ackReaction
        self.ackReactionScope = ackReactionScope
        self.allowBots = allowBots
        self.botLoopProtection = botLoopProtection
        self.groups = groups
    }

    /// Effective direct-message policy (upstream root default `pairing`).
    public var effectiveDMPolicy: ChannelDMPolicy {
        self.dmPolicy ?? .pairing
    }

    /// Effective group policy (upstream root default `allowlist`).
    public var effectiveGroupPolicy: ChannelGroupPolicy {
        self.groupPolicy ?? .allowlist
    }

    /// Effective acknowledgement reaction scope (upstream default `group-mentions`).
    public var effectiveAckReactionScope: ChannelAckReactionScope {
        self.ackReactionScope ?? .groupMentions
    }

    /// Effective chunking mode (default `length`).
    public var effectiveChunkMode: ChannelTextChunkMode {
        self.streaming?.chunkMode ?? .length
    }

    /// Keys this policy reads from a channel object.
    public static let codingKeyNames: Set<String> = [
        "name", "configWrites", "dmPolicy", "allowFrom", "groupPolicy", "groupAllowFrom", "defaultTo",
        "textChunkLimit", "streaming", "chunkMode", "blockStreaming", "blockStreamingCoalesce", "mediaMaxMb",
        "replyToMode", "responsePrefix", "historyLimit", "dmHistoryLimit", "contextVisibility", "markdown",
        "implicitMentions", "botLoopProtection", "allowBots", "ackReaction", "ackReactionScope",
        "reactionNotifications", "reactionLevel", "joinIntro", "requireMention", "groups", "mentionPatterns",
        "heartbeatVisibility", "typingMode", "typingIntervalMs",
    ]

    /// Decodes the policy flat from a channel object, mapping retired flat streaming keys.
    /// - Parameter decoder: Decoder positioned at the channel object.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.init(reader: &reader)
    }

    init(reader: inout ChannelConfigReader) {
        self.name = reader.value(String.self, "name")
        self.configWrites = reader.value(Bool.self, "configWrites")
        self.dmPolicy = reader.value(ChannelDMPolicy.self, "dmPolicy")
        self.allowFrom = reader.stringList("allowFrom")
        self.groupPolicy = reader.value(ChannelGroupPolicy.self, "groupPolicy")
        self.groupAllowFrom = reader.stringList("groupAllowFrom")
        self.defaultTo = reader.value(ChannelLooseStringEntry.self, "defaultTo")?.value
        self.textChunkLimit = reader.value(Int.self, "textChunkLimit")
        var streaming = reader.value(ChannelStreamingConfig.self, "streaming")
        if let chunkMode = reader.value(ChannelTextChunkMode.self, "chunkMode") {
            reader.recordIssue("Moved legacy `chunkMode` into `streaming.chunkMode`.", kind: .legacyKey, forKey: "chunkMode")
            var value = streaming ?? ChannelStreamingConfig()
            value.chunkMode = value.chunkMode ?? chunkMode
            streaming = value
        }
        if let blockStreaming = reader.value(Bool.self, "blockStreaming") {
            reader.recordIssue(
                "Moved legacy `blockStreaming` into `streaming.block.enabled`.",
                kind: .legacyKey,
                forKey: "blockStreaming"
            )
            var value = streaming ?? ChannelStreamingConfig()
            var block = value.block ?? ChannelStreamingBlockConfig()
            block.enabled = block.enabled ?? blockStreaming
            value.block = block
            streaming = value
        }
        if let coalesce = reader.value(ChannelBlockStreamingCoalesceConfig.self, "blockStreamingCoalesce") {
            reader.recordIssue(
                "Moved legacy `blockStreamingCoalesce` into `streaming.block.coalesce`.",
                kind: .legacyKey,
                forKey: "blockStreamingCoalesce"
            )
            var value = streaming ?? ChannelStreamingConfig()
            var block = value.block ?? ChannelStreamingBlockConfig()
            block.coalesce = block.coalesce ?? coalesce
            value.block = block
            streaming = value
        }
        self.streaming = streaming
        self.mediaMaxMb = reader.value(Double.self, "mediaMaxMb")
        self.replyToMode = reader.value(ChannelReplyToMode.self, "replyToMode")
        self.responsePrefix = reader.value(String.self, "responsePrefix")
        self.historyLimit = reader.value(Int.self, "historyLimit")
        self.dmHistoryLimit = reader.value(Int.self, "dmHistoryLimit")
        self.contextVisibility = reader.value(ChannelContextVisibility.self, "contextVisibility")
        self.markdown = reader.value(ChannelMarkdownConfig.self, "markdown")
        self.implicitMentions = reader.value(ChannelImplicitMentionsConfig.self, "implicitMentions")
        self.botLoopProtection = reader.value(ChannelBotLoopProtectionConfig.self, "botLoopProtection")
        self.allowBots = reader.value(ChannelAllowBots.self, "allowBots")
        self.ackReaction = reader.value(String.self, "ackReaction")
        self.ackReactionScope = reader.value(ChannelAckReactionScope.self, "ackReactionScope")
        self.reactionNotifications = reader.value(String.self, "reactionNotifications")
        self.reactionLevel = reader.value(String.self, "reactionLevel")
        self.joinIntro = reader.value(Bool.self, "joinIntro")
        self.requireMention = reader.value(Bool.self, "requireMention")
        self.groups = reader.value([String: ChannelGroupConfig].self, "groups")
        self.mentionPatterns = reader.value(AnyCodable.self, "mentionPatterns")
        self.heartbeatVisibility = reader.value(ChannelHeartbeatVisibilityConfig.self, "heartbeatVisibility")
        self.typingMode = reader.value(ChannelTypingMode.self, "typingMode")
        self.typingIntervalMs = reader.value(Int.self, "typingIntervalMs")
    }

    /// Encodes the policy flat into a channel object.
    /// - Parameter encoder: Encoder positioned at the channel object.
    public func encode(to encoder: Encoder) throws {
        try self.encode(to: encoder, excluding: [])
    }

    /// Encodes the policy flat, skipping keys a channel encodes under its own Swift names.
    /// - Parameters:
    ///   - encoder: Encoder positioned at the channel object.
    ///   - excluded: Keys to skip.
    public func encode(to encoder: Encoder, excluding excluded: Set<String>) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        func put<T: Encodable>(_ value: T?, _ key: String) throws {
            guard !excluded.contains(key) else { return }
            try writer.encodeIfPresent(value, key)
        }
        try put(self.name, "name")
        try put(self.configWrites, "configWrites")
        try put(self.dmPolicy, "dmPolicy")
        try put(self.allowFrom, "allowFrom")
        try put(self.groupPolicy, "groupPolicy")
        try put(self.groupAllowFrom, "groupAllowFrom")
        try put(self.defaultTo, "defaultTo")
        try put(self.textChunkLimit, "textChunkLimit")
        try put(self.streaming, "streaming")
        try put(self.mediaMaxMb, "mediaMaxMb")
        try put(self.replyToMode, "replyToMode")
        try put(self.responsePrefix, "responsePrefix")
        try put(self.historyLimit, "historyLimit")
        try put(self.dmHistoryLimit, "dmHistoryLimit")
        try put(self.contextVisibility, "contextVisibility")
        try put(self.markdown, "markdown")
        try put(self.implicitMentions, "implicitMentions")
        try put(self.botLoopProtection, "botLoopProtection")
        try put(self.allowBots, "allowBots")
        try put(self.ackReaction, "ackReaction")
        try put(self.ackReactionScope, "ackReactionScope")
        try put(self.reactionNotifications, "reactionNotifications")
        try put(self.reactionLevel, "reactionLevel")
        try put(self.joinIntro, "joinIntro")
        try put(self.requireMention, "requireMention")
        try put(self.groups, "groups")
        try put(self.mentionPatterns, "mentionPatterns")
        try put(self.heartbeatVisibility, "heartbeatVisibility")
        try put(self.typingMode, "typingMode")
        try put(self.typingIntervalMs, "typingIntervalMs")
    }

    /// Returns the group override for a group id, falling back to the `"*"` wildcard entry.
    /// - Parameter groupID: Platform group id.
    /// - Returns: Matching group override, or `nil`.
    public func groupConfig(for groupID: String?) -> ChannelGroupConfig? {
        guard let groups else { return nil }
        if let groupID, let exact = groups[groupID] {
            return exact
        }
        return groups["*"]
    }
}

/// Channel-wide defaults (upstream `channels.defaults`).
public struct ChannelDefaultsConfig: Codable, Sendable, Equatable, Hashable {
    /// Default group policy inherited by channels that support groups.
    public var groupPolicy: ChannelGroupPolicy?
    /// Default context visibility.
    public var contextVisibility: ChannelContextVisibility?
    /// Default heartbeat visibility.
    public var heartbeatVisibility: ChannelHeartbeatVisibilityConfig?
    /// Default bot loop guard settings.
    public var botLoopProtection: ChannelBotLoopProtectionConfig?
    /// Default implicit mention settings.
    public var implicitMentions: ChannelImplicitMentionsConfig?

    /// Creates channel defaults.
    /// - Parameters:
    ///   - groupPolicy: Default group policy.
    ///   - contextVisibility: Default context visibility.
    ///   - heartbeatVisibility: Default heartbeat visibility.
    ///   - botLoopProtection: Default loop guard settings.
    ///   - implicitMentions: Default implicit mention settings.
    public init(
        groupPolicy: ChannelGroupPolicy? = nil,
        contextVisibility: ChannelContextVisibility? = nil,
        heartbeatVisibility: ChannelHeartbeatVisibilityConfig? = nil,
        botLoopProtection: ChannelBotLoopProtectionConfig? = nil,
        implicitMentions: ChannelImplicitMentionsConfig? = nil
    ) {
        self.groupPolicy = groupPolicy
        self.contextVisibility = contextVisibility
        self.heartbeatVisibility = heartbeatVisibility
        self.botLoopProtection = botLoopProtection
        self.implicitMentions = implicitMentions
    }

    /// Whether no default is set.
    public var isEmpty: Bool {
        self == ChannelDefaultsConfig()
    }

    /// Decodes defaults leniently; the doctor-only legacy `heartbeat` maps to `heartbeatVisibility`.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.groupPolicy = reader.value(ChannelGroupPolicy.self, "groupPolicy")
        self.contextVisibility = reader.value(ChannelContextVisibility.self, "contextVisibility")
        self.heartbeatVisibility = reader.value(ChannelHeartbeatVisibilityConfig.self, "heartbeatVisibility")
        if self.heartbeatVisibility == nil,
           let legacy = reader.value(ChannelHeartbeatVisibilityConfig.self, "heartbeat")
        {
            reader.recordIssue(
                "Moved legacy `channels.defaults.heartbeat` into `heartbeatVisibility`.",
                kind: .legacyKey,
                forKey: "heartbeat"
            )
            self.heartbeatVisibility = legacy
        }
        self.botLoopProtection = reader.value(ChannelBotLoopProtectionConfig.self, "botLoopProtection")
        self.implicitMentions = reader.value(ChannelImplicitMentionsConfig.self, "implicitMentions")
    }

    /// Encodes the set defaults.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encodeIfPresent(self.groupPolicy, "groupPolicy")
        try writer.encodeIfPresent(self.contextVisibility, "contextVisibility")
        try writer.encodeIfPresent(self.heartbeatVisibility, "heartbeatVisibility")
        try writer.encodeIfPresent(self.botLoopProtection, "botLoopProtection")
        try writer.encodeIfPresent(self.implicitMentions, "implicitMentions")
    }
}

/// One account override inside `channels.<id>.accounts`, kept as raw upstream-shaped JSON.
///
/// Account values merge over the channel root per key (see
/// ``ChannelSectionConfig/resolvedAccount(_:)``); only keys the account sets override the root.
public struct ChannelAccountOverride: Codable, Sendable, Equatable, Hashable {
    /// Raw account keys.
    public var values: [String: AnyCodable]

    /// Creates an account override.
    /// - Parameter values: Raw account keys.
    public init(values: [String: AnyCodable] = [:]) {
        self.values = values
    }

    /// Decodes the raw account object.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        self.values = try [String: AnyCodable](from: decoder)
    }

    /// Encodes the raw account object.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        try self.values.encode(to: encoder)
    }

    /// Returns a raw value.
    public subscript(key: String) -> AnyCodable? {
        get { self.values[key] }
        set { self.values[key] = newValue }
    }

    /// Whether the account is enabled (upstream: enabled unless `enabled: false`).
    public var isEnabled: Bool {
        self.values["enabled"]?.boolValue ?? true
    }
}

/// Common shape of every typed `channels.<id>` section.
public protocol ChannelSectionConfig: Codable, Sendable, Equatable {
    /// Whether the channel is enabled. Decoding a present section without `enabled` yields `true`
    /// (upstream semantics); memberwise initializers default to `false`.
    var enabled: Bool { get set }
    /// Shared messaging policy keys.
    var policy: ChannelMessagingPolicyConfig { get set }
    /// Per-account overrides keyed by account id.
    var accounts: [String: ChannelAccountOverride] { get set }
    /// Default account id when several accounts are configured.
    var defaultAccount: String? { get set }
    /// Upstream keys without a typed SDK field, preserved losslessly.
    var additionalProperties: [String: AnyCodable] { get set }
    /// Key spellings that name the same setting (SDK name first); used for account merges.
    static var keyAliasGroups: [[String]] { get }
    /// Policy with channel-specific fields (for example `mentionOnly`) folded in.
    var effectivePolicy: ChannelMessagingPolicyConfig { get }
}

public extension ChannelSectionConfig {
    /// Configured account ids, sorted.
    var accountIDs: [String] {
        self.accounts.keys.sorted()
    }

    /// Account id used when none is specified (`defaultAccount`, else `"default"`).
    var resolvedDefaultAccountID: String {
        let trimmed = self.defaultAccount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "default" : trimmed.lowercased()
    }

    /// Resolves one account: account keys override root keys (upstream `mergeAccountConfig`).
    ///
    /// `nil` resolves ``resolvedDefaultAccountID``. When no account entry matches, the root config
    /// is returned unchanged. Policy root defaults are applied by the `effective…` accessors, so an
    /// account inherits the root's explicit `dmPolicy`/`groupPolicy` unless it sets its own.
    /// - Parameter id: Account id (case-insensitive).
    /// - Returns: The merged account config.
    func resolvedAccount(_ id: String?) -> Self {
        let requested = id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = (requested?.isEmpty == false ? requested : nil) ?? self.resolvedDefaultAccountID
        guard let match = self.accounts.first(where: { $0.key.lowercased() == key }) else {
            return self
        }
        guard let root = ChannelConfigJSON.object(from: self) else {
            return self
        }
        let merged = ChannelConfigJSON.mergeAccount(root: root, account: match.value.values, aliasGroups: Self.keyAliasGroups)
        guard var resolved = ChannelConfigJSON.decode(Self.self, from: merged) else {
            return self
        }
        resolved.accounts = [:]
        resolved.defaultAccount = nil
        return resolved
    }

    /// Effective policy for one account.
    /// - Parameter accountID: Account id (`nil` uses the default account).
    /// - Returns: The merged policy.
    func effectivePolicy(accountID: String?) -> ChannelMessagingPolicyConfig {
        self.resolvedAccount(accountID).effectivePolicy
    }
}

/// Decoding/encoding support shared by the typed channel sections.
enum ChannelSectionCoding {
    static func encodeCommon(
        to encoder: Encoder,
        policy: ChannelMessagingPolicyConfig,
        excluding: Set<String>,
        accounts: [String: ChannelAccountOverride],
        defaultAccount: String?,
        additionalProperties: [String: AnyCodable],
        written: Set<String>
    ) throws {
        try policy.encode(to: encoder, excluding: excluding)
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encodeIfNotEmpty(accounts, "accounts")
        try writer.encodeIfPresent(defaultAccount, "defaultAccount")
        let skip = written
            .union(ChannelMessagingPolicyConfig.codingKeyNames)
            .union(["accounts", "defaultAccount"])
        try writer.encodePassthrough(additionalProperties, skipping: skip)
    }
}
