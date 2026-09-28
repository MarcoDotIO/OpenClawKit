import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Resolved Chat Completions compat flags: explicit model compat over endpoint defaults
/// (upstream `openai-completions-compat.ts`, reduced to the SDK's endpoint classes).
struct OpenAIChatCompletionsCompat: Sendable, Equatable {
    var supportsStore: Bool
    var supportsDeveloperRole: Bool
    var supportsReasoningEffort: Bool
    var supportsUsageInStreaming: Bool
    var supportsStrictMode: Bool
    var supportsJSONSchemaResponseFormat: Bool
    var supportsTemperature: Bool
    var maxTokensField: ModelCompatMaxTokensField
    var thinkingFormat: ModelCompatThinkingFormat
    var requiresStringContent: Bool
    var strictMessageKeys: Bool
    var requiresToolResultName: Bool
    var requiresAssistantAfterToolResult: Bool
    var requiresThinkingAsText: Bool
    var requiresReasoningContentOnAssistantMessages: Bool
    var zaiToolStream: Bool
    var openRouterRouting: [String: AnyCodable]?
    var endpoint: ModelProviderEndpointClass

    static func resolve(
        providerID: String,
        modelID: String,
        baseURL: String,
        compat: ModelCompatConfig?,
        api: ModelAPI?
    ) -> OpenAIChatCompletionsCompat {
        let provider = ProviderRuntimeIdentity.canonicalProviderID(providerID)
        let endpoint = ModelProviderEndpointClass.resolve(baseURL: baseURL)
        let lowerBase = baseURL.lowercased()
        let isOpenAINative = endpoint == .openAIPublic || endpoint == .azureOpenAI || (endpoint == .default && provider == "openai")
        let isBundledProvider = ModelProviderConfig.isBuiltInOverlayProviderID(provider)
        let proxyLike = (endpoint == .custom && !isBundledProvider) || endpoint == .openRouter
        let isMoonshot = provider == "moonshot" || provider == "kimi" || endpoint == .moonshotNative
        let isZai = provider == "zai" || endpoint == .zaiNative
        let isDeepSeek = provider == "deepseek" || endpoint == .deepseekNative
        let isTogether = provider == "together" || lowerBase.contains("api.together.ai") || lowerBase.contains("api.together.xyz")
        let isCloudflare = provider == "cloudflare-ai-gateway" || lowerBase.contains("gateway.ai.cloudflare.com")
        let isXiaomi = provider == "xiaomi" || endpoint == .xiaomiNative
        let isMistral = provider == "mistral" || endpoint == .mistralPublic
        let isOpenRouter = provider == "openrouter" || endpoint == .openRouter
        let isNonStandard = [.cerebrasNative, .chutesNative, .deepseekNative, .mistralPublic, .xaiNative].contains(endpoint)
            || isXiaomi || isZai
            || ["cerebras", "chutes", "deepseek", "opencode", "opencode-go", "xai"].contains(provider)
        let usesMaxTokens = isMistral || isMoonshot || isCloudflare || isZai || isTogether
            || provider == "chutes" || endpoint == .chutesNative
        let defaultThinking: ModelCompatThinkingFormat
        if isDeepSeek || isXiaomi {
            defaultThinking = .deepseek
        } else if isZai {
            defaultThinking = .zai
        } else if isTogether {
            defaultThinking = .together
        } else if isOpenRouter {
            defaultThinking = .openrouter
        } else {
            defaultThinking = .openAI
        }
        let supportsTemperature = ReasoningEffortResolver.supportsTemperature(modelID: modelID, compat: compat, api: api)
        return OpenAIChatCompletionsCompat(
            supportsStore: compat?.supportsStore ?? (endpoint == .openAIPublic),
            supportsDeveloperRole: compat?.supportsDeveloperRole ?? false,
            supportsReasoningEffort: compat?.supportsReasoningEffort
                ?? (!isZai && !isTogether && !isMistral && endpoint != .xaiNative && !proxyLike),
            supportsUsageInStreaming: compat?.supportsUsageInStreaming ?? !isNonStandard,
            supportsStrictMode: compat?.supportsStrictMode ?? (!isZai && !isNonStandard),
            supportsJSONSchemaResponseFormat: compat?.supportsJSONSchemaResponseFormat ?? true,
            supportsTemperature: supportsTemperature,
            maxTokensField: compat?.maxTokensField ?? (isOpenAINative && !usesMaxTokens ? .maxCompletionTokens : .maxTokens),
            thinkingFormat: compat?.thinkingFormat ?? defaultThinking,
            requiresStringContent: compat?.requiresStringContent ?? false,
            strictMessageKeys: compat?.strictMessageKeys ?? false,
            requiresToolResultName: compat?.requiresToolResultName ?? false,
            requiresAssistantAfterToolResult: compat?.requiresAssistantAfterToolResult ?? false,
            requiresThinkingAsText: compat?.requiresThinkingAsText ?? false,
            requiresReasoningContentOnAssistantMessages: compat?.requiresReasoningContentOnAssistantMessages
                ?? (isDeepSeek || isXiaomi),
            zaiToolStream: compat?.zaiToolStream ?? false,
            openRouterRouting: compat?.openRouterRouting,
            endpoint: endpoint
        )
    }

