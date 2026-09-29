import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore
@testable import OpenClawModels
import OpenClawProtocol

/// Upstream-shaped configs omit `auth` and `apiKey` and keep keys in auth profiles; the router then
/// injects the key as request metadata (`auth.apiKey` / `auth.accessToken`). Every engine must honor
/// it for the inferred `.none` auth mode instead of sending unauthenticated requests.
@Suite("Provider request credentials without configured auth")
struct ProviderRequestCredentialTests {
    private static func decodeConfig(_ json: String) throws -> ModelProviderConfig {
        try JSONDecoder().decode(ModelProviderConfig.self, from: Data(json.utf8))
    }

    private static func request(metadata: [String: String]) -> ModelGenerationRequest {
        ModelGenerationRequest(sessionKey: "s", prompt: "hi", metadata: metadata)
    }

    @Test
    func anthropicCompatibleRouteSendsProfileKeyAsXAPIKey() async throws {
        let config = try Self.decodeConfig(#"""
        {"enabled":true,"baseUrl":"https://api.minimax.io/anthropic","api":"anthropic-messages","models":[{"id":"MiniMax-M2.1"}]}
        """#)
        let legacy = config.legacyServiceConfig(providerID: "minimax")
        #expect(legacy.authMode == .none)
        let transport = ContractV2StubTransport(body: #"{"model":"MiniMax-M2.1","stop_reason":"end_turn","content":[{"type":"text","text":"ok"}]}"#)
        let provider = MinimaxModelProvider(
            configuration: legacy,
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .anthropicMessages)
        )
        let response = try await provider.generate(Self.request(metadata: ["auth.apiKey": "profile-key"]))
        #expect(response.text == "ok")
        let sent = try #require(await transport.lastRequest())
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "profile-key")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func anthropicCompatibleRouteSendsProfileTokenAsBearer() async throws {
        let config = try Self.decodeConfig(#"""
        {"enabled":true,"baseUrl":"https://api.synthetic.new/anthropic","api":"anthropic-messages","models":[{"id":"hf:zai-org/GLM-4.7"}]}
        """#)
        let transport = ContractV2StubTransport(body: #"{"stop_reason":"end_turn","content":[{"type":"text","text":"ok"}]}"#)
        let provider = ProviderServiceAnthropicModelProvider(
            id: "synthetic",
            configuration: config.legacyServiceConfig(providerID: "synthetic"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .anthropicMessages)
        )
        _ = try await provider.generate(Self.request(metadata: ["auth.accessToken": "profile-token"]))
        let sent = try #require(await transport.lastRequest())
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer profile-token")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test
    func googleRouteSendsProfileKeyInHeader() async throws {
        let config = try Self.decodeConfig(#"""
        {"enabled":true,"baseUrl":"https://generativelanguage.googleapis.com/v1beta","api":"google-generative-ai","models":[{"id":"gemini-3-flash"}]}
        """#)
        let transport = ContractV2StubTransport(body: #"{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#)
        let provider = GoogleGenerativeAIModelProvider(
            id: "google",
            configuration: config.legacyServiceConfig(providerID: "google"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .googleGenerativeAI)
        )
        _ = try await provider.generate(Self.request(metadata: ["auth.apiKey": "profile-key"]))
        let sent = try #require(await transport.lastRequest())
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "profile-key")
        #expect(sent.url?.query?.contains("key=") != true)
    }

    @Test
    func xaiAcceptsConfigWithoutAuthAndSendsProfileKey() async throws {
        let config = try Self.decodeConfig(#"""
        {"enabled":true,"baseUrl":"https://api.x.ai/v1","api":"openai-completions","models":[{"id":"grok-4"}]}
        """#)
        let transport = ContractV2StubTransport(body: #"{"choices":[{"finish_reason":"stop","message":{"content":"ok"}}]}"#)
        let provider = XAIModelProvider(
            id: "xai",
            configuration: config.legacyServiceConfig(providerID: "xai"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .openAICompletions)
        )
        let response = try await provider.generate(Self.request(metadata: ["auth.apiKey": "profile-key"]))
        #expect(response.text == "ok")
        #expect(await transport.lastRequest()?.value(forHTTPHeaderField: "Authorization") == "Bearer profile-key")
    }

    @Test
    func ollamaRouteSendsProfileKeyAsBearer() async throws {
        let config = try Self.decodeConfig(#"""
        {"enabled":true,"baseUrl":"https://ollama.com","api":"ollama","models":[{"id":"gpt-oss:120b"}]}
        """#)
        let transport = ContractV2StubTransport(body: #"{"model":"gpt-oss:120b","message":{"role":"assistant","content":"ok"},"done":true}"#)
        let provider = OllamaModelProvider(
            configuration: config.legacyServiceConfig(providerID: "ollama"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .ollama)
        )
        _ = try await provider.generate(Self.request(metadata: ["auth.apiKey": "profile-key"]))
        #expect(await transport.lastRequest()?.value(forHTTPHeaderField: "Authorization") == "Bearer profile-key")
    }

    /// Non-streamed `generate` on the `openai` Chat Completions route must not demand an API key the
    /// engine never needs (a `request.auth` header override or `authHeader: false`), exactly like
    /// `generateStream`.
    @Test
    func openAICompletionsGenerateHonorsAuthOverridesWithoutAPIKey() async throws {
        let body = #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"ok"}}]}"#
        let overrideConfig = ModelProviderConfig(
            enabled: true,
            baseURL: "https://proxy.example/v1",
            auth: nil,
            api: .openAICompletions,
            models: [ModelDefinitionConfig(id: "gpt-4.1")],
            request: ModelProviderRequestConfig(auth: .header(name: "X-Proxy-Key", value: .string("proxy-secret"), prefix: nil))
        )
        let overrideTransport = ContractV2StubTransport(body: body)
        let overrideProvider = OpenAIModelProvider(
            configuration: OpenAIModelConfig(enabled: true, modelID: "gpt-4.1", baseURL: "https://proxy.example/v1"),
            transport: overrideTransport,
            runtime: ModelProviderRuntimeContext(providerConfig: overrideConfig, api: .openAICompletions)
        )
        let response = try await overrideProvider.generate(Self.request(metadata: [:]))
        #expect(response.text == "ok")
        let sent = try #require(await overrideTransport.lastRequest())
        #expect(sent.value(forHTTPHeaderField: "X-Proxy-Key") == "proxy-secret")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)

        let keylessConfig = ModelProviderConfig(
            enabled: true,
            baseURL: "http://127.0.0.1:8080/v1",
            auth: nil,
            api: .openAICompletions,
            authHeader: false,
            models: [ModelDefinitionConfig(id: "gpt-4.1")]
        )
        let keylessTransport = ContractV2StubTransport(body: body)
        let keylessProvider = OpenAIModelProvider(
            configuration: OpenAIModelConfig(enabled: true, modelID: "gpt-4.1", baseURL: "http://127.0.0.1:8080/v1"),
            transport: keylessTransport,
            runtime: ModelProviderRuntimeContext(providerConfig: keylessConfig, api: .openAICompletions)
        )
        _ = try await keylessProvider.generate(Self.request(metadata: [:]))
        #expect(await keylessTransport.lastRequest()?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func keylessLocalConfigStillSendsNoCredential() async throws {
        let config = try Self.decodeConfig(#"""
        {"enabled":true,"baseUrl":"http://127.0.0.1:11434","api":"ollama","models":[{"id":"llama3"}]}
        """#)
        let transport = ContractV2StubTransport(body: #"{"message":{"role":"assistant","content":"ok"},"done":true}"#)
        let provider = OllamaModelProvider(
            configuration: config.legacyServiceConfig(providerID: "ollama"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .ollama)
        )
        _ = try await provider.generate(Self.request(metadata: [:]))
        #expect(await transport.lastRequest()?.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
