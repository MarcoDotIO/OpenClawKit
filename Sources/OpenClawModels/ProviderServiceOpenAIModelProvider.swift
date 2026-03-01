import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

private struct ProviderServiceOpenAIChatCompletionRequest: Codable, Sendable {
    let model: String
    let messages: [ProviderServiceOpenAIChatMessage]
}

private struct ProviderServiceOpenAIChatMessage: Codable, Sendable {
    let role: String
    let content: String
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

        let endpoint = try self.resolveEndpoint()
        let modelID = self.resolveModelID(request: request)
        let payload = ProviderServiceOpenAIChatCompletionRequest(
            model: modelID,
            messages: self.buildMessages(from: request)
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try self.resolveAuthorizationToken() {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let organizationID = self.configuration.organizationID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !organizationID.isEmpty
        {
            urlRequest.setValue(organizationID, forHTTPHeaderField: "x-organization-id")
        }
        for (key, value) in self.configuration.headers {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty, !normalizedValue.isEmpty else { continue }
            urlRequest.setValue(normalizedValue, forHTTPHeaderField: normalizedKey)
        }
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
        let requested = request.metadata["model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !requested.isEmpty {
            return requested
        }
        let configured = self.configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? "gpt-4.1-mini" : configured
    }

    private func resolveAuthorizationToken() throws -> String? {
        switch self.configuration.authMode {
        case .apiKey:
            let apiKey = self.configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !apiKey.isEmpty else {
                throw OpenClawCoreError.invalidConfiguration("\(self.id) API key is required")
            }
            return apiKey
        case .bearerToken, .oauthToken:
            let token = self.configuration.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else {
                throw OpenClawCoreError.invalidConfiguration("\(self.id) access token is required")
            }
            return token
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
            messages.append(ProviderServiceOpenAIChatMessage(role: "system", content: systemPrompt))
        }
        messages.append(ProviderServiceOpenAIChatMessage(role: "user", content: request.prompt))
        return messages
    }

    private func resolveEndpoint() throws -> URL {
        let baseRaw = self.configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseRaw.isEmpty, let baseURL = URL(string: baseRaw) else {
            throw OpenClawCoreError.invalidConfiguration("\(self.id) base URL is invalid")
        }
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
