import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore
@testable import OpenClawModels
import OpenClawProtocol

/// Intercepts requests to one dedicated host on `URLSession.shared` (the default transport of
/// factory-built providers) and answers with a canned provider response per path.
private final class ClawRouterWireStubProtocol: URLProtocol, @unchecked Sendable {
    static let host = "clawrouter-wire.fx4a.test"

    struct Captured: Sendable {
        var url: URL?
        var headers: [String: String]
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [Captured] = []
    nonisolated(unsafe) private static var registered = false

    static func install() {
        self.lock.withLock {
            self.captured = []
            if !self.registered {
                URLProtocol.registerClass(ClawRouterWireStubProtocol.self)
                self.registered = true
            }
        }
    }

    static var requests: [Captured] {
        self.lock.withLock { self.captured }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == self.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = self.request.httpBody ?? Self.readStream(self.request.httpBodyStream)
        Self.lock.withLock {
            Self.captured.append(Captured(url: self.request.url, headers: self.request.allHTTPHeaderFields ?? [:], body: body))
        }
        let path = self.request.url?.path ?? ""
        let payload = path.contains("/messages")
            ? #"{"stop_reason":"end_turn","content":[{"type":"text","text":"claude ok"}]}"#
            : #"{"candidates":[{"content":{"parts":[{"text":"gemini ok"}]},"finishReason":"STOP"}]}"#
        let response = HTTPURLResponse(
            url: self.request.url ?? URL(string: "https://\(Self.host)")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(payload.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// ClawRouter native routes (Anthropic Messages, Google generateContent) must send the upstream model
/// id, not the ClawRouter catalog id (upstream `prepareClawRouterRequestModel`).
@Suite("ClawRouter wire model ids", .serialized)
struct ClawRouterWireModelTests {
    private static let catalogJSON = """
    {
      "providers": [
        {
          "id": "openai", "displayName": "OpenAI", "openaiCompatible": true, "nativeBaseUrl": "/v1/native/openai",
          "routes": [],
          "models": [{"id": "openai/gpt-6-astra", "upstream": "gpt-6-astra", "capabilities": ["llm.responses"]}]
        },
        {
          "id": "anthropic", "displayName": "Anthropic", "openaiCompatible": false, "nativeBaseUrl": "/v1/native/anthropic",
          "routes": [{"path": "/v1/messages", "requestFormat": "anthropic.messages", "methods": ["post"]}],
          "models": [{"id": "anthropic/claude-opus-5", "upstream": "claude-opus-5", "capabilities": ["llm.messages"],
                      "pricing": {"defaultMaxOutputTokens": 64000}}]
        },
        {
          "id": "google", "displayName": "Google", "openaiCompatible": false, "nativeBaseUrl": "/v1/native/google-gemini",
          "routes": [{"path": "/v1beta/models/${model}:streamGenerateContent", "requestFormat": "google.generate_content", "methods": ["POST"]}],
          "models": [{"id": "google/gemini-3-flash-preview", "upstream": "gemini-3-flash-preview", "capabilities": ["llm.stream"]}]
        }
      ]
    }
    """

    @Test
    func providerConfigRowsCarryRouteMetadata() throws {
        let catalog = try ClawRouterCatalogDiscovery.parseCatalog(Data(Self.catalogJSON.utf8), rootURL: "https://\(ClawRouterWireStubProtocol.host)")
        let config = catalog.providerConfig(apiKey: "key")
        let claude = try #require(config.model(withID: "anthropic/claude-opus-5"))
        #expect(ClawRouterRoute.upstreamModelID(for: claude) == "claude-opus-5")
        let route = try #require(claude.params?[ClawRouterRoute.paramsKey]?.dictionaryValue)
        #expect(route["api"]?.stringValue == "anthropic-messages")
        #expect(route["baseUrl"]?.stringValue == "https://\(ClawRouterWireStubProtocol.host)/v1/native/anthropic")
        let prepared = try #require(ClawRouterRoute.requestModel(for: claude))
        #expect(prepared.id == "claude-opus-5")
        #expect(prepared.params == nil)
        #expect(prepared.maxTokens == 64_000)
        // OpenAI-compatible rows are requested by their catalog id.
        #expect(ClawRouterRoute.upstreamModelID(for: config.model(withID: "openai/gpt-6-astra")) == nil)
    }

    @Test
    func nativeRoutesSendUpstreamModelIDs() async throws {
        ClawRouterWireStubProtocol.install()
        let catalog = try ClawRouterCatalogDiscovery.parseCatalog(Data(Self.catalogJSON.utf8), rootURL: "https://\(ClawRouterWireStubProtocol.host)")
        let provider = try ModelProviderFactory.makeProvider(providerID: "clawrouter", config: catalog.providerConfig(apiKey: "key"))
        #expect(provider is RoutingModelProvider)

        let claude = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi", modelID: "anthropic/claude-opus-5"))
        #expect(claude.text == "claude ok")
        let gemini = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi", modelID: "google/gemini-3-flash-preview"))
        #expect(gemini.text == "gemini ok")

        let requests = ClawRouterWireStubProtocol.requests
        #expect(requests.count == 2)
        let anthropic = try #require(requests.first)
        #expect(anthropic.url?.absoluteString == "https://\(ClawRouterWireStubProtocol.host)/v1/native/anthropic/v1/messages")
        let anthropicBody = try JSONDecoder().decode([String: AnyCodable].self, from: anthropic.body)
        #expect(anthropicBody["model"]?.stringValue == "claude-opus-5")
        // The row's catalog limits still apply to the rewritten id.
        #expect(anthropicBody["max_tokens"]?.intValue == 64_000)

        let google = try #require(requests.last)
        #expect(
            google.url?.absoluteString
                == "https://\(ClawRouterWireStubProtocol.host)/v1/native/google-gemini/v1beta/models/gemini-3-flash-preview:generateContent"
        )
    }
}
