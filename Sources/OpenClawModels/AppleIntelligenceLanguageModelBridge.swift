import Foundation
import OpenClawCore
import OpenClawProtocol

// Exposes OpenClaw model providers as FoundationModels `LanguageModel`s (OS 27).
//
// FoundationModels 27 makes `LanguageModel`/`LanguageModelExecutor` public, so apps written against
// Foundation Models idioms (`LanguageModelSession`, `@Generable`, `Tool`, dynamic profiles) can target
// any OpenClaw provider -- Claude, GPT, Gemini, a gateway -- with a one-line model swap:
//
//     let session = LanguageModelSession(model: OpenClawLanguageModel(provider: anthropic, modelID: "claude-opus-5"))
//
// The executor converts the session transcript into a contract v2 `ModelGenerationRequest`
// (instructions -> system prompt, prompts/responses/reasoning/tool calls/tool outputs -> messages,
// tool definitions and response schemas -> JSON Schema), streams the provider's chunks back through
// the generation channel, and reports usage. When the provider proposes tool calls the session runs
// its own `Tool`s and calls the executor again with the tool output; Swift-only, no upstream parity.
#if compiler(>=6.4) && canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A FoundationModels `LanguageModel` backed by an OpenClaw ``ModelProvider`` (OS 27).
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct OpenClawLanguageModel: LanguageModel {
    /// Executor that runs requests against ``provider``.
    public typealias Executor = OpenClawLanguageModelExecutor

    /// Provider that generates the tokens.
    public let provider: any ModelProvider
    /// Provider identifier forwarded in requests.
    public let providerID: String
    /// Model identifier forwarded in requests (`nil` = provider default).
    public let modelID: String?
    /// Accepts image attachments.
    public let supportsVision: Bool
    /// Accepts a reasoning level.
    public let supportsReasoning: Bool
    /// Can call tools.
    public let supportsToolCalling: Bool
    /// Supports schema-constrained output.
    public let supportsGuidedGeneration: Bool

    /// Creates a bridged model.
    /// - Parameters:
    ///   - provider: Backing provider.
    ///   - modelID: Model identifier (`nil` = provider default).
    ///   - supportsVision: Declare image input.
    ///   - supportsReasoning: Declare reasoning levels.
    ///   - supportsToolCalling: Declare tool calling (default: the provider's `supportsTools`).
    ///   - supportsGuidedGeneration: Declare guided generation (default: the provider's `supportsJSONSchema`).
    public init(
        provider: any ModelProvider,
        modelID: String? = nil,
        supportsVision: Bool = false,
        supportsReasoning: Bool = false,
        supportsToolCalling: Bool? = nil,
        supportsGuidedGeneration: Bool? = nil
    ) {
        self.provider = provider
        self.providerID = provider.id
        self.modelID = modelID
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
        self.supportsToolCalling = supportsToolCalling ?? provider.capabilities.supportsTools
        self.supportsGuidedGeneration = supportsGuidedGeneration ?? provider.capabilities.supportsJSONSchema
    }

    /// Creates a bridged model whose capabilities come from a catalog model definition: image input
    /// -> vision, `reasoning` -> reasoning, `compat.supportsTools != false` -> tool calling.
    /// - Parameters:
    ///   - provider: Backing provider.
    ///   - definition: Catalog model definition.
    public init(provider: any ModelProvider, definition: ModelDefinitionConfig) {
        self.init(
            provider: provider,
            modelID: definition.id,
            supportsVision: definition.input.contains(.image),
            supportsReasoning: definition.reasoning,
            supportsToolCalling: definition.compat?.supportsTools != false && provider.capabilities.supportsTools
        )
    }

    /// Creates a bridged model routed through a ``ModelRouter`` (fallbacks, throttling, auth profiles).
    /// - Parameters:
    ///   - router: Router.
    ///   - providerID: Provider to route to.
    ///   - modelID: Model identifier.
    ///   - definition: Optional catalog definition for capabilities.
    /// - Returns: The bridged model.
    public static func routed(
        through router: ModelRouter,
        providerID: String,
        modelID: String? = nil,
        definition: ModelDefinitionConfig? = nil
    ) -> OpenClawLanguageModel {
        let provider = OpenClawRoutedModelProvider(router: router, id: providerID)
        return OpenClawLanguageModel(
            provider: provider,
            modelID: modelID ?? definition?.id,
            supportsVision: definition?.input.contains(.image) ?? false,
            supportsReasoning: definition?.reasoning ?? false,
            supportsToolCalling: definition?.compat?.supportsTools ?? true,
            supportsGuidedGeneration: true
        )
    }

    /// Declared capabilities.
    public var capabilities: LanguageModelCapabilities {
        var capabilities: [LanguageModelCapabilities.Capability] = []
        if self.supportsVision { capabilities.append(.vision) }
        if self.supportsReasoning { capabilities.append(.reasoning) }
        if self.supportsToolCalling { capabilities.append(.toolCalling) }
        if self.supportsGuidedGeneration { capabilities.append(.guidedGeneration) }
        return LanguageModelCapabilities(capabilities)
    }

    /// Executor configuration (provider and model identifiers).
    public var executorConfiguration: OpenClawLanguageModelExecutor.Configuration {
        OpenClawLanguageModelExecutor.Configuration(providerID: self.providerID, modelID: self.modelID)
    }
}

