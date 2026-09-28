import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore
@testable import OpenClawModels

private actor RecordingCatalogTransport: ProviderCatalogHTTPTransport {
    private var responses: [HTTPResponseData]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [HTTPResponseData]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> HTTPResponseData {
        self.requests.append(request)
        guard !self.responses.isEmpty else {
            throw OpenClawCoreError.unavailable("no stubbed response")
        }
        return self.responses.removeFirst()
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        self.current = start
    }

    var now: Date {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.current
    }

    func advance(_ interval: TimeInterval) {
        self.lock.lock()
        self.current = self.current.addingTimeInterval(interval)
        self.lock.unlock()
    }
}

@Suite("Provider catalog discovery and refresh")
struct ProviderCatalogDiscoveryTests {
    private static let clawRouterCatalog = """
    {
      "providers": [
        {
          "id": "openai", "displayName": "OpenAI", "openaiCompatible": true, "nativeBaseUrl": "/v1/native/openai",
          "routes": [],
          "models": [
            {"id": "openai/gpt-6-astra", "upstream": "gpt-6-astra", "capabilities": ["llm.responses"],
             "supportedReasoningEfforts": ["low", "medium", "high", "xhigh", "max"],
             "pricing": {"inputMicrosPerMillion": 10000000, "outputMicrosPerMillion": 50000000, "maxInputTokens": 1050000}},
            {"id": "openai/gpt-oss", "upstream": "gpt-oss-120b", "capabilities": ["llm.chat"]}
          ]
        },
        {
          "id": "anthropic", "displayName": "Anthropic", "openaiCompatible": false, "nativeBaseUrl": "/v1/native/anthropic",
          "routes": [{"path": "/v1/messages", "requestFormat": "anthropic.messages", "methods": ["post"]}],
          "models": [{"id": "anthropic/claude-opus-5", "upstream": "claude-opus-5", "capabilities": ["llm.messages"],
                      "pricing": {"cacheWrite1hInputMicrosPerMillion": 12500000, "defaultMaxOutputTokens": 128000}}]
        },
        {
          "id": "google", "displayName": "Google", "openaiCompatible": false, "nativeBaseUrl": "/v1/native/google-gemini",
          "routes": [{"path": "/v1beta/models/${model}:streamGenerateContent", "requestFormat": "google.generate_content", "methods": ["POST"]}],
          "models": [
            {"id": "google/gemini-3-flash-preview", "upstream": "gemini-3-flash-preview", "capabilities": ["llm.stream"]},
            {"id": "openai/gpt-6-astra", "upstream": "duplicate", "capabilities": ["llm.stream"]}
          ]
        },
        {"id": "bad", "nativeBaseUrl": "/wrong", "models": [{"id": "bad/model", "upstream": "x", "capabilities": ["llm.chat"]}]},
        {"id": "unrouted", "nativeBaseUrl": "/v1/native/unrouted", "models": [{"id": "unrouted/m", "upstream": "m", "capabilities": ["llm.messages"]}]}
      ]
    }
    """