    /// Whether the endpoint is a verified native OpenAI Chat Completions endpoint.
    var isKnownOpenAIEndpoint: Bool {
        self.endpoint == .openAIPublic || self.endpoint == .azureOpenAI
    }
}

/// OpenAI Chat Completions request/response mapping for contract v2 (upstream
/// `openai-completions-params.ts`, `openai-completions-messages.ts`, `openai-completions-stream.ts`).
enum OpenAIChatCompletionsWire {
    /// Placeholder assistant turn some providers need between tool results and the next user turn.
    static let assistantAfterToolResultText = "I have processed the tool results."

    struct BuildContext {
        var providerID: String
        var modelID: String
        var model: ModelDefinitionConfig?
        var api: ModelAPI?
        var baseURL: String
        var compat: OpenAIChatCompletionsCompat
        var stream: Bool
        var configuredFastMode: Bool?
        var maxTokens: Int?
    }

    // MARK: - Request

    static func buildPayload(request: ModelGenerationRequest, context: BuildContext) -> [String: Any] {
        let compat = context.compat
        let reasoning = self.reasoningPlan(request: request, context: context)
        var payload: [String: Any] = [
            "model": context.modelID,
            "messages": self.buildMessages(request: request, context: context, reasoningEnabled: reasoning.enabled),
        ]
        if context.stream {
            payload["stream"] = true
            if compat.supportsUsageInStreaming {
                payload["stream_options"] = ["include_usage": true]
            }
        }
        if compat.supportsStore, compat.isKnownOpenAIEndpoint {
            payload["store"] = false
        }
        if compat.supportsTemperature {
            if let temperature = request.policy.temperature {
                payload["temperature"] = temperature
            }
            if let topP = request.policy.topP {
                payload["top_p"] = topP
            }
        }
        if let maxTokens = context.maxTokens {
            payload[compat.maxTokensField.rawValue] = maxTokens
        }
        let tools = self.buildTools(request.tools, compat: compat)
        if !tools.isEmpty {
            payload["tools"] = tools
            if let toolChoice = self.toolChoice(request.toolChoice) {
                payload["tool_choice"] = toolChoice
            }
            if compat.zaiToolStream, context.stream {
                payload["tool_stream"] = true
            }
        }
        if let responseFormat = self.responseFormat(request.responseFormat, compat: compat) {
            payload["response_format"] = responseFormat
        }
        self.applyReasoning(reasoning, to: &payload, context: context)
        if let routing = compat.openRouterRouting, !routing.isEmpty {
            payload["provider"] = ProviderWireJSON.foundation(routing)
        }
        if context.baseURL.contains("ai-gateway.vercel.sh"), let compat = context.model?.compat {
            var gateway: [String: Any] = [:]
            if let only = compat.vercelGatewayOnly {
                gateway["only"] = only
            }
            if let order = compat.vercelGatewayOrder {
                gateway["order"] = order
            }
            if !gateway.isEmpty {
                payload["providerOptions"] = ["gateway": gateway]
            }
        }
        if !tools.isEmpty, compat.isKnownOpenAIEndpoint || context.compat.endpoint == .default {
            // Native Chat Completions rejects tools with enabled GPT-5.6 reasoning and rejects the
            // effort field entirely for GPT-5.4 mini and GPT-5.5 tool calls.
            if ReasoningEffortResolver.isGPT56(context.modelID) {
                payload["reasoning_effort"] = "none"
            } else if ReasoningEffortResolver.isGPT54Mini(context.modelID) || ReasoningEffortResolver.isGPT55(context.modelID) {
                payload.removeValue(forKey: "reasoning_effort")
            }
        }
        return payload
    }

