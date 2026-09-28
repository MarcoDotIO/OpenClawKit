import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Generic Google Generative AI provider supporting API-key and OAuth-style auth.
///
/// Serves `google`/`gemini`, `google-gemini-cli`, `google-antigravity` and `google-vertex`
/// (API `google-vertex`: a `{location}`/`{region}` placeholder in the base URL is replaced with the
/// configured region, default `us-central1`). Implements model contract v2 like
/// ``GeminiModelProvider``, with the system prompt sent as `systemInstruction`.
public struct GoogleGenerativeAIModelProvider: ModelProvider {
    /// Provider identifier.
    public let id: String

    private let engine: GoogleGenerativeAIEngine

    /// Creates a Google Generative AI provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config and effective API (`google-generative-ai` or `google-vertex`).
    public init(
        id: String,
        configuration: ProviderServiceConfig,
        transport: any GeminiHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.engine = GoogleGenerativeAIEngine(
            settings: ProviderEndpointSettings(providerID: id, service: configuration, api: .googleGenerativeAI, runtime: runtime),
            exchange: ProviderHTTPExchange(
                providerID: id,
                send: { try await transport.data(for: $0) },
                streamingTransport: transport as? any ModelHTTPStreamingTransport
            ),
            inlineSystemPrompt: false,
            fallbackModelID: "gemini-2.0-flash"
        )
    }

    /// Contract v2 features of the Google Generative AI engine.
    public var capabilities: ModelProviderCapabilities {
        GoogleGenerativeAIEngine.capabilities
    }

    /// Generates a response via `generateContent`.
    /// - Parameter request: Generation request.
    /// - Returns: Generation response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.engine.generate(request)
    }

    /// Streams chunks via `streamGenerateContent?alt=sse`.
    /// - Parameter request: Generation request.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        self.engine.stream(request)
    }
}
