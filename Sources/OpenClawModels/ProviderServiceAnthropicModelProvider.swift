import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

private struct ProviderServiceAnthropicMessagesRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        let role: String
        let content: AnthropicMessageContent
    }

    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [Message]
    let serviceTier: String?

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case serviceTier = "service_tier"
    }
}

private struct ProviderServiceAnthropicMessagesResponse: Codable, Sendable {
    struct ContentBlock: Codable, Sendable {
        let type: String
        let text: String?
    }

    let id: String?
    let model: String?
    let content: [ContentBlock]
}

/// Generic Anthropic-messages provider backed by `ProviderServiceConfig`.
public struct ProviderServiceAnthropicModelProvider: ModelProvider {
    /// Provider identifier.
    public let id: String

    private let configuration: ProviderServiceConfig
    private let transport: any AnthropicHTTPTransport

    /// Creates a provider service Anthropic-messages provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String,
        configuration: ProviderServiceConfig,
        transport: any AnthropicHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.configuration = configuration
        self.transport = transport
    }

    /// Generates text from an Anthropic-messages compatible endpoint.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("\(self.id) model provider is disabled")
        }
        switch self.configuration.apiStyle {
        case .anthropicMessages, .custom:
            break
        default:
            throw OpenClawCoreError.invalidConfiguration(
                "\(self.id) requires an Anthropic-messages compatible apiStyle"
            )
        }

        let endpoint = try self.resolveEndpoint()
        let modelID = self.resolveModelID(request: request)
        let payload = ProviderServiceAnthropicMessagesRequest(
            model: modelID,
            maxTokens: self.resolveMaxTokens(),
            system: self.resolveSystemPrompt(request: request),
            messages: [
                .init(
                    role: "user",
                    content: AnthropicStyleMultimodalSupport.userContent(
                        prompt: request.prompt,
                        attachments: request.attachments
                    )
                ),
            ],
            serviceTier: AnthropicFastModeResolution.serviceTier(
                providerID: self.id,
                baseURL: endpoint.deletingLastPathComponent(),
                request: request,
                configuredFastMode: self.configuration.fastMode,
                allowsFastModeDefaults: self.configuration.authMode == .apiKey
            )
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try self.applyAuthHeaders(to: &urlRequest, generationRequest: request)
        urlRequest.setValue(self.resolveAPIVersion(), forHTTPHeaderField: "anthropic-version")
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

        let decoded = try JSONDecoder().decode(ProviderServiceAnthropicMessagesResponse.self, from: response.body)
        guard let content = decoded.content.first(where: { $0.type == "text" })?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else {
            throw OpenClawCoreError.unavailable("\(self.id) response did not include text content")
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
            fallback: "claude-3-5-haiku-latest"
        )
    }

    private func resolveMaxTokens() -> Int {
        let metadataValue = self.configuration.metadata["maxTokens"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let parsed = Int(metadataValue), parsed > 0 {
            return parsed
        }
        return 8_192
    }

    private func resolveSystemPrompt(request: ModelGenerationRequest) -> String? {
        let systemPrompt = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return systemPrompt.isEmpty ? nil : systemPrompt
    }

    private func resolveAPIVersion() -> String {
        let version = self.configuration.apiVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? "2023-06-01" : version
    }

    private func applyAuthHeaders(to request: inout URLRequest, generationRequest: ModelGenerationRequest) throws {
        switch self.configuration.authMode {
        case .apiKey:
            let apiKey = try ProviderRequestResolution.resolveAPIKey(
                configured: self.configuration.apiKey,
                request: generationRequest,
                providerID: self.id
            )
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .bearerToken, .oauthToken:
            let token = try ProviderRequestResolution.resolveAccessToken(
                configured: self.configuration.accessToken,
                request: generationRequest,
                providerID: self.id
            )
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .none:
            break
        case .awsSDK:
            throw OpenClawCoreError.invalidConfiguration(
                "\(self.id) does not support aws-sdk auth mode for Anthropic-messages requests"
            )
        }
    }

    private func resolveEndpoint() throws -> URL {
        let baseRaw = self.configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseRaw.isEmpty, let baseURL = URL(string: baseRaw) else {
            throw OpenClawCoreError.invalidConfiguration("\(self.id) base URL is invalid")
        }
        let path = self.configuration.messagesPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("\(self.id) messages path is required")
        }
        var endpoint = baseURL
        for segment in path.split(separator: "/") {
            endpoint = endpoint.appendingPathComponent(String(segment))
        }
        return endpoint
    }
}

/// MiniMax Anthropic-compatible provider implementation.
public struct MinimaxModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "minimax"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceAnthropicModelProvider

    /// Creates a MiniMax provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String = MinimaxModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .anthropicMessages,
            authMode: .apiKey,
            modelID: "MiniMax-M2.1",
            baseURL: "https://api.minimax.io/anthropic",
            messagesPath: "messages"
        ),
        transport: any AnthropicHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from MiniMax.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }
}

/// MiniMax portal provider implementation.
public struct MinimaxPortalModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "minimax-portal"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceAnthropicModelProvider

    /// Creates a MiniMax portal provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String = MinimaxPortalModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .anthropicMessages,
            authMode: .oauthToken,
            modelID: "MiniMax-M2.1",
            baseURL: "https://api.minimax.io/anthropic",
            messagesPath: "messages"
        ),
        transport: any AnthropicHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from MiniMax portal.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }
}

/// Synthetic provider implementation.
public struct SyntheticModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "synthetic"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceAnthropicModelProvider

    /// Creates a Synthetic provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String = SyntheticModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .anthropicMessages,
            authMode: .apiKey,
            modelID: "hf:MiniMaxAI/MiniMax-M2.1",
            baseURL: "https://api.synthetic.new/anthropic",
            messagesPath: "messages"
        ),
        transport: any AnthropicHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Synthetic.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }
}

/// Xiaomi Anthropic-compatible provider implementation.
public struct XiaomiModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "xiaomi"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceAnthropicModelProvider

    /// Creates a Xiaomi provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String = XiaomiModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .anthropicMessages,
            authMode: .apiKey,
            modelID: "mimo-v2-flash",
            baseURL: "https://api.xiaomimimo.com/anthropic",
            messagesPath: "messages"
        ),
        transport: any AnthropicHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Xiaomi.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }
}

/// Cloudflare AI Gateway provider implementation.
public struct CloudflareAIGatewayModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "cloudflare-ai-gateway"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceAnthropicModelProvider

    /// Creates a Cloudflare AI Gateway provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String = CloudflareAIGatewayModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .anthropicMessages,
            authMode: .apiKey,
            modelID: "claude-3-5-sonnet-latest",
            baseURL: "https://gateway.ai.cloudflare.com/v1",
            messagesPath: "messages"
        ),
        transport: any AnthropicHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Cloudflare AI Gateway.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }
}

/// Vercel AI Gateway provider implementation.
public struct VercelAIGatewayModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "vercel-ai-gateway"

    /// Provider identifier.
    public let id: String

    private let provider: ProviderServiceAnthropicModelProvider

    /// Creates a Vercel AI Gateway provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String = VercelAIGatewayModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .anthropicMessages,
            authMode: .apiKey,
            modelID: "anthropic/claude-opus-4.6",
            baseURL: "https://ai-gateway.vercel.sh/v1",
            messagesPath: "messages"
        ),
        transport: any AnthropicHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.provider = ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: configuration,
            transport: transport
        )
    }

    /// Generates text from Vercel AI Gateway.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }
}
