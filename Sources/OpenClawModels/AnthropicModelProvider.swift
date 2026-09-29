import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// HTTP transport contract used by Anthropic model provider.
public protocol AnthropicHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: AnthropicHTTPTransport {}

/// Anthropic provider using the Messages API.
///
/// Implements model contract v2 (see ``ProviderServiceAnthropicModelProvider``) for the direct
/// Anthropic API: default betas (`fine-grained-tool-streaming-2025-05-14`,
/// `interleaved-thinking-2025-05-14`), adaptive thinking for Claude 5-family and 4.6+ models,
/// native fast mode for Opus 5 / Opus 4.8, and the legacy service tier for older models.
///
/// Headers come from the runtime context's canonical config (`headers`),
/// ``AnthropicModelConfig/headers`` and ``AnthropicModelConfig/workspaceID``, model headers and
/// ``ModelGenerationRequest/headers``. API keys that are not scoped to a workspace need an
/// `anthropic-workspace-id` header (set ``AnthropicModelConfig/workspaceID``).
public struct AnthropicModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "anthropic"

    /// Provider identifier.
    public let id: String

    private let configuration: AnthropicModelConfig
    private let engine: AnthropicMessagesEngine

    /// Creates an Anthropic provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = AnthropicModelProvider.providerID,
        configuration: AnthropicModelConfig,
        transport: any AnthropicHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.configuration = configuration
        // Canonical config headers (factory-built providers), then the direct config's headers and
        // workspace id (`anthropic-workspace-id` for keys that are not scoped to a workspace).
        var headers = runtime.providerConfig?.headers ?? [:]
        headers.merge(configuration.resolvedHeaders) { _, direct in direct }
        let service = ProviderServiceConfig(
            enabled: configuration.enabled,
            apiStyle: .anthropicMessages,
            authMode: .apiKey,
            modelID: configuration.modelID,
            fastMode: configuration.fastMode,
            apiKey: configuration.apiKey,
            baseURL: configuration.baseURL,
            messagesPath: "messages",
            apiVersion: configuration.apiVersion,
            headers: headers
        )
        self.engine = AnthropicMessagesEngine(
            settings: ProviderEndpointSettings(providerID: id, service: service, api: .anthropicMessages, runtime: runtime),
            exchange: ProviderHTTPExchange(
                providerID: id,
                send: { try await transport.data(for: $0) },
                streamingTransport: transport as? any ModelHTTPStreamingTransport
            ),
            defaultMaxTokens: configuration.maxTokens
        )
    }

    /// Contract v2 features of the Anthropic Messages engine.
    public var capabilities: ModelProviderCapabilities {
        AnthropicMessagesEngine.capabilities
    }

    /// Generates a response using the Anthropic Messages endpoint.
    /// - Parameter request: Generation request.
    /// - Returns: Generation response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try self.validate(request)
        return try await self.engine.generate(request)
    }

    /// Streams chunks from the Anthropic Messages endpoint.
    /// - Parameter request: Generation request.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        do {
            try self.validate(request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return self.engine.stream(request)
    }

    private func validate(_ request: ModelGenerationRequest) throws {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("Anthropic model provider is disabled")
        }
        let apiKey = self.configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || request.resolvedAPIKey != nil else {
            throw OpenClawCoreError.invalidConfiguration("Anthropic API key is required")
        }
    }
}
