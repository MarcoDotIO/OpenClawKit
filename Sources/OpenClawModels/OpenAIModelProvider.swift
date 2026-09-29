import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(OpenAIKit)
import OpenAIKit
#endif
import OpenClawCore

/// OpenAI-backed model provider using the Chat Completions API.
///
/// Every request uses the contract-v2 Chat Completions engine (see
/// ``ProviderServiceOpenAIModelProvider``) and sends `OpenAI-Organization` / `OpenAI-Project` from
/// request metadata, then provider metadata. OpenAIKit 3.0.0 is not used: it resolves endpoint
/// paths against the host root (`https://api.openai.com/chat/completions`, a 404).
///
/// Providers built by ``ModelProviderFactory`` keep the canonical config's `headers`,
/// `organizationID` and `metadata`.
public struct OpenAIModelProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "openai"

    /// Provider identifier.
    public let id: String
    private let configuration: OpenAIModelConfig
    private let engine: OpenAIChatCompletionsEngine
    private let clientFactory: OpenAIKitChatClientFactory
    private let usesOpenAIKit: Bool

    /// Creates an OpenAI model provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: OpenAI provider settings.
    ///   - httpClient: HTTP client used for API calls (buffered; streams replay the buffered body).
    public init(
        id: String = OpenAIModelProvider.providerID,
        configuration: OpenAIModelConfig,
        httpClient: HTTPClient = HTTPClient()
    ) {
        self.init(
            id: id,
            configuration: configuration,
            legacyTransport: httpClient,
            usesOpenAIKit: false,
            clientFactory: { providerID, resolved in
                try OpenAIKitClientFactory.makeChatClient(providerID: providerID, resolved: resolved)
            }
        )
    }

    /// Creates an OpenAI model provider with an explicit transport and runtime context.
    ///
    /// Every request goes through `transport`.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: OpenAI provider settings.
    ///   - transport: HTTP transport (streams incrementally when it conforms to ``ModelHTTPStreamingTransport``).
    ///   - runtime: Canonical provider config for per-model compat, params and limits.
    public init(
        id: String = OpenAIModelProvider.providerID,
        configuration: OpenAIModelConfig,
        transport: any OpenAICompatibleHTTPTransport,
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.init(
            id: id,
            configuration: configuration,
            legacyTransport: transport,
            runtime: runtime,
            usesOpenAIKit: false,
            clientFactory: { providerID, resolved in
                try OpenAIKitClientFactory.makeChatClient(providerID: providerID, resolved: resolved)
            }
        )
    }

    init(
        id: String = OpenAIModelProvider.providerID,
        configuration: OpenAIModelConfig,
        legacyTransport: any OpenAICompatibleHTTPTransport,
        runtime: ModelProviderRuntimeContext = .empty,
        usesOpenAIKit: Bool = true,
        clientFactory: @escaping OpenAIKitChatClientFactory
    ) {
        self.id = id
        self.configuration = configuration
        self.clientFactory = clientFactory
        self.usesOpenAIKit = usesOpenAIKit
        // OpenAIModelConfig has no headers or metadata; keep the canonical config's (factory-built providers).
        let providerConfig = runtime.providerConfig
        let configuredMetadata = providerConfig?.metadata ?? [:]
        let service = ProviderServiceConfig(
            enabled: configuration.enabled,
            apiStyle: .openAICompletions,
            authMode: .apiKey,
            modelID: configuration.modelID,
            fastMode: configuration.fastMode,
            apiKey: configuration.apiKey,
            baseURL: configuration.baseURL,
            chatCompletionsPath: "chat/completions",
            organizationID: providerConfig?.organizationID,
            headers: providerConfig?.headers ?? [:],
            metadata: configuredMetadata
        )
        self.engine = OpenAIChatCompletionsEngine(
            settings: ProviderEndpointSettings(providerID: id, service: service, api: .openAICompletions, runtime: runtime),
            exchange: ProviderHTTPExchange(
                providerID: id,
                send: { try await legacyTransport.data(for: $0) },
                streamingTransport: legacyTransport as? any ModelHTTPStreamingTransport
            ),
            defaultBaseURL: OpenAIRouteResolution.platformBaseURL,
            extraHeaders: { request in
                var headers: [String: String] = [:]
                if let organization = ProviderRequestResolution.metadataValue(
                    request.metadata,
                    configuredMetadata,
                    keys: ["openai.organizationID", "openai.organizationId"]
                ) {
                    headers["OpenAI-Organization"] = organization
                }
                if let project = ProviderRequestResolution.metadataValue(
                    request.metadata,
                    configuredMetadata,
                    keys: ["openai.projectID", "openai.projectId"]
                ) {
                    headers["OpenAI-Project"] = project
                }
                return headers
            }
        )
    }

    /// Contract v2 features of the Chat Completions engine.
    public var capabilities: ModelProviderCapabilities {
        OpenAIChatCompletionsEngine.capabilities
    }

    /// Generates a response via OpenAI Chat Completions.
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
        if self.usesOpenAIKit, Self.canUseOpenAIKit(request) {
            return try await self.generateViaOpenAIKit(request: request, resolved: resolved)
        }
        #else
        _ = resolved
        #endif

        return try await self.engine.generate(request)
    }

    /// Streams chunks from OpenAI Chat Completions.
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        guard self.configuration.enabled else {
            return AsyncThrowingStream { $0.finish(throwing: OpenClawCoreError.unavailable("OpenAI model provider is disabled")) }
        }
        return self.engine.stream(request)
    }

    static func canUseOpenAIKit(_ request: ModelGenerationRequest) -> Bool {
        request.attachments.isEmpty
            && !ProviderRequestValidation.usesContractV2(request)
            && request.policy.thinkingLevel == nil
            && request.policy.reasoningEffort == nil
            && request.policy.serviceTier == nil
            && request.policy.promptCache == nil
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
            let choice = response.choices.first
            guard let content = choice?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty
            else {
                throw OpenClawCoreError.unavailable("OpenAI response did not include message content")
            }
            let usage = response.usage.map {
                ModelUsage(inputTokens: $0.promptTokens, outputTokens: $0.completionTokens, totalTokens: $0.totalTokens)
            }
            return ModelGenerationResponse(
                text: content,
                providerID: self.id,
                modelID: resolved.modelID,
                usage: usage,
                stopReason: choice?.finishReason.map(ModelStopReason.init(providerValue:))
            )
        } catch {
            throw OpenAIKitErrorNormalizer.normalize(error, providerID: self.id)
        }
    }

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
