import Foundation
import Testing
@testable import OpenClawCore
import OpenClawProtocol

@Suite("Provider config wire keys")
struct ProviderConfigWireKeysTests {
    /// `models.providers.apple-fm` as produced by upstream `extensions/apple-fm/defaults.ts`.
    private static let appleFMProviderJSON = """
    {
      "baseUrl": "http://127.0.0.1",
      "api": "openai-completions",
      "authHeader": false,
      "timeoutSeconds": 120,
      "models": [
        {
          "id": "system",
          "name": "Apple Foundation Model",
          "reasoning": false,
          "input": ["text"],
          "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
          "contextWindow": 8192,
          "maxTokens": 1024,
          "compat": {
            "supportsTools": true,
            "supportsJsonSchemaResponseFormat": true,
            "supportsDeveloperRole": false,
            "supportsUsageInStreaming": true
          }
        }
      ]
    }
    """

    /// An upstream-shaped OpenAI provider row with SecretRef credentials and new model fields.
    private static let openAIProviderJSON = """
    {
      "baseUrl": "https://api.openai.com/v1",
      "apiKey": {"source": "env", "provider": "default", "id": "OPENAI_API_KEY"},
      "auth": "api-key",
      "api": "openai-responses",
      "maxTokens": 32000,
      "params": {"serviceTier": "priority"},
      "headers": {"x-trace": "abc", "x-secret": {"source": "env", "provider": "default", "id": "TRACE_SECRET"}},
      "request": {
        "headers": {"x-extra": "1"},
        "auth": {"mode": "header", "headerName": "x-api-key", "value": "plain", "prefix": "Key "},
        "allowPrivateNetwork": false
      },
      "models": [
        {
          "id": "gpt-6-astra",
          "name": "GPT-6 Astra",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 1050000,
          "contextTokens": 272000,
          "maxTokens": 128000,
          "thinkingLevelMap": {"off": null, "max": "max"},
          "cost": {
            "input": 10, "output": 50, "cacheRead": 1, "cacheWrite": 12.5,
            "tieredPricing": [
              {"input": 10, "output": 50, "cacheRead": 1, "cacheWrite": 12.5, "range": [0, 272001]},
              {"input": 20, "output": 75, "cacheRead": 2, "cacheWrite": 25, "range": [272001]}
            ]
          },
          "params": {"fastMode": "auto", "fastAutoOnSeconds": 30},
          "mediaInput": {"image": {"maxSidePx": 6000, "preferredSidePx": 2048, "tokenMode": "detail"}},
          "compat": {
            "requiresOpenAiAnthropicToolPayload": true,
            "supportedReasoningEfforts": ["low", "medium", "high", "xhigh", "max"],
            "reasoningEffortMap": {"Minimal": "Low"},
            "openRouterRouting": {"allow_fallbacks": false, "order": ["openai"]},
            "cacheControlFormat": "anthropic",
            "supportsLongCacheRetention": false
          }
        }
      ]
    }
    """

    @Test
    func decodesUpstreamAppleFMProviderAndRoundTripsWithUpstreamKeys() throws {
        let config = try JSONDecoder().decode(ModelProviderConfig.self, from: Data(Self.appleFMProviderJSON.utf8))
        #expect(config.baseURL == "http://127.0.0.1")
        #expect(config.api == .openAICompletions)
        #expect(config.authHeader == false)
        #expect(config.timeoutSeconds == 120)
        let model = try #require(config.defaultModel)
        #expect(model.name == "Apple Foundation Model")
        #expect(model.contextWindow == 8_192)
        #expect(model.compat?.supportsJSONSchemaResponseFormat == true)
        #expect(model.compat?.supportsDeveloperRole == false)

        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(encoded.contains("\"baseUrl\""))
        #expect(!encoded.contains("\"baseURL\""))
        #expect(encoded.contains("\"supportsJsonSchemaResponseFormat\""))
        #expect(!encoded.contains("chatCompletionsPath"))
        #expect(!encoded.contains("messagesPath"))
        #expect(!encoded.contains("\"enabled\""))
        let roundTrip = try JSONDecoder().decode(ModelProviderConfig.self, from: Data(encoded.utf8))
        #expect(roundTrip == config)
    }

