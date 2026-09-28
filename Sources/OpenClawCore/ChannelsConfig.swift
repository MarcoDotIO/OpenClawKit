import Foundation

/// Channel adapter related configuration.
public struct ChannelsConfig: Codable, Sendable, Equatable {
    public var discord: DiscordChannelConfig
    public var telegram: TelegramChannelConfig
    public var whatsappCloud: WhatsAppCloudChannelConfig
    public var slack: SlackChannelConfig
    public var googleChat: GoogleChatChannelConfig
    public var signal: SignalChannelConfig
    public var bluebubbles: BlueBubblesChannelConfig
    public var imessage: IMessageChannelConfig
    public var msteams: MicrosoftTeamsChannelConfig
    public var webchat: WebChatChannelConfig
    public var pluginChannels: [String: PluginChannelConfig]

    /// Creates channel config.
    /// - Parameter discord: Discord channel settings.
    /// - Parameter telegram: Telegram channel settings.
    /// - Parameter whatsappCloud: WhatsApp Cloud API channel settings.
    /// - Parameter slack: Slack channel settings.
    /// - Parameter googleChat: Google Chat channel settings.
    /// - Parameter signal: Signal channel settings.
    /// - Parameter bluebubbles: BlueBubbles channel settings.
    /// - Parameter imessage: iMessage channel settings.
    /// - Parameter msteams: Microsoft Teams channel settings.
    /// - Parameter webchat: WebChat channel settings.
    /// - Parameter pluginChannels: Metadata/config blocks for upstream plugin-only channels.
    public init(
        discord: DiscordChannelConfig = DiscordChannelConfig(),
        telegram: TelegramChannelConfig = TelegramChannelConfig(),
        whatsappCloud: WhatsAppCloudChannelConfig = WhatsAppCloudChannelConfig(),
        slack: SlackChannelConfig = SlackChannelConfig(),
        googleChat: GoogleChatChannelConfig = GoogleChatChannelConfig(),
        signal: SignalChannelConfig = SignalChannelConfig(),
        bluebubbles: BlueBubblesChannelConfig = BlueBubblesChannelConfig(),
        imessage: IMessageChannelConfig = IMessageChannelConfig(),
        msteams: MicrosoftTeamsChannelConfig = MicrosoftTeamsChannelConfig(),
        webchat: WebChatChannelConfig = WebChatChannelConfig(),
        pluginChannels: [String: PluginChannelConfig] = [:]
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
    }

    private enum CodingKeys: String, CodingKey {
        case discord
        case telegram
        case whatsappCloud
        case slack
        case googlechat
        case signal
        case bluebubbles
        case imessage
        case msteams
        case webchat
        case pluginChannels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.discord = try container.decodeIfPresent(DiscordChannelConfig.self, forKey: .discord) ?? DiscordChannelConfig()
        self.telegram = try container.decodeIfPresent(TelegramChannelConfig.self, forKey: .telegram) ?? TelegramChannelConfig()
        self.whatsappCloud = try container.decodeIfPresent(WhatsAppCloudChannelConfig.self, forKey: .whatsappCloud) ?? WhatsAppCloudChannelConfig()
        self.slack = try container.decodeIfPresent(SlackChannelConfig.self, forKey: .slack) ?? SlackChannelConfig()
        self.googleChat = try container.decodeIfPresent(GoogleChatChannelConfig.self, forKey: .googlechat) ?? GoogleChatChannelConfig()
        self.signal = try container.decodeIfPresent(SignalChannelConfig.self, forKey: .signal) ?? SignalChannelConfig()
        self.bluebubbles = try container.decodeIfPresent(BlueBubblesChannelConfig.self, forKey: .bluebubbles) ?? BlueBubblesChannelConfig()
        self.imessage = try container.decodeIfPresent(IMessageChannelConfig.self, forKey: .imessage) ?? IMessageChannelConfig()
        self.msteams = try container.decodeIfPresent(MicrosoftTeamsChannelConfig.self, forKey: .msteams) ?? MicrosoftTeamsChannelConfig()
        self.webchat = try container.decodeIfPresent(WebChatChannelConfig.self, forKey: .webchat) ?? WebChatChannelConfig()
        self.pluginChannels = try container.decodeIfPresent(
            [String: PluginChannelConfig].self,
            forKey: .pluginChannels
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.discord, forKey: .discord)
        try container.encode(self.telegram, forKey: .telegram)
        try container.encode(self.whatsappCloud, forKey: .whatsappCloud)
        try container.encode(self.slack, forKey: .slack)
        try container.encode(self.googleChat, forKey: .googlechat)
        try container.encode(self.signal, forKey: .signal)
        try container.encode(self.bluebubbles, forKey: .bluebubbles)
        try container.encode(self.imessage, forKey: .imessage)
        try container.encode(self.msteams, forKey: .msteams)
        try container.encode(self.webchat, forKey: .webchat)
        try container.encode(self.pluginChannels, forKey: .pluginChannels)
    }
}

