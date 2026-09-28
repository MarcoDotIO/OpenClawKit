import Foundation
import Testing
@testable import OpenClawCore
@testable import OpenClawModels

@Suite("Model catalog manifest row types")
struct ModelCatalogTypesTests {
    // Copied from extensions/openai/openclaw.plugin.json (OpenClaw 2026.9.6).
    private static let gpt6AstraRow = """
    {
      "id": "gpt-6-astra",
      "name": "GPT-6 Astra",
      "reasoning": true,
      "input": ["text", "image"],
      "contextWindow": 1050000,
      "contextTokens": 272000,
      "maxTokens": 128000,
      "cost": {
        "input": 10, "output": 50, "cacheRead": 1, "cacheWrite": 12.5,
        "tieredPricing": [
          {"range": [0, 272001], "input": 10, "output": 50, "cacheRead": 1, "cacheWrite": 12.5},
          {"range": [272001], "input": 20, "output": 75, "cacheRead": 2, "cacheWrite": 25}
        ]
      },
      "thinkingLevelMap": {"off": null, "minimal": "low", "xhigh": "xhigh", "max": "max"},
      "compat": {
        "supportsReasoningEffort": true,
        "supportedReasoningEfforts": ["low", "medium", "high", "xhigh", "max"],
        "supportsTemperature": false,
        "codeMode": "preferred"
      }
    }
    """

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test
    func upstreamOpenAIRowDecodesWithExplicitNullThinkingLevels() throws {
        let row = try Self.decode(ModelCatalogModel.self, Self.gpt6AstraRow)

        #expect(row.id == "gpt-6-astra")
        #expect(row.input == [.text, .image])
        #expect(row.contextWindow == 1_050_000)
        #expect(row.contextTokens == 272_000)
        #expect(row.effectiveContextBudget() == 272_000)
        #expect(row.thinkingLevelMap?[.off] == .disabled)
        #expect(row.thinkingLevelMap?[.minimal] == .mapped("low"))
        #expect(row.thinkingLevelMap?[.medium] == nil)
        #expect(row.thinkingLevelMap?.providerValue(for: .medium) == "medium")
        #expect(row.thinkingLevelMap?.providerValue(for: .off) == nil)
        #expect(row.compat?.supportsTemperature == false)
        #expect(row.compat?.codeMode == "preferred")
        #expect(row.cost?.tier(forPromptTokens: 100_000)?.input == 10)
        #expect(row.cost?.tier(forPromptTokens: 272_001)?.output == 75)
        #expect(row.cost?.tier(forPromptTokens: 5_000_000)?.cacheWrite == 25)
    }

    @Test
    func thinkingLevelMapEncodingPreservesNull() throws {
        let row = try Self.decode(ModelCatalogModel.self, Self.gpt6AstraRow)
        let encoded = try #require(String(data: JSONEncoder().encode(row.thinkingLevelMap), encoding: .utf8))
        #expect(encoded.contains("\"off\":null"))
        #expect(encoded.contains("\"minimal\":\"low\""))

        let roundTripped = try JSONDecoder().decode(ModelCatalogModel.self, from: JSONEncoder().encode(row))
        #expect(roundTripped == row)
    }

    @Test
    func encodingUsesUpstreamWireKeys() throws {
        var compat = ModelCatalogCompatConfig()
        compat.requiresOpenAIAnthropicToolPayload = true
        let row = ModelCatalogModel(id: "claude-opus-5", api: .anthropicMessages, baseURL: "https://opencode.ai/zen", compat: compat)
        let json = try #require(String(data: JSONEncoder().encode(row), encoding: .utf8))

        #expect(json.contains("\"baseUrl\""))
        #expect(!json.contains("\"baseURL\""))
        #expect(json.contains("\"requiresOpenAiAnthropicToolPayload\":true"))
        #expect(json.contains("\"api\":\"anthropic-messages\""))
    }

    @Test
    func compatDecodesUpstreamKeysAndDropsUnknownValues() throws {
        let compat = try Self.decode(
            ModelCatalogCompatConfig.self,
            """
            {
              "requiresOpenAiAnthropicToolPayload": true,
              "maxTokensField": "max_tokens",
              "thinkingFormat": "qwen-chat-template",
              "codeMode": "sometimes",
              "supportsStore": "yes",
              "supportedReasoningEfforts": [],
              "reasoningEffortMap": {"low": "high", "off": "none"},
              "openRouterRouting": {"order": ["anthropic"], "allow_fallbacks": false}
            }
            """
        )

        #expect(compat.requiresOpenAIAnthropicToolPayload == true)
        #expect(compat.maxTokensField == .maxTokens)
        #expect(compat.thinkingFormat == .qwenChatTemplate)
        #expect(compat.codeMode == nil)
        #expect(compat.supportsStore == nil)
        #expect(compat.disablesReasoningEffort)
        #expect(compat.reasoningEffortMap?["off"] == "none")
        #expect(compat.openRouterRouting?["allow_fallbacks"]?.boolValue == false)
        #expect(compat.runtimeConfig.requiresOpenAIAnthropicToolPayload == true)
        #expect(compat.runtimeConfig.maxTokensField == .maxTokens)
    }

