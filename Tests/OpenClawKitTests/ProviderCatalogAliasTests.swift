import Testing
@testable import OpenClawCore
@testable import OpenClawModels

@Suite("Provider catalog aliases and model refs")
struct ProviderCatalogAliasTests {
    @Test(arguments: [
        ("google", "google"),
        ("gemini", "google"),
        ("foundation", "apple-fm"),
        ("openai-codex", "openai"),
        ("codex", "openai"),
        ("azure-openai-responses", "openai"),
        ("x-ai", "xai"),
        ("grok", "xai"),
        ("kimi-code", "kimi"),
        ("kimi-coding", "kimi"),
        ("gmi-cloud", "gmi"),
        ("gmicloud", "gmi"),
        ("novita-ai", "novita"),
        ("moonshotai", "moonshot"),
        ("z.ai", "zai"),
        ("fireworks-ai", "fireworks"),
        ("qwencloud", "qwen"),
        ("modelstudio", "qwen"),
        ("dashscope", "qwen"),
        ("bailian-token-plan", "qwen-token-plan"),
        ("minimax-cn", "minimax"),
        ("minimax-portal-cn", "minimax-portal"),
        ("tencent", "tencent-tokenhub"),
        ("bedrock", "amazon-bedrock"),
        ("aws-bedrock", "amazon-bedrock"),
        ("opencode-zen", "opencode"),
        ("opencode-go-auth", "opencode-go"),
        ("doubao", "volcengine"),
        ("  OpenAI  ", "openai"),
    ])
    func aliasesResolveToCanonicalEntries(alias: String, canonical: String) throws {
        #expect(OpenClawReferenceProviderCatalog.normalize(providerID: alias) == canonical)
        let entry = try #require(OpenClawReferenceProviderCatalog.entry(for: alias))
        #expect(entry.providerID == canonical)
    }

    @Test
    func canonicalIDsWinOverAliasesAndAuthAliasesKeepTheirOwnEntries() {
        #expect(OpenClawReferenceProviderCatalog.normalize(providerID: "byteplus-plan") == "byteplus-plan")
        #expect(OpenClawReferenceProviderCatalog.authProviderID(for: "byteplus-plan") == "byteplus")
        #expect(OpenClawReferenceProviderCatalog.authProviderID(for: "volcengine-plan") == "volcengine")
        #expect(OpenClawReferenceProviderCatalog.authProviderID(for: "x-ai") == "xai")
        #expect(OpenClawReferenceProviderCatalog.alias(for: "openai") == nil)
        #expect(OpenClawReferenceProviderCatalog.normalize(providerID: "unknown-provider") == "unknown-provider")
        #expect(OpenClawReferenceProviderCatalog.entry(for: "openai-codex")?.providerID == "openai")
        #expect(OpenClawReferenceProviderCatalog.entries.contains { $0.providerID == "openai-codex" } == false)
        #expect(OpenClawReferenceProviderCatalog.entries.contains { $0.providerID == "modelstudio" } == false)
        #expect(OpenClawReferenceProviderCatalog.entries.contains { $0.providerID == "gemini" } == false)
    }

    @Test
    func legacyCodexRefsResolveToTheOpenAIChatGPTRoute() {
        let resolution = OpenClawReferenceProviderCatalog.resolveModelRef("openai-codex/gpt-5.4-codex")
        #expect(resolution.providerID == "openai")
        #expect(resolution.modelID == "gpt-5.4")
        #expect(resolution.ref == "openai/gpt-5.4")
        #expect(resolution.aliasProviderID == "openai-codex")
        #expect(resolution.api == .openAIChatGPTResponses)
        #expect(resolution.auth == .oauth)
        #expect(resolution.baseURL == "https://chatgpt.com/backend-api/codex")
        #expect(resolution.runtimeHint == "codex")
        #expect(resolution.isLegacy)

        let canonical = OpenClawReferenceProviderCatalog.canonicalizeModelRef("codex/gpt-6-astra")
        #expect(canonical.ref == "openai/gpt-6-astra")
        #expect(canonical.runtimeHint == "codex")
        #expect(OpenClawReferenceProviderCatalog.canonicalizeModelRef("openai/gpt-6-astra").runtimeHint == nil)
    }

    @Test
    func legacyCodexProviderConfigBecomesTheChatGPTRoute() {
        let config = ModelProviderConfig(baseURL: "https://api.openai.com/v1", auth: .apiKey, api: .openAIResponses)
        let canonical = OpenClawReferenceProviderCatalog.canonicalizeProviderConfig(providerID: "openai-codex", config: config)
        #expect(canonical.providerID == "openai")
        #expect(canonical.config.api == .openAIChatGPTResponses)
        #expect(canonical.config.auth == .oauth)
        #expect(canonical.config.baseURL == OpenClawReferenceProviderCatalog.openAIChatGPTBaseURL)

        let azure = OpenClawReferenceProviderCatalog.canonicalizeProviderConfig(
            providerID: "azure-openai-responses",
            config: ModelProviderConfig(baseURL: "https://example.openai.azure.com/openai/v1", api: .openAIResponses)
        )
        #expect(azure.providerID == "openai")
        #expect(azure.config.api == .azureOpenAIResponses)
        #expect(azure.config.baseURL == "https://example.openai.azure.com/openai/v1")
    }

