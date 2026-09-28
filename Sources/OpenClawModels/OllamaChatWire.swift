import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Native Ollama `/api/chat` mapping (upstream `extensions/ollama/src/stream.runtime.ts`).
///
/// Base URLs are Ollama roots (`http://127.0.0.1:11434`, `https://ollama.com`); a trailing `/v1`
/// (OpenAI-compat) is stripped. Streaming uses NDJSON.
enum OllamaChatWire {
    static let defaultBaseURL = "http://127.0.0.1:11434"
    static let cloudBaseURL = "https://ollama.com"

    /// Resolves `<root>/api/chat` from a configured base URL.
    static func chatURL(baseURL: String) -> String {
        var normalized = ProviderEndpointSettings.trimmingTrailingSlashes(baseURL)
        if normalized.lowercased().hasSuffix("/v1") {
            normalized = String(normalized.dropLast(3))
        }
        normalized = ProviderEndpointSettings.trimmingTrailingSlashes(normalized)
        return "\(normalized.isEmpty ? self.defaultBaseURL : normalized)/api/chat"
    }

    private static let optionParamKeys: Set<String> = [
        "num_keep", "seed", "num_predict", "top_k", "top_p", "min_p", "typical_p", "repeat_last_n", "temperature",
        "repeat_penalty", "presence_penalty", "frequency_penalty", "stop", "num_batch", "num_gpu", "main_gpu", "num_thread",
    ]
    private static let topLevelParamKeys: Set<String> = ["format", "keep_alive", "truncate", "shift"]

    static func buildPayload(request: ModelGenerationRequest, modelID: String, model: ModelDefinitionConfig?, maxTokens: Int?, stream: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "model": modelID,
            "messages": self.buildMessages(request),
            "stream": stream,
        ]
        var options: [String: Any] = [:]
        for (key, value) in model?.params ?? [:] {
            if self.optionParamKeys.contains(key) {
                options[key] = value.foundationValue
            } else if self.topLevelParamKeys.contains(key) {
                payload[key] = value.foundationValue
            }
        }
        if let numCtx = ProviderRuntimeParams.int(model?.params, keys: ["num_ctx"]) ?? model?.contextTokens {
            options["num_ctx"] = numCtx
        }
        if let temperature = request.policy.temperature {
            options["temperature"] = temperature
        }
        if let topP = request.policy.topP {
            options["top_p"] = topP
        }
        if let topK = request.policy.topK {
            options["top_k"] = topK
        }
        if let maxTokens {
            options["num_predict"] = maxTokens
        }
        if (options["temperature"] as? Double) == 0, options["top_p"] == nil {
            options["top_p"] = 1
        }
        if !options.isEmpty {
            payload["options"] = options
        }
        if !request.tools.isEmpty, request.toolChoice != .none {
            payload["tools"] = request.tools.map { tool -> [String: Any] in
                var function: [String: Any] = ["name": tool.name, "parameters": ProviderWireJSON.foundation(tool.parameters)]
                if !tool.description.isEmpty {
                    function["description"] = tool.description
                }
                return ["type": "function", "function": function]
            }
        }
        switch request.responseFormat {
        case .text:
            break
        case .jsonObject:
            payload["format"] = "json"
        case .jsonSchema(_, let schema, _):
            payload["format"] = ProviderWireJSON.foundation(schema)
        }
        if let level = request.policy.thinkingLevel ?? ThinkLevel.normalize(request.metadata["thinkingLevel"]), model?.reasoning != false {
            switch level {
            case .off:
                payload["think"] = false
            case .minimal, .low:
                payload["think"] = "low"
            case .medium, .adaptive:
                payload["think"] = "medium"
            case .high, .xhigh, .max, .ultra:
                payload["think"] = "high"
            }
            if model == nil || model?.compat?.supportsReasoningEffort == false {
                payload["think"] = level != .off
            }
        }
        return payload
    }

    private static func buildMessages(_ request: ModelGenerationRequest) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if let system = ModelGenerationRequest.normalized(request.systemPrompt) {
            messages.append(["role": "system", "content": system])
        }
        for message in request.resolvedMessages {
            switch message {
            case .system(let content):
                messages.append(["role": "system", "content": ProviderContentText.flatten(content)])
            case .user(let content):
                var entry: [String: Any] = ["role": "user"]
                var texts: [String] = []
                var images: [String] = []
                for part in content {
                    switch part {
                    case .text(let text):
                        texts.append(text)
                    case .image(let attachment):
                        images.append(attachment.data.base64EncodedString())
                    case .attachment:
                        texts.append(ProviderContentText.flatten([part]))
                    }
                }
                entry["content"] = texts.joined(separator: "\n")
                if !images.isEmpty {
                    entry["images"] = images
                }
                messages.append(entry)
            case .assistant(let parts):
                var entry: [String: Any] = ["role": "assistant"]
                var text = ""
                var thinking = ""
                var toolCalls: [[String: Any]] = []
                for part in parts {
                    switch part {
                    case .text(let value):
                        text += value
                    case .thinking(let value, _):
                        thinking += value
                    case .toolCall(let call):
                        toolCalls.append(["function": ["name": call.name, "arguments": ProviderWireJSON.argumentsObject(call.argumentsJSON)]])
                    }
                }
                entry["content"] = text
                if !thinking.isEmpty {
                    entry["thinking"] = thinking
                }
                if !toolCalls.isEmpty {
                    entry["tool_calls"] = toolCalls
                }
                messages.append(entry)
            case .toolResult(let result):
                var entry: [String: Any] = ["role": "tool", "content": ProviderContentText.toolResultText(result)]
                if !result.toolName.isEmpty {
                    entry["tool_name"] = result.toolName
                }
                messages.append(entry)
            }
        }
        return messages
    }

    /// Applies one response object (or NDJSON line) to an assembler.
    static func apply(_ root: AnyCodable, assembler: inout ProviderStreamAssembler) -> [ModelStreamChunk] {
        var chunks: [ModelStreamChunk] = []
        if let model = root.wireString("model") {
            assembler.modelID = model
        }
        let message = root[wireKey: "message"]
        if let thinking = message?[wireKey: "thinking"]?.stringValue, let chunk = assembler.appendReasoning(thinking) {
            chunks.append(chunk)
        }
        if let content = message?[wireKey: "content"]?.stringValue, let chunk = assembler.appendText(content) {
            chunks.append(chunk)
        }
        for call in message?[wireKey: "tool_calls"]?.arrayValue ?? [] {
            guard let function = call[wireKey: "function"], let name = function.wireString("name") else { continue }
            let index = assembler.nextToolCallIndex
            chunks.append(
                assembler.appendToolCall(
                    index: index,
                    id: call.wireString("id"),
                    name: name,
                    argumentsDelta: OpenAIChatCompletionsWire.argumentsString(function[wireKey: "arguments"])
                )
            )
        }
        if root[wireKey: "done"]?.boolValue == true {
            if let reason = root.wireString("done_reason") {
                assembler.stopReason = ModelStopReason(providerValue: reason)
            } else {
                assembler.stopReason = .stop
            }
            let prompt = root.wireInt("prompt_eval_count")
            let output = root.wireInt("eval_count")
            if prompt != nil || output != nil {
                chunks.append(assembler.setUsage(ModelUsage(inputTokens: prompt ?? 0, outputTokens: output ?? 0)))
            }
        }
        return chunks
    }
}

