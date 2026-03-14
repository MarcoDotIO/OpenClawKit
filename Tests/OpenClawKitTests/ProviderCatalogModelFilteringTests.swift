import Testing
@testable import OpenClawCore
@testable import OpenClawModels

@Suite("Provider catalog model filtering")
struct ProviderCatalogModelFilteringTests {
    @Test
    func sglangCatalogEntryMatchesBundledDefaults() throws {
        let entry = try #require(OpenClawReferenceProviderCatalog.entry(for: "sglang"))

        #expect(entry.displayName == "SGLang")
        #expect(entry.config.auth == .apiKey)
        #expect(entry.config.api == .openAICompletions)
        #expect(entry.config.baseURL == "http://127.0.0.1:30000/v1")
        #expect(entry.config.defaultModel?.id == "Qwen/Qwen3-8B")
    }

    @Test
    func normalizeBuiltInModelsSuppressesDirectSparkRows() {
        let models = [
            ModelDefinitionConfig(
                id: "gpt-5.3-codex-spark",
                name: "GPT-5.3 Codex Spark",
                api: .openAIResponses,
                reasoning: true,
                input: [.text, .image],
                contextWindow: 128_000,
                maxTokens: 128_000
            ),
        ]

        let openAIModels = OpenClawModelCatalogParity.normalizeBuiltInModels(
            providerID: "openai",
            models: models
        )
        let azureModels = OpenClawModelCatalogParity.normalizeBuiltInModels(
            providerID: "azure-openai-responses",
            models: models
        )

        #expect(openAIModels.isEmpty)
        #expect(azureModels.isEmpty)
    }

    @Test
    func normalizeBuiltInModelsSynthesizesCodexSparkFromBaseCodexModel() {
        let models = [
            ModelDefinitionConfig(
                id: "gpt-5.3-codex",
                name: "GPT-5.3 Codex",
                api: .openAICodexResponses,
                reasoning: true,
                input: [.text],
                contextWindow: 200_000,
                maxTokens: 64_000
            ),
        ]

        let normalized = OpenClawModelCatalogParity.normalizeBuiltInModels(
            providerID: "openai-codex",
            models: models
        )

        #expect(normalized.map(\.id) == ["gpt-5.3-codex", "gpt-5.3-codex-spark"])
        #expect(normalized.last?.name == "gpt-5.3-codex-spark")
        #expect(normalized.last?.api == .openAICodexResponses)
        #expect(normalized.last?.reasoning == true)
        #expect(normalized.last?.input == [.text])
        #expect(normalized.last?.contextWindow == 128_000)
        #expect(normalized.last?.maxTokens == 128_000)
    }

    @Test
    func normalizeBuiltInModelsPreservesExplicitCodexSparkRows() {
        let models = [
            ModelDefinitionConfig(
                id: "gpt-5.3-codex-spark",
                name: "GPT-5.3 Codex Spark",
                api: .openAICodexResponses,
                reasoning: true,
                input: [.text],
                contextWindow: 128_000,
                maxTokens: 128_000
            ),
        ]

        let normalized = OpenClawModelCatalogParity.normalizeBuiltInModels(
            providerID: "openai-codex",
            models: models
        )

        #expect(normalized.count == 1)
        #expect(normalized.first?.id == "gpt-5.3-codex-spark")
    }

    @Test
    func suppressedBuiltInModelErrorPointsToCodexOAuth() {
        let error = OpenClawModelCatalogParity.suppressedBuiltInModelError(
            providerID: "openai",
            modelID: "gpt-5.3-codex-spark"
        )

        #expect(
            error
                == """
                Unknown model: openai/gpt-5.3-codex-spark. \
                gpt-5.3-codex-spark is only supported via openai-codex OAuth. \
                Use openai-codex/gpt-5.3-codex-spark.
                """
        )
    }
}