/// Executor for ``OpenClawLanguageModel`` (OS 27). Holds no provider state; the model is passed in.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct OpenClawLanguageModelExecutor: LanguageModelExecutor {
    /// Executor configuration.
    public struct Configuration: Hashable, Sendable {
        /// Provider identifier.
        public var providerID: String
        /// Model identifier.
        public var modelID: String?

        /// Creates a configuration.
        /// - Parameters:
        ///   - providerID: Provider identifier.
        ///   - modelID: Model identifier.
        public init(providerID: String, modelID: String?) {
            self.providerID = providerID
            self.modelID = modelID
        }
    }

    /// Model type served by this executor.
    public typealias Model = OpenClawLanguageModel

    /// Executor configuration.
    public let configuration: Configuration

    /// Creates an executor.
    /// - Parameter configuration: Executor configuration.
    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    /// Runs one generation request against the model's provider and streams the result.
    /// - Parameters:
    ///   - request: Framework generation request.
    ///   - model: Bridged model.
    ///   - channel: Event channel.
    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: OpenClawLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let modelRequest = try OpenClawTranscriptConverter.request(from: request, model: model)
        var deltas: [Int: ModelToolCallDelta] = [:]
        var finalCalls: [ModelToolCall] = []
        var usage: ModelUsage?
        // Reasoning actions share one entry so the provider's signature lands on the streamed text.
        let reasoningEntryID = UUID().uuidString
        var reasoningStreamed = false
        var reasoningSignature: String?
        do {
            for try await chunk in await model.provider.generateStream(modelRequest) {
                if let signature = chunk.reasoningSignature, !signature.isEmpty {
                    reasoningSignature = signature
                }
                switch chunk.kind {
                case .text, .final:
                    if !chunk.text.isEmpty {
                        await channel.send(.response(action: .appendText(chunk.text, tokenCount: Self.estimatedTokens(chunk.text))))
                    }
                    if chunk.kind == .final {
                        finalCalls = chunk.toolCalls
                        usage = chunk.usage ?? usage
                    }
                case .reasoning:
                    if let reasoning = chunk.reasoningText, !reasoning.isEmpty {
                        await channel.send(
                            .reasoning(entryID: reasoningEntryID, action: .appendText(reasoning, tokenCount: Self.estimatedTokens(reasoning)))
                        )
                        reasoningStreamed = true
                    }
                case .toolCallDelta:
                    if let delta = chunk.toolCallDelta {
                        var merged = deltas[delta.index] ?? ModelToolCallDelta(index: delta.index)
                        merged.id = merged.id ?? delta.id
                        merged.name = merged.name ?? delta.name
                        merged.argumentsDelta += delta.argumentsDelta
                        deltas[delta.index] = merged
                    }
                case .usage:
                    usage = chunk.usage ?? usage
                }
            }
        } catch {
            throw OpenClawTranscriptConverter.frameworkError(error)
        }
        if let reasoningSignature {
            // Keep the provider's signature (for example Claude's signed thinking, which tool-use
            // continuations must send back) on the reasoning entry so the next request replays it.
            if !reasoningStreamed {
                await channel.send(.reasoning(entryID: reasoningEntryID, action: .appendText("", tokenCount: 0)))
            }
            await channel.send(
                .reasoning(
                    entryID: reasoningEntryID,
                    action: .updateSignature(OpenClawBridgeReasoningSignature.data(for: reasoningSignature), tokenCount: 0)
                )
            )
        }
        // Tool calls are sent whole: the session only runs tools once the response completes.
        let calls = finalCalls.isEmpty
            ? deltas.keys.sorted().compactMap { index -> ModelToolCall? in
                guard let delta = deltas[index], let name = delta.name else { return nil }
                return ModelToolCall(id: delta.id ?? "call_\(index)", name: name, argumentsJSON: delta.argumentsDelta.isEmpty ? "{}" : delta.argumentsDelta)
            }
            : finalCalls
        for call in calls {
            await channel.send(
                .toolCalls(
                    action: .toolCall(
                        id: call.id,
                        name: call.name,
                        action: .appendArguments(call.argumentsJSON, tokenCount: Self.estimatedTokens(call.argumentsJSON))
                    )
                )
            )
        }
        if let usage {
            await channel.send(
                .response(
                    action: .updateUsage(
                        input: .init(
                            totalTokenCount: usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens,
                            cachedTokenCount: usage.cacheReadTokens
                        ),
                        output: .init(totalTokenCount: usage.outputTokens, reasoningTokenCount: usage.reasoningTokens)
                    )
                )
            )
        }
    }

    /// Rough token estimate (4 UTF-8 bytes per token) for providers that stream text without counts.
    static func estimatedTokens(_ text: String) -> Int {
        text.isEmpty ? 0 : Swift.max(1, (text.utf8.count + 3) / 4)
    }
}

