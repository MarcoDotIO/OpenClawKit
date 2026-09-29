import Foundation
import OpenClawProtocol

/// One upstream `channels.<id>` block, kept losslessly with typed accessors for the common keys
/// (upstream `CommonChannelAccountSchema` plus the generic container fields).
public struct ChannelBlock: Codable, Sendable, Equatable {
    /// Raw block keys exactly as authored.
    public var raw: [String: AnyCodable]

    /// Creates a block from raw keys.
    /// - Parameter raw: Raw block keys.
    public init(raw: [String: AnyCodable] = [:]) {
        self.raw = raw
    }

    /// Decodes a raw block.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        self.raw = try [String: AnyCodable](from: decoder)
    }

    /// Encodes the raw block.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        try self.raw.encode(to: encoder)
    }

    /// Whether the block is enabled (upstream: enabled unless `enabled: false`).
    public var enabled: Bool {
        self.raw["enabled"]?.boolValue ?? true
    }

    /// Display name.
    public var name: String? {
        self.raw["name"]?.stringValue
    }

    /// Shared messaging policy keys decoded from the block.
    public var policy: ChannelMessagingPolicyConfig {
        ChannelConfigJSON.decode(ChannelMessagingPolicyConfig.self, from: self.raw) ?? ChannelMessagingPolicyConfig()
    }

    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride] {
        (self.raw["accounts"]?.dictionaryValue ?? [:]).compactMapValues { value in
            value.dictionaryValue.map { ChannelAccountOverride(values: $0) }
        }
    }

    /// Default account id.
    public var defaultAccount: String? {
        self.raw["defaultAccount"]?.stringValue
    }

    /// Thread-binding settings (`threadBindings`), kept raw.
    public var threadBindings: [String: AnyCodable]? {
        self.raw["threadBindings"]?.dictionaryValue
    }

    /// Native exec-approval routing (`execApprovals`), kept raw.
    public var execApprovals: [String: AnyCodable]? {
        self.raw["execApprovals"]?.dictionaryValue
    }

    /// Health monitor toggle (`healthMonitor.enabled`).
    public var healthMonitorEnabled: Bool? {
        self.raw["healthMonitor"]?.dictionaryValue?["enabled"]?.boolValue
    }

    /// Explicit opt-in for private-network callbacks (`dangerouslyAllowPrivateNetwork`).
    public var dangerouslyAllowPrivateNetwork: Bool {
        self.raw["dangerouslyAllowPrivateNetwork"]?.boolValue ?? false
    }

    /// Per-DM overrides (`dms`), kept raw.
    public var dms: [String: AnyCodable]? {
        self.raw["dms"]?.dictionaryValue
    }
}

/// Lossless upstream-shaped `channels` section (upstream `ChannelsSchema`, `.passthrough()`).
///
/// `defaults` and `modelByChannel` are typed; every other key is a channel id holding that
/// channel's (plugin-owned) block. Use ``init(exporting:preserving:)`` to project the SDK's
/// ``ChannelsConfig`` into upstream keys and ``channelsConfig`` to import it.
public struct ChannelsConfigDocument: Codable, Sendable, Equatable {
    /// Shared channel defaults.
    public var defaults: ChannelDefaultsConfig?
    /// Model overrides by channel.
    public var modelByChannel: [String: [String: String]]?
    /// Channel blocks keyed by channel id.
    public var channels: [String: ChannelBlock]

    /// Creates a document.
    /// - Parameters:
    ///   - defaults: Shared defaults.
    ///   - modelByChannel: Model overrides.
    ///   - channels: Channel blocks.
    public init(
        defaults: ChannelDefaultsConfig? = nil,
        modelByChannel: [String: [String: String]]? = nil,
        channels: [String: ChannelBlock] = [:]
    ) {
        self.defaults = defaults
        self.modelByChannel = modelByChannel
        self.channels = channels
    }