/// Generic config block for upstream plugin-only channels.
public struct PluginChannelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var packageName: String?
    public var config: [String: String]
    public var secrets: [String: String]

    /// Creates plugin-channel settings.
    /// - Parameters:
    ///   - enabled: Whether the host should attempt to activate this channel plugin.
    ///   - packageName: Optional upstream package/plugin package name.
    ///   - config: Non-secret plugin config values.
    ///   - secrets: Secret values or secret references required by the plugin.
    public init(
        enabled: Bool = false,
        packageName: String? = nil,
        config: [String: String] = [:],
        secrets: [String: String] = [:]
    ) {
        self.enabled = enabled
        self.packageName = packageName
        self.config = config
        self.secrets = secrets
    }
}

/// Discord adapter configuration.
public struct DiscordChannelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var botToken: String?
    public var defaultChannelID: String?
    public var pollIntervalMs: Int
    public var presenceEnabled: Bool
    public var mentionOnly: Bool

    /// Creates Discord channel settings.
    /// - Parameters:
    ///   - enabled: Enables Discord adapter startup.
    ///   - botToken: Bot token used for API auth.
    ///   - defaultChannelID: Default channel ID for polling/sends.
    ///   - pollIntervalMs: Poll interval in milliseconds.
    ///   - presenceEnabled: Enables Discord gateway presence lifecycle.
    ///   - mentionOnly: Processes messages only when bot is explicitly mentioned.
    public init(
        enabled: Bool = false,
        botToken: String? = nil,
        defaultChannelID: String? = nil,
        pollIntervalMs: Int = 2_000,
        presenceEnabled: Bool = true,
        mentionOnly: Bool = true
    ) {
        self.enabled = enabled
        self.botToken = botToken
        self.defaultChannelID = defaultChannelID
        self.pollIntervalMs = max(250, pollIntervalMs)
        self.presenceEnabled = presenceEnabled
        self.mentionOnly = mentionOnly
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case botToken
        case defaultChannelID
        case pollIntervalMs
        case presenceEnabled
        case mentionOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.botToken = try container.decodeIfPresent(String.self, forKey: .botToken)
        self.defaultChannelID = try container.decodeIfPresent(String.self, forKey: .defaultChannelID)
        let pollInterval = try container.decodeIfPresent(Int.self, forKey: .pollIntervalMs) ?? 2_000
        self.pollIntervalMs = max(250, pollInterval)
        self.presenceEnabled = try container.decodeIfPresent(Bool.self, forKey: .presenceEnabled) ?? true
        self.mentionOnly = try container.decodeIfPresent(Bool.self, forKey: .mentionOnly) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encodeIfPresent(self.botToken, forKey: .botToken)
        try container.encodeIfPresent(self.defaultChannelID, forKey: .defaultChannelID)
        try container.encode(self.pollIntervalMs, forKey: .pollIntervalMs)
        try container.encode(self.presenceEnabled, forKey: .presenceEnabled)
        try container.encode(self.mentionOnly, forKey: .mentionOnly)
    }
}

