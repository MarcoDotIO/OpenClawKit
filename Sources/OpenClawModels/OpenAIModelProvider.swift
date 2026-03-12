import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// OpenAI-backed model provider using the chat completions API.
public struct OpenAIModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "openai"

    /// Provider identifier.
    public let id: String
    private let configuration: OpenAIModelConfig
    private let httpClient: HTTPClient

    /// Creates an OpenAI model provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: OpenAI provider settings.
    ///   - httpClient: HTTP client used for API calls.
    public init(
        id: String = OpenAIModelProvider.providerID,
        configuration: OpenAIModelConfig,
        httpClient: HTTPClient = HTTPClient()
    ) {
        self.id = id
        self.configuration = configuration
        self.httpClient = httpClient
    }

    /// Generates text via OpenAI chat completions.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generation response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("OpenAI model provider is disabled")
        }
        let apiKey = try ProviderRequestResolution.resolveAPIKey(
            configured: self.configuration.apiKey,
            request: request,
            providerID: self.id
        )

        let base = self.configuration.baseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard let baseURL = URL(string: base), !base.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("OpenAI base URL is invalid")
        }

        let endpoint = baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
        var messages: [OpenAIChatMessage] = []
        let systemPrompt = request.systemPrompt?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        if !systemPrompt.isEmpty {
            messages.append(OpenAIChatMessage(role: "system", content: .text(systemPrompt)))
        }
        messages.append(
            OpenAIChatMessage(
                role: "user",
                content: OpenAIStyleMultimodalSupport.userContent(
                    prompt: request.prompt,
                    attachments: request.attachments
                )
            )
        )
        let payload = OpenAIChatCompletionRequest(
            model: request.resolvedModelID ?? self.configuration.modelID,
            messages: messages
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        ProviderRequestResolution.applyHeaders(request.resolvedRequestHeaders, request: &urlRequest)
        urlRequest.timeoutInterval = 30
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let response = try await self.httpClient.data(for: urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("OpenAI request failed with status \(response.statusCode)")
        }

        let decoded = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: response.body)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
              !content.isEmpty
        else {
            throw OpenClawCoreError.unavailable("OpenAI response did not include message content")
        }

        return ModelGenerationResponse(
            text: content,
            providerID: self.id,
            modelID: decoded.model
        )
    }
}

private struct OpenAIChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [OpenAIChatMessage]
}

private struct OpenAIChatMessage: Encodable, Sendable {
    let role: String
    let content: OpenAIStyleMessageContent
}

private struct OpenAIChatCompletionResponse: Codable, Sendable {
    struct Choice: Codable, Sendable {
        struct Message: Codable, Sendable {
            let role: String
            let content: String
        }

        let index: Int
        let message: Message
    }

    let model: String
    let choices: [Choice]
}
