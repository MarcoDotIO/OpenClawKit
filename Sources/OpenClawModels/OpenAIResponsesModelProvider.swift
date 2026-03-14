import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(OpenAIKit)
import OpenAIKit
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

    struct Text: Encodable, Sendable {
        let verbosity: String
    }

    let model: String
    let input: [InputItem]
    let instructions: String?
    let stream: Bool
    let store: Bool?
    let serviceTier: String?
    let reasoning: Reasoning?
    let text: Text?

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case instructions
        case stream
        case store
        case serviceTier = "service_tier"
        case reasoning
        case text
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
    private let responsesClientFactory: OpenAIKitResponsesClientFactory

    public init(
        id: String,
        configuration: ProviderServiceConfig,
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) {
        self.init(
            id: id,
            configuration: configuration,
            transport: transport,
            responsesClientFactory: { providerID, resolved in
                try OpenAIKitClientFactory.makeResponsesClient(providerID: providerID, resolved: resolved)
            }
        )
    }

    init(
        id: String,
        configuration: ProviderServiceConfig,
        transport: any OpenAICompatibleHTTPTransport,
        responsesClientFactory: @escaping OpenAIKitResponsesClientFactory
    ) {
        self.id = id
        self.configuration = configuration
        self.transport = transport
        self.responsesClientFactory = responsesClientFactory
    }

    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("\(self.id) model provider is disabled")
        }

        let resolved = try OpenAIKitClientFactory.resolve(
            providerID: self.id,
            configuration: self.configuration,
            request: request
        )

        #if canImport(OpenAIKit)
        if self.canUseOpenAIKitResponses(request: request, resolved: resolved) {
            do {
                let client = try self.responsesClientFactory(self.id, resolved)
                let response = try await client.createResponse(
                    parameters: ResponseCreateParameters(
                        model: resolved.modelID,
                        input: request.prompt,
                        instructions: ModelGenerationRequest.normalized(request.systemPrompt)
                    )
                )
                let text = Self.resolveText(from: response)
                guard !text.isEmpty else {
                    throw OpenClawCoreError.unavailable("\(self.id) response did not include text output")
                }
                return ModelGenerationResponse(
                    text: text,
                    providerID: self.id,
                    modelID: response.model ?? resolved.modelID
                )
            } catch {
                throw OpenAIKitErrorNormalizer.normalize(error, providerID: self.id)
            }
        }
        #endif

        return try await self.generateAdvanced(request: request, resolved: resolved)
    }

    private func generateAdvanced(
        request: ModelGenerationRequest,
        resolved: OpenAIKitResolvedRequest
    ) async throws -> ModelGenerationResponse {
        let configuredFastMode = self.configuration.fastMode
        let reasoningEffort = OpenAIFastModeResolution.reasoningEffort(
            request: request,
            configuredFastMode: configuredFastMode
        )
        let serviceTier = OpenAIFastModeResolution.serviceTier(
            providerID: self.id,
            baseURL: resolved.baseURL,
            request: request,
            configuredFastMode: configuredFastMode
        )
        let textVerbosity = OpenAIFastModeResolution.textVerbosity(
            request: request,
            configuredFastMode: configuredFastMode
        )
        let endpoint = self.resolveEndpoint(baseURL: resolved.baseURL)
        let payload = OpenAIResponsesRequest(
            model: resolved.modelID,
            input: self.buildInput(from: request),
            instructions: ModelGenerationRequest.normalized(request.systemPrompt),
            stream: request.policy.streamTokens || request.policy.codexTransport != .auto,
            store: request.policy.storeResponse,
            serviceTier: serviceTier,
            reasoning: reasoningEffort.map { .init(effort: $0.rawValue) },
            text: textVerbosity.map { .init(verbosity: $0) }
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

    #if canImport(OpenAIKit)
    private func canUseOpenAIKitResponses(
        request: ModelGenerationRequest,
        resolved: OpenAIKitResolvedRequest
    ) -> Bool {
        let configuredFastMode = self.configuration.fastMode
        let requiresAdvancedPayload =
            OpenAIFastModeResolution.reasoningEffort(
                request: request,
                configuredFastMode: configuredFastMode
            ) != nil ||
            OpenAIFastModeResolution.serviceTier(
                providerID: self.id,
                baseURL: resolved.baseURL,
                request: request,
                configuredFastMode: configuredFastMode
            ) != nil ||
            OpenAIFastModeResolution.textVerbosity(
                request: request,
                configuredFastMode: configuredFastMode
            ) != nil

        guard resolved.clientConfiguration != nil else {
            return false
        }
        return request.attachments.isEmpty &&
            request.policy.streamTokens == false &&
            request.policy.storeResponse == nil &&
            requiresAdvancedPayload == false &&
            request.policy.codexTransport == .auto
    }
    #endif

    private func resolveEndpoint(baseURL: URL) -> URL {
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

    #if canImport(OpenAIKit)
    private static func resolveText(from response: ResponseObject) -> String {
        response.outputText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    #endif
}
