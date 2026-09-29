import Foundation
import OpenClawCore
import OpenClawProtocol

/// Reasoning budget preference for providers that expose explicit reasoning controls.
///
/// Values follow upstream reasoning efforts in rank order (`none` disables reasoning). Providers
/// clamp the requested value to what the selected model accepts (see ``ReasoningEffortResolver``);
/// provider-native labels use ``ModelReasoningEffortValue``.
///
/// - Note: 2026.3.0 added `none`, `minimal`, `xhigh` and `max`.
public enum ModelReasoningEffort: String, Sendable, Equatable, CaseIterable {
    /// Reasoning disabled.
    case none
    /// Minimal reasoning.
    case minimal
    /// Low reasoning.
    case low
    /// Medium reasoning.
    case medium
    /// High reasoning.
    case high
    /// Extra-high reasoning.
    case xhigh
    /// Maximum reasoning.
    case max
}

/// Service tier preference for providers that expose tiered latency or cost controls.
///
/// OpenAI accepts `auto`, `default`, `flex` and `priority`; Anthropic accepts `auto` and
/// `standard_only` (``standard`` maps to `standard_only`, `priority` to `auto`).
///
/// - Note: 2026.3.0 added `default` and `flex`.
public enum ModelServiceTier: String, Sendable, Equatable, CaseIterable {
    /// Provider-chosen tier.
    case auto
    /// Standard tier (Anthropic `standard_only`).
    case standard
    /// Priority tier.
    case priority
    /// OpenAI default tier.
    case `default`
    /// OpenAI flex tier.
    case flex
}

/// Prompt-cache preferences for providers that support prompt caching.
public struct ModelPromptCachePolicy: Sendable, Equatable {
    /// Whether cache markers / cache keys are sent.
    public var enabled: Bool
    /// Whether long retention (Anthropic `ttl: "1h"`, OpenAI `prompt_cache_retention: "24h"`) is requested.
    public var longRetention: Bool

    /// Creates a prompt-cache policy.
    /// - Parameters:
    ///   - enabled: Whether caching hints are sent.
    ///   - longRetention: Whether long retention is requested.
    public init(enabled: Bool = true, longRetention: Bool = false) {
        self.enabled = enabled
        self.longRetention = longRetention
    }
}

/// Transport selection used by Codex-style response APIs.
public enum CodexTransportPreference: String, Sendable, Equatable, CaseIterable {
    case auto
    case sse
    case websocket
}

/// Runtime generation policy used for model-provider selection and behavior controls.
public struct ModelGenerationPolicy: Sendable, Equatable {
    /// Requests token streaming when provider supports it.
    public let streamTokens: Bool
    /// Indicates whether runtime cancellation should be honored.
    public let allowCancellation: Bool
    /// Optional caller-provided cancellation token identifier.
    public let cancellationToken: String?
    /// Optional max token override.
    public let maxTokens: Int?
    /// Optional sampling temperature override.
    public let temperature: Double?
    /// Optional top-p override.
    public let topP: Double?
    /// Optional top-k override.
    public let topK: Int?
    /// Optional request timeout override in milliseconds.
    public let requestTimeoutMs: Int?
    /// Ordered provider fallback identifiers attempted after primary provider.
    public let fallbackProviderIDs: [String]
    /// Optional local-runtime-specific hints (for example hardware/backend toggles).
    public let localRuntimeHints: [String: String]
    /// Optional provider reasoning effort hint.
    public let reasoningEffort: ModelReasoningEffort?
    /// Optional provider service tier hint.
    public let serviceTier: ModelServiceTier?
    /// Optional fast-mode override (legacy boolean view; `auto` reads as `nil`).
    public let fastMode: Bool?
    /// Optional fast-mode setting including `auto`; takes precedence over ``fastMode``.
    public let fastModeSetting: FastMode?
    /// Run start used to evaluate `auto` fast mode (defaults to request time when `nil`).
    public let runStartedAt: Date?
    /// Optional prompt-cache preferences.
    public let promptCache: ModelPromptCachePolicy?
    /// Requests provider-side response persistence when supported.
    public let storeResponse: Bool?
    /// Preferred transport for Codex response APIs.
    public let codexTransport: CodexTransportPreference
    /// Raw thinking-level override resolved from session state.
    public let thinkingLevel: ThinkLevel?
    /// Raw reasoning visibility override resolved from session state.
    public let reasoningLevel: ReasoningLevel?
    /// Raw verbosity override resolved from session state.
    public let verboseLevel: VerboseLevel?
    /// Raw response-usage override resolved from session state.
    public let responseUsage: UsageDisplayLevel?
    /// Raw elevated-execution override resolved from session state.
    public let elevatedLevel: ElevatedLevel?

    /// Creates generation policy values.
    /// - Parameters:
    ///   - streamTokens: Requests streaming behavior.
    ///   - allowCancellation: Enables cancellation support for this request.
    ///   - cancellationToken: Optional cancellation token.
    ///   - maxTokens: Optional max token override.
    ///   - temperature: Optional temperature override.
    ///   - topP: Optional top-p override.
    ///   - topK: Optional top-k override.
    ///   - requestTimeoutMs: Optional timeout override in milliseconds.
    ///   - fallbackProviderIDs: Ordered provider fallback chain.
    ///   - localRuntimeHints: Optional local runtime hints.
    ///   - reasoningEffort: Optional explicit reasoning effort (clamped per model).
    ///   - serviceTier: Optional service tier.
    ///   - fastMode: Optional legacy fast-mode flag.
    ///   - storeResponse: Requests provider-side persistence when supported.
    ///   - codexTransport: Preferred Codex transport.
    ///   - thinkingLevel: Thinking level; providers resolve it to native effort/thinking payloads.
    ///   - reasoningLevel: Reasoning visibility override.
    ///   - verboseLevel: Verbosity override.
    ///   - responseUsage: Response-usage override.
    ///   - elevatedLevel: Elevated-execution override.
    ///   - fastModeSetting: Fast-mode setting including `auto`; wins over `fastMode`.
    ///   - runStartedAt: Run start used for `auto` fast mode.
    ///   - promptCache: Prompt-cache preferences.
    public init(
        streamTokens: Bool = false,
        allowCancellation: Bool = true,
        cancellationToken: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        requestTimeoutMs: Int? = nil,
        fallbackProviderIDs: [String] = [],
        localRuntimeHints: [String: String] = [:],
        reasoningEffort: ModelReasoningEffort? = nil,
        serviceTier: ModelServiceTier? = nil,
        fastMode: Bool? = nil,
        storeResponse: Bool? = nil,
        codexTransport: CodexTransportPreference = .auto,
        thinkingLevel: ThinkLevel? = nil,
        reasoningLevel: ReasoningLevel? = nil,
        verboseLevel: VerboseLevel? = nil,
        responseUsage: UsageDisplayLevel? = nil,
        elevatedLevel: ElevatedLevel? = nil,
        fastModeSetting: FastMode? = nil,
        runStartedAt: Date? = nil,
        promptCache: ModelPromptCachePolicy? = nil
    ) {
        self.streamTokens = streamTokens
        self.allowCancellation = allowCancellation
        self.cancellationToken = cancellationToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxTokens = maxTokens.map { max(1, $0) }
        self.temperature = temperature
        self.topP = topP
        self.topK = topK.map { max(1, $0) }
        self.requestTimeoutMs = requestTimeoutMs.map { max(1, $0) }
        self.fallbackProviderIDs = fallbackProviderIDs
        self.localRuntimeHints = localRuntimeHints
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.fastMode = fastMode ?? fastModeSetting?.legacyBoolValue
        self.fastModeSetting = fastModeSetting ?? fastMode.map(FastMode.init(enabled:))
        self.runStartedAt = runStartedAt
        self.promptCache = promptCache
        self.storeResponse = storeResponse
        self.codexTransport = codexTransport
        self.thinkingLevel = thinkingLevel
        self.reasoningLevel = reasoningLevel
        self.verboseLevel = verboseLevel
        self.responseUsage = responseUsage
        self.elevatedLevel = elevatedLevel
    }
}