    struct ReasoningPlan {
        /// Resolved provider effort (`nil` = omit).
        var effort: String?
        /// Whether thinking is enabled for binary thinking switches.
        var enabled: Bool
        /// Whether the model reasons (unknown models are assumed to when a level is requested).
        var modelReasoning: Bool
        /// Whether the request expressed any thinking intent.
        var hasIntent: Bool
    }

    static func reasoningPlan(request: ModelGenerationRequest, context: BuildContext) -> ReasoningPlan {
        let modelReasoning = context.model?.reasoning ?? true
        if let level = request.policy.thinkingLevel ?? ThinkLevel.normalize(request.metadata["thinkingLevel"]) {
            let effort = ReasoningEffortResolver.resolve(
                thinkingLevel: level,
                model: context.model,
                modelID: context.modelID,
                providerID: context.providerID,
                api: context.api ?? .openAICompletions
            )
            return ReasoningPlan(effort: effort, enabled: level != .off && modelReasoning, modelReasoning: modelReasoning, hasIntent: true)
        }
        if let explicit = request.policy.reasoningEffort {
            let effort = ReasoningEffortResolver.clamp(
                effort: explicit.rawValue,
                model: context.model,
                modelID: context.modelID,
                api: context.api ?? .openAICompletions
            )
            return ReasoningPlan(effort: effort, enabled: explicit != .none && modelReasoning, modelReasoning: modelReasoning, hasIntent: true)
        }
        return ReasoningPlan(effort: nil, enabled: false, modelReasoning: context.model?.reasoning ?? false, hasIntent: false)
    }

    private static func applyReasoning(_ plan: ReasoningPlan, to payload: inout [String: Any], context: BuildContext) {
        let compat = context.compat
        guard plan.modelReasoning, plan.hasIntent else { return }
        switch compat.thinkingFormat {
        case .zai:
            payload["thinking"] = plan.enabled ? ["type": "enabled", "clear_thinking": false] : ["type": "disabled"]
        case .qwen:
            payload["enable_thinking"] = plan.enabled
        case .qwenChatTemplate:
            payload["chat_template_kwargs"] = ["enable_thinking": plan.enabled, "preserve_thinking": true]
        case .deepseek:
            payload["thinking"] = ["type": plan.enabled ? "enabled" : "disabled"]
            if plan.enabled, compat.supportsReasoningEffort, let effort = plan.effort {
                payload["reasoning_effort"] = effort
            }
        case .together:
            payload["reasoning"] = ["enabled": plan.enabled]
            if plan.enabled, compat.supportsReasoningEffort, let effort = plan.effort {
                payload["reasoning_effort"] = effort
            }
        case .openrouter:
            if let effort = plan.effort, effort != "none" {
                payload["reasoning"] = ["effort": effort]
            } else if context.model?.compat?.supportsReasoningEffort == false {
                payload["reasoning"] = ["enabled": plan.enabled]
            }
        case .openAI:
            if compat.supportsReasoningEffort, let effort = plan.effort {
                payload["reasoning_effort"] = effort
            }
        }
    }

    static func buildTools(_ tools: [ModelToolDefinition], compat: OpenAIChatCompletionsCompat) -> [[String: Any]] {
        tools.sorted(by: { $0.name < $1.name }).map { tool in
            var function: [String: Any] = [
                "name": tool.name,
                "parameters": ProviderWireJSON.foundation(tool.parameters),
            ]
            if !tool.description.isEmpty {
                function["description"] = tool.description
            }
            if compat.supportsStrictMode, let strict = tool.strict {
                function["strict"] = strict
            }
            return ["type": "function", "function": function]
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
            return ["type": "function", "function": ["name": name]]
        }
    }

    static func responseFormat(_ format: ModelResponseFormat, compat: OpenAIChatCompletionsCompat) -> [String: Any]? {
        switch format {
        case .text:
            return nil
        case .jsonObject:
            return ["type": "json_object"]
        case .jsonSchema(let name, let schema, let strict):
            guard compat.supportsJSONSchemaResponseFormat else {
                return ["type": "json_object"]
            }
            return [
                "type": "json_schema",
                "json_schema": ["name": name, "schema": ProviderWireJSON.foundation(schema), "strict": strict],
            ]
        }
    }

