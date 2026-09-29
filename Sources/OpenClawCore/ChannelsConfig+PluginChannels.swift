import Foundation
import OpenClawProtocol

/// Read-only view over an upstream-shaped raw channel section.
///
/// Plugin-only channels (Buzz, ClickClack, Raft, Reef, ...) have no Swift transport; these typed
/// helpers let hosts and UIs show configuration state without an adapter.
public protocol RawChannelSettings: Sendable, Equatable {
    /// Upstream channel id.
    static var channelID: String { get }
    /// Creates settings from a raw section.
    /// - Parameter raw: Raw `channels.<id>` object.
    init(raw: [String: AnyCodable])
    /// Raw section the settings were read from.
    var raw: [String: AnyCodable] { get }
}

public extension RawChannelSettings {
    /// Whether the section is enabled (upstream: enabled unless `enabled: false`).
    var enabled: Bool {
        self.raw["enabled"]?.boolValue ?? true
    }

    /// Configured account ids.
    var accountIDs: [String] {
        (self.raw["accounts"]?.dictionaryValue?.keys).map { $0.sorted() } ?? []
    }

    /// Reads a string value.
    /// - Parameter key: Raw key.
    /// - Returns: The trimmed non-empty string, or `nil`.
    func string(_ key: String) -> String? {
        guard let value = self.raw[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Reads a secret input value (string, env template, or SecretRef object).
    /// - Parameter key: Raw key.
    /// - Returns: The secret input, or `nil`.
    func secret(_ key: String) -> SecretInput? {
        self.raw[key].flatMap(ChannelConfigJSON.secretInput(from:))
    }
}

public extension ChannelsConfig {
    /// Returns typed read-only settings for a plugin-only channel section.
    /// - Parameter type: Settings type, for example ``BuzzChannelSettings``.
    /// - Returns: The settings, or `nil` when the section is absent.
    func pluginSettings<Settings: RawChannelSettings>(_ type: Settings.Type) -> Settings? {
        self.rawSection(named: Settings.channelID).map(Settings.init(raw:))
    }
}

/// Buzz team-room channel settings (upstream `extensions/buzz`).
///
/// Buzz identities are Nostr keypairs; the channel is groups-only (no DMs, media or reactions).
public struct BuzzChannelSettings: RawChannelSettings {
    /// Upstream channel id.
    public static let channelID = "buzz"
    /// Raw section.
    public let raw: [String: AnyCodable]

    /// Creates settings from a raw section.
    /// - Parameter raw: Raw `channels.buzz` object.
    public init(raw: [String: AnyCodable]) {
        self.raw = raw
    }

    /// Relay WebSocket URL (`ws://` or `wss://`).
    public var relayURL: String? { self.string("relayUrl") }
    /// Bot Nostr private key.
    public var privateKey: SecretInput? { self.secret("privateKey") }
    /// Relay auth tag.
    public var authTag: SecretInput? { self.secret("authTag") }
    /// Group policy (upstream default `allowlist`).
    public var groupPolicy: ChannelGroupPolicy {
        self.string("groupPolicy").flatMap(ChannelGroupPolicy.init(rawValue:)) ?? .allowlist
    }
    /// Group sender allowlist.
    public var groupAllowFrom: [String] {
        self.raw["groupAllowFrom"]?.arrayValue?.compactMap { $0.stringValue ?? $0.intValue.map(String.init) } ?? []
    }
    /// Group overrides keyed by Buzz channel UUID.
    public var groupIDs: [String] {
        (self.raw["groups"]?.dictionaryValue?.keys).map { $0.sorted() } ?? []
    }
    /// History limit (0...20).
    public var historyLimit: Int? {
        self.raw["historyLimit"]?.intValue.map { min(max(0, $0), 20) }
    }
    /// Reply mode (`off` or `all`).
    public var replyToMode: ChannelReplyToMode? {
        self.string("replyToMode").flatMap(ChannelReplyToMode.init(rawValue:))
    }
    /// Whether the channel has the credentials it needs.
    public var isConfigured: Bool {
        self.relayURL != nil && self.privateKey != nil
    }
}

/// ClickClack self-hosted chat settings (upstream `extensions/clickclack`).
public struct ClickClackChannelSettings: RawChannelSettings {
    /// Upstream channel id.
    public static let channelID = "clickclack"
    /// Raw section.
    public let raw: [String: AnyCodable]

    /// Creates settings from a raw section.
    /// - Parameter raw: Raw `channels.clickclack` object.
    public init(raw: [String: AnyCodable]) {
        self.raw = raw
    }

    /// Workspace base URL.
    public var baseURL: String? { self.string("baseUrl") }
    /// API base URL.
    public var apiBaseURL: String? { self.string("apiBaseUrl") }
    /// Bot token.
    public var token: SecretInput? { self.secret("token") }
    /// Token file path.
    public var tokenFile: String? { self.string("tokenFile") }
    /// Workspace id.
    public var workspace: String? { self.string("workspace") }
    /// Bot user id.
    public var botUserID: String? { self.string("botUserId") }
    /// Routed agent id.
    public var agentID: String? { self.string("agentId") }
    /// Reply mode (`agent` or `model`).
    public var replyMode: String? { self.string("replyMode") }
    /// Sender allowlist.
    public var allowFrom: [String] {
        self.raw["allowFrom"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
    /// Whether bot messages are admitted.
    public var allowBots: ChannelAllowBots? {
        self.raw["allowBots"].flatMap { ChannelConfigJSON.decode(ChannelAllowBots.self, fromAny: $0) }
    }
    /// Loop guard settings.
    public var botLoopProtection: ChannelBotLoopProtectionConfig? {
        self.raw["botLoopProtection"].flatMap { ChannelConfigJSON.decode(ChannelBotLoopProtectionConfig.self, fromAny: $0) }
    }
    /// Reconnect delay in milliseconds (100...60000).
    public var reconnectMs: Int? {
        self.raw["reconnectMs"]?.intValue.map { min(max(100, $0), 60_000) }
    }
    /// Whether messages must mention the bot.
    public var requireMention: Bool? { self.raw["requireMention"]?.boolValue }
    /// Mention patterns.
    public var mentionPatterns: [String] {
        self.raw["mentionPatterns"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
    /// Group override ids.
    public var groupIDs: [String] {
        (self.raw["groups"]?.dictionaryValue?.keys).map { $0.sorted() } ?? []
    }
    /// Whether discussions are enabled.
    public var discussionsEnabled: Bool {
        self.raw["discussions"]?.dictionaryValue?["enabled"]?.boolValue ?? false
    }
    /// Whether the channel has the credentials it needs.
    public var isConfigured: Bool {
        self.baseURL != nil && (self.token != nil || self.tokenFile != nil)
    }
}

/// Raft CLI wake bridge settings (upstream `extensions/raft`; direct only, no stored credentials).
public struct RaftChannelSettings: RawChannelSettings {
    /// Upstream channel id.
    public static let channelID = "raft"
    /// Raw section.
    public let raw: [String: AnyCodable]

    /// Creates settings from a raw section.
    /// - Parameter raw: Raw `channels.raft` object.
    public init(raw: [String: AnyCodable]) {
        self.raw = raw
    }

    /// Raft CLI profile.
    public var profile: String? { self.string("profile") }
    /// Whether a profile is configured.
    public var isConfigured: Bool {
        self.profile != nil
    }
}

/// Reef guarded claw channel settings (upstream `extensions/reef`).
public struct ReefChannelSettings: RawChannelSettings {
    /// Friend-request policy.
    public enum RequestPolicy: String, Sendable, Equatable, CaseIterable {
        /// Only requests with an invite code.
        case codeOnly = "code-only"
        /// Friends of existing friends.
        case friendsOfFriends = "friends-of-friends"
        /// Anyone.
        case open
    }

    /// Guard (screening model) settings.
    public struct Guard: Sendable, Equatable {
        /// Screening model provider (`openai` or `anthropic`).
        public var provider: String?
        /// Auth mode (`oauth` or `api-key`).
        public var authMode: String?
        /// Environment variable holding the provider API key.
        public var apiKeyEnv: String?
        /// OAuth auth profile id.
        public var authProfileID: String?
        /// Pinned screening model.
        public var pinnedModel: String?
        /// Policy version.
        public var policyVersion: String?
        /// Screening timeout in milliseconds.
        public var timeoutMs: Int?
        /// Whether custom inbound/outbound rules are set.
        public var hasRules: Bool
    }

    /// Upstream channel id.
    public static let channelID = "reef"
    /// Raw section.
    public let raw: [String: AnyCodable]

    /// Creates settings from a raw section.
    /// - Parameter raw: Raw `channels.reef` object.
    public init(raw: [String: AnyCodable]) {
        self.raw = raw
    }

    /// Relay origin (default `https://reefwire.ai`).
    public var relayURL: String { self.string("relayUrl") ?? "https://reefwire.ai" }
    /// Reef handle.
    public var handle: String? { self.string("handle") }
    /// Contact email.
    public var email: String? { self.string("email") }
    /// State directory.
    public var stateDir: String? { self.string("stateDir") }
    /// Friend-request policy (default `code-only`).
    public var requestPolicy: RequestPolicy {
        self.string("requestPolicy").flatMap(RequestPolicy.init(rawValue:)) ?? .codeOnly
    }
    /// Guard settings.
    public var guardSettings: Guard? {
        guard let object = self.raw["guard"]?.dictionaryValue else { return nil }
        return Guard(
            provider: object["provider"]?.stringValue,
            authMode: object["authMode"]?.stringValue,
            apiKeyEnv: object["apiKeyEnv"]?.stringValue,
            authProfileID: object["authProfileId"]?.stringValue,
            pinnedModel: object["pinnedModel"]?.stringValue,
            policyVersion: object["policyVersion"]?.stringValue,
            timeoutMs: object["timeoutMs"]?.intValue,
            hasRules: object["rules"]?.dictionaryValue?.isEmpty == false
        )
    }
    /// Whether a handle and guard are configured.
    public var isConfigured: Bool {
        self.handle != nil && self.guardSettings != nil
    }
}