/// Input payload passed to model providers.
///
/// Contract v2 adds a transcript (``messages``), tool declarations (``tools``/``toolChoice``) and a
/// requested output format (``responseFormat``). Every new field has a default, so providers and
/// callers written against v1 keep compiling; providers that ignore the new fields keep reading
/// ``prompt``, ``systemPrompt`` and ``attachments``.
public struct ModelGenerationRequest: Sendable, Equatable {
    /// Session key associated with generation request.
    public let sessionKey: String
    /// User prompt payload.
    public let prompt: String
    /// Optional system prompt prefix.
    public let systemPrompt: String?
    /// Optional explicit provider override.
    public let providerID: String?
    /// Optional explicit model override.
    public let modelID: String?
    /// Optional preferred auth-profile identifier.
    public let preferredAuthProfileID: String?
    /// Additional provider-specific metadata.
    public let metadata: [String: String]
    /// Additional request headers applied on top of provider config.
    public let headers: [String: String]
    /// Runtime generation policy controls.
    public let policy: ModelGenerationPolicy
    /// Optional multimodal attachments for providers that support rich input.
    public let attachments: [MediaAttachment]
    /// Transcript sent to the model. When non-empty it supersedes ``prompt`` and ``attachments``;
    /// ``systemPrompt`` stays the primary system prompt either way.
    public let messages: [ModelMessage]
    /// Tools the model may call. Providers that cannot call tools must reject non-empty tools
    /// (see ``validateToolSupport(supportsTools:providerID:)``).
    public let tools: [ModelToolDefinition]
    /// How the model may use ``tools``.
    public let toolChoice: ModelToolChoice
    /// Requested output format.
    public let responseFormat: ModelResponseFormat

    /// Creates a model generation request.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - prompt: Prompt payload.
    ///   - systemPrompt: Optional system prompt.
    ///   - providerID: Optional provider override.
    ///   - modelID: Optional model override.
    ///   - preferredAuthProfileID: Optional preferred auth profile.
    ///   - metadata: Additional metadata.
    ///   - headers: Additional request headers.
    ///   - policy: Runtime generation policy controls.
    ///   - attachments: Optional multimodal attachments.
    ///   - messages: Optional transcript; supersedes `prompt` and `attachments` when non-empty.
    ///   - tools: Tools the model may call.
    ///   - toolChoice: How the model may use `tools`.
    ///   - responseFormat: Requested output format.
    public init(
        sessionKey: String,
        prompt: String,
        systemPrompt: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        preferredAuthProfileID: String? = nil,
        metadata: [String: String] = [:],
        headers: [String: String] = [:],
        policy: ModelGenerationPolicy = ModelGenerationPolicy(),
        attachments: [MediaAttachment] = [],
        messages: [ModelMessage] = [],
        tools: [ModelToolDefinition] = [],
        toolChoice: ModelToolChoice = .auto,
        responseFormat: ModelResponseFormat = .text
    ) {
        self.sessionKey = sessionKey
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.providerID = providerID
        self.modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredAuthProfileID = preferredAuthProfileID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.metadata = metadata
        self.headers = headers
        self.policy = policy
        self.attachments = attachments
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.responseFormat = responseFormat
    }

    /// Transcript to send: ``messages`` when non-empty, otherwise one user message built from
    /// ``prompt`` and ``attachments``. Does not include ``systemPrompt``.
    public var resolvedMessages: [ModelMessage] {
        if !self.messages.isEmpty {
            return self.messages
        }
        var content: [ModelContentPart] = []
        if !self.prompt.isEmpty {
            content.append(.text(self.prompt))
        }
        content.append(contentsOf: self.attachments.map(ModelContentPart.media))
        return [.user(content: content)]
    }

    /// JSON schema requested through ``responseFormat``, if any.
    public var responseFormatJSONSchema: [String: AnyCodable]? {
        self.responseFormat.jsonSchema
    }

    /// Throws when the request declares tools but the provider/model cannot call tools.
    /// - Parameters:
    ///   - supportsTools: Tool support declared by the provider or model compat (`nil` = unknown,
    ///     treated as supported).
    ///   - providerID: Provider identifier used in the error message.
    /// - Throws: ``OpenClawCoreError/invalidConfiguration(_:)`` when `tools` is non-empty and
    ///   `supportsTools` is `false`.
    public func validateToolSupport(supportsTools: Bool?, providerID: String) throws {
        guard !self.tools.isEmpty, supportsTools == false else {
            return
        }
        let model = self.modelID.map { " model '\($0)'" } ?? ""
        throw OpenClawCoreError.invalidConfiguration(
            "Model provider '\(providerID)'\(model) does not support tool calling; remove tools from the request"
        )
    }

