import Testing
@testable import OpenClawCore
@testable import OpenClawModels

/// Hand-checked upstream 2026.9.6 defaults (independent of the generated fixture).
@Suite("Provider catalog 2026.9.6 defaults")
struct ProviderCatalogDefaultsTests {
    @Test(arguments: [
        ("openai", "gpt-6-astra", "https://api.openai.com/v1"),
        ("anthropic", "claude-opus-5", "https://api.anthropic.com"),
        ("google", "gemini-3.1-pro-preview", "https://generativelanguage.googleapis.com/v1beta"),
        ("xai", "grok-4.7", "https://api.x.ai/v1"),
        ("moonshot", "kimi-k3", "https://api.moonshot.ai/v1"),
        ("zai", "glm-5.2", "https://api.z.ai/api/paas/v4"),
        ("minimax", "MiniMax-M3", "https://api.minimax.io/anthropic"),
        ("deepseek", "deepseek-v4-pro", "https://api.deepseek.com"),
        ("github-copilot", "claude-sonnet-5", "https://api.individual.githubcopilot.com"),
        ("ollama", "gemma4", "http://127.0.0.1:11434"),
        ("openrouter", "openrouter/auto", "https://openrouter.ai/api/v1"),
        ("groq", "openai/gpt-oss-120b", "https://api.groq.com/openai/v1"),
        ("cerebras", "gemma-4-31b", "https://api.cerebras.ai/v1"),
        ("together", "moonshotai/Kimi-K2.6", "https://api.together.xyz/v1"),
        ("xiaomi", "mimo-v2.6-pro", "https://api.xiaomimimo.com/v1"),
        ("kilocode", "kilo-auto/balanced", "https://api.kilo.ai/api/gateway/"),
        ("fireworks", "accounts/fireworks/routers/glm-5p2-fast", "https://api.fireworks.ai/inference/v1"),
        ("opencode", "claude-opus-5", "https://opencode.ai/zen/v1"),
        ("opencode-go", "deepseek-v4-pro", "https://opencode.ai/zen/go/v1"),
        ("litellm", "claude-opus-4-6", "http://localhost:4000"),
        ("baseten", "thinkingmachines/inkling", "https://inference.baseten.co/v1"),
        ("cohere", "command-a-plus-05-2026", "https://api.cohere.ai/compatibility/v1"),
        ("deepinfra", "deepseek-ai/DeepSeek-V4-Flash", "https://api.deepinfra.com/v1/openai"),
        ("featherless", "Qwen/Qwen3-32B", "https://api.featherless.ai/v1"),
        ("gmi", "openai/gpt-5.6-sol", "https://api.gmi-serving.com/v1"),
        ("longcat", "LongCat-2.0", "https://api.longcat.chat/openai"),
        ("meta", "muse-spark-1.3", "https://api.meta.ai/v1"),
        ("novita", "deepseek/deepseek-v4-pro", "https://api.novita.ai/openai/v1"),
        ("ollama-cloud", "minimax-m2.7", "https://ollama.com"),
        ("qwen-token-plan", "qwen3.7-plus", "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"),
        ("tencent-tokenplan", "hy4-preview", "https://api.lkeap.cloud.tencent.com/plan/v3"),
        ("xiaomi-token-plan", "mimo-v2.6-pro", "https://token-plan-sgp.xiaomimimo.com/v1"),
        ("kimi", "kimi-for-coding", "https://api.kimi.com/coding/"),
        ("llama-cpp", "gemma-4-e4b-it-q4_k_m", "http://127.0.0.1:19432/v1"),
        ("apple-fm", "system", "http://127.0.0.1"),
    ])
    func defaultModelsAndBaseURLs(provider: String, model: String, baseURL: String) throws {
        let entry = try #require(OpenClawReferenceProviderCatalog.entry(for: provider))
        #expect(entry.defaultModelID == model)
        #expect(entry.config.defaultModel?.id == model)
        #expect(entry.config.baseURL == baseURL)
    }

    @Test
    func providerAPIsMatchUpstream() {
        let catalog = OpenClawReferenceProviderCatalog.self
        #expect(catalog.entry(for: "xai")?.config.api == .openAIResponses)
        #expect(catalog.entry(for: "github-copilot")?.config.api == .openAIResponses)
        #expect(catalog.entry(for: "github-copilot")?.config.defaultModel?.api == .anthropicMessages)
        #expect(catalog.entry(for: "xiaomi")?.config.api == .openAICompletions)
        #expect(catalog.entry(for: "meta")?.config.api == .openAIResponses)
        #expect(catalog.entry(for: "kimi")?.config.api == .anthropicMessages)
        #expect(catalog.entry(for: "ollama-cloud")?.config.api == .ollama)
        #expect(catalog.entry(for: "radius")?.config.api == .piMessages)
        #expect(catalog.entry(for: "radius")?.requiresDiscovery == true)
        #expect(catalog.entry(for: "clawrouter")?.config.api == .openAIResponses)
        #expect(catalog.entry(for: "google-vertex")?.config.api == .googleVertex)
    }

    @Test
    func kimiCodeSendsTheClaudeCodeUserAgent() throws {
        let kimi = try #require(OpenClawReferenceProviderCatalog.entry(for: "kimi-coding"))
        #expect(kimi.config.headers["User-Agent"] == "claude-code/0.1.0")
        #expect(kimi.authEnvVars == ["KIMI_API_KEY", "KIMICODE_API_KEY"])
        #expect(kimi.models.map(\.id).contains("k3"))
    }

    @Test
    func openAIUtilityAndAnthropicUtilityModels() {
        #expect(OpenClawReferenceProviderCatalog.entry(for: "openai")?.defaultUtilityModelID == "gpt-5.6-luna")
        #expect(OpenClawReferenceProviderCatalog.entry(for: "anthropic")?.defaultUtilityModelID == "claude-haiku-4-5")
    }

    @Test
    func claude5RowsDeclareContextWindowOptions() throws {
        let opus = try #require(OpenClawReferenceProviderCatalog.catalogModel(providerID: "anthropic", modelID: "claude-opus-5"))
        #expect(opus.contextWindows?.map(\.id).contains("1m") == true)
        #expect(opus.contextWindowDefault != nil)
    }

    @Test
    func factoryRoutesRenamedProvidersToTheirRuntimes() throws {
        let appleFM = try #require(OpenClawReferenceProviderCatalog.entry(for: "apple-fm"))
        let provider = try ModelProviderFactory.makeProvider(providerID: "foundation", config: appleFM.config)
        #expect(provider is FoundationModelsProvider)

        let google = try #require(OpenClawReferenceProviderCatalog.entry(for: "google"))
        let gemini = try ModelProviderFactory.makeProvider(providerID: "gemini", config: google.config)
        #expect(gemini.id == "google")

        let xiaomi = try #require(OpenClawReferenceProviderCatalog.entry(for: "xiaomi"))
        let xiaomiProvider = try ModelProviderFactory.makeProvider(providerID: "xiaomi", config: xiaomi.config)
        #expect(!(xiaomiProvider is XiaomiModelProvider))
        #expect(xiaomiProvider.id == "xiaomi")

        let radius = try #require(OpenClawReferenceProviderCatalog.entry(for: "radius"))
        #expect(throws: OpenClawCoreError.self) {
            try ModelProviderFactory.makeProvider(providerID: "radius", config: radius.config)
        }
    }
}
