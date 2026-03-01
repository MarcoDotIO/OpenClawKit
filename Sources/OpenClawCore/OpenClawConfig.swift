import Foundation

/// Root configuration object for runtime, routing, channels, and models.
public struct OpenClawConfig: Codable, Sendable, Equatable {
    public var gateway: GatewayConfig
    public var agents: AgentsConfig
    public var channels: ChannelsConfig
    public var routing: RoutingConfig
    public var models: ModelsConfig
    public var runtime: RuntimeConfig

    /// Creates an OpenClaw runtime configuration.
    /// - Parameters:
    ///   - gateway: Gateway transport settings.
    ///   - agents: Agent workspace/default settings.
    ///   - channels: Channel adapter settings.
    ///   - routing: Session routing behavior.
    ///   - models: Model provider settings.
    public init(
        gateway: GatewayConfig = GatewayConfig(),
        agents: AgentsConfig = AgentsConfig(),
        channels: ChannelsConfig = ChannelsConfig(),
        routing: RoutingConfig = RoutingConfig(),
        models: ModelsConfig = ModelsConfig(),
        runtime: RuntimeConfig = RuntimeConfig()
    ) {
        self.gateway = gateway
        self.agents = agents
        self.channels = channels
        self.routing = routing
        self.models = models
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey {
        case gateway
        case agents
        case channels
        case routing
        case models
        case runtime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.gateway = try container.decodeIfPresent(GatewayConfig.self, forKey: .gateway) ?? GatewayConfig()
        self.agents = try container.decodeIfPresent(AgentsConfig.self, forKey: .agents) ?? AgentsConfig()
        self.channels = try container.decodeIfPresent(ChannelsConfig.self, forKey: .channels) ?? ChannelsConfig()
        self.routing = try container.decodeIfPresent(RoutingConfig.self, forKey: .routing) ?? RoutingConfig()
        self.models = try container.decodeIfPresent(ModelsConfig.self, forKey: .models) ?? ModelsConfig()
        self.runtime = try container.decodeIfPresent(RuntimeConfig.self, forKey: .runtime) ?? RuntimeConfig()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.gateway, forKey: .gateway)
        try container.encode(self.agents, forKey: .agents)
        try container.encode(self.channels, forKey: .channels)
        try container.encode(self.routing, forKey: .routing)
        try container.encode(self.models, forKey: .models)
        try container.encode(self.runtime, forKey: .runtime)
    }
}

/// Runtime behavior controls for replay and adaptive routing.
public struct RuntimeConfig: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var replay: ReplayConfig
    public var adaptiveRouting: AdaptiveRoutingConfig
    public var memoryGraph: MemoryGraphConfig

    /// Creates runtime behavior settings.
    /// - Parameters:
    ///   - schemaVersion: Runtime config schema version.
    ///   - replay: Replay event/capture settings.
    ///   - adaptiveRouting: Adaptive model routing settings.
    ///   - memoryGraph: SwiftData+CloudKit memory graph settings.
    public init(
        schemaVersion: Int = ReplayEvent.currentSchemaVersion,
        replay: ReplayConfig = ReplayConfig(),
        adaptiveRouting: AdaptiveRoutingConfig = AdaptiveRoutingConfig(),
        memoryGraph: MemoryGraphConfig = MemoryGraphConfig()
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.replay = replay
        self.adaptiveRouting = adaptiveRouting
        self.memoryGraph = memoryGraph
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case replay
        case adaptiveRouting
        case memoryGraph
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = max(
            1,
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? ReplayEvent.currentSchemaVersion
        )
        self.replay = try container.decodeIfPresent(ReplayConfig.self, forKey: .replay) ?? ReplayConfig()
        self.adaptiveRouting = try container.decodeIfPresent(
            AdaptiveRoutingConfig.self,
            forKey: .adaptiveRouting
        ) ?? AdaptiveRoutingConfig()
        self.memoryGraph = try container.decodeIfPresent(MemoryGraphConfig.self, forKey: .memoryGraph)
            ?? MemoryGraphConfig()
    }
}