/// Native Ollama engine.
struct OllamaChatEngine: Sendable {
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

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        let prepared = try self.prepare(request, stream: false)
        let response = try await self.exchange.data(for: prepared.urlRequest)
        var assembler = ProviderStreamAssembler(providerID: self.settings.providerID, modelID: prepared.modelID)
        _ = OllamaChatWire.apply(try ProviderWireJSON.decode(response.body), assembler: &assembler)
        let parsed = assembler.response()
        let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !parsed.toolCalls.isEmpty else {
            throw OpenClawCoreError.unavailable("\(self.settings.providerID) response did not include message content")
        }
        return ModelGenerationResponse(
            text: parsed.toolCalls.isEmpty ? text : parsed.text,
            providerID: parsed.providerID,
            modelID: parsed.modelID,
            toolCalls: parsed.toolCalls,
            usage: parsed.usage,
            stopReason: parsed.stopReason,
            reasoningText: parsed.reasoningText
        )
    }

    func stream(_ request: ModelGenerationRequest) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        let providerID = self.settings.providerID
        return ProviderStreamSupport.makeStream { continuation in
            let prepared = try self.prepare(request, stream: true)
            let lines = try await self.exchange.lines(for: prepared.urlRequest)
            var assembler = ProviderStreamAssembler(providerID: providerID, modelID: prepared.modelID)
            for try await line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let object = ProviderWireJSON.object(from: trimmed) else { continue }
                if let error = object["error"]?.stringValue {
                    throw OpenClawCoreError.unavailable("\(providerID) stream failed: \(error)")
                }
                OllamaChatWire.apply(AnyCodable(.object(object)), assembler: &assembler).forEach { continuation.yield($0) }
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
        let modelID = settings.resolvedModelID(for: request)
        let model = settings.modelDefinition(for: modelID)
        try ProviderRequestValidation.validate(request, providerID: settings.providerID, model: model)
        let base = settings.resolvedBaseURLString(for: request, defaultBaseURL: OllamaChatWire.defaultBaseURL)
        guard let url = URL(string: OllamaChatWire.chatURL(baseURL: base)), url.scheme != nil else {
            throw OpenClawCoreError.invalidConfiguration("\(settings.providerID) base URL is invalid")
        }
        var urlRequest = settings.makeJSONRequest(url: url, request: request, model: model, streaming: false)
        if stream {
            urlRequest.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        }
        if !settings.applyRequestAuthOverride(to: &urlRequest) {
            switch settings.authMode {
            case .none, .awsSDK:
                if let key = ModelGenerationRequest.normalized(settings.apiKey) {
                    urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                }
            default:
                if let token = try settings.bearerCredential(for: request) {
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
            }
        }
        ProviderRequestResolution.applyHeaders(settings.mergedHeaders(for: request, model: model), request: &urlRequest)
        let payload = OllamaChatWire.buildPayload(
            request: request,
            modelID: modelID,
            model: model,
            maxTokens: settings.maxTokens(for: request, model: model),
            stream: stream
        )
        urlRequest.httpBody = try ProviderWireJSON.encode(payload)
        return Prepared(urlRequest: urlRequest, modelID: modelID)
    }
}
