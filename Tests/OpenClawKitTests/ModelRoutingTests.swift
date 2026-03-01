import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit

@Suite("Model routing")
struct ModelRoutingTests {
    struct StaticProvider: ModelProvider {
        let id: String
        let text: String

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            _ = request
            return ModelGenerationResponse(text: self.text, providerID: self.id, modelID: "static")
        }
    }

    struct ThrowingProvider: ModelProvider {
        let id: String
        let message: String

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            _ = request
            throw OpenClawCoreError.unavailable(self.message)
        }
    }

    struct StreamingProvider: ModelProvider {
        let id: String

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            _ = request
            return ModelGenerationResponse(text: "stream-final", providerID: self.id, modelID: "stream")
        }

        func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
            _ = request
            return AsyncThrowingStream { continuation in
                continuation.yield(ModelStreamChunk(text: "stream-", isFinal: false))
                continuation.yield(ModelStreamChunk(text: "final", isFinal: true))
                continuation.finish()
            }
        }
    }

    struct DelayedProvider: ModelProvider {
        let id: String
        let text: String
        let delayMs: UInt64

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            _ = request
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            return ModelGenerationResponse(text: self.text, providerID: self.id, modelID: "delayed")
        }
    }

    actor MockOpenAICompatibleTransport: OpenAICompatibleHTTPTransport {
        let statusCode: Int
        let body: Data
        private(set) var lastPath: String?
        private(set) var lastAuthorization: String?

        init(statusCode: Int = 200, body: Data) {
            self.statusCode = statusCode
            self.body = body
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.lastPath = request.url?.path
            self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
            return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: self.body)
        }

        func path() -> String? {
            self.lastPath
        }

        func authorization() -> String? {
            self.lastAuthorization
        }
    }

    actor MockAnthropicTransport: AnthropicHTTPTransport {
        let statusCode: Int
        let body: Data

        init(statusCode: Int = 200, body: Data) {
            self.statusCode = statusCode
            self.body = body
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            _ = request
            return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: self.body)
        }
    }

    actor MockGeminiTransport: GeminiHTTPTransport {
        let statusCode: Int
        let body: Data
        private(set) var lastQuery: String?

        init(statusCode: Int = 200, body: Data) {
            self.statusCode = statusCode
            self.body = body
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.lastQuery = request.url?.query
            return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: self.body)
        }

        func query() -> String? {
            self.lastQuery
        }
    }

    actor MockXAITransport: XAIHTTPTransport {
        let statusCode: Int
        let body: Data
        private(set) var lastPath: String?
        private(set) var lastAuthorization: String?

        init(statusCode: Int = 200, body: Data) {
            self.statusCode = statusCode
            self.body = body
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.lastPath = request.url?.path
            self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
            return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: self.body)
        }

        func path() -> String? {
            self.lastPath
        }

        func authorization() -> String? {
            self.lastAuthorization
        }
    }

    @Test
    func routerUsesDefaultProviderWhenRequestDoesNotSpecifyOne() async throws {
        let router = ModelRouter()
        let response = try await router.generate(
            ModelGenerationRequest(sessionKey: "main", prompt: "hello")
        )

        #expect(response.providerID == EchoModelProvider.defaultID)
        #expect(response.text == "OK")
    }

    @Test
    func routerSupportsRegisteredProviderAsDefault() async throws {
        let router = ModelRouter()
        await router.register(StaticProvider(id: "custom", text: "custom-output"))
        try await router.setDefaultProviderID("custom")

        let response = try await router.generate(
            ModelGenerationRequest(sessionKey: "main", prompt: "hello")
        )
        #expect(response.providerID == "custom")
        #expect(response.text == "custom-output")
    }

    @Test
    func runtimeUsesExplicitProviderFromRunRequest() async throws {
        let router = ModelRouter()
        await router.register(StaticProvider(id: "discord", text: "agent-response"))
        let runtime = EmbeddedAgentRuntime(modelRouter: router)

        let result = try await runtime.run(
            AgentRunRequest(
                sessionKey: "main",
                prompt: "hi",
                modelProviderID: "discord"
            )
        )

        #expect(result.output == "agent-response")
    }

    @Test
    func routerUsesMetadataFallbackWhenRequestedProviderMissing() async throws {
        let router = ModelRouter()
        await router.register(StaticProvider(id: "secondary", text: "secondary-output"))

        let response = try await router.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "hello",
                providerID: "does-not-exist",
                metadata: ["fallbackProviderID": "secondary"]
            )
        )
        #expect(response.providerID == "secondary")
        #expect(response.text == "secondary-output")
    }

    @Test
    func routerFallsBackToNextProviderWhenPrimaryThrows() async throws {
        let router = ModelRouter(defaultProviderID: "fallback", providers: [
            ThrowingProvider(id: "primary", message: "primary failed"),
            StaticProvider(id: "fallback", text: "fallback-output"),
        ])

        let response = try await router.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "hello",
                providerID: "primary"
            )
        )

        #expect(response.providerID == "fallback")
        #expect(response.text == "fallback-output")
    }

    @Test
    func routerUsesOrderedPolicyFallbackChain() async throws {
        let router = ModelRouter(defaultProviderID: "echo", providers: [
            ThrowingProvider(id: "primary", message: "primary failed"),
            ThrowingProvider(id: "secondary", message: "secondary failed"),
            StaticProvider(id: "tertiary", text: "tertiary-output"),
            EchoModelProvider(),
        ])

        let response = try await router.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "hello",
                providerID: "primary",
                policy: ModelGenerationPolicy(
                    fallbackProviderIDs: ["secondary", "tertiary"]
                )
            )
        )

        #expect(response.providerID == "tertiary")
        #expect(response.text == "tertiary-output")
    }

    @Test
    func routerFallsBackWhenPrimaryIsThrottleDropped() async throws {
        let pipeline = RuntimeDiagnosticsPipeline(eventLimit: 50)
        let router = ModelRouter(
            defaultProviderID: "secondary",
            providers: [
                StaticProvider(id: "primary", text: "primary-output"),
                StaticProvider(id: "secondary", text: "secondary-output"),
            ],
            throttlePolicy: ModelProviderThrottlePolicy(
                maxRequestsPerWindow: 1,
                windowMs: 1_000,
                strategy: .drop
            ),
            diagnosticsSink: await pipeline.sink()
        )

        let first = try await router.generate(
            ModelGenerationRequest(sessionKey: "main", prompt: "hello", providerID: "primary")
        )
        let second = try await router.generate(
            ModelGenerationRequest(sessionKey: "main", prompt: "hello", providerID: "primary")
        )

        #expect(first.providerID == "primary")
        #expect(second.providerID == "secondary")

        let events = await pipeline.recentEvents(limit: 50)
        #expect(events.contains(where: { $0.name == "model.throttle.drop" }))
        #expect(events.contains(where: { $0.name == "model.request.retry" }))
    }

    @Test
    func routerThrottleDelayAppliesCooldownAndEmitsDiagnostics() async throws {
        let pipeline = RuntimeDiagnosticsPipeline(eventLimit: 50)
        let router = ModelRouter(
            defaultProviderID: "primary",
            providers: [StaticProvider(id: "primary", text: "primary-output")],
            throttlePolicy: ModelProviderThrottlePolicy(
                maxRequestsPerWindow: 1,
                windowMs: 70,
                strategy: .delay
            ),
            diagnosticsSink: await pipeline.sink()
        )

        let startedAt = Date()
        _ = try await router.generate(
            ModelGenerationRequest(sessionKey: "main", prompt: "hello", providerID: "primary")
        )
        _ = try await router.generate(
            ModelGenerationRequest(sessionKey: "main", prompt: "hello", providerID: "primary")
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed >= 0.06)
        let events = await pipeline.recentEvents(limit: 50)
        #expect(events.contains(where: { $0.name == "model.throttle.delay" }))
    }

    @Test
    func routerGenerateStreamUsesStreamingProviderWhenAvailable() async throws {
        let router = ModelRouter(defaultProviderID: "streamer", providers: [
            StreamingProvider(id: "streamer"),
        ])

        let stream = await router.generateStream(
            ModelGenerationRequest(sessionKey: "main", prompt: "hello", providerID: "streamer")
        )
        var chunks: [ModelStreamChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        #expect(chunks.count == 2)
        #expect(chunks.map(\.text).joined() == "stream-final")
        #expect(chunks.last?.isFinal == true)
    }

    @Test
    func adaptiveRoutingPrefersLowerLatencyProvider() async throws {
        let router = ModelRouter(
            defaultProviderID: "slow",
            providers: [
                DelayedProvider(id: "slow", text: "slow-output", delayMs: 40),
                DelayedProvider(id: "fast", text: "fast-output", delayMs: 1),
            ],
            adaptiveRoutingConfig: AdaptiveRoutingConfig(
                enabled: true,
                minSamplesPerProvider: 1,
                explorationRate: 0,
                decisionWindow: 50,
                objective: .latency
            )
        )

        for _ in 0..<2 {
            _ = try await router.generate(
                ModelGenerationRequest(sessionKey: "main", prompt: "sample", providerID: "slow")
            )
            _ = try await router.generate(
                ModelGenerationRequest(sessionKey: "main", prompt: "sample", providerID: "fast")
            )
        }

        let response = try await router.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "choose fastest",
                metadata: ["fallbackProviderIDs": "slow,fast"]
            )
        )
        #expect(response.providerID == "fast")

        let snapshot = await router.adaptiveRoutingSnapshot(candidateProviderIDs: ["slow", "fast"])
        let scores = snapshot?.providers.reduce(into: [String: Double]()) { partial, score in
            partial[score.providerID] = score.score
        }
        #expect((scores?["fast"] ?? 0) > (scores?["slow"] ?? 0))
    }

    @Test
    func adaptiveRoutingPenalizesFailureRate() async throws {
        let router = ModelRouter(
            defaultProviderID: "stable",
            providers: [
                ThrowingProvider(id: "flaky", message: "flaky-failure"),
                StaticProvider(id: "stable", text: "stable-output"),
            ],
            adaptiveRoutingConfig: AdaptiveRoutingConfig(
                enabled: true,
                minSamplesPerProvider: 1,
                explorationRate: 0,
                decisionWindow: 50,
                objective: .balanced
            )
        )

        for _ in 0..<3 {
            _ = try await router.generate(
                ModelGenerationRequest(
                    sessionKey: "main",
                    prompt: "sample",
                    providerID: "flaky",
                    policy: ModelGenerationPolicy(fallbackProviderIDs: ["stable"])
                )
            )
        }

        let response = try await router.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "choose reliable",
                metadata: ["fallbackProviderIDs": "flaky,stable"]
            )
        )
        #expect(response.providerID == "stable")

        let snapshot = await router.adaptiveRoutingSnapshot(candidateProviderIDs: ["flaky", "stable"])
        let scores = snapshot?.providers.reduce(into: [String: Double]()) { partial, score in
            partial[score.providerID] = score.score
        }
        #expect((scores?["stable"] ?? 0) > (scores?["flaky"] ?? 0))
    }

    @Test
    func openAICompatibleProviderParsesChatCompletionResponse() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"gpt-4.1-mini","choices":[{"index":0,"message":{"role":"assistant","content":"compat-output"}}]}
            """.utf8)
        )
        let provider = OpenAICompatibleModelProvider(
            configuration: OpenAICompatibleModelConfig(
                enabled: true,
                modelID: "gpt-4.1-mini",
                apiKey: "key",
                baseURL: "https://compat.example/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == OpenAICompatibleModelProvider.providerID)
        #expect(response.text == "compat-output")
        #expect(await transport.path()?.contains("/v1/chat/completions") == true)
    }

    @Test
    func anthropicProviderParsesMessagesResponse() async throws {
        let transport = MockAnthropicTransport(
            body: Data("""
            {"id":"msg_1","model":"claude-3-5-haiku-latest","content":[{"type":"text","text":"anthropic-output"}]}
            """.utf8)
        )
        let provider = AnthropicModelProvider(
            configuration: AnthropicModelConfig(
                enabled: true,
                modelID: "claude-3-5-haiku-latest",
                apiKey: "key"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == AnthropicModelProvider.providerID)
        #expect(response.text == "anthropic-output")
    }

    @Test
    func geminiProviderParsesGenerateContentResponse() async throws {
        let transport = MockGeminiTransport(
            body: Data("""
            {"candidates":[{"content":{"parts":[{"text":"gemini-output"}]}}]}
            """.utf8)
        )
        let provider = GeminiModelProvider(
            configuration: GeminiModelConfig(
                enabled: true,
                modelID: "gemini-2.0-flash",
                apiKey: "gem-key",
                baseURL: "https://generativelanguage.googleapis.com/v1beta"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == GeminiModelProvider.providerID)
        #expect(response.text == "gemini-output")
        #expect(await transport.query()?.contains("key=gem-key") == true)
    }

    @Test
    func xaiProviderParsesChatCompletionsResponse() async throws {
        let transport = MockXAITransport(
            body: Data("""
            {"model":"grok-3-mini","choices":[{"index":0,"message":{"role":"assistant","content":"grok-output"}}]}
            """.utf8)
        )
        let provider = XAIModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .apiKey,
                modelID: "grok-3-mini",
                apiKey: "xai-key",
                baseURL: "https://api.x.ai/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == XAIModelProvider.providerID)
        #expect(response.text == "grok-output")
        #expect(await transport.path()?.contains("/v1/chat/completions") == true)
        #expect(await transport.authorization() == "Bearer xai-key")
    }

    @Test
    func openRouterProviderParsesChatCompletionsResponse() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"anthropic/claude-sonnet-4-5","choices":[{"index":0,"message":{"role":"assistant","content":"openrouter-output"}}]}
            """.utf8)
        )
        let provider = OpenRouterModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .apiKey,
                modelID: "anthropic/claude-sonnet-4-5",
                apiKey: "openrouter-key",
                baseURL: "https://openrouter.ai/api/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == OpenRouterModelProvider.providerID)
        #expect(response.text == "openrouter-output")
        #expect(await transport.path()?.contains("/api/v1/chat/completions") == true)
        #expect(await transport.authorization() == "Bearer openrouter-key")
    }

    @Test
    func routerSupportsGroqProviderID() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"llama-3.3-70b-versatile","choices":[{"index":0,"message":{"role":"assistant","content":"groq-output"}}]}
            """.utf8)
        )
        let router = ModelRouter()
        await router.register(
            GroqModelProvider(
                configuration: ProviderServiceConfig(
                    enabled: true,
                    apiStyle: .openAICompletions,
                    authMode: .apiKey,
                    modelID: "llama-3.3-70b-versatile",
                    apiKey: "groq-key",
                    baseURL: "https://api.groq.com/openai/v1",
                    chatCompletionsPath: "chat/completions"
                ),
                transport: transport
            )
        )
        let response = try await router.generate(
            ModelGenerationRequest(
                sessionKey: "s1",
                prompt: "hello",
                providerID: GroqModelProvider.providerID
            )
        )

        #expect(response.providerID == GroqModelProvider.providerID)
        #expect(response.text == "groq-output")
    }

    @Test
    func mistralProviderSupportsBearerTokenAuthMode() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"mistral-large-latest","choices":[{"index":0,"message":{"role":"assistant","content":"mistral-output"}}]}
            """.utf8)
        )
        let provider = MistralModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .bearerToken,
                modelID: "mistral-large-latest",
                accessToken: "mistral-token",
                baseURL: "https://api.mistral.ai/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == MistralModelProvider.providerID)
        #expect(response.text == "mistral-output")
        #expect(await transport.authorization() == "Bearer mistral-token")
    }

    @Test
    func cerebrasProviderParsesChatCompletionsResponse() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"zai-glm-4.7","choices":[{"index":0,"message":{"role":"assistant","content":"cerebras-output"}}]}
            """.utf8)
        )
        let provider = CerebrasModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .apiKey,
                modelID: "zai-glm-4.7",
                apiKey: "cerebras-key",
                baseURL: "https://api.cerebras.ai/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == CerebrasModelProvider.providerID)
        #expect(response.text == "cerebras-output")
        #expect(await transport.path()?.contains("/v1/chat/completions") == true)
    }

    @Test
    func routerSupportsGrokAliasProviderID() async throws {
        let transport = MockXAITransport(
            body: Data("""
            {"model":"grok-3-mini","choices":[{"index":0,"message":{"role":"assistant","content":"grok-alias-output"}}]}
            """.utf8)
        )
        let router = ModelRouter()
        await router.register(
            XAIModelProvider(
                id: XAIModelProvider.grokAliasProviderID,
                configuration: ProviderServiceConfig(
                    enabled: true,
                    apiStyle: .openAICompletions,
                    authMode: .apiKey,
                    modelID: "grok-3-mini",
                    apiKey: "xai-key",
                    baseURL: "https://api.x.ai/v1",
                    chatCompletionsPath: "chat/completions"
                ),
                transport: transport
            )
        )
        let response = try await router.generate(
            ModelGenerationRequest(
                sessionKey: "s1",
                prompt: "hello",
                providerID: "grok"
            )
        )

        #expect(response.providerID == "grok")
        #expect(response.text == "grok-alias-output")
    }
}