    static func buildMessages(
        request: ModelGenerationRequest,
        context: BuildContext,
        reasoningEnabled: Bool
    ) -> [[String: Any]] {
        let compat = context.compat
        let systemRole = compat.supportsDeveloperRole ? "developer" : "system"
        let supportsImages = context.model.map { $0.input.contains(.image) } ?? true
        var messages: [[String: Any]] = []
        if let system = ModelGenerationRequest.normalized(request.systemPrompt) {
            messages.append(["role": systemRole, "content": system])
        }
        let transcript = request.resolvedMessages
        var lastRole: ModelMessageRole?
        var index = 0
        while index < transcript.count {
            let message = transcript[index]
            if compat.requiresAssistantAfterToolResult, lastRole == .tool, message.role == .user {
                messages.append(["role": "assistant", "content": self.assistantAfterToolResultText])
            }
            switch message {
            case .system(let content):
                let text = ProviderContentText.flatten(content)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.append(["role": systemRole, "content": text])
                }
                lastRole = .system
            case .user(let content):
                if let user = self.userMessage(content, legacyPrompt: request.messages.isEmpty, supportsImages: supportsImages, compat: compat) {
                    messages.append(user)
                    lastRole = .user
                }
            case .assistant(let parts):
                if let assistant = self.assistantMessage(
                    parts,
                    compat: compat,
                    reasoningEnabled: reasoningEnabled,
                    modelReasoning: context.model?.reasoning ?? false
                ) {
                    messages.append(assistant)
                    lastRole = .assistant
                }
            case .toolResult:
                var imageParts: [[String: Any]] = []
                var ordinal = 1
                while index < transcript.count, case .toolResult(let result) = transcript[index] {
                    var toolMessage: [String: Any] = [
                        "role": "tool",
                        "tool_call_id": result.toolCallID,
                        "content": ProviderContentText.toolResultText(result),
                    ]
                    if compat.requiresToolResultName, !result.toolName.isEmpty {
                        toolMessage["name"] = result.toolName
                    }
                    messages.append(toolMessage)
                    let images = result.content.compactMap { part -> MediaAttachment? in
                        if case .image(let attachment) = part { return attachment }
                        return nil
                    }
                    if !images.isEmpty, supportsImages {
                        let name = result.toolName.isEmpty ? "" : " (\(result.toolName.prefix(64)))"
                        imageParts.append(["type": "text", "text": "Image(s) from tool result #\(ordinal)\(name):"])
                        for image in images {
                            imageParts.append(self.imagePart(image))
                        }
                    }
                    ordinal += 1
                    index += 1
                }
                index -= 1
                if !imageParts.isEmpty {
                    if compat.requiresAssistantAfterToolResult {
                        messages.append(["role": "assistant", "content": self.assistantAfterToolResultText])
                    }
                    messages.append(["role": "user", "content": imageParts])
                    lastRole = .user
                } else {
                    lastRole = .tool
                }
            }
            index += 1
        }
        if compat.requiresStringContent {
            messages = messages.map(self.flattenToString)
        }
        if compat.strictMessageKeys {
            let allowed: Set<String> = ["role", "content", "tool_calls", "tool_call_id", "name"]
            messages = messages.map { $0.filter { allowed.contains($0.key) } }
        }
        return messages
    }

    private static func userMessage(
        _ content: [ModelContentPart],
        legacyPrompt: Bool,
        supportsImages: Bool,
        compat: OpenAIChatCompletionsCompat
    ) -> [String: Any]? {
        let hasMedia = content.contains { $0.mediaAttachment != nil }
        if !hasMedia {
            let texts = content.compactMap(\.text)
            let text = texts.joined()
            guard legacyPrompt || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if texts.count > 1, !legacyPrompt {
                return ["role": "user", "content": texts.map { ["type": "text", "text": $0] }]
            }
            return ["role": "user", "content": text]
        }
        if legacyPrompt {
            let prompt = content.compactMap(\.text).joined()
            let attachments = content.compactMap(\.mediaAttachment)
            let legacy = OpenAIStyleMultimodalSupport.userContent(prompt: prompt, attachments: attachments)
            return ["role": "user", "content": self.foundationContent(legacy)]
        }
        var parts: [[String: Any]] = []
        for part in content {
            switch part {
            case .text(let text):
                parts.append(["type": "text", "text": text])
            case .image(let attachment):
                if supportsImages {
                    parts.append(self.imagePart(attachment))
                } else {
                    parts.append(["type": "text", "text": "(image omitted: model does not support images)"])
                }
            case .attachment(let attachment):
                parts.append(["type": "text", "text": ProviderContentText.flatten([.attachment(attachment)])])
            }
        }
        guard !parts.isEmpty else { return nil }
        return ["role": "user", "content": parts]
    }

    private static func assistantMessage(
        _ parts: [ModelAssistantPart],
        compat: OpenAIChatCompletionsCompat,
        reasoningEnabled: Bool,
        modelReasoning: Bool
    ) -> [String: Any]? {
        var texts: [String] = []
        var thinking: [String] = []
        var toolCalls: [[String: Any]] = []
        for part in parts {
            switch part {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    texts.append(text)
                }
            case .thinking(let text, _):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    thinking.append(text)
                }
            case .toolCall(let call):
                toolCalls.append([
                    "id": call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": self.argumentsText(call.argumentsJSON)],
                ])
            }
        }
        var message: [String: Any] = ["role": "assistant"]
        if !thinking.isEmpty, compat.requiresThinkingAsText {
            texts.insert("<thinking>\n\(thinking.joined(separator: "\n"))\n</thinking>", at: 0)
        } else if !thinking.isEmpty, compat.thinkingFormat == .deepseek || compat.requiresReasoningContentOnAssistantMessages {
            message["reasoning_content"] = thinking.joined(separator: "\n")
        }
        let text = texts.joined(separator: "\n")
        if !text.isEmpty {
            message["content"] = text
        } else if compat.requiresAssistantAfterToolResult {
            message["content"] = ""
        } else {
            message["content"] = NSNull()
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
        }
        if compat.requiresReasoningContentOnAssistantMessages, modelReasoning, reasoningEnabled, message["reasoning_content"] == nil {
            message["reasoning_content"] = ""
        }
        guard !text.isEmpty || !toolCalls.isEmpty else { return nil }
        return message
    }

    private static func argumentsText(_ argumentsJSON: String) -> String {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "{}" : trimmed
    }

    static func imagePart(_ attachment: MediaAttachment) -> [String: Any] {
        let mime = MultimodalAttachmentUtilities.normalizedMimeType(for: attachment)
        return ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(attachment.data.base64EncodedString())"]]
    }

    private static func foundationContent(_ content: OpenAIStyleMessageContent) -> Any {
        switch content {
        case .text(let text):
            return text
        case .parts(let parts):
            return parts.map { part -> [String: Any] in
                switch part {
                case .text(let text):
                    return ["type": "text", "text": text]
                case .imageDataURL(let url):
                    return ["type": "image_url", "image_url": ["url": url]]
                }
            }
        }
    }

    private static func flattenToString(_ message: [String: Any]) -> [String: Any] {
        guard let parts = message["content"] as? [[String: Any]] else { return message }
        var flattened = message
        flattened["content"] = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return flattened
    }

    // MARK: - Response

    static func parseResponse(_ data: Data, providerID: String, modelID: String) throws -> ModelGenerationResponse {
        let root = try ProviderWireJSON.decode(data)
        let choice = root[wireKey: "choices"]?.arrayValue?.first
        let message = choice?[wireKey: "message"]
        var text = ""
        if let content = message?[wireKey: "content"] {
            if let string = content.stringValue {
                text = string
            } else if let parts = content.arrayValue {
                text = parts.compactMap { $0.wireString("text") }.joined()
            }
        }
        let reasoning = message?.wireString("reasoning_content") ?? message?.wireString("reasoning")
        var toolCalls: [ModelToolCall] = []
        for (offset, call) in (message?[wireKey: "tool_calls"]?.arrayValue ?? []).enumerated() {
            guard let function = call[wireKey: "function"], let name = function.wireString("name") else { continue }
            toolCalls.append(
                ModelToolCall(
                    id: call.wireString("id") ?? ProviderToolCallIDs.synthesize(index: offset),
                    name: name,
                    argumentsJSON: self.argumentsString(function[wireKey: "arguments"])
                )
            )
        }
        if toolCalls.isEmpty, let legacy = message?[wireKey: "function_call"], let name = legacy.wireString("name") {
            toolCalls.append(
                ModelToolCall(
                    id: ProviderToolCallIDs.synthesize(index: 0),
                    name: name,
                    argumentsJSON: self.argumentsString(legacy[wireKey: "arguments"])
                )
            )
        }
        var stopReason = choice?.wireString("finish_reason").map(ModelStopReason.init(providerValue:))
        if text.isEmpty, toolCalls.isEmpty, message?.wireString("refusal") != nil {
            stopReason = .refusal
            text = message?.wireString("refusal") ?? ""
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, toolCalls.isEmpty, stopReason != .refusal {
            throw OpenClawCoreError.unavailable("\(providerID) response did not include message content")
        }
        return ModelGenerationResponse(
            text: toolCalls.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text,
            providerID: providerID,
            modelID: root.wireString("model") ?? modelID,
            toolCalls: toolCalls,
            usage: self.usage(root[wireKey: "usage"]),
            stopReason: stopReason,
            reasoningText: reasoning
        )
    }

    static func argumentsString(_ value: AnyCodable?) -> String {
        guard let value else { return "{}" }
        if let string = value.stringValue {
            return string.isEmpty ? "{}" : string
        }
        if let object = value.dictionaryValue {
            return ProviderWireJSON.compactText(object)
        }
        return "{}"
    }

    static func usage(_ value: AnyCodable?) -> ModelUsage? {
        guard let value, value.dictionaryValue != nil else { return nil }
        let prompt = value.wireInt("prompt_tokens") ?? value.wireInt("input_tokens") ?? 0
        let completion = value.wireInt("completion_tokens") ?? value.wireInt("output_tokens") ?? 0
        let cached = value[wireKey: "prompt_tokens_details"]?.wireInt("cached_tokens")
            ?? value.wireInt("prompt_cache_hit_tokens")
            ?? value[wireKey: "input_tokens_details"]?.wireInt("cached_tokens")
            ?? 0
        let reasoning = value[wireKey: "completion_tokens_details"]?.wireInt("reasoning_tokens") ?? 0
        let total = value.wireInt("total_tokens")
        return ModelUsage(
            inputTokens: max(0, prompt - cached),
            outputTokens: completion,
            cacheReadTokens: cached,
            reasoningTokens: reasoning,
            totalTokens: total ?? (prompt + completion)
        )
    }

    // MARK: - Stream

    /// Applies one SSE `data:` payload; returns the chunks to emit and whether the stream ended.
    static func handleStreamData(_ data: String, assembler: inout ProviderStreamAssembler) -> (chunks: [ModelStreamChunk], done: Bool) {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" {
            return ([], true)
        }
        guard let object = ProviderWireJSON.object(from: trimmed) else {
            return ([], false)
        }
        let root = AnyCodable(.object(object))
        var chunks: [ModelStreamChunk] = []
        if let model = root.wireString("model") {
            assembler.modelID = model
        }
        for choice in root[wireKey: "choices"]?.arrayValue ?? [] {
            let delta = choice[wireKey: "delta"] ?? choice[wireKey: "message"]
            if let reasoning = delta?.wireString("reasoning_content") ?? delta?.wireString("reasoning"),
               let chunk = assembler.appendReasoning(reasoning)
            {
                chunks.append(chunk)
            }
            if let content = delta?[wireKey: "content"]?.stringValue, let chunk = assembler.appendText(content) {
                chunks.append(chunk)
            }
            for call in delta?[wireKey: "tool_calls"]?.arrayValue ?? [] {
                let index = call.wireInt("index") ?? 0
                let function = call[wireKey: "function"]
                let arguments = function?[wireKey: "arguments"].map { $0.stringValue ?? self.argumentsString($0) } ?? ""
                chunks.append(
                    assembler.appendToolCall(
                        index: index,
                        id: call.wireString("id"),
                        name: function?.wireString("name"),
                        argumentsDelta: arguments
                    )
                )
            }
            if let finish = choice.wireString("finish_reason") {
                assembler.stopReason = ModelStopReason(providerValue: finish)
            }
        }
        if let usage = self.usage(root[wireKey: "usage"]) {
            chunks.append(assembler.setUsage(usage))
        }
        return (chunks, false)
    }
}

