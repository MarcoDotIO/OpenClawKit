import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// HTTP transport contract used by Gemini model provider.
public protocol GeminiHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: GeminiHTTPTransport {}

/// Gemini provider using the `generateContent` endpoint with an API key.
///
/// Implements model contract v2 (`contents` transcripts with `functionCall`/`functionResponse`
/// parts, function declarations and `toolConfig`, JSON-schema responses via
/// `responseMimeType`/`responseJsonSchema`, thinking config, usage and SSE streaming). Legacy
/// prompt-only requests keep inlining the system prompt into the user turn.
public struct GeminiModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "gemini"

    /// Provider identifier.
    public let id: String

    private let engine: GoogleGenerativeAIEngine

    /// Creates a Gemini provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = GeminiModelProvider.providerID,
        configuration: GeminiModelConfig,
        transport: any GeminiHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        let service = ProviderServiceConfig(
            enabled: configuration.enabled,
            apiStyle: .custom,
            authMode: .apiKey,
            modelID: configuration.modelID,
            apiKey: configuration.apiKey,
            baseURL: configuration.baseURL
        )
        self.engine = GoogleGenerativeAIEngine(
            settings: ProviderEndpointSettings(providerID: id, service: service, api: .googleGenerativeAI, runtime: runtime),
            exchange: ProviderHTTPExchange(
                providerID: id,
                send: { try await transport.data(for: $0) },
                streamingTransport: transport as? any ModelHTTPStreamingTransport
            ),
            inlineSystemPrompt: true,
            fallbackModelID: configuration.modelID
        )
    }

    /// Contract v2 features of the Google Generative AI engine.
    public var capabilities: ModelProviderCapabilities {
        GoogleGenerativeAIEngine.capabilities
    }

    /// Generates a response via the Gemini `generateContent` API.
    /// - Parameter request: Generation request.
    /// - Returns: Generation response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.engine.settings.enabled else {
            throw OpenClawCoreError.unavailable("Gemini model provider is disabled")
        }
        return try await self.engine.generate(request)
    }

    /// Streams chunks via `streamGenerateContent?alt=sse`.
    /// - Parameter request: Generation request.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        guard self.engine.settings.enabled else {
            return AsyncThrowingStream { $0.finish(throwing: OpenClawCoreError.unavailable("Gemini model provider is disabled")) }
        }
        return self.engine.stream(request)
    }
}