    /// Returns a copy with a replaced model id, preserving every other field.
    func replacingModelID(_ modelID: String) -> ModelGenerationRequest {
        ModelGenerationRequest(
            sessionKey: self.sessionKey,
            prompt: self.prompt,
            systemPrompt: self.systemPrompt,
            providerID: self.providerID,
            modelID: modelID,
            preferredAuthProfileID: self.preferredAuthProfileID,
            metadata: self.metadata,
            headers: self.headers,
            policy: self.policy,
            attachments: self.attachments,
            messages: self.messages,
            tools: self.tools,
            toolChoice: self.toolChoice,
            responseFormat: self.responseFormat
        )
    }

    /// Returns a copy with replaced metadata, preserving every other field.
    func replacingMetadata(_ metadata: [String: String]) -> ModelGenerationRequest {
        ModelGenerationRequest(
            sessionKey: self.sessionKey,
            prompt: self.prompt,
            systemPrompt: self.systemPrompt,
            providerID: self.providerID,
            modelID: self.modelID,
            preferredAuthProfileID: self.preferredAuthProfileID,
            metadata: metadata,
            headers: self.headers,
            policy: self.policy,
            attachments: self.attachments,
            messages: self.messages,
            tools: self.tools,
            toolChoice: self.toolChoice,
            responseFormat: self.responseFormat
        )
    }
}

/// Output payload returned from model providers.
///
/// Contract v2 adds proposed ``toolCalls``, ``usage``, ``stopReason`` and ``reasoningText``, all
/// defaulted so v1 providers keep compiling. Tool calls are proposals: the host or agent loop owns
/// execution and approval.
public struct ModelGenerationResponse: Sendable, Equatable {
    /// Generated text output.
    public let text: String
    /// Provider identifier that generated the output.
    public let providerID: String
    /// Optional concrete model identifier.
    public let modelID: String?
    /// Tool calls proposed by the model, in order.
    public let toolCalls: [ModelToolCall]
    /// Token accounting, when the provider reports it.
    public let usage: ModelUsage?
    /// Why generation stopped.
    public let stopReason: ModelStopReason
    /// Provider reasoning text, when exposed.
    public let reasoningText: String?
    /// Opaque signature of the reasoning block (Anthropic thinking signatures), required to replay
    /// thinking before tool use on the next turn.
    public let reasoningSignature: String?
    /// Tool calls the provider already executed in-process while generating (for example Apple
    /// Foundation Models in `executeInProcess` mode), in order. Unlike ``toolCalls`` these are not
    /// proposals: hosts record them in the transcript and must not execute them again.
    ///
    /// - Note: Added in 2026.3.0; empty for providers that never run tools themselves.
    public let executedToolCalls: [ModelExecutedToolCall]

    /// Creates a model generation response.
    /// - Parameters:
    ///   - text: Generated text output.
    ///   - providerID: Provider identifier.
    ///   - modelID: Optional concrete model identifier.
    ///   - toolCalls: Proposed tool calls.
    ///   - usage: Optional token accounting.
    ///   - stopReason: Stop reason; defaults to `.toolUse` when `toolCalls` is non-empty, else `.stop`.
    ///   - reasoningText: Optional reasoning text.
    ///   - reasoningSignature: Optional opaque reasoning signature.
    ///   - executedToolCalls: Tool calls the provider executed in-process.
    public init(
        text: String,
        providerID: String,
        modelID: String? = nil,
        toolCalls: [ModelToolCall] = [],
        usage: ModelUsage? = nil,
        stopReason: ModelStopReason? = nil,
        reasoningText: String? = nil,
        reasoningSignature: String? = nil,
        executedToolCalls: [ModelExecutedToolCall] = []
    ) {
        self.text = text
        self.providerID = providerID
        self.modelID = modelID
        self.toolCalls = toolCalls
        self.usage = usage
        self.stopReason = stopReason ?? (toolCalls.isEmpty ? .stop : .toolUse)
        self.reasoningText = reasoningText
        self.reasoningSignature = reasoningSignature
        self.executedToolCalls = executedToolCalls
    }

    /// Returns a copy with different `text`, preserving every other field.
    /// - Parameter text: Replacement text.
    /// - Returns: The updated response.
    public func withText(_ text: String) -> ModelGenerationResponse {
        ModelGenerationResponse(
            text: text,
            providerID: self.providerID,
            modelID: self.modelID,
            toolCalls: self.toolCalls,
            usage: self.usage,
            stopReason: self.stopReason,
            reasoningText: self.reasoningText,
            reasoningSignature: self.reasoningSignature,
            executedToolCalls: self.executedToolCalls
        )
    }

    /// Returns a copy carrying `executedToolCalls`, preserving every other field.
    /// - Parameter executedToolCalls: Tool calls the provider executed in-process.
    /// - Returns: The updated response.
    public func withExecutedToolCalls(_ executedToolCalls: [ModelExecutedToolCall]) -> ModelGenerationResponse {
        ModelGenerationResponse(
            text: self.text,
            providerID: self.providerID,
            modelID: self.modelID,
            toolCalls: self.toolCalls,
            usage: self.usage,
            stopReason: self.stopReason,
            reasoningText: self.reasoningText,
            reasoningSignature: self.reasoningSignature,
            executedToolCalls: executedToolCalls
        )
    }

    /// Transcript messages recording ``executedToolCalls`` (one assistant tool-call message followed
    /// by the results), so a loop can store the pairs without re-executing them. Empty when the
    /// provider executed nothing.
    public var executedToolMessages: [ModelMessage] {
        ModelExecutedToolCall.transcriptMessages(for: self.executedToolCalls)
    }

    /// Assistant content parts in transcript order: reasoning, text, then tool calls.
    public var assistantContent: [ModelAssistantPart] {
        var parts: [ModelAssistantPart] = []
        if let reasoningText, !reasoningText.isEmpty {
            parts.append(.thinking(reasoningText, signature: self.reasoningSignature))
        }
        if !self.text.isEmpty {
            parts.append(.text(self.text))
        }
        parts.append(contentsOf: self.toolCalls.map(ModelAssistantPart.toolCall))
        return parts
    }

    /// Assistant message to append to the transcript for the next turn.
    public var assistantMessage: ModelMessage {
        .assistant(content: self.assistantContent)
    }
}

