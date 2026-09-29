import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// OpenAI Responses payload policy by endpoint class (upstream
/// `packages/ai/src/transports/openai-responses-payload-policy.ts`).
///
/// Endpoint classes: `api.openai.com` → openai-public, `chatgpt.com` → openai (ChatGPT), `api.x.ai` →
/// xai-native, Azure hosts → azure-openai, no base → default, anything else → custom.
public struct OpenAIResponsesPayloadPolicy: Sendable, Equatable {
    /// Endpoint class of the route.
    public var endpointClass: ModelProviderEndpointClass
    /// Whether the system prompt goes in top-level `instructions` (else as an input message).
    public var usesInstructionsField: Bool
    /// Whether `service_tier` may be sent.
    public var allowsServiceTier: Bool
    /// Whether `store` may be sent as `true` (known native OpenAI/Azure routes).
    public var allowsStore: Bool
    /// Whether the route accepts the `store` field at all.
    public var supportsStoreField: Bool
    /// Whether `store` must be stripped (`compat.supportsStore == false`).
    public var shouldStripStore: Bool
    /// Whether `prompt_cache_key` / `prompt_cache_retention` must be stripped.
    public var shouldStripPromptCache: Bool
    /// Whether item-level `status` must be stripped from replayed input items.
    public var shouldStripInputStatus: Bool
    /// Whether the route is a verified native OpenAI route.
    public var usesKnownNativeOpenAIRoute: Bool

    /// Resolves the policy for one route.
    /// - Parameters:
    ///   - providerID: Provider identifier.
    ///   - api: Transport API.
    ///   - baseURL: Effective base URL (empty = provider default).
    ///   - compat: Optional model compat flags.
    public static func resolve(
        providerID: String,
        api: ModelAPI?,
        baseURL: String?,
        compat: ModelCompatConfig?
    ) -> OpenAIResponsesPayloadPolicy {
        let provider = ProviderRuntimeIdentity.canonicalProviderID(providerID)
        let endpoint = Self.endpointClass(baseURL: baseURL)
        let isResponsesAPI = api == .openAIResponses || api == .openAIChatGPTResponses || api == .azureOpenAIResponses
        let usesKnownNativeEndpoint = endpoint == .openAIPublic || endpoint == .openAIChatGPT || endpoint == .azureOpenAI
        let usesKnownNativeRoute = endpoint == .default ? provider == "openai" : usesKnownNativeEndpoint
        let usesProxyLikeEndpoint = endpoint != .default && !usesKnownNativeEndpoint
        let verifiedNativeRoute = endpoint == .default ? provider == "openai" : (endpoint == .openAIPublic || endpoint == .openAIChatGPT)
        let verifiedInstructions = verifiedNativeRoute || endpoint == .xaiNative
        let promptCacheSupport = compat?.supportsPromptCacheKey
        let stripPromptCache: Bool
        if promptCacheSupport == true {
            stripPromptCache = false
        } else if promptCacheSupport == false {
            stripPromptCache = isResponsesAPI
        } else {
            stripPromptCache = isResponsesAPI && usesProxyLikeEndpoint && endpoint != .xaiNative
        }
        let supportsStoreField = compat?.supportsStore != false && isResponsesAPI
        let responsesProviders: Set<String> = ["openai", "azure-openai", "azure-openai-responses"]
        let allowsStore = supportsStoreField && api != .openAIChatGPTResponses
            && responsesProviders.contains(provider) && usesKnownNativeEndpoint
        return OpenAIResponsesPayloadPolicy(
            endpointClass: endpoint,
            usesInstructionsField: compat?.supportsInstructions ?? verifiedInstructions,
            allowsServiceTier: OpenAIFastModeResolution.allowsServiceTier(providerID: provider, api: api, baseURL: baseURL ?? ""),
            allowsStore: allowsStore,
            supportsStoreField: supportsStoreField,
            shouldStripStore: compat?.supportsStore == false && isResponsesAPI,
            shouldStripPromptCache: stripPromptCache,
            shouldStripInputStatus: isResponsesAPI && !usesKnownNativeRoute,
            usesKnownNativeOpenAIRoute: usesKnownNativeRoute
        )
    }

    /// Responses endpoint class (only the classes the Responses policy distinguishes).
    /// - Parameter baseURL: Base URL string.
    public static func endpointClass(baseURL: String?) -> ModelProviderEndpointClass {
        switch ModelProviderEndpointClass.resolve(baseURL: baseURL) {
        case .default:
            return .default
        case .openAIPublic:
            return .openAIPublic
        case .openAIChatGPT:
            return .openAIChatGPT
        case .xaiNative:
            return .xaiNative
        case .azureOpenAI:
            return .azureOpenAI
        default:
            return .custom
        }
    }

