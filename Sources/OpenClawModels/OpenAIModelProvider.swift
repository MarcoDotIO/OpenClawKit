import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(OpenAIKit)
import OpenAIKit
#endif
import OpenClawCore

/// OpenAI-backed model provider using the chat completions API.
public struct OpenAIModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "openai"

    /// Provider identifier.
    public let id: String
    private let configuration: OpenAIModelConfig
    private let legacyTransport: any OpenAICompatibleHTTPTransport
    private let clientFactory: OpenAIKitChatClientFactory

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
        self.init(
            id: id,
            configuration: configuration,
            legacyTransport: httpClient,
            clientFactory: { providerID, resolved in
                try OpenAIKitClientFactory.makeChatClient(providerID: providerID, resolved: resolved)
            }
        )
    }

    init(
        id: String = OpenAIModelProvider.providerID,
        configuration: OpenAIModelConfig,
        legacyTransport: any OpenAICompatibleHTTPTransport,
        clientFactory: @escaping OpenAIKitChatClientFactory
    ) {
        self.id = id
        self.configuration = configuration
        self.legacyTransport = legacyTransport
        self.clientFactory = clientFactory
    }

    /// Generates text via OpenAI chat completions.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generation response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("OpenAI model provider is disabled")
        }
        let resolved = try OpenAIKitClientFactory.resolve(
            providerID: self.id,
            configuration: self.configuration,
            request: request
        )

        #if canImport(OpenAIKit)
        if request.attachments.isEmpty {
            return try await self.generateViaOpenAIKit(request: request, resolved: resolved)
        }
        #endif

        return try await self.generateLegacy(request: request, resolved: resolved)
    }

    #if canImport(OpenAIKit)
    private func generateViaOpenAIKit(
        request: ModelGenerationRequest,
        resolved: OpenAIKitResolvedRequest
    ) async throws -> ModelGenerationResponse {
        do {
            let client = try self.clientFactory(self.id, resolved)
            let response = try await client.generateChatCompletion(
                parameters: Self.buildChatParameters(from: request, resolved: resolved)
            )
            guard let content = response.choices.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty
            else {
                throw OpenClawCoreError.unavailable("OpenAI response did not include message content")
            }
            return ModelGenerationResponse(
                text: content,
                providerID: self.id,
                modelID: resolved.modelID
            )
        } catch {
            throw OpenAIKitErrorNormalizer.normalize(error, providerID: self.id)
        }
    }
    #endif

    private func generateLegacy(
        request: ModelGenerationRequest,
        resolved: OpenAIKitResolvedRequest
    ) async throws -> ModelGenerationResponse {
        var endpoint = resolved.baseURL
        endpoint = endpoint.appendingPathComponent("chat").appendingPathComponent("completions")
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
            model: resolved.modelID,
            messages: messages
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if case .bearerToken(let token) = resolved.authorization {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let organizationID = resolved.organizationID {
            urlRequest.setValue(organizationID, forHTTPHeaderField: "OpenAI-Organization")
        }
        if let projectID = resolved.projectID {
            urlRequest.setValue(projectID, forHTTPHeaderField: "OpenAI-Project")
        }
        ProviderRequestResolution.applyHeaders(resolved.requestOptions.additionalHeaders, request: &urlRequest)
        urlRequest.timeoutInterval = resolved.requestOptions.timeoutInterval
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let response = try await self.legacyTransport.data(for: urlRequest)
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
            modelID: decoded.model.isEmpty ? resolved.modelID : decoded.model
        )
    }

    #if canImport(OpenAIKit)
    private static func buildChatParameters(
        from request: ModelGenerationRequest,
        resolved: OpenAIKitResolvedRequest
    ) -> ChatParameters {
        var messages: [ChatMessage] = []
        let systemPrompt = request.systemPrompt?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        if !systemPrompt.isEmpty {
            messages.append(ChatMessage(role: .system, content: systemPrompt))
        }
        messages.append(ChatMessage(role: .user, content: request.prompt))

        return ChatParameters(
            model: .gpt4,
            customModel: resolved.modelID,
            messages: messages,
            temperature: request.policy.temperature ?? 1,
            topP: request.policy.topP ?? 1,
            stream: false,
            maxCompletionTokens: request.policy.maxTokens,
            maxTokens: request.policy.maxTokens
        )
    }
    #endif
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