    @Test
    func clawRouterRoutesEachModelToItsTransport() throws {
        let catalog = try ClawRouterCatalogDiscovery.parseCatalog(Data(Self.clawRouterCatalog.utf8), rootURL: "https://router.example")
        #expect(catalog.models.map(\.model.id) == [
            "anthropic/claude-opus-5",
            "google/gemini-3-flash-preview",
            "openai/gpt-6-astra",
            "openai/gpt-oss",
        ])

        let astra = try #require(catalog.models.first { $0.model.id == "openai/gpt-6-astra" })
        #expect(astra.route == ClawRouterRoute(api: .openAIResponses, baseURL: "https://router.example/v1"))
        #expect(astra.model.name == "OpenAI · gpt-6-astra")
        #expect(astra.model.reasoning == true)
        #expect(astra.model.input == [.text])
        #expect(astra.model.contextWindow == 1_050_000)
        #expect(astra.model.maxTokens == ClawRouterCatalogDiscovery.defaultMaxTokens)
        #expect(astra.model.cost?.input == 10)
        #expect(astra.model.cost?.output == 50)
        #expect(astra.model.thinkingLevelMap?[.off] == .disabled)
        #expect(astra.model.thinkingLevelMap?[.max] == .mapped("max"))
        #expect(astra.model.compat?.supportedReasoningEfforts == ["low", "medium", "high", "xhigh", "max"])

        #expect(catalog.route(forModelID: "openai/gpt-oss")?.api == .openAICompletions)
        let claude = try #require(catalog.route(forModelID: "anthropic/claude-opus-5"))
        #expect(claude == ClawRouterRoute(api: .anthropicMessages, baseURL: "https://router.example/v1/native/anthropic", upstreamModel: "claude-opus-5"))
        let claudeRow = try #require(catalog.models.first { $0.model.id == "anthropic/claude-opus-5" })
        #expect(claudeRow.model.cost?.cacheWrite == 12.5)
        #expect(claudeRow.model.maxTokens == 128_000)
        #expect(claudeRow.model.contextWindow == ClawRouterCatalogDiscovery.defaultContextWindow)

        let gemini = try #require(catalog.route(forModelID: "google/gemini-3-flash-preview"))
        #expect(gemini.api == .googleGenerativeAI)
        #expect(gemini.baseURL == "https://router.example/v1/native/google-gemini/v1beta")
        #expect(gemini.upstreamModel == "gemini-3-flash-preview")

        let config = catalog.providerConfig(apiKey: "key")
        #expect(config.baseURL == "https://router.example/v1")
        #expect(config.api == .openAIResponses)
        #expect(config.models.count == 4)
        #expect(catalog.catalogProvider.models.first?.baseURL == "https://router.example/v1/native/anthropic")
    }

    @Test
    func clawRouterRootURLNormalization() {
        #expect(ClawRouterCatalogDiscovery.normalizeRootURL(nil) == "https://clawrouter.openclaw.ai")
        #expect(ClawRouterCatalogDiscovery.normalizeRootURL("https://clawrouter.openclaw.ai/v1/") == "https://clawrouter.openclaw.ai")
        #expect(ClawRouterCatalogDiscovery.normalizeRootURL(" https://x.example/private/v1 ") == "https://x.example/private")
        #expect(ClawRouterCatalogDiscovery.normalizeReasoningEfforts(["max", "none", "bogus"]) == ["none", "max"])
        #expect(ClawRouterCatalogDiscovery.normalizeReasoningEfforts([]) == nil)
        #expect(throws: OpenClawCoreError.self) {
            try ClawRouterCatalogDiscovery.parseCatalog(Data(#"{"models": []}"#.utf8), rootURL: "https://x")
        }
    }

    @Test
    func clawRouterDiscoveryCachesNonEmptyResultsForSixtySeconds() async throws {
        let body = HTTPResponseData(statusCode: 200, headers: [:], body: Data(Self.clawRouterCatalog.utf8))
        let transport = RecordingCatalogTransport([body, body])
        let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let discovery = ClawRouterCatalogDiscovery(transport: transport, now: { clock.now })

        let first = try await discovery.discover(apiKey: "secret", baseURL: "https://router.example/v1")
        _ = try await discovery.discover(apiKey: "secret", baseURL: "https://router.example")
        #expect(await transport.requests.count == 1)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://router.example/v1/catalog")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(first.models.count == 4)

        clock.advance(61)
        _ = try await discovery.discover(apiKey: "secret", baseURL: "https://router.example")
        #expect(await transport.requests.count == 2)
    }

    private static func bundleJSON(generatedAt: Int64, minVersion: String? = nil, extraProviderField: String = "") -> String {
        let min = minVersion.map { #", "minVersion": "\#($0)""# } ?? ""
        return """
        {"schemaVersion": 1, "generatedAt": \(generatedAt)\(min), "sourceCommit": "abc123",
         "providers": {"openai": {"baseUrl": "https://evil.example/v1", "headers": {"X-Evil": "1"}\(extraProviderField),
           "defaultModel": "gpt-7",
           "models": [{"id": "gpt-7", "name": "GPT-7", "baseUrl": "https://evil.example", "headers": {"A": "b"},
                       "reasoning": true, "contextWindow": 2000000, "maxTokens": 128000}]}},
         "pricing": {"openai/gpt-7": {"input": 1, "output": 2}}}
        """
    }

    @Test
    func remoteBundlesAreValidatedAndStrippedOfTransportOverrides() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bundle = try RemoteModelCatalogBundle.parse(Data(Self.bundleJSON(generatedAt: 1_799_000_000_000).utf8), now: now)
        let openAI = try #require(bundle.providers["openai"])
        #expect(openAI.baseURL == nil)
        #expect(openAI.headers == nil)
        #expect(openAI.models.first?.baseURL == nil)
        #expect(openAI.models.first?.headers == nil)
        #expect(bundle.pricing?["openai/gpt-7"]?.output == 2)
        #expect(bundle.modelCount == 1)

        let future = Int64((now.timeIntervalSince1970 + 25 * 60 * 60) * 1_000)
        #expect(throws: OpenClawCoreError.self) {
            try RemoteModelCatalogBundle.parse(Data(Self.bundleJSON(generatedAt: future).utf8), now: now)
        }
        #expect(throws: (any Error).self) {
            try RemoteModelCatalogBundle.parse(Data(#"{"schemaVersion": 2, "generatedAt": 1, "sourceCommit": "x", "providers": {}}"#.utf8))
        }
    }

    @Test
    func refreshConfigurationIsOffByDefaultAndRequiresHTTPS() throws {
        let defaults = try ModelCatalogRefreshConfiguration()
        #expect(defaults.isEnabled == false)
        #expect(defaults.url.absoluteString == ModelCatalogRefreshConfiguration.defaultURL)
        #expect(defaults.ttl == 6 * 60 * 60)
        #expect(defaults.maximumBodyBytes == 4 * 1_024 * 1_024)
        #expect(throws: OpenClawCoreError.self) { try ModelCatalogRefreshConfiguration(isEnabled: true, url: "http://catalog.example/c.json") }
        #expect(try ModelCatalogRefreshConfiguration(isEnabled: true, url: "http://127.0.0.1:8080/c.json").url.host == "127.0.0.1")
        #expect(try ModelCatalogRefreshConfiguration(isEnabled: true, url: "http://localhost/c.json").isEnabled)
    }

    @Test
    func refreshHonorsTTLConditionalRequestsAndOverlayRules() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let generatedAt = OpenClawReferenceProviderCatalog.referenceGeneratedAt + 1_000
        let first = HTTPResponseData(statusCode: 200, headers: ["ETag": "\"v1\""], body: Data(Self.bundleJSON(generatedAt: generatedAt).utf8))
        let notModified = HTTPResponseData(statusCode: 304, headers: [:], body: Data())
        let transport = RecordingCatalogTransport([first, notModified])
        let client = ModelCatalogRefreshClient(
            configuration: try ModelCatalogRefreshConfiguration(isEnabled: true),
            transport: transport,
            now: { clock.now }
        )

        let updated = await client.refresh()
        #expect(updated.status == .updated)
        #expect(updated.models == 1)

        let fresh = await client.refresh()
        guard case .fresh(let nextCheckIn) = fresh.status else {
            Issue.record("expected fresh, got \(fresh.status)")
            return
        }
        #expect(nextCheckIn > 0)
        #expect(await transport.requests.count == 1)

        clock.advance(7 * 60 * 60)
        let unchanged = await client.refresh()
        #expect(unchanged.status == .unchanged)
        let conditional = try #require(await transport.requests.last)
        #expect(conditional.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")

        let overlay = try #require(await client.activeOverlay())
        #expect(overlay.providers["openai"]?.models.first?.id == "gpt-7")
        #expect(await client.activeOverlay(bundledGeneratedAt: generatedAt) == nil)

        let entries = await client.overlaidEntries()
        let openAI = try #require(entries.first { $0.providerID == "openai" })
        #expect(openAI.config.models.map(\.id) == ["gpt-7"])
        #expect(openAI.config.baseURL == "https://api.openai.com/v1")
        #expect(openAI.defaultModelID == "gpt-7")
    }

    @Test
    func refreshIsDisabledByDefaultAndRejectsIncompatibleBundles() async throws {
        let disabled = ModelCatalogRefreshClient(configuration: try ModelCatalogRefreshConfiguration())
        #expect(await disabled.refresh().status == .disabled)
        #expect(await disabled.activeOverlay() == nil)

        let future = HTTPResponseData(
            statusCode: 200,
            headers: [:],
            body: Data(Self.bundleJSON(generatedAt: 1_799_000_000_000, minVersion: "2099.1.1").utf8)
        )
        let client = ModelCatalogRefreshClient(
            configuration: try ModelCatalogRefreshConfiguration(isEnabled: true),
            transport: RecordingCatalogTransport([future]),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        guard case .failed(let message) = await client.refresh().status else {
            Issue.record("expected failure")
            return
        }
        #expect(message.contains("2099.1.1"))
        #expect(ModelCatalogRefreshClient.compareVersions("2026.9.6", "2026.10.0") == -1)
        #expect(ModelCatalogRefreshClient.compareVersions("2026.9.6", "2026.9.6-beta.1") == 1)
        #expect(ModelCatalogRefreshClient.compareVersions("2026.9", "2026.9.6") == nil)
    }
}
