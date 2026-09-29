import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// A model available to a Sign in with ChatGPT account (`GET /v1/models`).
public struct ChatGPTPlanModel: Sendable, Equatable, Codable, Identifiable {
    /// Model id to send as `model`.
    public let slug: String
    /// Name to show in model pickers.
    public let displayName: String
    /// Server visibility (`"list"` models belong in pickers).
    public let visibility: String?

    /// Creates a model entry.
    /// - Parameters:
    ///   - slug: Model id.
    ///   - displayName: Display name.
    ///   - visibility: Visibility.
    public init(slug: String, displayName: String, visibility: String?) {
        self.slug = slug
        self.displayName = displayName
        self.visibility = visibility
    }

    /// Identity (the slug).
    public var id: String {
        self.slug
    }

    /// Whether the model should be shown in pickers (`visibility == "list"`).
    public var isListed: Bool {
        self.visibility == "list"
    }

    enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case visibility
    }
}

/// Model provider that runs inference on the user's ChatGPT plan with Sign in with ChatGPT tokens.
///
/// Requests go to `POST https://api.openai.com/v1/responses` with the account's access token and are
/// shaped for plan usage:
/// - always `store: false` and `stream: true`; only `response.completed` counts as success;
/// - the system prompt goes to `instructions` and transcript system messages become `developer`
///   messages (system-role items are rejected);
/// - `temperature`, `top_p`, `max_output_tokens`, `service_tier`, `metadata`, `truncation`, `user`,
///   `previous_response_id` and the other unsupported fields are never sent;
/// - function tools are grouped in one `namespace` tool (``Options/toolNamespace``) and replayed
///   function calls carry that namespace; a named tool choice sends only that tool with
///   `tool_choice: "required"`.
///
/// A `401` refreshes the token once through the `ChatGPTPlanAccessTokenProvider` and retries.
/// Plan errors (`subscription_sharing_*`, `chatpass_v2_*`, direct admission) are thrown as
/// `ChatGPTPlanError` — show the usage-limit UI when `ChatGPTPlanError.isUsageLimit` is set.
public struct ChatGPTPlanModelProvider: ModelProvider {
    /// Default provider identifier.
    public static let providerID = "chatgpt-plan"
    /// Default namespace that holds function tools.
    public static let defaultToolNamespace = "openclaw"

    /// Endpoint and tool-shaping options.
    public struct Options: Sendable, Equatable {
        /// Responses endpoint.
        public var responsesURL: URL
        /// Models endpoint.
        public var modelsURL: URL
        /// Namespace name that groups function tools.
        public var toolNamespace: String
        /// Namespace description shown to the model.
        public var toolNamespaceDescription: String

        /// Creates options.
        /// - Parameters:
        ///   - responsesURL: Responses endpoint.
        ///   - modelsURL: Models endpoint.
        ///   - toolNamespace: Namespace name for function tools.
        ///   - toolNamespaceDescription: Namespace description.
        public init(
            responsesURL: URL = SignInWithChatGPTConfiguration.responsesURL,
            modelsURL: URL = SignInWithChatGPTConfiguration.modelsURL,
            toolNamespace: String = ChatGPTPlanModelProvider.defaultToolNamespace,
            toolNamespaceDescription: String = "Tools provided by the app."
        ) {
            self.responsesURL = responsesURL
            self.modelsURL = modelsURL
            self.toolNamespace = toolNamespace
            self.toolNamespaceDescription = toolNamespaceDescription
        }
    }

    /// Provider identifier.
    public let id: String
    /// Model used when a request does not name one.
    public let defaultModelID: String?
    /// Options.
    public let options: Options
    private let tokenProvider: any ChatGPTPlanAccessTokenProvider
    private let transport: any OpenAICompatibleHTTPTransport & ModelHTTPStreamingTransport

    /// Creates a provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - tokenProvider: Source of plan access tokens (for example a `SignInWithChatGPTSession`).
    ///   - defaultModelID: Model used when a request does not name one (pick from ``listModels(includeHidden:)``).
    ///   - options: Endpoint and tool options.
    ///   - transport: HTTP transport.
    public init(
        id: String = ChatGPTPlanModelProvider.providerID,
        tokenProvider: any ChatGPTPlanAccessTokenProvider,
        defaultModelID: String? = nil,
        options: Options = Options(),
        transport: any OpenAICompatibleHTTPTransport & ModelHTTPStreamingTransport = ModelStreamingHTTPClient()
    ) {
        self.id = id
        self.tokenProvider = tokenProvider
        self.defaultModelID = defaultModelID
        self.options = options
        self.transport = transport
    }

    /// Streaming, namespaced tools, JSON schema, images, reasoning and transcripts.
    public var capabilities: ModelProviderCapabilities {
        ModelProviderCapabilities(
            supportsStreaming: true,
            supportsTools: true,
            supportsParallelToolCalls: true,
            supportsJSONSchema: true,
            supportsImages: true,
            supportsReasoning: true,
            supportsTranscript: true
        )
    }

