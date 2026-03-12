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
        private(set) var lastRequestBody: Data?

        init(statusCode: Int = 200, body: Data) {
            self.statusCode = statusCode
            self.body = body
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.lastPath = request.url?.path
            self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
            self.lastRequestBody = request.httpBody
            return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: self.body)
        }

        func path() -> String? {
            self.lastPath
        }

        func authorization() -> String? {
            self.lastAuthorization
        }

        func bodyString() -> String? {
            guard let lastRequestBody else {
                return nil
            }
            return String(data: lastRequestBody, encoding: .utf8)
        }
    }

    actor MockAnthropicTransport: AnthropicHTTPTransport {
        let statusCode: Int
        let body: Data
        private(set) var lastPath: String?
        private(set) var lastAPIKey: String?
        private(set) var lastAuthorization: String?
        private(set) var lastRequestBody: Data?

        init(statusCode: Int = 200, body: Data) {
            self.statusCode = statusCode
            self.body = body
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.lastPath = request.url?.path
            self.lastAPIKey = request.value(forHTTPHeaderField: "x-api-key")
            self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
            self.lastRequestBody = request.httpBody
            return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: self.body)
        }

        func path() -> String? {
            self.lastPath
        }

        func apiKey() -> String? {
            self.lastAPIKey
        }

        func authorization() -> String? {
            self.lastAuthorization
        }

        func bodyString() -> String? {
            guard let lastRequestBody else {
                return nil
            }
            return String(data: lastRequestBody, encoding: .utf8)
        }
    }

    actor MockGeminiTransport: GeminiHTTPTransport {
        let statusCode: Int
        let body: Data
        private(set) var lastQuery: String?
        private(set) var lastRequestBody: Data?

        init(statusCode: Int = 200, body: Data) {
            self.statusCode = statusCode
            self.body = body
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.lastQuery = request.url?.query
            self.lastRequestBody = request.httpBody
            return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: self.body)
        }

        func query() -> String? {
            self.lastQuery
        }

        func bodyString() -> String? {
            guard let lastRequestBody else {
                return nil
            }
            return String(data: lastRequestBody, encoding: .utf8)
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

    actor MockBedrockTransport: BedrockHTTPTransport {
        let statusCode: Int
        let body: Data
        private(set) var lastPath: String?
        private(set) var lastRegion: String?
        private(set) var lastAuthorization: String?

        init(statusCode: Int = 200, body: Data) {
            self.statusCode = statusCode
            self.body = body
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.lastPath = request.url?.path
            self.lastRegion = request.value(forHTTPHeaderField: "x-amz-region")
            self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
            return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: self.body)
        }

        func path() -> String? {
            self.lastPath
        }

        func region() -> String? {
            self.lastRegion
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
    func openAICompatibleProviderEmbedsImageAttachmentAsDataURL() async throws {
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

        let attachment = MediaAttachment(
            mimeType: "image/png",
            data: Data([0x01, 0x02, 0x03]),
            fileName: "photo.png"
        )
        let response = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s1",
                prompt: "Describe this photo.",
                attachments: [attachment]
            )
        )

        #expect(response.text == "compat-output")
        let requestBody = await transport.bodyString() ?? ""
        #expect(requestBody.contains("\"image_url\""))
        #expect(requestBody.contains("data:image\\/png;base64,AQID"))
        #expect(requestBody.contains("Describe this photo."))
    }

    @Test
    func openAICompatibleProviderEmbedsFileAttachmentPayload() async throws {
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

        let textAttachment = MediaAttachment(
            mimeType: "text/plain",
            data: Data("line one\nline two".utf8),
            fileName: "notes.txt"
        )
        let binaryAttachment = MediaAttachment(
            mimeType: "application/octet-stream",
            data: Data([0x01, 0x02]),
            fileName: "blob.bin"
        )
        _ = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s1",
                prompt: "Inspect attached files.",
                attachments: [textAttachment, binaryAttachment]
            )
        )

        let requestBody = await transport.bodyString() ?? ""
        #expect(requestBody.contains("notes.txt"))
        #expect(requestBody.contains("line one"))
        #expect(requestBody.contains("blob.bin"))
        #expect(requestBody.contains("AQI="))
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
    func anthropicProviderEmbedsImageAttachmentBlock() async throws {
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
        let attachment = MediaAttachment(
            mimeType: "image/png",
            data: Data([0x01, 0x02, 0x03]),
            fileName: "photo.png"
        )
        _ = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s1",
                prompt: "Describe this image.",
                attachments: [attachment]
            )
        )

        let requestBody = await transport.bodyString() ?? ""
        #expect(requestBody.contains("\"type\":\"image\""))
        #expect(requestBody.contains("\"media_type\":\"image\\/png\""))
        #expect(requestBody.contains("\"data\":\"AQID\""))
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
    func geminiProviderEmbedsImageAttachmentInlineData() async throws {
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
        let attachment = MediaAttachment(
            mimeType: "image/png",
            data: Data([0x01, 0x02, 0x03]),
            fileName: "photo.png"
        )
        _ = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s1",
                prompt: "Describe this image.",
                attachments: [attachment]
            )
        )

        let requestBody = await transport.bodyString() ?? ""
        #expect(requestBody.contains("\"inline_data\""))
        #expect(requestBody.contains("\"mime_type\":\"image\\/png\""))
        #expect(requestBody.contains("\"data\":\"AQID\""))
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
    func moonshotProviderParsesChatCompletionsResponse() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"kimi-k2.5","choices":[{"index":0,"message":{"role":"assistant","content":"moonshot-output"}}]}
            """.utf8)
        )
        let provider = MoonshotModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .apiKey,
                modelID: "kimi-k2.5",
                apiKey: "moonshot-key",
                baseURL: "https://api.moonshot.ai/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == MoonshotModelProvider.providerID)
        #expect(response.text == "moonshot-output")
        #expect(await transport.authorization() == "Bearer moonshot-key")
    }

    @Test
    func routerSupportsLiteLLMProviderID() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"gpt-4.1-mini","choices":[{"index":0,"message":{"role":"assistant","content":"litellm-output"}}]}
            """.utf8)
        )
        let router = ModelRouter()
        await router.register(
            LiteLLMModelProvider(
                configuration: ProviderServiceConfig(
                    enabled: true,
                    apiStyle: .openAICompletions,
                    authMode: .apiKey,
                    modelID: "gpt-4.1-mini",
                    apiKey: "litellm-key",
                    baseURL: "http://127.0.0.1:4000/v1",
                    chatCompletionsPath: "chat/completions"
                ),
                transport: transport
            )
        )
        let response = try await router.generate(
            ModelGenerationRequest(
                sessionKey: "s1",
                prompt: "hello",
                providerID: LiteLLMModelProvider.providerID
            )
        )

        #expect(response.providerID == LiteLLMModelProvider.providerID)
        #expect(response.text == "litellm-output")
    }

    @Test
    func togetherProviderParsesChatCompletionsResponse() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"meta-llama/Llama-3.3-70B-Instruct-Turbo","choices":[{"index":0,"message":{"role":"assistant","content":"together-output"}}]}
            """.utf8)
        )
        let provider = TogetherModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .apiKey,
                modelID: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
                apiKey: "together-key",
                baseURL: "https://api.together.xyz/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == TogetherModelProvider.providerID)
        #expect(response.text == "together-output")
    }

    @Test
    func huggingFaceProviderParsesChatCompletionsResponse() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"deepseek-ai/DeepSeek-R1","choices":[{"index":0,"message":{"role":"assistant","content":"huggingface-output"}}]}
            """.utf8)
        )
        let provider = HuggingFaceModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .apiKey,
                modelID: "deepseek-ai/DeepSeek-R1",
                apiKey: "huggingface-key",
                baseURL: "https://router.huggingface.co/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == HuggingFaceModelProvider.providerID)
        #expect(response.text == "huggingface-output")
    }

    @Test
    func qianfanProviderParsesChatCompletionsResponse() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"deepseek-v3.2","choices":[{"index":0,"message":{"role":"assistant","content":"qianfan-output"}}]}
            """.utf8)
        )
        let provider = QianfanModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .apiKey,
                modelID: "deepseek-v3.2",
                apiKey: "qianfan-key",
                baseURL: "https://qianfan.baidubce.com/v2",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == QianfanModelProvider.providerID)
        #expect(response.text == "qianfan-output")
    }

    @Test
    func nvidiaProviderParsesChatCompletionsResponse() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"nvidia/llama-3.1-nemotron-70b-instruct","choices":[{"index":0,"message":{"role":"assistant","content":"nvidia-output"}}]}
            """.utf8)
        )
        let provider = NVIDIAModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .apiKey,
                modelID: "nvidia/llama-3.1-nemotron-70b-instruct",
                apiKey: "nvidia-key",
                baseURL: "https://integrate.api.nvidia.com/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == NVIDIAModelProvider.providerID)
        #expect(response.text == "nvidia-output")
    }

    @Test
    func zaiProviderParsesChatCompletionsResponse() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"glm-4.7","choices":[{"index":0,"message":{"role":"assistant","content":"zai-output"}}]}
            """.utf8)
        )
        let provider = ZAIModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .apiKey,
                modelID: "glm-4.7",
                apiKey: "zai-key",
                baseURL: "https://api.z.ai/api/paas/v4",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == ZAIModelProvider.providerID)
        #expect(response.text == "zai-output")
    }

    @Test
    func minimaxProviderParsesMessagesResponse() async throws {
        let transport = MockAnthropicTransport(
            body: Data("""
            {"id":"msg_1","model":"MiniMax-M2.1","content":[{"type":"text","text":"minimax-output"}]}
            """.utf8)
        )
        let provider = MinimaxModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                authMode: .apiKey,
                modelID: "MiniMax-M2.1",
                apiKey: "minimax-key",
                baseURL: "https://api.minimax.io/anthropic",
                messagesPath: "messages"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == MinimaxModelProvider.providerID)
        #expect(response.text == "minimax-output")
        #expect(await transport.path()?.contains("/anthropic/messages") == true)
        #expect(await transport.apiKey() == "minimax-key")
    }

    @Test
    func minimaxPortalProviderSupportsOAuthAuthMode() async throws {
        let transport = MockAnthropicTransport(
            body: Data("""
            {"id":"msg_1","model":"MiniMax-M2.1","content":[{"type":"text","text":"minimax-portal-output"}]}
            """.utf8)
        )
        let provider = MinimaxPortalModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                authMode: .oauthToken,
                modelID: "MiniMax-M2.1",
                accessToken: "minimax-oauth",
                baseURL: "https://api.minimax.io/anthropic",
                messagesPath: "messages"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == MinimaxPortalModelProvider.providerID)
        #expect(response.text == "minimax-portal-output")
        #expect(await transport.authorization() == "Bearer minimax-oauth")
    }

    @Test
    func syntheticProviderParsesMessagesResponse() async throws {
        let transport = MockAnthropicTransport(
            body: Data("""
            {"id":"msg_1","model":"hf:MiniMaxAI/MiniMax-M2.1","content":[{"type":"text","text":"synthetic-output"}]}
            """.utf8)
        )
        let provider = SyntheticModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                authMode: .apiKey,
                modelID: "hf:MiniMaxAI/MiniMax-M2.1",
                apiKey: "synthetic-key",
                baseURL: "https://api.synthetic.new/anthropic",
                messagesPath: "messages"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == SyntheticModelProvider.providerID)
        #expect(response.text == "synthetic-output")
    }

    @Test
    func xiaomiProviderParsesMessagesResponse() async throws {
        let transport = MockAnthropicTransport(
            body: Data("""
            {"id":"msg_1","model":"mimo-v2-flash","content":[{"type":"text","text":"xiaomi-output"}]}
            """.utf8)
        )
        let provider = XiaomiModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                authMode: .apiKey,
                modelID: "mimo-v2-flash",
                apiKey: "xiaomi-key",
                baseURL: "https://api.xiaomimimo.com/anthropic",
                messagesPath: "messages"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == XiaomiModelProvider.providerID)
        #expect(response.text == "xiaomi-output")
    }

    @Test
    func cloudflareAIGatewayProviderParsesMessagesResponse() async throws {
        let transport = MockAnthropicTransport(
            body: Data("""
            {"id":"msg_1","model":"claude-3-5-sonnet-latest","content":[{"type":"text","text":"cloudflare-output"}]}
            """.utf8)
        )
        let provider = CloudflareAIGatewayModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                authMode: .apiKey,
                modelID: "claude-3-5-sonnet-latest",
                apiKey: "cloudflare-key",
                baseURL: "https://gateway.ai.cloudflare.com/v1",
                messagesPath: "messages"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == CloudflareAIGatewayModelProvider.providerID)
        #expect(response.text == "cloudflare-output")
    }

    @Test
    func vercelAIGatewayProviderParsesMessagesResponse() async throws {
        let transport = MockAnthropicTransport(
            body: Data("""
            {"id":"msg_1","model":"anthropic/claude-opus-4.6","content":[{"type":"text","text":"vercel-output"}]}
            """.utf8)
        )
        let provider = VercelAIGatewayModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                authMode: .apiKey,
                modelID: "anthropic/claude-opus-4.6",
                apiKey: "vercel-key",
                baseURL: "https://ai-gateway.vercel.sh/v1",
                messagesPath: "messages"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == VercelAIGatewayModelProvider.providerID)
        #expect(response.text == "vercel-output")
    }

    @Test
    func bedrockProviderParsesConverseResponse() async throws {
        let transport = MockBedrockTransport(
            body: Data("""
            {"output":{"message":{"role":"assistant","content":[{"text":"bedrock-output"}]}}}
            """.utf8)
        )
        let provider = BedrockConverseModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .bedrockConverse,
                authMode: .awsSDK,
                modelID: "anthropic.claude-3-5-sonnet",
                baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                region: "us-east-1",
                profile: "default"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == BedrockConverseModelProvider.providerID)
        #expect(response.text == "bedrock-output")
        #expect(await transport.path()?.contains("/model/anthropic.claude-3-5-sonnet/converse") == true)
        #expect(await transport.region() == "us-east-1")
    }

    @Test
    func bedrockProviderAllowsNoneAuthModeWithoutAuthorizationHeader() async throws {
        let transport = MockBedrockTransport(
            body: Data("""
            {"output":{"message":{"role":"assistant","content":[{"text":"bedrock-local-output"}]}}}
            """.utf8)
        )
        let provider = BedrockConverseModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .bedrockConverse,
                authMode: .none,
                modelID: "anthropic.claude-3-5-sonnet",
                baseURL: "http://127.0.0.1:9000"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == BedrockConverseModelProvider.providerID)
        #expect(response.text == "bedrock-local-output")
        #expect(await transport.authorization() == nil)
    }

    @Test
    func githubCopilotProviderParsesChatCompletionsResponse() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"gpt-5","choices":[{"index":0,"message":{"role":"assistant","content":"copilot-output"}}]}
            """.utf8)
        )
        let provider = GitHubCopilotModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .bearerToken,
                modelID: "gpt-5",
                accessToken: "copilot-token",
                baseURL: "https://api.githubcopilot.com",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == GitHubCopilotModelProvider.providerID)
        #expect(response.text == "copilot-output")
        #expect(await transport.authorization() == "Bearer copilot-token")
    }

    @Test
    func ollamaProviderAllowsNoAuthorizationHeader() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"llama3.3","choices":[{"index":0,"message":{"role":"assistant","content":"ollama-output"}}]}
            """.utf8)
        )
        let provider = OllamaModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .ollama,
                authMode: .none,
                modelID: "llama3.3",
                baseURL: "http://127.0.0.1:11434/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == OllamaModelProvider.providerID)
        #expect(response.text == "ollama-output")
        #expect(await transport.authorization() == nil)
    }

    @Test
    func routerSupportsVLLMProviderID() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"qwen2.5-coder-32b-instruct","choices":[{"index":0,"message":{"role":"assistant","content":"vllm-output"}}]}
            """.utf8)
        )
        let router = ModelRouter()
        await router.register(
            VLLMModelProvider(
                configuration: ProviderServiceConfig(
                    enabled: true,
                    apiStyle: .openAICompletions,
                    authMode: .none,
                    modelID: "qwen2.5-coder-32b-instruct",
                    baseURL: "http://127.0.0.1:8000/v1",
                    chatCompletionsPath: "chat/completions"
                ),
                transport: transport
            )
        )
        let response = try await router.generate(
            ModelGenerationRequest(
                sessionKey: "s1",
                prompt: "hello",
                providerID: VLLMModelProvider.providerID
            )
        )

        #expect(response.providerID == VLLMModelProvider.providerID)
        #expect(response.text == "vllm-output")
    }

    @Test
    func qwenPortalProviderSupportsOAuthAuthMode() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"coder-model","choices":[{"index":0,"message":{"role":"assistant","content":"qwen-output"}}]}
            """.utf8)
        )
        let provider = QwenPortalModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .oauthToken,
                modelID: "coder-model",
                accessToken: "qwen-oauth",
                baseURL: "https://portal.qwen.ai/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
        )

        #expect(response.providerID == QwenPortalModelProvider.providerID)
        #expect(response.text == "qwen-output")
        #expect(await transport.authorization() == "Bearer qwen-oauth")
    }

    @Test
    func providerServiceOpenAIRejectsAWSSDKAuthMode() async throws {
        let transport = MockOpenAICompatibleTransport(
            body: Data("""
            {"model":"gpt-4.1-mini","choices":[{"index":0,"message":{"role":"assistant","content":"unused"}}]}
            """.utf8)
        )
        let provider = ProviderServiceOpenAIModelProvider(
            id: "openrouter",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .awsSDK,
                modelID: "gpt-4.1-mini",
                baseURL: "https://openrouter.ai/api/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )

        do {
            _ = try await provider.generate(
                ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
            )
            Issue.record("Expected aws-sdk auth mode rejection for OpenAI-compatible provider")
        } catch {
            #expect(String(describing: error).contains("aws-sdk"))
        }
    }

    @Test
    func providerServiceAnthropicRejectsOpenAICompletionsAPIStyle() async throws {
        let transport = MockAnthropicTransport(
            body: Data("""
            {"id":"msg_1","model":"claude-3-5-haiku-latest","content":[{"type":"text","text":"unused"}]}
            """.utf8)
        )
        let provider = ProviderServiceAnthropicModelProvider(
            id: "minimax",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .apiKey,
                modelID: "MiniMax-M2.1",
                apiKey: "minimax-key",
                baseURL: "https://api.minimax.io/anthropic",
                messagesPath: "messages"
            ),
            transport: transport
        )

        do {
            _ = try await provider.generate(
                ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
            )
            Issue.record("Expected apiStyle validation error for Anthropic-compatible provider")
        } catch {
            #expect(String(describing: error).contains("Anthropic-messages compatible"))
        }
    }

    @Test
    func providerServiceAnthropicRejectsAWSSDKAuthMode() async throws {
        let transport = MockAnthropicTransport(
            body: Data("""
            {"id":"msg_1","model":"claude-3-5-haiku-latest","content":[{"type":"text","text":"unused"}]}
            """.utf8)
        )
        let provider = ProviderServiceAnthropicModelProvider(
            id: "minimax",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                authMode: .awsSDK,
                modelID: "MiniMax-M2.1",
                baseURL: "https://api.minimax.io/anthropic",
                messagesPath: "messages"
            ),
            transport: transport
        )

        do {
            _ = try await provider.generate(
                ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
            )
            Issue.record("Expected aws-sdk auth mode rejection for Anthropic-compatible provider")
        } catch {
            #expect(String(describing: error).contains("aws-sdk"))
        }
    }

    @Test
    func xaiProviderRejectsNoneAuthMode() async throws {
        let transport = MockXAITransport(
            body: Data("""
            {"model":"grok-3-mini","choices":[{"index":0,"message":{"role":"assistant","content":"unused"}}]}
            """.utf8)
        )
        let provider = XAIModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .none,
                modelID: "grok-3-mini",
                baseURL: "https://api.x.ai/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: transport
        )

        do {
            _ = try await provider.generate(
                ModelGenerationRequest(sessionKey: "s1", prompt: "hello")
            )
            Issue.record("Expected auth mode validation error for xAI provider")
        } catch {
            #expect(String(describing: error).contains("token-based authentication"))
        }
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
