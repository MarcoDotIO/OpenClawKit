import Foundation
import Testing
@testable import OpenClawCore

@Suite("Config and session routing")
struct ConfigSessionRoutingTests {
    @Test
    func configStoreRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-config-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configPath = root.appendingPathComponent("openclaw.json", isDirectory: false)

        let store = ConfigStore(fileURL: configPath, cacheTTLms: 5_000)
        let config = OpenClawConfig(
            gateway: GatewayConfig(host: "0.0.0.0", port: 18800, authMode: "password"),
            agents: AgentsConfig(defaultAgentID: "ops", workspaceRoot: "./workspace-ops"),
            routing: RoutingConfig(defaultSessionKey: "main", includeAccountID: true, includePeerID: true)
        )
        try await store.save(config)

        let loaded = try await store.load()
        #expect(loaded == config)
    }

    @Test
    func channelsConfigDefaultsLoadWhenFieldsMissing() throws {
        let legacyJSON = """
        {
          "channels": {
            "discord": {
              "enabled": true,
              "botToken": "discord-token",
              "defaultChannelID": "123"
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: Data(legacyJSON.utf8))
        #expect(decoded.channels.discord.enabled == true)
        #expect(decoded.channels.telegram.enabled == false)
        #expect(decoded.channels.telegram.baseURL == "https://api.telegram.org")
        #expect(decoded.channels.whatsappCloud.enabled == false)
        #expect(decoded.channels.whatsappCloud.apiVersion == "v20.0")
        #expect(decoded.channels.slack.enabled == false)
        #expect(decoded.channels.googleChat.webhookPath == "/webhooks/googlechat")
        #expect(decoded.channels.signal.serviceURL == "http://127.0.0.1:8080")
        #expect(decoded.channels.imessage.allowUnsupportedPlatformSimulation == false)
        #expect(decoded.channels.msteams.serviceURL == "https://smba.trafficmanager.net/teams/")
        #expect(decoded.channels.webchat.port == 3_001)
    }

    @Test
    func channelsConfigRoundTripsExpandedChannelSettings() throws {
        let config = OpenClawConfig(
            channels: ChannelsConfig(
                discord: DiscordChannelConfig(enabled: true, botToken: "discord", defaultChannelID: "1"),
                telegram: TelegramChannelConfig(
                    enabled: true,
                    botToken: "telegram",
                    defaultChatID: "456",
                    pollIntervalMs: 3_000,
                    mentionOnly: false
                ),
                whatsappCloud: WhatsAppCloudChannelConfig(
                    enabled: true,
                    accessToken: "wa-token",
                    phoneNumberID: "pnid",
                    webhookVerifyToken: "verify-token"
                ),
                slack: SlackChannelConfig(
                    enabled: true,
                    botToken: "xoxb-token",
                    appToken: "xapp-token",
                    signingSecret: "slack-signing-secret",
                    defaultChannelID: "C123",
                    mentionOnly: false
                ),
                googleChat: GoogleChatChannelConfig(
                    enabled: true,
                    bearerToken: "googlechat-token",
                    verificationToken: "verify-googlechat",
                    defaultSpaceID: "spaces/AAA",
                    pollIntervalMs: 3_000
                ),
                signal: SignalChannelConfig(
                    enabled: true,
                    accountID: "+15551234",
                    authToken: "signal-token",
                    defaultRecipient: "+15557654",
                    pollIntervalMs: 1_500
                ),
                imessage: IMessageChannelConfig(
                    enabled: true,
                    bundleIdentifier: "io.marcodotio.OpenClawKit",
                    defaultHandle: "user@icloud.com",
                    allowUnsupportedPlatformSimulation: true
                ),
                msteams: MicrosoftTeamsChannelConfig(
                    enabled: true,
                    botAppID: "ms-app-id",
                    botAppPassword: "ms-app-password",
                    tenantID: "tenant-id",
                    defaultConversationID: "conversation-id",
                    mentionOnly: false
                ),
                webchat: WebChatChannelConfig(
                    enabled: true,
                    host: "0.0.0.0",
                    port: 4_040,
                    sharedSecret: "webchat-shared-secret",
                    transcriptLimit: 500
                )
            )
        )
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: encoded)
        #expect(decoded.channels.telegram.enabled == true)
        #expect(decoded.channels.telegram.defaultChatID == "456")
        #expect(decoded.channels.whatsappCloud.enabled == true)
        #expect(decoded.channels.whatsappCloud.phoneNumberID == "pnid")
        #expect(decoded.channels.slack.defaultChannelID == "C123")
        #expect(decoded.channels.googleChat.defaultSpaceID == "spaces/AAA")
        #expect(decoded.channels.signal.defaultRecipient == "+15557654")
        #expect(decoded.channels.imessage.defaultHandle == "user@icloud.com")
        #expect(decoded.channels.msteams.defaultConversationID == "conversation-id")
        #expect(decoded.channels.webchat.transcriptLimit == 500)
    }

    @Test
    func localModelConfigDecodesWithDefaultsWhenNewFieldsMissing() throws {
        let legacyJSON = """
        {
          "models": {
            "defaultProviderID": "local",
            "local": {
              "enabled": true,
              "runtime": "llmfarm",
              "modelPath": "/tmp/model.gguf",
              "contextWindow": 4096,
              "temperature": 0.8,
              "topP": 0.9,
              "maxTokens": 256
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: Data(legacyJSON.utf8))
        let local = decoded.models.local
        #expect(local.enabled == true)
        #expect(local.modelPath == "/tmp/model.gguf")
        #expect(local.topK == 40)
        #expect(local.useMetal == true)
        #expect(local.streamTokens == true)
        #expect(local.allowCancellation == true)
        #expect(local.requestTimeoutMs == 60_000)
        #expect(local.fallbackModelPaths.isEmpty)
        #expect(local.runtimeOptions.isEmpty)
    }

    @Test
    func providerMatrixDefaultsLoadWhenMissing() throws {
        let legacyJSON = """
        {
          "models": {
            "defaultProviderID": "openai",
            "openAI": {
              "enabled": true,
              "modelID": "gpt-4.1-mini",
              "baseURL": "https://api.openai.com/v1"
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: Data(legacyJSON.utf8))
        #expect(decoded.models.providers.isEmpty)
    }

    @Test
    func providerMatrixRoundTripsExtendedServiceDefinitions() throws {
        let config = OpenClawConfig(
            models: ModelsConfig(
                defaultProviderID: "openrouter",
                providers: [
                    "openrouter": ModelProviderConfig(
                        enabled: true,
                        baseURL: "https://openrouter.ai/api/v1",
                        apiKey: "openrouter-key",
                        auth: .apiKey,
                        api: .openAICompletions,
                        models: [ModelDefinitionConfig(id: "anthropic/claude-sonnet-4-5", api: .openAICompletions)],
                        chatCompletionsPath: "chat/completions"
                    ),
                    "amazon-bedrock": ModelProviderConfig(
                        enabled: true,
                        baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                        auth: .awsSDK,
                        api: .bedrockConverseStream,
                        models: [ModelDefinitionConfig(id: "anthropic.claude-3-5-sonnet", api: .bedrockConverseStream)],
                        region: "us-east-1",
                        profile: "default",
                        metadata: [
                            "runtime": "aws-sdk",
                        ]
                    ),
                    "qwen-portal": ModelProviderConfig(
                        enabled: true,
                        baseURL: "https://portal.qwen.ai/v1",
                        apiKey: "qwen-oauth-token",
                        auth: .oauth,
                        api: .openAICompletions,
                        models: [ModelDefinitionConfig(id: "coder-model", api: .openAICompletions)],
                        scope: "models.read"
                    ),
                ]
            )
        )

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: encoded)
        #expect(decoded.models.defaultProviderID == "openrouter")
        #expect(decoded.models.providers["openrouter"]?.enabled == true)
        #expect(decoded.models.providers["openrouter"]?.api == .openAICompletions)
        #expect(decoded.models.providers["amazon-bedrock"]?.auth == .awsSDK)
        #expect(decoded.models.providers["amazon-bedrock"]?.region == "us-east-1")
        #expect(decoded.models.providers["qwen-portal"]?.auth == .oauth)
        #expect(decoded.models.providers["qwen-portal"]?.apiKey == "qwen-oauth-token")
        #expect(decoded.models.providers["qwen-portal"]?.models.first?.id == "coder-model")
    }

    @Test
    func providerMatrixLegacyShapeStillDecodesIntoCanonicalProviders() throws {
        let legacyJSON = """
        {
          "models": {
            "defaultProviderID": "openrouter",
            "providers": {
              "openrouter": {
                "enabled": true,
                "apiStyle": "openAICompletions",
                "authMode": "apiKey",
                "modelID": "anthropic/claude-sonnet-4-5",
                "apiKey": "openrouter-key",
                "baseURL": "https://openrouter.ai/api/v1"
              },
              "qwen-portal": {
                "enabled": true,
                "apiStyle": "openAICompletions",
                "authMode": "oauthToken",
                "modelID": "coder-model",
                "accessToken": "qwen-oauth-token",
                "baseURL": "https://portal.qwen.ai/v1"
              }
            }
          }
        }
        """

        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: Data(legacyJSON.utf8))
        #expect(decoded.models.providers["openrouter"]?.api == .openAICompletions)
        #expect(decoded.models.providers["qwen-portal"]?.auth == .oauth)
        #expect(decoded.models.providers["qwen-portal"]?.apiKey == "qwen-oauth-token")
    }

    @Test
    func providerMatrixRoundTripsGatewayHeadersAndVersionOverrides() throws {
        let config = OpenClawConfig(
            models: ModelsConfig(
                defaultProviderID: "synthetic",
                providers: [
                    "synthetic": ModelProviderConfig(
                        enabled: true,
                        baseURL: "https://api.synthetic.new/anthropic",
                        apiKey: "synthetic-key",
                        auth: .apiKey,
                        api: .anthropicMessages,
                        headers: [
                            "x-gateway-route": "edge",
                            "x-team": "runtime",
                        ],
                        models: [ModelDefinitionConfig(id: "hf:MiniMaxAI/MiniMax-M2.1", api: .anthropicMessages)],
                        chatCompletionsPath: "chat/completions",
                        messagesPath: "messages",
                        apiVersion: "2023-06-01",
                        organizationID: "org_openclaw",
                        region: nil,
                        profile: nil,
                        tenantID: nil,
                        scope: "models.read",
                        metadata: [
                            "maxTokens": "4096",
                        ]
                    ),
                ]
            )
        )

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: encoded)
        let synthetic = decoded.models.providers["synthetic"]

        #expect(synthetic?.apiVersion == "2023-06-01")
        #expect(synthetic?.organizationID == "org_openclaw")
        #expect(synthetic?.headers["x-gateway-route"] == "edge")
        #expect(synthetic?.scope == "models.read")
        #expect(synthetic?.metadata["maxTokens"] == "4096")
    }

    @Test
    func authConfigRoundTripsProfilesAndCooldowns() throws {
        let config = OpenClawConfig(
            auth: AuthConfig(
                profiles: [
                    "openai-codex:work": AuthProfileConfig(provider: "openai-codex", mode: .oauth, email: "work@example.com"),
                    "github-copilot:default": AuthProfileConfig(provider: "github-copilot", mode: .token),
                ],
                order: [
                    "openai-codex": ["openai-codex:work"],
                ],
                cooldowns: AuthCooldownConfig(
                    billingBackoffHours: 6,
                    billingBackoffHoursByProvider: ["github-copilot": 2],
                    billingMaxHours: 12,
                    failureWindowHours: 18
                )
            )
        )

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: encoded)
        #expect(decoded.auth.profiles["openai-codex:work"]?.mode == .oauth)
        #expect(decoded.auth.order["openai-codex"] == ["openai-codex:work"])
        #expect(decoded.auth.cooldowns.billingBackoffHoursByProvider["github-copilot"] == 2)
        #expect(decoded.auth.cooldowns.billingMaxHours == 12)
    }

    @Test
    func runtimeConfigDefaultsLoadWhenFieldsMissing() throws {
        let legacyJSON = """
        {
          "gateway": {
            "host": "127.0.0.1",
            "port": 18789,
            "authMode": "token"
          }
        }
        """
        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: Data(legacyJSON.utf8))
        #expect(decoded.runtime.schemaVersion == ReplayEvent.currentSchemaVersion)
        #expect(decoded.runtime.replay.enabled == false)
        #expect(decoded.runtime.replay.persistToDisk == true)
        #expect(decoded.runtime.adaptiveRouting.enabled == false)
        #expect(decoded.runtime.adaptiveRouting.objective == .balanced)
        #expect(decoded.runtime.memoryGraph.enabled == false)
        #expect(decoded.runtime.memoryGraph.swiftDataEnabled == true)
        #expect(decoded.runtime.memoryGraph.cloudKitSyncEnabled == false)
    }

    @Test
    func runtimeConfigRoundTripsReplayAndAdaptiveRouting() throws {
        let config = OpenClawConfig(
            runtime: RuntimeConfig(
                schemaVersion: 3,
                replay: ReplayConfig(
                    enabled: true,
                    persistToDisk: true,
                    maxInMemoryEvents: 5_000,
                    storePath: "/tmp/openclaw/replay.jsonl",
                    signEvents: true
                ),
                adaptiveRouting: AdaptiveRoutingConfig(
                    enabled: true,
                    minSamplesPerProvider: 15,
                    explorationRate: 0.12,
                    decisionWindow: 750,
                    objective: .quality
                ),
                memoryGraph: MemoryGraphConfig(
                    enabled: true,
                    swiftDataEnabled: true,
                    cloudKitSyncEnabled: true,
                    cloudKitContainerID: "iCloud.io.marcodotio.openclaw",
                    legacyStorePath: "/tmp/openclaw/conversation-memory.json"
                )
            )
        )
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: encoded)
        #expect(decoded.runtime == config.runtime)
    }

    @Test
    func configStoreCacheCanBeCleared() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-config-cache-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("openclaw.json", isDirectory: false)

        let store = ConfigStore(fileURL: path, cacheTTLms: 60_000)
        try await store.save(OpenClawConfig(gateway: GatewayConfig(port: 18789)))
        let first = try await store.loadCached()
        #expect(first.gateway.port == 18789)

        try await store.save(OpenClawConfig(gateway: GatewayConfig(port: 19999)))
        let cached = try await store.loadCached()
        #expect(cached.gateway.port == 19999)

        await store.clearCache()
        let refreshed = try await store.loadCached()
        #expect(refreshed.gateway.port == 19999)
    }

    @Test
    func sessionKeyResolverUsesRoutingConfig() {
        let config = OpenClawConfig(
            routing: RoutingConfig(defaultSessionKey: "main", includeAccountID: true, includePeerID: true)
        )
        let context = SessionRoutingContext(channel: "telegram", accountID: "default", peerID: "1234")
        let key = SessionKeyResolver.resolve(explicit: nil, context: context, config: config)
        #expect(key == "telegram:default:1234")
    }

    @Test
    func sessionKeyResolverCanUseSharedFallbackAcrossChannels() {
        let config = OpenClawConfig(
            routing: RoutingConfig(
                defaultSessionKey: "shared",
                includeChannelID: false,
                includeAccountID: false,
                includePeerID: false
            )
        )
        let webchat = SessionRoutingContext(channel: "webchat", accountID: nil, peerID: "ios-local-user")
        let discord = SessionRoutingContext(channel: "discord", accountID: "user-1", peerID: "channel-1")
        let webchatKey = SessionKeyResolver.resolve(explicit: nil, context: webchat, config: config)
        let discordKey = SessionKeyResolver.resolve(explicit: nil, context: discord, config: config)
        #expect(webchatKey == "shared")
        #expect(discordKey == "shared")
    }

    @Test
    func agentsConfigResolvesRouteMappedAgentIDs() {
        let agents = AgentsConfig(
            defaultAgentID: "main",
            workspaceRoot: "./workspace",
            agentIDs: ["main", "discord-agent", "ios-agent"],
            routeAgentMap: [
                AgentsConfig.routeKey(channel: "discord"): "discord-agent",
                AgentsConfig.routeKey(channel: "webchat", accountID: "ios-user", peerID: "peer-1"): "ios-agent",
            ]
        )
        let discordAgent = agents.resolvedAgentID(
            for: SessionRoutingContext(channel: "discord", accountID: "123", peerID: "abc")
        )
        let iosAgent = agents.resolvedAgentID(
            for: SessionRoutingContext(channel: "webchat", accountID: "ios-user", peerID: "peer-1")
        )
        let fallbackAgent = agents.resolvedAgentID(
            for: SessionRoutingContext(channel: "telegram", accountID: "u1", peerID: "p1")
        )

        #expect(discordAgent == "discord-agent")
        #expect(iosAgent == "ios-agent")
        #expect(fallbackAgent == "main")
    }

    @Test
    func sessionStoreResolveOrCreateTracksRoute() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-session-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("sessions.json", isDirectory: false)
        let store = SessionStore(fileURL: path)

        let created = await store.resolveOrCreate(
            sessionKey: "telegram:default:1234",
            defaultAgentID: "main",
            route: SessionRoute(channel: "telegram", accountID: "default", peerID: "1234")
        )
        #expect(created.agentID == "main")
        #expect(created.lastRoute?.channel == "telegram")

        let updated = await store.resolveOrCreate(
            sessionKey: "telegram:default:1234",
            defaultAgentID: "support",
            route: SessionRoute(channel: "telegram", accountID: "default", peerID: "1234")
        )
        #expect(updated.agentID == "support")

        try await store.save()
        let reloaded = SessionStore(fileURL: path)
        try await reloaded.load()
        let fetched = await reloaded.recordForKey("telegram:default:1234")
        #expect(fetched?.key == "telegram:default:1234")
    }
}