    /// Generates a response (collected from the stream).
    /// - Parameter request: Generation request.
    /// - Returns: Generated response.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        let modelID = try self.modelID(for: request)
        let response = try await ProviderStreamSupport.collect(self.stream(request, modelID: modelID), providerID: self.id, modelID: modelID)
        guard !response.text.isEmpty || !response.toolCalls.isEmpty || response.stopReason.permitsEmptyOutput else {
            throw OpenClawCoreError.unavailable("\(self.id) response did not include text output")
        }
        return response
    }

    /// Streams a response.
    /// - Parameter request: Generation request.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        do {
            return self.stream(request, modelID: try self.modelID(for: request))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    /// Models available to the signed-in account, in server order.
    /// - Parameter includeHidden: Include models whose visibility is not `"list"`.
    /// - Returns: Models.
    public func listModels(includeHidden: Bool = false) async throws -> [ChatGPTPlanModel] {
        let response = try await self.authorizedData { token in
            var request = URLRequest(url: self.options.modelsURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        }
        guard let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            throw OpenClawCoreError.unavailable("\(self.id) model list is not valid JSON")
        }
        let entries = (object["models"] as? [[String: Any]]) ?? (object["data"] as? [[String: Any]]) ?? []
        let models = entries.compactMap { entry -> ChatGPTPlanModel? in
            guard let slug = (entry["slug"] as? String) ?? (entry["id"] as? String), !slug.isEmpty else { return nil }
            return ChatGPTPlanModel(slug: slug, displayName: (entry["display_name"] as? String) ?? slug, visibility: entry["visibility"] as? String)
        }
        return includeHidden ? models : models.filter(\.isListed)
    }

    // MARK: - Request

    private func modelID(for request: ModelGenerationRequest) throws -> String {
        guard let modelID = ModelGenerationRequest.normalized(request.modelID) ?? ModelGenerationRequest.normalized(self.defaultModelID) else {
            throw OpenClawCoreError.invalidConfiguration("\(self.id) needs a model id; pick one from listModels()")
        }
        return modelID
    }

    func makeURLRequest(body: Data, token: String, request: ModelGenerationRequest) -> URLRequest {
        var urlRequest = URLRequest(url: self.options.responsesURL)
        urlRequest.httpMethod = "POST"
        for (name, value) in request.headers where !Self.reservedHeaders.contains(name.lowercased()) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = body
        return urlRequest
    }

    private static let reservedHeaders: Set<String> = ["authorization", "content-type", "accept", "content-length", "host"]

    private func stream(_ request: ModelGenerationRequest, modelID: String) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        let providerID = self.id
        let body: Data
        do {
            body = try ProviderWireJSON.encode(
                ChatGPTPlanResponsesWire.buildPayload(request: request, modelID: modelID, providerID: providerID, options: self.options)
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let transport = self.transport
        let tokenProvider = self.tokenProvider
        return ProviderStreamSupport.makeStream { continuation in
            var token = try await tokenProvider.chatGPTPlanAccessToken(rejectedAccessToken: nil)
            var response = try await transport.lineStream(for: self.makeURLRequest(body: body, token: token, request: request))
            if response.statusCode == 401 {
                let errorBody = try await Self.collect(response.lines)
                if let planError = ChatGPTPlanError.classify(statusCode: 401, body: errorBody, headers: response.headers), planError.kind != .admissionDenied {
                    throw planError
                }
                token = try await tokenProvider.chatGPTPlanAccessToken(rejectedAccessToken: token)
                response = try await transport.lineStream(for: self.makeURLRequest(body: body, token: token, request: request))
            }
            guard (200..<300).contains(response.statusCode) else {
                let errorBody = try await Self.collect(response.lines)
                throw ChatGPTPlanError.classify(statusCode: response.statusCode, body: errorBody, headers: response.headers)
                    ?? ProviderHTTPExchange.statusError(providerID: providerID, statusCode: response.statusCode, body: errorBody)
            }
            var assembler = ProviderStreamAssembler(providerID: providerID, modelID: modelID)
            var parser = ServerSentEventParser()
            var state = OpenAIResponsesWire.StreamState()
            for try await line in response.lines {
                guard let event = parser.consume(line) else { continue }
                OpenAIResponsesWire.handleStreamEvent(event, state: &state, assembler: &assembler).forEach { continuation.yield($0) }
            }
            if let event = parser.finish() {
                OpenAIResponsesWire.handleStreamEvent(event, state: &state, assembler: &assembler).forEach { continuation.yield($0) }
            }
            if let failure = state.failure {
                throw ChatGPTPlanError.classify(code: state.failureCode, message: failure)
                    ?? OpenClawCoreError.unavailable("\(providerID) response failed: \(failure)")
            }
            guard state.sawEvent else {
                throw OpenClawCoreError.unavailable("\(providerID) stream ended before a terminal response event")
            }
            if let incomplete = state.incompleteReason() {
                throw OpenClawCoreError.unavailable("\(providerID) \(incomplete)")
            }
            continuation.yield(.completed(response: assembler.response()))
        }
    }

    private func authorizedData(_ makeRequest: (String) -> URLRequest) async throws -> HTTPResponseData {
        var token = try await self.tokenProvider.chatGPTPlanAccessToken(rejectedAccessToken: nil)
        var response = try await self.send(makeRequest(token))
        if response.statusCode == 401, ChatGPTPlanError.classify(statusCode: 401, body: response.body).map({ $0.kind == .admissionDenied }) ?? true {
            token = try await self.tokenProvider.chatGPTPlanAccessToken(rejectedAccessToken: token)
            response = try await self.send(makeRequest(token))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ChatGPTPlanError.classify(statusCode: response.statusCode, body: response.body, headers: response.headers)
                ?? ProviderHTTPExchange.statusError(providerID: self.id, statusCode: response.statusCode, body: response.body)
        }
        return response
    }

    private func send(_ request: URLRequest) async throws -> HTTPResponseData {
        do {
            return try await self.transport.data(for: request)
        } catch {
            throw ProviderErrorRedaction.sanitize(error)
        }
    }

    private static func collect(_ lines: AsyncThrowingStream<String, Error>) async throws -> Data {
        var text = ""
        for try await line in lines where text.utf8.count < 65_536 {
            text += line + "\n"
        }
        return Data(text.utf8)
    }
}

