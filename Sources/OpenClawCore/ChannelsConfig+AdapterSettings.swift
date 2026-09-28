import Foundation
import OpenClawProtocol

// Typed accessors for upstream 2026.9.6 channel keys that the native adapters read.
//
// These keys stay in each section's `additionalProperties`, so upstream documents round-trip
// byte-for-byte (import, export and account merges keep working without new coding keys); the
// accessors below decode them leniently and write them back on assignment.

extension [String: AnyCodable] {
    func channelDecoded<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let value = self[key] else { return nil }
        return ChannelConfigJSON.decode(type, fromAny: value)
    }

    mutating func setChannelEncoded(_ value: (some Encodable)?, forKey key: String) {
        guard let value, let encoded = try? AnyCodable(encoding: value), !encoded.isNull else {
            self.removeValue(forKey: key)
            return
        }
        self[key] = encoded
    }

    func channelBool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    func channelStringList(_ key: String) -> [String]? {
        guard let array = self[key]?.arrayValue else { return nil }
        return array.compactMap { value in
            if let string = value.stringValue { return string }
            if let integer = value.int64Value { return String(integer) }
            return nil
        }
    }
}

public extension ChannelSectionConfig {
    /// Per-action toggles from the section's upstream `actions` object (for example Telegram
    /// `editMessage`, `deleteMessage`, `poll`, `reactions`). Missing keys mean enabled.
    var actionToggles: [String: Bool] {
        (self.additionalProperties["actions"]?.dictionaryValue ?? [:]).compactMapValues(\.boolValue)
    }
}

// MARK: - Discord

/// Discord gateway intents switches (upstream `channels.discord.intents`).
public struct DiscordIntentsConfig: Codable, Sendable, Equatable, Hashable {
    /// Request the privileged Message Content intent (default `true`).
    public var messageContent: Bool?
    /// Request the privileged Guild Presences intent (default `false`).
    public var presence: Bool?
    /// Request the privileged Guild Members intent (default `false`).
    public var guildMembers: Bool?

    /// Creates intent switches.
    /// - Parameters:
    ///   - messageContent: Message Content intent.
    ///   - presence: Guild Presences intent.
    ///   - guildMembers: Guild Members intent.
    public init(messageContent: Bool? = nil, presence: Bool? = nil, guildMembers: Bool? = nil) {
        self.messageContent = messageContent
        self.presence = presence
        self.guildMembers = guildMembers
    }
}

/// Discord direct-message switches (upstream `channels.discord.dm`, also used by Slack).
public struct ChannelDirectMessageConfig: Codable, Sendable, Equatable, Hashable {
    /// Whether direct messages are processed (default `true`).
    public var enabled: Bool?
    /// Whether group DMs are processed (default `false`).
    public var groupEnabled: Bool?
    /// Optional group DM channel allowlist.
    public var groupChannels: [String]?

    /// Creates DM switches.
    /// - Parameters:
    ///   - enabled: Whether DMs are processed.
    ///   - groupEnabled: Whether group DMs are processed.
    ///   - groupChannels: Group DM allowlist.
    public init(enabled: Bool? = nil, groupEnabled: Bool? = nil, groupChannels: [String]? = nil) {
        self.enabled = enabled
        self.groupEnabled = groupEnabled
        self.groupChannels = groupChannels
    }

    /// Decodes DM switches leniently (numbers in `groupChannels` are stringified).
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled")
        self.groupEnabled = reader.value(Bool.self, "groupEnabled")
        self.groupChannels = reader.stringList("groupChannels")
    }
}

/// Per-room override shared by Discord guild channels and Slack channels.
public struct ChannelRoomOverrideConfig: Codable, Sendable, Equatable, Hashable {
    /// Whether the bot is enabled in the room.
    public var enabled: Bool?
    /// Whether messages must mention the bot.
    public var requireMention: Bool?
    /// Drop messages that mention other identities but not the bot.
    public var ignoreOtherMentions: Bool?
    /// Sender allowlist.
    public var users: [String]?
    /// Reply threading override (Slack).
    public var replyToMode: ChannelReplyToMode?
    /// Nested channel overrides (Discord guilds).
    public var channels: [String: ChannelRoomOverrideConfig]?

    /// Creates a room override.
    /// - Parameters:
    ///   - enabled: Whether the bot is enabled.
    ///   - requireMention: Whether a mention is required.
    ///   - ignoreOtherMentions: Drop messages addressed to others.
    ///   - users: Sender allowlist.
    public init(enabled: Bool? = nil, requireMention: Bool? = nil, ignoreOtherMentions: Bool? = nil, users: [String]? = nil) {
        self.enabled = enabled
        self.requireMention = requireMention
        self.ignoreOtherMentions = ignoreOtherMentions
        self.users = users
        self.replyToMode = nil
        self.channels = nil
    }

