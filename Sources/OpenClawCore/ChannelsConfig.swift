import Foundation
import OpenClawProtocol

/// Channel adapter related configuration (`channels` section).
///
/// Decoding accepts both the SDK shape and upstream OpenClaw's `channels.*` JSON:
/// - typed sections (`telegram`, `discord`, `slack`, `googlechat`, `signal`, `imessage`,
///   `msteams`, plus the SDK-only `whatsappCloud`, `webchat` and deprecated `bluebubbles`) accept
///   upstream key aliases, SecretRef objects, env templates, `accounts`/`defaultAccount` and the
///   shared messaging policy keys (``ChannelMessagingPolicyConfig``);
/// - `defaults` and `modelByChannel` are typed;
/// - every other `channels.<id>` object (for example `sms`, `a2a`, `matrix`, and upstream
///   `whatsapp`, which is WhatsApp *Web* config and never maps to ``whatsappCloud``) is kept in
///   ``extensionChannels`` and written back unchanged.
///
/// - Note: A present section without `enabled` decodes as enabled (upstream: enabled unless
///   `enabled: false`); memberwise initializers keep defaulting to disabled.
public struct ChannelsConfig: Codable, Sendable, Equatable {
    /// Discord settings.
    public var discord: DiscordChannelConfig
    /// Telegram settings.
    public var telegram: TelegramChannelConfig
    /// WhatsApp Cloud API settings (SDK-only; upstream `whatsapp` is WhatsApp Web).
    public var whatsappCloud: WhatsAppCloudChannelConfig
    /// Slack settings.
    public var slack: SlackChannelConfig
    /// Google Chat settings (encoded as `googlechat`).
    public var googleChat: GoogleChatChannelConfig
    /// Signal settings.
    public var signal: SignalChannelConfig
    /// BlueBubbles settings. Removed upstream; migrate with ``migrateBlueBubblesToIMessage()``.
    public var bluebubbles: LegacyBlueBubblesChannelConfig
    /// iMessage settings.
    public var imessage: IMessageChannelConfig
    /// Microsoft Teams settings.
    public var msteams: MicrosoftTeamsChannelConfig
    /// SDK WebChat settings (upstream retired `channels.webchat`; never emitted upstream).
    public var webchat: WebChatChannelConfig
    /// Legacy SDK wrapper for plugin-only channels (kept for back-compat).
    public var pluginChannels: [String: PluginChannelConfig]
    /// Shared channel defaults (upstream `channels.defaults`).
    public var defaults: ChannelDefaultsConfig
    /// Model overrides: channel id → peer/account/group key → model ref (upstream `modelByChannel`).
    public var modelByChannel: [String: [String: String]]
    /// Upstream-shaped `channels.<id>` objects without a typed SDK section, round-tripped as-is.
    public var extensionChannels: [String: AnyCodable]
    /// SDK-only migration switches for the 2026.3.0 channel behavior changes.
    public var compatibility: ChannelsCompatibilityConfig

    /// Creates channel config.
    /// - Parameters:
    ///   - discord: Discord channel settings.
    ///   - telegram: Telegram channel settings.
    ///   - whatsappCloud: WhatsApp Cloud API channel settings.
    ///   - slack: Slack channel settings.
    ///   - googleChat: Google Chat channel settings.
    ///   - signal: Signal channel settings.
    ///   - bluebubbles: BlueBubbles channel settings (deprecated).
    ///   - imessage: iMessage channel settings.
    ///   - msteams: Microsoft Teams channel settings.
    ///   - webchat: WebChat channel settings.
    ///   - pluginChannels: Metadata/config blocks for upstream plugin-only channels.
    ///   - defaults: Shared channel defaults.
    ///   - modelByChannel: Per-channel model overrides.
    ///   - extensionChannels: Raw upstream sections for channels without typed SDK config.
    ///   - compatibility: SDK migration switches.
    public init(
        discord: DiscordChannelConfig = DiscordChannelConfig(),
        telegram: TelegramChannelConfig = TelegramChannelConfig(),
        whatsappCloud: WhatsAppCloudChannelConfig = WhatsAppCloudChannelConfig(),
        slack: SlackChannelConfig = SlackChannelConfig(),
        googleChat: GoogleChatChannelConfig = GoogleChatChannelConfig(),
        signal: SignalChannelConfig = SignalChannelConfig(),
        bluebubbles: LegacyBlueBubblesChannelConfig = LegacyBlueBubblesChannelConfig(),
        imessage: IMessageChannelConfig = IMessageChannelConfig(),
        msteams: MicrosoftTeamsChannelConfig = MicrosoftTeamsChannelConfig(),
        webchat: WebChatChannelConfig = WebChatChannelConfig(),
        pluginChannels: [String: PluginChannelConfig] = [:],
        defaults: ChannelDefaultsConfig = ChannelDefaultsConfig(),
        modelByChannel: [String: [String: String]] = [:],
        extensionChannels: [String: AnyCodable] = [:],
        compatibility: ChannelsCompatibilityConfig = ChannelsCompatibilityConfig()
    ) {
        self.discord = discord
        self.telegram = telegram
        self.whatsappCloud = whatsappCloud
        self.slack = slack
        self.googleChat = googleChat
        self.signal = signal
        self.bluebubbles = bluebubbles
        self.imessage = imessage
        self.msteams = msteams
        self.webchat = webchat
        self.pluginChannels = pluginChannels
        self.defaults = defaults
        self.modelByChannel = modelByChannel
        self.extensionChannels = extensionChannels
        self.compatibility = compatibility
    }

    /// Top-level keys the SDK decodes into typed fields; every other key is an extension channel.
    public static let typedSectionKeys: Set<String> = [
        "discord", "telegram", "whatsappCloud", "slack", "googlechat", "googleChat", "signal", "bluebubbles",
        "imessage", "msteams", "webchat", "pluginChannels", "defaults", "modelByChannel", "compatibility",
    ]

    /// Decodes SDK-shaped or upstream-shaped channel config without failing on one bad section.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.discord = reader.value(DiscordChannelConfig.self, "discord") ?? DiscordChannelConfig()
        self.telegram = reader.value(TelegramChannelConfig.self, "telegram") ?? TelegramChannelConfig()
        self.whatsappCloud = reader.value(WhatsAppCloudChannelConfig.self, "whatsappCloud") ?? WhatsAppCloudChannelConfig()
        self.slack = reader.value(SlackChannelConfig.self, "slack") ?? SlackChannelConfig()
        self.googleChat = reader.value(GoogleChatChannelConfig.self, "googlechat", "googleChat") ?? GoogleChatChannelConfig()
        self.signal = reader.value(SignalChannelConfig.self, "signal") ?? SignalChannelConfig()
        self.bluebubbles = reader.value(LegacyBlueBubblesChannelConfig.self, "bluebubbles") ?? LegacyBlueBubblesChannelConfig()
        self.imessage = reader.value(IMessageChannelConfig.self, "imessage") ?? IMessageChannelConfig()
        self.msteams = reader.value(MicrosoftTeamsChannelConfig.self, "msteams") ?? MicrosoftTeamsChannelConfig()
        self.webchat = reader.value(WebChatChannelConfig.self, "webchat") ?? WebChatChannelConfig()
        self.pluginChannels = reader.container.decodeLossyDictionaryIfPresent(
            PluginChannelConfig.self,
            forKey: ChannelConfigKey("pluginChannels")
        ) ?? [:]
        reader.consume(["pluginChannels"])
        self.defaults = reader.value(ChannelDefaultsConfig.self, "defaults") ?? ChannelDefaultsConfig()
        self.modelByChannel = reader.value([String: [String: String]].self, "modelByChannel") ?? [:]
        self.compatibility = reader.value(ChannelsCompatibilityConfig.self, "compatibility") ?? ChannelsCompatibilityConfig()
        self.extensionChannels = reader.remaining(excluding: Self.typedSectionKeys)
    }

    /// Encodes typed sections under their SDK keys and extension channels under their own ids.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.discord, "discord")
        try writer.encode(self.telegram, "telegram")
        try writer.encode(self.whatsappCloud, "whatsappCloud")
        try writer.encode(self.slack, "slack")
        try writer.encode(self.googleChat, "googlechat")
        try writer.encode(self.signal, "signal")
        try writer.encode(self.bluebubbles, "bluebubbles")
        try writer.encode(self.imessage, "imessage")
        try writer.encode(self.msteams, "msteams")
        try writer.encode(self.webchat, "webchat")
        try writer.encode(self.pluginChannels, "pluginChannels")
        if !self.defaults.isEmpty {
            try writer.encode(self.defaults, "defaults")
        }
        try writer.encodeIfNotEmpty(self.modelByChannel, "modelByChannel")
        if self.compatibility != ChannelsCompatibilityConfig() {
            try writer.encode(self.compatibility, "compatibility")
        }
        try writer.encodePassthrough(self.extensionChannels, skipping: Self.typedSectionKeys)
    }

    /// Returns the raw upstream section for a channel id without a typed SDK section.
    ///
    /// Looks up ``extensionChannels`` by id (case-insensitive), then falls back to the legacy
    /// ``pluginChannels`` wrapper's ``PluginChannelConfig/raw`` block.
    /// - Parameter channelID: Upstream channel id (for example `sms`).
    /// - Returns: The raw JSON object, or `nil`.
    public func rawSection(named channelID: String) -> [String: AnyCodable]? {
        let key = channelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = self.extensionChannels[key]?.dictionaryValue {
            return exact
        }
        if let match = self.extensionChannels.first(where: { $0.key.lowercased() == key })?.value.dictionaryValue {
            return match
        }
        if let plugin = self.pluginChannels.first(where: { $0.key.lowercased() == key })?.value, !plugin.raw.isEmpty {
            return plugin.raw
        }
        return nil
    }

    /// Returns whether a channel section is enabled.
    ///
    /// Typed sections use their `enabled` flag. Raw sections follow upstream semantics (enabled
    /// unless `enabled: false`); absent sections are disabled.
    /// - Parameter channelID: Upstream channel id.
    /// - Returns: `true` when enabled.
    public func isChannelEnabled(_ channelID: String) -> Bool {
        switch channelID.lowercased() {
        case "discord": return self.discord.enabled
        case "telegram": return self.telegram.enabled
        case "whatsapp": return self.whatsappCloud.enabled || self.rawSection(named: "whatsapp")?["enabled"]?.boolValue == true
        case "slack": return self.slack.enabled
        case "googlechat": return self.googleChat.enabled
        case "signal": return self.signal.enabled
        case "bluebubbles": return self.bluebubbles.enabled
        case "imessage": return self.imessage.enabled
        case "msteams": return self.msteams.enabled
        case "webchat": return self.webchat.enabled
        default:
            if let raw = self.rawSection(named: channelID) {
                return raw["enabled"]?.boolValue ?? true
            }
            return self.pluginChannels.first { $0.key.lowercased() == channelID.lowercased() }?.value.enabled ?? false
        }
    }

    /// Resolves the messaging policy for one channel and account, applying `channels.defaults`.
    ///
    /// Typed sections contribute their ``ChannelSectionConfig/effectivePolicy``; other channels
    /// decode the policy keys from their raw section. Channel values win over `defaults`.
    /// - Parameters:
    ///   - channelID: Upstream channel id.
    ///   - accountID: Account id (`nil` uses the channel's default account).
    /// - Returns: The resolved policy.
    public func messagingPolicy(for channelID: String, accountID: String? = nil) -> ChannelMessagingPolicyConfig {
        var policy: ChannelMessagingPolicyConfig
        switch channelID.lowercased() {
        case "discord": policy = self.discord.effectivePolicy(accountID: accountID)
        case "telegram": policy = self.telegram.effectivePolicy(accountID: accountID)
        case "whatsapp": policy = self.whatsappCloud.effectivePolicy(accountID: accountID)
        case "slack": policy = self.slack.effectivePolicy(accountID: accountID)
        case "googlechat": policy = self.googleChat.effectivePolicy(accountID: accountID)
        case "signal": policy = self.signal.effectivePolicy(accountID: accountID)
        case "bluebubbles": policy = self.bluebubbles.effectivePolicy(accountID: accountID)
        case "imessage": policy = self.imessage.effectivePolicy(accountID: accountID)
        case "msteams": policy = self.msteams.effectivePolicy(accountID: accountID)
        case "webchat": policy = self.webchat.effectivePolicy(accountID: accountID)
        case "a2a": policy = self.a2a.effectivePolicy
        default:
            policy = self.rawSection(named: channelID).map { raw in
                Self.rawPolicy(raw, accountID: accountID)
            } ?? ChannelMessagingPolicyConfig()
        }
        policy.groupPolicy = policy.groupPolicy ?? self.defaults.groupPolicy
        policy.contextVisibility = policy.contextVisibility ?? self.defaults.contextVisibility
        policy.heartbeatVisibility = policy.heartbeatVisibility ?? self.defaults.heartbeatVisibility
        if let defaultsMentions = self.defaults.implicitMentions {
            policy.implicitMentions = defaultsMentions.merged(with: policy.implicitMentions)
        }
        policy.botLoopProtection = ChannelBotLoopProtectionConfig.merge([
            self.defaults.botLoopProtection,
            policy.botLoopProtection,
        ])
        return policy
    }

    private static func rawPolicy(_ raw: [String: AnyCodable], accountID: String?) -> ChannelMessagingPolicyConfig {
        var object = raw
        let requested = accountID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let defaultAccount = raw["defaultAccount"]?.stringValue?.lowercased()
        let key = (requested?.isEmpty == false ? requested : nil) ?? defaultAccount ?? "default"
        if let accounts = raw["accounts"]?.dictionaryValue,
           let account = accounts.first(where: { $0.key.lowercased() == key })?.value.dictionaryValue
        {
            object = ChannelConfigJSON.mergeAccount(root: raw, account: account, aliasGroups: [])
        }
        return ChannelConfigJSON.decode(ChannelMessagingPolicyConfig.self, from: object) ?? ChannelMessagingPolicyConfig()
    }
}