    @Test
    func contextWindowOptionsAndDefaultAreAtomic() throws {
        let valid = try Self.decode(
            ModelCatalogModel.self,
            """
            {"id": "claude-opus-5", "contextWindow": 1000000,
             "contextWindows": [{"id": "1m", "label": "1M", "contextWindow": 1000000},
                                {"id": "200k", "label": "200K", "contextWindow": 200000},
                                {"id": "200k", "label": "dupe", "contextWindow": 5}],
             "contextWindowDefault": "1m"}
            """
        )
        #expect(valid.contextWindows?.map(\.id) == ["200k", "1m"])
        #expect(valid.contextWindowDefault == "1m")
        #expect(valid.effectiveContextBudget() == 1_000_000)
        #expect(valid.effectiveContextBudget(selectedContextWindowID: "200k") == 200_000)

        let invalidDefault = try Self.decode(
            ModelCatalogModel.self,
            """
            {"id": "m", "contextWindows": [{"id": "1m", "label": "1M", "contextWindow": 1000000}], "contextWindowDefault": "2m"}
            """
        )
        #expect(invalidDefault.contextWindows == nil)
        #expect(invalidDefault.contextWindowDefault == nil)
    }

    @Test
    func manifestCatalogBlockDecodesLeniently() throws {
        let catalog = try Self.decode(
            ModelCatalog.self,
            """
            {
              "providers": {
                "google": {
                  "baseUrl": "https://generativelanguage.googleapis.com/v1beta",
                  "api": "google-generative-ai",
                  "models": [
                    {"id": "gemini-3-flash-preview", "input": ["text", "image", "video", "hologram"], "contextWindow": 1048576},
                    {"name": "missing id"}
                  ]
                },
                "empty": {"models": []}
              },
              "aliases": {"azure-openai-responses": {"provider": "openai", "api": "azure-openai-responses"}},
              "discovery": {"google": "runtime", "other": "sometimes"},
              "suppressions": [{"provider": "google", "model": "gemini-1.5-pro", "reason": "retired"}, {"model": "no-provider"}]
            }
            """
        )

        let google = try #require(catalog.providers?["google"])
        #expect(google.models.map(\.id) == ["gemini-3-flash-preview"])
        #expect(google.models.first?.input == [.text, .image, .video])
        #expect(catalog.providers?["empty"] == nil)
        #expect(catalog.aliases?["azure-openai-responses"]?.api == .azureOpenAIResponses)
        #expect(catalog.discovery == ["google": .runtime])
        #expect(catalog.suppressions?.count == 1)

        let rows = catalog.normalizedRows()
        #expect(rows.first?.ref == "google/gemini-3-flash-preview")
        #expect(rows.first?.mergeKey == "google::gemini-3-flash-preview")
        #expect(rows.first?.api == .googleGenerativeAI)
        #expect(rows.first?.status == .available)
        #expect(rows.first?.reasoning == false)
    }

    @Test
    func appleFMProviderConfigFixtureDecodes() throws {
        // Upstream extensions/apple-fm/defaults.ts buildAppleFmProviderConfig output. Upstream fills
        // contextWindow from runtime facts; the SDK catalog row uses the 8,192-token on-device window.
        let provider = try Self.decode(
            ModelCatalogProvider.self,
            """
            {
              "baseUrl": "http://127.0.0.1",
              "api": "openai-completions",
              "models": [{
                "id": "system", "name": "Apple Foundation Models", "reasoning": false, "input": ["text"],
                "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                "contextWindow": 8192, "maxTokens": 1024,
                "compat": {"supportsTools": true, "supportsJsonSchemaResponseFormat": true,
                           "supportsDeveloperRole": false, "supportsUsageInStreaming": true}
              }]
            }
            """
        )
        let entry = try #require(OpenClawReferenceProviderCatalog.entry(for: "apple-fm"))
        #expect(entry.catalog.baseURL == provider.baseURL)
        #expect(entry.catalog.api == provider.api)
        #expect(entry.catalog.model(id: "system") == provider.models.first)
        #expect(entry.config.authHeader == false)
        #expect(entry.config.auth == nil)
        #expect(entry.aliases == ["foundation", "apple-foundation"])
        #expect(OpenClawReferenceProviderCatalog.normalize(providerID: "apple-foundation") == "apple-fm")
        #expect(OpenClawReferenceProviderCatalog.normalize(providerID: "foundation") == "apple-fm")
        let pcc = try #require(entry.catalog.model(id: "private-cloud-compute"))
        #expect(pcc.tags?.contains("network-required") == true)
        #expect(pcc.params?["network"]?.stringValue == "required")
        #expect(pcc.definitionConfig().params?["network"]?.stringValue == "required")
    }

