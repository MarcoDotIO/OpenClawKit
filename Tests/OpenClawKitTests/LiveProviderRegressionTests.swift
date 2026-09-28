import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import OpenClawCore
@testable import OpenClawModels
import OpenClawProtocol

// Offline regression tests (stubbed HTTP) for provider bugs found by the live suites
// (`LiveProvider*Tests`). None of these touch the network.

/// Recording transport answering every request with one fixed response.
private actor RegressionStubTransport: OpenAICompatibleHTTPTransport, AnthropicHTTPTransport {
    private let statusCode: Int
    private let body: Data
    private(set) var requests: [URLRequest] = []

    init(statusCode: Int = 200, body: String) {
        self.statusCode = statusCode
        self.body = Data(body.utf8)
    }

    func data(for request: URLRequest) async throws -> HTTPResponseData {
        self.requests.append(request)
        return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: self.body)
    }
}

/// URL protocol answering requests for registered hosts (and recording them); other hosts pass through.
private final class RegressionURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Stub {
        var statusCode: Int
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
    nonisolated(unsafe) private static var recorded: [String: [URLRequest]] = [:]

    static func stub(host: String, statusCode: Int = 200, body: String) {
        self.lock.lock()
        self.stubs[host] = Stub(statusCode: statusCode, body: Data(body.utf8))
        self.recorded[host] = []
        self.lock.unlock()
    }

    static func remove(host: String) {
        self.lock.lock()
        self.stubs.removeValue(forKey: host)
        self.recorded.removeValue(forKey: host)
        self.lock.unlock()
    }

    static func requests(host: String) -> [URLRequest] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recorded[host] ?? []
    }

    private static func take(_ request: URLRequest) -> Stub? {
        guard let host = request.url?.host else { return nil }
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let stub = self.stubs[host] else { return nil }
        self.recorded[host, default: []].append(request)
        return stub
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stubs[host] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = self.request.url, let stub = Self.take(self.request),
              let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: stub.body)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Ephemeral session routed through this protocol.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegressionURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Real OpenAI Responses body: text lives in `output[].content[]`; there is no top-level `output_text`.
private let responsesBody = """
{"id":"resp_1","object":"response","status":"completed","model":"gpt-6-luna","output":[{"type":"message","id":"msg_1",\
"status":"completed","role":"assistant","content":[{"type":"output_text","text":"pong","annotations":[]}]}],\
"usage":{"input_tokens":12,"input_tokens_details":{"cached_tokens":0},"output_tokens":2,\
"output_tokens_details":{"reasoning_tokens":0},"total_tokens":14}}
"""

private let chatCompletionBody = """
{"id":"chatcmpl-1","object":"chat.completion","model":"gpt-6-luna","choices":[{"index":0,"finish_reason":"stop",\
"message":{"role":"assistant","content":"pong"}}],"usage":{"prompt_tokens":12,"completion_tokens":2,"total_tokens":14}}
"""

private let anthropicBody = """
{"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-4-5","content":[{"type":"text","text":"pong"}],\
"stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":2}}
"""

private let invalidKeyBody = """
{"error":{"message":"Incorrect API key provided: sk-bad***key.","type":"invalid_request_error","code":"invalid_api_key"}}
"""

@Suite("Live provider regressions (offline)", .serialized)
struct LiveProviderRegressionTests {
    // MARK: - OpenAIKit 3.0.0 bypass