/// Replay capture controls.
public struct ReplayConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var persistToDisk: Bool
    public var maxInMemoryEvents: Int
    public var storePath: String?
    public var signEvents: Bool

    /// Creates replay settings.
    /// - Parameters:
    ///   - enabled: Enables replay event capture.
    ///   - persistToDisk: Persists replay events to file-backed storage.
    ///   - maxInMemoryEvents: Maximum replay events retained in memory.
    ///   - storePath: Optional custom replay store path.
    ///   - signEvents: Enables event signing.
    public init(
        enabled: Bool = false,
        persistToDisk: Bool = true,
        maxInMemoryEvents: Int = 10_000,
        storePath: String? = nil,
        signEvents: Bool = false
    ) {
        self.enabled = enabled
        self.persistToDisk = persistToDisk
        self.maxInMemoryEvents = max(1, maxInMemoryEvents)
        self.storePath = storePath
        self.signEvents = signEvents
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case persistToDisk
        case maxInMemoryEvents
        case storePath
        case signEvents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.persistToDisk = try container.decodeIfPresent(Bool.self, forKey: .persistToDisk) ?? true
        self.maxInMemoryEvents = max(1, try container.decodeIfPresent(Int.self, forKey: .maxInMemoryEvents) ?? 10_000)
        self.storePath = try container.decodeIfPresent(String.self, forKey: .storePath)
        self.signEvents = try container.decodeIfPresent(Bool.self, forKey: .signEvents) ?? false
    }
}

/// SwiftData + CloudKit memory graph controls.
public struct MemoryGraphConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var swiftDataEnabled: Bool
    public var cloudKitSyncEnabled: Bool
    public var cloudKitContainerID: String?
    public var legacyStorePath: String?

    /// Creates memory graph settings.
    /// - Parameters:
    ///   - enabled: Enables memory graph storage.
    ///   - swiftDataEnabled: Enables SwiftData backing where available.
    ///   - cloudKitSyncEnabled: Enables CloudKit sync where available.
    ///   - cloudKitContainerID: Optional CloudKit container identifier.
    ///   - legacyStorePath: Optional legacy JSON store path used for migration.
    public init(
        enabled: Bool = false,
        swiftDataEnabled: Bool = true,
        cloudKitSyncEnabled: Bool = false,
        cloudKitContainerID: String? = nil,
        legacyStorePath: String? = nil
    ) {
        self.enabled = enabled
        self.swiftDataEnabled = swiftDataEnabled
        self.cloudKitSyncEnabled = cloudKitSyncEnabled
        self.cloudKitContainerID = cloudKitContainerID
        self.legacyStorePath = legacyStorePath
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case swiftDataEnabled
        case cloudKitSyncEnabled
        case cloudKitContainerID
        case legacyStorePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.swiftDataEnabled = try container.decodeIfPresent(Bool.self, forKey: .swiftDataEnabled) ?? true
        self.cloudKitSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .cloudKitSyncEnabled) ?? false
        self.cloudKitContainerID = try container.decodeIfPresent(String.self, forKey: .cloudKitContainerID)
        self.legacyStorePath = try container.decodeIfPresent(String.self, forKey: .legacyStorePath)
    }
}

/// Optimization objective for adaptive routing policy.
public enum AdaptiveRoutingObjective: String, Codable, Sendable, Equatable, CaseIterable {
    case balanced
    case latency
    case cost
    case quality
}

/// Runtime adaptive model routing controls.
public struct AdaptiveRoutingConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var minSamplesPerProvider: Int
    public var explorationRate: Double
    public var decisionWindow: Int
    public var objective: AdaptiveRoutingObjective

    /// Creates adaptive routing settings.
    /// - Parameters:
    ///   - enabled: Enables adaptive provider ordering.
    ///   - minSamplesPerProvider: Minimum samples before hard ranking.
    ///   - explorationRate: Probability of non-greedy exploration (`0...1`).
    ///   - decisionWindow: Number of recent calls considered for scoring.
    ///   - objective: Optimization objective.
    public init(
        enabled: Bool = false,
        minSamplesPerProvider: Int = 20,
        explorationRate: Double = 0.05,
        decisionWindow: Int = 500,
        objective: AdaptiveRoutingObjective = .balanced
    ) {
        self.enabled = enabled
        self.minSamplesPerProvider = max(1, minSamplesPerProvider)
        self.explorationRate = min(max(0, explorationRate), 1)
        self.decisionWindow = max(1, decisionWindow)
        self.objective = objective
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case minSamplesPerProvider
        case explorationRate
        case decisionWindow
        case objective
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.minSamplesPerProvider = max(
            1,
            try container.decodeIfPresent(Int.self, forKey: .minSamplesPerProvider) ?? 20
        )
        self.explorationRate = min(
            max(0, try container.decodeIfPresent(Double.self, forKey: .explorationRate) ?? 0.05),
            1
        )
        self.decisionWindow = max(1, try container.decodeIfPresent(Int.self, forKey: .decisionWindow) ?? 500)
        self.objective = try container.decodeIfPresent(AdaptiveRoutingObjective.self, forKey: .objective) ?? .balanced
    }
}

