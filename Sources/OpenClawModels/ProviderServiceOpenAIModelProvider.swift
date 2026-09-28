import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Generic OpenAI-completions provider backed by `ProviderServiceConfig`.
///
/// Implements model contract v2 (transcript messages, tools and tool choice, JSON-schema response
/// formats, tool calls, usage, stop reasons, reasoning and incremental streaming) and shapes
/// payloads from model compat flags (`maxTokensField`, `thinkingFormat`, developer role, string
/// content, usage streaming, OpenRouter/Vercel routing). Tool calls are proposals; the host or agent
/// loop owns execution and approval.
public struct ProviderServiceOpenAIModelProvider: ModelProvider {
    /// Provider identifier.
    public let id: String

    private let configuration: ProviderServiceConfig
    private let runtime: ModelProviderRuntimeContext
    private let engine: OpenAIChatCompletionsEngine

    /// Creates a provider service OpenAI-completions provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation (streams incrementally when it conforms to
    ///     ``ModelHTTPStreamingTransport``).
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String,
        configuration: ProviderServiceConfig,
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.configuration = configuration
        self.runtime = runtime
        self.engine = OpenAIChatCompletionsEngine(
            settings: ProviderEndpointSettings(providerID: id, service: configuration, api: .openAICompletions, runtime: runtime),
            exchange: ProviderHTTPExchange(
                providerID: id,
                send: { try await transport.data(for: $0) },
                streamingTransport: transport as? any ModelHTTPStreamingTransport
            )
        )
    }

    /// Contract v2 features: streaming, tools, JSON schema, images, reasoning and transcripts.
    public var capabilities: ModelProviderCapabilities {
        OpenAIChatCompletionsEngine.capabilities
    }

    /// Generates a response from an OpenAI-completions compatible endpoint.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try self.validateAPIStyle()
        return try await self.engine.generate(request)
    }

    /// Streams text, reasoning, tool-call and usage chunks from an OpenAI-completions endpoint.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        do {
            try self.validateAPIStyle()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return self.engine.stream(request)
    }

    private func validateAPIStyle() throws {
        guard self.runtime.api == nil else { return }
        switch self.configuration.apiStyle {
        case .openAICompletions, .custom, .ollama:
            return
        default:
            throw OpenClawCoreError.invalidConfiguration(
                "\(self.id) requires an OpenAI-completions compatible apiStyle"
            )
        }
    }
}

/// OpenRouter provider service implementation.
public struct OpenRouterModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "openrouter"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates an OpenRouter provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = OpenRouterModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: "anthropic/claude-sonnet-4-5",
            baseURL: "https://openrouter.ai/api/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from OpenRouter.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from OpenRouter.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Groq provider service implementation.
public struct GroqModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "groq"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a Groq provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = GroqModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: "llama-3.3-70b-versatile",
            baseURL: "https://api.groq.com/openai/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Groq.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Groq.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Mistral provider service implementation.
public struct MistralModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "mistral"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a Mistral provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = MistralModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: "mistral-large-latest",
            baseURL: "https://api.mistral.ai/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Mistral.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Mistral.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Cerebras provider service implementation.
public struct CerebrasModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "cerebras"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a Cerebras provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = CerebrasModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: "zai-glm-4.7",
            baseURL: "https://api.cerebras.ai/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Cerebras.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Cerebras.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Moonshot provider service implementation.
public struct MoonshotModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "moonshot"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a Moonshot provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = MoonshotModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: "kimi-k2.5",
            baseURL: "https://api.moonshot.ai/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Moonshot.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Moonshot.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// LiteLLM provider service implementation.
public struct LiteLLMModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "litellm"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a LiteLLM provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = LiteLLMModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: "gpt-4.1-mini",
            baseURL: "http://127.0.0.1:4000/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from LiteLLM.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from LiteLLM.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Together provider service implementation.
public struct TogetherModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "together"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a Together provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = TogetherModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            baseURL: "https://api.together.xyz/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Together.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Together.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Hugging Face Inference provider service implementation.
public struct HuggingFaceModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "huggingface"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a Hugging Face Inference provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = HuggingFaceModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: "deepseek-ai/DeepSeek-R1",
            baseURL: "https://router.huggingface.co/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Hugging Face Inference.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Hugging Face Inference.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Qianfan provider service implementation.
public struct QianfanModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "qianfan"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a Qianfan provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = QianfanModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: "deepseek-v3.2",
            baseURL: "https://qianfan.baidubce.com/v2",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Qianfan.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Qianfan.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// NVIDIA provider service implementation.
public struct NVIDIAModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "nvidia"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates an NVIDIA provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = NVIDIAModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: "nvidia/llama-3.1-nemotron-70b-instruct",
            baseURL: "https://integrate.api.nvidia.com/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from NVIDIA.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from NVIDIA.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Z.AI provider service implementation.
public struct ZAIModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "zai"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a Z.AI provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = ZAIModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: "glm-4.7",
            baseURL: "https://api.z.ai/api/paas/v4",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Z.AI.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Z.AI.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// GitHub Copilot provider service implementation.
public struct GitHubCopilotModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "github-copilot"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a GitHub Copilot provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = GitHubCopilotModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .bearerToken,
            modelID: "gpt-5",
            baseURL: "https://api.githubcopilot.com",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from GitHub Copilot.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from GitHub Copilot.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// vLLM provider service implementation.
public struct VLLMModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "vllm"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a vLLM provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = VLLMModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .none,
            modelID: "qwen2.5-coder-32b-instruct",
            baseURL: "http://127.0.0.1:8000/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from vLLM.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from vLLM.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Qwen Portal provider service implementation.
public struct QwenPortalModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "qwen-portal"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a Qwen Portal provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = QwenPortalModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .oauthToken,
            modelID: "coder-model",
            baseURL: "https://portal.qwen.ai/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying OpenAI-completions engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Qwen Portal.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Qwen Portal.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Ollama provider service implementation.
///
/// With `apiStyle: .ollama` (the default) requests use the native `/api/chat` endpoint at the
/// Ollama root (a trailing `/v1` is stripped), matching upstream. Other API styles keep the
/// OpenAI-compatible `chat/completions` path. Ollama Cloud (`https://ollama.com`) takes an API
/// key sent as `Authorization: Bearer`.
public struct OllamaModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "ollama"

    /// Provider identifier.
    public let id: String

    private let native: OllamaChatEngine?
    private let compatible: ProviderServiceOpenAIModelProvider

    /// Creates an Ollama provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = OllamaModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .ollama,
            authMode: .none,
            modelID: "llama3.3",
            baseURL: "http://127.0.0.1:11434",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        let usesNative = runtime.api.map { $0 == .ollama } ?? (configuration.apiStyle == .ollama)
        if usesNative {
            self.native = OllamaChatEngine(
                settings: ProviderEndpointSettings(providerID: id, service: configuration, api: .ollama, runtime: runtime),
                exchange: ProviderHTTPExchange(
                    providerID: id,
                    send: { try await transport.data(for: $0) },
                    streamingTransport: transport as? any ModelHTTPStreamingTransport
                )
            )
        } else {
            self.native = nil
        }
        self.compatible = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the active engine.
    public var capabilities: ModelProviderCapabilities {
        self.native == nil ? self.compatible.capabilities : OllamaChatEngine.capabilities
    }

    /// Generates a response from Ollama.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        if let native {
            return try await native.generate(request)
        }
        return try await self.compatible.generate(request)
    }

    /// Streams chunks from Ollama (NDJSON on the native endpoint).
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        if let native {
            return native.stream(request)
        }
        return await self.compatible.generateStream(request)
    }
}
