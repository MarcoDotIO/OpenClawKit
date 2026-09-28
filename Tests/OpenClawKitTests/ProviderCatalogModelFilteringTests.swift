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
        #expect(entry.authEnvVars == ["SGLANG_API_KEY"])
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
        let chatGPTModels = OpenClawModelCatalogParity.normalizeBuiltInModels(
            providerID: "openai",
            models: models,
            baseURL: "https://chatgpt.com/backend-api/codex"
        )

        #expect(openAIModels.isEmpty)
        #expect(azureModels.isEmpty)
        #expect(chatGPTModels.map(\.id) == ["gpt-5.3-codex-spark"])
    }

    @Test
    func normalizeBuiltInModelsSynthesizesCodexSparkFromBaseCodexModel() {
        let models = [
            ModelDefinitionConfig(
                id: "gpt-5.3-codex",
                name: "GPT-5.3 Codex",
                api: .openAIChatGPTResponses,
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
        #expect(normalized.last?.api == .openAIChatGPTResponses)
        #expect(normalized.last?.reasoning == true)
        #expect(normalized.last?.input == [.text])
        #expect(normalized.last?.contextWindow == 128_000)
        #expect(normalized.last?.maxTokens == 128_000)
    }

    @Test
    func normalizeBuiltInModelsSynthesizesSparkOnChatGPTRouteOfCanonicalOpenAI() {
        let models = [
            ModelDefinitionConfig(id: "gpt-5.4", api: .openAIChatGPTResponses, reasoning: true, input: [.text, .image]),
        ]

        let apiKeyRoute = OpenClawModelCatalogParity.normalizeBuiltInModels(providerID: "openai", models: models)
        let chatGPTRoute = OpenClawModelCatalogParity.normalizeBuiltInModels(
            providerID: "openai",
            models: [ModelDefinitionConfig(id: "gpt-5.3-codex", reasoning: true)],
            api: .openAIChatGPTResponses
        )

        #expect(apiKeyRoute.map(\.id) == ["gpt-5.4"])
        #expect(chatGPTRoute.map(\.id) == ["gpt-5.3-codex", "gpt-5.3-codex-spark"])
    }

    @Test
    func normalizeBuiltInModelsPreservesExplicitCodexSparkRows() {
        let models = [
            ModelDefinitionConfig(
                id: "gpt-5.3-codex-spark",
                name: "GPT-5.3 Codex Spark",
                api: .openAIChatGPTResponses,
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
    func normalizeBuiltInModelsHidesRetiredChatGPTRowsAndNormalizesLegacyIDs() {
        let models = [
            ModelDefinitionConfig(id: "gpt-5.4-codex"),
            ModelDefinitionConfig(id: "gpt-5.4-mini"),
            ModelDefinitionConfig(id: "gpt-5.6-luna"),
        ]

        let apiKeyRoute = OpenClawModelCatalogParity.normalizeBuiltInModels(providerID: "openai", models: models)
        let chatGPTRoute = OpenClawModelCatalogParity.normalizeBuiltInModels(providerID: "openai-codex", models: models)

        #expect(apiKeyRoute.map(\.id) == ["gpt-5.4", "gpt-5.4-mini", "gpt-5.6-luna"])
        #expect(chatGPTRoute.map(\.id) == ["gpt-5.6-luna"])
    }

    @Test
    func suppressedBuiltInModelErrorPointsToChatGPTOAuth() {
        let error = OpenClawModelCatalogParity.suppressedBuiltInModelError(
            providerID: "openai",
            modelID: "gpt-5.3-codex-spark"
        )

        #expect(
            error
                == """
                Unknown model: openai/gpt-5.3-codex-spark. \
                gpt-5.3-codex-spark is available only through ChatGPT/Codex OAuth. \
                Run `openclaw models auth login --provider openai` and use openai/gpt-5.3-codex-spark with that \
                OAuth profile; OpenAI API-key auth cannot use this model.
                """
        )
    }

    @Test
    func retiredChatGPTModelErrorNamesTheSuccessor() {
        let error = OpenClawModelCatalogParity.suppressedBuiltInModelError(
            providerID: "openai",
            modelID: "gpt-5.4",
            baseURL: "https://chatgpt.com/backend-api/codex"
        )

        #expect(
            error
                == """
                Unknown model: openai/gpt-5.4. GPT-5.4 has retired from the ChatGPT-account Codex route. \
                Run `openclaw doctor --fix` to replace it with gpt-5.6-terra.
                """
        )
        #expect(OpenClawModelCatalogParity.suppressedBuiltInModelError(providerID: "openai", modelID: "gpt-5.4") == nil)
    }
}