    @Test
    func decodesSecretInputsAndNewProviderAndModelFields() throws {
        let config = try JSONDecoder().decode(ModelProviderConfig.self, from: Data(Self.openAIProviderJSON.utf8))
        #expect(config.apiKeyInput == .ref(SecretRef(source: .env, id: "OPENAI_API_KEY")))
        #expect(config.apiKey == nil)
        #expect(config.headers == ["x-trace": "abc"])
        #expect(config.headerInputs["x-secret"]?.refValue?.id == "TRACE_SECRET")
        #expect(config.maxTokens == 32_000)
        #expect(config.params?["serviceTier"]?.stringValue == "priority")
        #expect(config.request?.auth == .header(name: "x-api-key", value: .string("plain"), prefix: "Key "))
        #expect(config.request?.headers?["x-extra"] == .string("1"))

        let model = try #require(config.defaultModel)
        #expect(model.contextTokens == 272_000)
        #expect(model.thinkingLevelMap?.mapping(for: .off) == .unsupported)
        #expect(model.thinkingLevelMap?.mapping(for: .max) == .value("max"))
        #expect(model.thinkingLevelMap?.mapping(for: .high) == .identity)
        #expect(model.cost.tieredPricing?.count == 2)
        #expect(model.cost.tieredPricing?[1].contains(promptTokens: 300_000) == true)
        #expect(model.cost.tieredPricing?[0].contains(promptTokens: 272_001) == false)
        #expect(model.fastModeSetting == .auto)
        #expect(model.mediaInput?.image?.preferredSidePx == 2_048)
        #expect(model.mediaInput?.image?.tokenMode == .detail)
        #expect(model.compat?.requiresOpenAIAnthropicToolPayload == true)
        #expect(model.compat?.reasoningEffortMap == ["Minimal": "Low"])
        #expect(model.compat?.openRouterRouting?["allow_fallbacks"]?.boolValue == false)
        #expect(model.compat?.cacheControlFormat == .anthropic)

        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(encoded.contains("\"requiresOpenAiAnthropicToolPayload\":true"))
        #expect(encoded.contains("\"off\":null"))
        #expect(encoded.contains("\"source\":\"env\""))
        let roundTrip = try JSONDecoder().decode(ModelProviderConfig.self, from: Data(encoded.utf8))
        #expect(roundTrip == config)
    }

    @Test
    func legacyKeysDecodeAndRetiredKeysAreNotEncoded() throws {
        let json = """
        {
          "baseURL": "https://legacy.example/v1",
          "models": [
            {
              "id": "m",
              "fastMode": true,
              "compat": {"requiresMistralToolIds": true, "requiresOpenAIAnthropicToolPayload": true}
            }
          ]
        }
        """
        let decoded = try ConfigDecodeIssueCollector.decode(ModelProviderConfig.self, from: Data(json.utf8))
        let config = decoded.value
        #expect(config.baseURL == "https://legacy.example/v1")
        let model = try #require(config.defaultModel)
        #expect(model.fastMode == true)
        #expect(model.params?["fastMode"]?.boolValue == true)
        #expect(model.compat?.requiresOpenAIAnthropicToolPayload == true)
        #expect(decoded.issues.contains { $0.kind == .legacyKey && $0.path.hasSuffix("baseURL") })
        #expect(decoded.issues.contains { $0.kind == .retiredKey })

        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(!encoded.contains("requiresMistralToolIds"))
        #expect(!encoded.contains("requiresMistralToolIDs"))
        #expect(!encoded.contains("\"fastMode\":true,\"id\""))
        #expect(encoded.contains("\"params\":{\"fastMode\":true}"))
    }

    @Test
    func missingBaseURLDecodesEmptyAndCustomProvidersReportIssues() throws {
        let config = try JSONDecoder().decode(ModelProviderConfig.self, from: Data(#"{"apiKey":"sk"}"#.utf8))
        #expect(config.baseURL.isEmpty)
        #expect(config.validationIssues(providerID: "anthropic").isEmpty)
        #expect(ModelProviderConfig.isBuiltInOverlayProviderID("Google"))
        let issues = config.validationIssues(providerID: "my-proxy")
        #expect(issues.map(\.path) == ["models.providers.my-proxy.baseUrl", "models.providers.my-proxy.models"])
    }

    @Test
    func unknownAPIIsPreservedAndReported() throws {
        let json = #"{"baseUrl":"https://x.example","api":"future-transport","models":[{"id":"m","api":"other-future"}]}"#
        let config = try JSONDecoder().decode(ModelProviderConfig.self, from: Data(json.utf8))
        #expect(config.api == nil)
        #expect(config.unrecognizedAPI == "future-transport")
        #expect(config.defaultModel?.unrecognizedAPI == "other-future")
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(encoded.contains("\"api\":\"future-transport\""))
        #expect(config.validationIssues(providerID: "x").contains { $0.kind == .unknownEnumValue })
    }

    @Test
    func fastModeNormalizesUpstreamAliases() {
        #expect(FastMode(normalizing: "Enabled") == .on)
        #expect(FastMode(normalizing: "normal") == .off)
        #expect(FastMode(normalizing: "automatic") == .auto)
        #expect(FastMode(normalizing: "sometimes") == nil)
        #expect(FastMode(jsonValue: AnyCodable(true)) == .on)
        #expect(FastMode(jsonValue: AnyCodable("auto")) == .auto)
        #expect(FastMode.auto.legacyBoolValue == nil)
    }

    @Test
    func catalogRefreshURLValidation() {
        #expect(ModelCatalogRefreshConfig.isValidCatalogURL("https://catalog.openclaw.ai/models/v1/catalog.json"))
        #expect(ModelCatalogRefreshConfig.isValidCatalogURL("http://localhost:8080/catalog.json"))
        #expect(ModelCatalogRefreshConfig.isValidCatalogURL("http://127.0.0.1/catalog.json"))
        #expect(!ModelCatalogRefreshConfig.isValidCatalogURL("http://catalog.example/catalog.json"))
        #expect(!ModelCatalogRefreshConfig(url: "ftp://x").hasValidURL)
    }
}
