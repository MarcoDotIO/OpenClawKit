import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// HTTP transport contract used by Bedrock-converse model providers.
public protocol BedrockHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: BedrockHTTPTransport {}

/// Generic Bedrock-converse provider backed by `ProviderServiceConfig`.
///
/// Implements model contract v2 on `POST /model/{modelId}/converse`: transcripts with `toolUse` /
/// `toolResult` blocks, `toolConfig`, usage (including cache reads/writes) and stop reasons.
/// Claude Opus 5, 4.8 and 4.7 (including region-prefixed inference profiles) never receive
/// `temperature`. Requests are not SigV4-signed: `aws-sdk` auth expects a signing proxy or gateway.
/// Streaming yields one final chunk (Converse streaming uses AWS event-stream framing).
public struct BedrockConverseModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "amazon-bedrock"

    /// Provider identifier.
    public let id: String

    private let configuration: ProviderServiceConfig
    private let settings: ProviderEndpointSettings
    private let exchange: ProviderHTTPExchange

    /// Creates a Bedrock-converse provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = BedrockConverseModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .bedrockConverse,
            authMode: .awsSDK,
            modelID: "anthropic.claude-3-5-sonnet",
            baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com"
        ),
        transport: any BedrockHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.id = id
        self.configuration = configuration
        self.settings = ProviderEndpointSettings(providerID: id, service: configuration, api: .bedrockConverseStream, runtime: runtime)
        self.exchange = ProviderHTTPExchange(providerID: id, send: { try await transport.data(for: $0) }, streamingTransport: nil)
    }

    /// Contract v2 features: tools, transcripts, images and reasoning replay (no incremental streaming).
    public var capabilities: ModelProviderCapabilities {
        ModelProviderCapabilities(
            supportsStreaming: false,
            supportsTools: true,
            supportsParallelToolCalls: true,
            supportsJSONSchema: false,
            supportsImages: true,
            supportsReasoning: true,
            supportsTranscript: true
        )
    }

    /// Generates a response using a Bedrock Converse endpoint.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("\(self.id) model provider is disabled")
        }
        if self.settings.runtime.api == nil {
            switch self.configuration.apiStyle {
            case .bedrockConverse, .custom:
                break
            default:
                throw OpenClawCoreError.invalidConfiguration(
                    "\(self.id) requires a bedrock-converse compatible apiStyle"
                )
            }
        }

        let modelID = self.settings.resolvedModelID(for: request)
        let model = self.settings.modelDefinition(for: modelID)
        try ProviderRequestValidation.validate(request, providerID: self.id, model: model)
        let baseURL = try self.settings.resolvedBaseURL(for: request)
        let endpoint = baseURL
            .appendingPathComponent("model")
            .appendingPathComponent(modelID)
            .appendingPathComponent("converse")
        var urlRequest = self.settings.makeJSONRequest(url: endpoint, request: request, model: model, streaming: false)
        try self.applyAuthHeaders(to: &urlRequest, generationRequest: request)
        if let region = ModelGenerationRequest.normalized(self.configuration.region) {
            urlRequest.setValue(region, forHTTPHeaderField: "x-amz-region")
        }
        if let profile = ModelGenerationRequest.normalized(self.configuration.profile) {
            urlRequest.setValue(profile, forHTTPHeaderField: "x-aws-profile")
        }
        ProviderRequestResolution.applyHeaders(self.settings.mergedHeaders(for: request, model: model), request: &urlRequest)
        let payload = BedrockConverseWire.buildPayload(
            request: request,
            modelID: modelID,
            model: model,
            maxTokens: self.settings.maxTokens(for: request, model: model) ?? 8_192
        )
        urlRequest.httpBody = try ProviderWireJSON.encode(payload)
        let response = try await self.exchange.data(for: urlRequest)
        return try BedrockConverseWire.parseResponse(response.body, providerID: self.id, modelID: modelID)
    }

    private func applyAuthHeaders(to request: inout URLRequest, generationRequest: ModelGenerationRequest) throws {
        if self.settings.applyRequestAuthOverride(to: &request) {
            return
        }
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
        case .awsSDK, .none:
            // aws-sdk and none rely on caller/environment provided request signing or gateway-level auth.
            break
        }
    }
}