/// How ingress access policy is applied by the SDK auto-reply pipeline.
public enum ChannelIngressAccessMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Enforce upstream `dmPolicy`/`groupPolicy`/`requireMention` (default since 2026.3.0).
    case enforce
    /// Pre-2026.3.0 behavior: admit every inbound message (not recommended).
    case legacyAllowAll = "legacy-allow-all"
}

/// SDK-only switches that restore pre-2026.3.0 channel behavior during migration.
public struct ChannelsCompatibilityConfig: Codable, Sendable, Equatable, Hashable {
    /// Route sessions with the sender id in the account slot, like 2026.2 and earlier.
    ///
    /// 2026.3.0 fixed `InboundMessage.accountID` to mean the channel account key (upstream
    /// `accountId`) and moved the human sender to `senderID`. Session keys therefore change from
    /// `telegram:<senderID>:<peerID>` to `telegram:<peerID>` for the built-in adapters. Set this to `true` for one
    /// release to keep existing session keys (and conversation memory) stable.
    public var legacySessionAccountKeys: Bool
    /// Whether ingress access policy is enforced (default ``ChannelIngressAccessMode/enforce``).
    public var ingressAccessPolicy: ChannelIngressAccessMode

    /// Creates compatibility switches.
    /// - Parameters:
    ///   - legacySessionAccountKeys: Keep pre-2026.3.0 session keys.
    ///   - ingressAccessPolicy: Ingress access mode.
    public init(legacySessionAccountKeys: Bool = false, ingressAccessPolicy: ChannelIngressAccessMode = .enforce) {
        self.legacySessionAccountKeys = legacySessionAccountKeys
        self.ingressAccessPolicy = ingressAccessPolicy
    }

    /// Decodes switches leniently.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.legacySessionAccountKeys = reader.value(Bool.self, "legacySessionAccountKeys") ?? false
        self.ingressAccessPolicy = reader.value(ChannelIngressAccessMode.self, "ingressAccessPolicy") ?? .enforce
    }
}

/// Generic config block for upstream plugin-only channels (legacy SDK wrapper).
public struct PluginChannelConfig: Codable, Sendable, Equatable {
    /// Whether the host should attempt to activate this channel plugin.
    public var enabled: Bool
    /// Upstream package name.
    public var packageName: String?
    /// Non-secret plugin config values (flattened to strings).
    public var config: [String: String]
    /// Secret values or secret references.
    public var secrets: [String: String]
    /// Lossless upstream-shaped section, when known.
    public var raw: [String: AnyCodable]

    /// Creates plugin-channel settings.
    /// - Parameters:
    ///   - enabled: Whether the host should attempt to activate this channel plugin.
    ///   - packageName: Optional upstream package/plugin package name.
    ///   - config: Non-secret plugin config values.
    ///   - secrets: Secret values or secret references required by the plugin.
    ///   - raw: Lossless upstream-shaped section.
    public init(
        enabled: Bool = false,
        packageName: String? = nil,
        config: [String: String] = [:],
        secrets: [String: String] = [:],
        raw: [String: AnyCodable] = [:]
    ) {
        self.enabled = enabled
        self.packageName = packageName
        self.config = config
        self.secrets = secrets
        self.raw = raw
    }

    /// Decodes plugin-channel settings; missing keys use defaults.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? false
        self.packageName = reader.value(String.self, "packageName")
        self.config = reader.value([String: String].self, "config") ?? [:]
        self.secrets = reader.value([String: String].self, "secrets") ?? [:]
        self.raw = reader.value([String: AnyCodable].self, "raw") ?? [:]
    }

    /// Encodes plugin-channel settings.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encodeIfPresent(self.packageName, "packageName")
        try writer.encode(self.config, "config")
        try writer.encode(self.secrets, "secrets")
        try writer.encodeIfNotEmpty(self.raw, "raw")
    }
}

// MARK: - Discord

/// Discord adapter configuration.
public struct DiscordChannelConfig: ChannelSectionConfig {
    /// Enables Discord adapter startup.
    public var enabled: Bool
    /// Bot token (upstream `token`; plaintext, env template or SecretRef).
    public var botTokenInput: SecretInput?
    /// Default channel ID for polling/sends (upstream `defaultTo`).
    public var defaultChannelID: String?
    /// Poll interval in milliseconds.
    public var pollIntervalMs: Int
    /// Enables Discord gateway presence lifecycle.
    public var presenceEnabled: Bool
    /// Processes guild messages only when the bot is mentioned (upstream `requireMention`).
    public var mentionOnly: Bool
    /// Shared messaging policy keys.
    public var policy: ChannelMessagingPolicyConfig
    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride]
    /// Default account id.
    public var defaultAccount: String?
    /// Upstream keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Plaintext bot token (`nil` when the token is a SecretRef; resolve with ``ChannelSecretResolver``).
    public var botToken: String? {
        get { self.botTokenInput?.stringValue }
        set { self.botTokenInput = newValue.map(SecretInput.string) }
    }

    /// Creates Discord channel settings.
    /// - Parameters:
    ///   - enabled: Enables Discord adapter startup.
    ///   - botToken: Bot token used for API auth.
    ///   - defaultChannelID: Default channel ID for polling/sends.
    ///   - pollIntervalMs: Poll interval in milliseconds.
    ///   - presenceEnabled: Enables Discord gateway presence lifecycle.
    ///   - mentionOnly: Processes messages only when bot is explicitly mentioned.
    ///   - policy: Shared messaging policy keys.
    public init(
        enabled: Bool = false,
        botToken: String? = nil,
        defaultChannelID: String? = nil,
        pollIntervalMs: Int = 2_000,
        presenceEnabled: Bool = true,
        mentionOnly: Bool = true,
        policy: ChannelMessagingPolicyConfig = ChannelMessagingPolicyConfig()
    ) {
        self.enabled = enabled
        self.botTokenInput = botToken.map(SecretInput.string)
        self.defaultChannelID = defaultChannelID
        self.pollIntervalMs = max(250, pollIntervalMs)
        self.presenceEnabled = presenceEnabled
        self.mentionOnly = mentionOnly
        self.policy = policy
        self.accounts = [:]
        self.defaultAccount = nil
        self.additionalProperties = [:]
    }

    /// Key spellings that name the same setting.
    public static let keyAliasGroups: [[String]] = [
        ["botToken", "token"], ["defaultChannelID", "defaultTo"], ["mentionOnly", "requireMention"],
    ]

    private static let writtenKeys: Set<String> = [
        "enabled", "botToken", "token", "defaultChannelID", "defaultTo", "pollIntervalMs", "presenceEnabled",
        "mentionOnly", "requireMention",
    ]

    /// Policy with `mentionOnly` and `defaultChannelID` folded in.
    public var effectivePolicy: ChannelMessagingPolicyConfig {
        var policy = self.policy
        policy.requireMention = self.mentionOnly
        policy.defaultTo = self.defaultChannelID ?? policy.defaultTo
        return policy
    }

    /// Decodes SDK or upstream-shaped Discord settings.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? true
        self.botTokenInput = reader.secret("botToken", "token")
        self.defaultChannelID = reader.value(ChannelLooseStringEntry.self, "defaultChannelID", "defaultTo")?.value
        self.pollIntervalMs = max(250, reader.value(Int.self, "pollIntervalMs") ?? 2_000)
        self.presenceEnabled = reader.value(Bool.self, "presenceEnabled") ?? true
        self.mentionOnly = reader.value(Bool.self, "mentionOnly", "requireMention") ?? true
        reader.retired("retry", reason: "Discord send retries are handled by the channel registry.")
        self.policy = ChannelMessagingPolicyConfig(reader: &reader)
        self.accounts = reader.value([String: ChannelAccountOverride].self, "accounts") ?? [:]
        self.defaultAccount = reader.value(String.self, "defaultAccount")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes Discord settings with SDK key names.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encodeIfPresent(self.botTokenInput, "botToken")
        try writer.encodeIfPresent(self.defaultChannelID, "defaultChannelID")
        try writer.encode(self.pollIntervalMs, "pollIntervalMs")
        try writer.encode(self.presenceEnabled, "presenceEnabled")
        try writer.encode(self.mentionOnly, "mentionOnly")
        try ChannelSectionCoding.encodeCommon(
            to: encoder,
            policy: self.policy,
            excluding: ["defaultTo", "requireMention"],
            accounts: self.accounts,
            defaultAccount: self.defaultAccount,
            additionalProperties: self.additionalProperties,
            written: Self.writtenKeys
        )
    }
}