/// Telegram adapter configuration.
public struct TelegramChannelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var botToken: String?
    public var defaultChatID: String?
    public var pollIntervalMs: Int
    public var mentionOnly: Bool
    public var baseURL: String

    /// Creates Telegram channel settings.
    /// - Parameters:
    ///   - enabled: Enables Telegram adapter startup.
    ///   - botToken: Bot token used for API auth.
    ///   - defaultChatID: Default chat ID for polling/sends.
    ///   - pollIntervalMs: Poll interval in milliseconds.
    ///   - mentionOnly: Processes group messages only when bot is explicitly mentioned.
    ///   - baseURL: Telegram Bot API base URL.
    public init(
        enabled: Bool = false,
        botToken: String? = nil,
        defaultChatID: String? = nil,
        pollIntervalMs: Int = 2_000,
        mentionOnly: Bool = true,
        baseURL: String = "https://api.telegram.org"
    ) {
        self.enabled = enabled
        self.botToken = botToken
        self.defaultChatID = defaultChatID
        self.pollIntervalMs = max(250, pollIntervalMs)
        self.mentionOnly = mentionOnly
        self.baseURL = baseURL
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case botToken
        case defaultChatID
        case pollIntervalMs
        case mentionOnly
        case baseURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.botToken = try container.decodeIfPresent(String.self, forKey: .botToken)
        self.defaultChatID = try container.decodeIfPresent(String.self, forKey: .defaultChatID)
        let pollInterval = try container.decodeIfPresent(Int.self, forKey: .pollIntervalMs) ?? 2_000
        self.pollIntervalMs = max(250, pollInterval)
        self.mentionOnly = try container.decodeIfPresent(Bool.self, forKey: .mentionOnly) ?? true
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.telegram.org"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encodeIfPresent(self.botToken, forKey: .botToken)
        try container.encodeIfPresent(self.defaultChatID, forKey: .defaultChatID)
        try container.encode(self.pollIntervalMs, forKey: .pollIntervalMs)
        try container.encode(self.mentionOnly, forKey: .mentionOnly)
        try container.encode(self.baseURL, forKey: .baseURL)
    }
}

/// WhatsApp Cloud API adapter configuration.
public struct WhatsAppCloudChannelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var accessToken: String?
    public var phoneNumberID: String?
    public var businessAccountID: String?
    public var webhookVerifyToken: String?
    public var webhookPath: String
    public var baseURL: String
    public var apiVersion: String

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
    public init(
        enabled: Bool = false,
        accessToken: String? = nil,
        phoneNumberID: String? = nil,
        businessAccountID: String? = nil,
        webhookVerifyToken: String? = nil,
        webhookPath: String = "/webhooks/whatsapp",
        baseURL: String = "https://graph.facebook.com",
        apiVersion: String = "v20.0"
    ) {
        self.enabled = enabled
        self.accessToken = accessToken
        self.phoneNumberID = phoneNumberID
        self.businessAccountID = businessAccountID
        self.webhookVerifyToken = webhookVerifyToken
        self.webhookPath = webhookPath
        self.baseURL = baseURL
        self.apiVersion = apiVersion
    }
}

/// Slack adapter configuration.
public struct SlackChannelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var botToken: String?
    public var appToken: String?
    public var signingSecret: String?
    public var defaultChannelID: String?
    public var mentionOnly: Bool
    public var baseURL: String

    /// Creates Slack channel settings.
    /// - Parameters:
    ///   - enabled: Enables Slack adapter startup.
    ///   - botToken: Slack Bot OAuth token.
    ///   - appToken: Slack App-Level token for socket mode.
    ///   - signingSecret: Slack signing secret for request validation.
    ///   - defaultChannelID: Default channel ID for outbound sends.
    ///   - mentionOnly: Limits processing to explicit bot mentions.
    ///   - baseURL: Slack Web API base URL.
    public init(
        enabled: Bool = false,
        botToken: String? = nil,
        appToken: String? = nil,
        signingSecret: String? = nil,
        defaultChannelID: String? = nil,
        mentionOnly: Bool = true,
        baseURL: String = "https://slack.com/api"
    ) {
        self.enabled = enabled
        self.botToken = botToken
        self.appToken = appToken
        self.signingSecret = signingSecret
        self.defaultChannelID = defaultChannelID
        self.mentionOnly = mentionOnly
        self.baseURL = baseURL
    }
}

