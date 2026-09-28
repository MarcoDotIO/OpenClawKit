import Foundation

/// Root configuration object for runtime, routing, channels, and models.
public struct OpenClawConfig: Codable, Sendable, Equatable {
    public var secrets: SecretsConfig
    public var gateway: GatewayConfig
    public var agents: AgentsConfig
    public var channels: ChannelsConfig
    public var routing: RoutingConfig
    public var auth: AuthConfig
    public var models: ModelsConfig
    public var runtime: RuntimeConfig

    /// Creates an OpenClaw runtime configuration.
    /// - Parameters:
    ///   - secrets: Secret provider and resolution settings.
    ///   - gateway: Gateway transport settings.
    ///   - agents: Agent workspace/default settings.
    ///   - channels: Channel adapter settings.
    ///   - routing: Session routing behavior.
    ///   - models: Model provider settings.
    public init(
        secrets: SecretsConfig = SecretsConfig(),
        gateway: GatewayConfig = GatewayConfig(),
        agents: AgentsConfig = AgentsConfig(),
        channels: ChannelsConfig = ChannelsConfig(),
        routing: RoutingConfig = RoutingConfig(),
        auth: AuthConfig = AuthConfig(),
        models: ModelsConfig = ModelsConfig(),
        runtime: RuntimeConfig = RuntimeConfig()
    ) {
        self.secrets = secrets
        self.gateway = gateway
        self.agents = agents
        self.channels = channels
        self.routing = routing
        self.auth = auth
        self.models = models
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey {
        case secrets
        case gateway
        case agents
        case channels
        case routing
        case auth
        case models
        case runtime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.secrets = try container.decodeIfPresent(SecretsConfig.self, forKey: .secrets) ?? SecretsConfig()
        self.gateway = try container.decodeIfPresent(GatewayConfig.self, forKey: .gateway) ?? GatewayConfig()
        self.agents = try container.decodeIfPresent(AgentsConfig.self, forKey: .agents) ?? AgentsConfig()
        self.channels = try container.decodeIfPresent(ChannelsConfig.self, forKey: .channels) ?? ChannelsConfig()
        self.routing = try container.decodeIfPresent(RoutingConfig.self, forKey: .routing) ?? RoutingConfig()
        self.auth = try container.decodeIfPresent(AuthConfig.self, forKey: .auth) ?? AuthConfig()
        self.models = try container.decodeIfPresent(ModelsConfig.self, forKey: .models) ?? ModelsConfig()
        self.runtime = try container.decodeIfPresent(RuntimeConfig.self, forKey: .runtime) ?? RuntimeConfig()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.secrets, forKey: .secrets)
        try container.encode(self.gateway, forKey: .gateway)
        try container.encode(self.agents, forKey: .agents)
        try container.encode(self.channels, forKey: .channels)
        try container.encode(self.routing, forKey: .routing)
        try container.encode(self.auth, forKey: .auth)
        try container.encode(self.models, forKey: .models)
        try container.encode(self.runtime, forKey: .runtime)
    }
}