// MARK: - Telegram

/// Telegram adapter configuration.
public struct TelegramChannelConfig: ChannelSectionConfig {
    /// Enables Telegram adapter startup.
    public var enabled: Bool
    /// Bot token (plaintext, env template or SecretRef).
    public var botTokenInput: SecretInput?
    /// Path to a regular file that contains the bot token (upstream `tokenFile`).
    public var tokenFile: String?
    /// Webhook secret token (plaintext, env template or SecretRef).
    public var webhookSecretInput: SecretInput?
    /// Default chat ID for polling/sends (upstream `defaultTo`).
    public var defaultChatID: String?
    /// Poll interval in milliseconds.
    public var pollIntervalMs: Int
    /// Processes group messages only when the bot is mentioned (upstream `requireMention`).
    public var mentionOnly: Bool
    /// Telegram Bot API base URL (upstream `apiRoot`).
    public var baseURL: String
    /// Use Bot API rich messages (upstream `richMessages`; raises the chunk limit to 32768).
    public var richMessages: Bool
    /// Shared messaging policy keys.
    public var policy: ChannelMessagingPolicyConfig
    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride]
    /// Default account id.
    public var defaultAccount: String?
    /// Upstream keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Plaintext bot token (`nil` when the token is a SecretRef).
    public var botToken: String? {
        get { self.botTokenInput?.stringValue }
        set { self.botTokenInput = newValue.map(SecretInput.string) }
    }

    /// Plaintext webhook secret (`nil` when unset or a SecretRef).
    public var webhookSecret: String? {
        get { self.webhookSecretInput?.stringValue }
        set { self.webhookSecretInput = newValue.map(SecretInput.string) }
    }

    /// Creates Telegram channel settings.
    /// - Parameters:
    ///   - enabled: Enables Telegram adapter startup.
    ///   - botToken: Bot token used for API auth.
    ///   - defaultChatID: Default chat ID for polling/sends.
    ///   - pollIntervalMs: Poll interval in milliseconds.
    ///   - mentionOnly: Processes group messages only when bot is explicitly mentioned.
    ///   - baseURL: Telegram Bot API base URL.
    ///   - tokenFile: Path to a file containing the bot token.
    ///   - webhookSecret: Webhook secret token.
    ///   - richMessages: Use Bot API rich messages.
    ///   - policy: Shared messaging policy keys.
    public init(
        enabled: Bool = false,
        botToken: String? = nil,
        defaultChatID: String? = nil,
        pollIntervalMs: Int = 2_000,
        mentionOnly: Bool = true,
        baseURL: String = "https://api.telegram.org",
        tokenFile: String? = nil,
        webhookSecret: String? = nil,
        richMessages: Bool = false,
        policy: ChannelMessagingPolicyConfig = ChannelMessagingPolicyConfig()
    ) {
        self.enabled = enabled
        self.botTokenInput = botToken.map(SecretInput.string)
        self.tokenFile = tokenFile
        self.webhookSecretInput = webhookSecret.map(SecretInput.string)
        self.defaultChatID = defaultChatID
        self.pollIntervalMs = max(250, pollIntervalMs)
        self.mentionOnly = mentionOnly
        self.baseURL = baseURL
        self.richMessages = richMessages
        self.policy = policy
        self.accounts = [:]
        self.defaultAccount = nil
        self.additionalProperties = [:]
    }

    /// Key spellings that name the same setting.
    public static let keyAliasGroups: [[String]] = [
        ["defaultChatID", "defaultTo"], ["mentionOnly", "requireMention"], ["baseURL", "apiRoot"],
    ]

    private static let writtenKeys: Set<String> = [
        "enabled", "botToken", "tokenFile", "webhookSecret", "defaultChatID", "defaultTo", "pollIntervalMs",
        "mentionOnly", "requireMention", "baseURL", "apiRoot", "richMessages",
    ]

    /// Policy with `mentionOnly` and `defaultChatID` folded in.
    public var effectivePolicy: ChannelMessagingPolicyConfig {
        var policy = self.policy
        policy.requireMention = self.mentionOnly
        policy.defaultTo = self.defaultChatID ?? policy.defaultTo
        return policy
    }

    /// Decodes SDK or upstream-shaped Telegram settings.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? true
        self.botTokenInput = reader.secret("botToken")
        self.tokenFile = reader.value(String.self, "tokenFile")
        self.webhookSecretInput = reader.secret("webhookSecret")
        self.defaultChatID = reader.value(ChannelLooseStringEntry.self, "defaultChatID", "defaultTo")?.value
        self.pollIntervalMs = max(250, reader.value(Int.self, "pollIntervalMs") ?? 2_000)
        self.mentionOnly = reader.value(Bool.self, "mentionOnly", "requireMention") ?? true
        self.baseURL = reader.value(String.self, "baseURL", "apiRoot") ?? "https://api.telegram.org"
        self.richMessages = reader.value(Bool.self, "richMessages") ?? false
        reader.retired(
            "timeoutSeconds",
            "pollingStallThresholdMs",
            "retry",
            "errorCooldownMs",
            reason: "Telegram polling timeouts, retries and cooldowns are no longer configurable upstream."
        )
        self.policy = ChannelMessagingPolicyConfig(reader: &reader)
        self.accounts = reader.value([String: ChannelAccountOverride].self, "accounts") ?? [:]
        self.defaultAccount = reader.value(String.self, "defaultAccount")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes Telegram settings with SDK key names.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encodeIfPresent(self.botTokenInput, "botToken")
        try writer.encodeIfPresent(self.tokenFile, "tokenFile")
        try writer.encodeIfPresent(self.webhookSecretInput, "webhookSecret")
        try writer.encodeIfPresent(self.defaultChatID, "defaultChatID")
        try writer.encode(self.pollIntervalMs, "pollIntervalMs")
        try writer.encode(self.mentionOnly, "mentionOnly")
        try writer.encode(self.baseURL, "baseURL")
        if self.richMessages {
            try writer.encode(self.richMessages, "richMessages")
        }
        try ChannelSectionCoding.encodeCommon(
            to: encoder,
            policy: self.policy,
            excluding: ["defaultTo", "requireMention"],
            accounts: self.accounts,
            defaultAccount: self.defaultAccount,
            additionalProperties: self.additionalProperties,
            written: Self.writtenKeys
        )
    }
}

// MARK: - WhatsApp Cloud

/// WhatsApp Cloud API adapter configuration (SDK-only `channels.whatsappCloud`).
///
/// Upstream `channels.whatsapp` configures WhatsApp *Web* (Baileys) and is kept in
/// ``ChannelsConfig/extensionChannels``; it never maps onto this section.
public struct WhatsAppCloudChannelConfig: ChannelSectionConfig {
    /// Enables WhatsApp Cloud adapter startup.
    public var enabled: Bool
    /// Cloud API access token (plaintext, env template or SecretRef).
    public var accessTokenInput: SecretInput?
    /// WhatsApp phone number ID for send APIs.
    public var phoneNumberID: String?
    /// Optional business account identifier.
    public var businessAccountID: String?
    /// Webhook verify token (plaintext, env template or SecretRef).
    public var webhookVerifyTokenInput: SecretInput?
    /// Webhook path exposed by the host app.
    public var webhookPath: String
    /// Graph API base URL.
    public var baseURL: String
    /// Graph API version segment.
    public var apiVersion: String
    /// Shared messaging policy keys.
    public var policy: ChannelMessagingPolicyConfig
    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride]
    /// Default account id.
    public var defaultAccount: String?
    /// Keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Plaintext access token (`nil` when unset or a SecretRef).
    public var accessToken: String? {
        get { self.accessTokenInput?.stringValue }
        set { self.accessTokenInput = newValue.map(SecretInput.string) }
    }

    /// Plaintext webhook verify token (`nil` when unset or a SecretRef).
    public var webhookVerifyToken: String? {
        get { self.webhookVerifyTokenInput?.stringValue }
        set { self.webhookVerifyTokenInput = newValue.map(SecretInput.string) }
    }

    /// Creates WhatsApp Cloud API channel settings.
    /// - Parameters:
    ///   - enabled: Enables WhatsApp Cloud adapter startup.
    ///   - accessToken: Cloud API access token.
    ///   - phoneNumberID: WhatsApp phone number ID for send APIs.
    ///   - businessAccountID: Optional business account identifier.
    ///   - webhookVerifyToken: Verify token used during webhook setup.
    ///   - webhookPath: Webhook path exposed by host app.
    ///   - baseURL: Graph API base URL.
    ///   - apiVersion: Graph API version segment.
    ///   - policy: Shared messaging policy keys.
    public init(
        enabled: Bool = false,
        accessToken: String? = nil,
        phoneNumberID: String? = nil,
        businessAccountID: String? = nil,
        webhookVerifyToken: String? = nil,
        webhookPath: String = "/webhooks/whatsapp",
        baseURL: String = "https://graph.facebook.com",
        apiVersion: String = "v20.0",
        policy: ChannelMessagingPolicyConfig = ChannelMessagingPolicyConfig()
    ) {
        self.enabled = enabled
        self.accessTokenInput = accessToken.map(SecretInput.string)
        self.phoneNumberID = phoneNumberID
        self.businessAccountID = businessAccountID
        self.webhookVerifyTokenInput = webhookVerifyToken.map(SecretInput.string)
        self.webhookPath = webhookPath
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.policy = policy
        self.accounts = [:]
        self.defaultAccount = nil
        self.additionalProperties = [:]
    }

    /// Key spellings that name the same setting.
    public static let keyAliasGroups: [[String]] = [
        ["phoneNumberID", "phoneNumberId"], ["businessAccountID", "businessAccountId"], ["baseURL", "baseUrl"],
    ]

    private static let writtenKeys: Set<String> = [
        "enabled", "accessToken", "phoneNumberID", "phoneNumberId", "businessAccountID", "businessAccountId",
        "webhookVerifyToken", "webhookPath", "baseURL", "baseUrl", "apiVersion",
    ]

    /// Policy for WhatsApp Cloud messages.
    public var effectivePolicy: ChannelMessagingPolicyConfig {
        self.policy
    }

    /// Decodes WhatsApp Cloud settings; missing keys use defaults.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        // SDK-only section: keeps the pre-2026.3.0 disabled-by-default decode.
        self.enabled = reader.value(Bool.self, "enabled") ?? false
        self.accessTokenInput = reader.secret("accessToken")
        self.phoneNumberID = reader.value(ChannelLooseStringEntry.self, "phoneNumberID", "phoneNumberId")?.value
        self.businessAccountID = reader.value(ChannelLooseStringEntry.self, "businessAccountID", "businessAccountId")?.value
        self.webhookVerifyTokenInput = reader.secret("webhookVerifyToken")
        self.webhookPath = reader.value(String.self, "webhookPath") ?? "/webhooks/whatsapp"
        self.baseURL = reader.value(String.self, "baseURL", "baseUrl") ?? "https://graph.facebook.com"
        self.apiVersion = reader.value(String.self, "apiVersion") ?? "v20.0"
        self.policy = ChannelMessagingPolicyConfig(reader: &reader)
        self.accounts = reader.value([String: ChannelAccountOverride].self, "accounts") ?? [:]
        self.defaultAccount = reader.value(String.self, "defaultAccount")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes WhatsApp Cloud settings.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encodeIfPresent(self.accessTokenInput, "accessToken")
        try writer.encodeIfPresent(self.phoneNumberID, "phoneNumberID")
        try writer.encodeIfPresent(self.businessAccountID, "businessAccountID")
        try writer.encodeIfPresent(self.webhookVerifyTokenInput, "webhookVerifyToken")
        try writer.encode(self.webhookPath, "webhookPath")
        try writer.encode(self.baseURL, "baseURL")
        try writer.encode(self.apiVersion, "apiVersion")
        try ChannelSectionCoding.encodeCommon(
            to: encoder,
            policy: self.policy,
            excluding: [],
            accounts: self.accounts,
            defaultAccount: self.defaultAccount,
            additionalProperties: self.additionalProperties,
            written: Self.writtenKeys
        )
    }
}

