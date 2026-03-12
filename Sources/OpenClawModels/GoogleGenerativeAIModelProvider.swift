import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

private struct GoogleGenerativeAIRequest: Encodable, Sendable {
    struct Content: Encodable, Sendable {
        let role: String
        let parts: [GeminiInputPart]
    }

    let contents: [Content]
}

private struct GoogleGenerativeAIResponse: Decodable, Sendable {
    struct Candidate: Decodable, Sendable {
        struct Content: Decodable, Sendable {
            struct Part: Decodable, Sendable {
                let text: String?
            }

            let parts: [Part]
        }

        let content: Content?
    }

    let candidates: [Candidate]?
}

/// Generic Google Generative AI provider supporting API-key and OAuth-style auth.
public struct GoogleGenerativeAIModelProvider: ModelProvider {
    public let id: String

    private let configuration: ProviderServiceConfig
    private let transport: any GeminiHTTPTransport

    public init(
        id: String,
        configuration: ProviderServiceConfig,
        transport: any GeminiHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.configuration = configuration
        self.transport = transport
    }

    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("\(self.id) model provider is disabled")
        }
        let modelID = ProviderRequestResolution.resolveModelID(
            request: request,
            configured: self.configuration.modelID,
            fallback: "gemini-2.0-flash"
        )
        var urlRequest = URLRequest(url: try self.resolveEndpoint(modelID: modelID, request: request))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try self.applyAuthorization(to: &urlRequest, request: request)
        ProviderRequestResolution.applyHeaders(
            ProviderRequestResolution.mergedHeaders(configured: self.configuration.headers, request: request),
            request: &urlRequest
        )
        let payload = GoogleGenerativeAIRequest(
            contents: [
                .init(
                    role: "user",
                    parts: GeminiMultimodalSupport.parts(prompt: request.prompt, attachments: request.attachments)
                ),
            ]
        )
        urlRequest.timeoutInterval = 30
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let response = try await self.transport.data(for: urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("\(self.id) request failed with status \(response.statusCode)")
        }
        let decoded = try JSONDecoder().decode(GoogleGenerativeAIResponse.self, from: response.body)
        let text = decoded.candidates?.first?.content?.parts.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw OpenClawCoreError.unavailable("\(self.id) response did not include generated text")
        }
        return ModelGenerationResponse(text: text, providerID: self.id, modelID: modelID)
    }

    private func resolveEndpoint(modelID: String, request: ModelGenerationRequest) throws -> URL {
        let baseRaw = self.configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseRaw.isEmpty, let baseURL = URL(string: baseRaw) else {
            throw OpenClawCoreError.invalidConfiguration("\(self.id) base URL is invalid")
        }
        let path = "models/\(modelID):generateContent"
        let url = baseURL.appendingPathComponent(path)
        guard self.configuration.authMode == .apiKey else {
            return url
        }
        let apiKey = try ProviderRequestResolution.resolveAPIKey(
            configured: self.configuration.apiKey,
            request: request,
            providerID: self.id
        )
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OpenClawCoreError.invalidConfiguration("\(self.id) endpoint is invalid")
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let resolved = components.url else {
            throw OpenClawCoreError.invalidConfiguration("\(self.id) endpoint is invalid")
        }
        return resolved
    }

    private func applyAuthorization(to urlRequest: inout URLRequest, request: ModelGenerationRequest) throws {
        switch self.configuration.authMode {
        case .apiKey:
            break
        case .bearerToken, .oauthToken:
            let token = try ProviderRequestResolution.resolveAccessToken(
                configured: self.configuration.accessToken,
                request: request,
                providerID: self.id
            )
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .awsSDK:
            throw OpenClawCoreError.invalidConfiguration("\(self.id) does not support aws-sdk auth mode")
        case .none:
            break
        }
    }
}
