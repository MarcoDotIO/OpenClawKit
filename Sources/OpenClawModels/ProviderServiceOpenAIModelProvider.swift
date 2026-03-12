import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

private struct ProviderServiceOpenAIChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [ProviderServiceOpenAIChatMessage]
}

private struct ProviderServiceOpenAIChatMessage: Encodable, Sendable {
    let role: String
    let content: OpenAIStyleMessageContent
}

private struct ProviderServiceOpenAIChatCompletionResponse: Codable, Sendable {
    struct Choice: Codable, Sendable {
        struct Message: Codable, Sendable {
            let role: String
            let content: String
        }

        let index: Int
        let message: Message
    }

    let model: String?
    let choices: [Choice]
}

/// Generic OpenAI-completions provider backed by `ProviderServiceConfig`.
public struct ProviderServiceOpenAIModelProvider: ModelProvider {
    /// Provider identifier.
    public let id: String

    private let configuration: ProviderServiceConfig
    private let transport: any OpenAICompatibleHTTPTransport

    /// Creates a provider service OpenAI-completions provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String,
        configuration: ProviderServiceConfig,
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.configuration = configuration
        self.transport = transport
    }

    /// Generates text from an OpenAI-completions compatible endpoint.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("\(self.id) model provider is disabled")
        }
        switch self.configuration.apiStyle {
        case .openAICompletions, .custom, .ollama:
            break
        default:
            throw OpenClawCoreError.invalidConfiguration(
                "\(self.id) requires an OpenAI-completions compatible apiStyle"
            )
        }

        let endpoint = try self.resolveEndpoint(request: request)
        let modelID = self.resolveModelID(request: request)
        let payload = ProviderServiceOpenAIChatCompletionRequest(
            model: modelID,
            messages: self.buildMessages(from: request)
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try self.resolveAuthorizationToken(request: request) {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let organizationID = self.configuration.organizationID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !organizationID.isEmpty
        {
            urlRequest.setValue(organizationID, forHTTPHeaderField: "x-organization-id")
        }
        ProviderRequestResolution.applyHeaders(
            ProviderRequestResolution.mergedHeaders(configured: self.configuration.headers, request: request),
            request: &urlRequest
        )
        urlRequest.timeoutInterval = 30
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let response = try await self.transport.data(for: urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("\(self.id) request failed with status \(response.statusCode)")
        }

        let decoded = try JSONDecoder().decode(ProviderServiceOpenAIChatCompletionResponse.self, from: response.body)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else {
            throw OpenClawCoreError.unavailable("\(self.id) response did not include message content")
        }

        return ModelGenerationResponse(
            text: content,
            providerID: self.id,
            modelID: decoded.model ?? modelID
        )
    }

    private func resolveModelID(request: ModelGenerationRequest) -> String {
        ProviderRequestResolution.resolveModelID(
            request: request,
            configured: self.configuration.modelID,
            fallback: "gpt-4.1-mini"
        )
    }

    private func resolveAuthorizationToken(request: ModelGenerationRequest) throws -> String? {
        switch self.configuration.authMode {
        case .apiKey:
            return try ProviderRequestResolution.resolveAPIKey(
                configured: self.configuration.apiKey,
                request: request,
                providerID: self.id
            )
        case .bearerToken, .oauthToken:
            return try ProviderRequestResolution.resolveAccessToken(
                configured: self.configuration.accessToken,
                request: request,
                providerID: self.id
            )
        case .none:
            return nil
        case .awsSDK:
            throw OpenClawCoreError.invalidConfiguration(
                "\(self.id) does not support aws-sdk auth mode for OpenAI-completions requests"
            )
        }
    }

    private func buildMessages(from request: ModelGenerationRequest) -> [ProviderServiceOpenAIChatMessage] {
        var messages: [ProviderServiceOpenAIChatMessage] = []
        let systemPrompt = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !systemPrompt.isEmpty {
            messages.append(ProviderServiceOpenAIChatMessage(role: "system", content: .text(systemPrompt)))
        }
        messages.append(
            ProviderServiceOpenAIChatMessage(
                role: "user",
                content: OpenAIStyleMultimodalSupport.userContent(
                    prompt: request.prompt,
                    attachments: request.attachments
                )
            )
        )
        return messages
    }

    private func resolveEndpoint(request: ModelGenerationRequest) throws -> URL {
        let baseURL = try ProviderRequestResolution.resolveBaseURL(
            configured: self.configuration.baseURL,
            request: request,
            providerID: self.id
        )
        let path = self.configuration.chatCompletionsPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("\(self.id) chat completions path is required")
        }
        var endpoint = baseURL
        for segment in path.split(separator: "/") {
            endpoint = endpoint.appendingPathComponent(String(segment))
        }
        return endpoint
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from OpenRouter.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Groq.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Mistral.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Cerebras.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Moonshot.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from LiteLLM.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Together.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }
}

/// Hugging Face Inference provider service implementation.
public struct HuggingFaceModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "huggingface"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates a Hugging Face provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Hugging Face Inference.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Qianfan.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from NVIDIA.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Z.AI.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from GitHub Copilot.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }
}

/// Ollama provider service implementation.
public struct OllamaModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "ollama"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceOpenAIModelProvider

    /// Creates an Ollama provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String = OllamaModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .ollama,
            authMode: .none,
            modelID: "llama3.3",
            baseURL: "http://127.0.0.1:11434/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Ollama.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from vLLM.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
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
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceOpenAIModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Qwen Portal.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }
}