/// Request shaping for ChatGPT plan inference.
enum ChatGPTPlanResponsesWire {
    static let platformBaseURL = "https://api.openai.com/v1"

    static func buildPayload(
        request: ModelGenerationRequest,
        modelID: String,
        providerID: String,
        options: ChatGPTPlanModelProvider.Options
    ) -> [String: Any] {
        let context = OpenAIResponsesWire.BuildContext(
            providerID: providerID,
            modelID: modelID,
            model: nil,
            api: .openAIResponses,
            baseURL: self.platformBaseURL,
            policy: OpenAIResponsesPayloadPolicy.resolve(providerID: "openai", api: .openAIResponses, baseURL: self.platformBaseURL, compat: nil),
            stream: true,
            serviceTier: nil,
            maxTokens: nil,
            isChatGPTRoute: false,
            supportsDeveloperRole: true
        )
        var tools = request.tools
        var toolChoice: Any?
        switch request.toolChoice {
        case .auto:
            toolChoice = nil
        case .none:
            toolChoice = "none"
        case .required:
            toolChoice = "required"
        case .named(let name):
            // A namespaced tool cannot be named in `tool_choice`; offer only that tool and require a call.
            tools = tools.filter { $0.name == name }
            toolChoice = tools.isEmpty ? nil : "required"
        }
        let namespace = options.toolNamespace
        let input = OpenAIResponsesWire.buildInput(request: request, context: context).map { item -> [String: Any] in
            guard item["type"] as? String == "function_call" else { return item }
            var item = item
            item["namespace"] = namespace
            return item
        }
        var payload: [String: Any] = [
            "model": modelID,
            "input": input,
            "store": false,
            "stream": true,
            "prompt_cache_key": request.promptCacheKey,
        ]
        if let instructions = ModelGenerationRequest.normalized(request.systemPrompt) {
            payload["instructions"] = instructions
        }
        let functions = OpenAIResponsesWire.buildTools(tools, strictDefault: nil)
        if !functions.isEmpty {
            payload["tools"] = [[
                "type": "namespace",
                "name": namespace,
                "description": options.toolNamespaceDescription,
                "tools": functions,
            ] as [String: Any]]
            if let toolChoice {
                payload["tool_choice"] = toolChoice
            }
        }
        if let format = OpenAIResponsesWire.textFormat(request.responseFormat) {
            payload["text"] = ["format": format]
        }
        if let effort = OpenAIResponsesWire.reasoningEffort(request: request, context: context, tools: tools) {
            var reasoning: [String: Any] = ["effort": effort]
            if effort != "none" {
                reasoning["summary"] = "auto"
            }
            payload["reasoning"] = reasoning
        }
        return payload
    }

    /// Top-level fields ChatGPT plan inference rejects; ``buildPayload(request:modelID:providerID:options:)``
    /// never sets them.
    static let forbiddenFields: Set<String> = [
        "background", "conversation", "max_output_tokens", "max_tool_calls", "metadata", "moderation",
        "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier", "temperature", "top_logprobs",
        "top_p", "truncation", "user", "previous_response_id", "service_tier",
    ]
}