    @Test(arguments: [
        ("anthropic/opus", "anthropic", "claude-opus-5"),
        ("anthropic/opus-5.5", "anthropic", "claude-opus-5-5"),
        ("anthropic/sonnet", "anthropic", "claude-sonnet-5"),
        ("anthropic/haiku", "anthropic", "claude-haiku-4-5"),
        ("anthropic/anthropic/claude-opus-4-6", "anthropic", "claude-opus-4-6"),
        ("google/gemini-3-pro-preview", "google", "gemini-3.1-pro-preview"),
        ("gemini/gemini-3.1-flash-lite-preview", "google", "gemini-3.1-flash-lite"),
        ("google-vertex/gemini-3-flash", "google-vertex", "gemini-3-flash-preview"),
        ("xai/grok-4.7-latest", "xai", "grok-4.7"),
        ("x-ai/grok-build-latest", "xai", "grok-4.5"),
        ("openrouter/auto", "openrouter", "openrouter/auto"),
        ("openrouter/anthropic/claude-opus-5", "openrouter", "anthropic/claude-opus-5"),
        ("nvidia/nemotron-3-ultra-550b-a55b", "nvidia", "nvidia/nemotron-3-ultra-550b-a55b"),
        ("huggingface/huggingface/deepseek-ai/DeepSeek-R1", "huggingface", "deepseek-ai/DeepSeek-R1"),
        ("vercel-ai-gateway/opus-4.6", "vercel-ai-gateway", "anthropic/claude-opus-4-6"),
        ("vercel-ai-gateway/claude-sonnet-5", "vercel-ai-gateway", "anthropic/claude-sonnet-5"),
        ("kimi-code/k2p5", "kimi", "kimi-for-coding"),
        ("kimi/k3[1m]", "kimi", "k3"),
        ("together/moonshotai/Kimi-K2.5", "together", "moonshotai/Kimi-K2.6"),
        ("apple-fm/pcc", "apple-fm", "private-cloud-compute"),
        ("foundation/apple-foundation-default", "apple-fm", "system"),
        ("claude-opus-5", "anthropic", "claude-opus-5"),
        ("gpt-6-astra", "openai", "gpt-6-astra"),
        ("o3", "openai", "o3"),
        ("mystery-model", "", "mystery-model"),
    ])
    func modelRefsNormalizeThroughManifestRules(ref: String, provider: String, model: String) {
        let normalized = OpenClawReferenceProviderCatalog.normalizeModelRef(ref)
        #expect(normalized.provider == provider)
        #expect(normalized.model == model)
    }

    @Test
    func catalogModelLookupAppliesAliasesAndNormalization() throws {
        let row = try #require(OpenClawReferenceProviderCatalog.catalogModel(providerID: "gemini", modelID: "gemini-3-pro"))
        #expect(row.id == "gemini-3.1-pro-preview")
        #expect(OpenClawReferenceProviderCatalog.catalogModel(providerID: "anthropic", modelID: "OPUS")?.id == "claude-opus-5")
        #expect(OpenClawReferenceProviderCatalog.catalogModel(providerID: "openai", modelID: "gpt-4.1-mini") == nil)
    }

    @Test
    func environmentKeyResolutionIsOptInAndOrdered() {
        let environment = [
            "GOOGLE_API_KEY": "google-key",
            "GEMINI_API_KEY": "  ",
            "BYTEPLUS_API_KEY": "byteplus-key",
            "KIMICODE_API_KEY": "kimi-key",
        ]
        #expect(OpenClawReferenceProviderCatalog.resolveAPIKey(providerID: "gemini", environment: environment) == "google-key")
        #expect(OpenClawReferenceProviderCatalog.resolveAPIKey(providerID: "byteplus-plan", environment: environment) == "byteplus-key")
        #expect(OpenClawReferenceProviderCatalog.resolveAPIKey(providerID: "kimi-coding", environment: environment) == "kimi-key")
        #expect(OpenClawReferenceProviderCatalog.resolveAPIKey(providerID: "openai", environment: environment) == nil)
        #expect(OpenClawReferenceProviderCatalog.resolveAPIKey(providerID: "apple-fm", environment: environment) == nil)
        #expect(OpenClawReferenceProviderCatalog.resolveAPIKey(providerID: "unknown", environment: environment) == nil)
        #expect(
            OpenClawReferenceProviderCatalog.resolveAPIKey(providerID: "azure", environment: ["AZURE_SPEECH_KEY": "speech"])
                == "speech"
        )
    }
}
