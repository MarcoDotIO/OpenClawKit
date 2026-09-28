import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// HTTP transport contract used by xAI/Grok model provider.
public protocol XAIHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: XAIHTTPTransport {}

/// First-class xAI/Grok provider.
///
/// Uses Chat Completions by default and the Responses API when the runtime context selects
/// `openai-responses` (upstream's current xAI API). Fast mode swaps to the `-fast` model variants
/// (`grok-3` → `grok-3-fast`, `grok-3-mini` → `grok-3-mini-fast`, `grok-4`/`grok-4-0709` →
/// `grok-4-fast`).
public struct XAIModelProvider: ModelProvider {
    /// Canonical provider identifier for xAI.
    public static let providerID = "xai"
    /// Canonical Grok alias identifier.
    public static let grokAliasProviderID = "grok"

    /// Provider identifier.
    public let id: String

    private let configuration: ProviderServiceConfig
    private let completions: OpenAIChatCompletionsEngine
    private let responses: OpenAIResponsesEngine?

    /// Creates an xAI/Grok provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config and effective API.
    public init(
        id: String = XAIModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: "grok-3-mini",
            baseURL: "https://api.x.ai/v1",
            chatCompletionsPath: "chat/completions"
        ),
        transport: any XAIHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.configuration = configuration
        let exchange = ProviderHTTPExchange(
            providerID: id,
            send: { try await transport.data(for: $0) },
            streamingTransport: transport as? any ModelHTTPStreamingTransport
        )
        self.completions = OpenAIChatCompletionsEngine(
            settings: ProviderEndpointSettings(providerID: id, service: configuration, api: .openAICompletions, runtime: runtime),
            exchange: exchange,
            defaultBaseURL: "https://api.x.ai/v1"
        )
        if runtime.api == .openAIResponses {
            self.responses = OpenAIResponsesEngine(
                settings: ProviderEndpointSettings(providerID: id, service: configuration, api: .openAIResponses, runtime: runtime),
                exchange: exchange
            )
        } else {
            self.responses = nil
        }
    }

    /// Contract v2 features of the active engine.
    public var capabilities: ModelProviderCapabilities {
        self.responses == nil ? OpenAIChatCompletionsEngine.capabilities : OpenAIResponsesEngine.capabilities
    }

    /// Generates a response from xAI.
    /// - Parameter request: Model generation request.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try self.validate()
        if let responses {
            return try await responses.generate(request)
        }
        return try await self.completions.generate(request)
    }

    /// Streams chunks from xAI.
    /// - Parameter request: Model generation request.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        do {
            try self.validate()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        if let responses {
            return responses.stream(request)
        }
        return self.completions.stream(request)
    }

    private func validate() throws {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("xAI model provider is disabled")
        }
        switch self.configuration.authMode {
        case .none, .awsSDK:
            throw OpenClawCoreError.invalidConfiguration("xAI provider requires token-based authentication")
        case .apiKey, .bearerToken, .oauthToken:
            return
        }
    }
}