/// Streaming chunk payload emitted by providers that support token streaming.
///
/// ``text`` always carries visible assistant text only, so v1 consumers that concatenate `text`
/// never see reasoning or tool-call payloads. Contract v2 chunks add a ``kind`` plus optional
/// reasoning, tool-call, usage and stop-reason payloads.
public struct ModelStreamChunk: Sendable, Equatable {
    /// Payload carried by a chunk.
    public enum Kind: String, Sendable, Equatable, CaseIterable, Codable {
        /// Visible text delta in ``ModelStreamChunk/text``.
        case text
        /// Reasoning delta in ``ModelStreamChunk/reasoningText``.
        case reasoning
        /// Tool-call fragment in ``ModelStreamChunk/toolCallDelta``.
        case toolCallDelta
        /// Usage update in ``ModelStreamChunk/usage``.
        case usage
        /// End of stream; may carry trailing text, complete tool calls, usage and a stop reason.
        case final
    }

    /// Token/text fragment (visible assistant text only).
    public let text: String
    /// Indicates whether this chunk marks end-of-stream payload.
    public let isFinal: Bool
    /// Payload kind.
    public let kind: Kind
    /// Reasoning delta for `.reasoning` chunks.
    public let reasoningText: String?
    /// Tool-call fragment for `.toolCallDelta` chunks.
    public let toolCallDelta: ModelToolCallDelta?
    /// Usage for `.usage` and `.final` chunks.
    public let usage: ModelUsage?
    /// Stop reason, usually on the `.final` chunk.
    public let stopReason: ModelStopReason?
    /// Complete tool calls, usually on the `.final` chunk.
    public let toolCalls: [ModelToolCall]
    /// Opaque reasoning signature, usually on the `.final` chunk.
    public let reasoningSignature: String?
    /// Tool calls the provider executed in-process, usually on the `.final` chunk (see
    /// ``ModelGenerationResponse/executedToolCalls``).
    public let executedToolCalls: [ModelExecutedToolCall]

    /// Creates a text chunk (v1 initializer).
    /// - Parameters:
    ///   - text: Token/text fragment.
    ///   - isFinal: End-of-stream marker; `true` produces a `.final` chunk.
    public init(text: String, isFinal: Bool = false) {
        self.init(kind: isFinal ? .final : .text, text: text)
    }

    /// Creates a chunk of any kind.
    /// - Parameters:
    ///   - kind: Payload kind; `.final` sets ``isFinal``.
    ///   - text: Visible text delta.
    ///   - reasoningText: Reasoning delta.
    ///   - toolCallDelta: Tool-call fragment.
    ///   - usage: Usage update.
    ///   - stopReason: Stop reason.
    ///   - toolCalls: Complete tool calls.
    ///   - reasoningSignature: Opaque reasoning signature.
    ///   - executedToolCalls: Tool calls the provider executed in-process.
    public init(
        kind: Kind,
        text: String = "",
        reasoningText: String? = nil,
        toolCallDelta: ModelToolCallDelta? = nil,
        usage: ModelUsage? = nil,
        stopReason: ModelStopReason? = nil,
        toolCalls: [ModelToolCall] = [],
        reasoningSignature: String? = nil,
        executedToolCalls: [ModelExecutedToolCall] = []
    ) {
        self.text = text
        self.isFinal = kind == .final
        self.kind = kind
        self.reasoningText = reasoningText
        self.toolCallDelta = toolCallDelta
        self.usage = usage
        self.stopReason = stopReason
        self.toolCalls = toolCalls
        self.reasoningSignature = reasoningSignature
        self.executedToolCalls = executedToolCalls
    }

    /// Creates a `.reasoning` chunk.
    /// - Parameter delta: Reasoning text delta.
    /// - Returns: A reasoning chunk.
    public static func reasoningDelta(_ delta: String) -> ModelStreamChunk {
        ModelStreamChunk(kind: .reasoning, reasoningText: delta)
    }

    /// Creates a `.toolCallDelta` chunk.
    /// - Parameter delta: Tool-call fragment.
    /// - Returns: A tool-call chunk.
    public static func toolCallUpdate(_ delta: ModelToolCallDelta) -> ModelStreamChunk {
        ModelStreamChunk(kind: .toolCallDelta, toolCallDelta: delta)
    }

    /// Creates a `.usage` chunk.
    /// - Parameter usage: Usage update.
    /// - Returns: A usage chunk.
    public static func usageUpdate(_ usage: ModelUsage) -> ModelStreamChunk {
        ModelStreamChunk(kind: .usage, usage: usage)
    }

    /// Creates the `.final` chunk that summarizes a complete response.
    /// - Parameters:
    ///   - text: Trailing visible text (empty when every text delta was already streamed).
    ///   - response: Complete response providing tool calls, usage and stop reason.
    /// - Returns: A final chunk.
    public static func completed(text: String = "", response: ModelGenerationResponse) -> ModelStreamChunk {
        ModelStreamChunk(
            kind: .final,
            text: text,
            usage: response.usage,
            stopReason: response.stopReason,
            toolCalls: response.toolCalls,
            reasoningSignature: response.reasoningSignature,
            executedToolCalls: response.executedToolCalls
        )
    }
}

/// Request throttling controls applied per model provider.
public struct ModelProviderThrottlePolicy: Sendable, Equatable {
    /// Strategy used when provider rate exceeds configured window.
    public enum Strategy: String, Sendable, Equatable {
        case delay
        case drop
    }

    public let maxRequestsPerWindow: Int
    public let windowMs: Int
    public let strategy: Strategy

    /// Creates provider throttle policy values.
    /// - Parameters:
    ///   - maxRequestsPerWindow: Maximum requests allowed in one rolling window per provider.
    ///   - windowMs: Rolling window duration in milliseconds.
    ///   - strategy: Strategy applied when limit is exceeded.
    public init(
        maxRequestsPerWindow: Int = 0,
        windowMs: Int = 1_000,
        strategy: Strategy = .delay
    ) {
        self.maxRequestsPerWindow = max(0, maxRequestsPerWindow)
        self.windowMs = max(1, windowMs)
        self.strategy = strategy
    }

    var isEnabled: Bool {
        self.maxRequestsPerWindow > 0
    }
}

/// Interface implemented by model backends.
public protocol ModelProvider: Sendable {
    /// Stable provider identifier.
    var id: String { get }
    /// Executes generation request.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generation response payload.
    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse

    /// Returns a token stream for providers that support streaming generation.
    /// - Parameter request: Generation request payload.
    /// - Returns: Async throwing stream of model chunks.
    func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error>

    /// Requests cancellation for an in-flight generation token when supported.
    /// - Parameter token: Stable cancellation token.
    func cancelGeneration(token: String?) async

    /// Contract v2 features this provider implements. Defaults to ``ModelProviderCapabilities/legacy``.
    var capabilities: ModelProviderCapabilities { get }
}