// MARK: - Slack

/// Slack connection mode (upstream `channels.slack.mode`).
public enum SlackConnectionMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Socket Mode (default).
    case socket
    /// HTTP Events API.
    case http
    /// Relay through an OpenClaw relay gateway.
    case relay
    /// Legacy SDK-only `conversations.history` polling of `defaultChannelID` (pre-2026.3.0 behavior).
    ///
    /// The adapter also falls back to polling when `mode` is ``socket`` but no app token is set.
    case poll
}

/// Slack relay settings (upstream `channels.slack.relay`).
public struct SlackRelayConfig: Codable, Sendable, Equatable {
    /// Relay URL.
    public var url: String?
    /// Relay auth token (plaintext, env template or SecretRef).
    public var authTokenInput: SecretInput?
    /// Relay gateway id.
    public var gatewayID: String?

    /// Plaintext relay auth token.
    public var authToken: String? {
        get { self.authTokenInput?.stringValue }
        set { self.authTokenInput = newValue.map(SecretInput.string) }
    }

    /// Creates relay settings.
    /// - Parameters:
    ///   - url: Relay URL.
    ///   - authToken: Relay auth token.
    ///   - gatewayID: Relay gateway id.
    public init(url: String? = nil, authToken: String? = nil, gatewayID: String? = nil) {
        self.url = url
        self.authTokenInput = authToken.map(SecretInput.string)
        self.gatewayID = gatewayID
    }

    /// Decodes relay settings (upstream `gatewayId`).
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.url = reader.value(String.self, "url")
        self.authTokenInput = reader.secret("authToken")
        self.gatewayID = reader.value(String.self, "gatewayId", "gatewayID")
    }

    /// Encodes relay settings with upstream keys.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encodeIfPresent(self.url, "url")
        try writer.encodeIfPresent(self.authTokenInput, "authToken")
        try writer.encodeIfPresent(self.gatewayID, "gatewayId")
    }
}

/// Slack adapter configuration.
public struct SlackChannelConfig: ChannelSectionConfig {
    /// Enables Slack adapter startup.
    public var enabled: Bool
    /// Bot OAuth token (plaintext, env template or SecretRef).
    public var botTokenInput: SecretInput?
    /// App-level token for Socket Mode.
    public var appTokenInput: SecretInput?
    /// Signing secret for HTTP request validation.
    public var signingSecretInput: SecretInput?
    /// User token.
    public var userTokenInput: SecretInput?
    /// Default channel ID for outbound sends (upstream `defaultTo`).
    public var defaultChannelID: String?
    /// Limits processing to explicit bot mentions (upstream `requireMention`).
    public var mentionOnly: Bool
    /// Slack Web API base URL.
    public var baseURL: String
    /// Connection mode (default ``SlackConnectionMode/socket``).
    public var mode: SlackConnectionMode
    /// Relay settings for ``SlackConnectionMode/relay``.
    public var relay: SlackRelayConfig?
    /// HTTP Events path (default `/slack/events`).
    public var webhookPath: String
    /// Reaction used as a typing indicator.
    public var typingReaction: String?
    /// Unfurl links in outbound messages (default `false`).
    public var unfurlLinks: Bool
    /// Unfurl media in outbound messages.
    public var unfurlMedia: Bool?
    /// Shared messaging policy keys.
    public var policy: ChannelMessagingPolicyConfig
    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride]
    /// Default account id.
    public var defaultAccount: String?
    /// Upstream keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Plaintext bot token.
    public var botToken: String? {
        get { self.botTokenInput?.stringValue }
        set { self.botTokenInput = newValue.map(SecretInput.string) }
    }

    /// Plaintext app token.
    public var appToken: String? {
        get { self.appTokenInput?.stringValue }
        set { self.appTokenInput = newValue.map(SecretInput.string) }
    }

    /// Plaintext signing secret.
    public var signingSecret: String? {
        get { self.signingSecretInput?.stringValue }
        set { self.signingSecretInput = newValue.map(SecretInput.string) }
    }

    /// Plaintext user token.
    public var userToken: String? {
        get { self.userTokenInput?.stringValue }
        set { self.userTokenInput = newValue.map(SecretInput.string) }
    }

    /// Creates Slack channel settings.
    /// - Parameters:
    ///   - enabled: Enables Slack adapter startup.
    ///   - botToken: Slack Bot OAuth token.
    ///   - appToken: Slack App-Level token for socket mode.
    ///   - signingSecret: Slack signing secret for request validation.
    ///   - defaultChannelID: Default channel ID for outbound sends.
    ///   - mentionOnly: Limits processing to explicit bot mentions.
    ///   - baseURL: Slack Web API base URL.
    ///   - mode: Connection mode.
    ///   - webhookPath: HTTP Events path.
    ///   - policy: Shared messaging policy keys.
    public init(
        enabled: Bool = false,
        botToken: String? = nil,
        appToken: String? = nil,
        signingSecret: String? = nil,
        defaultChannelID: String? = nil,
        mentionOnly: Bool = true,
        baseURL: String = "https://slack.com/api",
        mode: SlackConnectionMode = .socket,
        webhookPath: String = "/slack/events",
        policy: ChannelMessagingPolicyConfig = ChannelMessagingPolicyConfig()
    ) {
        self.enabled = enabled
        self.botTokenInput = botToken.map(SecretInput.string)
        self.appTokenInput = appToken.map(SecretInput.string)
        self.signingSecretInput = signingSecret.map(SecretInput.string)
        self.userTokenInput = nil
        self.defaultChannelID = defaultChannelID
        self.mentionOnly = mentionOnly
        self.baseURL = baseURL
        self.mode = mode
        self.relay = nil
        self.webhookPath = webhookPath
        self.typingReaction = nil
        self.unfurlLinks = false
        self.unfurlMedia = nil
        self.policy = policy
        self.accounts = [:]
        self.defaultAccount = nil
        self.additionalProperties = [:]
    }

    /// Key spellings that name the same setting.
    public static let keyAliasGroups: [[String]] = [
        ["defaultChannelID", "defaultTo"], ["mentionOnly", "requireMention"],
    ]

    private static let writtenKeys: Set<String> = [
        "enabled", "botToken", "appToken", "signingSecret", "userToken", "defaultChannelID", "defaultTo",
        "mentionOnly", "requireMention", "baseURL", "mode", "relay", "webhookPath", "typingReaction",
        "unfurlLinks", "unfurlMedia",
    ]

    /// Policy with `mentionOnly` and `defaultChannelID` folded in.
    public var effectivePolicy: ChannelMessagingPolicyConfig {
        var policy = self.policy
        policy.requireMention = self.mentionOnly
        policy.defaultTo = self.defaultChannelID ?? policy.defaultTo
        return policy
    }

    /// Decodes SDK or upstream-shaped Slack settings.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? true
        self.botTokenInput = reader.secret("botToken")
        self.appTokenInput = reader.secret("appToken")
        self.signingSecretInput = reader.secret("signingSecret")
        self.userTokenInput = reader.secret("userToken")
        self.defaultChannelID = reader.value(ChannelLooseStringEntry.self, "defaultChannelID", "defaultTo")?.value
        self.mentionOnly = reader.value(Bool.self, "mentionOnly", "requireMention") ?? true
        self.baseURL = reader.value(String.self, "baseURL") ?? "https://slack.com/api"
        self.mode = reader.value(SlackConnectionMode.self, "mode") ?? .socket
        self.relay = reader.value(SlackRelayConfig.self, "relay")
        self.webhookPath = reader.value(String.self, "webhookPath") ?? "/slack/events"
        self.typingReaction = reader.value(String.self, "typingReaction")
        self.unfurlLinks = reader.value(Bool.self, "unfurlLinks") ?? false
        self.unfurlMedia = reader.value(Bool.self, "unfurlMedia")
        self.policy = ChannelMessagingPolicyConfig(reader: &reader)
        self.accounts = reader.value([String: ChannelAccountOverride].self, "accounts") ?? [:]
        self.defaultAccount = reader.value(String.self, "defaultAccount")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes Slack settings with SDK key names.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encodeIfPresent(self.botTokenInput, "botToken")
        try writer.encodeIfPresent(self.appTokenInput, "appToken")
        try writer.encodeIfPresent(self.signingSecretInput, "signingSecret")
        try writer.encodeIfPresent(self.userTokenInput, "userToken")
        try writer.encodeIfPresent(self.defaultChannelID, "defaultChannelID")
        try writer.encode(self.mentionOnly, "mentionOnly")
        try writer.encode(self.baseURL, "baseURL")
        try writer.encode(self.mode, "mode")
        try writer.encodeIfPresent(self.relay, "relay")
        try writer.encode(self.webhookPath, "webhookPath")
        try writer.encodeIfPresent(self.typingReaction, "typingReaction")
        try writer.encode(self.unfurlLinks, "unfurlLinks")
        try writer.encodeIfPresent(self.unfurlMedia, "unfurlMedia")
        try ChannelSectionCoding.encodeCommon(
            to: encoder,
            policy: self.policy,
            excluding: ["defaultTo", "requireMention"],
            accounts: self.accounts,
            defaultAccount: self.defaultAccount,
            additionalProperties: self.additionalProperties,
            written: Self.writtenKeys
        )
    }
}

