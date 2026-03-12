import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

private struct OpenAIResponsesRequest: Encodable, Sendable {
    struct InputItem: Encodable, Sendable {
        let role: String
        let content: [InputContent]
    }

    struct InputContent: Encodable, Sendable {
        let type: String
        let text: String?
        let imageURL: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        init(type: String, text: String? = nil, imageURL: String? = nil) {
            self.type = type
            self.text = text
            self.imageURL = imageURL
        }
    }

    struct Reasoning: Encodable, Sendable {
        let effort: String
    }

    let model: String
    let input: [InputItem]
    let instructions: String?
    let stream: Bool
    let store: Bool?
    let serviceTier: String?
    let reasoning: Reasoning?

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case instructions
        case stream
        case store
        case serviceTier = "service_tier"
        case reasoning
    }
}

private struct OpenAIResponsesResponse: Decodable, Sendable {
    struct OutputItem: Decodable, Sendable {
        struct ContentItem: Decodable, Sendable {
            let type: String?
            let text: String?
        }

        let content: [ContentItem]?
    }

    let model: String?
    let outputText: String?
    let output: [OutputItem]?

    private enum CodingKeys: String, CodingKey {
        case model
        case outputText = "output_text"
        case output
    }
}

/// Generic OpenAI Responses API provider used for OpenAI and Codex-style response surfaces.
public struct OpenAIResponsesModelProvider: ModelProvider {
    public let id: String

    private let configuration: ProviderServiceConfig
    private let transport: any OpenAICompatibleHTTPTransport

    public init(
        id: String,
        configuration: ProviderServiceConfig,
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.configuration = configuration
        self.transport = transport
    }

    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("\(self.id) model provider is disabled")
        }

        let endpoint = try self.resolveEndpoint(request: request)
        let payload = OpenAIResponsesRequest(
            model: ProviderRequestResolution.resolveModelID(
                request: request,
                configured: self.configuration.modelID,
                fallback: "gpt-4.1-mini"
            ),
            input: self.buildInput(from: request),
            instructions: ModelGenerationRequest.normalized(request.systemPrompt),
            stream: request.policy.streamTokens || request.policy.codexTransport != .auto,
            store: request.policy.storeResponse,
            serviceTier: request.policy.serviceTier?.rawValue,
            reasoning: request.policy.reasoningEffort.map { .init(effort: $0.rawValue) }
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try self.resolveAuthorizationToken(request: request) {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: response.body)
        let text = Self.resolveText(from: decoded)
        guard !text.isEmpty else {
            throw OpenClawCoreError.unavailable("\(self.id) response did not include text output")
        }
        return ModelGenerationResponse(text: text, providerID: self.id, modelID: decoded.model ?? payload.model)
    }

    private func resolveEndpoint(request: ModelGenerationRequest) throws -> URL {
        let baseURL = try ProviderRequestResolution.resolveBaseURL(
            configured: self.configuration.baseURL,
            request: request,
            providerID: self.id
        )
        let path = self.configuration.chatCompletionsPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let resolvedPath = path.isEmpty || path == "chat/completions" ? "responses" : path
        var endpoint = baseURL
        for segment in resolvedPath.split(separator: "/") {
            endpoint = endpoint.appendingPathComponent(String(segment))
        }
        return endpoint
    }

    private func resolveAuthorizationToken(request: ModelGenerationRequest) throws -> String? {
        switch self.configuration.authMode {
        case .apiKey:
            return try ProviderRequestResolution.resolveAPIKey(
                configured: self.configuration.apiKey,
                request: request,
                providerID: self.id
            )
        case .bearerToken, .oauthToken:
            return try ProviderRequestResolution.resolveAccessToken(
                configured: self.configuration.accessToken,
                request: request,
                providerID: self.id
            )
        case .none:
            return nil
        case .awsSDK:
            throw OpenClawCoreError.invalidConfiguration("\(self.id) does not support aws-sdk auth mode")
        }
    }

    private func buildInput(from request: ModelGenerationRequest) -> [OpenAIResponsesRequest.InputItem] {
        let content = OpenAIStyleMultimodalSupport.userContent(prompt: request.prompt, attachments: request.attachments)
        return [
            .init(
                role: "user",
                content: Self.inputContent(from: content)
            ),
        ]
    }

    private static func inputContent(from content: OpenAIStyleMessageContent) -> [OpenAIResponsesRequest.InputContent] {
        switch content {
        case .text(let text):
            return [.init(type: "input_text", text: text)]
        case .parts(let parts):
            return parts.map { part in
                switch part {
                case .text(let text):
                    return .init(type: "input_text", text: text)
                case .imageDataURL(let dataURL):
                    return .init(type: "input_image", imageURL: dataURL)
                }
            }
        }
    }

    private static func resolveText(from response: OpenAIResponsesResponse) -> String {
        if let outputText = response.outputText?.trimmingCharacters(in: .whitespacesAndNewlines), !outputText.isEmpty {
            return outputText
        }
        let blocks = response.output?.flatMap { $0.content ?? [] } ?? []
        return blocks.compactMap { item in
            guard item.type == nil || item.type == "output_text" || item.type == "text" else {
                return nil
            }
            return item.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
