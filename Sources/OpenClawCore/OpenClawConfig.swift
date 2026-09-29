import Foundation

/// Root configuration object for runtime, routing, channels, and models.
///
/// The `mcp`, `skills`, `memory` and `plugins` sections use the upstream `openclaw.json` shapes
/// (``OpenClawConfigDocument/MCP``, ``OpenClawConfigDocument/Skills``, ``OpenClawConfigDocument/Memory``
/// and ``OpenClawConfigDocument/Plugins``): they decode the upstream JSON losslessly, so runtime
/// modules can bridge them to their own configuration types (`MCPConfig`, `SkillsConfiguration`,
/// `MemoryEngineConfiguration`, …). Absent sections stay `nil` and are not encoded.
public struct OpenClawConfig: Codable, Sendable, Equatable {
    public var secrets: SecretsConfig
    public var gateway: GatewayConfig
    public var agents: AgentsConfig
    public var channels: ChannelsConfig
    public var routing: RoutingConfig
    public var auth: AuthConfig
    public var models: ModelsConfig
    public var runtime: RuntimeConfig
    /// `mcp`: MCP servers and MCP apps (upstream shape).
    @ConfigIndirect public var mcp: OpenClawConfigDocument.MCP?
    /// `skills`: skill loading, limits and per-skill entries (upstream shape).
    @ConfigIndirect public var skills: OpenClawConfigDocument.Skills?
    /// `memory`: citations and `memory.search` (upstream shape).
    @ConfigIndirect public var memory: OpenClawConfigDocument.Memory?
    /// `plugins`: plugin loading, slots and per-plugin entries (upstream shape).
    @ConfigIndirect public var plugins: OpenClawConfigDocument.Plugins?

    /// Creates an OpenClaw runtime configuration.
    /// - Parameters:
    ///   - secrets: Secret provider and resolution settings.
    ///   - gateway: Gateway transport settings.
    ///   - agents: Agent workspace/default settings.
    ///   - channels: Channel adapter settings.
    ///   - routing: Session routing behavior.
    ///   - auth: Auth-profile metadata.
    ///   - models: Model provider settings.
    ///   - runtime: SDK runtime settings.
    ///   - mcp: MCP servers (upstream `mcp`).
    ///   - skills: Skill settings (upstream `skills`).
    ///   - memory: Memory search settings (upstream `memory`).
    ///   - plugins: Plugin settings (upstream `plugins`).
    public init(
        secrets: SecretsConfig = SecretsConfig(),
        gateway: GatewayConfig = GatewayConfig(),
        agents: AgentsConfig = AgentsConfig(),
        channels: ChannelsConfig = ChannelsConfig(),
        routing: RoutingConfig = RoutingConfig(),
        auth: AuthConfig = AuthConfig(),
        models: ModelsConfig = ModelsConfig(),
        runtime: RuntimeConfig = RuntimeConfig(),
        mcp: OpenClawConfigDocument.MCP? = nil,
        skills: OpenClawConfigDocument.Skills? = nil,
        memory: OpenClawConfigDocument.Memory? = nil,
        plugins: OpenClawConfigDocument.Plugins? = nil
    ) {
        self.secrets = secrets
        self.gateway = gateway
        self.agents = agents
        self.channels = channels
        self.routing = routing
        self.auth = auth
        self.models = models
        self.runtime = runtime
        self.mcp = mcp
        self.skills = skills
        self.memory = memory
        self.plugins = plugins
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
        case mcp
        case skills
        case memory
        case plugins
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
        // Upstream-shaped sections decode leniently: a malformed section is dropped (and reported),
        // never failing the whole config.
        self.mcp = container.decodeLenient(OpenClawConfigDocument.MCP.self, forKey: .mcp)
        self.skills = container.decodeLenient(OpenClawConfigDocument.Skills.self, forKey: .skills)
        self.memory = container.decodeLenient(OpenClawConfigDocument.Memory.self, forKey: .memory)
        self.plugins = container.decodeLenient(OpenClawConfigDocument.Plugins.self, forKey: .plugins)
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
        try container.encodeIfPresent(self.mcp, forKey: .mcp)
        try container.encodeIfPresent(self.skills, forKey: .skills)
        try container.encodeIfPresent(self.memory, forKey: .memory)
        try container.encodeIfPresent(self.plugins, forKey: .plugins)
    }
}