// MARK: - Google Chat

/// Google Chat audience type (upstream `audienceType`).
public enum GoogleChatAudienceType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Audience is the app URL.
    case appURL = "app-url"
    /// Audience is the project number.
    case projectNumber = "project-number"
}

/// Google Chat typing indicator mode (upstream `typingIndicator`).
public enum GoogleChatTypingIndicator: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// No typing indicator.
    case none
    /// Post and update a placeholder message.
    case message
    /// React to the inbound message.
    case reaction
}

/// Google Chat adapter configuration.
public struct GoogleChatChannelConfig: ChannelSectionConfig {
    /// Enables Google Chat adapter startup.
    public var enabled: Bool
    /// Bot/service auth bearer token.
    public var bearerTokenInput: SecretInput?
    /// Token used to verify inbound calls.
    public var verificationTokenInput: SecretInput?
    /// Service account (a JSON string, an inline object, or a SecretRef), kept raw.
    public var serviceAccount: AnyCodable?
    /// Path to a service account JSON file.
    public var serviceAccountFile: String?
    /// Default Google Chat space identifier (upstream `defaultTo`).
    public var defaultSpaceID: String?
    /// Google Chat API base URL.
    public var baseURL: String
    /// Host webhook path for inbound events.
    public var webhookPath: String
    /// Polling interval used for fallback polling paths.
    public var pollIntervalMs: Int
    /// Audience type for inbound token verification.
    public var audienceType: GoogleChatAudienceType?
    /// Audience value.
    public var audience: String?
    /// App principal.
    public var appPrincipal: String?
    /// Public webhook URL.
    public var webhookURL: String?
    /// Bot user resource name.
    public var botUser: String?
    /// Typing indicator mode.
    public var typingIndicator: GoogleChatTypingIndicator?
    /// Shared messaging policy keys.
    public var policy: ChannelMessagingPolicyConfig
    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride]
    /// Default account id.
    public var defaultAccount: String?
    /// Upstream keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Plaintext bearer token.
    public var bearerToken: String? {
        get { self.bearerTokenInput?.stringValue }
        set { self.bearerTokenInput = newValue.map(SecretInput.string) }
    }

    /// Plaintext verification token.
    public var verificationToken: String? {
        get { self.verificationTokenInput?.stringValue }
        set { self.verificationTokenInput = newValue.map(SecretInput.string) }
    }

    /// Service account as a secret input: a string or a SecretRef object (`nil` for inline JSON objects).
    public var serviceAccountSecret: SecretInput? {
        guard let serviceAccount else { return nil }
        return ChannelConfigJSON.secretInput(from: serviceAccount)
    }

    /// Creates Google Chat channel settings.
    /// - Parameters:
    ///   - enabled: Enables Google Chat adapter startup.
    ///   - bearerToken: Bot/service auth bearer token.
    ///   - verificationToken: Optional token used to verify inbound calls.
    ///   - defaultSpaceID: Default Google Chat space identifier.
    ///   - baseURL: Google Chat API base URL.
    ///   - webhookPath: Host webhook path for inbound events.
    ///   - pollIntervalMs: Polling interval used for fallback polling paths.
    ///   - policy: Shared messaging policy keys.
    public init(
        enabled: Bool = false,
        bearerToken: String? = nil,
        verificationToken: String? = nil,
        defaultSpaceID: String? = nil,
        baseURL: String = "https://chat.googleapis.com/v1",
        webhookPath: String = "/webhooks/googlechat",
        pollIntervalMs: Int = 2_000,
        policy: ChannelMessagingPolicyConfig = ChannelMessagingPolicyConfig()
    ) {
        self.enabled = enabled
        self.bearerTokenInput = bearerToken.map(SecretInput.string)
        self.verificationTokenInput = verificationToken.map(SecretInput.string)
        self.serviceAccount = nil
        self.serviceAccountFile = nil
        self.defaultSpaceID = defaultSpaceID
        self.baseURL = baseURL
        self.webhookPath = webhookPath
        self.pollIntervalMs = max(250, pollIntervalMs)
        self.audienceType = nil
        self.audience = nil
        self.appPrincipal = nil
        self.webhookURL = nil
        self.botUser = nil
        self.typingIndicator = nil
        self.policy = policy
        self.accounts = [:]
        self.defaultAccount = nil
        self.additionalProperties = [:]
    }

    /// Key spellings that name the same setting.
    public static let keyAliasGroups: [[String]] = [
        ["defaultSpaceID", "defaultTo"], ["webhookURL", "webhookUrl"],
    ]

    private static let writtenKeys: Set<String> = [
        "enabled", "bearerToken", "verificationToken", "serviceAccount", "serviceAccountFile", "defaultSpaceID",
        "defaultTo", "baseURL", "webhookPath", "pollIntervalMs", "audienceType", "audience", "appPrincipal",
        "webhookURL", "webhookUrl", "botUser", "typingIndicator",
    ]

    /// Policy with `defaultSpaceID` folded in.
    public var effectivePolicy: ChannelMessagingPolicyConfig {
        var policy = self.policy
        policy.defaultTo = self.defaultSpaceID ?? policy.defaultTo
        return policy
    }

    /// Decodes SDK or upstream-shaped Google Chat settings.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? true
        self.bearerTokenInput = reader.secret("bearerToken")
        self.verificationTokenInput = reader.secret("verificationToken")
        self.serviceAccount = reader.value(AnyCodable.self, "serviceAccount")
        self.serviceAccountFile = reader.value(String.self, "serviceAccountFile")
        self.defaultSpaceID = reader.value(ChannelLooseStringEntry.self, "defaultSpaceID", "defaultTo")?.value
        self.baseURL = reader.value(String.self, "baseURL") ?? "https://chat.googleapis.com/v1"
        self.webhookPath = reader.value(String.self, "webhookPath") ?? "/webhooks/googlechat"
        self.pollIntervalMs = max(250, reader.value(Int.self, "pollIntervalMs") ?? 2_000)
        self.audienceType = reader.value(GoogleChatAudienceType.self, "audienceType")
        self.audience = reader.value(ChannelLooseStringEntry.self, "audience")?.value
        self.appPrincipal = reader.value(String.self, "appPrincipal")
        self.webhookURL = reader.value(String.self, "webhookURL", "webhookUrl")
        self.botUser = reader.value(String.self, "botUser")
        self.typingIndicator = reader.value(GoogleChatTypingIndicator.self, "typingIndicator")
        self.policy = ChannelMessagingPolicyConfig(reader: &reader)
        self.accounts = reader.value([String: ChannelAccountOverride].self, "accounts") ?? [:]
        self.defaultAccount = reader.value(String.self, "defaultAccount")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes Google Chat settings with SDK key names.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encodeIfPresent(self.bearerTokenInput, "bearerToken")
        try writer.encodeIfPresent(self.verificationTokenInput, "verificationToken")
        try writer.encodeIfPresent(self.serviceAccount, "serviceAccount")
        try writer.encodeIfPresent(self.serviceAccountFile, "serviceAccountFile")
        try writer.encodeIfPresent(self.defaultSpaceID, "defaultSpaceID")
        try writer.encode(self.baseURL, "baseURL")
        try writer.encode(self.webhookPath, "webhookPath")
        try writer.encode(self.pollIntervalMs, "pollIntervalMs")
        try writer.encodeIfPresent(self.audienceType, "audienceType")
        try writer.encodeIfPresent(self.audience, "audience")
        try writer.encodeIfPresent(self.appPrincipal, "appPrincipal")
        try writer.encodeIfPresent(self.webhookURL, "webhookURL")
        try writer.encodeIfPresent(self.botUser, "botUser")
        try writer.encodeIfPresent(self.typingIndicator, "typingIndicator")
        try ChannelSectionCoding.encodeCommon(
            to: encoder,
            policy: self.policy,
            excluding: ["defaultTo"],
            accounts: self.accounts,
            defaultAccount: self.defaultAccount,
            additionalProperties: self.additionalProperties,
            written: Self.writtenKeys
        )
    }
}

// MARK: - Signal

/// Signal transport kind (upstream `channels.signal.transport.kind`).
public enum SignalTransportKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// signal-cli managed by the gateway.
    case managedNative = "managed-native"
    /// Externally managed native signal-cli daemon.
    case externalNative = "external-native"
    /// signal-cli REST container.
    case container
}

/// Signal transport settings (upstream `channels.signal.transport`).
public struct SignalTransportConfig: Codable, Sendable, Equatable, Hashable {
    /// Transport kind.
    public var kind: SignalTransportKind?
    /// Service URL for container/external transports.
    public var url: String?
    /// HTTP host for managed transports.
    public var httpHost: String?
    /// HTTP port for managed transports.
    public var httpPort: Int?
    /// signal-cli binary path.
    public var cliPath: String?
    /// signal-cli config path.
    public var configPath: String?
    /// signal-cli socket path.
    public var socketPath: String?
    /// Startup timeout in milliseconds.
    public var startupTimeoutMs: Int?
    /// Receive mode.
    public var receiveMode: String?
    /// Ignore stories.
    public var ignoreStories: Bool?

    /// Creates transport settings.
    /// - Parameters:
    ///   - kind: Transport kind.
    ///   - url: Service URL.
    public init(kind: SignalTransportKind? = nil, url: String? = nil) {
        self.kind = kind
        self.url = url
    }
}

