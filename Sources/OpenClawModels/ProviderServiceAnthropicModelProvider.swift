import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Generic Anthropic-messages provider backed by `ProviderServiceConfig`.
///
/// Implements model contract v2 on the Messages API: transcripts with tool-use/tool-result blocks,
/// tools and tool choice, adaptive or budget thinking with `output_config.effort`, betas, sampling
/// rules for Claude 5-family models, fast mode, usage, stop reasons and SSE streaming. The endpoint
/// follows upstream: `<base>/v1/messages`, or `<base>/messages` when the base already ends in `/v1`.
public struct ProviderServiceAnthropicModelProvider: ModelProvider {
    /// Provider identifier.
    public let id: String

    private let configuration: ProviderServiceConfig
    private let runtime: ModelProviderRuntimeContext
    private let engine: AnthropicMessagesEngine

    /// Creates a provider service Anthropic-messages provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String,
        configuration: ProviderServiceConfig,
        transport: any AnthropicHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.configuration = configuration
        self.runtime = runtime
        self.engine = AnthropicMessagesEngine(
            settings: ProviderEndpointSettings(providerID: id, service: configuration, api: .anthropicMessages, runtime: runtime),
            exchange: ProviderHTTPExchange(
                providerID: id,
                send: { try await transport.data(for: $0) },
                streamingTransport: transport as? any ModelHTTPStreamingTransport
            ),
            defaultMaxTokens: 8_192
        )
    }

    /// Contract v2 features of the Anthropic Messages engine.
    public var capabilities: ModelProviderCapabilities {
        AnthropicMessagesEngine.capabilities
    }

    /// Generates a response from an Anthropic-messages compatible endpoint.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try self.validateAPIStyle()
        return try await self.engine.generate(request)
    }

    /// Streams chunks from an Anthropic-messages compatible endpoint.
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
        case .anthropicMessages, .custom:
            return
        default:
            throw OpenClawCoreError.invalidConfiguration(
                "\(self.id) requires an Anthropic-messages compatible apiStyle"
            )
        }
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
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
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
        transport: any AnthropicHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying Anthropic Messages engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from MiniMax.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from MiniMax.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// MiniMax portal Anthropic-compatible provider implementation.
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
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
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
        transport: any AnthropicHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying Anthropic Messages engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from MiniMax portal.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from MiniMax portal.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Synthetic Anthropic-compatible provider implementation.
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
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
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
        transport: any AnthropicHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying Anthropic Messages engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Synthetic.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Synthetic.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
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
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
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
        transport: any AnthropicHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying Anthropic Messages engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Xiaomi.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Xiaomi.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Cloudflare AI Gateway Anthropic-compatible provider implementation.
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
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
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
        transport: any AnthropicHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying Anthropic Messages engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Cloudflare AI Gateway.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Cloudflare AI Gateway.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}

/// Vercel AI Gateway Anthropic-compatible provider implementation.
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
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = VercelAIGatewayModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .anthropicMessages,
            authMode: .apiKey,
            modelID: "anthropic/claude-opus-4.6",
            baseURL: "https://ai-gateway.vercel.sh",
            messagesPath: "messages"
        ),
        transport: any AnthropicHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.provider = ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime
        )
    }

    /// Contract v2 features of the underlying Anthropic Messages engine.
    public var capabilities: ModelProviderCapabilities {
        self.provider.capabilities
    }

    /// Generates a response from Vercel AI Gateway.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider.generate(request)
    }

    /// Streams chunks from Vercel AI Gateway.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.provider.generateStream(request)
    }
}