/// Gateway client connection settings.
public struct GatewayConfig: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var authMode: String

    /// Creates gateway settings.
    /// - Parameters:
    ///   - host: Gateway host name or IP.
    ///   - port: Gateway port.
    ///   - authMode: Gateway auth mode string.
    public init(host: String = "127.0.0.1", port: Int = 18789, authMode: String = "token") {
        self.host = host
        self.port = port
        self.authMode = authMode
    }
}

/// Agent runtime defaults and workspace location.
public struct AgentsConfig: Codable, Sendable, Equatable {
    public var defaultAgentID: String
    public var workspaceRoot: String
    public var skillInvocationTimeoutMs: Int
    public var agentIDs: [String]
    public var routeAgentMap: [String: String]

    /// Creates agent defaults.
    /// - Parameters:
    ///   - defaultAgentID: Default agent identifier.
    ///   - workspaceRoot: Workspace root path.
    ///   - skillInvocationTimeoutMs: Default timeout for skill invocation in milliseconds.
    ///   - agentIDs: Declared agent identifiers available at runtime.
    ///   - routeAgentMap: Route mapping table (`channel[:accountID[:peerID]] -> agentID`).
    public init(
        defaultAgentID: String = "main",
        workspaceRoot: String = "./workspace",
        skillInvocationTimeoutMs: Int = 30_000,
        agentIDs: [String] = [],
        routeAgentMap: [String: String] = [:]
    ) {
        self.defaultAgentID = defaultAgentID
        self.workspaceRoot = workspaceRoot
        self.skillInvocationTimeoutMs = max(1, skillInvocationTimeoutMs)
        var normalizedAgentIDs = Set(agentIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        normalizedAgentIDs.insert(defaultAgentID)
        self.agentIDs = normalizedAgentIDs.sorted()
        self.routeAgentMap = routeAgentMap
    }

    private enum CodingKeys: String, CodingKey {
        case defaultAgentID
        case workspaceRoot
        case skillInvocationTimeoutMs
        case agentIDs
        case routeAgentMap
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaultAgentID = try container.decodeIfPresent(String.self, forKey: .defaultAgentID) ?? "main"
        let workspaceRoot = try container.decodeIfPresent(String.self, forKey: .workspaceRoot) ?? "./workspace"
        let skillInvocationTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .skillInvocationTimeoutMs) ?? 30_000
        let agentIDs = try container.decodeIfPresent([String].self, forKey: .agentIDs) ?? []
        let routeAgentMap = try container.decodeIfPresent([String: String].self, forKey: .routeAgentMap) ?? [:]
        self.init(
            defaultAgentID: defaultAgentID,
            workspaceRoot: workspaceRoot,
            skillInvocationTimeoutMs: skillInvocationTimeoutMs,
            agentIDs: agentIDs,
            routeAgentMap: routeAgentMap
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.defaultAgentID, forKey: .defaultAgentID)
        try container.encode(self.workspaceRoot, forKey: .workspaceRoot)
        try container.encode(self.skillInvocationTimeoutMs, forKey: .skillInvocationTimeoutMs)
        try container.encode(self.agentIDs, forKey: .agentIDs)
        try container.encode(self.routeAgentMap, forKey: .routeAgentMap)
    }

    /// Creates a route map key for channel/account/peer matching.
    /// - Parameters:
    ///   - channel: Channel identifier.
    ///   - accountID: Optional account identifier.
    ///   - peerID: Optional peer identifier.
    /// - Returns: Canonical route key.
    public static func routeKey(channel: String, accountID: String? = nil, peerID: String? = nil) -> String {
        [channel, accountID, peerID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ":")
    }

