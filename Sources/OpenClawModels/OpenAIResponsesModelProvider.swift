import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(OpenAIKit)
import OpenAIKit
#endif
import OpenClawCore
import OpenClawProtocol

/// OpenAI Responses API provider for the OpenAI Platform, the ChatGPT/Codex OAuth route, Azure OpenAI
/// and Responses-compatible third parties.
///
/// Implements model contract v2 (input items for transcripts, function tools and tool choice,
/// `text.format` JSON schema, function calls, usage, stop reasons, reasoning summaries and SSE
/// streaming). Payloads follow ``OpenAIResponsesPayloadPolicy``: `instructions` only on verified
/// routes, `store` only on native OpenAI/Azure routes, prompt-cache fields stripped on proxies.
///
/// - The ChatGPT route (API `openai-chatgpt-responses`, base `https://chatgpt.com/backend-api/codex`)
///   always streams, sends `store: false`, `instructions`, `include: ["reasoning.encrypted_content"]`
///   and the `chatgpt-account-id` / `originator` headers.
/// - Azure (`azure-openai-responses`) adds `api-version` and authenticates API keys with `api-key`.
/// - Every request goes through `transport`. OpenAIKit 3.0.0 is not used: it resolves endpoint
///   paths against the host root (`https://api.openai.com/responses`, a 404), and its response
///   model has no `output` items, so it cannot read Responses text.
public struct OpenAIResponsesModelProvider: ModelProvider {
    /// Provider identifier.
    public let id: String

    private let configuration: ProviderServiceConfig
    private let engine: OpenAIResponsesEngine
    private let responsesClientFactory: OpenAIKitResponsesClientFactory
    /// Whether simple text requests may use the injected OpenAIKit client (internal test hook).
    private let usesOpenAIKit: Bool

    /// Creates a Responses provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Provider service configuration.
    ///   - transport: HTTP transport implementation.
    ///   - runtime: Canonical provider config and effective API (`openai-responses`,
    ///     `openai-chatgpt-responses` or `azure-openai-responses`).
    public init(
        id: String,
        configuration: ProviderServiceConfig,
        transport: any OpenAICompatibleHTTPTransport = ModelStreamingHTTPClient(),
        runtime: ModelProviderRuntimeContext = .empty
    ) {
        self.init(
            id: id,
            configuration: configuration,
            transport: transport,
            runtime: runtime,
            usesOpenAIKit: false,
            responsesClientFactory: { providerID, resolved in
                try OpenAIKitClientFactory.makeResponsesClient(providerID: providerID, resolved: resolved)
            }
        )
    }

    init(
        id: String,
        configuration: ProviderServiceConfig,
        transport: any OpenAICompatibleHTTPTransport,
        runtime: ModelProviderRuntimeContext = .empty,
        usesOpenAIKit: Bool = true,
        responsesClientFactory: @escaping OpenAIKitResponsesClientFactory
    ) {
        self.id = id
        self.configuration = configuration
        self.usesOpenAIKit = usesOpenAIKit
        let api = runtime.api ?? .openAIResponses
        self.engine = OpenAIResponsesEngine(
            settings: ProviderEndpointSettings(providerID: id, service: configuration, api: api, runtime: runtime),
            exchange: ProviderHTTPExchange(
                providerID: id,
                send: { try await transport.data(for: $0) },
                streamingTransport: transport as? any ModelHTTPStreamingTransport
            )
        )
        self.responsesClientFactory = responsesClientFactory
    }

    /// Contract v2 features of the Responses engine.
    public var capabilities: ModelProviderCapabilities {
        OpenAIResponsesEngine.capabilities
    }

    /// Generates a response from the Responses API.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generated response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("\(self.id) model provider is disabled")
        }

        #if canImport(OpenAIKit)
        if self.usesOpenAIKit {
            let resolved = try OpenAIKitClientFactory.resolve(providerID: self.id, configuration: self.configuration, request: request)
            if self.canUseOpenAIKitResponses(request: request, resolved: resolved) {
                return try await self.generateViaOpenAIKit(request: request, resolved: resolved)
            }
        }
        #endif

        return try await self.engine.generate(request)
    }

    /// Streams chunks from the Responses API (SSE).
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        self.engine.stream(request)
    }

    #if canImport(OpenAIKit)
    private func generateViaOpenAIKit(
        request: ModelGenerationRequest,
        resolved: OpenAIKitResolvedRequest
    ) async throws -> ModelGenerationResponse {
        do {
            let client = try self.responsesClientFactory(self.id, resolved)
            let response = try await client.createResponse(
                parameters: ResponseCreateParameters(
                    model: resolved.modelID,
                    input: request.prompt,
                    instructions: ModelGenerationRequest.normalized(request.systemPrompt)
                )
            )
            let text = response.outputText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw OpenClawCoreError.unavailable("\(self.id) response did not include text output")
            }
            return ModelGenerationResponse(
                text: text,
                providerID: self.id,
                modelID: response.model ?? resolved.modelID,
                stopReason: response.status == "incomplete" ? .length : .stop
            )
        } catch {
            throw OpenAIKitErrorNormalizer.normalize(error, providerID: self.id)
        }
    }

    private func canUseOpenAIKitResponses(
        request: ModelGenerationRequest,
        resolved: OpenAIKitResolvedRequest
    ) -> Bool {
        guard resolved.clientConfiguration != nil else {
            return false
        }
        let settings = self.engine.settings
        let baseURL = settings.resolvedBaseURLString(for: request, defaultBaseURL: OpenAIRouteResolution.platformBaseURL)
        guard settings.api == .openAIResponses, !self.engine.isChatGPTRoute(baseURL: baseURL) else {
            return false
        }
        let policy = OpenAIResponsesPayloadPolicy.resolve(
            providerID: self.id,
            api: settings.api,
            baseURL: baseURL,
            compat: settings.modelDefinition(for: resolved.modelID)?.compat
        )
        let fastMode = FastModeResolution.resolve(
            request: request,
            configured: settings.configuredFastMode,
            model: settings.modelDefinition(for: resolved.modelID)
        )
        let requiresServiceTier = policy.allowsServiceTier && (request.policy.serviceTier != nil || fastMode == true)
        return request.attachments.isEmpty
            && !ProviderRequestValidation.usesContractV2(request)
            && request.policy.streamTokens == false
            && request.policy.storeResponse == nil
            && request.policy.reasoningEffort == nil
            && request.policy.thinkingLevel == nil
            && request.policy.maxTokens == nil
            && request.policy.temperature == nil
            && request.policy.promptCache == nil
            && !requiresServiceTier
            && policy.usesInstructionsField
            && request.policy.codexTransport == .auto
    }
    #endif
}