public extension ModelProvider {
    /// Default streaming implementation for non-streaming providers.
    ///
    /// Emits a `.reasoning` chunk when the response carries reasoning text, then one `.final` chunk
    /// with the full text, tool calls, usage and stop reason.
    /// - Parameter request: Generation request payload.
    /// - Returns: Stream ending with a single final chunk containing full generated text.
    func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.generate(request)
                    if let reasoningText = response.reasoningText, !reasoningText.isEmpty {
                        continuation.yield(.reasoningDelta(reasoningText))
                    }
                    continuation.yield(.completed(text: response.text, response: response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Default no-op cancellation implementation for providers without token-based cancellation.
    func cancelGeneration(token _: String?) async {}

    /// Default capabilities for providers that predate contract v2.
    var capabilities: ModelProviderCapabilities {
        .legacy
    }
}

/// Default fallback provider returning deterministic placeholder output.
public struct EchoModelProvider: ModelProvider {
    /// Default echo provider identifier.
    public static let defaultID = "echo"
    /// Provider identifier.
    public let id: String

    /// Creates an echo provider.
    /// - Parameter id: Provider identifier.
    public init(id: String = EchoModelProvider.defaultID) {
        self.id = id
    }

    /// Returns a deterministic echo response.
    /// - Parameter request: Generation request payload.
    /// - Returns: Echo response.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        _ = request
        return ModelGenerationResponse(text: "OK", providerID: self.id, modelID: "echo-1")
    }
}

/// Actor that resolves providers and routes generation requests.
public actor ModelRouter {
    private var providers: [String: any ModelProvider]
    private var defaultProviderID: String
    private var throttlePolicy: ModelProviderThrottlePolicy
    private var requestTimestampsByProvider: [String: [Date]] = [:]
    private let diagnosticsSink: RuntimeDiagnosticSink?
    private let runtimeAuthResolver: any ProviderRuntimeAuthResolving
    private var adaptivePolicy: AdaptiveRoutingPolicy?
    private var authConfig: AuthConfig?
    private var authProfileStore: AuthProfileStore?

    /// Creates a model router.
    /// - Parameters:
    ///   - defaultProviderID: Default provider identifier.
    ///   - providers: Initial provider list.
    public init(
        defaultProviderID: String = EchoModelProvider.defaultID,
        providers: [any ModelProvider] = [EchoModelProvider()],
        throttlePolicy: ModelProviderThrottlePolicy = ModelProviderThrottlePolicy(),
        diagnosticsSink: RuntimeDiagnosticSink? = nil,
        adaptiveRoutingConfig: AdaptiveRoutingConfig? = nil,
        authConfig: AuthConfig? = nil,
        authProfileStore: AuthProfileStore? = nil,
        runtimeAuthResolver: any ProviderRuntimeAuthResolving = RuntimeProviderAuthResolver.shared
    ) {
        var map: [String: any ModelProvider] = [:]
        for provider in providers {
            map[provider.id] = provider
        }
        if map[defaultProviderID] == nil {
            map[EchoModelProvider.defaultID] = EchoModelProvider()
            self.defaultProviderID = EchoModelProvider.defaultID
        } else {
            self.defaultProviderID = defaultProviderID
        }
        self.providers = map
        self.throttlePolicy = throttlePolicy
        self.diagnosticsSink = diagnosticsSink
        self.runtimeAuthResolver = runtimeAuthResolver
        self.authConfig = authConfig
        self.authProfileStore = authProfileStore
        if let adaptiveRoutingConfig, adaptiveRoutingConfig.enabled {
            self.adaptivePolicy = AdaptiveRoutingPolicy(config: adaptiveRoutingConfig)
        } else {
            self.adaptivePolicy = nil
        }
    }

    /// Registers or replaces a provider.
    /// - Parameter provider: Provider implementation.
    public func register(_ provider: any ModelProvider) {
        self.providers[provider.id] = provider
    }

    /// Sets default provider by identifier.
    /// - Parameter id: Provider identifier.
    public func setDefaultProviderID(_ id: String) throws {
        let resolved = self.registeredProviderID(for: id)
        guard self.providers[resolved] != nil else {
            throw OpenClawCoreError.invalidConfiguration("Unknown model provider: \(id)")
        }
        self.defaultProviderID = resolved
    }

    /// Maps a requested provider id or alias onto a registered provider id.
    ///
    /// Exact registrations win. Otherwise the id is normalized through the reference catalog
    /// (`foundation` → `apple-fm`, `gemini` → `google`, `openai-codex` → `openai`, …) and matched
    /// against registered providers whose own id normalizes the same way. Unknown ids are returned
    /// trimmed so fallback ordering and error messages keep the caller's spelling.
    /// - Parameter rawID: Requested provider id or alias.
    /// - Returns: A registered provider id, or the trimmed input when none matches.
    public func registeredProviderID(for rawID: String) -> String {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, self.providers[trimmed] == nil else {
            return trimmed
        }
        let lowered = trimmed.lowercased()
        if self.providers[lowered] != nil {
            return lowered
        }
        let canonical = OpenClawReferenceProviderCatalog.normalize(providerID: lowered)
        if self.providers[canonical] != nil {
            return canonical
        }
        let matches = self.providers.keys
            .filter { OpenClawReferenceProviderCatalog.normalize(providerID: $0) == canonical }
            .sorted()
        return matches.first ?? trimmed
    }

    /// Sets per-provider throttle policy.
    /// - Parameter policy: Provider throttling policy.
    public func setThrottlePolicy(_ policy: ModelProviderThrottlePolicy) {
        self.throttlePolicy = policy
    }

    /// Enables or disables adaptive routing policy.
    /// - Parameter config: Adaptive routing configuration.
    public func setAdaptiveRoutingConfig(_ config: AdaptiveRoutingConfig?) {
        guard let config, config.enabled else {
            self.adaptivePolicy = nil
            return
        }
        self.adaptivePolicy = AdaptiveRoutingPolicy(config: config)
    }

    /// Updates auth config used for profile ordering and cooldowns.
    public func setAuthConfig(_ config: AuthConfig?) {
        self.authConfig = config
    }

    /// Updates the auth profile store used for request credential resolution.
    public func setAuthProfileStore(_ store: AuthProfileStore?) {
        self.authProfileStore = store
    }

    /// Returns a snapshot of adaptive routing scores.
    /// - Parameter candidateProviderIDs: Optional subset of providers for ranking.
    public func adaptiveRoutingSnapshot(candidateProviderIDs: [String]? = nil) -> AdaptiveRoutingSnapshot? {
        guard let adaptivePolicy else {
            return nil
        }
        let candidates = (candidateProviderIDs ?? self.providers.keys.sorted()).filter { !$0.isEmpty }
        return adaptivePolicy.snapshot(for: candidates)
    }

    /// Updates adaptive routing state using aggregate diagnostics telemetry.
    /// - Parameters:
    ///   - diagnostics: Runtime diagnostics snapshot.
    ///   - decayFactor: Historical retention factor (`0...1`).
    /// - Returns: Updated adaptive snapshot.
    public func optimizeRouting(
        using diagnostics: RuntimeUsageSnapshot,
        decayFactor: Double = 0.85
    ) -> AdaptiveRoutingSnapshot? {
        guard self.adaptivePolicy != nil else {
            return nil
        }
        self.adaptivePolicy?.ingest(
            modelMetrics: diagnostics.models,
            decayFactor: decayFactor
        )
        return self.adaptivePolicy?.snapshot(for: self.providers.keys.sorted())
    }

    /// Updates adaptive routing state using a diagnostics pipeline.
    /// - Parameters:
    ///   - diagnosticsPipeline: Runtime diagnostics pipeline.
    ///   - decayFactor: Historical retention factor (`0...1`).
    /// - Returns: Updated adaptive snapshot.
    public func optimizeRouting(
        using diagnosticsPipeline: RuntimeDiagnosticsPipeline,
        decayFactor: Double = 0.85
    ) async -> AdaptiveRoutingSnapshot? {
        guard self.adaptivePolicy != nil else {
            return nil
        }
        let modelMetrics = await diagnosticsPipeline.modelTelemetry()
        self.adaptivePolicy?.ingest(
            modelMetrics: modelMetrics,
            decayFactor: decayFactor
        )
        return self.adaptivePolicy?.snapshot(for: self.providers.keys.sorted())
    }

    /// Returns configured provider identifiers sorted alphabetically.
    public func configuredProviderIDs() -> [String] {
        self.providers.keys.sorted()
    }

    /// Identifier and contract-v2 capabilities of the first registered provider that would serve
    /// `request` (explicit provider, fallbacks, then the default), or `nil` when none is registered.
    ///
    /// The agent loop uses this to decide whether to send transcript messages and tools.
    /// - Parameter request: Generation request.
    /// - Returns: Provider id and capabilities.
    public func primaryProvider(for request: ModelGenerationRequest) -> (id: String, capabilities: ModelProviderCapabilities)? {
        for providerID in self.resolveProviderOrder(for: request) {
            if let provider = self.providers[providerID] {
                return (providerID, provider.capabilities)
            }
        }
        return nil
    }

    /// Routes generation request to requested/default provider.
    /// - Parameter request: Generation request payload.
    /// - Returns: Provider response.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        let orderedProviderIDs = self.resolveProviderOrder(for: request)
        var lastError: Error?
        for (index, providerID) in orderedProviderIDs.enumerated() {
            guard let provider = self.providers[providerID] else {
                continue
            }
            let candidateProfileIDs = await self.resolveAuthProfileOrder(for: providerID, request: request)
            let candidateSet: [String?] = candidateProfileIDs.isEmpty ? [nil] : candidateProfileIDs.map(Optional.some)
            for profileID in candidateSet {
                let startedAt = Date()
                do {
                    try await self.applyThrottleIfNeeded(providerID: providerID)
                    let resolvedRequest = try await self.requestWithResolvedAuth(
                        request,
                        providerID: providerID,
                        profileID: profileID
                    )
                    let response = try await provider.generate(resolvedRequest)
                    let latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                    self.recordAdaptiveObservation(
                        providerID: providerID,
                        succeeded: true,
                        latencyMs: latencyMs,
                        metadata: resolvedRequest.metadata
                    )
                    if let profileID, let authProfileStore {
                        try? await authProfileStore.recordSuccess(profileID: profileID, provider: providerID)
                    }
                    return response
                } catch {
                    // A caller abort is not a provider failure: stop the chain without recording
                    // cooldowns or trying further candidates (upstream `caller_signal_aborted`).
                    if Self.isCancellation(error) {
                        throw error
                    }
                    await self.recordAttemptFailure(
                        providerID: providerID,
                        profileID: profileID,
                        error: error,
                        startedAt: startedAt,
                        metadata: request.metadata
                    )
                    lastError = error
                    await self.emitRetryDiagnostic(
                        providerID: providerID,
                        profileID: profileID,
                        index: index,
                        orderedProviderIDs: orderedProviderIDs,
                        error: error,
                        streaming: false
                    )
                }
            }
        }
        if let lastError {
            throw lastError
        }
        throw OpenClawCoreError.invalidConfiguration(
            "No registered model providers available for request and fallback chain"
        )
    }