/// Stores provider reasoning signatures (strings) in `Transcript.Reasoning.signature` (bytes) so they
/// round-trip unchanged through a Foundation Models session.
enum OpenClawBridgeReasoningSignature {
    /// Marks signatures stored by ``OpenClawLanguageModelExecutor``.
    static let prefix = Data("openclaw-signature:".utf8)

    /// Bytes stored on the framework's reasoning entry for a provider signature.
    static func data(for signature: String) -> Data {
        Self.prefix + Data(signature.utf8)
    }

    /// The provider signature stored by the bridge, or `nil` for missing or foreign signatures.
    static func signature(from data: Data?) -> String? {
        guard let data, data.starts(with: Self.prefix) else { return nil }
        let signature = String(decoding: data.dropFirst(Self.prefix.count), as: UTF8.self)
        return signature.isEmpty ? nil : signature
    }
}

/// Converts between Foundation Models executor requests and OpenClaw contract v2 requests.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
enum OpenClawTranscriptConverter {
    static func request(from request: LanguageModelExecutorGenerationRequest, model: OpenClawLanguageModel) throws -> ModelGenerationRequest {
        var system: [String] = []
        var messages: [ModelMessage] = []
        var assistant: [ModelAssistantPart] = []
        func flushAssistant() {
            if !assistant.isEmpty {
                messages.append(.assistant(content: assistant))
                assistant = []
            }
        }
        for entry in request.transcript {
            switch entry {
            case .instructions(let instructions):
                let text = Self.text(instructions.segments)
                if !text.isEmpty { system.append(text) }
            case .prompt(let prompt):
                flushAssistant()
                messages.append(.user(content: try Self.parts(prompt.segments)))
            case .response(let response):
                let text = Self.text(response.segments)
                if !text.isEmpty { assistant.append(.text(text)) }
            case .reasoning(let reasoning):
                // Only signatures this bridge stored come back; other models' signatures are opaque here.
                assistant.append(.thinking(Self.text(reasoning.segments), signature: OpenClawBridgeReasoningSignature.signature(from: reasoning.signature)))
            case .toolCalls(let calls):
                for call in calls {
                    assistant.append(.toolCall(ModelToolCall(id: call.id, name: call.toolName, argumentsJSON: call.arguments.jsonString)))
                }
            case .toolOutput(let output):
                flushAssistant()
                messages.append(.toolResult(ModelToolResult(toolCallID: output.id, toolName: output.toolName, content: try Self.parts(output.segments))))
            @unknown default:
                continue
            }
        }
        flushAssistant()

        let options = request.generationOptions
        var topK: Int?
        var topP: Double?
        var hints: [String: String] = [:]
        if let kind = options.samplingMode?.kind {
            switch kind {
            case .greedy:
                topK = 1
            case .randomTopK(let k, let seed):
                topK = k
                hints["seed"] = seed.map(String.init)
            case .randomProbabilityThreshold(let p, let seed):
                topP = p
                hints["seed"] = seed.map(String.init)
            @unknown default:
                break
            }
        }
        let thinking = request.contextOptions.reasoningLevel.map(Self.thinkLevel)
        let policy = ModelGenerationPolicy(
            streamTokens: true,
            maxTokens: options.maximumResponseTokens,
            temperature: options.temperature,
            topP: topP,
            topK: topK,
            localRuntimeHints: hints,
            thinkingLevel: thinking
        )
        let tools = request.enabledToolDefinitions.map { definition in
            ModelToolDefinition(
                name: definition.name,
                description: definition.description,
                parameters: FoundationModelsSchemaConverter.jsonSchema(from: definition.parameters)
            )
        }
        var toolChoice = ModelToolChoice.auto
        if let mode = options.toolCallingMode?.kind {
            switch mode {
            case .allowed:
                toolChoice = .auto
            case .required:
                toolChoice = .required
            case .disallowed:
                toolChoice = .none
            @unknown default:
                toolChoice = .auto
            }
        }
        let responseFormat: ModelResponseFormat = request.schema.map { schema in
            .jsonSchema(name: schema.name, schema: FoundationModelsSchemaConverter.jsonSchema(from: schema), strict: true)
        } ?? .text
        var metadata: [String: String] = [:]
        for (key, value) in request.metadata {
            if case .string(let string) = value.kind {
                metadata[key] = string
            } else {
                metadata[key] = value.jsonString
            }
        }
        let lastUserText = messages.last(where: { $0.role == .user })?.text ?? ""
        let prompt = model.provider.capabilities.supportsTranscript ? lastUserText : Self.flattened(messages)
        return ModelGenerationRequest(
            sessionKey: "apple-fm-bridge-\(request.id.uuidString)",
            prompt: prompt,
            systemPrompt: system.isEmpty ? nil : system.joined(separator: "\n\n"),
            providerID: model.providerID,
            modelID: model.modelID,
            metadata: metadata,
            policy: policy,
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat
        )
    }