    /// Applies store/prompt-cache/status stripping to a payload tree.
    func apply(to payload: inout [String: Any]) {
        if self.shouldStripStore {
            payload.removeValue(forKey: "store")
        }
        if self.shouldStripPromptCache {
            payload.removeValue(forKey: "prompt_cache_key")
            payload.removeValue(forKey: "prompt_cache_retention")
        }
        if self.shouldStripInputStatus, let input = payload["input"] as? [[String: Any]] {
            payload["input"] = input.map { item in
                var item = item
                item.removeValue(forKey: "status")
                return item
            }
        }
    }
}

/// OpenAI Responses request/response mapping for contract v2.
enum OpenAIResponsesWire {
    struct BuildContext {
        var providerID: String
        var modelID: String
        var model: ModelDefinitionConfig?
        var api: ModelAPI
        var baseURL: String
        var policy: OpenAIResponsesPayloadPolicy
        var stream: Bool
        var serviceTier: String?
        var maxTokens: Int?
        var isChatGPTRoute: Bool
        var supportsDeveloperRole: Bool
    }

    static let defaultChatGPTInstructions = "You are a helpful assistant."

    // MARK: - Request

    static func buildPayload(request: ModelGenerationRequest, context: BuildContext) -> [String: Any] {
        let policy = context.policy
        let systemPrompt = ModelGenerationRequest.normalized(request.systemPrompt)
        var input: [[String: Any]] = []
        var payload: [String: Any] = ["model": context.modelID]
        if context.isChatGPTRoute {
            payload["instructions"] = systemPrompt ?? Self.defaultChatGPTInstructions
        } else if let systemPrompt {
            if policy.usesInstructionsField {
                payload["instructions"] = systemPrompt
            } else {
                input.append(self.systemItem(systemPrompt, developer: context.supportsDeveloperRole))
            }
        }
        input.append(contentsOf: self.buildInput(request: request, context: context))
        payload["input"] = input
        payload["stream"] = context.stream
        if context.isChatGPTRoute {
            payload["store"] = false
            payload["include"] = ["reasoning.encrypted_content"]
            payload["text"] = ["verbosity": "low"]
            payload["prompt_cache_key"] = request.promptCacheKey
        } else if let store = request.policy.storeResponse {
            if store ? policy.allowsStore : policy.supportsStoreField {
                payload["store"] = store
            }
        } else if policy.allowsStore {
            payload["store"] = false
        }
        if let serviceTier = context.serviceTier {
            payload["service_tier"] = serviceTier
        }
        if let maxTokens = context.maxTokens, !context.isChatGPTRoute {
            payload["max_output_tokens"] = maxTokens
        }
        if ReasoningEffortResolver.supportsTemperature(modelID: context.modelID, compat: context.model?.compat, api: context.api) {
            if let temperature = request.policy.temperature {
                payload["temperature"] = temperature
            }
            if let topP = request.policy.topP, !context.isChatGPTRoute {
                payload["top_p"] = topP
            }
        }
        let tools = self.buildTools(request.tools, strictDefault: context.isChatGPTRoute ? false : nil)
        if !tools.isEmpty {
            payload["tools"] = tools
            if context.isChatGPTRoute {
                payload["tool_choice"] = "auto"
                payload["parallel_tool_calls"] = true
            }
            if let toolChoice = self.toolChoice(request.toolChoice) {
                payload["tool_choice"] = toolChoice
            }
        }
        if let format = self.textFormat(request.responseFormat) {
            var text = payload["text"] as? [String: Any] ?? [:]
            text["format"] = format
            payload["text"] = text
        }
        if let effort = self.reasoningEffort(request: request, context: context, tools: request.tools) {
            var reasoning: [String: Any] = ["effort": effort]
            if effort != "none", context.isChatGPTRoute || (request.policy.reasoningLevel.map { $0 != .off } ?? false) {
                reasoning["summary"] = "auto"
            }
            payload["reasoning"] = reasoning
        }
        if let cache = request.policy.promptCache, cache.enabled, !context.isChatGPTRoute {
            payload["prompt_cache_key"] = request.promptCacheKey
            if cache.longRetention, context.model?.compat?.supportsLongCacheRetention != false {
                payload["prompt_cache_retention"] = "24h"
            }
        }
        policy.apply(to: &payload)
        return payload
    }