/// Google Chat adapter configuration.
public struct GoogleChatChannelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var bearerToken: String?
    public var verificationToken: String?
    public var defaultSpaceID: String?
    public var baseURL: String
    public var webhookPath: String
    public var pollIntervalMs: Int

    /// Creates Google Chat channel settings.
    /// - Parameters:
    ///   - enabled: Enables Google Chat adapter startup.
    ///   - bearerToken: Bot/service auth bearer token.
    ///   - verificationToken: Optional token used to verify inbound calls.
    ///   - defaultSpaceID: Default Google Chat space identifier.
    ///   - baseURL: Google Chat API base URL.
    ///   - webhookPath: Host webhook path for inbound events.
    ///   - pollIntervalMs: Polling interval used for fallback polling paths.
    public init(
        enabled: Bool = false,
        bearerToken: String? = nil,
        verificationToken: String? = nil,
        defaultSpaceID: String? = nil,
        baseURL: String = "https://chat.googleapis.com/v1",
        webhookPath: String = "/webhooks/googlechat",
        pollIntervalMs: Int = 2_000
    ) {
        self.enabled = enabled
        self.bearerToken = bearerToken
        self.verificationToken = verificationToken
        self.defaultSpaceID = defaultSpaceID
        self.baseURL = baseURL
        self.webhookPath = webhookPath
        self.pollIntervalMs = max(250, pollIntervalMs)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case bearerToken
        case verificationToken
        case defaultSpaceID
        case baseURL
        case webhookPath
        case pollIntervalMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.bearerToken = try container.decodeIfPresent(String.self, forKey: .bearerToken)
        self.verificationToken = try container.decodeIfPresent(String.self, forKey: .verificationToken)
        self.defaultSpaceID = try container.decodeIfPresent(String.self, forKey: .defaultSpaceID)
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://chat.googleapis.com/v1"
        self.webhookPath = try container.decodeIfPresent(String.self, forKey: .webhookPath) ?? "/webhooks/googlechat"
        let pollInterval = try container.decodeIfPresent(Int.self, forKey: .pollIntervalMs) ?? 2_000
        self.pollIntervalMs = max(250, pollInterval)
    }
}

/// Signal adapter configuration.
public struct SignalChannelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var serviceURL: String
    public var accountID: String?
    public var authToken: String?
    public var defaultRecipient: String?
    public var pollIntervalMs: Int

    /// Creates Signal channel settings.
    /// - Parameters:
    ///   - enabled: Enables Signal adapter startup.
    ///   - serviceURL: Signal bridge/service base URL.
    ///   - accountID: Optional account identifier used by the bridge.
    ///   - authToken: Optional auth token for bridge requests.
    ///   - defaultRecipient: Default recipient when outbound peer is omitted.
    ///   - pollIntervalMs: Poll interval used for inbound fetch loops.
    public init(
        enabled: Bool = false,
        serviceURL: String = "http://127.0.0.1:8080",
        accountID: String? = nil,
        authToken: String? = nil,
        defaultRecipient: String? = nil,
        pollIntervalMs: Int = 2_000
    ) {
        self.enabled = enabled
        self.serviceURL = serviceURL
        self.accountID = accountID
        self.authToken = authToken
        self.defaultRecipient = defaultRecipient
        self.pollIntervalMs = max(250, pollIntervalMs)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case serviceURL
        case accountID
        case authToken
        case defaultRecipient
        case pollIntervalMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.serviceURL = try container.decodeIfPresent(String.self, forKey: .serviceURL) ?? "http://127.0.0.1:8080"
        self.accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        self.authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
        self.defaultRecipient = try container.decodeIfPresent(String.self, forKey: .defaultRecipient)
        let pollInterval = try container.decodeIfPresent(Int.self, forKey: .pollIntervalMs) ?? 2_000
        self.pollIntervalMs = max(250, pollInterval)
    }
}

