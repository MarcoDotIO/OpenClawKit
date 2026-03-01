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
                )
            )
        )
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: encoded)
        #expect(decoded.channels.telegram.enabled == true)
        #expect(decoded.channels.telegram.defaultChatID == "456")
        #expect(decoded.channels.whatsappCloud.enabled == true)
        #expect(decoded.channels.whatsappCloud.phoneNumberID == "pnid")
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