    /// Decodes a room override leniently.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled")
        self.requireMention = reader.value(Bool.self, "requireMention")
        self.ignoreOtherMentions = reader.value(Bool.self, "ignoreOtherMentions")
        self.users = reader.stringList("users")
        self.replyToMode = reader.value(ChannelReplyToMode.self, "replyToMode")
        self.channels = reader.value([String: ChannelRoomOverrideConfig].self, "channels")
    }
}

/// Discord inbound transport (SDK extension key `transport`).
public enum DiscordTransportMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Gateway WebSocket `MESSAGE_CREATE` ingestion (default).
    case gateway
    /// Legacy REST polling of `defaultChannelID` (pre-2026.3.0 behavior).
    case restPolling = "rest-polling"
}

/// Discord bot presence status (upstream `channels.discord.status`).
public enum DiscordPresenceStatus: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Online.
    case online
    /// Do not disturb.
    case dnd
    /// Idle.
    case idle
    /// Invisible.
    case invisible
}

public extension DiscordChannelConfig {
    /// Inbound transport (default ``DiscordTransportMode/gateway``).
    var transport: DiscordTransportMode {
        get { self.additionalProperties.channelDecoded(DiscordTransportMode.self, forKey: "transport") ?? .gateway }
        set { self.additionalProperties.setChannelEncoded(newValue == .gateway ? nil : newValue, forKey: "transport") }
    }

    /// Gateway intents switches.
    var intents: DiscordIntentsConfig {
        get { self.additionalProperties.channelDecoded(DiscordIntentsConfig.self, forKey: "intents") ?? DiscordIntentsConfig() }
        set { self.additionalProperties.setChannelEncoded(newValue == DiscordIntentsConfig() ? nil : newValue, forKey: "intents") }
    }

    /// Suppress link embeds on outbound messages (default `true`, Discord `SUPPRESS_EMBEDS` flag).
    var suppressEmbeds: Bool {
        get { self.additionalProperties.channelBool("suppressEmbeds") ?? true }
        set { self.additionalProperties.setChannelEncoded(newValue ? nil : false, forKey: "suppressEmbeds") }
    }

    /// Soft maximum lines per outbound message (default 17).
    var maxLinesPerMessage: Int {
        get { max(1, self.additionalProperties["maxLinesPerMessage"]?.intValue ?? 17) }
        set { self.additionalProperties.setChannelEncoded(newValue == 17 ? nil : newValue, forKey: "maxLinesPerMessage") }
    }

    /// Outbound `@handle` → user id rewrites (keys without the leading `@`).
    var mentionAliases: [String: String] {
        get { self.additionalProperties.channelDecoded([String: String].self, forKey: "mentionAliases") ?? [:] }
        set { self.additionalProperties.setChannelEncoded(newValue.isEmpty ? nil : newValue, forKey: "mentionAliases") }
    }

    /// Direct-message switches.
    var dm: ChannelDirectMessageConfig {
        get { self.additionalProperties.channelDecoded(ChannelDirectMessageConfig.self, forKey: "dm") ?? ChannelDirectMessageConfig() }
        set { self.additionalProperties.setChannelEncoded(newValue == ChannelDirectMessageConfig() ? nil : newValue, forKey: "dm") }
    }

    /// Per-guild overrides keyed by guild id or slug.
    var guilds: [String: ChannelRoomOverrideConfig] {
        get { self.additionalProperties.channelDecoded([String: ChannelRoomOverrideConfig].self, forKey: "guilds") ?? [:] }
        set { self.additionalProperties.setChannelEncoded(newValue.isEmpty ? nil : newValue, forKey: "guilds") }
    }

    /// Presence status.
    var status: DiscordPresenceStatus? {
        get { self.additionalProperties.channelDecoded(DiscordPresenceStatus.self, forKey: "status") }
        set { self.additionalProperties.setChannelEncoded(newValue, forKey: "status") }
    }

    /// Presence activity text.
    var activity: String? {
        get { self.additionalProperties["activity"]?.stringValue }
        set { self.additionalProperties.setChannelEncoded(newValue, forKey: "activity") }
    }

    /// Activity type 0-5 (defaults to 4, Custom, when ``activity`` is set).
    var activityType: Int? {
        get { self.additionalProperties["activityType"]?.intValue.flatMap { (0...5).contains($0) ? $0 : nil } }
        set { self.additionalProperties.setChannelEncoded(newValue, forKey: "activityType") }
    }

    /// Streaming URL used when ``activityType`` is 1.
    var activityURL: String? {
        get { self.additionalProperties["activityUrl"]?.stringValue }
        set { self.additionalProperties.setChannelEncoded(newValue, forKey: "activityUrl") }
    }
}

// MARK: - Slack