/// Chat Completions engine shared by every OpenAI-compatible provider type.
struct OpenAIChatCompletionsEngine: Sendable {
    let settings: ProviderEndpointSettings
    let exchange: ProviderHTTPExchange
    /// Extra headers resolved by the owning provider (for example OpenAI organization/project).
    let extraHeaders: @Sendable (ModelGenerationRequest) -> [String: String]
    /// Default base URL when the config leaves it empty.
    let defaultBaseURL: String?

    init(
        settings: ProviderEndpointSettings,
        exchange: ProviderHTTPExchange,
        defaultBaseURL: String? = nil,
        extraHeaders: @escaping @Sendable (ModelGenerationRequest) -> [String: String] = { _ in [:] }
    ) {
        self.settings = settings
        self.exchange = exchange
        self.defaultBaseURL = defaultBaseURL
        self.extraHeaders = extraHeaders
    }

    static let capabilities = ModelProviderCapabilities(
        supportsStreaming: true,
        supportsTools: true,
        supportsParallelToolCalls: true,
        supportsJSONSchema: true,
        supportsImages: true,
        supportsReasoning: true,
        supportsTranscript: true
    )

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        let prepared = try self.prepare(request, stream: false)
        let response = try await self.exchange.data(for: prepared.urlRequest)
        return try OpenAIChatCompletionsWire.parseResponse(response.body, providerID: self.settings.providerID, modelID: prepared.modelID)
    }

    func stream(_ request: ModelGenerationRequest) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        ProviderStreamSupport.makeStream { continuation in
            let prepared = try self.prepare(request, stream: true)
            let lines = try await self.exchange.lines(for: prepared.urlRequest)
            var assembler = ProviderStreamAssembler(providerID: self.settings.providerID, modelID: prepared.modelID)
            var parser = ServerSentEventParser()
            var finished = false
            for try await line in lines {
                guard let event = parser.consume(line) else { continue }
                let result = OpenAIChatCompletionsWire.handleStreamData(event.data, assembler: &assembler)
                result.chunks.forEach { continuation.yield($0) }
                if result.done {
                    finished = true
                    break
                }
            }
            if !finished, let event = parser.finish() {
                OpenAIChatCompletionsWire.handleStreamData(event.data, assembler: &assembler).chunks.forEach { continuation.yield($0) }
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
        let request = MediaInputPreparation.apply(request, limits: model?.mediaInput?.image)
        let baseURLString = settings.resolvedBaseURLString(for: request, defaultBaseURL: self.defaultBaseURL)
        let baseURL = try settings.resolvedBaseURL(for: request, defaultBaseURL: self.defaultBaseURL)
        if FastModeResolution.resolve(request: request, configured: settings.configuredFastMode, model: model) == true,
           let fastModel = FastModeModelSwap.fastModelID(providerID: settings.providerID, modelID: modelID, api: settings.api)
        {
            modelID = fastModel
        }
        let path = settings.chatCompletionsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("\(settings.providerID) chat completions path is required")
        }
        let endpoint = ProviderEndpointSettings.appending(path: path, to: baseURL)
        let compat = OpenAIChatCompletionsCompat.resolve(
            providerID: settings.providerID,
            modelID: modelID,
            baseURL: baseURLString,
            compat: model?.compat,
            api: settings.api
        )
        let context = OpenAIChatCompletionsWire.BuildContext(
            providerID: settings.providerID,
            modelID: modelID,
            model: model,
            api: settings.api,
            baseURL: baseURLString,
            compat: compat,
            stream: stream,
            configuredFastMode: settings.configuredFastMode,
            maxTokens: settings.maxTokens(for: request, model: model)
        )
        let payload = OpenAIChatCompletionsWire.buildPayload(request: request, context: context)
        var urlRequest = settings.makeJSONRequest(url: endpoint, request: request, model: model, streaming: stream)
        if !settings.applyRequestAuthOverride(to: &urlRequest), settings.runtime.providerConfig?.authHeader != false {
            if settings.authMode == .awsSDK {
                throw OpenClawCoreError.invalidConfiguration(
                    "\(settings.providerID) does not support aws-sdk auth mode for OpenAI-completions requests"
                )
            }
            if let token = try settings.bearerCredential(for: request) {
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        if let organizationID = ModelGenerationRequest.normalized(settings.organizationID) {
            urlRequest.setValue(organizationID, forHTTPHeaderField: "x-organization-id")
        }
        var headers = settings.mergedHeaders(for: request, model: model)
        headers.merge(self.extraHeaders(request)) { _, extra in extra }
        ProviderRequestResolution.applyHeaders(headers, request: &urlRequest)
        urlRequest.httpBody = try ProviderWireJSON.encode(payload)
        return Prepared(urlRequest: urlRequest, modelID: modelID)
    }
}