/// Signal adapter configuration.
public struct SignalChannelConfig: ChannelSectionConfig {
    /// Enables Signal adapter startup.
    public var enabled: Bool
    /// Signal bridge/service base URL (upstream `transport.url` for container/external transports).
    public var serviceURL: String
    /// Account (E.164) used by the bridge (upstream `account`).
    public var accountID: String?
    /// Auth token for bridge requests.
    public var authTokenInput: SecretInput?
    /// Default recipient when outbound peer is omitted (upstream `defaultTo`).
    public var defaultRecipient: String?
    /// Poll interval used for inbound fetch loops.
    public var pollIntervalMs: Int
    /// Transport settings.
    public var transport: SignalTransportConfig?
    /// Shared messaging policy keys.
    public var policy: ChannelMessagingPolicyConfig
    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride]
    /// Default account id.
    public var defaultAccount: String?
    /// Upstream keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Plaintext auth token.
    public var authToken: String? {
        get { self.authTokenInput?.stringValue }
        set { self.authTokenInput = newValue.map(SecretInput.string) }
    }

    /// Creates Signal channel settings.
    /// - Parameters:
    ///   - enabled: Enables Signal adapter startup.
    ///   - serviceURL: Signal bridge/service base URL.
    ///   - accountID: Optional account identifier used by the bridge.
    ///   - authToken: Optional auth token for bridge requests.
    ///   - defaultRecipient: Default recipient when outbound peer is omitted.
    ///   - pollIntervalMs: Poll interval used for inbound fetch loops.
    ///   - transport: Transport settings.
    ///   - policy: Shared messaging policy keys.
    public init(
        enabled: Bool = false,
        serviceURL: String = "http://127.0.0.1:8080",
        accountID: String? = nil,
        authToken: String? = nil,
        defaultRecipient: String? = nil,
        pollIntervalMs: Int = 2_000,
        transport: SignalTransportConfig? = nil,
        policy: ChannelMessagingPolicyConfig = ChannelMessagingPolicyConfig()
    ) {
        self.enabled = enabled
        self.serviceURL = serviceURL
        self.accountID = accountID
        self.authTokenInput = authToken.map(SecretInput.string)
        self.defaultRecipient = defaultRecipient
        self.pollIntervalMs = max(250, pollIntervalMs)
        self.transport = transport
        self.policy = policy
        self.accounts = [:]
        self.defaultAccount = nil
        self.additionalProperties = [:]
    }

    /// Key spellings that name the same setting.
    public static let keyAliasGroups: [[String]] = [
        ["serviceURL", "httpUrl"], ["accountID", "account"], ["defaultRecipient", "defaultTo"],
    ]

    private static let writtenKeys: Set<String> = [
        "enabled", "serviceURL", "httpUrl", "accountID", "account", "authToken", "defaultRecipient", "defaultTo",
        "pollIntervalMs", "transport",
    ]

    /// Policy with `defaultRecipient` folded in.
    public var effectivePolicy: ChannelMessagingPolicyConfig {
        var policy = self.policy
        policy.defaultTo = self.defaultRecipient ?? policy.defaultTo
        return policy
    }

    /// Decodes SDK or upstream-shaped Signal settings.
    ///
    /// `transport.url` becomes ``serviceURL`` for container and external-native transports; the
    /// legacy `httpUrl` key is still accepted.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? true
        let explicitURL = reader.value(String.self, "serviceURL", "httpUrl")
        self.transport = reader.value(SignalTransportConfig.self, "transport")
        if let explicitURL {
            self.serviceURL = explicitURL
        } else if let transport, transport.kind == .container || transport.kind == .externalNative, let url = transport.url {
            self.serviceURL = url
        } else {
            self.serviceURL = "http://127.0.0.1:8080"
        }
        self.accountID = reader.value(ChannelLooseStringEntry.self, "accountID", "account")?.value
        self.authTokenInput = reader.secret("authToken")
        self.defaultRecipient = reader.value(ChannelLooseStringEntry.self, "defaultRecipient", "defaultTo")?.value
        self.pollIntervalMs = max(250, reader.value(Int.self, "pollIntervalMs") ?? 2_000)
        self.policy = ChannelMessagingPolicyConfig(reader: &reader)
        self.accounts = reader.value([String: ChannelAccountOverride].self, "accounts") ?? [:]
        self.defaultAccount = reader.value(String.self, "defaultAccount")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes Signal settings with SDK key names.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encode(self.serviceURL, "serviceURL")
        try writer.encodeIfPresent(self.accountID, "accountID")
        try writer.encodeIfPresent(self.authTokenInput, "authToken")
        try writer.encodeIfPresent(self.defaultRecipient, "defaultRecipient")
        try writer.encode(self.pollIntervalMs, "pollIntervalMs")
        try writer.encodeIfPresent(self.transport, "transport")
        try ChannelSectionCoding.encodeCommon(
            to: encoder,
            policy: self.policy,
            excluding: ["defaultTo"],
            accounts: self.accounts,
            defaultAccount: self.defaultAccount,
            additionalProperties: self.additionalProperties,
            written: Self.writtenKeys
        )
    }
}

// MARK: - BlueBubbles (deprecated)

/// Deprecated name of the BlueBubbles channel settings.
@available(
    *,
    deprecated,
    message: "BlueBubbles support was removed upstream in OpenClaw 2026.9.x; migrate to the iMessage channel (imsg). See /channels/imessage-from-bluebubbles"
)
public typealias BlueBubblesChannelConfig = LegacyBlueBubblesChannelConfig

/// Storage for the deprecated `channels.bluebubbles` section.
///
/// BlueBubbles was removed upstream in OpenClaw 2026.5.12. This type keeps existing configs
/// decoding for one more release; use ``ChannelsConfig/migrateBlueBubblesToIMessage()`` to move
/// settings to ``IMessageChannelConfig``. It is referenced by name through the deprecated
/// `BlueBubblesChannelConfig` alias.
public struct LegacyBlueBubblesChannelConfig: ChannelSectionConfig {
    /// Enables BlueBubbles adapter startup.
    public var enabled: Bool
    /// BlueBubbles REST API base URL (`serverUrl`).
    public var serverURL: String
    /// API and webhook password.
    public var passwordInput: SecretInput?
    /// Host webhook path for inbound events.
    public var webhookPath: String
    /// Default conversation GUID (`defaultChatGuid`).
    public var defaultChatGUID: String?
    /// Send read receipts.
    public var sendReadReceipts: Bool?
    /// Include inbound attachments.
    public var includeAttachments: Bool?
    /// Allowed attachment roots.
    public var attachmentRoots: [String]?
    /// Per-action toggles.
    public var actions: [String: Bool]?
    /// Shared messaging policy keys.
    public var policy: ChannelMessagingPolicyConfig
    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride]
    /// Default account id.
    public var defaultAccount: String?
    /// Keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Plaintext password.
    public var password: String? {
        get { self.passwordInput?.stringValue }
        set { self.passwordInput = newValue.map(SecretInput.string) }
    }

    /// Creates BlueBubbles channel settings.
    /// - Parameters:
    ///   - enabled: Enables BlueBubbles adapter startup.
    ///   - serverURL: BlueBubbles REST API base URL.
    ///   - password: BlueBubbles API and webhook password.
    ///   - webhookPath: Host webhook path for inbound BlueBubbles events.
    ///   - defaultChatGUID: Default conversation GUID used when outbound peer ID is omitted.
    ///   - policy: Shared messaging policy keys.
    public init(
        enabled: Bool = false,
        serverURL: String = "http://127.0.0.1:1234",
        password: String? = nil,
        webhookPath: String = "/bluebubbles-webhook",
        defaultChatGUID: String? = nil,
        policy: ChannelMessagingPolicyConfig = ChannelMessagingPolicyConfig()
    ) {
        self.enabled = enabled
        self.serverURL = serverURL
        self.passwordInput = password.map(SecretInput.string)
        self.webhookPath = webhookPath
        self.defaultChatGUID = defaultChatGUID
        self.sendReadReceipts = nil
        self.includeAttachments = nil
        self.attachmentRoots = nil
        self.actions = nil
        self.policy = policy
        self.accounts = [:]
        self.defaultAccount = nil
        self.additionalProperties = [:]
    }

    /// Key spellings that name the same setting.
    public static let keyAliasGroups: [[String]] = [
        ["serverUrl", "serverURL"], ["defaultChatGuid", "defaultChatGUID", "defaultTo"],
    ]

    private static let writtenKeys: Set<String> = [
        "enabled", "serverUrl", "serverURL", "password", "webhookPath", "defaultChatGuid", "defaultChatGUID",
        "sendReadReceipts", "includeAttachments", "attachmentRoots", "actions",
    ]

    /// Policy with `defaultChatGUID` folded in.
    public var effectivePolicy: ChannelMessagingPolicyConfig {
        var policy = self.policy
        policy.defaultTo = self.defaultChatGUID ?? policy.defaultTo
        return policy
    }

    /// Decodes BlueBubbles settings.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? true
        self.serverURL = reader.value(String.self, "serverUrl", "serverURL") ?? "http://127.0.0.1:1234"
        self.passwordInput = reader.secret("password")
        self.webhookPath = reader.value(String.self, "webhookPath") ?? "/bluebubbles-webhook"
        self.defaultChatGUID = reader.value(String.self, "defaultChatGuid", "defaultChatGUID")
        self.sendReadReceipts = reader.value(Bool.self, "sendReadReceipts")
        self.includeAttachments = reader.value(Bool.self, "includeAttachments")
        self.attachmentRoots = reader.stringList("attachmentRoots")
        self.actions = reader.value([String: Bool].self, "actions")
        self.policy = ChannelMessagingPolicyConfig(reader: &reader)
        self.accounts = reader.value([String: ChannelAccountOverride].self, "accounts") ?? [:]
        self.defaultAccount = reader.value(String.self, "defaultAccount")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes BlueBubbles settings.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encode(self.serverURL, "serverUrl")
        try writer.encodeIfPresent(self.passwordInput, "password")
        try writer.encode(self.webhookPath, "webhookPath")
        try writer.encodeIfPresent(self.defaultChatGUID, "defaultChatGuid")
        try writer.encodeIfPresent(self.sendReadReceipts, "sendReadReceipts")
        try writer.encodeIfPresent(self.includeAttachments, "includeAttachments")
        try writer.encodeIfPresent(self.attachmentRoots, "attachmentRoots")
        try writer.encodeIfPresent(self.actions, "actions")
        try ChannelSectionCoding.encodeCommon(
            to: encoder,
            policy: self.policy,
            excluding: [],
            accounts: self.accounts,
            defaultAccount: self.defaultAccount,
            additionalProperties: self.additionalProperties,
            written: Self.writtenKeys
        )
    }
}

// MARK: - iMessage

/// iMessage service selection (upstream `service`).
public enum IMessageService: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// iMessage only.
    case imessage
    /// SMS only.
    case sms
    /// Let the bridge choose.
    case auto
}

/// iMessage send transport (upstream `sendTransport`).
public enum IMessageSendTransport: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Let the bridge choose.
    case auto
    /// Private API bridge.
    case bridge
    /// AppleScript.
    case applescript
}

/// Per-action toggles for iMessage message actions (upstream `IMessageActionConfig`; all default `true`).
public struct IMessageActionConfig: Codable, Sendable, Equatable, Hashable {
    /// Reactions (tapbacks).
    public var reactions: Bool
    /// Editing sent messages.
    public var edit: Bool
    /// Unsending messages.
    public var unsend: Bool
    /// Native replies.
    public var reply: Bool
    /// Sending with effects.
    public var sendWithEffect: Bool
    /// Renaming groups.
    public var renameGroup: Bool
    /// Setting group icons.
    public var setGroupIcon: Bool
    /// Adding participants.
    public var addParticipant: Bool
    /// Removing participants.
    public var removeParticipant: Bool
    /// Leaving groups.
    public var leaveGroup: Bool
    /// Sending attachments.
    public var sendAttachment: Bool
    /// Polls.
    public var polls: Bool