    /// Resolves the effective agent ID for the provided routing context.
    /// - Parameter context: Routing context for inbound message/session.
    /// - Returns: Mapped or default agent identifier.
    public func resolvedAgentID(for context: SessionRoutingContext) -> String {
        let channel = context.channel.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = context.accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let peerID = context.peerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateKeys = [
            Self.routeKey(channel: channel, accountID: accountID, peerID: peerID),
            Self.routeKey(channel: channel, accountID: accountID, peerID: nil),
            Self.routeKey(channel: channel),
        ].filter { !$0.isEmpty }

        let available = Set(self.agentIDs)
        for key in candidateKeys {
            guard let mapped = self.routeAgentMap[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !mapped.isEmpty
            else {
                continue
            }
            if available.isEmpty || available.contains(mapped) {
                return mapped
            }
        }
        return self.defaultAgentID
    }
}

/// Session key routing behavior controls.
public struct RoutingConfig: Codable, Sendable, Equatable {
    public var defaultSessionKey: String
    public var includeChannelID: Bool
    public var includeAccountID: Bool
    public var includePeerID: Bool

    /// Creates routing settings.
    /// - Parameters:
    ///   - defaultSessionKey: Fallback session key.
    ///   - includeChannelID: Include channel ID in derived key.
    ///   - includeAccountID: Include account ID in derived key.
    ///   - includePeerID: Include peer ID in derived key.
    public init(
        defaultSessionKey: String = "main",
        includeChannelID: Bool = true,
        includeAccountID: Bool = true,
        includePeerID: Bool = true
    ) {
        self.defaultSessionKey = defaultSessionKey
        self.includeChannelID = includeChannelID
        self.includeAccountID = includeAccountID
        self.includePeerID = includePeerID
    }

    private enum CodingKeys: String, CodingKey {
        case defaultSessionKey
        case includeChannelID
        case includeAccountID
        case includePeerID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultSessionKey = try container.decodeIfPresent(String.self, forKey: .defaultSessionKey) ?? "main"
        self.includeChannelID = try container.decodeIfPresent(Bool.self, forKey: .includeChannelID) ?? true
        self.includeAccountID = try container.decodeIfPresent(Bool.self, forKey: .includeAccountID) ?? true
        self.includePeerID = try container.decodeIfPresent(Bool.self, forKey: .includePeerID) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.defaultSessionKey, forKey: .defaultSessionKey)
        try container.encode(self.includeChannelID, forKey: .includeChannelID)
        try container.encode(self.includeAccountID, forKey: .includeAccountID)
        try container.encode(self.includePeerID, forKey: .includePeerID)
    }
}

/// Channel adapter related configuration.
public struct ChannelsConfig: Codable, Sendable, Equatable {
    public var discord: DiscordChannelConfig
    public var telegram: TelegramChannelConfig
    public var whatsappCloud: WhatsAppCloudChannelConfig
    public var slack: SlackChannelConfig
    public var googleChat: GoogleChatChannelConfig
    public var signal: SignalChannelConfig
    public var imessage: IMessageChannelConfig
    public var msteams: MicrosoftTeamsChannelConfig
    public var webchat: WebChatChannelConfig

    /// Creates channel config.
    /// - Parameter discord: Discord channel settings.
    /// - Parameter telegram: Telegram channel settings.
    /// - Parameter whatsappCloud: WhatsApp Cloud API channel settings.
    /// - Parameter slack: Slack channel settings.
    /// - Parameter googleChat: Google Chat channel settings.
    /// - Parameter signal: Signal channel settings.
    /// - Parameter imessage: iMessage channel settings.
    /// - Parameter msteams: Microsoft Teams channel settings.
    /// - Parameter webchat: WebChat channel settings.
    public init(
        discord: DiscordChannelConfig = DiscordChannelConfig(),
        telegram: TelegramChannelConfig = TelegramChannelConfig(),
        whatsappCloud: WhatsAppCloudChannelConfig = WhatsAppCloudChannelConfig(),
        slack: SlackChannelConfig = SlackChannelConfig(),
        googleChat: GoogleChatChannelConfig = GoogleChatChannelConfig(),
        signal: SignalChannelConfig = SignalChannelConfig(),
        imessage: IMessageChannelConfig = IMessageChannelConfig(),
        msteams: MicrosoftTeamsChannelConfig = MicrosoftTeamsChannelConfig(),
        webchat: WebChatChannelConfig = WebChatChannelConfig()
    ) {
        self.discord = discord
        self.telegram = telegram
        self.whatsappCloud = whatsappCloud
        self.slack = slack
        self.googleChat = googleChat
        self.signal = signal
        self.imessage = imessage
        self.msteams = msteams
        self.webchat = webchat
    }

