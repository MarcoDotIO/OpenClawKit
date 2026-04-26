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

enum ProviderCatalogReferenceFixture {
    static let referenceCommit = "6b0c72bec8"

    static let entries: [ProviderCatalogSnapshotEntry] = [
        .init(providerID: "openai", auth: .apiKey, api: .openAIResponses, baseURL: "https://api.openai.com/v1", defaultModelID: "gpt-4.1-mini"),
        .init(providerID: "openai-compatible", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.openai.com/v1", defaultModelID: "gpt-4.1-mini"),
        .init(providerID: "anthropic", auth: .apiKey, api: .anthropicMessages, baseURL: "https://api.anthropic.com/v1", defaultModelID: "claude-3-5-haiku-latest"),
        .init(providerID: "gemini", auth: .apiKey, api: .googleGenerativeAI, baseURL: "https://generativelanguage.googleapis.com/v1beta", defaultModelID: "gemini-2.0-flash"),
        .init(providerID: "foundation", auth: nil, api: .openAICompletions, baseURL: "foundation://system", defaultModelID: "apple-foundation-default"),
        .init(providerID: "local", auth: nil, api: .ollama, baseURL: "local://runtime", defaultModelID: "local-default"),
        .init(providerID: "xai", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.x.ai/v1", defaultModelID: "grok-3-mini"),
        .init(providerID: "openrouter", auth: .apiKey, api: .openAICompletions, baseURL: "https://openrouter.ai/api/v1", defaultModelID: "auto"),
        .init(providerID: "groq", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.groq.com/openai/v1", defaultModelID: "llama-3.3-70b-versatile"),
        .init(providerID: "mistral", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.mistral.ai/v1", defaultModelID: "mistral-large-latest"),
        .init(providerID: "cerebras", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.cerebras.ai/v1", defaultModelID: "zai-glm-4.7"),
        .init(providerID: "moonshot", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.moonshot.ai/v1", defaultModelID: "kimi-k2.5"),
        .init(providerID: "litellm", auth: nil, api: .openAICompletions, baseURL: "http://127.0.0.1:4000/v1", defaultModelID: "gpt-4.1-mini"),
        .init(providerID: "together", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.together.xyz/v1", defaultModelID: "meta-llama/Llama-3.3-70B-Instruct-Turbo"),
        .init(providerID: "huggingface", auth: .apiKey, api: .openAICompletions, baseURL: "https://router.huggingface.co/v1", defaultModelID: "deepseek-ai/DeepSeek-R1"),
        .init(providerID: "qianfan", auth: .apiKey, api: .openAICompletions, baseURL: "https://qianfan.baidubce.com/v2", defaultModelID: "deepseek-v3.2"),
        .init(providerID: "nvidia", auth: .apiKey, api: .openAICompletions, baseURL: "https://integrate.api.nvidia.com/v1", defaultModelID: "nvidia/llama-3.1-nemotron-70b-instruct"),
        .init(providerID: "zai", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.z.ai/api/paas/v4", defaultModelID: "glm-4.7"),
        .init(providerID: "minimax", auth: .apiKey, api: .anthropicMessages, baseURL: "https://api.minimax.io/anthropic", defaultModelID: "MiniMax-M2.5"),
        .init(providerID: "minimax-portal", auth: .oauth, api: .anthropicMessages, baseURL: "https://api.minimax.io/anthropic", defaultModelID: "MiniMax-M2.5"),
        .init(providerID: "synthetic", auth: .apiKey, api: .anthropicMessages, baseURL: "https://api.synthetic.new/anthropic", defaultModelID: "hf:MiniMaxAI/MiniMax-M2.1"),
        .init(providerID: "xiaomi", auth: .apiKey, api: .anthropicMessages, baseURL: "https://api.xiaomimimo.com/anthropic", defaultModelID: "mimo-v2-flash"),
        .init(providerID: "cloudflare-ai-gateway", auth: .apiKey, api: .anthropicMessages, baseURL: "https://gateway.ai.cloudflare.com/v1", defaultModelID: "claude-3-5-sonnet-latest"),
        .init(providerID: "vercel-ai-gateway", auth: .apiKey, api: .anthropicMessages, baseURL: "https://ai-gateway.vercel.sh/v1", defaultModelID: "anthropic/claude-opus-4.6"),
        .init(providerID: "amazon-bedrock", auth: .awsSDK, api: .bedrockConverseStream, baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com", defaultModelID: "anthropic.claude-3-5-sonnet"),
        .init(providerID: "github-copilot", auth: .token, api: .githubCopilot, baseURL: "https://api.githubcopilot.com", defaultModelID: "gpt-5"),
        .init(providerID: "ollama", auth: nil, api: .ollama, baseURL: "http://127.0.0.1:11434/v1", defaultModelID: "llama3.3"),
        .init(providerID: "vllm", auth: nil, api: .openAICompletions, baseURL: "http://127.0.0.1:8000/v1", defaultModelID: "qwen2.5-coder-32b-instruct"),
        .init(providerID: "sglang", auth: .apiKey, api: .openAICompletions, baseURL: "http://127.0.0.1:30000/v1", defaultModelID: "Qwen/Qwen3-8B"),
        .init(providerID: "qwen-portal", auth: .oauth, api: .openAICompletions, baseURL: "https://portal.qwen.ai/v1", defaultModelID: "coder-model"),
        .init(providerID: "openai-codex", auth: .oauth, api: .openAICodexResponses, baseURL: "https://chatgpt.com/backend-api", defaultModelID: "gpt-5.5"),
        .init(providerID: "opencode", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.opencode.ai/v1", defaultModelID: "claude-opus-4-6"),
        .init(providerID: "opencode-go", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.opencode.ai/v1", defaultModelID: "kimi-k2.5"),
        .init(providerID: "anthropic-vertex", auth: .apiKey, api: .anthropicMessages, baseURL: "https://aiplatform.googleapis.com", defaultModelID: "claude-sonnet-4-6"),
        .init(providerID: "amazon-bedrock-mantle", auth: .apiKey, api: .openAICompletions, baseURL: "https://bedrock-mantle.us-east-1.api.aws/v1", defaultModelID: "openai.gpt-oss-120b"),
        .init(providerID: "arcee", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.arcee.ai/api/v1", defaultModelID: "trinity-large-thinking"),
        .init(providerID: "chutes", auth: .apiKey, api: .openAICompletions, baseURL: "https://llm.chutes.ai/v1", defaultModelID: "zai-org/GLM-4.7-TEE"),
        .init(providerID: "copilot-proxy", auth: nil, api: .openAICompletions, baseURL: "http://localhost:3000/v1", defaultModelID: "gpt-5.2"),
        .init(providerID: "deepseek", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.deepseek.com", defaultModelID: "deepseek-v4-flash"),
        .init(providerID: "fireworks", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.fireworks.ai/inference/v1", defaultModelID: "accounts/fireworks/routers/kimi-k2p5-turbo"),
        .init(
            providerID: "lmstudio",
            auth: nil,
            api: .openAICompletions,
            baseURL: "http://localhost:1234/v1",
            defaultModelID: "qwen/qwen3.5-9b",
            capabilities: [.text, .memoryEmbedding]
        ),
        .init(providerID: "microsoft-foundry", auth: .oauth, api: .openAIResponses, baseURL: "https://example.services.ai.azure.com/openai/v1", defaultModelID: "gpt-5"),
        .init(providerID: "qwen", auth: .apiKey, api: .openAICompletions, baseURL: "https://coding-intl.dashscope.aliyuncs.com/v1", defaultModelID: "qwen3.5-plus"),
        .init(providerID: "stepfun", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.stepfun.ai/v1", defaultModelID: "step-3.5-flash"),
        .init(providerID: "stepfun-plan", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.stepfun.ai/step_plan/v1", defaultModelID: "step-3.5-flash"),
        .init(providerID: "tencent-tokenhub", auth: .apiKey, api: .openAICompletions, baseURL: "https://tokenhub.tencentmaas.com/v1", defaultModelID: "hy3-preview"),
        .init(providerID: "google-vertex", auth: .oauth, api: .googleGenerativeAI, baseURL: "https://us-central1-aiplatform.googleapis.com", defaultModelID: "gemini-3-pro-preview"),
        .init(providerID: "google-antigravity", auth: .oauth, api: .googleGenerativeAI, baseURL: "https://generativelanguage.googleapis.com/v1beta", defaultModelID: "gemini-3-pro-preview"),
        .init(providerID: "google-gemini-cli", auth: .oauth, api: .googleGenerativeAI, baseURL: "https://generativelanguage.googleapis.com/v1beta", defaultModelID: "gemini-3-flash-preview"),
        .init(providerID: "kilocode", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.kilo.ai/api/gateway/", defaultModelID: "kilo/auto"),
        .init(providerID: "kimi-coding", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.kimi.com/coding/", defaultModelID: "k2p5"),
        .init(providerID: "venice", auth: .apiKey, api: .openAICompletions, baseURL: "https://api.venice.ai/api/v1", defaultModelID: "kimi-k2-5"),
        .init(providerID: "modelstudio", auth: .apiKey, api: .openAICompletions, baseURL: "https://coding-intl.dashscope.aliyuncs.com/v1", defaultModelID: "qwen3.5-plus"),
        .init(providerID: "volcengine", auth: .apiKey, api: .openAICompletions, baseURL: "https://ark.cn-beijing.volces.com/api/v3", defaultModelID: "doubao-seed-1-8-251228"),
        .init(providerID: "volcengine-plan", auth: .apiKey, api: .openAICompletions, baseURL: "https://ark.cn-beijing.volces.com/api/coding/v3", defaultModelID: "ark-code-latest"),
        .init(providerID: "byteplus", auth: .apiKey, api: .openAICompletions, baseURL: "https://ark.ap-southeast.bytepluses.com/api/v3", defaultModelID: "seed-1-8-251228"),
        .init(providerID: "byteplus-plan", auth: .apiKey, api: .openAICompletions, baseURL: "https://ark.ap-southeast.bytepluses.com/api/coding/v3", defaultModelID: "ark-code-latest"),
    ]
}
