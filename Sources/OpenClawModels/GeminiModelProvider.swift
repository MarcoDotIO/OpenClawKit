import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// HTTP transport contract used by Gemini model provider.
public protocol GeminiHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: GeminiHTTPTransport {}

private struct GeminiGenerateContentRequest: Encodable, Sendable {
    struct Content: Encodable, Sendable {
        let role: String
        let parts: [GeminiInputPart]
    }

    let contents: [Content]
}

private struct GeminiGenerateContentResponse: Codable, Sendable {
    struct Candidate: Codable, Sendable {
        struct CandidateContent: Codable, Sendable {
            struct Part: Codable, Sendable {
                let text: String?
            }

            let parts: [Part]
        }

        let content: CandidateContent?
    }

    let candidates: [Candidate]?
}

/// Gemini provider using the generateContent endpoint.
public struct GeminiModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "gemini"

    /// Provider identifier.
    public let id: String

    private let configuration: GeminiModelConfig
    private let transport: any GeminiHTTPTransport

    /// Creates a Gemini provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider configuration.
    ///   - transport: HTTP transport implementation.
    public init(
        id: String = GeminiModelProvider.providerID,
        configuration: GeminiModelConfig,
        transport: any GeminiHTTPTransport = HTTPClient()
    ) {
        self.id = id
        self.configuration = configuration
        self.transport = transport
    }

    /// Generates text via Gemini generateContent API.
    /// - Parameter request: Generation request.
    /// - Returns: Generation response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("Gemini model provider is disabled")
        }
        let apiKey = try ProviderRequestResolution.resolveAPIKey(
            configured: self.configuration.apiKey,
            request: request,
            providerID: self.id
        )
        let modelID = request.resolvedModelID ?? self.configuration.modelID
        let endpoint = try self.resolveEndpoint(modelID: modelID, apiKey: apiKey)
        let payload = GeminiGenerateContentRequest(contents: [self.buildContent(from: request)])

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ProviderRequestResolution.applyHeaders(request.resolvedRequestHeaders, request: &urlRequest)
        urlRequest.timeoutInterval = 30
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let response = try await self.transport.data(for: urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Gemini request failed with status \(response.statusCode)")
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: response.body)
        guard let rawText = decoded.candidates?.first?.content?.parts.first?.text else {
            throw OpenClawCoreError.unavailable("Gemini response did not include generated text")
        }
        let text = rawText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !text.isEmpty
        else {
            throw OpenClawCoreError.unavailable("Gemini response did not include generated text")
        }

        return ModelGenerationResponse(text: text, providerID: self.id, modelID: modelID)
    }

    private func buildContent(from request: ModelGenerationRequest) -> GeminiGenerateContentRequest.Content {
        let systemPrompt = request.systemPrompt?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        let prompt: String
        if systemPrompt.isEmpty {
            prompt = request.prompt
        } else {
            prompt = "\(systemPrompt)\n\nUser:\n\(request.prompt)"
        }
        return GeminiGenerateContentRequest.Content(
            role: "user",
            parts: GeminiMultimodalSupport.parts(prompt: prompt, attachments: request.attachments)
        )
    }

    private func resolveEndpoint(modelID: String, apiKey: String) throws -> URL {
        let baseRaw = self.configuration.baseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !baseRaw.isEmpty, let baseURL = URL(string: baseRaw) else {
            throw OpenClawCoreError.invalidConfiguration("Gemini base URL is invalid")
        }
        let path = "models/\(modelID):generateContent"
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw OpenClawCoreError.invalidConfiguration("Gemini endpoint is invalid")
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw OpenClawCoreError.invalidConfiguration("Gemini endpoint is invalid")
        }
        return url
    }
}