/// Slack reply threading per chat type (upstream `replyToModeByChatType`).
public struct ChannelReplyToModeByChatType: Codable, Sendable, Equatable, Hashable {
    /// Direct messages.
    public var direct: ChannelReplyToMode?
    /// Group conversations (Slack MPIMs, Signal groups).
    public var group: ChannelReplyToMode?
    /// Channels.
    public var channel: ChannelReplyToMode?

    /// Creates per-chat-type modes.
    /// - Parameters:
    ///   - direct: Direct messages.
    ///   - group: Group conversations.
    ///   - channel: Channels.
    public init(direct: ChannelReplyToMode? = nil, group: ChannelReplyToMode? = nil, channel: ChannelReplyToMode? = nil) {
        self.direct = direct
        self.group = group
        self.channel = channel
    }

    /// Decodes leniently (invalid entries are dropped).
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.direct = reader.value(ChannelReplyToMode.self, "direct")
        self.group = reader.value(ChannelReplyToMode.self, "group")
        self.channel = reader.value(ChannelReplyToMode.self, "channel")
    }
}

public extension SlackChannelConfig {
    /// Drop room messages that mention other users or groups but not the bot (default `false`).
    var ignoreOtherMentions: Bool {
        get { self.additionalProperties.channelBool("ignoreOtherMentions") ?? false }
        set { self.additionalProperties.setChannelEncoded(newValue ? true : nil, forKey: "ignoreOtherMentions") }
    }

    /// Reply threading per chat type.
    var replyToModeByChatType: ChannelReplyToModeByChatType {
        get {
            self.additionalProperties.channelDecoded(ChannelReplyToModeByChatType.self, forKey: "replyToModeByChatType")
                ?? ChannelReplyToModeByChatType()
        }
        set {
            self.additionalProperties.setChannelEncoded(
                newValue == ChannelReplyToModeByChatType() ? nil : newValue,
                forKey: "replyToModeByChatType"
            )
        }
    }

    /// Per-channel overrides keyed by channel id.
    var channels: [String: ChannelRoomOverrideConfig] {
        get { self.additionalProperties.channelDecoded([String: ChannelRoomOverrideConfig].self, forKey: "channels") ?? [:] }
        set { self.additionalProperties.setChannelEncoded(newValue.isEmpty ? nil : newValue, forKey: "channels") }
    }

    /// Direct-message switches.
    var dm: ChannelDirectMessageConfig {
        get { self.additionalProperties.channelDecoded(ChannelDirectMessageConfig.self, forKey: "dm") ?? ChannelDirectMessageConfig() }
        set { self.additionalProperties.setChannelEncoded(newValue == ChannelDirectMessageConfig() ? nil : newValue, forKey: "dm") }
    }
}

// MARK: - Signal

public extension SignalChannelConfig {
    /// Account UUID used to drop self-authored messages (loop protection).
    var accountUUID: String? {
        get { self.additionalProperties["accountUuid"]?.stringValue }
        set { self.additionalProperties.setChannelEncoded(newValue, forKey: "accountUuid") }
    }

    /// Send read receipts for accepted inbound messages (default `false`).
    var sendReadReceipts: Bool {
        get { self.additionalProperties.channelBool("sendReadReceipts") ?? false }
        set { self.additionalProperties.setChannelEncoded(newValue ? true : nil, forKey: "sendReadReceipts") }
    }

    /// Skip inbound attachments (default `false`).
    var ignoreAttachments: Bool {
        get { self.additionalProperties.channelBool("ignoreAttachments") ?? false }
        set { self.additionalProperties.setChannelEncoded(newValue ? true : nil, forKey: "ignoreAttachments") }
    }

    /// Reply quoting per chat type.
    var replyToModeByChatType: ChannelReplyToModeByChatType {
        get {
            self.additionalProperties.channelDecoded(ChannelReplyToModeByChatType.self, forKey: "replyToModeByChatType")
                ?? ChannelReplyToModeByChatType()
        }
        set {
            self.additionalProperties.setChannelEncoded(
                newValue == ChannelReplyToModeByChatType() ? nil : newValue,
                forKey: "replyToModeByChatType"
            )
        }
    }

    /// Resolved transport kind (``SignalTransportKind/container`` when unset, the Swift default).
    var resolvedTransportKind: SignalTransportKind {
        self.transport?.kind ?? .container
    }
}

// MARK: - Microsoft Teams

public extension MicrosoftTeamsChannelConfig {
    /// Send `typing` activities while a reply is prepared (default `true`).
    var typingIndicator: Bool {
        get { self.additionalProperties.channelBool("typingIndicator") ?? true }
        set { self.additionalProperties.setChannelEncoded(newValue ? nil : false, forKey: "typingIndicator") }
    }
}

// MARK: - Google Chat

public extension GoogleChatChannelConfig {
    /// Bot display name used for mention detection when `botUser` is unset.
    var botDisplayName: String? {
        self.additionalProperties["botDisplayName"]?.stringValue
    }
}