    /// Transcript flattened into one prompt for providers that ignore ``ModelGenerationRequest/messages``.
    static func flattened(_ messages: [ModelMessage]) -> String {
        messages.compactMap { message -> String? in
            let text = message.text
            guard !text.isEmpty else { return nil }
            switch message.role {
            case .user: return "User: \(text)"
            case .assistant: return "Assistant: \(text)"
            case .tool: return "Tool result: \(text)"
            case .system: return "System: \(text)"
            }
        }.joined(separator: "\n\n")
    }

    static func thinkLevel(_ level: ContextOptions.ReasoningLevel) -> ThinkLevel {
        switch level {
        case .light:
            return .low
        case .moderate:
            return .medium
        case .deep:
            return .high
        case .custom(let raw):
            return ThinkLevel(rawValue: raw.lowercased()) ?? .medium
        @unknown default:
            return .medium
        }
    }

    static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text):
                return text.content
            case .structure(let structure):
                return structure.content.jsonString
            case .attachment:
                return nil
            @unknown default:
                return nil
            }
        }.joined(separator: "\n")
    }

    static func parts(_ segments: [Transcript.Segment]) throws -> [ModelContentPart] {
        try segments.compactMap { segment -> ModelContentPart? in
            switch segment {
            case .text(let text):
                return .text(text.content)
            case .structure(let structure):
                return .text(structure.content.jsonString)
            case .attachment(let attachment):
                switch attachment.content {
                case .image(let image):
                    return .image(try Self.pngAttachment(image, label: attachment.label))
                @unknown default:
                    return nil
                }
            @unknown default:
                return nil
            }
        }
    }

    static func pngAttachment(_ image: Transcript.ImageAttachment, label: String?) throws -> MediaAttachment {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw FoundationModelsError.invalidRequest("Could not encode an image attachment")
        }
        CGImageDestinationAddImage(destination, image.cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FoundationModelsError.invalidRequest("Could not encode an image attachment")
        }
        return MediaAttachment(mimeType: "image/png", data: data as Data, fileName: label.map { "\($0).png" })
        #else
        throw FoundationModelsError.invalidRequest(FoundationModelsTranscriptPlanner.textOnlyMessage)
        #endif
    }

    /// Maps provider errors onto `LanguageModelError` so Foundation Models clients handle every
    /// backend uniformly (context overflow, rate limits, timeouts, guardrails, refusals).
    static func frameworkError(_ error: any Error) -> any Error {
        if error is CancellationError || error is LanguageModelError {
            return error
        }
        if let modelError = error as? FoundationModelsError {
            switch modelError.code {
            case .contextOverflow:
                return LanguageModelError.contextSizeExceeded(
                    .init(contextSize: modelError.contextSize ?? 0, tokenCount: modelError.tokenCount ?? 0, debugDescription: modelError.message)
                )
            case .rateLimited:
                return LanguageModelError.rateLimited(.init(resetDate: modelError.resetDate, debugDescription: modelError.message))
            case .timeout:
                return LanguageModelError.timeout(.init(debugDescription: modelError.message))
            case .guardrail:
                return LanguageModelError.guardrailViolation(.init(debugDescription: modelError.message))
            case .refusal:
                return LanguageModelError.refusal(.init(explanation: modelError.message, debugDescription: modelError.message))
            default:
                return error
            }
        }
        let description = String(describing: error).lowercased()
        if description.contains("context") && (description.contains("exceed") || description.contains("too long") || description.contains("overflow")) {
            return LanguageModelError.contextSizeExceeded(.init(contextSize: 0, tokenCount: 0, debugDescription: String(describing: error)))
        }
        if description.contains("rate limit") || description.contains("rate_limit") || description.contains("429") {
            return LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: String(describing: error)))
        }
        if description.contains("timed out") || description.contains("timeout") {
            return LanguageModelError.timeout(.init(debugDescription: String(describing: error)))
        }
        return error
    }
}