    /// Returns a token stream from the first available provider in fallback order.
    ///
    /// Candidates (auth profiles within a provider, then fallback providers) are tried until one
    /// stream produces its first non-usage chunk. A stream that fails before that point records the
    /// failure, emits `model.request.retry` and falls through to the next candidate; once a stream has
    /// produced output the router commits to it, so a later error ends the stream without replaying
    /// output from another provider. Success is recorded only when the committed stream finishes
    /// normally. Cancelling the consumer cancels the in-flight provider stream without recording a
    /// failure.
    /// - Parameter request: Generation request payload.
    /// - Returns: Async throwing stream of model chunks.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        let orderedProviderIDs = self.resolveProviderOrder(for: request)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ModelStreamChunk.self, throwing: Error.self)
        let producer = Task {
            await self.relayStream(request: request, orderedProviderIDs: orderedProviderIDs, continuation: continuation)
        }
        continuation.onTermination = { _ in
            producer.cancel()
        }
        return stream
    }

    /// Walks the streaming candidates, relaying the first stream that produces output.
    ///
    /// Runs outside the actor so provider stream iterators never cross isolation; the actor is
    /// entered only for provider lookup, throttling, auth resolution and bookkeeping.
    nonisolated private func relayStream(
        request: ModelGenerationRequest,
        orderedProviderIDs: [String],
        continuation: AsyncThrowingStream<ModelStreamChunk, Error>.Continuation
    ) async {
        var lastError: Error?
        for (index, providerID) in orderedProviderIDs.enumerated() {
            guard let provider = await self.registeredProvider(providerID) else {
                continue
            }
            let candidateProfileIDs = await self.resolveAuthProfileOrder(for: providerID, request: request)
            let candidateSet: [String?] = candidateProfileIDs.isEmpty ? [nil] : candidateProfileIDs.map(Optional.some)
            for profileID in candidateSet {
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                let startedAt = Date()
                var committed = false
                var pending: [ModelStreamChunk] = []
                var metadata = request.metadata
                do {
                    try await self.applyThrottleIfNeeded(providerID: providerID)
                    let resolvedRequest = try await self.requestWithResolvedAuth(
                        request,
                        providerID: providerID,
                        profileID: profileID
                    )
                    metadata = resolvedRequest.metadata
                    let providerStream = await provider.generateStream(resolvedRequest)
                    for try await chunk in providerStream {
                        if committed {
                            continuation.yield(chunk)
                        } else if chunk.kind == .usage {
                            pending.append(chunk)
                        } else {
                            committed = true
                            pending.forEach { continuation.yield($0) }
                            pending.removeAll()
                            continuation.yield(chunk)
                        }
                    }
                    if Task.isCancelled {
                        // The consumer went away; the provider stream ended because it was cancelled.
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    pending.forEach { continuation.yield($0) }
                    await self.recordAttemptSuccess(
                        providerID: providerID,
                        profileID: profileID,
                        startedAt: startedAt,
                        metadata: metadata
                    )
                    continuation.finish()
                    return
                } catch {
                    if Self.isCancellation(error) || Task.isCancelled {
                        continuation.finish(throwing: error)
                        return
                    }
                    await self.recordAttemptFailure(
                        providerID: providerID,
                        profileID: profileID,
                        error: error,
                        startedAt: startedAt,
                        metadata: metadata
                    )
                    if committed {
                        continuation.finish(throwing: error)
                        return
                    }
                    lastError = error
                    await self.emitRetryDiagnostic(
                        providerID: providerID,
                        profileID: profileID,
                        index: index,
                        orderedProviderIDs: orderedProviderIDs,
                        error: error,
                        streaming: true
                    )
                }
            }
        }
        continuation.finish(
            throwing: lastError ?? OpenClawCoreError.invalidConfiguration(
                "No registered model providers available for streaming request"
            )
        )
    }

    private func registeredProvider(_ providerID: String) -> (any ModelProvider)? {
        self.providers[providerID]
    }

    private func recordAttemptSuccess(
        providerID: String,
        profileID: String?,
        startedAt: Date,
        metadata: [String: String]
    ) async {
        let latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        self.recordAdaptiveObservation(providerID: providerID, succeeded: true, latencyMs: latencyMs, metadata: metadata)
        if let profileID, let authProfileStore {
            try? await authProfileStore.recordSuccess(profileID: profileID, provider: providerID)
        }
    }

    private func recordAttemptFailure(
        providerID: String,
        profileID: String?,
        error: Error,
        startedAt: Date,
        metadata: [String: String]
    ) async {
        let latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        self.recordAdaptiveObservation(providerID: providerID, succeeded: false, latencyMs: latencyMs, metadata: metadata)
        if let profileID, let authProfileStore {
            try? await authProfileStore.recordFailure(
                profileID: profileID,
                provider: providerID,
                reason: Self.failureReason(for: error),
                cooldowns: self.authConfig?.cooldowns ?? AuthCooldownConfig()
            )
        }
    }

    private func emitRetryDiagnostic(
        providerID: String,
        profileID: String?,
        index: Int,
        orderedProviderIDs: [String],
        error: Error,
        streaming: Bool
    ) async {
        guard let nextProviderID = self.nextAvailableProviderID(after: index, in: orderedProviderIDs) else {
            return
        }
        var metadata = [
            "fromProviderID": providerID,
            "profileID": profileID ?? "",
            "nextProviderID": nextProviderID,
            "error": ProviderErrorRedaction.describe(error),
        ]
        if streaming {
            metadata["streaming"] = "true"
        }
        await self.emitDiagnostic(name: "model.request.retry", metadata: metadata)
    }

    /// Whether an error is a caller abort rather than a provider failure.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return Task.isCancelled
    }

    /// Broadcasts a cancellation request to registered providers.
    /// - Parameter token: Stable cancellation token.
    public func cancelGeneration(token: String?) async {
        let normalized = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized?.isEmpty == false else {
            return
        }
        let providers = Array(self.providers.values)
        for provider in providers {
            await provider.cancelGeneration(token: normalized)
        }
        await self.emitDiagnostic(
            name: "model.request.cancel",
            metadata: [
                "cancellationToken": normalized ?? "",
            ]
        )
    }

    private func applyThrottleIfNeeded(providerID: String) async throws {
        guard self.throttlePolicy.isEnabled else {
            return
        }
        let now = Date()
        let windowStart = now.addingTimeInterval(-Double(self.throttlePolicy.windowMs) / 1000.0)
        var timestamps = (self.requestTimestampsByProvider[providerID] ?? []).filter { $0 >= windowStart }

        if timestamps.count < self.throttlePolicy.maxRequestsPerWindow {
            timestamps.append(now)
            self.requestTimestampsByProvider[providerID] = timestamps
            return
        }

        switch self.throttlePolicy.strategy {
        case .drop:
            await self.emitDiagnostic(
                name: "model.throttle.drop",
                metadata: [
                    "providerID": providerID,
                    "windowMs": String(self.throttlePolicy.windowMs),
                    "maxRequestsPerWindow": String(self.throttlePolicy.maxRequestsPerWindow),
                ]
            )
            throw OpenClawCoreError.unavailable("Model provider '\(providerID)' is throttled by policy")
        case .delay:
            let earliest = timestamps.first ?? now
            let releaseAt = earliest.addingTimeInterval(Double(self.throttlePolicy.windowMs) / 1000.0)
            let delayMs = max(1, Int(releaseAt.timeIntervalSince(now) * 1000))
            await self.emitDiagnostic(
                name: "model.throttle.delay",
                metadata: [
                    "providerID": providerID,
                    "delayMs": String(delayMs),
                    "windowMs": String(self.throttlePolicy.windowMs),
                    "maxRequestsPerWindow": String(self.throttlePolicy.maxRequestsPerWindow),
                ]
            )
            let sleepNs = UInt64(delayMs) * 1_000_000
            try await Task.sleep(nanoseconds: sleepNs)

            let delayedNow = Date()
            let delayedWindowStart = delayedNow.addingTimeInterval(-Double(self.throttlePolicy.windowMs) / 1000.0)
            timestamps = (self.requestTimestampsByProvider[providerID] ?? []).filter { $0 >= delayedWindowStart }
            timestamps.append(delayedNow)
            self.requestTimestampsByProvider[providerID] = timestamps
        }
    }

    private func nextAvailableProviderID(after index: Int, in orderedProviderIDs: [String]) -> String? {
        guard index + 1 < orderedProviderIDs.count else {
            return nil
        }
        for nextIndex in (index + 1)..<orderedProviderIDs.count {
            let nextProviderID = orderedProviderIDs[nextIndex]
            if self.providers[nextProviderID] != nil {
                return nextProviderID
            }
        }
        return nil
    }

    private func emitDiagnostic(name: String, metadata: [String: String]) async {
        guard let diagnosticsSink else { return }
        await diagnosticsSink(
            RuntimeDiagnosticEvent(
                subsystem: "model",
                name: name,
                metadata: metadata
            )
        )
    }

    private func resolveProviderOrder(for request: ModelGenerationRequest) -> [String] {
        var orderedIDs: [String] = []
        var seen: Set<String> = []

        func appendProviderID(_ rawID: String?) {
            guard let rawID else { return }
            let normalized = self.registeredProviderID(for: rawID)
            guard !normalized.isEmpty else { return }
            if seen.insert(normalized).inserted {
                orderedIDs.append(normalized)
            }
        }

        func appendProviderList(_ rawList: String?) {
            guard let rawList else { return }
            let components = rawList.split { character in
                character == "," || character == ";"
            }
            for component in components {
                appendProviderID(String(component))
            }
        }

        appendProviderID(request.providerID)
        for fallbackID in request.policy.fallbackProviderIDs {
            appendProviderID(fallbackID)
        }
        appendProviderList(request.metadata["fallbackProviderID"])
        appendProviderList(request.metadata["fallbackProviderIDs"])
        appendProviderID(self.defaultProviderID)

        guard let adaptivePolicy else {
            return orderedIDs
        }

        let explicitProvider = request.providerID.map { self.registeredProviderID(for: $0) }
        if let explicitProvider, !explicitProvider.isEmpty {
            let tail = orderedIDs.filter { $0 != explicitProvider }
            let rankedTail = adaptivePolicy.rankedProviderIDs(from: tail)
            return [explicitProvider] + rankedTail
        }
        return adaptivePolicy.rankedProviderIDs(from: orderedIDs)
    }

    private func recordAdaptiveObservation(
        providerID: String,
        succeeded: Bool,
        latencyMs: Int,
        metadata: [String: String]
    ) {
        guard self.adaptivePolicy != nil else {
            return
        }
        let normalizedProvider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cost = Self.metadataDouble(
            metadata,
            keys: ["costUSD:\(normalizedProvider)", "estimatedCostUSD:\(normalizedProvider)", "costUSD", "estimatedCostUSD"]
        )
        let quality = Self.metadataDouble(
            metadata,
            keys: ["qualityScore:\(normalizedProvider)", "qualityScore"]
        )
        self.adaptivePolicy?.record(
            providerID: normalizedProvider,
            succeeded: succeeded,
            latencyMs: latencyMs,
            costUSD: cost,
            qualityScore: quality
        )
    }

    private static func metadataDouble(_ metadata: [String: String], keys: [String]) -> Double? {
        for key in keys {
            guard let raw = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let value = Double(raw)
            else {
                continue
            }
            return value
        }
        return nil
    }

    private func resolveAuthProfileOrder(for providerID: String, request: ModelGenerationRequest) async -> [String] {
        guard let authProfileStore else {
            return []
        }
        let snapshot = await authProfileStore.snapshot()
        return AuthProfileResolver.resolveProfileOrder(
            provider: providerID,
            preferredProfileID: request.preferredAuthProfileID,
            config: self.authConfig,
            snapshot: snapshot
        )
    }

    private func requestWithResolvedAuth(
        _ request: ModelGenerationRequest,
        providerID: String,
        profileID: String?
    ) async throws -> ModelGenerationRequest {
        guard let profileID, let authProfileStore, let credential = try await authProfileStore.resolvedCredential(for: profileID) else {
            return request
        }
        let runtimeResolution = try await self.runtimeAuthResolver.resolve(
            providerID: providerID,
            credential: credential
        )
        if runtimeResolution.persistCredential, runtimeResolution.credential != credential {
            try await authProfileStore.setCredential(runtimeResolution.credential, for: profileID)
        }
        var metadata = request.metadata
        metadata["auth.profileID"] = profileID
        metadata["auth.providerID"] = providerID
        for (key, value) in runtimeResolution.metadata {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty, !normalizedValue.isEmpty else { continue }
            metadata[normalizedKey] = normalizedValue
        }
        switch runtimeResolution.credential {
        case .apiKey(let value):
            // Non-secret local markers (for example `apple-fm-local`) identify on-device auth profiles;
            // they are never forwarded as credentials.
            if let key = value.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
               !ModelProviderSecrets.isNonSecretAuthMarker(key)
            {
                metadata["auth.apiKey"] = key
            }
        case .token(let value):
            if let token = value.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                metadata["auth.accessToken"] = token
            }
            if let expires = value.expires {
                metadata["auth.expires"] = String(expires)
            }
        case .oauth(let value):
            if let accessToken = value.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !accessToken.isEmpty {
                metadata["auth.accessToken"] = accessToken
            }
            if let refreshToken = value.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines), !refreshToken.isEmpty {
                metadata["auth.refreshToken"] = refreshToken
            }
            if let clientID = value.clientID?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty {
                metadata["auth.clientID"] = clientID
            }
            if let expires = value.expires {
                metadata["auth.expires"] = String(expires)
            }
        }
        return request.replacingMetadata(metadata)
    }

    private static func failureReason(for error: Error) -> AuthProfileFailureReason {
        let description = String(describing: error).lowercased()
        // Match rate-limit phrasing, not the bare substring "rate" ("generated", "moderate", …).
        let rateLimitMarkers = ["rate limit", "rate-limit", "rate_limit", "ratelimit", "rate limited", "too many requests", "429"]
        if rateLimitMarkers.contains(where: description.contains) {
            return .rateLimit
        }
        if description.contains("billing") || description.contains("quota") {
            return .billing
        }
        if description.contains("timeout") {
            return .timeout
        }
        if description.contains("expired") || description.contains("session") {
            return .sessionExpired
        }
        if description.contains("model") && description.contains("not found") {
            return .modelNotFound
        }
        if description.contains("auth") || description.contains("token") || description.contains("unauthorized") {
            return .auth
        }
        return .unknown
    }
}
