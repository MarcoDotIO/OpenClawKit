import OpenClawCore
import OpenClawModels

struct ProviderCatalogSnapshotEntry: Sendable, Equatable {
    let providerID: String
    let auth: ModelProviderAuthMode?
    let api: ModelAPI
    let baseURL: String
    let defaultModelID: String
    let capabilities: [ProviderCapability]

    init(
        providerID: String,
        auth: ModelProviderAuthMode?,
        api: ModelAPI,
        baseURL: String,
        defaultModelID: String,
        capabilities: [ProviderCapability] = [.text]
    ) {
        self.providerID = providerID
        self.auth = auth
        self.api = api
        self.baseURL = baseURL
        self.defaultModelID = defaultModelID
        self.capabilities = capabilities
    }
}

/// Snapshot of the provider catalog at OpenClaw 2026.9.6 (eb377ac59e).
///
/// Regenerating `ProviderCatalogData.swift` must keep this fixture in sync; review every diff against upstream.
enum ProviderCatalogReferenceFixture {
    static let referenceCommit = "eb377ac59e"

    static let entries: [ProviderCatalogSnapshotEntry] = [
        .init(
            providerID: "openai",
            auth: .apiKey,
            api: .openAIResponses,
            baseURL: "https://api.openai.com/v1",
            defaultModelID: "gpt-6-astra",
            capabilities: [
                .text,
                .imageGeneration,
                .videoGeneration,
                .speech,
                .realtimeVoice,
                .realtimeTranscription,
                .mediaUnderstanding,
                .embedding,
                .usage,
            ]
        ),
        .init(
            providerID: "openai-compatible",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.openai.com/v1",
            defaultModelID: "gpt-5.4-mini",
            capabilities: [.text, .embedding]
        ),
        .init(
            providerID: "anthropic",
            auth: .apiKey,
            api: .anthropicMessages,
            baseURL: "https://api.anthropic.com",
            defaultModelID: "claude-opus-5",
            capabilities: [.text, .mediaUnderstanding, .usage]
        ),
        .init(
            providerID: "google",
            auth: .apiKey,
            api: .googleGenerativeAI,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            defaultModelID: "gemini-3.1-pro-preview",
            capabilities: [
                .text,
                .imageGeneration,
                .videoGeneration,
                .musicGeneration,
                .speech,
                .realtimeVoice,
                .mediaUnderstanding,
                .embedding,
                .webSearch,
            ]
        ),
        .init(
            providerID: "apple-fm",
            auth: nil,
            api: .openAICompletions,
            baseURL: "http://127.0.0.1",
            defaultModelID: "system",
            capabilities: [.text]
        ),
        .init(
            providerID: "local",
            auth: nil,
            api: .ollama,
            baseURL: "local://runtime",
            defaultModelID: "local-default",
            capabilities: [.text]
        ),
        .init(
            providerID: "xai",
            auth: .apiKey,
            api: .openAIResponses,
            baseURL: "https://api.x.ai/v1",
            defaultModelID: "grok-4.7",
            capabilities: [
                .text,
                .imageGeneration,
                .videoGeneration,
                .speech,
                .realtimeVoice,
                .realtimeTranscription,
                .mediaUnderstanding,
                .webSearch,
                .usage,
                .tool,
            ]
        ),
        .init(
            providerID: "openrouter",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://openrouter.ai/api/v1",
            defaultModelID: "openrouter/auto",
            capabilities: [.text, .imageGeneration, .videoGeneration, .musicGeneration, .speech, .mediaUnderstanding, .usage]
        ),
        .init(
            providerID: "groq",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.groq.com/openai/v1",
            defaultModelID: "openai/gpt-oss-120b",
            capabilities: [.text, .mediaUnderstanding]
        ),
        .init(
            providerID: "mistral",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.mistral.ai/v1",
            defaultModelID: "mistral-large-latest",
            capabilities: [.text, .realtimeTranscription, .mediaUnderstanding, .embedding]
        ),
        .init(
            providerID: "cerebras",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.cerebras.ai/v1",
            defaultModelID: "gemma-4-31b",
            capabilities: [.text]
        ),
        .init(
            providerID: "moonshot",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.moonshot.ai/v1",
            defaultModelID: "kimi-k3",
            capabilities: [.text, .mediaUnderstanding, .webSearch]
        ),
        .init(
            providerID: "litellm",
            auth: nil,
            api: .openAICompletions,
            baseURL: "http://localhost:4000",
            defaultModelID: "claude-opus-4-6",
            capabilities: [.text, .imageGeneration]
        ),
        .init(
            providerID: "together",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.together.xyz/v1",
            defaultModelID: "moonshotai/Kimi-K2.6",
            capabilities: [.text, .videoGeneration]
        ),
        .init(
            providerID: "huggingface",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://router.huggingface.co/v1",
            defaultModelID: "deepseek-ai/DeepSeek-R1",
            capabilities: [.text]
        ),
        .init(
            providerID: "qianfan",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://qianfan.baidubce.com/v2",
            defaultModelID: "deepseek-v4-pro",
            capabilities: [.text]
        ),
        .init(
            providerID: "nvidia",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://integrate.api.nvidia.com/v1",
            defaultModelID: "nvidia/nemotron-3-ultra-550b-a55b",
            capabilities: [.text]
        ),
        .init(
            providerID: "zai",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.z.ai/api/paas/v4",
            defaultModelID: "glm-5.2",
            capabilities: [.text, .mediaUnderstanding, .usage]
        ),
        .init(
            providerID: "minimax",
            auth: .apiKey,
            api: .anthropicMessages,
            baseURL: "https://api.minimax.io/anthropic",
            defaultModelID: "MiniMax-M3",
            capabilities: [.text, .imageGeneration, .videoGeneration, .musicGeneration, .speech, .mediaUnderstanding, .webSearch, .usage]
        ),
        .init(
            providerID: "minimax-portal",
            auth: .oauth,
            api: .anthropicMessages,
            baseURL: "https://api.minimax.io/anthropic",
            defaultModelID: "MiniMax-M3",
            capabilities: [.text, .imageGeneration, .videoGeneration, .musicGeneration, .mediaUnderstanding]
        ),
        .init(
            providerID: "synthetic",
            auth: .apiKey,
            api: .anthropicMessages,
            baseURL: "https://api.synthetic.new/anthropic",
            defaultModelID: "hf:MiniMaxAI/MiniMax-M3",
            capabilities: [.text]
        ),
        .init(
            providerID: "xiaomi",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.xiaomimimo.com/v1",
            defaultModelID: "mimo-v2.6-pro",
            capabilities: [.text, .speech, .usage]
        ),
        .init(
            providerID: "cloudflare-ai-gateway",
            auth: .apiKey,
            api: .anthropicMessages,
            baseURL: "https://gateway.ai.cloudflare.com/v1/{accountId}/{gatewayId}/anthropic",
            defaultModelID: "claude-sonnet-4-6",
            capabilities: [.text]
        ),
        .init(
            providerID: "vercel-ai-gateway",
            auth: .apiKey,
            api: .anthropicMessages,
            baseURL: "https://ai-gateway.vercel.sh",
            defaultModelID: "anthropic/claude-opus-4.6",
            capabilities: [.text]
        ),
        .init(
            providerID: "amazon-bedrock",
            auth: .awsSDK,
            api: .bedrockConverseStream,
            baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
            defaultModelID: "anthropic.claude-opus-5",
            capabilities: [.text, .embedding]
        ),
        .init(
            providerID: "github-copilot",
            auth: .token,
            api: .anthropicMessages,
            baseURL: "https://api.individual.githubcopilot.com",
            defaultModelID: "claude-sonnet-5",
            capabilities: [.text, .embedding, .usage]
        ),
        .init(
            providerID: "ollama",
            auth: nil,
            api: .ollama,
            baseURL: "http://127.0.0.1:11434",
            defaultModelID: "gemma4",
            capabilities: [.text, .embedding, .webSearch, .tool]
        ),
        .init(
            providerID: "vllm",
            auth: nil,
            api: .openAICompletions,
            baseURL: "http://127.0.0.1:8000/v1",
            defaultModelID: "qwen2.5-coder-32b-instruct",
            capabilities: [.text]
        ),
        .init(
            providerID: "sglang",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "http://127.0.0.1:30000/v1",
            defaultModelID: "Qwen/Qwen3-8B",
            capabilities: [.text]
        ),
        .init(
            providerID: "qwen-portal",
            auth: .oauth,
            api: .openAICompletions,
            baseURL: "https://portal.qwen.ai/v1",
            defaultModelID: "coder-model",
            capabilities: [.text]
        ),
        .init(
            providerID: "opencode",
            auth: .apiKey,
            api: .anthropicMessages,
            baseURL: "https://opencode.ai/zen/v1",
            defaultModelID: "claude-opus-5",
            capabilities: [.text, .mediaUnderstanding]
        ),
        .init(
            providerID: "opencode-go",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://opencode.ai/zen/go/v1",
            defaultModelID: "deepseek-v4-pro",
            capabilities: [.text, .mediaUnderstanding]
        ),
        .init(
            providerID: "anthropic-vertex",
            auth: .apiKey,
            api: .anthropicMessages,
            baseURL: "https://aiplatform.googleapis.com",
            defaultModelID: "claude-sonnet-4-6",
            capabilities: [.text]
        ),
        .init(
            providerID: "amazon-bedrock-mantle",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://bedrock-mantle.{region}.api.aws/v1",
            defaultModelID: "openai.gpt-oss-120b",
            capabilities: [.text]
        ),
        .init(
            providerID: "arcee",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.arcee.ai/api/v1",
            defaultModelID: "trinity-large-thinking",
            capabilities: [.text]
        ),
        .init(
            providerID: "chutes",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://llm.chutes.ai/v1",
            defaultModelID: "zai-org/GLM-5.2-TEE",
            capabilities: [.text]
        ),
        .init(
            providerID: "copilot-proxy",
            auth: nil,
            api: .openAICompletions,
            baseURL: "http://localhost:3000/v1",
            defaultModelID: "gpt-5-mini",
            capabilities: [.text]
        ),
        .init(
            providerID: "deepseek",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.deepseek.com",
            defaultModelID: "deepseek-v4-pro",
            capabilities: [.text, .usage]
        ),
        .init(
            providerID: "fireworks",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.fireworks.ai/inference/v1",
            defaultModelID: "accounts/fireworks/routers/glm-5p2-fast",
            capabilities: [.text]
        ),
        .init(
            providerID: "lmstudio",
            auth: nil,
            api: .openAICompletions,
            baseURL: "http://localhost:1234/v1",
            defaultModelID: "qwen/qwen3.5-9b",
            capabilities: [.text, .embedding]
        ),
        .init(
            providerID: "microsoft-foundry",
            auth: .oauth,
            api: .openAIResponses,
            baseURL: "https://example.services.ai.azure.com/openai/v1",
            defaultModelID: "gpt-5",
            capabilities: [.text, .imageGeneration]
        ),
        .init(
            providerID: "qwen",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://coding-intl.dashscope.aliyuncs.com/v1",
            defaultModelID: "qwen3.5-plus",
            capabilities: [.text, .videoGeneration, .mediaUnderstanding]
        ),
        .init(
            providerID: "stepfun",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.stepfun.ai/v1",
            defaultModelID: "step-3.5-flash",
            capabilities: [.text]
        ),
        .init(
            providerID: "stepfun-plan",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.stepfun.ai/step_plan/v1",
            defaultModelID: "step-3.5-flash",
            capabilities: [.text]
        ),
        .init(
            providerID: "tencent-tokenhub",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://tokenhub.tencentmaas.com/v1",
            defaultModelID: "hy4-preview",
            capabilities: [.text]
        ),
        .init(
            providerID: "google-vertex",
            auth: .apiKey,
            api: .googleVertex,
            baseURL: "https://{location}-aiplatform.googleapis.com",
            defaultModelID: "gemini-3.1-pro-preview",
            capabilities: [.text]
        ),
        .init(
            providerID: "google-antigravity",
            auth: .oauth,
            api: .googleGenerativeAI,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            defaultModelID: "gemini-3.1-pro-preview",
            capabilities: [.text]
        ),
        .init(
            providerID: "google-gemini-cli",
            auth: .oauth,
            api: .googleGenerativeAI,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            defaultModelID: "gemini-3-flash-preview",
            capabilities: [.text]
        ),
        .init(
            providerID: "kilocode",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.kilo.ai/api/gateway/",
            defaultModelID: "kilo-auto/balanced",
            capabilities: [.text]
        ),
        .init(
            providerID: "kimi",
            auth: .apiKey,
            api: .anthropicMessages,
            baseURL: "https://api.kimi.com/coding/",
            defaultModelID: "kimi-for-coding",
            capabilities: [.text]
        ),
        .init(
            providerID: "venice",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.venice.ai/api/v1",
            defaultModelID: "zai-org-glm-4.7",
            capabilities: [.text, .usage]
        ),
        .init(
            providerID: "volcengine",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            defaultModelID: "doubao-seed-2-1-pro-260628",
            capabilities: [.text, .speech]
        ),
        .init(
            providerID: "volcengine-plan",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://ark.cn-beijing.volces.com/api/coding/v3",
            defaultModelID: "ark-code-latest",
            capabilities: [.text]
        ),
        .init(
            providerID: "byteplus",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://ark.ap-southeast.bytepluses.com/api/v3",
            defaultModelID: "dola-seed-2-1-turbo-260628",
            capabilities: [.text, .videoGeneration]
        ),
        .init(
            providerID: "byteplus-plan",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://ark.ap-southeast.bytepluses.com/api/coding/v3",
            defaultModelID: "ark-code-latest",
            capabilities: [.text]
        ),
        .init(
            providerID: "baseten",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://inference.baseten.co/v1",
            defaultModelID: "thinkingmachines/inkling",
            capabilities: [.text]
        ),
        .init(
            providerID: "clawrouter",
            auth: .apiKey,
            api: .openAIResponses,
            baseURL: "https://clawrouter.openclaw.ai/v1",
            defaultModelID: "",
            capabilities: [.text, .usage]
        ),
        .init(
            providerID: "cohere",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.cohere.ai/compatibility/v1",
            defaultModelID: "command-a-plus-05-2026",
            capabilities: [.text]
        ),
        .init(
            providerID: "deepinfra",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.deepinfra.com/v1/openai",
            defaultModelID: "deepseek-ai/DeepSeek-V4-Flash",
            capabilities: [.text, .imageGeneration, .videoGeneration, .speech, .mediaUnderstanding, .embedding]
        ),
        .init(
            providerID: "featherless",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.featherless.ai/v1",
            defaultModelID: "Qwen/Qwen3-32B",
            capabilities: [.text]
        ),
        .init(
            providerID: "gmi",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.gmi-serving.com/v1",
            defaultModelID: "openai/gpt-5.6-sol",
            capabilities: [.text]
        ),
        .init(
            providerID: "llama-cpp",
            auth: nil,
            api: .openAICompletions,
            baseURL: "http://127.0.0.1:19432/v1",
            defaultModelID: "gemma-4-e4b-it-q4_k_m",
            capabilities: [.text, .embedding]
        ),
        .init(
            providerID: "longcat",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.longcat.chat/openai",
            defaultModelID: "LongCat-2.0",
            capabilities: [.text]
        ),
        .init(
            providerID: "meta",
            auth: .apiKey,
            api: .openAIResponses,
            baseURL: "https://api.meta.ai/v1",
            defaultModelID: "muse-spark-1.3",
            capabilities: [.text]
        ),
        .init(
            providerID: "novita",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.novita.ai/openai/v1",
            defaultModelID: "deepseek/deepseek-v4-pro",
            capabilities: [.text]
        ),
        .init(
            providerID: "ollama-cloud",
            auth: .apiKey,
            api: .ollama,
            baseURL: "https://ollama.com",
            defaultModelID: "minimax-m2.7",
            capabilities: [.text]
        ),
        .init(
            providerID: "qwen-token-plan",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
            defaultModelID: "qwen3.7-plus",
            capabilities: [.text]
        ),
        .init(
            providerID: "tencent-tokenplan",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://api.lkeap.cloud.tencent.com/plan/v3",
            defaultModelID: "hy4-preview",
            capabilities: [.text]
        ),
        .init(
            providerID: "xiaomi-token-plan",
            auth: .apiKey,
            api: .openAICompletions,
            baseURL: "https://token-plan-sgp.xiaomimimo.com/v1",
            defaultModelID: "mimo-v2.6-pro",
            capabilities: [.text, .usage]
        ),
        .init(
            providerID: "radius",
            auth: .apiKey,
            api: .piMessages,
            baseURL: "https://radius.pi.dev/v1",
            defaultModelID: "",
            capabilities: [.text]
        ),
    ]
}
