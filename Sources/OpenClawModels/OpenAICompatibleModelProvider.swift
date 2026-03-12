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

private struct OpenAICompatibleChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [OpenAICompatibleChatMessage]
}

private struct OpenAICompatibleChatMessage: Encodable, Sendable {
    let role: String
    let content: OpenAIStyleMessageContent
}

private struct OpenAICompatibleChatCompletionResponse: Codable, Sendable {
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

/// Generic OpenAI-compatible provider for compatible chat completion APIs.
public struct OpenAICompatibleModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "openai-compatible"

    /// Provider identifier.
    public let id: String

    private let configuration: OpenAICompatibleModelConfig
    private let transport: any OpenAICompatibleHTTPTransport

    /// Creates an OpenAI-compatible provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String = OpenAICompatibleModelProvider.providerID,
        configuration: OpenAICompatibleModelConfig,
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.configuration = configuration
        self.transport = transport
    }

    /// Generates text from a chat completion endpoint.
    /// - Parameter request: Generation request.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("OpenAI-compatible provider is disabled")
        }
        let apiKey = try ProviderRequestResolution.resolveAPIKey(
            configured: self.configuration.apiKey,
            request: request,
            providerID: self.id
        )

        let endpoint = try self.resolveEndpoint()
        let selectedModel = request.resolvedModelID ?? self.configuration.modelID
        let payload = OpenAICompatibleChatCompletionRequest(
            model: selectedModel,
            messages: self.buildMessages(from: request)
        )
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        ProviderRequestResolution.applyHeaders(request.resolvedRequestHeaders, request: &urlRequest)
        urlRequest.timeoutInterval = 30
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let response = try await self.transport.data(for: urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("OpenAI-compatible request failed with status \(response.statusCode)")
        }

        let decoded = try JSONDecoder().decode(OpenAICompatibleChatCompletionResponse.self, from: response.body)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
              !content.isEmpty
        else {
            throw OpenClawCoreError.unavailable("OpenAI-compatible response did not include message content")
        }
        return ModelGenerationResponse(
            text: content,
            providerID: self.id,
            modelID: decoded.model ?? self.configuration.modelID
        )
    }

    private func buildMessages(from request: ModelGenerationRequest) -> [OpenAICompatibleChatMessage] {
        var messages: [OpenAICompatibleChatMessage] = []
        let systemPrompt = request.systemPrompt?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        if !systemPrompt.isEmpty {
            messages.append(OpenAICompatibleChatMessage(role: "system", content: .text(systemPrompt)))
        }
        messages.append(
            OpenAICompatibleChatMessage(
                role: "user",
                content: OpenAIStyleMultimodalSupport.userContent(
                    prompt: request.prompt,
                    attachments: request.attachments
                )
            )
        )
        return messages
    }

    private func resolveEndpoint() throws -> URL {
        let rawBase = self.configuration.baseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !rawBase.isEmpty, let baseURL = URL(string: rawBase) else {
            throw OpenClawCoreError.invalidConfiguration("OpenAI-compatible base URL is invalid")
        }

        let path = self.configuration.chatCompletionsPath
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("OpenAI-compatible chat path is required")
        }
        var endpoint = baseURL
        for segment in path.split(separator: "/") {
            endpoint = endpoint.appendingPathComponent(String(segment))
        }
        return endpoint
    }
}