    /// Creates action toggles; every action defaults to enabled.
    public init() {
        self.reactions = true
        self.edit = true
        self.unsend = true
        self.reply = true
        self.sendWithEffect = true
        self.renameGroup = true
        self.setGroupIcon = true
        self.addParticipant = true
        self.removeParticipant = true
        self.leaveGroup = true
        self.sendAttachment = true
        self.polls = true
    }

    /// Decodes action toggles; missing actions default to enabled.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.reactions = reader.value(Bool.self, "reactions") ?? true
        self.edit = reader.value(Bool.self, "edit") ?? true
        self.unsend = reader.value(Bool.self, "unsend") ?? true
        self.reply = reader.value(Bool.self, "reply") ?? true
        self.sendWithEffect = reader.value(Bool.self, "sendWithEffect") ?? true
        self.renameGroup = reader.value(Bool.self, "renameGroup") ?? true
        self.setGroupIcon = reader.value(Bool.self, "setGroupIcon") ?? true
        self.addParticipant = reader.value(Bool.self, "addParticipant") ?? true
        self.removeParticipant = reader.value(Bool.self, "removeParticipant") ?? true
        self.leaveGroup = reader.value(Bool.self, "leaveGroup") ?? true
        self.sendAttachment = reader.value(Bool.self, "sendAttachment") ?? true
        self.polls = reader.value(Bool.self, "polls") ?? true
    }

    /// Toggles keyed by action name.
    public var asDictionary: [String: Bool] {
        [
            "reactions": self.reactions, "edit": self.edit, "unsend": self.unsend, "reply": self.reply,
            "sendWithEffect": self.sendWithEffect, "renameGroup": self.renameGroup, "setGroupIcon": self.setGroupIcon,
            "addParticipant": self.addParticipant, "removeParticipant": self.removeParticipant,
            "leaveGroup": self.leaveGroup, "sendAttachment": self.sendAttachment, "polls": self.polls,
        ]
    }
}

/// iMessage inbound catch-up settings (upstream `catchup`).
public struct IMessageCatchupConfig: Codable, Sendable, Equatable, Hashable {
    /// Whether catch-up runs (default `false`).
    public var enabled: Bool
    /// Maximum message age in minutes (default 120, clamped 1...720).
    public var maxAgeMinutes: Int
    /// Messages processed per run (default 50, clamped 1...500).
    public var perRunLimit: Int
    /// Look-back on the first run in minutes (default 30).
    public var firstRunLookbackMinutes: Int
    /// Retries per failing message (default 10, clamped 1...1000).
    public var maxFailureRetries: Int

    /// Creates catch-up settings with clamping.
    /// - Parameters:
    ///   - enabled: Whether catch-up runs.
    ///   - maxAgeMinutes: Maximum message age in minutes.
    ///   - perRunLimit: Messages per run.
    ///   - firstRunLookbackMinutes: First-run look-back.
    ///   - maxFailureRetries: Retries per failing message.
    public init(
        enabled: Bool = false,
        maxAgeMinutes: Int = 120,
        perRunLimit: Int = 50,
        firstRunLookbackMinutes: Int = 30,
        maxFailureRetries: Int = 10
    ) {
        self.enabled = enabled
        self.maxAgeMinutes = min(max(1, maxAgeMinutes), 720)
        self.perRunLimit = min(max(1, perRunLimit), 500)
        self.firstRunLookbackMinutes = max(0, firstRunLookbackMinutes)
        self.maxFailureRetries = min(max(1, maxFailureRetries), 1_000)
    }

    /// Decodes catch-up settings with defaults and clamping.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.init(
            enabled: reader.value(Bool.self, "enabled") ?? false,
            maxAgeMinutes: reader.value(Int.self, "maxAgeMinutes") ?? 120,
            perRunLimit: reader.value(Int.self, "perRunLimit") ?? 50,
            firstRunLookbackMinutes: reader.value(Int.self, "firstRunLookbackMinutes") ?? 30,
            maxFailureRetries: reader.value(Int.self, "maxFailureRetries") ?? 10
        )
    }
}

/// iMessage adapter configuration.
public struct IMessageChannelConfig: ChannelSectionConfig {
    /// Enables iMessage adapter startup.
    public var enabled: Bool
    /// Optional bundle identifier for host integration.
    public var bundleIdentifier: String?
    /// Optional default iMessage handle (upstream `defaultTo`).
    public var defaultHandle: String?
    /// Enables simulated mode on unsupported platforms.
    public var allowUnsupportedPlatformSimulation: Bool
    /// `imsg` CLI path (default `imsg`).
    public var cliPath: String
    /// Messages database path.
    public var dbPath: String?
    /// SSH host running `imsg` (remote Mac).
    public var remoteHost: String?
    /// Service selection.
    public var service: IMessageService?
    /// Send transport.
    public var sendTransport: IMessageSendTransport?
    /// Phone number region for normalization.
    public var region: String?
    /// Include inbound attachments (default `false`).
    public var includeAttachments: Bool
    /// Allowed local attachment roots.
    public var attachmentRoots: [String]?
    /// Allowed remote attachment roots.
    public var remoteAttachmentRoots: [String]?
    /// Bridge probe timeout in milliseconds (default 10000).
    public var probeTimeoutMs: Int
    /// Send read receipts (default `true`).
    public var sendReadReceipts: Bool
    /// Per-action toggles.
    public var actions: IMessageActionConfig
    /// Inbound catch-up settings.
    public var catchup: IMessageCatchupConfig
    /// Shared messaging policy keys.
    public var policy: ChannelMessagingPolicyConfig
    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride]
    /// Default account id.
    public var defaultAccount: String?
    /// Upstream keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Creates iMessage channel settings.
    /// - Parameters:
    ///   - enabled: Enables iMessage adapter startup.
    ///   - bundleIdentifier: Optional bundle identifier for host integration.
    ///   - defaultHandle: Optional default iMessage handle.
    ///   - allowUnsupportedPlatformSimulation: Enables simulated mode on unsupported platforms.
    ///   - cliPath: `imsg` CLI path.
    ///   - includeAttachments: Include inbound attachments.
    ///   - sendReadReceipts: Send read receipts.
    ///   - policy: Shared messaging policy keys.
    public init(
        enabled: Bool = false,
        bundleIdentifier: String? = nil,
        defaultHandle: String? = nil,
        allowUnsupportedPlatformSimulation: Bool = false,
        cliPath: String = "imsg",
        includeAttachments: Bool = false,
        sendReadReceipts: Bool = true,
        policy: ChannelMessagingPolicyConfig = ChannelMessagingPolicyConfig()
    ) {
        self.enabled = enabled
        self.bundleIdentifier = bundleIdentifier
        self.defaultHandle = defaultHandle
        self.allowUnsupportedPlatformSimulation = allowUnsupportedPlatformSimulation
        self.cliPath = cliPath
        self.dbPath = nil
        self.remoteHost = nil
        self.service = nil
        self.sendTransport = nil
        self.region = nil
        self.includeAttachments = includeAttachments
        self.attachmentRoots = nil
        self.remoteAttachmentRoots = nil
        self.probeTimeoutMs = 10_000
        self.sendReadReceipts = sendReadReceipts
        self.actions = IMessageActionConfig()
        self.catchup = IMessageCatchupConfig()
        self.policy = policy
        self.accounts = [:]
        self.defaultAccount = nil
        self.additionalProperties = [:]
    }

    /// Key spellings that name the same setting.
    public static let keyAliasGroups: [[String]] = [["defaultHandle", "defaultTo"]]

    private static let writtenKeys: Set<String> = [
        "enabled", "bundleIdentifier", "defaultHandle", "defaultTo", "allowUnsupportedPlatformSimulation", "cliPath",
        "dbPath", "remoteHost", "service", "sendTransport", "region", "includeAttachments", "attachmentRoots",
        "remoteAttachmentRoots", "probeTimeoutMs", "sendReadReceipts", "actions", "catchup",
    ]

    /// Policy with `defaultHandle` folded in.
    public var effectivePolicy: ChannelMessagingPolicyConfig {
        var policy = self.policy
        policy.defaultTo = self.defaultHandle ?? policy.defaultTo
        return policy
    }

    /// Decodes SDK or upstream-shaped iMessage settings.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? true
        self.bundleIdentifier = reader.value(String.self, "bundleIdentifier")
        self.defaultHandle = reader.value(ChannelLooseStringEntry.self, "defaultHandle", "defaultTo")?.value
        self.allowUnsupportedPlatformSimulation = reader.value(Bool.self, "allowUnsupportedPlatformSimulation") ?? false
        self.cliPath = reader.value(String.self, "cliPath") ?? "imsg"
        self.dbPath = reader.value(String.self, "dbPath")
        self.remoteHost = reader.value(String.self, "remoteHost")
        self.service = reader.value(IMessageService.self, "service")
        self.sendTransport = reader.value(IMessageSendTransport.self, "sendTransport")
        self.region = reader.value(String.self, "region")
        self.includeAttachments = reader.value(Bool.self, "includeAttachments") ?? false
        self.attachmentRoots = reader.stringList("attachmentRoots")
        self.remoteAttachmentRoots = reader.stringList("remoteAttachmentRoots")
        self.probeTimeoutMs = max(1, reader.value(Int.self, "probeTimeoutMs") ?? 10_000)
        self.sendReadReceipts = reader.value(Bool.self, "sendReadReceipts") ?? true
        self.actions = reader.value(IMessageActionConfig.self, "actions") ?? IMessageActionConfig()
        self.catchup = reader.value(IMessageCatchupConfig.self, "catchup") ?? IMessageCatchupConfig()
        self.policy = ChannelMessagingPolicyConfig(reader: &reader)
        self.accounts = reader.value([String: ChannelAccountOverride].self, "accounts") ?? [:]
        self.defaultAccount = reader.value(String.self, "defaultAccount")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes iMessage settings.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encodeIfPresent(self.bundleIdentifier, "bundleIdentifier")
        try writer.encodeIfPresent(self.defaultHandle, "defaultHandle")
        try writer.encode(self.allowUnsupportedPlatformSimulation, "allowUnsupportedPlatformSimulation")
        try writer.encode(self.cliPath, "cliPath")
        try writer.encodeIfPresent(self.dbPath, "dbPath")
        try writer.encodeIfPresent(self.remoteHost, "remoteHost")
        try writer.encodeIfPresent(self.service, "service")
        try writer.encodeIfPresent(self.sendTransport, "sendTransport")
        try writer.encodeIfPresent(self.region, "region")
        try writer.encode(self.includeAttachments, "includeAttachments")
        try writer.encodeIfPresent(self.attachmentRoots, "attachmentRoots")
        try writer.encodeIfPresent(self.remoteAttachmentRoots, "remoteAttachmentRoots")
        try writer.encode(self.probeTimeoutMs, "probeTimeoutMs")
        try writer.encode(self.sendReadReceipts, "sendReadReceipts")
        if self.actions != IMessageActionConfig() {
            try writer.encode(self.actions, "actions")
        }
        if self.catchup != IMessageCatchupConfig() {
            try writer.encode(self.catchup, "catchup")
        }
        try ChannelSectionCoding.encodeCommon(
            to: encoder,
            policy: self.policy,
            excluding: ["defaultTo"],
            accounts: self.accounts,
            defaultAccount: self.defaultAccount,
            additionalProperties: self.additionalProperties,
            written: Self.writtenKeys
        )
    }
}