    @Test
    func googleCatalogRowsAcceptVideoInput() throws {
        let google = try #require(OpenClawReferenceProviderCatalog.entry(for: "google"))
        #expect(google.models.allSatisfy { $0.effectiveInput.contains(.video) })
        let vertex = try #require(OpenClawReferenceProviderCatalog.entry(for: "google-vertex"))
        #expect(vertex.config.api == .googleVertex)
        #expect(vertex.config.baseURL == "https://{location}-aiplatform.googleapis.com")
        #expect(vertex.models.contains { $0.effectiveInput.contains(.video) } == false)
        #expect(vertex.authEnvVars == ["GOOGLE_CLOUD_API_KEY"])
    }

    @Test
    func suppressionMatchingFollowsUpstreamRouteRules() {
        let spark = ModelCatalogSuppression(
            provider: "openai",
            model: "gpt-5.3-codex-spark",
            reason: "ChatGPT only.",
            when: .init(baseUrlHosts: ["api.openai.com"])
        )
        #expect(spark.matches(provider: "openai", model: "GPT-5.3-codex-spark"))
        #expect(spark.matches(provider: "openai", model: "gpt-5.3-codex-spark", baseURL: "https://api.openai.com/v1"))
        #expect(!spark.matches(provider: "openai", model: "gpt-5.3-codex-spark", baseURL: "https://chatgpt.com/backend-api/codex"))
        #expect(!spark.matches(provider: "openai", model: "gpt-5.3-codex-spark", baseURL: "not a url"))

        let retired = ModelCatalogSuppression(
            provider: "openai",
            model: "gpt-5.4",
            reason: "Retired.",
            retirement: .init(replacedBy: "gpt-5.6-terra"),
            when: .init(baseUrlHosts: ["chatgpt.com"])
        )
        #expect(!retired.matches(provider: "openai", model: "gpt-5.4"))
        #expect(retired.matches(provider: "openai", model: "gpt-5.4", baseURL: "https://chatgpt.com./backend-api"))
        #expect(retired.errorMessage() == "Unknown model: openai/gpt-5.4. Retired. Run `openclaw doctor --fix` to replace it with gpt-5.6-terra.")

        let apiScoped = ModelCatalogSuppression(provider: "qwen", model: "m", when: .init(providerConfigApiIn: ["openai-responses"]))
        #expect(apiScoped.matches(provider: "qwen", model: "m", api: .openAIResponses))
        #expect(!apiScoped.matches(provider: "qwen", model: "m", api: .openAICompletions))
    }

    @Test
    func catalogSuppressionsHideRetiredGoogleAndXAIRows() {
        #expect(OpenClawReferenceProviderCatalog.suppression(providerID: "gemini", modelID: "gemini-2.0-flash") != nil)
        #expect(OpenClawReferenceProviderCatalog.suppression(providerID: "google", modelID: "gemini-3-flash-preview") == nil)
        #expect(OpenClawReferenceProviderCatalog.suppression(providerID: "azure-openai-responses", modelID: "gpt-5.3-codex-spark") != nil)
        let message = OpenClawReferenceProviderCatalog.suppressionErrorMessage(providerID: "google", modelID: "gemini-1.5-pro")
        #expect(message?.hasPrefix("Unknown model: google/gemini-1.5-pro. Google shut down Gemini 1.5 Pro") == true)
    }

    @Test
    func selectableModelsHideDisabledAndSuppressedRowsAndSortDeprecatedLast() throws {
        let rows = OpenClawReferenceProviderCatalog.selectableModels(providerID: "openai")
        let ids = rows.map(\.id)
        #expect(ids.first == "gpt-6-astra")
        #expect(ids.contains("gpt-5.4"))
        #expect(rows.allSatisfy { $0.status != .disabled })
        if let firstDeprecated = rows.firstIndex(where: { $0.status == .deprecated }) {
            #expect(rows[firstDeprecated...].allSatisfy { $0.status == .deprecated })
        }

        let chatGPT = OpenClawReferenceProviderCatalog.selectableModels(
            providerID: "openai",
            baseURL: "https://chatgpt.com/backend-api/codex"
        )
        #expect(!chatGPT.map(\.id).contains("gpt-5.4"))
        #expect(!chatGPT.map(\.id).contains("gpt-5.4-mini"))
    }

    @Test
    func successorFollowsRetirementChains() {
        #expect(OpenClawReferenceProviderCatalog.successor(
            providerID: "openai",
            modelID: "gpt-5.4",
            baseURL: "https://chatgpt.com/backend-api/codex"
        ) == "gpt-5.6-terra")
        #expect(OpenClawReferenceProviderCatalog.successor(providerID: "openai", modelID: "gpt-6-astra") == nil)
    }
}
