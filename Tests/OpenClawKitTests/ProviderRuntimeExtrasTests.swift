import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore
@testable import OpenClawModels
import OpenClawProtocol

@Suite("Provider runtime extras")
struct ProviderRuntimeExtrasTests {
    actor RefreshTransport: RuntimeAuthHTTPTransport {
        private(set) var bodies: [String] = []
        private(set) var urls: [URL] = []
        let response: String

        init(response: String) {
            self.response = response
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            if let url = request.url {
                self.urls.append(url)
            }
            return HTTPResponseData(statusCode: 200, headers: [:], body: Data(self.response.utf8))
        }
    }

    private static func jwt(accountID: String) -> String {
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"\#(accountID)"}}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "h.\(encoded).s"
    }

    @Test
    func chatGPTOAuthRefreshesExpiringTokensAndExposesAccountID() async throws {
        let next = Self.jwt(accountID: "acct_new")
        let transport = RefreshTransport(response: #"{"access_token":"\#(next)","refresh_token":"r2","expires_in":3600}"#)
        let resolver = RuntimeProviderAuthResolver(transport: transport, now: { 1_000_000 })
        let expiring = AuthProfileCredential.oauth(
            OAuthAuthProfileCredential(provider: "openai", accessToken: "old", refreshToken: "r1", expires: 1_000_500)
        )
        let resolution = try await resolver.resolve(providerID: "openai-codex", credential: expiring)
        #expect(resolution.persistCredential)
        #expect(resolution.metadata["openai.chatgptAccountID"] == "acct_new")
        guard case .oauth(let updated) = resolution.credential else {
            Issue.record("Expected an OAuth credential")
            return
        }
        #expect(updated.accessToken == next)
        #expect(updated.refreshToken == "r2")
        #expect(updated.expires == 1_000_000 + 3_600_000)
        #expect(await transport.urls.first == OpenAIChatGPTOAuthConfiguration.tokenURL)
        let body = try #require(await transport.bodies.first)
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))

        let fresh = AuthProfileCredential.oauth(
            OAuthAuthProfileCredential(provider: "openai", accessToken: Self.jwt(accountID: "acct_1"), refreshToken: "r", expires: 9_000_000)
        )
        let unchanged = try await resolver.resolve(providerID: "openai", credential: fresh)
        #expect(!unchanged.persistCredential)
        #expect(unchanged.metadata["openai.chatgptAccountID"] == "acct_1")
        let apiKey = AuthProfileCredential.apiKey(APIKeyAuthProfileCredential(provider: "openai", key: "sk"))
        #expect(try await resolver.resolve(providerID: "openai", credential: apiKey).credential == apiKey)
    }

    @Test
    func chatCompletionsPromptCacheMarkersAndKeys() async throws {
        let transport = ContractV2StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#)
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: "k",
            models: [ModelDefinitionConfig(id: "anthropic/claude-sonnet-4-6", compat: ModelCompatConfig(cacheControlFormat: .anthropic))]
        )
        let provider = ProviderServiceOpenAIModelProvider(
            id: "openrouter",
            configuration: config.legacyServiceConfig(providerID: "openrouter"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .openAICompletions)
        )
        _ = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "sess",
                prompt: "question",
                systemPrompt: "stable",
                policy: ModelGenerationPolicy(promptCache: ModelPromptCachePolicy(enabled: true, longRetention: true)),
                tools: [ModelToolDefinition(name: "a"), ModelToolDefinition(name: "b")]
            )
        )
        let body = try #require(await transport.lastBodyObject())
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages[0][wireKey: "content"]?.arrayValue?.first?[wireKey: "cache_control"]?.wireString("ttl") == "1h")
        #expect(messages[1][wireKey: "content"]?.arrayValue?.first?[wireKey: "cache_control"] != nil)
        #expect(body["tools"]?.arrayValue?.last?[wireKey: "cache_control"] != nil)
        #expect(body["prompt_cache_key"] == nil)

        let openAITransport = ContractV2StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#)
        let openAI = OpenAIModelProvider(
            configuration: OpenAIModelConfig(enabled: true, modelID: "gpt-4.1", apiKey: "k"),
            transport: openAITransport
        )
        _ = try await openAI.generate(
            ModelGenerationRequest(
                sessionKey: "sess",
                prompt: "q",
                policy: ModelGenerationPolicy(maxTokens: 64, promptCache: ModelPromptCachePolicy(enabled: true, longRetention: true))
            )
        )
        let openAIBody = try #require(await openAITransport.lastBodyObject())
        #expect(openAIBody["prompt_cache_key"]?.stringValue == "sess")
        #expect(openAIBody["prompt_cache_retention"]?.stringValue == "24h")
        #expect(openAIBody["max_completion_tokens"]?.intValue == 64)
    }

    @Test
    func localProviderRejectsToolsAndFlattensTranscripts() async throws {
        let provider = LocalModelProvider(
            configuration: LocalModelConfig(enabled: true, modelPath: "/tmp/model.gguf"),
            engine: StubLocalModelEngine(cannedResponse: "local")
        )
        #expect(provider.capabilities.supportsStreaming)
        #expect(!provider.capabilities.supportsTools)
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "x", tools: [ModelToolDefinition(name: "t")]))
        }
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s", prompt: "", messages: [.user("hi"), .assistant("hello"), .user("bye")])
        )
        #expect(response.text == "local")
        let prompt = LocalModelProvider.prompt(
            for: ModelGenerationRequest(sessionKey: "s", prompt: "", messages: [.user("hi"), .assistant("hello")])
        )
        #expect(prompt == "User:\nhi\n\nAssistant:\nhello")
    }

    @Test
    func legacyBridgeInfersAPIKeyAuthWhenConfigOmitsAuth() throws {
        let decoded = try JSONDecoder().decode(ModelProviderConfig.self, from: Data(#"{"baseUrl":"https://x.example","apiKey":"sk"}"#.utf8))
        #expect(decoded.auth == nil)
        #expect(decoded.legacyServiceConfig(providerID: "x").authMode == .apiKey)
        let noHeader = try JSONDecoder().decode(
            ModelProviderConfig.self,
            from: Data(#"{"baseUrl":"https://x.example","apiKey":"sk","authHeader":false}"#.utf8)
        )
        #expect(noHeader.legacyServiceConfig(providerID: "x").authMode == .none)
    }
}
