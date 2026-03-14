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

private struct AnthropicMessagesRequest: Encodable, Sendable {
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

private struct AnthropicMessagesResponse: Codable, Sendable {
    struct ContentBlock: Codable, Sendable {
        let type: String
        let text: String?
    }

    let id: String?
    let model: String?
    let content: [ContentBlock]
}

/// Anthropic provider using the v1 messages API.
public struct AnthropicModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "anthropic"

    /// Provider identifier.
    public let id: String

    private let configuration: AnthropicModelConfig
    private let transport: any AnthropicHTTPTransport

    /// Creates an Anthropic provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String = AnthropicModelProvider.providerID,
        configuration: AnthropicModelConfig,
        transport: any AnthropicHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.configuration = configuration
        self.transport = transport
    }

    /// Generates text using Anthropic messages endpoint.
    /// - Parameter request: Generation request.
    /// - Returns: Generation response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("Anthropic model provider is disabled")
        }
        let apiKey = self.configuration.apiKey?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Anthropic API key is required")
        }
        let endpoint = try self.resolveEndpoint()
        let requestedModel = request.metadata["model"]?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let selectedModel = (requestedModel?.isEmpty == false) ? requestedModel! : self.configuration.modelID
        let normalizedSystemPrompt: String?
        if let systemPrompt = request.systemPrompt?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !systemPrompt.isEmpty {
            normalizedSystemPrompt = systemPrompt
        } else {
            normalizedSystemPrompt = nil
        }
        let payload = AnthropicMessagesRequest(
            model: selectedModel,
            maxTokens: self.configuration.maxTokens,
            system: normalizedSystemPrompt,
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
                allowsFastModeDefaults: true
            )
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(self.configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.timeoutInterval = 30
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let response = try await self.transport.data(for: urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Anthropic request failed with status \(response.statusCode)")
        }

        let decoded = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: response.body)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
              !text.isEmpty
        else {
            throw OpenClawCoreError.unavailable("Anthropic response did not include text content")
        }

        return ModelGenerationResponse(
            text: text,
            providerID: self.id,
            modelID: decoded.model ?? payload.model
        )
    }

    private func resolveEndpoint() throws -> URL {
        let baseRaw = self.configuration.baseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !baseRaw.isEmpty, let baseURL = URL(string: baseRaw) else {
            throw OpenClawCoreError.invalidConfiguration("Anthropic base URL is invalid")
        }
        return baseURL.appendingPathComponent("messages")
    }
}