    private enum CodingKeys: String, CodingKey {
        case discord
        case telegram
        case whatsappCloud
        case slack
        case googlechat
        case signal
        case imessage
        case msteams
        case webchat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.discord = try container.decodeIfPresent(DiscordChannelConfig.self, forKey: .discord) ?? DiscordChannelConfig()
        self.telegram = try container.decodeIfPresent(TelegramChannelConfig.self, forKey: .telegram) ?? TelegramChannelConfig()
        self.whatsappCloud = try container.decodeIfPresent(WhatsAppCloudChannelConfig.self, forKey: .whatsappCloud) ?? WhatsAppCloudChannelConfig()
        self.slack = try container.decodeIfPresent(SlackChannelConfig.self, forKey: .slack) ?? SlackChannelConfig()
        self.googleChat = try container.decodeIfPresent(GoogleChatChannelConfig.self, forKey: .googlechat) ?? GoogleChatChannelConfig()
        self.signal = try container.decodeIfPresent(SignalChannelConfig.self, forKey: .signal) ?? SignalChannelConfig()
        self.imessage = try container.decodeIfPresent(IMessageChannelConfig.self, forKey: .imessage) ?? IMessageChannelConfig()
        self.msteams = try container.decodeIfPresent(MicrosoftTeamsChannelConfig.self, forKey: .msteams) ?? MicrosoftTeamsChannelConfig()
        self.webchat = try container.decodeIfPresent(WebChatChannelConfig.self, forKey: .webchat) ?? WebChatChannelConfig()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.discord, forKey: .discord)
        try container.encode(self.telegram, forKey: .telegram)
        try container.encode(self.whatsappCloud, forKey: .whatsappCloud)
        try container.encode(self.slack, forKey: .slack)
        try container.encode(self.googleChat, forKey: .googlechat)
        try container.encode(self.signal, forKey: .signal)
        try container.encode(self.imessage, forKey: .imessage)
        try container.encode(self.msteams, forKey: .msteams)
        try container.encode(self.webchat, forKey: .webchat)
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

/// Model routing and provider settings.
public struct ModelsConfig: Codable, Sendable, Equatable {
    public var defaultProviderID: String
    public var systemPrompt: String?
    public var openAI: OpenAIModelConfig
    public var openAICompatible: OpenAICompatibleModelConfig
    public var anthropic: AnthropicModelConfig
    public var gemini: GeminiModelConfig
    public var foundation: FoundationModelConfig
    public var local: LocalModelConfig
    public var providers: [String: ProviderServiceConfig]

