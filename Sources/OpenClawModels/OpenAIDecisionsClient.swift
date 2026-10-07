import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// HTTP failure from Decisions, with redacted API details and retry metadata.
public struct OpenAIDecisionsHTTPError: Error, LocalizedError, Sendable {
    /// HTTP status code.
    public let statusCode: Int
    /// Optional OpenAI error code, such as `insufficient_quota`.
    public let code: String?
    /// Optional OpenAI error type.
    public let type: String?
    /// Redacted provider message, when present.
    public let message: String?
    /// OpenAI request id for support and diagnostics.
    public let requestID: String?
    /// Raw `Retry-After` header (seconds or HTTP date); the client does not retry automatically.
    public let retryAfter: String?

    /// Human-readable failure without request bodies or credentials.
    public var errorDescription: String? {
        "OpenAI Decisions request failed with status \(self.statusCode)" + (self.message.map { ": \($0)" } ?? "")
    }
}

/// Client for OpenAI's official `POST /v1/decisions` API on Apple platforms and Linux.
///
/// Uses an OpenAI Platform API key. Load `.env` into the host process before using the environment
/// initializer. Decisions has a separate typed contract from `ModelProvider` text generation;
/// questions return predicate, choice, score, or refusal answers and do not stream or call tools.
public struct OpenAIDecisionsClient: Sendable {
    /// HTTP endpoint and account-scoping options.
    public struct Options: Sendable, Equatable {
        /// API base URL; `/decisions` is appended to its path.
        public var baseURL: URL
        /// Optional OpenAI organization scope.
        public var organizationID: String?
        /// Optional OpenAI project scope.
        public var projectID: String?
        /// Request timeout in seconds, greater than zero.
        public var timeoutInterval: TimeInterval

        /// Creates options for the official Platform endpoint or an explicitly configured gateway.
        public init(
            baseURL: URL = URL(string: "https://api.openai.com/v1")!,
            organizationID: String? = nil,
            projectID: String? = nil,
            timeoutInterval: TimeInterval = 120
        ) {
            self.baseURL = baseURL
            self.organizationID = organizationID
            self.projectID = projectID
            self.timeoutInterval = timeoutInterval
        }
    }

    /// Endpoint and account-scoping options.
    public let options: Options
    private let apiKey: String
    private let transport: any OpenAICompatibleHTTPTransport

    /// Creates a client with an explicit API key and injectable HTTP transport.
    public init(
        apiKey: String,
        options: Options = Options(),
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("OpenAI Decisions needs OPENAI_API_KEY")
        }
        guard let components = URLComponents(url: options.baseURL, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              options.timeoutInterval.isFinite, options.timeoutInterval > 0 else {
            throw OpenClawCoreError.invalidConfiguration("OpenAI Decisions needs a valid base URL and positive timeout")
        }
        self.apiKey = key
        self.options = options
        self.transport = transport
    }

    /// Creates a client from `OPENAI_API_KEY` in the host environment (for example, sourced `.env`).
    /// - Parameters:
    ///   - environment: Environment containing the API key; never persisted or logged.
    ///   - options: Endpoint and account-scoping options.
    ///   - transport: HTTP transport.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        options: Options = Options(),
        transport: any OpenAICompatibleHTTPTransport = HTTPClient()
    ) throws {
        try self.init(apiKey: environment["OPENAI_API_KEY"] ?? "", options: options, transport: transport)
    }

    /// Evaluates shared text/image evidence and returns ordered typed answers and usage.
    /// - Parameter request: Model, evidence, and questions.
    /// - Returns: Answers, including per-question refusals, and token usage.
    public func create(_ request: OpenAIDecisionRequest) async throws -> OpenAIDecisionResponse {
        try request.validate()
        try Task.checkCancellation()
        var urlRequest = URLRequest(url: self.options.baseURL.appendingPathComponent("decisions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = self.options.timeoutInterval
        urlRequest.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(self.options.organizationID, forHTTPHeaderField: "OpenAI-Organization")
        urlRequest.setValue(self.options.projectID, forHTTPHeaderField: "OpenAI-Project")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        let response: HTTPResponseData
        do {
            response = try await self.transport.data(for: urlRequest)
        } catch {
            throw ProviderErrorRedaction.sanitize(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw self.httpError(response)
        }
        let decision: OpenAIDecisionResponse
        do {
            decision = try JSONDecoder().decode(OpenAIDecisionResponse.self, from: response.body)
        } catch {
            throw OpenClawCoreError.unavailable("OpenAI Decisions returned an invalid response")
        }
        guard decision.answers.count == request.questions.count,
              zip(decision.answers, request.questions).allSatisfy({ answer, question in
                  answer.name == question.name && (answer.type == question.type || answer.type == "refusal")
              }) else {
            throw OpenClawCoreError.unavailable("OpenAI Decisions answers did not match the requested questions")
        }
        return decision
    }

    private func httpError(_ response: HTTPResponseData) -> OpenAIDecisionsHTTPError {
        struct Envelope: Decodable {
            struct Detail: Decodable { let code: String?; let type: String?; let message: String? }
            let error: Detail
        }
        let detail = try? JSONDecoder().decode(Envelope.self, from: response.body).error
        func redact(_ text: String?) -> String? {
            text.map { ProviderErrorRedaction.redact($0.replacingOccurrences(of: self.apiKey, with: "[redacted]")) }
        }
        func header(_ name: String) -> String? {
            response.headers.first { $0.key.lowercased() == name }?.value
        }
        return OpenAIDecisionsHTTPError(
            statusCode: response.statusCode, code: redact(detail?.code), type: redact(detail?.type), message: redact(detail?.message),
            requestID: redact(header("x-request-id")), retryAfter: redact(header("retry-after"))
        )
    }
}
