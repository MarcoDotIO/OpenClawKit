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

private struct BedrockConverseRequest: Codable, Sendable {
    struct ContentBlock: Codable, Sendable {
        let text: String
    }

    struct Message: Codable, Sendable {
        let role: String
        let content: [ContentBlock]
    }

    struct InferenceConfig: Codable, Sendable {
        let maxTokens: Int

        private enum CodingKeys: String, CodingKey {
            case maxTokens = "maxTokens"
        }
    }

    let messages: [Message]
    let system: [ContentBlock]?
    let inferenceConfig: InferenceConfig
}

private struct BedrockConverseResponse: Codable, Sendable {
    struct ContentBlock: Codable, Sendable {
        let text: String?
    }

    struct Message: Codable, Sendable {
        let role: String?
        let content: [ContentBlock]
    }

    struct Output: Codable, Sendable {
        let message: Message?
    }

    let output: Output?
}

/// Generic Bedrock-converse provider backed by `ProviderServiceConfig`.
public struct BedrockConverseModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "amazon-bedrock"

    /// Provider identifier.
    public let id: String

    private let configuration: ProviderServiceConfig
    private let transport: any BedrockHTTPTransport

    /// Creates a Bedrock-converse provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String = BedrockConverseModelProvider.providerID,
        configuration: ProviderServiceConfig = ProviderServiceConfig(
            enabled: false,
            apiStyle: .bedrockConverse,
            authMode: .awsSDK,
            modelID: "anthropic.claude-3-5-sonnet",
            baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com"
        ),
        transport: any BedrockHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.configuration = configuration
        self.transport = transport
    }

    /// Generates text using a Bedrock converse endpoint.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("\(self.id) model provider is disabled")
        }
        switch self.configuration.apiStyle {
        case .bedrockConverse, .custom:
            break
        default:
            throw OpenClawCoreError.invalidConfiguration(
                "\(self.id) requires a bedrock-converse compatible apiStyle"
            )
        }

        let modelID = self.resolveModelID(request: request)
        let endpoint = try self.resolveEndpoint(modelID: modelID)
        let payload = BedrockConverseRequest(
            messages: [.init(role: "user", content: [.init(text: request.prompt)])],
            system: self.resolveSystemPrompt(request: request),
            inferenceConfig: .init(maxTokens: self.resolveMaxTokens())
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try self.applyAuthHeaders(to: &urlRequest, generationRequest: request)
        if let region = self.configuration.region?.trimmingCharacters(in: .whitespacesAndNewlines),
           !region.isEmpty
        {
            urlRequest.setValue(region, forHTTPHeaderField: "x-amz-region")
        }
        if let profile = self.configuration.profile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !profile.isEmpty
        {
            urlRequest.setValue(profile, forHTTPHeaderField: "x-aws-profile")
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

        let decoded = try JSONDecoder().decode(BedrockConverseResponse.self, from: response.body)
        guard let text = decoded.output?.message?.content.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            throw OpenClawCoreError.unavailable("\(self.id) response did not include text content")
        }
        return ModelGenerationResponse(
            text: text,
            providerID: self.id,
            modelID: modelID
        )
    }

    private func resolveModelID(request: ModelGenerationRequest) -> String {
        ProviderRequestResolution.resolveModelID(
            request: request,
            configured: self.configuration.modelID,
            fallback: "anthropic.claude-3-5-sonnet"
        )
    }

    private func resolveSystemPrompt(request: ModelGenerationRequest) -> [BedrockConverseRequest.ContentBlock]? {
        let systemPrompt = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if systemPrompt.isEmpty {
            return nil
        }
        return [.init(text: systemPrompt)]
    }

    private func resolveMaxTokens() -> Int {
        let metadataValue = self.configuration.metadata["maxTokens"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let parsed = Int(metadataValue), parsed > 0 {
            return parsed
        }
        return 8_192
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
        case .awsSDK, .none:
            // aws-sdk and none rely on caller/environment provided request signing or gateway-level auth.
            break
        }
    }

    private func resolveEndpoint(modelID: String) throws -> URL {
        let baseRaw = self.configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseRaw.isEmpty, let baseURL = URL(string: baseRaw) else {
            throw OpenClawCoreError.invalidConfiguration("\(self.id) base URL is invalid")
        }
        return baseURL
            .appendingPathComponent("model")
            .appendingPathComponent(modelID)
            .appendingPathComponent("converse")
    }
}