    /// Creates model settings.
    /// - Parameters:
    ///   - defaultProviderID: Default provider ID when none is specified.
    ///   - systemPrompt: Optional system prompt prefix.
    ///   - openAI: OpenAI provider settings.
    ///   - openAICompatible: Generic OpenAI-compatible provider settings.
    ///   - anthropic: Anthropic provider settings.
    ///   - gemini: Gemini provider settings.
    ///   - foundation: Foundation Models settings.
    ///   - local: Local model settings.
    ///   - providers: Extended provider service matrix keyed by provider ID.
    public init(
        defaultProviderID: String = "echo",
        systemPrompt: String? = nil,
        openAI: OpenAIModelConfig = OpenAIModelConfig(),
        openAICompatible: OpenAICompatibleModelConfig = OpenAICompatibleModelConfig(),
        anthropic: AnthropicModelConfig = AnthropicModelConfig(),
        gemini: GeminiModelConfig = GeminiModelConfig(),
        foundation: FoundationModelConfig = FoundationModelConfig(),
        local: LocalModelConfig = LocalModelConfig(),
        providers: [String: ProviderServiceConfig] = [:]
    ) {
        self.defaultProviderID = defaultProviderID
        self.systemPrompt = systemPrompt
        self.openAI = openAI
        self.openAICompatible = openAICompatible
        self.anthropic = anthropic
        self.gemini = gemini
        self.foundation = foundation
        self.local = local
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey {
        case defaultProviderID
        case systemPrompt
        case openAI
        case openAICompatible
        case anthropic
        case gemini
        case foundation
        case local
        case providers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultProviderID = try container.decodeIfPresent(String.self, forKey: .defaultProviderID) ?? "echo"
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.openAI = try container.decodeIfPresent(OpenAIModelConfig.self, forKey: .openAI) ?? OpenAIModelConfig()
        self.openAICompatible = try container.decodeIfPresent(OpenAICompatibleModelConfig.self, forKey: .openAICompatible) ?? OpenAICompatibleModelConfig()
        self.anthropic = try container.decodeIfPresent(AnthropicModelConfig.self, forKey: .anthropic) ?? AnthropicModelConfig()
        self.gemini = try container.decodeIfPresent(GeminiModelConfig.self, forKey: .gemini) ?? GeminiModelConfig()
        self.foundation = try container.decodeIfPresent(FoundationModelConfig.self, forKey: .foundation) ?? FoundationModelConfig()
        self.local = try container.decodeIfPresent(LocalModelConfig.self, forKey: .local) ?? LocalModelConfig()
        self.providers = try container.decodeIfPresent([String: ProviderServiceConfig].self, forKey: .providers) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.defaultProviderID, forKey: .defaultProviderID)
        try container.encodeIfPresent(self.systemPrompt, forKey: .systemPrompt)
        try container.encode(self.openAI, forKey: .openAI)
        try container.encode(self.openAICompatible, forKey: .openAICompatible)
        try container.encode(self.anthropic, forKey: .anthropic)
        try container.encode(self.gemini, forKey: .gemini)
        try container.encode(self.foundation, forKey: .foundation)
        try container.encode(self.local, forKey: .local)
        try container.encode(self.providers, forKey: .providers)
    }
}

/// API contract style used by an extended provider service.
public enum ProviderServiceAPIStyle: String, Codable, Sendable, Equatable, CaseIterable {
    case openAICompletions
    case anthropicMessages
    case bedrockConverse
    case ollama
    case custom
}

/// Authentication mode used by an extended provider service.
public enum ProviderServiceAuthMode: String, Codable, Sendable, Equatable, CaseIterable {
    case apiKey
    case bearerToken
    case oauthToken
    case awsSDK
    case none
}

/// Extended provider service configuration used for parity provider matrices.
public struct ProviderServiceConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var apiStyle: ProviderServiceAPIStyle
    public var authMode: ProviderServiceAuthMode
    public var modelID: String
    public var apiKey: String?
    public var accessToken: String?
    public var baseURL: String
    public var chatCompletionsPath: String
    public var messagesPath: String
    public var apiVersion: String?
    public var organizationID: String?
    public var headers: [String: String]
    public var region: String?
    public var profile: String?
    public var tenantID: String?
    public var scope: String?
    public var metadata: [String: String]

    /// Creates a provider service configuration block.
    /// - Parameters:
    ///   - enabled: Enables this provider service.
    ///   - apiStyle: API style contract for this provider service.
    ///   - authMode: Authentication mode for this provider.
    ///   - modelID: Default model identifier.
    ///   - apiKey: Optional API key secret.
    ///   - accessToken: Optional bearer/OAuth access token.
    ///   - baseURL: API base URL.
    ///   - chatCompletionsPath: Relative OpenAI-style chat completions path.
    ///   - messagesPath: Relative Anthropic-style messages path.
    ///   - apiVersion: Optional provider API version.
    ///   - organizationID: Optional organization or project identifier.
    ///   - headers: Additional static headers.
    ///   - region: Optional region identifier.
    ///   - profile: Optional profile identifier.
    ///   - tenantID: Optional tenant identifier.
    ///   - scope: Optional OAuth scope identifier.
    ///   - metadata: Additional provider metadata.
    public init(
        enabled: Bool = false,
        apiStyle: ProviderServiceAPIStyle = .openAICompletions,
        authMode: ProviderServiceAuthMode = .apiKey,
        modelID: String = "gpt-4.1-mini",
        apiKey: String? = nil,
        accessToken: String? = nil,
        baseURL: String = "https://api.openai.com/v1",
        chatCompletionsPath: String = "chat/completions",
        messagesPath: String = "messages",
        apiVersion: String? = nil,
        organizationID: String? = nil,
        headers: [String: String] = [:],
        region: String? = nil,
        profile: String? = nil,
        tenantID: String? = nil,
        scope: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.enabled = enabled
        self.apiStyle = apiStyle
        self.authMode = authMode
        self.modelID = modelID
        self.apiKey = apiKey
        self.accessToken = accessToken
        self.baseURL = baseURL
        self.chatCompletionsPath = chatCompletionsPath
        self.messagesPath = messagesPath
        self.apiVersion = apiVersion
        self.organizationID = organizationID
        self.headers = headers
        self.region = region
        self.profile = profile
        self.tenantID = tenantID
        self.scope = scope
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case apiStyle
        case authMode
        case modelID
        case apiKey
        case accessToken
        case baseURL
        case chatCompletionsPath
        case messagesPath
        case apiVersion
        case organizationID
        case headers
        case region
        case profile
        case tenantID
        case scope
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.apiStyle = try container.decodeIfPresent(ProviderServiceAPIStyle.self, forKey: .apiStyle) ?? .openAICompletions
        self.authMode = try container.decodeIfPresent(ProviderServiceAuthMode.self, forKey: .authMode) ?? .apiKey
        self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? "gpt-4.1-mini"
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        self.accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        self.chatCompletionsPath = try container.decodeIfPresent(String.self, forKey: .chatCompletionsPath) ?? "chat/completions"
        self.messagesPath = try container.decodeIfPresent(String.self, forKey: .messagesPath) ?? "messages"
        self.apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion)
        self.organizationID = try container.decodeIfPresent(String.self, forKey: .organizationID)
        self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.region = try container.decodeIfPresent(String.self, forKey: .region)
        self.profile = try container.decodeIfPresent(String.self, forKey: .profile)
        self.tenantID = try container.decodeIfPresent(String.self, forKey: .tenantID)
        self.scope = try container.decodeIfPresent(String.self, forKey: .scope)
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}

