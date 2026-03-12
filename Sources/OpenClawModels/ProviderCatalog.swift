import Foundation
import OpenClawCore

/// Canonical provider entry derived from the pinned OpenClaw TS reference snapshot.
public struct ProviderCatalogEntry: Sendable, Equatable {
    public var providerID: String
    public var displayName: String
    public var aliases: [String]
    public var config: ModelProviderConfig

    public init(
        providerID: String,
        displayName: String,
        aliases: [String] = [],
        config: ModelProviderConfig
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.aliases = aliases
        self.config = config
    }
}

/// Shared provider catalog aligned with the pinned OpenClaw TS reference.
public enum OpenClawReferenceProviderCatalog {
    public static let referenceCommit = "8cc0c9baf2ffce3da3402c0fb1309cc31a7343e6"

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
        entry("qwen-portal", "Qwen Portal", api: .openAICompletions, auth: .oauth, baseURL: "https://portal.qwen.ai/v1", modelID: "coder-model"),
        entry("openai-codex", "OpenAI Codex", api: .openAICodexResponses, auth: .oauth, baseURL: "https://chatgpt.com/backend-api", modelID: "gpt-5.4"),
        entry("opencode", "OpenCode Zen", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.opencode.ai/v1", modelID: "claude-opus-4-6"),
        entry("opencode-go", "OpenCode Go", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.opencode.ai/v1", modelID: "kimi-k2.5"),
        entry("google-vertex", "Google Vertex", api: .googleGenerativeAI, auth: .oauth, baseURL: "https://us-central1-aiplatform.googleapis.com", modelID: "gemini-3-pro-preview", inputs: [.text, .image]),
        entry("google-antigravity", "Google Antigravity", api: .googleGenerativeAI, auth: .oauth, baseURL: "https://generativelanguage.googleapis.com/v1beta", modelID: "gemini-3-pro-preview", inputs: [.text, .image]),
        entry("google-gemini-cli", "Google Gemini CLI", api: .googleGenerativeAI, auth: .oauth, baseURL: "https://generativelanguage.googleapis.com/v1beta", modelID: "gemini-3-flash-preview", inputs: [.text, .image]),
        entry("kilocode", "KiloCode", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.kilo.ai/api/gateway/", modelID: "kilo/auto", inputs: [.text, .image], reasoning: true),
        entry("kimi-coding", "Kimi Coding", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.kimi.com/coding/", modelID: "k2p5"),
        entry("venice", "Venice", api: .openAICompletions, auth: .apiKey, baseURL: "https://api.venice.ai/api/v1", modelID: "kimi-k2-5", inputs: [.text, .image], reasoning: true),
        entry("modelstudio", "Model Studio", api: .openAICompletions, auth: .apiKey, baseURL: "https://coding-intl.dashscope.aliyuncs.com/v1", modelID: "qwen3.5-plus", inputs: [.text, .image]),
        entry("volcengine", "Volcengine", api: .openAICompletions, auth: .apiKey, baseURL: "https://ark.cn-beijing.volces.com/api/v3", modelID: "doubao-seed-1-8-251228", inputs: [.text, .image]),
        entry("volcengine-plan", "Volcengine Plan", api: .openAICompletions, auth: .apiKey, baseURL: "https://ark.cn-beijing.volces.com/api/coding/v3", modelID: "ark-code-latest"),
        entry("byteplus", "BytePlus", api: .openAICompletions, auth: .apiKey, baseURL: "https://ark.ap-southeast.bytepluses.com/api/v3", modelID: "seed-1-8-251228", inputs: [.text, .image]),
        entry("byteplus-plan", "BytePlus Plan", api: .openAICompletions, auth: .apiKey, baseURL: "https://ark.ap-southeast.bytepluses.com/api/coding/v3", modelID: "ark-code-latest"),
    ]

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

    public static func entry(for providerID: String) -> ProviderCatalogEntry? {
        let normalized = normalize(providerID: providerID)
        return entries.first(where: { $0.providerID == normalized })
    }

    public static func providerConfigsByID() -> [String: ModelProviderConfig] {
        entries.reduce(into: [:]) { partial, entry in
            partial[entry.providerID] = entry.config
        }
    }

    private static func entry(
        _ providerID: String,
        _ displayName: String,
        aliases: [String] = [],
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
}

/// Factory for constructing runtime providers from canonical provider catalog configs.
public enum ModelProviderFactory {
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
