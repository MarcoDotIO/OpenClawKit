import Foundation
import OpenClawCore

/// Capability bucket advertised by an upstream provider or provider-like plugin.
public enum ProviderCapability: String, Codable, Sendable, Equatable, CaseIterable {
    case text
    case imageGeneration = "image-generation"
    case videoGeneration = "video-generation"
    case musicGeneration = "music-generation"
    case speech
    case realtimeVoice = "realtime-voice"
    case realtimeTranscription = "realtime-transcription"
    case mediaUnderstanding = "media-understanding"
    case memoryEmbedding = "memory-embedding"
    case webSearch = "web-search"
    case tool
}

/// Canonical provider entry derived from the pinned OpenClaw TS reference snapshot.
public struct ProviderCatalogEntry: Sendable, Equatable {
    /// Stable provider identifier.
    public var providerID: String
    /// User-facing provider display name.
    public var displayName: String
    /// Additional provider aliases accepted by config and routing helpers.
    public var aliases: [String]
    /// Capability groups advertised for this provider entry.
    public var capabilities: [ProviderCapability]
    /// Default provider configuration used when synthesizing built-in providers.
    public var config: ModelProviderConfig

    /// Creates one canonical provider catalog entry.
    public init(
        providerID: String,
        displayName: String,
        aliases: [String] = [],
        capabilities: [ProviderCapability] = [.text],
        config: ModelProviderConfig
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.aliases = aliases
        self.capabilities = capabilities.isEmpty ? [.text] : capabilities
        self.config = config
    }
}

/// Metadata for upstream provider plugins that are represented without native Swift runtime wiring.
public struct ProviderPluginMetadataEntry: Sendable, Equatable {
    /// Stable upstream provider or plugin identifier.
    public var providerID: String
    /// Human-facing label from the upstream plugin catalog.
    public var displayName: String
    /// Optional upstream documentation path.
    public var docsPath: String?
    /// Capability groups covered by this metadata entry.
    public var capabilities: [ProviderCapability]
    /// Whether OpenClawKit currently has a native runtime adapter for this provider.
    public var nativeRuntimeAvailable: Bool

    /// Creates one metadata entry for a provider-like upstream plugin.
    public init(
        providerID: String,
        displayName: String,
        docsPath: String? = nil,
        capabilities: [ProviderCapability],
        nativeRuntimeAvailable: Bool = false
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.docsPath = docsPath
        self.capabilities = capabilities
        self.nativeRuntimeAvailable = nativeRuntimeAvailable
    }
}

/// Shared provider catalog aligned with the pinned OpenClaw TS reference.
public enum OpenClawReferenceProviderCatalog {
    /// Upstream OpenClaw commit used to derive the built-in provider list.
    public static let referenceCommit = "6b0c72bec8"

