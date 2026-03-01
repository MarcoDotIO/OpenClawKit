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

private struct XAIGenerationRequest: Codable, Sendable {
    let model: String
    let messages: [XAIGenerationMessage]
}

private struct XAIGenerationMessage: Codable, Sendable {
    let role: String
    let content: String
}

private struct XAIGenerationResponse: Codable, Sendable {
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

/// First-class xAI/Grok provider implementation.
public struct XAIModelProvider: ModelProvider {
    /// Canonical provider identifier for xAI.
    public static let providerID = "xai"
    /// Canonical Grok alias identifier.
    public static let grokAliasProviderID = "grok"

    /// Provider identifier.
    public let id: String

    private let configuration: ProviderServiceConfig
    private let transport: any XAIHTTPTransport

    /// Creates an xAI/Grok provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
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
        transport: any XAIHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.configuration = configuration
        self.transport = transport
    }

    /// Generates text using xAI chat completions endpoint.
    /// - Parameter request: Model generation request.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("xAI model provider is disabled")
        }
        let endpoint = try self.resolveEndpoint()
        let modelID = self.resolveModelID(request: request)
        let payload = XAIGenerationRequest(
            model: modelID,
            messages: self.buildMessages(from: request)
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(try self.resolveBearerToken())", forHTTPHeaderField: "Authorization")
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
            throw OpenClawCoreError.unavailable("xAI request failed with status \(response.statusCode)")
        }
        let decoded = try JSONDecoder().decode(XAIGenerationResponse.self, from: response.body)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else {
            throw OpenClawCoreError.unavailable("xAI response did not include message content")
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
        return self.configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "grok-3-mini"
            : self.configuration.modelID
    }

    private func resolveBearerToken() throws -> String {
        switch self.configuration.authMode {
        case .apiKey:
            let apiKey = self.configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !apiKey.isEmpty else {
                throw OpenClawCoreError.invalidConfiguration("xAI API key is required")
            }
            return apiKey
        case .bearerToken, .oauthToken:
            let token = self.configuration.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else {
                throw OpenClawCoreError.invalidConfiguration("xAI access token is required")
            }
            return token
        case .none, .awsSDK:
            throw OpenClawCoreError.invalidConfiguration("xAI provider requires token-based authentication")
        }
    }

    private func buildMessages(from request: ModelGenerationRequest) -> [XAIGenerationMessage] {
        var messages: [XAIGenerationMessage] = []
        let systemPrompt = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !systemPrompt.isEmpty {
            messages.append(XAIGenerationMessage(role: "system", content: systemPrompt))
        }
        messages.append(XAIGenerationMessage(role: "user", content: request.prompt))
        return messages
    }

    private func resolveEndpoint() throws -> URL {
        let baseRaw = self.configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseRaw.isEmpty, let baseURL = URL(string: baseRaw) else {
            throw OpenClawCoreError.invalidConfiguration("xAI base URL is invalid")
        }
        let path = self.configuration.chatCompletionsPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("xAI chat completions path is required")
        }
        var endpoint = baseURL
        for segment in path.split(separator: "/") {
            endpoint = endpoint.appendingPathComponent(String(segment))
        }
        return endpoint
    }
}