/// ``ModelProvider`` that forwards to a ``ModelRouter`` with a fixed provider identifier.
struct OpenClawRoutedModelProvider: ModelProvider {
    let router: ModelRouter
    let id: String

    var capabilities: ModelProviderCapabilities {
        ModelProviderCapabilities(
            supportsStreaming: true,
            supportsTools: true,
            supportsJSONSchema: true,
            supportsImages: true,
            supportsReasoning: true,
            supportsTranscript: true
        )
    }

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.router.generate(self.routed(request))
    }

    func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        await self.router.generateStream(self.routed(request))
    }

    func cancelGeneration(token: String?) async {
        await self.router.cancelGeneration(token: token)
    }

    private func routed(_ request: ModelGenerationRequest) -> ModelGenerationRequest {
        ModelGenerationRequest(
            sessionKey: request.sessionKey,
            prompt: request.prompt,
            systemPrompt: request.systemPrompt,
            providerID: self.id,
            modelID: request.modelID,
            preferredAuthProfileID: request.preferredAuthProfileID,
            metadata: request.metadata,
            headers: request.headers,
            policy: request.policy,
            attachments: request.attachments,
            messages: request.messages,
            tools: request.tools,
            toolChoice: request.toolChoice,
            responseFormat: request.responseFormat
        )
    }
}
#endif
