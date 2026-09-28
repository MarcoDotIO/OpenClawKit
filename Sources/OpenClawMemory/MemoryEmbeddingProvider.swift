import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Whether an embedding is computed for a search query or an indexed document.
public enum MemoryEmbeddingInputType: String, Codable, Sendable, Equatable {
    /// Search query.
    case query
    /// Indexed document chunk.
    case document
}

/// Computes embeddings for semantic memory search.
public protocol MemoryEmbeddingProvider: Sendable {
    /// Provider identifier (`natural-language`, `openai-compatible`, …).
    var id: String { get }
    /// Model identifier.
    var model: String { get }
    /// Vector dimensions (0 when unknown until the first call).
    var dimensions: Int { get }

    /// Embeds texts.
    /// - Parameters:
    ///   - texts: Inputs.
    ///   - inputType: Query or document.
    /// - Returns: One vector per input.
    func embed(_ texts: [String], inputType: MemoryEmbeddingInputType) async throws -> [[Float]]
}

/// Error raised when an explicitly configured embedding provider cannot serve requests.
public struct MemoryUnavailableError: Error, LocalizedError, Sendable, Equatable {
    /// Provider identifier.
    public let provider: String
    /// Reason.
    public let reason: String

    /// Creates the error.
    /// - Parameters:
    ///   - provider: Provider.
    ///   - reason: Reason.
    public init(provider: String, reason: String) {
        self.provider = provider
        self.reason = reason
    }

    /// Human-readable description.
    public var errorDescription: String? {
        "Memory search provider \(self.provider) is unavailable: \(self.reason)"
    }
}

/// HTTP transport for ``OpenAICompatibleEmbeddingProvider`` (inject a stub in tests).
public protocol MemoryEmbeddingHTTPTransport: Sendable {
    /// Performs a request.
    /// - Parameter request: URL request.
    /// - Returns: Response data.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: MemoryEmbeddingHTTPTransport {}

/// OpenAI-compatible `POST {baseURL}/v1/embeddings` provider.
public struct OpenAICompatibleEmbeddingProvider: MemoryEmbeddingProvider {
    /// Provider identifier.
    public let id = "openai-compatible"
    /// Model identifier.
    public let model: String
    /// Vector dimensions (from ``outputDimensionality`` when set).
    public let dimensions: Int
    private let baseURL: URL
    private let apiKey: String?
    private let headers: [String: String]
    private let queryInputType: String?
    private let documentInputType: String?
    private let outputDimensionality: Int?
    private let transport: any MemoryEmbeddingHTTPTransport

    /// Creates the provider.
    /// - Parameters:
    ///   - baseURL: API base URL (`/v1/embeddings` is appended unless the path already ends in `/v1`).
    ///   - model: Model.
    ///   - apiKey: Bearer token.
    ///   - headers: Extra headers.
    ///   - queryInputType: `input_type` sent for queries.
    ///   - documentInputType: `input_type` sent for documents.
    ///   - outputDimensionality: Requested `dimensions`.
    ///   - transport: HTTP transport.
    public init(
        baseURL: URL,
        model: String,
        apiKey: String? = nil,
        headers: [String: String] = [:],
        queryInputType: String? = nil,
        documentInputType: String? = nil,
        outputDimensionality: Int? = nil,
        transport: (any MemoryEmbeddingHTTPTransport)? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.headers = headers
        self.queryInputType = queryInputType
        self.documentInputType = documentInputType
        self.outputDimensionality = outputDimensionality
        self.dimensions = outputDimensionality ?? 0
        self.transport = transport ?? HTTPClient()
    }

    /// Embeds texts through the embeddings endpoint.
    public func embed(_ texts: [String], inputType: MemoryEmbeddingInputType) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var base = self.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let endpoint = base.hasSuffix("/v1") ? base + "/embeddings" : base + "/v1/embeddings"
        guard let url = URL(string: endpoint) else {
            throw MemoryUnavailableError(provider: self.id, reason: "invalid base URL")
        }
        var body: [String: AnyCodable] = [
            "model": AnyCodable(self.model),
            "input": AnyCodable(texts.map { AnyCodable($0) }),
            "encoding_format": AnyCodable("float"),
        ]
        if let label = inputType == .query ? self.queryInputType : self.documentInputType {
            body["input_type"] = AnyCodable(label)
        }
        if let outputDimensionality { body["dimensions"] = AnyCodable(outputDimensionality) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (key, value) in self.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONEncoder().encode(AnyCodable(body))
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw MemoryUnavailableError(provider: self.id, reason: "HTTP \(response.statusCode)")
        }
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: response.body)
        let rows = decoded.dictionaryValue?["data"]?.arrayValue ?? []
        let ordered = rows.sorted { ($0.dictionaryValue?["index"]?.intValue ?? 0) < ($1.dictionaryValue?["index"]?.intValue ?? 0) }
        let vectors = ordered.map { row in (row.dictionaryValue?["embedding"]?.arrayValue ?? []).map { Float($0.doubleValue ?? 0) } }
        guard vectors.count == texts.count else {
            throw MemoryUnavailableError(provider: self.id, reason: "expected \(texts.count) embeddings, got \(vectors.count)")
        }
        return vectors
    }
}

#if canImport(NaturalLanguage)
/// On-device sentence embeddings from the NaturalLanguage framework.
///
/// Picks the sentence embedding for the language of each text (dominant language via
/// `NLLanguageRecognizer`, falling back to ``fallbackLanguage``); inputs in languages without an
/// embedding throw ``MemoryUnavailableError`` so the engine can degrade to keyword search.
public struct NaturalLanguageEmbeddingProvider: MemoryEmbeddingProvider {
    /// Provider identifier.
    public let id = "natural-language"
    /// Language used when detection fails.
    public let fallbackLanguage: NLLanguage

    /// Creates the provider.
    /// - Parameter fallbackLanguage: Fallback language (default English).
    public init(fallbackLanguage: NLLanguage = .english) {
        self.fallbackLanguage = fallbackLanguage
    }

    /// Model identifier (`sentence-<language>`).
    public var model: String {
        "sentence-\(self.fallbackLanguage.rawValue)"
    }

    /// Dimensions of the fallback-language embedding (0 when unavailable).
    public var dimensions: Int {
        NLEmbedding.sentenceEmbedding(for: self.fallbackLanguage)?.dimension ?? 0
    }

    /// Whether an embedding exists for the fallback language on this device.
    public var isAvailable: Bool {
        NLEmbedding.sentenceEmbedding(for: self.fallbackLanguage) != nil
    }

    /// Embeds texts with the fallback-language sentence embedding (all vectors share one space).
    public func embed(_ texts: [String], inputType _: MemoryEmbeddingInputType) async throws -> [[Float]] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: self.fallbackLanguage) else {
            throw MemoryUnavailableError(provider: self.id, reason: "no sentence embedding for \(self.fallbackLanguage.rawValue)")
        }
        return try texts.map { text in
            guard let vector = embedding.vector(for: text) else {
                throw MemoryUnavailableError(provider: self.id, reason: "embedding failed")
            }
            return vector.map(Float.init)
        }
    }

    /// Dominant language of a text.
    /// - Parameter text: Text.
    /// - Returns: Detected language, if any.
    public static func dominantLanguage(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }
}
#endif