    /// Decodes the section leniently; non-object channel values are dropped with an issue.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.defaults = reader.value(ChannelDefaultsConfig.self, "defaults")
        self.modelByChannel = reader.value([String: [String: String]].self, "modelByChannel")
        var channels: [String: ChannelBlock] = [:]
        for (key, value) in reader.remaining() {
            if let object = value.dictionaryValue {
                channels[key] = ChannelBlock(raw: object)
            } else {
                reader.recordIssue("channels.\(key) must be an object", kind: .typeMismatch, forKey: key)
            }
        }
        self.channels = channels
    }

    /// Encodes `defaults`, `modelByChannel` and every channel block.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        if let defaults, !defaults.isEmpty {
            try writer.encode(defaults, "defaults")
        }
        try writer.encodeIfPresent(self.modelByChannel, "modelByChannel")
        for (key, block) in self.channels where key != "defaults" && key != "modelByChannel" {
            try writer.encode(block, key)
        }
    }

    /// Raw JSON object of the whole section.
    public var jsonObject: [String: AnyCodable] {
        ChannelConfigJSON.object(from: self) ?? [:]
    }

    /// Imports the section into the SDK runtime model (typed sections decode from their blocks,
    /// every other block lands in ``ChannelsConfig/extensionChannels``).
    public var channelsConfig: ChannelsConfig {
        ChannelConfigJSON.decode(ChannelsConfig.self, from: self.jsonObject) ?? ChannelsConfig()
    }

    /// Upstream validation issues (see ``ChannelsConfig/validationIssues()``).
    /// - Returns: Issues.
    public func validationIssues() -> [ConfigDecodeIssue] {
        self.channelsConfig.validationIssues()
    }

    /// Projects SDK channel settings onto upstream keys, merged over an original document so
    /// plugin-owned and unmodeled keys survive.
    ///
    /// SDK-only sections (`whatsappCloud`, `webchat`, `bluebubbles`, `pluginChannels`,
    /// `compatibility`) and SDK-only keys (poll intervals, `typingMode`, ...) are never emitted.
    /// `mentionOnly: false` on Telegram becomes `groups["*"].requireMention: false` because
    /// upstream Telegram has no root-level `requireMention`.
    /// - Parameters:
    ///   - config: SDK channel settings.
    ///   - original: Document to preserve unmanaged keys from.
    public init(exporting config: ChannelsConfig, preserving original: ChannelsConfigDocument? = nil) {
        var channels = original?.channels ?? [:]
        for (id, value) in config.extensionChannels {
            if let object = value.dictionaryValue {
                channels[id] = ChannelBlock(raw: object)
            }
        }
        for (id, plugin) in config.pluginChannels where channels[id] == nil && !plugin.raw.isEmpty {
            channels[id] = ChannelBlock(raw: plugin.raw)
        }
        func merge(_ id: String, include: Bool, _ managed: [String: AnyCodable], removing: [String] = []) {
            guard include || channels[id] != nil else { return }
            var raw = channels[id]?.raw ?? [:]
            for key in removing {
                raw.removeValue(forKey: key)
            }
            raw.merge(managed) { _, new in new }
            channels[id] = ChannelBlock(raw: raw)
        }
        merge("discord", include: config.discord.enabled, ChannelDocumentExport.discord(config.discord))
        merge("telegram", include: config.telegram.enabled, ChannelDocumentExport.telegram(config.telegram), removing: ["requireMention"])
        merge("slack", include: config.slack.enabled, ChannelDocumentExport.slack(config.slack))
        merge("googlechat", include: config.googleChat.enabled, ChannelDocumentExport.googleChat(config.googleChat))
        merge("signal", include: config.signal.enabled, ChannelDocumentExport.signal(config.signal))
        merge("imessage", include: config.imessage.enabled, ChannelDocumentExport.iMessage(config.imessage))
        merge("msteams", include: config.msteams.enabled, ChannelDocumentExport.teams(config.msteams))
        self.init(
            defaults: config.defaults.isEmpty ? original?.defaults : config.defaults,
            modelByChannel: config.modelByChannel.isEmpty ? original?.modelByChannel : config.modelByChannel,
            channels: channels
        )
    }
}