    static func reasoningEffort(request: ModelGenerationRequest, context: BuildContext, tools: [ModelToolDefinition]) -> String? {
        var effort: String?
        if let level = request.policy.thinkingLevel ?? ThinkLevel.normalize(request.metadata["thinkingLevel"]) {
            effort = ReasoningEffortResolver.resolve(
                thinkingLevel: level,
                model: context.model,
                modelID: context.modelID,
                providerID: context.providerID,
                api: context.api
            )
        } else if let explicit = request.policy.reasoningEffort {
            effort = ReasoningEffortResolver.clamp(effort: explicit.rawValue, model: context.model, modelID: context.modelID, api: context.api)
        }
        if effort == "minimal", tools.contains(where: { $0.name == "web_search" }) {
            effort = ReasoningEffortResolver.clamp(effort: "low", model: context.model, modelID: context.modelID, api: context.api) ?? "low"
        }
        return effort
    }

    private static func systemItem(_ text: String, developer: Bool) -> [String: Any] {
        ["role": developer ? "developer" : "system", "content": [["type": "input_text", "text": text]]]
    }

    static func buildInput(request: ModelGenerationRequest, context: BuildContext) -> [[String: Any]] {
        let supportsImages = context.model.map { $0.input.contains(.image) } ?? true
        var items: [[String: Any]] = []
        for message in request.resolvedMessages {
            switch message {
            case .system(let content):
                let text = ProviderContentText.flatten(content)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    items.append(self.systemItem(text, developer: context.supportsDeveloperRole))
                }
            case .user(let content):
                let parts = self.userContent(content, legacy: request.messages.isEmpty, supportsImages: supportsImages)
                if !parts.isEmpty {
                    items.append(["role": "user", "content": parts])
                }
            case .assistant(let parts):
                for part in parts {
                    switch part {
                    case .text(let text):
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        items.append([
                            "type": "message",
                            "role": "assistant",
                            "content": [["type": "output_text", "text": text, "annotations": [Any]()]],
                            "status": "completed",
                        ])
                    case .thinking:
                        // Responses reasoning replay needs provider item ids and encrypted content.
                        continue
                    case .toolCall(let call):
                        items.append([
                            "type": "function_call",
                            "call_id": Self.callID(call.id),
                            "name": call.name,
                            "arguments": call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON,
                        ])
                    }
                }
            case .toolResult(let result):
                let images = result.content.compactMap { part -> MediaAttachment? in
                    if case .image(let attachment) = part { return attachment }
                    return nil
                }
                let output: Any
                if !images.isEmpty, supportsImages {
                    var parts: [[String: Any]] = []
                    let text = result.content.compactMap(\.text).joined(separator: "\n")
                    parts.append(["type": "input_text", "text": text.isEmpty ? "(see attached media)" : text])
                    for image in images {
                        parts.append(self.imagePart(image))
                    }
                    output = parts
                } else {
                    output = ProviderContentText.toolResultText(result)
                }
                items.append(["type": "function_call_output", "call_id": Self.callID(result.toolCallID), "output": output])
            }
        }
        return items
    }

    /// Call ids may be stored as `call_id|item_id`; only the call id is replayed.
    static func callID(_ id: String) -> String {
        guard let separator = id.firstIndex(of: "|") else { return id }
        return String(id[..<separator])
    }

    private static func userContent(_ content: [ModelContentPart], legacy: Bool, supportsImages: Bool) -> [[String: Any]] {
        if legacy, content.contains(where: { $0.mediaAttachment != nil }) {
            let prompt = content.compactMap(\.text).joined()
            let legacyContent = OpenAIStyleMultimodalSupport.userContent(prompt: prompt, attachments: content.compactMap(\.mediaAttachment))
            switch legacyContent {
            case .text(let text):
                return [["type": "input_text", "text": text]]
            case .parts(let parts):
                return parts.map { part in
                    switch part {
                    case .text(let text):
                        return ["type": "input_text", "text": text]
                    case .imageDataURL(let url):
                        return ["type": "input_image", "image_url": url]
                    }
                }
            }
        }
        var parts: [[String: Any]] = []
        for part in content {
            switch part {
            case .text(let text):
                if legacy || !text.isEmpty {
                    parts.append(["type": "input_text", "text": text])
                }
            case .image(let attachment):
                if supportsImages {
                    parts.append(self.imagePart(attachment))
                }
            case .attachment(let attachment):
                parts.append(["type": "input_text", "text": ProviderContentText.flatten([.attachment(attachment)])])
            }
        }
        return parts
    }

    private static func imagePart(_ attachment: MediaAttachment) -> [String: Any] {
        let mime = MultimodalAttachmentUtilities.normalizedMimeType(for: attachment)
        return ["type": "input_image", "detail": "auto", "image_url": "data:\(mime);base64,\(attachment.data.base64EncodedString())"]
    }

    static func buildTools(_ tools: [ModelToolDefinition], strictDefault: Bool?) -> [[String: Any]] {
        tools.sorted(by: { $0.name < $1.name }).map { tool in
            var item: [String: Any] = [
                "type": "function",
                "name": tool.name,
                "parameters": ProviderWireJSON.foundation(tool.parameters),
            ]
            if !tool.description.isEmpty {
                item["description"] = tool.description
            }
            if let strict = tool.strict ?? strictDefault {
                item["strict"] = strict
            }
            return item
        }
    }

    static func toolChoice(_ choice: ModelToolChoice) -> Any? {
        switch choice {
        case .auto:
            return nil
        case .none:
            return "none"
        case .required:
            return "required"
        case .named(let name):
            return ["type": "function", "name": name]
        }
    }

    static func textFormat(_ format: ModelResponseFormat) -> [String: Any]? {
        switch format {
        case .text:
            return nil
        case .jsonObject:
            return ["type": "json_object"]
        case .jsonSchema(let name, let schema, let strict):
            return ["type": "json_schema", "name": name, "schema": ProviderWireJSON.foundation(schema), "strict": strict]
        }
    }

    // MARK: - Response

    static func parseResponse(_ root: AnyCodable, providerID: String, modelID: String) -> ModelGenerationResponse {
        var text = ""
        var reasoning = ""
        var refusal: String?
        var toolCalls: [ModelToolCall] = []
        for item in root[wireKey: "output"]?.arrayValue ?? [] {
            switch item.wireString("type") {
            case "function_call"?:
                guard let name = item.wireString("name") else { continue }
                let callID = item.wireString("call_id") ?? item.wireString("id") ?? ProviderToolCallIDs.synthesize(index: toolCalls.count)
                toolCalls.append(ModelToolCall(id: callID, name: name, argumentsJSON: OpenAIChatCompletionsWire.argumentsString(item[wireKey: "arguments"])))
            case "reasoning"?:
                for summary in item[wireKey: "summary"]?.arrayValue ?? [] {
                    if let value = summary.wireString("text") {
                        reasoning += reasoning.isEmpty ? value : "\n\(value)"
                    }
                }
                for content in item[wireKey: "content"]?.arrayValue ?? [] where content.wireString("type") == "reasoning_text" {
                    if let value = content.wireString("text") {
                        reasoning += reasoning.isEmpty ? value : "\n\(value)"
                    }
                }
            default:
                for content in item[wireKey: "content"]?.arrayValue ?? [] {
                    switch content.wireString("type") {
                    case "refusal"?:
                        refusal = content.wireString("refusal") ?? refusal
                    case nil, "output_text"?, "text"?:
                        if let value = content[wireKey: "text"]?.stringValue {
                            text += text.isEmpty ? value : "\n\(value)"
                        }
                    default:
                        break
                    }
                }
            }
        }
        if text.isEmpty, let outputText = root[wireKey: "output_text"]?.stringValue {
            text = outputText
        }
        var stopReason = self.stopReason(root)
        if stopReason == .stop, !toolCalls.isEmpty {
            stopReason = .toolUse
        }
        if text.isEmpty, toolCalls.isEmpty, let refusal {
            text = refusal
            stopReason = .refusal
        }
        return ModelGenerationResponse(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            providerID: providerID,
            modelID: root.wireString("model") ?? modelID,
            toolCalls: toolCalls,
            usage: self.usage(root[wireKey: "usage"]),
            stopReason: stopReason ?? (toolCalls.isEmpty ? .stop : .toolUse),
            reasoningText: reasoning.isEmpty ? nil : reasoning
        )
    }

    static func stopReason(_ response: AnyCodable) -> ModelStopReason? {
        switch response.wireString("status") {
        case "incomplete"?:
            let reason = response[wireKey: "incomplete_details"]?.wireString("reason")
            if reason == "content_filter" {
                return .contentFilter
            }
            return .length
        case "failed"?:
            return .error
        case "cancelled"?:
            return .aborted
        case "completed"?:
            return .stop
        default:
            return nil
        }
    }

    static func usage(_ value: AnyCodable?) -> ModelUsage? {
        guard let value, value.dictionaryValue != nil else { return nil }
        let input = value.wireInt("input_tokens") ?? 0
        let output = value.wireInt("output_tokens") ?? 0
        let cached = value[wireKey: "input_tokens_details"]?.wireInt("cached_tokens") ?? 0
        let reasoning = value[wireKey: "output_tokens_details"]?.wireInt("reasoning_tokens") ?? 0
        return ModelUsage(
            inputTokens: max(0, input - cached),
            outputTokens: output,
            cacheReadTokens: cached,
            reasoningTokens: reasoning,
            totalTokens: value.wireInt("total_tokens") ?? (input + output)
        )
    }

    // MARK: - Stream

    struct StreamState {
        var toolIndexByOutputIndex: [Int: Int] = [:]
        var toolIndexByItemID: [String: Int] = [:]
        var sawEvent = false
        var failure: String?
        /// Structured error code of a `response.failed` / `error` event (for example
        /// `subscription_sharing_usage_limit_exceeded`).
        var failureCode: String?
        /// Set by `response.completed` / `incomplete` / `failed` / `done`.
        var terminalEvent: String?
        /// Function-call tool indexes whose arguments have not been finalized yet.
        var openToolIndexes: Set<Int> = []

        /// Error for a stream that ended without a terminal event or with unfinished tool calls
        /// (upstream `openai-responses-stream-internal.ts`); `nil` when the stream is complete.
        func incompleteReason() -> String? {
            guard self.sawEvent else { return nil }
            guard let terminal = self.terminalEvent else {
                return self.openToolIndexes.isEmpty
                    ? "stream ended before a terminal response event"
                    : "stream ended with unresolved tool calls"
            }
            if terminal == "response.incomplete", !self.openToolIndexes.isEmpty {
                return "stream completed with unresolved tool calls"
            }
            return nil
        }
    }

    static func handleStreamEvent(
        _ event: ServerSentEvent,
        state: inout StreamState,
        assembler: inout ProviderStreamAssembler
    ) -> [ModelStreamChunk] {
        guard let object = ProviderWireJSON.object(from: event.data) else { return [] }
        state.sawEvent = true
        let payload = AnyCodable(.object(object))
        let type = payload.wireString("type") ?? event.event ?? ""
        var chunks: [ModelStreamChunk] = []
        switch type {
        case "response.created", "response.in_progress":
            if let model = payload[wireKey: "response"]?.wireString("model") {
                assembler.modelID = model
            }
        case "response.output_text.delta":
            if let delta = payload[wireKey: "delta"]?.stringValue, let chunk = assembler.appendText(delta) {
                chunks.append(chunk)
            }
        case "response.refusal.delta":
            if let delta = payload[wireKey: "delta"]?.stringValue, let chunk = assembler.appendText(delta) {
                chunks.append(chunk)
                assembler.stopReason = .refusal
            }
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            if let delta = payload[wireKey: "delta"]?.stringValue, let chunk = assembler.appendReasoning(delta) {
                chunks.append(chunk)
            }
        case "response.output_item.added":
            if let item = payload[wireKey: "item"], item.wireString("type") == "function_call" {
                let index = self.toolIndex(payload: payload, item: item, state: &state, assembler: assembler)
                if item.wireString("status") != "completed" {
                    state.openToolIndexes.insert(index)
                }
                chunks.append(
                    assembler.appendToolCall(
                        index: index,
                        id: item.wireString("call_id"),
                        name: item.wireString("name"),
                        argumentsDelta: item[wireKey: "arguments"]?.stringValue ?? ""
                    )
                )
            }
        case "response.function_call_arguments.delta":
            let index = self.toolIndex(payload: payload, item: nil, state: &state, assembler: assembler)
            chunks.append(assembler.appendToolCall(index: index, id: nil, name: nil, argumentsDelta: payload[wireKey: "delta"]?.stringValue ?? ""))
        case "response.function_call_arguments.done":
            let index = self.toolIndex(payload: payload, item: nil, state: &state, assembler: assembler)
            state.openToolIndexes.remove(index)
            assembler.completeToolCall(index: index, id: nil, name: nil, argumentsJSON: payload[wireKey: "arguments"]?.stringValue)
        case "response.output_item.done":
            if let item = payload[wireKey: "item"], item.wireString("type") == "function_call" {
                let index = self.toolIndex(payload: payload, item: item, state: &state, assembler: assembler)
                state.openToolIndexes.remove(index)
                assembler.completeToolCall(
                    index: index,
                    id: item.wireString("call_id"),
                    name: item.wireString("name"),
                    argumentsJSON: item[wireKey: "arguments"]?.stringValue
                )
            }
        case "response.completed", "response.incomplete", "response.failed", "response.done":
            state.terminalEvent = type
            if let response = payload[wireKey: "response"] {
                if let model = response.wireString("model") {
                    assembler.modelID = model
                }
                if let usage = self.usage(response[wireKey: "usage"]) {
                    chunks.append(assembler.setUsage(usage))
                }
                if let reason = self.stopReason(response) {
                    if assembler.stopReason != .refusal {
                        assembler.stopReason = reason
                    }
                }
                if type == "response.failed" {
                    state.failure = response[wireKey: "error"]?.wireString("message") ?? "response failed"
                    state.failureCode = response[wireKey: "error"]?.wireString("code")
                }
            }
        case "error":
            state.failure = payload.wireString("message") ?? payload[wireKey: "error"]?.wireString("message") ?? "stream error"
            state.failureCode = payload.wireString("code") ?? payload[wireKey: "error"]?.wireString("code")
        default:
            break
        }
        return chunks
    }

    private static func toolIndex(
        payload: AnyCodable,
        item: AnyCodable?,
        state: inout StreamState,
        assembler: ProviderStreamAssembler
    ) -> Int {
        let outputIndex = payload.wireInt("output_index")
        let itemID = payload.wireString("item_id") ?? item?.wireString("id")
        if let outputIndex, let index = state.toolIndexByOutputIndex[outputIndex] {
            return index
        }
        if let itemID, let index = state.toolIndexByItemID[itemID] {
            return index
        }
        let index = max(assembler.nextToolCallIndex, (state.toolIndexByOutputIndex.values.max() ?? -1) + 1)
        if let outputIndex {
            state.toolIndexByOutputIndex[outputIndex] = index
        }
        if let itemID {
            state.toolIndexByItemID[itemID] = index
        }
        return index
    }
}