    /// Canonical built-in provider entries exposed by the SDK.
    public static let entries: [ProviderCatalogEntry] = [
        entry("openai", "OpenAI", api: .openAIResponses, auth: .apiKey, baseURL: "https://api.openai.com/v1", modelID: "gpt-4.1-mini"),
        entry("openai-compatible", "OpenAI Compatible", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.openai.com/v1", modelID: "gpt-4.1-mini"),
        entry("anthropic", "Anthropic", api: .anthropicMessages, auth: .apiKey, baseURL: "https://api.anthropic.com/v1", modelID: "claude-3-5-haiku-latest"),
        entry("gemini", "Google Gemini", api: .googleGenerativeAI, auth: .apiKey, baseURL: "https://generativelanguage.googleapis.com/v1beta", modelID: "gemini-2.0-flash", inputs: [.text, .image]),
        entry("foundation", "Apple Foundation Models", api: .openAICompletions, auth: nil, baseURL: "foundation://system", modelID: "apple-foundation-default"),
        entry("local", "Local", api: .ollama, auth: nil, baseURL: "local://runtime", modelID: "local-default"),
        entry("xai", "xAI", aliases: ["grok"], api: .openAICompletions, auth: .apiKey, baseURL: "https://api.x.ai/v1", modelID: "grok-3-mini"),
        entry("openrouter", "OpenRouter", api: .openAICompletions, auth: .apiKey, baseURL: "https://openrouter.ai/api/v1", modelID: "auto", inputs: [.text, .image]),
        entry("groq", "Groq", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.groq.com/openai/v1", modelID: "llama-3.3-70b-versatile"),
        entry("mistral", "Mistral", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.mistral.ai/v1", modelID: "mistral-large-latest"),
        entry("cerebras", "Cerebras", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.cerebras.ai/v1", modelID: "zai-glm-4.7"),
        entry("moonshot", "Moonshot", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.moonshot.ai/v1", modelID: "kimi-k2.5"),
        entry("litellm", "LiteLLM", api: .openAICompletions, auth: nil, baseURL: "http://127.0.0.1:4000/v1", modelID: "gpt-4.1-mini"),
        entry("together", "Together AI", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.together.xyz/v1", modelID: "meta-llama/Llama-3.3-70B-Instruct-Turbo"),
        entry("huggingface", "Hugging Face", api: .openAICompletions, auth: .apiKey, baseURL: "https://router.huggingface.co/v1", modelID: "deepseek-ai/DeepSeek-R1"),
        entry("qianfan", "Qianfan", api: .openAICompletions, auth: .apiKey, baseURL: "https://qianfan.baidubce.com/v2", modelID: "deepseek-v3.2"),
        entry("nvidia", "NVIDIA", api: .openAICompletions, auth: .apiKey, baseURL: "https://integrate.api.nvidia.com/v1", modelID: "nvidia/llama-3.1-nemotron-70b-instruct"),
        entry("zai", "Z.AI", aliases: ["z.ai", "z-ai"], api: .openAICompletions, auth: .apiKey, baseURL: "https://api.z.ai/api/paas/v4", modelID: "glm-4.7"),
        entry("minimax", "MiniMax", api: .anthropicMessages, auth: .apiKey, baseURL: "https://api.minimax.io/anthropic", modelID: "MiniMax-M2.5"),
        entry("minimax-portal", "MiniMax Portal", api: .anthropicMessages, auth: .oauth, baseURL: "https://api.minimax.io/anthropic", modelID: "MiniMax-M2.5"),
        entry("synthetic", "Synthetic", api: .anthropicMessages, auth: .apiKey, baseURL: "https://api.synthetic.new/anthropic", modelID: "hf:MiniMaxAI/MiniMax-M2.1"),
        entry("xiaomi", "Xiaomi", api: .anthropicMessages, auth: .apiKey, baseURL: "https://api.xiaomimimo.com/anthropic", modelID: "mimo-v2-flash"),
        entry("cloudflare-ai-gateway", "Cloudflare AI Gateway", api: .anthropicMessages, auth: .apiKey, baseURL: "https://gateway.ai.cloudflare.com/v1", modelID: "claude-3-5-sonnet-latest"),
        entry("vercel-ai-gateway", "Vercel AI Gateway", api: .anthropicMessages, auth: .apiKey, baseURL: "https://ai-gateway.vercel.sh/v1", modelID: "anthropic/claude-opus-4.6"),
        entry("amazon-bedrock", "Amazon Bedrock", api: .bedrockConverseStream, auth: .awsSDK, baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com", modelID: "anthropic.claude-3-5-sonnet"),
        entry("github-copilot", "GitHub Copilot", api: .githubCopilot, auth: .token, baseURL: "https://api.githubcopilot.com", modelID: "gpt-5"),
        entry("ollama", "Ollama", api: .ollama, auth: nil, baseURL: "http://127.0.0.1:11434/v1", modelID: "llama3.3"),
        entry("vllm", "vLLM", api: .openAICompletions, auth: nil, baseURL: "http://127.0.0.1:8000/v1", modelID: "qwen2.5-coder-32b-instruct"),
        entry("sglang", "SGLang", api: .openAICompletions, auth: .apiKey, baseURL: "http://127.0.0.1:30000/v1", modelID: "Qwen/Qwen3-8B"),
        entry("qwen-portal", "Qwen Portal", api: .openAICompletions, auth: .oauth, baseURL: "https://portal.qwen.ai/v1", modelID: "coder-model"),
        entry("openai-codex", "OpenAI Codex", api: .openAICodexResponses, auth: .oauth, baseURL: "https://chatgpt.com/backend-api", modelID: "gpt-5.5"),
        entry("opencode", "OpenCode Zen", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.opencode.ai/v1", modelID: "claude-opus-4-6"),
        entry("opencode-go", "OpenCode Go", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.opencode.ai/v1", modelID: "kimi-k2.5"),
        entry("anthropic-vertex", "Anthropic Vertex", api: .anthropicMessages, auth: .apiKey, baseURL: "https://aiplatform.googleapis.com", modelID: "claude-sonnet-4-6", inputs: [.text, .image], reasoning: true),
        entry("amazon-bedrock-mantle", "Amazon Bedrock Mantle", api: .openAICompletions, auth: .apiKey, baseURL: "https://bedrock-mantle.us-east-1.api.aws/v1", modelID: "openai.gpt-oss-120b", reasoning: true),
        entry("arcee", "Arcee AI", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.arcee.ai/api/v1", modelID: "trinity-large-thinking", reasoning: true),
        entry("chutes", "Chutes", api: .openAICompletions, auth: .apiKey, baseURL: "https://llm.chutes.ai/v1", modelID: "zai-org/GLM-4.7-TEE", reasoning: true),
        entry("copilot-proxy", "Copilot Proxy", api: .openAICompletions, auth: nil, baseURL: "http://localhost:3000/v1", modelID: "gpt-5.2", inputs: [.text, .image]),
        entry("deepseek", "DeepSeek", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.deepseek.com", modelID: "deepseek-v4-flash", reasoning: true),
        entry("fireworks", "Fireworks", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.fireworks.ai/inference/v1", modelID: "accounts/fireworks/routers/kimi-k2p5-turbo", inputs: [.text, .image]),
        entry("lmstudio", "LM Studio", capabilities: [.text, .memoryEmbedding], api: .openAICompletions, auth: nil, baseURL: "http://localhost:1234/v1", modelID: "qwen/qwen3.5-9b"),
        entry("microsoft-foundry", "Microsoft Foundry", api: .openAIResponses, auth: .oauth, baseURL: "https://example.services.ai.azure.com/openai/v1", modelID: "gpt-5", inputs: [.text, .image]),
        entry("qwen", "Qwen", api: .openAICompletions, auth: .apiKey, baseURL: "https://coding-intl.dashscope.aliyuncs.com/v1", modelID: "qwen3.5-plus", inputs: [.text, .image]),
        entry("stepfun", "StepFun", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.stepfun.ai/v1", modelID: "step-3.5-flash", reasoning: true),
        entry("stepfun-plan", "StepFun Plan", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.stepfun.ai/step_plan/v1", modelID: "step-3.5-flash", reasoning: true),
        entry("tencent-tokenhub", "Tencent TokenHub", aliases: ["tencent"], api: .openAICompletions, auth: .apiKey, baseURL: "https://tokenhub.tencentmaas.com/v1", modelID: "hy3-preview", reasoning: true),
        entry(
            "google-vertex",
            "Google Vertex",
            api: .googleGenerativeAI,
            auth: .oauth,
            baseURL: "https://us-central1-aiplatform.googleapis.com",
            modelID: "gemini-3-pro-preview",
            inputs: [.text, .image]
        ),
        entry(
            "google-antigravity",
            "Google Antigravity",
            api: .googleGenerativeAI,
            auth: .oauth,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            modelID: "gemini-3-pro-preview",
            inputs: [.text, .image]
        ),
        entry(
            "google-gemini-cli",
            "Google Gemini CLI",
            api: .googleGenerativeAI,
            auth: .oauth,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            modelID: "gemini-3-flash-preview",
            inputs: [.text, .image]
        ),
        entry("kilocode", "KiloCode", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.kilo.ai/api/gateway/", modelID: "kilo/auto", inputs: [.text, .image], reasoning: true),
        entry("kimi-coding", "Kimi Coding", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.kimi.com/coding/", modelID: "k2p5"),
        entry("venice", "Venice", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.venice.ai/api/v1", modelID: "kimi-k2-5", inputs: [.text, .image], reasoning: true),
        entry("modelstudio", "Model Studio", api: .openAICompletions, auth: .apiKey, baseURL: "https://coding-intl.dashscope.aliyuncs.com/v1", modelID: "qwen3.5-plus", inputs: [.text, .image]),
        entry("volcengine", "Volcengine", api: .openAICompletions, auth: .apiKey, baseURL: "https://ark.cn-beijing.volces.com/api/v3", modelID: "doubao-seed-1-8-251228", inputs: [.text, .image]),
        entry("volcengine-plan", "Volcengine Plan", api: .openAICompletions, auth: .apiKey, baseURL: "https://ark.cn-beijing.volces.com/api/coding/v3", modelID: "ark-code-latest"),
        entry("byteplus", "BytePlus", api: .openAICompletions, auth: .apiKey, baseURL: "https://ark.ap-southeast.bytepluses.com/api/v3", modelID: "seed-1-8-251228", inputs: [.text, .image]),
        entry("byteplus-plan", "BytePlus Plan", api: .openAICompletions, auth: .apiKey, baseURL: "https://ark.ap-southeast.bytepluses.com/api/coding/v3", modelID: "ark-code-latest"),
    ]

    /// Upstream provider-plugin metadata that is config-visible but not a native Swift text provider.
    public static let providerMetadataEntries: [ProviderPluginMetadataEntry] = [
        metadata("alibaba", "Alibaba", docsPath: "/providers/alibaba", capabilities: [.videoGeneration]),
        metadata("brave", "Brave Search", docsPath: "/providers/brave", capabilities: [.webSearch]),
        metadata("comfy", "Comfy", docsPath: "/providers/comfy", capabilities: [.imageGeneration, .videoGeneration, .musicGeneration]),
        metadata("deepgram", "Deepgram", docsPath: "/providers/deepgram", capabilities: [.mediaUnderstanding, .realtimeTranscription]),
        metadata("duckduckgo", "DuckDuckGo", docsPath: "/providers/duckduckgo", capabilities: [.webSearch]),
        metadata("elevenlabs", "ElevenLabs", docsPath: "/providers/elevenlabs", capabilities: [.speech, .realtimeTranscription]),
        metadata("exa", "Exa", docsPath: "/providers/exa", capabilities: [.webSearch]),
        metadata("fal", "fal.ai", docsPath: "/providers/fal", capabilities: [.imageGeneration, .videoGeneration]),
        metadata("firecrawl", "Firecrawl", docsPath: "/providers/firecrawl", capabilities: [.webSearch]),
        metadata("gradium", "Gradium", docsPath: "/providers/gradium", capabilities: [.speech]),
        metadata("inworld", "Inworld", docsPath: "/providers/inworld", capabilities: [.speech]),
        metadata("perplexity", "Perplexity", docsPath: "/providers/perplexity", capabilities: [.webSearch]),
        metadata("runway", "Runway", docsPath: "/providers/runway", capabilities: [.videoGeneration]),
        metadata("searxng", "SearXNG", docsPath: "/providers/searxng", capabilities: [.webSearch]),
        metadata("senseaudio", "SenseAudio", docsPath: "/providers/senseaudio", capabilities: [.mediaUnderstanding]),
        metadata("tavily", "Tavily", docsPath: "/providers/tavily", capabilities: [.webSearch]),
        metadata("tts-local-cli", "TTS Local CLI", docsPath: "/providers/tts-local-cli", capabilities: [.speech]),
        metadata("voyage", "Voyage", docsPath: "/providers/voyage", capabilities: [.memoryEmbedding]),
        metadata("vydra", "Vydra", docsPath: "/providers/vydra", capabilities: [.imageGeneration, .videoGeneration, .speech]),
    ]

    /// Normalizes a provider identifier or alias into the canonical built-in provider ID.
    public static func normalize(providerID: String) -> String {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if entries.contains(where: { $0.providerID == normalized }) {
            return normalized
        }
        if let matched = entries.first(where: { $0.aliases.contains(normalized) }) {
            return matched.providerID
        }
        if normalized.hasPrefix("google/") {
            return "gemini"
        }
        return normalized
    }

    /// Returns the built-in catalog entry for a provider identifier or alias.
    public static func entry(for providerID: String) -> ProviderCatalogEntry? {
        let normalized = normalize(providerID: providerID)
        return entries.first(where: { $0.providerID == normalized })
    }

    /// Returns built-in provider configs keyed by their canonical identifier.
    public static func providerConfigsByID() -> [String: ModelProviderConfig] {
        entries.reduce(into: [:]) { partial, entry in
            partial[entry.providerID] = entry.config
        }
    }

    private static func entry(
        _ providerID: String,
        _ displayName: String,
        aliases: [String] = [],
        capabilities: [ProviderCapability] = [.text],
        api: ModelAPI,
        auth: ModelProviderAuthMode?,
        baseURL: String,
        modelID: String,
        inputs: [ModelInputType] = [.text],
        reasoning: Bool = false
    ) -> ProviderCatalogEntry {
        ProviderCatalogEntry(
            providerID: providerID,
            displayName: displayName,
            aliases: aliases,
            capabilities: capabilities,
            config: ModelProviderConfig(
                enabled: false,
                baseURL: baseURL,
                auth: auth,
                api: api,
                models: [
                    ModelDefinitionConfig(
                        id: modelID,
                        api: api,
                        reasoning: reasoning,
                        input: inputs
                    ),
                ]
            )
        )
    }

    private static func metadata(
        _ providerID: String,
        _ displayName: String,
        docsPath: String? = nil,
        capabilities: [ProviderCapability]
    ) -> ProviderPluginMetadataEntry {
        ProviderPluginMetadataEntry(
            providerID: providerID,
            displayName: displayName,
            docsPath: docsPath,
            capabilities: capabilities
        )
    }
}

/// Factory for constructing runtime providers from canonical provider catalog configs.
public enum ModelProviderFactory {
    /// Instantiates a model provider implementation for the given provider ID and config.
    public static func makeProvider(
        providerID: String,
        config: ModelProviderConfig
    ) throws -> any ModelProvider {
        let normalizedProviderID = OpenClawReferenceProviderCatalog.normalize(providerID: providerID)
        let legacy = config.legacyServiceConfig(providerID: normalizedProviderID)
        switch normalizedProviderID {
        case OpenAIModelProvider.providerID:
            return OpenAIModelProvider(
                configuration: OpenAIModelConfig(
                    enabled: config.enabled,
                    modelID: config.defaultModel?.id ?? "gpt-4.1-mini",
                    apiKey: config.apiKey,
                    baseURL: config.baseURL
                )
            )
        case OpenAICompatibleModelProvider.providerID:
            return OpenAICompatibleModelProvider(
                configuration: OpenAICompatibleModelConfig(
                    enabled: config.enabled,
                    modelID: config.defaultModel?.id ?? "gpt-4.1-mini",
                    apiKey: config.apiKey,
                    baseURL: config.baseURL,
                    chatCompletionsPath: config.chatCompletionsPath
                )
            )
        case AnthropicModelProvider.providerID:
            return AnthropicModelProvider(
                configuration: AnthropicModelConfig(
                    enabled: config.enabled,
                    modelID: config.defaultModel?.id ?? "claude-3-5-haiku-latest",
                    apiKey: config.apiKey,
                    baseURL: config.baseURL,
                    apiVersion: config.apiVersion ?? "2023-06-01",
                    maxTokens: config.defaultModel?.maxTokens ?? 8_192
                )
            )
        case GeminiModelProvider.providerID, "google-vertex", "google-antigravity", "google-gemini-cli":
            return GoogleGenerativeAIModelProvider(id: normalizedProviderID, configuration: legacy)
        case FoundationModelsProvider.providerID:
            return FoundationModelsProvider()
        case LocalModelProvider.providerID:
            return LocalModelProvider(
                configuration: LocalModelConfig(
                    enabled: config.enabled,
                    runtime: "llmfarm",
                    modelPath: nil
                ),
                engine: StubLocalModelEngine()
            )
        case XAIModelProvider.providerID, XAIModelProvider.grokAliasProviderID:
            return XAIModelProvider(id: normalizedProviderID, configuration: legacy)
        case MinimaxModelProvider.providerID:
            return MinimaxModelProvider(configuration: legacy)
        case MinimaxPortalModelProvider.providerID:
            return MinimaxPortalModelProvider(configuration: legacy)
        case SyntheticModelProvider.providerID:
            return SyntheticModelProvider(configuration: legacy)
        case XiaomiModelProvider.providerID:
            return XiaomiModelProvider(configuration: legacy)
        case CloudflareAIGatewayModelProvider.providerID:
            return CloudflareAIGatewayModelProvider(configuration: legacy)
        case VercelAIGatewayModelProvider.providerID:
            return VercelAIGatewayModelProvider(configuration: legacy)
        case BedrockConverseModelProvider.providerID:
            return BedrockConverseModelProvider(configuration: legacy)
        case GitHubCopilotModelProvider.providerID:
            return GitHubCopilotModelProvider(configuration: legacy)
        case OllamaModelProvider.providerID:
            return OllamaModelProvider(configuration: legacy)
        case VLLMModelProvider.providerID:
            return VLLMModelProvider(configuration: legacy)
        case QwenPortalModelProvider.providerID:
            return QwenPortalModelProvider(configuration: legacy)
        case OpenRouterModelProvider.providerID:
            return OpenRouterModelProvider(configuration: legacy)
        case GroqModelProvider.providerID:
            return GroqModelProvider(configuration: legacy)
        case MistralModelProvider.providerID:
            return MistralModelProvider(configuration: legacy)
        case CerebrasModelProvider.providerID:
            return CerebrasModelProvider(configuration: legacy)
        case MoonshotModelProvider.providerID:
            return MoonshotModelProvider(configuration: legacy)
        case LiteLLMModelProvider.providerID:
            return LiteLLMModelProvider(configuration: legacy)
        case TogetherModelProvider.providerID:
            return TogetherModelProvider(configuration: legacy)
        case HuggingFaceModelProvider.providerID:
            return HuggingFaceModelProvider(configuration: legacy)
        case QianfanModelProvider.providerID:
            return QianfanModelProvider(configuration: legacy)
        case NVIDIAModelProvider.providerID:
            return NVIDIAModelProvider(configuration: legacy)
        case ZAIModelProvider.providerID:
            return ZAIModelProvider(configuration: legacy)
        default:
            switch config.api ?? .openAICompletions {
            case .anthropicMessages:
                return ProviderServiceAnthropicModelProvider(id: normalizedProviderID, configuration: legacy)
            case .bedrockConverseStream:
                return BedrockConverseModelProvider(id: normalizedProviderID, configuration: legacy)
            case .githubCopilot:
                return GitHubCopilotModelProvider(id: normalizedProviderID, configuration: legacy)
            case .googleGenerativeAI:
                return GoogleGenerativeAIModelProvider(id: normalizedProviderID, configuration: legacy)
            case .openAIResponses, .openAICodexResponses:
                return OpenAIResponsesModelProvider(id: normalizedProviderID, configuration: legacy)
            case .ollama:
                return OllamaModelProvider(id: normalizedProviderID, configuration: legacy)
            case .openAICompletions:
                return ProviderServiceOpenAIModelProvider(id: normalizedProviderID, configuration: legacy)
            }
        }
    }
}