/// SDK → upstream key projections for typed channel sections.
enum ChannelDocumentExport {
    /// Policy keys upstream accepts on channel roots (SDK extensions such as `typingMode` are excluded).
    static let upstreamPolicyKeys: Set<String> = [
        "name", "configWrites", "dmPolicy", "allowFrom", "groupPolicy", "groupAllowFrom", "defaultTo",
        "textChunkLimit", "streaming", "mediaMaxMb", "replyToMode", "responsePrefix", "historyLimit",
        "dmHistoryLimit", "contextVisibility", "markdown", "implicitMentions", "botLoopProtection", "allowBots",
        "ackReaction", "ackReactionScope", "reactionNotifications", "reactionLevel", "joinIntro", "groups",
        "mentionPatterns", "heartbeatVisibility",
    ]

    static func common<Section: ChannelSectionConfig>(_ section: Section, policy: ChannelMessagingPolicyConfig) -> [String: AnyCodable] {
        var object = (ChannelConfigJSON.object(from: policy) ?? [:]).filter { Self.upstreamPolicyKeys.contains($0.key) }
        object["enabled"] = AnyCodable(section.enabled)
        for (key, value) in section.additionalProperties {
            object[key] = value
        }
        if !section.accounts.isEmpty {
            object["accounts"] = AnyCodable(AnySendableValue.object(section.accounts.mapValues { AnyCodable(AnySendableValue.object($0.values)) }))
        }
        if let defaultAccount = section.defaultAccount {
            object["defaultAccount"] = AnyCodable(defaultAccount)
        }
        return object
    }

    static func put(_ object: inout [String: AnyCodable], _ key: String, _ value: some Encodable) {
        if let encoded = try? AnyCodable(encoding: value), !encoded.isNull {
            object[key] = encoded
        }
    }

    static func discord(_ section: DiscordChannelConfig) -> [String: AnyCodable] {
        var object = self.common(section, policy: section.effectivePolicy)
        object.removeValue(forKey: "requireMention")
        // SDK-only inbound transport switch; upstream always uses the gateway.
        object.removeValue(forKey: "transport")
        if let token = section.botTokenInput { self.put(&object, "token", token) }
        return object
    }

    static func telegram(_ section: TelegramChannelConfig) -> [String: AnyCodable] {
        var policy = section.policy
        if !section.mentionOnly {
            var groups = policy.groups ?? [:]
            var wildcard = groups["*"] ?? ChannelGroupConfig()
            wildcard.requireMention = wildcard.requireMention ?? false
            groups["*"] = wildcard
            policy.groups = groups
        }
        policy.defaultTo = section.defaultChatID ?? policy.defaultTo
        var object = self.common(section, policy: policy)
        object.removeValue(forKey: "requireMention")
        if let token = section.botTokenInput { self.put(&object, "botToken", token) }
        if let tokenFile = section.tokenFile { object["tokenFile"] = AnyCodable(tokenFile) }
        if let secret = section.webhookSecretInput { self.put(&object, "webhookSecret", secret) }
        if section.baseURL != "https://api.telegram.org" { object["apiRoot"] = AnyCodable(section.baseURL) }
        if section.richMessages { object["richMessages"] = AnyCodable(true) }
        return object
    }

    static func slack(_ section: SlackChannelConfig) -> [String: AnyCodable] {
        var policy = section.policy
        policy.defaultTo = section.defaultChannelID ?? policy.defaultTo
        var object = self.common(section, policy: policy)
        if let token = section.botTokenInput { self.put(&object, "botToken", token) }
        if let token = section.appTokenInput { self.put(&object, "appToken", token) }
        if let secret = section.signingSecretInput { self.put(&object, "signingSecret", secret) }
        if let token = section.userTokenInput { self.put(&object, "userToken", token) }
        // `poll` is the SDK-only legacy conversations.history mode; upstream has no equivalent.
        if section.mode != .poll { object["mode"] = AnyCodable(section.mode.rawValue) }
        if let relay = section.relay { self.put(&object, "relay", relay) }
        if section.mode == .http { object["webhookPath"] = AnyCodable(section.webhookPath) }
        if let reaction = section.typingReaction { object["typingReaction"] = AnyCodable(reaction) }
        return object
    }

