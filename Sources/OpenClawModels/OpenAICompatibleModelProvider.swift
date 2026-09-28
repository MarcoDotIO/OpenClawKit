import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// HTTP transport contract used by OpenAI-compatible model providers.
public protocol OpenAICompatibleHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: OpenAICompatibleHTTPTransport {}

/// Generic OpenAI-compatible provider for compatible Chat Completions APIs.
///
/// Implements model contract v2 through the shared Chat Completions engine (see
/// ``ProviderServiceOpenAIModelProvider``).
public struct OpenAICompatibleModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "openai-compatible"

    /// Provider identifier.
    public let id: String

    private let engine: OpenAIChatCompletionsEngine

    /// Creates an OpenAI-compatible provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = OpenAICompatibleModelProvider.providerID,
        configuration: OpenAICompatibleModelConfig,
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        let service = ProviderServiceConfig(
            enabled: configuration.enabled,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: configuration.modelID,
            apiKey: configuration.apiKey,
            baseURL: configuration.baseURL,
            chatCompletionsPath: configuration.chatCompletionsPath
        )
        self.engine = OpenAIChatCompletionsEngine(
            settings: ProviderEndpointSettings(providerID: id, service: service, api: .openAICompletions, runtime: runtime),
            exchange: ProviderHTTPExchange(
                providerID: id,
                send: { try await transport.data(for: $0) },
                streamingTransport: transport as? any ModelHTTPStreamingTransport
            )
        )
    }

    /// Contract v2 features of the Chat Completions engine.
    public var capabilities: ModelProviderCapabilities {
        OpenAIChatCompletionsEngine.capabilities
    }

    /// Generates a response from a Chat Completions endpoint.
    /// - Parameter request: Generation request.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.engine.settings.enabled else {
            throw OpenClawCoreError.unavailable("OpenAI-compatible provider is disabled")
        }
        return try await self.engine.generate(request)
    }

    /// Streams chunks from a Chat Completions endpoint.
    /// - Parameter request: Generation request.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        guard self.engine.settings.enabled else {
            return AsyncThrowingStream { $0.finish(throwing: OpenClawCoreError.unavailable("OpenAI-compatible provider is disabled")) }
        }
        return self.engine.stream(request)
    }
}