/// OpenAI Responses engine (Platform, ChatGPT/Codex OAuth route, Azure, and compatible routes).
struct OpenAIResponsesEngine: Sendable {
    let settings: ProviderEndpointSettings
    let exchange: ProviderHTTPExchange

    static let capabilities = ModelProviderCapabilities(
        supportsStreaming: true,
        supportsTools: true,
        supportsParallelToolCalls: true,
        supportsJSONSchema: true,
        supportsImages: true,
        supportsReasoning: true,
        supportsTranscript: true
    )

    /// Whether the effective route is the ChatGPT/Codex backend.
    func isChatGPTRoute(baseURL: String) -> Bool {
        self.settings.api == .openAIChatGPTResponses || OpenAIRouteResolution.classify(baseURL: baseURL) == .chatGPT
    }

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        let prepared = try self.prepare(request, stream: false)
        if prepared.streamOnly {
            return try await ProviderStreamSupport.collect(
                self.stream(prepared: prepared),
                providerID: self.settings.providerID,
                modelID: prepared.modelID
            )
        }
        let response = try await self.exchange.data(for: prepared.urlRequest)
        let root = try ProviderWireJSON.decode(response.body)
        let parsed = OpenAIResponsesWire.parseResponse(root, providerID: self.settings.providerID, modelID: prepared.modelID)
        if parsed.stopReason == .error {
            let message = root[wireKey: "error"]?.wireString("message") ?? "response failed"
            throw OpenClawCoreError.unavailable("\(self.settings.providerID) response failed: \(message)")
        }
        guard !parsed.text.isEmpty || !parsed.toolCalls.isEmpty || parsed.stopReason.permitsEmptyOutput else {
            throw OpenClawCoreError.unavailable("\(self.settings.providerID) response did not include text output")
        }
        return parsed
    }

    func stream(_ request: ModelGenerationRequest) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        do {
            return self.stream(prepared: try self.prepare(request, stream: true))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    private func stream(prepared: Prepared) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        let providerID = self.settings.providerID
        let exchange = self.exchange
        return ProviderStreamSupport.makeStream { continuation in
            let lines = try await exchange.lines(for: prepared.urlRequest)
            var assembler = ProviderStreamAssembler(providerID: providerID, modelID: prepared.modelID)
            var parser = ServerSentEventParser()
            var state = OpenAIResponsesWire.StreamState()
            var rawBody = ""
            for try await line in lines {
                if !state.sawEvent, rawBody.utf8.count < 1_048_576 {
                    rawBody += line + "\n"
                }
                guard let event = parser.consume(line) else { continue }
                OpenAIResponsesWire.handleStreamEvent(event, state: &state, assembler: &assembler).forEach { continuation.yield($0) }
            }
            if let event = parser.finish() {
                OpenAIResponsesWire.handleStreamEvent(event, state: &state, assembler: &assembler).forEach { continuation.yield($0) }
            }
            if let failure = state.failure {
                throw OpenClawCoreError.unavailable("\(providerID) response failed: \(failure)")
            }
            if let incomplete = state.incompleteReason() {
                throw OpenClawCoreError.unavailable("\(providerID) \(incomplete)")
            }
            if !state.sawEvent {
                // Servers that ignore `stream: true` answer with a plain JSON response; an empty or
                // unparseable body means the stream closed before any event arrived.
                guard let data = rawBody.data(using: .utf8), let root = try? ProviderWireJSON.decode(data), root.dictionaryValue != nil else {
                    throw OpenClawCoreError.unavailable("\(providerID) stream ended before a terminal response event")
                }
                let parsed = OpenAIResponsesWire.parseResponse(root, providerID: providerID, modelID: prepared.modelID)
                if parsed.stopReason == .error {
                    let message = root[wireKey: "error"]?.wireString("message") ?? "response failed"
                    throw OpenClawCoreError.unavailable("\(providerID) response failed: \(message)")
                }
                if let chunk = assembler.appendReasoning(parsed.reasoningText ?? "") {
                    continuation.yield(chunk)
                }
                if let chunk = assembler.appendText(parsed.text) {
                    continuation.yield(chunk)
                }
                for (index, call) in parsed.toolCalls.enumerated() {
                    continuation.yield(assembler.appendToolCall(index: index, id: call.id, name: call.name, argumentsDelta: call.argumentsJSON))
                }
                if let usage = parsed.usage {
                    continuation.yield(assembler.setUsage(usage))
                }
                assembler.stopReason = parsed.stopReason
            }
            continuation.yield(.completed(response: assembler.response()))
        }
    }

    struct Prepared: Sendable {
        var urlRequest: URLRequest
        var modelID: String
        var streamOnly: Bool
    }

    func prepare(_ request: ModelGenerationRequest, stream: Bool) throws -> Prepared {
        let settings = self.settings
        guard settings.enabled else {
            throw OpenClawCoreError.unavailable("\(settings.providerID) model provider is disabled")
        }
        let defaultBase = settings.api == .openAIChatGPTResponses ? OpenAIRouteResolution.chatGPTBaseURL : OpenAIRouteResolution.platformBaseURL
        let baseURLString = settings.resolvedBaseURLString(for: request, defaultBaseURL: defaultBase)
        let chatGPT = self.isChatGPTRoute(baseURL: baseURLString)
        let api: ModelAPI = chatGPT ? .openAIChatGPTResponses : settings.api
        var modelID = settings.resolvedModelID(for: request)
        if ProviderRuntimeIdentity.canonicalProviderID(settings.providerID) == "openai" {
            modelID = OpenAIRouteResolution.normalizeModelID(modelID)
        }
        let model = settings.modelDefinition(for: modelID)
        try ProviderRequestValidation.validate(request, providerID: settings.providerID, model: model)
        let request = MediaInputPreparation.apply(request, limits: model?.mediaInput?.image)
        let fastEnabled = FastModeResolution.resolve(request: request, configured: settings.configuredFastMode, model: model)
        if fastEnabled == true, let fastModel = FastModeModelSwap.fastModelID(providerID: settings.providerID, modelID: modelID, api: api) {
            modelID = fastModel
        }
        let policy = OpenAIResponsesPayloadPolicy.resolve(
            providerID: settings.providerID,
            api: api,
            baseURL: baseURLString,
            compat: model?.compat
        )
        let serviceTier: String?
        if policy.allowsServiceTier {
            serviceTier = OpenAIFastModeResolution.serviceTier(
                providerID: settings.providerID,
                api: api,
                baseURL: baseURLString,
                request: request,
                fastEnabled: fastEnabled
            )
        } else {
            serviceTier = nil
        }
        // Streaming transports and the ChatGPT backend always use SSE; `generate` then collects it.
        let streaming = stream || chatGPT || request.policy.streamTokens || request.policy.codexTransport != .auto
        let context = OpenAIResponsesWire.BuildContext(
            providerID: settings.providerID,
            modelID: modelID,
            model: model,
            api: api,
            baseURL: baseURLString,
            policy: policy,
            stream: streaming,
            serviceTier: serviceTier,
            maxTokens: settings.maxTokens(for: request, model: model),
            isChatGPTRoute: chatGPT,
            supportsDeveloperRole: model?.compat?.supportsDeveloperRole ?? policy.usesKnownNativeOpenAIRoute
        )
        let payload = OpenAIResponsesWire.buildPayload(request: request, context: context)
        let endpoint = try self.endpointURL(baseURL: baseURLString, chatGPT: chatGPT, api: api)
        var urlRequest = settings.makeJSONRequest(url: endpoint, request: request, model: model, streaming: streaming)
        try self.applyAuth(to: &urlRequest, request: request, api: api, chatGPT: chatGPT)
        var headers = settings.mergedHeaders(for: request, model: model)
        if let organizationID = ProviderRequestResolution.metadataValue(
            request.metadata,
            settings.metadata,
            keys: ["openai.organizationID", "openai.organizationId"]
        ) {
            headers["OpenAI-Organization"] = organizationID
        }
        if let projectID = ProviderRequestResolution.metadataValue(
            request.metadata,
            settings.metadata,
            keys: ["openai.projectID", "openai.projectId"]
        ) {
            headers["OpenAI-Project"] = projectID
        }
        if let organizationID = ModelGenerationRequest.normalized(settings.organizationID) {
            headers["x-organization-id"] = headers["x-organization-id"] ?? organizationID
        }
        if chatGPT {
            headers["originator"] = headers["originator"] ?? "openclaw"
            headers["OpenAI-Beta"] = "responses=experimental"
            headers["session_id"] = headers["session_id"] ?? request.promptCacheKey
            headers["x-client-request-id"] = headers["x-client-request-id"] ?? request.promptCacheKey
        } else if let cache = request.policy.promptCache, cache.enabled {
            let compat = model?.compat
            if compat?.sendSessionIdHeader != false, policy.usesKnownNativeOpenAIRoute {
                headers["session_id"] = headers["session_id"] ?? request.promptCacheKey
            }
            if compat?.sendSessionAffinityHeaders == true {
                headers["session_id"] = headers["session_id"] ?? request.promptCacheKey
                headers["x-client-request-id"] = headers["x-client-request-id"] ?? request.promptCacheKey
                headers["x-session-affinity"] = headers["x-session-affinity"] ?? request.promptCacheKey
            }
        }
        ProviderRequestResolution.applyHeaders(headers, request: &urlRequest)
        urlRequest.httpBody = try ProviderWireJSON.encode(payload)
        return Prepared(urlRequest: urlRequest, modelID: modelID, streamOnly: streaming)
    }

    private func endpointURL(baseURL: String, chatGPT: Bool, api: ModelAPI) throws -> URL {
        if chatGPT {
            guard let url = URL(string: OpenAIRouteResolution.chatGPTResponsesURL(baseURL: baseURL)) else {
                throw OpenClawCoreError.invalidConfiguration("\(self.settings.providerID) base URL is invalid")
            }
            return url
        }
        guard let base = URL(string: baseURL), base.scheme != nil else {
            throw OpenClawCoreError.invalidConfiguration("\(self.settings.providerID) base URL is invalid")
        }
        let configuredPath = self.settings.chatCompletionsPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = configuredPath.isEmpty || configuredPath == "chat/completions" ? "responses" : configuredPath
        var url = ProviderEndpointSettings.appending(path: path, to: base)
        if api == .azureOpenAIResponses {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            var items = components.queryItems ?? []
            if !items.contains(where: { $0.name == "api-version" }) {
                let version = ModelGenerationRequest.normalized(self.settings.apiVersion) ?? ProviderEndpointTemplates.azureDefaultAPIVersion
                items.append(URLQueryItem(name: "api-version", value: version))
            }
            components.queryItems = items
            url = components.url ?? url
        }
        return url
    }

    private func applyAuth(to urlRequest: inout URLRequest, request: ModelGenerationRequest, api: ModelAPI, chatGPT: Bool) throws {
        let settings = self.settings
        if settings.applyRequestAuthOverride(to: &urlRequest) {
            return
        }
        guard settings.runtime.providerConfig?.authHeader != false else { return }
        if settings.authMode == .awsSDK {
            throw OpenClawCoreError.invalidConfiguration("\(settings.providerID) does not support aws-sdk auth mode for OpenAI Responses requests")
        }
        guard let credential = try settings.bearerCredential(for: request) else { return }
        if api == .azureOpenAIResponses, settings.authMode == .apiKey {
            urlRequest.setValue(credential, forHTTPHeaderField: "api-key")
            return
        }
        urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if chatGPT {
            let accountID = ProviderRequestResolution.metadataValue(
                request.metadata,
                settings.metadata,
                keys: ["openai.chatgptAccountID", "openai.chatgptAccountId", "auth.accountID", "auth.accountId"]
            ) ?? OpenAIRouteResolution.chatGPTAccountID(fromAccessToken: credential)
            if let accountID {
                urlRequest.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }
        }
    }
}