    static func googleChat(_ section: GoogleChatChannelConfig) -> [String: AnyCodable] {
        var object = self.common(section, policy: section.effectivePolicy)
        if let serviceAccount = section.serviceAccount { object["serviceAccount"] = serviceAccount }
        if let file = section.serviceAccountFile { object["serviceAccountFile"] = AnyCodable(file) }
        if let audienceType = section.audienceType { object["audienceType"] = AnyCodable(audienceType.rawValue) }
        if let audience = section.audience { object["audience"] = AnyCodable(audience) }
        if let principal = section.appPrincipal { object["appPrincipal"] = AnyCodable(principal) }
        if let url = section.webhookURL { object["webhookUrl"] = AnyCodable(url) }
        if let botUser = section.botUser { object["botUser"] = AnyCodable(botUser) }
        if let typing = section.typingIndicator { object["typingIndicator"] = AnyCodable(typing.rawValue) }
        return object
    }

    static func signal(_ section: SignalChannelConfig) -> [String: AnyCodable] {
        var object = self.common(section, policy: section.effectivePolicy)
        if let account = section.accountID { object["account"] = AnyCodable(account) }
        if var transport = section.transport {
            if transport.url == nil, transport.kind != .managedNative {
                transport.url = section.serviceURL
            }
            self.put(&object, "transport", transport)
        } else if section.serviceURL != "http://127.0.0.1:8080" {
            self.put(&object, "transport", SignalTransportConfig(kind: .externalNative, url: section.serviceURL))
        }
        return object
    }

    static func iMessage(_ section: IMessageChannelConfig) -> [String: AnyCodable] {
        var object = self.common(section, policy: section.effectivePolicy)
        object["cliPath"] = AnyCodable(section.cliPath)
        if let dbPath = section.dbPath { object["dbPath"] = AnyCodable(dbPath) }
        if let remoteHost = section.remoteHost { object["remoteHost"] = AnyCodable(remoteHost) }
        if let service = section.service { object["service"] = AnyCodable(service.rawValue) }
        if let transport = section.sendTransport { object["sendTransport"] = AnyCodable(transport.rawValue) }
        if let region = section.region { object["region"] = AnyCodable(region) }
        object["includeAttachments"] = AnyCodable(section.includeAttachments)
        if let roots = section.attachmentRoots { self.put(&object, "attachmentRoots", roots) }
        if let roots = section.remoteAttachmentRoots { self.put(&object, "remoteAttachmentRoots", roots) }
        object["probeTimeoutMs"] = AnyCodable(section.probeTimeoutMs)
        object["sendReadReceipts"] = AnyCodable(section.sendReadReceipts)
        if section.actions != IMessageActionConfig() { self.put(&object, "actions", section.actions) }
        if section.catchup != IMessageCatchupConfig() { self.put(&object, "catchup", section.catchup) }
        return object
    }

    static func teams(_ section: MicrosoftTeamsChannelConfig) -> [String: AnyCodable] {
        var object = self.common(section, policy: section.effectivePolicy)
        object.removeValue(forKey: "requireMention")
        if let appID = section.botAppID { object["appId"] = AnyCodable(appID) }
        if let password = section.botAppPasswordInput { self.put(&object, "appPassword", password) }
        if let tenant = section.tenantID { object["tenantId"] = AnyCodable(tenant) }
        if section.serviceURL != MicrosoftTeamsChannelConfig.defaultServiceURL || section.cloud != .public {
            object["serviceUrl"] = AnyCodable(section.serviceURL)
        }
        if section.cloud != .public { object["cloud"] = AnyCodable(section.cloud.rawValue) }
        return object
    }
}
