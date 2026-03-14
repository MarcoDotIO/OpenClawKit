import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore
@testable import OpenClawKit
@testable import OpenClawModels

@Suite("Fast mode parity")
struct FastModeParityTests {
    actor FastModeCapturingProvider: ModelProvider {
        let id = "fast-mode-capture"
        private(set) var capturedFastMode: Bool?

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            self.capturedFastMode = request.policy.fastMode
            return ModelGenerationResponse(text: "ok", providerID: self.id, modelID: "capture")
        }

        func fastMode() -> Bool? {
            self.capturedFastMode
        }
    }

    actor AnthropicTransport: AnthropicHTTPTransport {
        private(set) var lastBody: Data?

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.lastBody = request.httpBody
            return HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data(
                    """
                    {
                      "model": "claude-sonnet-4-5",
                      "content": [{"type":"text","text":"ok"}]
                    }
                    """.utf8
                )
            )
        }

        func bodyString() -> String? {
            guard let lastBody else {
                return nil
            }
            return String(data: lastBody, encoding: .utf8)
        }
    }

    @Test
    func providerServiceFastModeBridgesThroughCanonicalConfig() {
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "https://api.openai.com/v1",
            auth: .apiKey,
            api: .openAIResponses,
            models: [
                ModelDefinitionConfig(id: "gpt-5.4", api: .openAIResponses, fastMode: true),
            ]
        )

        let legacy = config.legacyServiceConfig(providerID: "openai")

        #expect(legacy.fastMode == true)
        #expect(ModelProviderConfig(legacyService: legacy).defaultModel?.fastMode == true)
    }

    @Test
    func rootConfigRoundTripsDedicatedFastModeDefaults() throws {
        let config = OpenClawConfig(
            models: ModelsConfig(
                openAI: OpenAIModelConfig(enabled: true, modelID: "gpt-5.4", fastMode: true, apiKey: "openai-key"),
                anthropic: AnthropicModelConfig(
                    enabled: true,
                    modelID: "claude-sonnet-4-5",
                    fastMode: false,
                    apiKey: "anthropic-key"
                )
            )
        )

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: encoded)

        #expect(decoded.models.openAI.fastMode == true)
        #expect(decoded.models.anthropic.fastMode == false)
    }

    @Test
    func runtimeForwardsFastModeIntoGenerationPolicy() async throws {
        let provider = FastModeCapturingProvider()
        let router = ModelRouter()
        await router.register(provider)
        let runtime = EmbeddedAgentRuntime(modelRouter: router)
        try await runtime.setDefaultModelProviderID("fast-mode-capture")

        _ = try await runtime.run(
            AgentRunRequest(
                sessionKey: "main",
                prompt: "hello",
                fastMode: true
            )
        )

        #expect(await provider.fastMode() == true)
    }

    @Test
    func autoReplyEngineUsesSessionFastModeOverride() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-fast-mode-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sessionStore = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        let registry = ChannelRegistry()
        let adapter = InMemoryChannelAdapter(id: .webchat)
        await registry.register(adapter)
        try await adapter.start()

        let provider = FastModeCapturingProvider()
        let router = ModelRouter()
        await router.register(provider)
        try await router.setDefaultProviderID("fast-mode-capture")
        let runtime = EmbeddedAgentRuntime(modelRouter: router)
        let config = OpenClawConfig()
        let sessionKey = SessionKeyResolver.resolve(
            explicit: nil,
            context: SessionRoutingContext(channel: "webchat", accountID: nil, peerID: "user-1"),
            config: config
        )
        _ = await sessionStore.resolveOrCreate(
            sessionKey: sessionKey,
            defaultAgentID: config.agents.defaultAgentID,
            route: SessionRoute(channel: "webchat", accountID: nil, peerID: "user-1")
        )
        _ = await sessionStore.updateRuntimeState(sessionKey: sessionKey, fastMode: true)

        let engine = AutoReplyEngine(
            config: config,
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime
        )

        _ = try await engine.process(
            InboundMessage(channel: .webchat, peerID: "user-1", text: "hello")
        )

        #expect(await provider.fastMode() == true)
    }

    @Test
    func anthropicFastModeMapsToDirectServiceTierDefaults() async throws {
        let transport = AnthropicTransport()
        let provider = AnthropicModelProvider(
            configuration: AnthropicModelConfig(
                enabled: true,
                modelID: "claude-sonnet-4-5",
                fastMode: true,
                apiKey: "sk-ant-test",
                baseURL: "https://api.anthropic.com/v1",
                maxTokens: 512
            ),
            transport: transport
        )

        _ = try await provider.generate(
            ModelGenerationRequest(sessionKey: "main", prompt: "hello")
        )

        let body = try #require(await transport.bodyString())
        #expect(body.contains("\"service_tier\":\"auto\""))
    }

    @Test
    func anthropicFastModeFalseMapsToStandardOnlyAndSkipsOAuthDefaults() async throws {
        let directTransport = AnthropicTransport()
        let directProvider = ProviderServiceAnthropicModelProvider(
            id: "anthropic",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                authMode: .apiKey,
                modelID: "claude-sonnet-4-5",
                fastMode: false,
                apiKey: "sk-ant-test",
                baseURL: "https://api.anthropic.com/v1"
            ),
            transport: directTransport
        )

        _ = try await directProvider.generate(
            ModelGenerationRequest(sessionKey: "main", prompt: "hello")
        )

        let directBody = try #require(await directTransport.bodyString())
        #expect(directBody.contains("\"service_tier\":\"standard_only\""))

        let oauthTransport = AnthropicTransport()
        let oauthProvider = ProviderServiceAnthropicModelProvider(
            id: "anthropic",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                authMode: .oauthToken,
                modelID: "claude-sonnet-4-5",
                fastMode: true,
                accessToken: "oauth-token",
                baseURL: "https://api.anthropic.com/v1"
            ),
            transport: oauthTransport
        )

        _ = try await oauthProvider.generate(
            ModelGenerationRequest(sessionKey: "main", prompt: "hello")
        )

        let oauthBody = try #require(await oauthTransport.bodyString())
        #expect(oauthBody.contains("service_tier") == false)
    }
}