    /// Live finding: simple prompts through the public `OpenAIResponsesModelProvider` init used
    /// OpenAIKit, which requests `https://api.openai.com/responses` (404) and cannot read `output`.
    @Test
    func responsesPublicInitSendsSimplePromptsThroughTransport() async throws {
        let transport = RegressionStubTransport(body: responsesBody)
        let provider = OpenAIResponsesModelProvider(
            id: "openai",
            configuration: ProviderServiceConfig(enabled: true, modelID: "gpt-6-luna", apiKey: "sk-test", baseURL: "https://api.openai.com/v1"),
            transport: transport
        )

        let response = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "Reply with pong"))

        #expect(response.text == "pong")
        #expect(response.stopReason == .stop)
        #expect(response.usage?.inputTokens == 12)
        #expect(response.usage?.outputTokens == 2)
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    /// Live finding: the invalid-key error of a simple prompt was a 404 instead of the API's 401.
    @Test
    func responsesPublicInitMapsInvalidKeyForSimplePrompts() async throws {
        let transport = RegressionStubTransport(statusCode: 401, body: invalidKeyBody)
        let provider = OpenAIResponsesModelProvider(
            id: "openai",
            configuration: ProviderServiceConfig(enabled: true, modelID: "gpt-6-luna", apiKey: "sk-bad", baseURL: "https://api.openai.com/v1"),
            transport: transport
        )

        await #expect {
            _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi"))
        } throws: { error in
            guard case OpenClawCoreError.unavailable(let detail) = error else { return false }
            return detail.contains("status 401") && detail.contains("Incorrect API key")
        }
        #expect(await transport.requests.count == 1)
    }

    /// Live finding: simple prompts through `OpenAIModelProvider(configuration:httpClient:)` used
    /// OpenAIKit, which requests `https://api.openai.com/chat/completions` (404).
    @Test
    func chatCompletionsDefaultInitSendsSimplePromptsThroughHTTPClient() async throws {
        let host = "chat-default-init.regression.test"
        RegressionURLProtocol.stub(host: host, body: chatCompletionBody)
        defer { RegressionURLProtocol.remove(host: host) }
        let provider = OpenAIModelProvider(
            configuration: OpenAIModelConfig(enabled: true, modelID: "gpt-6-luna", apiKey: "sk-test", baseURL: "https://\(host)/v1"),
            httpClient: HTTPClient(session: RegressionURLProtocol.makeSession())
        )

        let response = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "Reply with pong"))

        #expect(response.text == "pong")
        #expect(response.usage?.totalTokens == 14)
        let requests = RegressionURLProtocol.requests(host: host)
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == "/v1/chat/completions")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    // MARK: - Provider headers on factory-built providers

    /// Live finding: unscoped Anthropic keys need `anthropic-workspace-id`, but the factory-built
    /// `AnthropicModelProvider` dropped `models.providers.anthropic.headers`.
    @Test
    func anthropicFactoryProviderKeepsConfiguredHeaders() async throws {
        let host = "anthropic-headers.regression.test"
        RegressionURLProtocol.stub(host: host, body: anthropicBody)
        URLProtocol.registerClass(RegressionURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(RegressionURLProtocol.self)
            RegressionURLProtocol.remove(host: host)
        }
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "https://\(host)",
            apiKey: "sk-ant-test",
            auth: .apiKey,
            api: .anthropicMessages,
            headers: ["anthropic-workspace-id": "wrkspc_regression"],
            models: [ModelDefinitionConfig(id: "claude-haiku-4-5", reasoning: true, maxTokens: 64)]
        )
        let provider = try ModelProviderFactory.makeProvider(providerID: "anthropic", config: config)
        #expect(provider is AnthropicModelProvider)

        let response = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "Reply with pong"))

        #expect(response.text == "pong")
        let request = try #require(RegressionURLProtocol.requests(host: host).first)
        #expect(request.url?.path == "/v1/messages")
        #expect(request.value(forHTTPHeaderField: "anthropic-workspace-id") == "wrkspc_regression")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
    }

    @Test
    func anthropicProviderKeepsRuntimeConfigHeaders() async throws {
        let transport = RegressionStubTransport(body: anthropicBody)
        let providerConfig = ModelProviderConfig(
            enabled: true,
            baseURL: "https://api.anthropic.com",
            apiKey: "sk-ant-test",
            api: .anthropicMessages,
            headers: ["anthropic-workspace-id": "wrkspc_regression", "anthropic-beta": "custom-beta-2026-01-01"]
        )
        let provider = AnthropicModelProvider(
            configuration: AnthropicModelConfig(enabled: true, modelID: "claude-haiku-4-5", apiKey: "sk-ant-test", maxTokens: 64),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: providerConfig, api: .anthropicMessages)
        )

        _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi"))

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "anthropic-workspace-id") == "wrkspc_regression")
        // Configured betas merge with the direct-API defaults instead of replacing them.
        let betas = request.value(forHTTPHeaderField: "anthropic-beta") ?? ""
        #expect(betas.contains("custom-beta-2026-01-01"))
        #expect(betas.contains("fine-grained-tool-streaming-2025-05-14"))
    }

    @Test
    func openAIChatProviderKeepsRuntimeConfigHeadersAndMetadata() async throws {
        let transport = RegressionStubTransport(body: chatCompletionBody)
        let providerConfig = ModelProviderConfig(
            enabled: true,
            apiKey: "sk-test",
            headers: ["X-Gateway-Route": "blue"],
            organizationID: "org-configured",
            metadata: ["openai.projectID": "proj_configured"]
        )
        let provider = OpenAIModelProvider(
            configuration: OpenAIModelConfig(enabled: true, modelID: "gpt-6-luna", apiKey: "sk-test"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: providerConfig, api: .openAICompletions)
        )

        _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi"))

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Gateway-Route") == "blue")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Project") == "proj_configured")
        #expect(request.value(forHTTPHeaderField: "x-organization-id") == "org-configured")

        // Request metadata still wins over provider metadata.
        _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi", metadata: ["openai.projectID": "proj_request"]))
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "OpenAI-Project") == "proj_request")
    }

    @Test
    func openAICompatibleProviderKeepsRuntimeConfigHeaders() async throws {
        let transport = RegressionStubTransport(body: chatCompletionBody)
        let provider = OpenAICompatibleModelProvider(
            configuration: OpenAICompatibleModelConfig(enabled: true, modelID: "local-model", apiKey: "k", baseURL: "http://127.0.0.1:4000/v1"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: ModelProviderConfig(enabled: true, headers: ["X-Tenant": "acme"]))
        )

        _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi"))

        #expect(await transport.requests.first?.value(forHTTPHeaderField: "X-Tenant") == "acme")
    }
}