// MARK: - Microsoft Teams

/// Microsoft cloud for Teams (upstream `channels.msteams.cloud`).
public enum MicrosoftTeamsCloud: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Public commercial cloud (default).
    case `public` = "Public"
    /// US Government (GCC High).
    case usGov = "USGov"
    /// US Government DoD.
    case usGovDoD = "USGovDoD"
    /// China (21Vianet).
    case china = "China"
}

/// Microsoft Teams adapter configuration.
public struct MicrosoftTeamsChannelConfig: ChannelSectionConfig {
    /// Enables Microsoft Teams adapter startup.
    public var enabled: Bool
    /// Bot App ID (upstream `appId`).
    public var botAppID: String?
    /// Bot App password (upstream `appPassword`; plaintext, env template or SecretRef).
    public var botAppPasswordInput: SecretInput?
    /// Microsoft Entra tenant ID (upstream `tenantId`).
    public var tenantID: String?
    /// Default conversation target (upstream `defaultTo`).
    public var defaultConversationID: String?
    /// Bot Framework service endpoint (upstream `serviceUrl`).
    public var serviceURL: String
    /// Limits processing to explicit bot mentions (upstream `requireMention`).
    public var mentionOnly: Bool
    /// Microsoft cloud (default ``MicrosoftTeamsCloud/public``). Non-public clouds require `serviceUrl`.
    public var cloud: MicrosoftTeamsCloud
    /// Shared messaging policy keys.
    public var policy: ChannelMessagingPolicyConfig
    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride]
    /// Default account id.
    public var defaultAccount: String?
    /// Upstream keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Plaintext bot app password.
    public var botAppPassword: String? {
        get { self.botAppPasswordInput?.stringValue }
        set { self.botAppPasswordInput = newValue.map(SecretInput.string) }
    }

    /// Default Bot Framework service URL for the public cloud.
    public static let defaultServiceURL = "https://smba.trafficmanager.net/teams/"

    /// Creates Microsoft Teams channel settings.
    /// - Parameters:
    ///   - enabled: Enables Microsoft Teams adapter startup.
    ///   - botAppID: Bot App ID for Teams/Bot Framework auth.
    ///   - botAppPassword: Bot App password/secret.
    ///   - tenantID: Optional Microsoft Entra tenant ID.
    ///   - defaultConversationID: Default conversation target.
    ///   - serviceURL: Bot Framework service endpoint.
    ///   - mentionOnly: Limits processing to explicit bot mentions.
    ///   - cloud: Microsoft cloud.
    ///   - policy: Shared messaging policy keys.
    public init(
        enabled: Bool = false,
        botAppID: String? = nil,
        botAppPassword: String? = nil,
        tenantID: String? = nil,
        defaultConversationID: String? = nil,
        serviceURL: String = MicrosoftTeamsChannelConfig.defaultServiceURL,
        mentionOnly: Bool = true,
        cloud: MicrosoftTeamsCloud = .public,
        policy: ChannelMessagingPolicyConfig = ChannelMessagingPolicyConfig()
    ) {
        self.enabled = enabled
        self.botAppID = botAppID
        self.botAppPasswordInput = botAppPassword.map(SecretInput.string)
        self.tenantID = tenantID
        self.defaultConversationID = defaultConversationID
        self.serviceURL = serviceURL
        self.mentionOnly = mentionOnly
        self.cloud = cloud
        self.policy = policy
        self.accounts = [:]
        self.defaultAccount = nil
        self.additionalProperties = [:]
    }

    /// Key spellings that name the same setting.
    public static let keyAliasGroups: [[String]] = [
        ["botAppID", "appId"], ["botAppPassword", "appPassword"], ["tenantID", "tenantId"],
        ["serviceURL", "serviceUrl"], ["mentionOnly", "requireMention"], ["defaultConversationID", "defaultTo"],
    ]

    private static let writtenKeys: Set<String> = [
        "enabled", "botAppID", "appId", "botAppPassword", "appPassword", "tenantID", "tenantId", "defaultConversationID",
        "defaultTo", "serviceURL", "serviceUrl", "mentionOnly", "requireMention", "cloud",
    ]

    /// Policy with `mentionOnly` and `defaultConversationID` folded in.
    public var effectivePolicy: ChannelMessagingPolicyConfig {
        var policy = self.policy
        policy.requireMention = self.mentionOnly
        policy.defaultTo = self.defaultConversationID ?? policy.defaultTo
        return policy
    }

    /// Decodes SDK or upstream-shaped Teams settings.
    ///
    /// A non-public ``cloud`` without an explicit service URL records an `invalidValue` issue
    /// (upstream rejects it) and keeps the public default URL.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? true
        self.botAppID = reader.value(String.self, "botAppID", "appId")
        self.botAppPasswordInput = reader.secret("botAppPassword", "appPassword")
        self.tenantID = reader.value(String.self, "tenantID", "tenantId")
        self.defaultConversationID = reader.value(String.self, "defaultConversationID", "defaultTo")
        let explicitServiceURL = reader.value(String.self, "serviceURL", "serviceUrl")
        self.serviceURL = explicitServiceURL ?? Self.defaultServiceURL
        self.mentionOnly = reader.value(Bool.self, "mentionOnly", "requireMention") ?? true
        self.cloud = reader.value(MicrosoftTeamsCloud.self, "cloud") ?? .public
        if self.cloud != .public, explicitServiceURL == nil {
            reader.recordIssue(
                "channels.msteams.cloud \(self.cloud.rawValue) requires an explicit serviceUrl.",
                kind: .invalidValue,
                forKey: "cloud"
            )
        }
        self.policy = ChannelMessagingPolicyConfig(reader: &reader)
        self.accounts = reader.value([String: ChannelAccountOverride].self, "accounts") ?? [:]
        self.defaultAccount = reader.value(String.self, "defaultAccount")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes Teams settings with SDK key names.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encodeIfPresent(self.botAppID, "botAppID")
        try writer.encodeIfPresent(self.botAppPasswordInput, "botAppPassword")
        try writer.encodeIfPresent(self.tenantID, "tenantID")
        try writer.encodeIfPresent(self.defaultConversationID, "defaultConversationID")
        try writer.encode(self.serviceURL, "serviceURL")
        try writer.encode(self.mentionOnly, "mentionOnly")
        if self.cloud != .public {
            try writer.encode(self.cloud, "cloud")
        }
        try ChannelSectionCoding.encodeCommon(
            to: encoder,
            policy: self.policy,
            excluding: ["defaultTo", "requireMention"],
            accounts: self.accounts,
            defaultAccount: self.defaultAccount,
            additionalProperties: self.additionalProperties,
            written: Self.writtenKeys
        )
    }
}

// MARK: - WebChat

/// Production WebChat adapter configuration (SDK-only; upstream retired `channels.webchat`).
///
/// WebChat is the SDK's own authenticated surface, so ingress access policy does not apply to it.
public struct WebChatChannelConfig: ChannelSectionConfig {
    /// Enables WebChat adapter startup.
    public var enabled: Bool
    /// Hostname/interface the WebChat server binds to.
    public var host: String
    /// Port the WebChat server listens on.
    public var port: Int
    /// Inbound webhook path.
    public var webhookPath: String
    /// Shared secret for request validation.
    public var sharedSecretInput: SecretInput?
    /// Max in-memory transcript messages per session.
    public var transcriptLimit: Int
    /// Shared messaging policy keys (only outbound keys such as `textChunkLimit` apply).
    public var policy: ChannelMessagingPolicyConfig
    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride]
    /// Default account id.
    public var defaultAccount: String?
    /// Keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Plaintext shared secret.
    public var sharedSecret: String? {
        get { self.sharedSecretInput?.stringValue }
        set { self.sharedSecretInput = newValue.map(SecretInput.string) }
    }

    /// Creates WebChat channel settings.
    /// - Parameters:
    ///   - enabled: Enables WebChat adapter startup.
    ///   - host: Hostname/interface WebChat server binds to.
    ///   - port: Port WebChat server listens on.
    ///   - webhookPath: Inbound webhook path.
    ///   - sharedSecret: Optional shared secret for request validation.
    ///   - transcriptLimit: Max in-memory transcript messages per session.
    public init(
        enabled: Bool = false,
        host: String = "127.0.0.1",
        port: Int = 3_001,
        webhookPath: String = "/webhooks/webchat",
        sharedSecret: String? = nil,
        transcriptLimit: Int = 200
    ) {
        self.enabled = enabled
        self.host = host
        self.port = min(max(1, port), 65_535)
        self.webhookPath = webhookPath
        self.sharedSecretInput = sharedSecret.map(SecretInput.string)
        self.transcriptLimit = max(1, transcriptLimit)
        self.policy = ChannelMessagingPolicyConfig()
        self.accounts = [:]
        self.defaultAccount = nil
        self.additionalProperties = [:]
    }

    /// Key spellings that name the same setting.
    public static let keyAliasGroups: [[String]] = []

    private static let writtenKeys: Set<String> = [
        "enabled", "host", "port", "webhookPath", "sharedSecret", "transcriptLimit",
    ]

    /// WebChat policy.
    public var effectivePolicy: ChannelMessagingPolicyConfig {
        self.policy
    }

    /// Decodes WebChat settings; missing keys use defaults.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? false
        self.host = reader.value(String.self, "host") ?? "127.0.0.1"
        self.port = min(max(1, reader.value(Int.self, "port") ?? 3_001), 65_535)
        self.webhookPath = reader.value(String.self, "webhookPath") ?? "/webhooks/webchat"
        self.sharedSecretInput = reader.secret("sharedSecret")
        self.transcriptLimit = max(1, reader.value(Int.self, "transcriptLimit") ?? 200)
        self.policy = ChannelMessagingPolicyConfig(reader: &reader)
        self.accounts = reader.value([String: ChannelAccountOverride].self, "accounts") ?? [:]
        self.defaultAccount = reader.value(String.self, "defaultAccount")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes WebChat settings.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encode(self.host, "host")
        try writer.encode(self.port, "port")
        try writer.encode(self.webhookPath, "webhookPath")
        try writer.encodeIfPresent(self.sharedSecretInput, "sharedSecret")
        try writer.encode(self.transcriptLimit, "transcriptLimit")
        try ChannelSectionCoding.encodeCommon(
            to: encoder,
            policy: self.policy,
            excluding: [],
            accounts: self.accounts,
            defaultAccount: self.defaultAccount,
            additionalProperties: self.additionalProperties,
            written: Self.writtenKeys
        )
    }
}