/// OpenAI provider-specific configuration.
public struct OpenAIModelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var modelID: String
    public var apiKey: String?
    public var baseURL: String

    /// Creates OpenAI provider settings.
    /// - Parameters:
    ///   - enabled: Enables OpenAI provider routing.
    ///   - modelID: OpenAI model identifier.
    ///   - apiKey: OpenAI API key.
    ///   - baseURL: OpenAI-compatible API base URL.
    public init(
        enabled: Bool = false,
        modelID: String = "gpt-4.1-mini",
        apiKey: String? = nil,
        baseURL: String = "https://api.openai.com/v1"
    ) {
        self.enabled = enabled
        self.modelID = modelID
        self.apiKey = apiKey
        self.baseURL = baseURL
    }
}

/// Generic OpenAI-compatible provider settings.
public struct OpenAICompatibleModelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var modelID: String
    public var apiKey: String?
    public var baseURL: String
    public var chatCompletionsPath: String

    /// Creates OpenAI-compatible provider settings.
    /// - Parameters:
    ///   - enabled: Enables the provider.
    ///   - modelID: Model identifier.
    ///   - apiKey: API key or bearer token.
    ///   - baseURL: API base URL.
    ///   - chatCompletionsPath: Relative chat completions endpoint path.
    public init(
        enabled: Bool = false,
        modelID: String = "gpt-4.1-mini",
        apiKey: String? = nil,
        baseURL: String = "https://api.openai.com/v1",
        chatCompletionsPath: String = "chat/completions"
    ) {
        self.enabled = enabled
        self.modelID = modelID
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.chatCompletionsPath = chatCompletionsPath
    }
}

/// Anthropic provider settings.
public struct AnthropicModelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var modelID: String
    public var apiKey: String?
    public var baseURL: String
    public var apiVersion: String
    public var maxTokens: Int

    /// Creates Anthropic provider settings.
    /// - Parameters:
    ///   - enabled: Enables the provider.
    ///   - modelID: Anthropic model identifier.
    ///   - apiKey: Anthropic API key.
    ///   - baseURL: Anthropic API base URL.
    ///   - apiVersion: Anthropic API version header.
    ///   - maxTokens: Maximum output tokens.
    public init(
        enabled: Bool = false,
        modelID: String = "claude-3-5-haiku-latest",
        apiKey: String? = nil,
        baseURL: String = "https://api.anthropic.com/v1",
        apiVersion: String = "2023-06-01",
        maxTokens: Int = 512
    ) {
        self.enabled = enabled
        self.modelID = modelID
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.maxTokens = max(1, maxTokens)
    }
}

/// Gemini provider settings.
public struct GeminiModelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var modelID: String
    public var apiKey: String?
    public var baseURL: String

    /// Creates Gemini provider settings.
    /// - Parameters:
    ///   - enabled: Enables the provider.
    ///   - modelID: Gemini model identifier.
    ///   - apiKey: Gemini API key.
    ///   - baseURL: Gemini API base URL.
    public init(
        enabled: Bool = false,
        modelID: String = "gemini-2.0-flash",
        apiKey: String? = nil,
        baseURL: String = "https://generativelanguage.googleapis.com/v1beta"
    ) {
        self.enabled = enabled
        self.modelID = modelID
        self.apiKey = apiKey
        self.baseURL = baseURL
    }
}

