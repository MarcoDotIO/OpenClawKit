import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Anthropic Messages request/response mapping for contract v2 (upstream
/// `packages/ai/src/transports/anthropic-messages.ts`, `anthropic-transport-stream.ts`,
/// `packages/ai/src/providers/anthropic-model-contract.ts`, `extensions/anthropic/stream-wrappers.ts`).
enum AnthropicMessagesWire {
    static let defaultBaseURL = "https://api.anthropic.com"
    static let defaultAPIVersion = "2023-06-01"
    static let defaultBetas = ["fine-grained-tool-streaming-2025-05-14", "interleaved-thinking-2025-05-14"]
    static let oauthBetas = ["claude-code-20250219", "oauth-2025-04-20"]
    static let retiredBetas: Set<String> = ["context-1m-2025-08-07"]
    static let defaultThinkingBudgetTokens = 1024
    static let emptyMessagesFallbackText = "(no content)"

    /// Resolves the Messages endpoint: base without trailing slashes, plus `/messages` when it ends in
    /// `/v1`, otherwise `/v1/messages` (upstream `resolveAnthropicMessagesUrl`). A non-default
    /// `messagesPath` is appended verbatim.
    static func messagesURL(baseURL: String, messagesPath: String) -> String {
        let base = ProviderEndpointSettings.trimmingTrailingSlashes(baseURL.isEmpty ? self.defaultBaseURL : baseURL)
        let path = messagesPath.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty, path != "messages" {
            return "\(base)/\(path)"
        }
        return base.hasSuffix("/v1") ? "\(base)/messages" : "\(base)/v1/messages"
    }

    /// Anthropic tool ids accept only ASCII word characters and dashes (max 64).
    static func normalizeToolCallID(_ id: String) -> String {
        let mapped = String(id.map { character -> Character in
            (character.isASCII && (character.isLetter || character.isNumber)) || character == "_" || character == "-" ? character : "_"
        })
        return String(mapped.prefix(64))
    }

    struct ThinkingPlan {
        var thinking: [String: Any]?
        var outputEffort: String?
        var thinkingEnabled: Bool
    }

    struct BuildContext {
        var providerID: String
        var modelID: String
        var model: ModelDefinitionConfig?
        var identity: ClaudeModelIdentity
        var maxTokens: Int
        var stream: Bool
        var isDirectAnthropic: Bool
        var cacheControl: [String: Any]?
    }

    // MARK: - Request

    static func thinkingPlan(request: ModelGenerationRequest, model: ModelDefinitionConfig?, identity: ClaudeModelIdentity) -> ThinkingPlan {
        let level: ThinkLevel?
        if let requested = request.policy.thinkingLevel ?? ThinkLevel.normalize(request.metadata["thinkingLevel"]) {
            level = requested
        } else if let effort = request.policy.reasoningEffort {
            switch effort {
            case .none:
                level = .off
            case .minimal:
                level = .minimal
            case .low:
                level = .low
            case .medium:
                level = .medium
            case .high:
                level = .high
            case .xhigh:
                level = .xhigh
            case .max:
                level = .max
            }
        } else {
            level = nil
        }
        let mandatory = identity.requiresMandatoryAdaptiveThinking
        let thinkingEnabled = mandatory || (level != nil && level != .off)
        let reasoningCapable = mandatory || (model?.reasoning ?? true) || identity.supportsAdaptiveThinking
        guard reasoningCapable else {
            return ThinkingPlan(thinking: nil, outputEffort: nil, thinkingEnabled: false)
        }
        if thinkingEnabled {
            if identity.supportsAdaptiveThinking {
                let effort = identity.effort(for: level, thinkingLevelMap: model?.thinkingLevelMap)
                return ThinkingPlan(thinking: ["type": "adaptive", "display": "summarized"], outputEffort: effort, thinkingEnabled: true)
            }
            return ThinkingPlan(
                thinking: ["type": "enabled", "budget_tokens": self.defaultThinkingBudgetTokens],
                outputEffort: nil,
                thinkingEnabled: true
            )
        }
        if level == .off {
            return ThinkingPlan(thinking: ["type": "disabled"], outputEffort: nil, thinkingEnabled: false)
        }
        return ThinkingPlan(thinking: nil, outputEffort: nil, thinkingEnabled: false)
    }

    static func buildPayload(request: ModelGenerationRequest, context: BuildContext) -> [String: Any] {
        let identity = context.identity
        let thinking = self.thinkingPlan(request: request, model: context.model, identity: identity)
        var maxTokens = context.maxTokens
        if let budget = thinking.thinking?["budget_tokens"] as? Int, maxTokens <= budget {
            maxTokens = budget + 1024
        }
        var payload: [String: Any] = [
            "model": context.modelID,
            "max_tokens": maxTokens,
            "messages": self.buildMessages(request: request, context: context),
        ]
        if var system = self.systemPrompt(request: request) {
            if case .jsonSchema(let name, let schema, _) = request.responseFormat {
                system += "\n\n" + self.jsonSchemaInstruction(name: name, schema: schema)
            } else if request.responseFormat == .jsonObject {
                system += "\n\nRespond with a single valid JSON object and no other text."
            }
            if let cacheControl = context.cacheControl {
                payload["system"] = [["type": "text", "text": system, "cache_control": cacheControl]]
            } else {
                payload["system"] = system
            }
        } else if let instruction = self.responseFormatInstruction(request.responseFormat) {
            payload["system"] = instruction
        }
        if context.stream {
            payload["stream"] = true
        }
        if let thinkingPayload = thinking.thinking {
            payload["thinking"] = thinkingPayload
        }
        if let effort = thinking.outputEffort {
            payload["output_config"] = ["effort": effort]
        }
        if !thinking.thinkingEnabled, !identity.requiresDefaultSampling, !identity.isOpus5, !identity.isSonnet5 {
            if let temperature = request.policy.temperature {
                payload["temperature"] = temperature
            }
            if let topP = request.policy.topP {
                payload["top_p"] = topP
            }
            if let topK = request.policy.topK {
                payload["top_k"] = topK
            }
        }
        let tools = self.buildTools(request.tools, compat: context.model?.compat, cacheControl: context.cacheControl)
        if !tools.isEmpty {
            payload["tools"] = tools
            if let choice = self.toolChoice(request.toolChoice, thinkingEnabled: thinking.thinkingEnabled) {
                payload["tool_choice"] = choice
            }
        }
        return payload
    }

    private static func systemPrompt(request: ModelGenerationRequest) -> String? {
        ProviderContentText.systemPrompt(for: request)
    }

    private static func responseFormatInstruction(_ format: ModelResponseFormat) -> String? {
        switch format {
        case .text:
            return nil
        case .jsonObject:
            return "Respond with a single valid JSON object and no other text."
        case .jsonSchema(let name, let schema, _):
            return self.jsonSchemaInstruction(name: name, schema: schema)
        }
    }

    static func jsonSchemaInstruction(name: String, schema: [String: AnyCodable]) -> String {
        "Respond with a single JSON value named \"\(name)\" that validates against this JSON Schema, and no other text:\n"
            + ProviderWireJSON.compactText(schema)
    }

    static func buildTools(_ tools: [ModelToolDefinition], compat: ModelCompatConfig?, cacheControl: [String: Any]?) -> [[String: Any]] {
        var converted = tools.map { tool -> [String: Any] in
            var item: [String: Any] = [
                "name": tool.name,
                "input_schema": ProviderWireJSON.foundation(tool.parameters),
            ]
            if !tool.description.isEmpty {
                item["description"] = tool.description
            }
            if compat?.supportsEagerToolInputStreaming == true {
                item["eager_input_streaming"] = true
            }
            return item
        }
        if let cacheControl, !converted.isEmpty {
            converted[converted.count - 1]["cache_control"] = cacheControl
        }
        return converted
    }

    static func toolChoice(_ choice: ModelToolChoice, thinkingEnabled: Bool) -> [String: Any]? {
        switch choice {
        case .auto:
            return nil
        case .none:
            return ["type": "none"]
        case .required:
            return thinkingEnabled ? ["type": "auto"] : ["type": "any"]
        case .named(let name):
            return thinkingEnabled ? ["type": "auto"] : ["type": "tool", "name": name]
        }
    }

    static func buildMessages(request: ModelGenerationRequest, context: BuildContext) -> [[String: Any]] {
        let supportsImages = context.model.map { $0.input.contains(.image) } ?? true
        var transcript = request.resolvedMessages
        if context.identity.isOpus5 || context.identity.isSonnet5 {
            // Opus 5 and Sonnet 5 reject assistant prefills; keep completed tool-use turns.
            while let last = transcript.last, case .assistant(let parts) = last,
                  !parts.contains(where: { if case .toolCall = $0 { return true } else { return false } })
            {
                transcript.removeLast()
            }
        }
        var messages: [[String: Any]] = []
        var index = 0
        while index < transcript.count {
            switch transcript[index] {
            case .system:
                break
            case .user(let content):
                if let blocks = self.userBlocks(content, legacy: request.messages.isEmpty, supportsImages: supportsImages) {
                    messages.append(["role": "user", "content": blocks])
                }
            case .assistant(let parts):
                var blocks: [[String: Any]] = []
                for part in parts {
                    switch part {
                    case .text(let text):
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            blocks.append(["type": "text", "text": text])
                        }
                    case .thinking(let text, let signature):
                        if let signature, !signature.isEmpty, signature != "reasoning_content" {
                            blocks.append(["type": "thinking", "thinking": text, "signature": signature])
                        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            blocks.append(["type": "text", "text": text])
                        }
                    case .toolCall(let call):
                        blocks.append([
                            "type": "tool_use",
                            "id": self.normalizeToolCallID(call.id),
                            "name": call.name,
                            "input": ProviderWireJSON.argumentsObject(call.argumentsJSON),
                        ])
                    }
                }
                if !blocks.isEmpty {
                    messages.append(["role": "assistant", "content": blocks])
                }
            case .toolResult:
                var results: [[String: Any]] = []
                while index < transcript.count, case .toolResult(let result) = transcript[index] {
                    results.append([
                        "type": "tool_result",
                        "tool_use_id": self.normalizeToolCallID(result.toolCallID),
                        "content": self.toolResultContent(result, supportsImages: supportsImages),
                        "is_error": result.isError,
                    ])
                    index += 1
                }
                index -= 1
                messages.append(["role": "user", "content": results])
            }
            index += 1
        }
        if messages.isEmpty {
            messages = [["role": "user", "content": self.emptyMessagesFallbackText]]
        }
        if let cacheControl = context.cacheControl {
            self.markLastTextBlock(in: &messages, cacheControl: cacheControl)
        }
        return messages
    }

    private static func userBlocks(_ content: [ModelContentPart], legacy: Bool, supportsImages: Bool) -> Any? {
        if legacy {
            let prompt = content.compactMap(\.text).joined()
            let attachments = content.compactMap(\.mediaAttachment)
            switch AnthropicStyleMultimodalSupport.userContent(prompt: prompt, attachments: attachments) {
            case .text(let text):
                return text.isEmpty ? self.emptyMessagesFallbackText : text
            case .blocks(let blocks):
                return blocks.map(self.foundationBlock)
            }
        }
        var blocks: [[String: Any]] = []
        for part in content {
            switch part {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
            case .image(let attachment):
                if supportsImages {
                    blocks.append(self.imageBlock(attachment))
                } else {
                    blocks.append(["type": "text", "text": "(image omitted: model does not support images)"])
                }
            case .attachment(let attachment):
                blocks.append(["type": "text", "text": ProviderContentText.flatten([.attachment(attachment)])])
            }
        }
        return blocks.isEmpty ? nil : blocks
    }

    private static func toolResultContent(_ result: ModelToolResult, supportsImages: Bool) -> Any {
        let images = result.content.compactMap { part -> MediaAttachment? in
            if case .image(let attachment) = part { return attachment }
            return nil
        }
        guard !images.isEmpty, supportsImages else {
            return ProviderContentText.toolResultText(result)
        }
        var blocks: [[String: Any]] = []
        let text = result.content.compactMap(\.text).joined(separator: "\n")
        blocks.append(["type": "text", "text": text.isEmpty ? "(see attached image)" : text])
        blocks.append(contentsOf: images.map(self.imageBlock))
        return blocks
    }

    private static func imageBlock(_ attachment: MediaAttachment) -> [String: Any] {
        let mime = MultimodalAttachmentUtilities.normalizedMimeType(for: attachment)
        return ["type": "image", "source": ["type": "base64", "media_type": mime, "data": attachment.data.base64EncodedString()]]
    }

    private static func foundationBlock(_ block: AnthropicMessageBlock) -> [String: Any] {
        switch block {
        case .text(let text):
            return ["type": "text", "text": text]
        case .imageBase64(let mediaType, let data):
            return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data]]
        }
    }

    private static func markLastTextBlock(in messages: inout [[String: Any]], cacheControl: [String: Any]) {
        for messageIndex in messages.indices.reversed() {
            guard let role = messages[messageIndex]["role"] as? String, role == "user" || role == "assistant" else { continue }
            if let text = messages[messageIndex]["content"] as? String {
                messages[messageIndex]["content"] = [["type": "text", "text": text, "cache_control": cacheControl]]
                return
            }
            guard var blocks = messages[messageIndex]["content"] as? [[String: Any]] else { continue }
            if let blockIndex = blocks.lastIndex(where: { ($0["type"] as? String) == "text" }) {
                blocks[blockIndex]["cache_control"] = cacheControl
                messages[messageIndex]["content"] = blocks
                return
            }
        }
    }

    /// Beta header value: configured betas plus defaults (direct Anthropic), OAuth and extra betas,
    /// without the retired 1M-context beta.
    static func betaHeader(configured: String?, isDirect: Bool, oauth: Bool, extra: [String]) -> String? {
        var betas: [String] = []
        if oauth, isDirect {
            betas.append(contentsOf: self.oauthBetas)
        }
        if isDirect {
            betas.append(contentsOf: self.defaultBetas)
        }
        if let configured {
            betas.append(contentsOf: configured.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        betas.append(contentsOf: extra)
        var seen = Set<String>()
        let unique = betas.filter { !$0.isEmpty && !self.retiredBetas.contains($0) && seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: ",")
    }

    // MARK: - Response

    static func stopReason(_ raw: String?) -> ModelStopReason? {
        guard let raw else { return nil }
        switch raw {
        case "end_turn", "pause_turn", "compaction", "stop_sequence":
            return .stop
        case "max_tokens", "model_context_window_exceeded":
            return .length
        case "tool_use":
            return .toolUse
        case "refusal", "sensitive":
            return .refusal
        default:
            return ModelStopReason(providerValue: raw)
        }
    }

    static func usage(_ value: AnyCodable?) -> ModelUsage? {
        guard let value, value.dictionaryValue != nil else { return nil }
        return ModelUsage(
            inputTokens: value.wireInt("input_tokens") ?? 0,
            outputTokens: value.wireInt("output_tokens") ?? 0,
            cacheReadTokens: value.wireInt("cache_read_input_tokens") ?? 0,
            cacheWriteTokens: value.wireInt("cache_creation_input_tokens") ?? 0
        )
    }

    static func parseResponse(_ data: Data, providerID: String, modelID: String) throws -> ModelGenerationResponse {
        let root = try ProviderWireJSON.decode(data)
        var text = ""
        var reasoning = ""
        var toolCalls: [ModelToolCall] = []
        for block in root[wireKey: "content"]?.arrayValue ?? [] {
            switch block.wireString("type") {
            case "text"?:
                if let value = block[wireKey: "text"]?.stringValue {
                    text += value
                }
            case "thinking"?:
                if let value = block[wireKey: "thinking"]?.stringValue {
                    reasoning += value
                }
            case "tool_use"?:
                guard let name = block.wireString("name") else { continue }
                toolCalls.append(
                    ModelToolCall(
                        id: block.wireString("id") ?? ProviderToolCallIDs.synthesize(index: toolCalls.count),
                        name: name,
                        argumentsJSON: OpenAIChatCompletionsWire.argumentsString(block[wireKey: "input"])
                    )
                )
            default:
                break
            }
        }
        let stopReason = self.stopReason(root.wireString("stop_reason"))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, toolCalls.isEmpty, stopReason != .refusal {
            throw OpenClawCoreError.unavailable("\(providerID) response did not include text content")
        }
        return ModelGenerationResponse(
            text: toolCalls.isEmpty ? trimmed : text,
            providerID: providerID,
            modelID: root.wireString("model") ?? modelID,
            toolCalls: toolCalls,
            usage: self.usage(root[wireKey: "usage"]),
            stopReason: stopReason,
            reasoningText: reasoning.isEmpty ? nil : reasoning
        )
    }

    // MARK: - Stream

    struct StreamState {
        var toolIndexByBlock: [Int: Int] = [:]
        var inputTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0
        var outputTokens = 0
        var sawUsage = false
        var failure: String?
    }

    static func handleStreamEvent(
        _ event: ServerSentEvent,
        state: inout StreamState,
        assembler: inout ProviderStreamAssembler
    ) -> [ModelStreamChunk] {
        guard let object = ProviderWireJSON.object(from: event.data) else { return [] }
        let payload = AnyCodable(.object(object))
        var chunks: [ModelStreamChunk] = []
        switch payload.wireString("type") ?? event.event ?? "" {
        case "message_start":
            let message = payload[wireKey: "message"]
            if let model = message?.wireString("model") {
                assembler.modelID = model
            }
            if let usage = message?[wireKey: "usage"] {
                self.mergeUsage(usage, state: &state)
            }
        case "content_block_start":
            let blockIndex = payload.wireInt("index") ?? 0
            let block = payload[wireKey: "content_block"]
            switch block?.wireString("type") {
            case "tool_use"?:
                let toolIndex = assembler.nextToolCallIndex
                state.toolIndexByBlock[blockIndex] = toolIndex
                chunks.append(assembler.appendToolCall(index: toolIndex, id: block?.wireString("id"), name: block?.wireString("name"), argumentsDelta: ""))
            case "text"?:
                if let text = block?[wireKey: "text"]?.stringValue, let chunk = assembler.appendText(text) {
                    chunks.append(chunk)
                }
            case "thinking"?:
                if let thinking = block?[wireKey: "thinking"]?.stringValue, let chunk = assembler.appendReasoning(thinking) {
                    chunks.append(chunk)
                }
            default:
                break
            }
        case "content_block_delta":
            let blockIndex = payload.wireInt("index") ?? 0
            let delta = payload[wireKey: "delta"]
            switch delta?.wireString("type") {
            case "text_delta"?:
                if let text = delta?[wireKey: "text"]?.stringValue, let chunk = assembler.appendText(text) {
                    chunks.append(chunk)
                }
            case "thinking_delta"?:
                if let thinking = delta?[wireKey: "thinking"]?.stringValue, let chunk = assembler.appendReasoning(thinking) {
                    chunks.append(chunk)
                }
            case "signature_delta"?:
                if let signature = delta?[wireKey: "signature"]?.stringValue {
                    assembler.setReasoningSignature(signature)
                }
            case "input_json_delta"?:
                if let toolIndex = state.toolIndexByBlock[blockIndex] {
                    chunks.append(
                        assembler.appendToolCall(index: toolIndex, id: nil, name: nil, argumentsDelta: delta?[wireKey: "partial_json"]?.stringValue ?? "")
                    )
                }
            default:
                break
            }
        case "message_delta":
            if let reason = payload[wireKey: "delta"]?.wireString("stop_reason") {
                assembler.stopReason = self.stopReason(reason)
            }
            if let usage = payload[wireKey: "usage"] {
                self.mergeUsage(usage, state: &state)
                chunks.append(
                    assembler.setUsage(
                        ModelUsage(
                            inputTokens: state.inputTokens,
                            outputTokens: state.outputTokens,
                            cacheReadTokens: state.cacheReadTokens,
                            cacheWriteTokens: state.cacheWriteTokens
                        )
                    )
                )
            }
        case "error":
            state.failure = payload[wireKey: "error"]?.wireString("message") ?? "stream error"
        default:
            break
        }
        return chunks
    }

    private static func mergeUsage(_ usage: AnyCodable, state: inout StreamState) {
        state.sawUsage = true
        if let input = usage.wireInt("input_tokens"), input > 0 {
            state.inputTokens = input
        }
        if let read = usage.wireInt("cache_read_input_tokens"), read > 0 {
            state.cacheReadTokens = read
        }
        if let write = usage.wireInt("cache_creation_input_tokens"), write > 0 {
            state.cacheWriteTokens = write
        }
        if let output = usage.wireInt("output_tokens") {
            state.outputTokens = output
        }
    }
}

/// Anthropic Messages engine shared by the direct Anthropic provider and Anthropic-compatible routes.
struct AnthropicMessagesEngine: Sendable {
    let settings: ProviderEndpointSettings
    let exchange: ProviderHTTPExchange
    /// Default output-token limit when neither the request nor the config sets one.
    let defaultMaxTokens: Int

    static let capabilities = ModelProviderCapabilities(
        supportsStreaming: true,
        supportsTools: true,
        supportsParallelToolCalls: true,
        supportsJSONSchema: false,
        supportsImages: true,
        supportsReasoning: true,
        supportsTranscript: true
    )

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        let prepared = try self.prepare(request, stream: false)
        let response = try await self.exchange.data(for: prepared.urlRequest)
        return try AnthropicMessagesWire.parseResponse(response.body, providerID: self.settings.providerID, modelID: prepared.modelID)
    }

    func stream(_ request: ModelGenerationRequest) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        let providerID = self.settings.providerID
        return ProviderStreamSupport.makeStream { continuation in
            let prepared = try self.prepare(request, stream: true)
            let lines = try await self.exchange.lines(for: prepared.urlRequest)
            var assembler = ProviderStreamAssembler(providerID: providerID, modelID: prepared.modelID)
            var parser = ServerSentEventParser()
            var state = AnthropicMessagesWire.StreamState()
            for try await line in lines {
                guard let event = parser.consume(line) else { continue }
                AnthropicMessagesWire.handleStreamEvent(event, state: &state, assembler: &assembler).forEach { continuation.yield($0) }
            }
            if let event = parser.finish() {
                AnthropicMessagesWire.handleStreamEvent(event, state: &state, assembler: &assembler).forEach { continuation.yield($0) }
            }
            if let failure = state.failure {
                throw OpenClawCoreError.unavailable("\(providerID) stream failed: \(failure)")
            }
            continuation.yield(.completed(response: assembler.response()))
        }
    }

    struct Prepared {
        var urlRequest: URLRequest
        var modelID: String
    }

    func prepare(_ request: ModelGenerationRequest, stream: Bool) throws -> Prepared {
        let settings = self.settings
        guard settings.enabled else {
            throw OpenClawCoreError.unavailable("\(settings.providerID) model provider is disabled")
        }
        var modelID = settings.resolvedModelID(for: request)
        let model = settings.modelDefinition(for: modelID)
        try ProviderRequestValidation.validate(request, providerID: settings.providerID, model: model)
        let baseURLString = settings.resolvedBaseURLString(for: request, defaultBaseURL: AnthropicMessagesWire.defaultBaseURL)
        let credential = try self.credential(for: request)
        let usesOAuth = settings.authMode == .oauthToken || settings.authMode == .bearerToken
            || (credential?.hasPrefix("sk-ant-oat") ?? false)
        let isDirect = ProviderRuntimeIdentity.canonicalProviderID(settings.providerID) == "anthropic"
            && [.default, .anthropicPublic].contains(ModelProviderEndpointClass.resolve(baseURL: baseURLString))
        let fastEnabled = FastModeResolution.resolve(request: request, configured: settings.configuredFastMode, model: model)
        if fastEnabled == true,
           let fastModel = FastModeModelSwap.fastModelID(providerID: settings.providerID, modelID: modelID, api: .anthropicMessages)
        {
            modelID = fastModel
        }
        let identity = ClaudeModelIdentity(modelID: modelID, params: model?.params)
        let cacheControl = self.cacheControl(request: request, model: model, isDirect: isDirect)
        let context = AnthropicMessagesWire.BuildContext(
            providerID: settings.providerID,
            modelID: modelID,
            model: model,
            identity: identity,
            maxTokens: settings.maxTokens(for: request, model: model) ?? self.defaultMaxTokens,
            stream: stream,
            isDirectAnthropic: isDirect,
            cacheControl: cacheControl
        )
        var payload = AnthropicMessagesWire.buildPayload(request: request, context: context)
        var extraBetas: [String] = []
        let runtimeID = model?.agentRuntime?.id ?? settings.runtime.providerConfig?.agentRuntime?.id
        let plan = AnthropicFastModeResolution.plan(
            providerID: settings.providerID,
            modelID: modelID,
            model: model,
            api: .anthropicMessages,
            baseURL: baseURLString,
            usesOAuth: usesOAuth,
            runtimeID: runtimeID
        )
        if let explicit = request.policy.serviceTier {
            payload["service_tier"] = AnthropicFastModeResolution.explicitServiceTier(explicit)
        } else if let fastEnabled {
            switch plan {
            case .native?:
                if fastEnabled {
                    payload.removeValue(forKey: "service_tier")
                    payload["speed"] = "fast"
                    extraBetas.append(AnthropicFastModeResolution.fastModeBeta)
                }
            case .serviceTier?:
                payload["service_tier"] = fastEnabled ? "auto" : "standard_only"
            case .unavailable?, nil:
                break
            }
        }
        if identity.isOpus5 || identity.isSonnet5 {
            payload.removeValue(forKey: "service_tier")
        }
        guard let endpoint = URL(string: AnthropicMessagesWire.messagesURL(baseURL: baseURLString, messagesPath: settings.messagesPath)),
              endpoint.scheme != nil
        else {
            throw OpenClawCoreError.invalidConfiguration("\(settings.providerID) base URL is invalid")
        }
        var urlRequest = settings.makeJSONRequest(url: endpoint, request: request, model: model, streaming: stream)
        if !settings.applyRequestAuthOverride(to: &urlRequest), let credential {
            if usesOAuth {
                urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            } else {
                urlRequest.setValue(credential, forHTTPHeaderField: "x-api-key")
            }
        }
        let apiVersion = ModelGenerationRequest.normalized(settings.apiVersion) ?? AnthropicMessagesWire.defaultAPIVersion
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        if let organizationID = ModelGenerationRequest.normalized(settings.organizationID) {
            urlRequest.setValue(organizationID, forHTTPHeaderField: "x-organization-id")
        }
        var headers = settings.mergedHeaders(for: request, model: model)
        let configuredBeta = headers.first(where: { $0.key.lowercased() == "anthropic-beta" })
        if let configuredBeta {
            headers.removeValue(forKey: configuredBeta.key)
        }
        if usesOAuth, isDirect {
            headers["anthropic-dangerous-direct-browser-access"] = headers["anthropic-dangerous-direct-browser-access"] ?? "true"
            headers["x-app"] = headers["x-app"] ?? "cli"
        }
        ProviderRequestResolution.applyHeaders(headers, request: &urlRequest)
        if let beta = AnthropicMessagesWire.betaHeader(configured: configuredBeta?.value, isDirect: isDirect, oauth: usesOAuth, extra: extraBetas) {
            urlRequest.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try ProviderWireJSON.encode(payload)
        return Prepared(urlRequest: urlRequest, modelID: modelID)
    }

    private func credential(for request: ModelGenerationRequest) throws -> String? {
        let settings = self.settings
        switch settings.authMode {
        case .awsSDK:
            throw OpenClawCoreError.invalidConfiguration(
                "\(settings.providerID) does not support aws-sdk auth mode for Anthropic-messages requests"
            )
        case .none:
            return nil
        default:
            return try settings.bearerCredential(for: request)
        }
    }

    private func cacheControl(request: ModelGenerationRequest, model: ModelDefinitionConfig?, isDirect: Bool) -> [String: Any]? {
        guard let cache = request.policy.promptCache, cache.enabled else { return nil }
        guard isDirect || model?.compat?.cacheControlFormat == .anthropic else { return nil }
        var control: [String: Any] = ["type": "ephemeral"]
        if cache.longRetention, model?.compat?.supportsLongCacheRetention != false {
            control["ttl"] = "1h"
        }
        return control
    }
}