/// BlueBubbles adapter configuration.
public struct BlueBubblesChannelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var serverURL: String
    public var password: String?
    public var webhookPath: String
    public var defaultChatGUID: String?

    /// Creates BlueBubbles channel settings.
    /// - Parameters:
    ///   - enabled: Enables BlueBubbles adapter startup.
    ///   - serverURL: BlueBubbles REST API base URL.
    ///   - password: BlueBubbles API and webhook password.
    ///   - webhookPath: Host webhook path for inbound BlueBubbles events.
    ///   - defaultChatGUID: Default conversation GUID used when outbound peer ID is omitted.
    public init(
        enabled: Bool = false,
        serverURL: String = "http://127.0.0.1:1234",
        password: String? = nil,
        webhookPath: String = "/bluebubbles-webhook",
        defaultChatGUID: String? = nil
    ) {
        self.enabled = enabled
        self.serverURL = serverURL
        self.password = password
        self.webhookPath = webhookPath
        self.defaultChatGUID = defaultChatGUID
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case serverURL = "serverUrl"
        case password
        case webhookPath
        case defaultChatGUID = "defaultChatGuid"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL) ?? "http://127.0.0.1:1234"
        self.password = try container.decodeIfPresent(String.self, forKey: .password)
        self.webhookPath = try container.decodeIfPresent(String.self, forKey: .webhookPath) ?? "/bluebubbles-webhook"
        self.defaultChatGUID = try container.decodeIfPresent(String.self, forKey: .defaultChatGUID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.serverURL, forKey: .serverURL)
        try container.encodeIfPresent(self.password, forKey: .password)
        try container.encode(self.webhookPath, forKey: .webhookPath)
        try container.encodeIfPresent(self.defaultChatGUID, forKey: .defaultChatGUID)
    }
}

/// iMessage adapter configuration.
public struct IMessageChannelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var bundleIdentifier: String?
    public var defaultHandle: String?
    public var allowUnsupportedPlatformSimulation: Bool

    /// Creates iMessage channel settings.
    /// - Parameters:
    ///   - enabled: Enables iMessage adapter startup.
    ///   - bundleIdentifier: Optional bundle identifier for host integration.
    ///   - defaultHandle: Optional default iMessage handle.
    ///   - allowUnsupportedPlatformSimulation: Enables simulated mode on unsupported platforms.
    public init(
        enabled: Bool = false,
        bundleIdentifier: String? = nil,
        defaultHandle: String? = nil,
        allowUnsupportedPlatformSimulation: Bool = false
    ) {
        self.enabled = enabled
        self.bundleIdentifier = bundleIdentifier
        self.defaultHandle = defaultHandle
        self.allowUnsupportedPlatformSimulation = allowUnsupportedPlatformSimulation
    }
}

/// Microsoft Teams adapter configuration.
public struct MicrosoftTeamsChannelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var botAppID: String?
    public var botAppPassword: String?
    public var tenantID: String?
    public var defaultConversationID: String?
    public var serviceURL: String
    public var mentionOnly: Bool

    /// Creates Microsoft Teams channel settings.
    /// - Parameters:
    ///   - enabled: Enables Microsoft Teams adapter startup.
    ///   - botAppID: Bot App ID for Teams/Bot Framework auth.
    ///   - botAppPassword: Bot App password/secret.
    ///   - tenantID: Optional Microsoft Entra tenant ID.
    ///   - defaultConversationID: Default conversation target.
    ///   - serviceURL: Bot Framework service endpoint.
    ///   - mentionOnly: Limits processing to explicit bot mentions.
    public init(
        enabled: Bool = false,
        botAppID: String? = nil,
        botAppPassword: String? = nil,
        tenantID: String? = nil,
        defaultConversationID: String? = nil,
        serviceURL: String = "https://smba.trafficmanager.net/teams/",
        mentionOnly: Bool = true
    ) {
        self.enabled = enabled
        self.botAppID = botAppID
        self.botAppPassword = botAppPassword
        self.tenantID = tenantID
        self.defaultConversationID = defaultConversationID
        self.serviceURL = serviceURL
        self.mentionOnly = mentionOnly
    }
}

/// Production WebChat adapter configuration.
public struct WebChatChannelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var webhookPath: String
    public var sharedSecret: String?
    public var transcriptLimit: Int

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
        self.sharedSecret = sharedSecret
        self.transcriptLimit = max(1, transcriptLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case host
        case port
        case webhookPath
        case sharedSecret
        case transcriptLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        let port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 3_001
        self.port = min(max(1, port), 65_535)
        self.webhookPath = try container.decodeIfPresent(String.self, forKey: .webhookPath) ?? "/webhooks/webchat"
        self.sharedSecret = try container.decodeIfPresent(String.self, forKey: .sharedSecret)
        let transcriptLimit = try container.decodeIfPresent(Int.self, forKey: .transcriptLimit) ?? 200
        self.transcriptLimit = max(1, transcriptLimit)
    }
}