/// Apple Foundation Models provider settings.
public struct FoundationModelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var preferredModelID: String?

    /// Creates Foundation Models settings.
    /// - Parameters:
    ///   - enabled: Enables provider selection.
    ///   - preferredModelID: Optional preferred model name.
    public init(enabled: Bool = false, preferredModelID: String? = nil) {
        self.enabled = enabled
        self.preferredModelID = preferredModelID
    }
}

/// Local inference runtime/provider settings.
public struct LocalModelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var runtime: String
    public var modelPath: String?
    public var contextWindow: Int
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var useMetal: Bool
    public var streamTokens: Bool
    public var allowCancellation: Bool
    public var requestTimeoutMs: Int
    public var fallbackModelPaths: [String]
    public var runtimeOptions: [String: String]
    public var maxTokens: Int

    /// Creates local model settings.
    /// - Parameters:
    ///   - enabled: Enables local provider selection.
    ///   - runtime: Runtime identifier (for example, `llmfarm`).
    ///   - modelPath: Model artifact path.
    ///   - contextWindow: Token context window size.
    ///   - temperature: Sampling temperature.
    ///   - topP: Top-p sampling value.
    ///   - topK: Top-k sampling value.
    ///   - useMetal: Enables Metal acceleration where available.
    ///   - streamTokens: Enables token streaming requests.
    ///   - allowCancellation: Enables cancellation-aware generation requests.
    ///   - requestTimeoutMs: Default local request timeout in milliseconds.
    ///   - fallbackModelPaths: Ordered local model fallback paths.
    ///   - runtimeOptions: Additional runtime-specific option key/value pairs.
    ///   - maxTokens: Maximum generated token count.
    public init(
        enabled: Bool = false,
        runtime: String = "llmfarm",
        modelPath: String? = nil,
        contextWindow: Int = 4096,
        temperature: Double = 0.7,
        topP: Double = 0.95,
        topK: Int = 40,
        useMetal: Bool = true,
        streamTokens: Bool = true,
        allowCancellation: Bool = true,
        requestTimeoutMs: Int = 60_000,
        fallbackModelPaths: [String] = [],
        runtimeOptions: [String: String] = [:],
        maxTokens: Int = 512
    ) {
        self.enabled = enabled
        self.runtime = runtime
        self.modelPath = modelPath
        self.contextWindow = contextWindow
        self.temperature = temperature
        self.topP = topP
        self.topK = max(1, topK)
        self.useMetal = useMetal
        self.streamTokens = streamTokens
        self.allowCancellation = allowCancellation
        self.requestTimeoutMs = max(1, requestTimeoutMs)
        self.fallbackModelPaths = fallbackModelPaths
        self.runtimeOptions = runtimeOptions
        self.maxTokens = max(1, maxTokens)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case runtime
        case modelPath
        case contextWindow
        case temperature
        case topP
        case topK
        case useMetal
        case streamTokens
        case allowCancellation
        case requestTimeoutMs
        case fallbackModelPaths
        case runtimeOptions
        case maxTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.runtime = try container.decodeIfPresent(String.self, forKey: .runtime) ?? "llmfarm"
        self.modelPath = try container.decodeIfPresent(String.self, forKey: .modelPath)
        self.contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 4096
        self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        self.topP = try container.decodeIfPresent(Double.self, forKey: .topP) ?? 0.95
        self.topK = max(1, try container.decodeIfPresent(Int.self, forKey: .topK) ?? 40)
        self.useMetal = try container.decodeIfPresent(Bool.self, forKey: .useMetal) ?? true
        self.streamTokens = try container.decodeIfPresent(Bool.self, forKey: .streamTokens) ?? true
        self.allowCancellation = try container.decodeIfPresent(Bool.self, forKey: .allowCancellation) ?? true
        self.requestTimeoutMs = max(
            1,
            try container.decodeIfPresent(Int.self, forKey: .requestTimeoutMs) ?? 60_000
        )
        self.fallbackModelPaths = try container.decodeIfPresent([String].self, forKey: .fallbackModelPaths) ?? []
        self.runtimeOptions = try container.decodeIfPresent([String: String].self, forKey: .runtimeOptions) ?? [:]
        self.maxTokens = max(1, try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 512)
    }
}

