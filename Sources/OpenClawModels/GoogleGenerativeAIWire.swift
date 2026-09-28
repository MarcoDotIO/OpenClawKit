import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Google Generative Language / Vertex `generateContent` mapping for contract v2 (upstream
/// `packages/ai/src/providers/google-shared.ts`, `google-stream.ts`).
enum GoogleGenerativeAIWire {
    struct BuildContext {
        var modelID: String
        var model: ModelDefinitionConfig?
        var maxTokens: Int?
        /// Legacy Gemini provider behavior: prepend the system prompt to the user prompt.
        var inlineSystemPrompt: Bool
    }

    static func buildPayload(request: ModelGenerationRequest, context: BuildContext) -> [String: Any] {
        var payload: [String: Any] = [:]
        let systemPrompt = ProviderContentText.systemPrompt(for: request)
        let legacy = request.messages.isEmpty
        if legacy {
            var prompt = request.prompt
            if context.inlineSystemPrompt, let systemPrompt {
                prompt = "\(systemPrompt)\n\nUser:\n\(request.prompt)"
            }
            let parts = GeminiMultimodalSupport.parts(prompt: prompt, attachments: request.attachments).map(self.foundationPart)
            payload["contents"] = [["role": "user", "parts": parts]]
            if !context.inlineSystemPrompt, let systemPrompt {
                payload["systemInstruction"] = ["parts": [["text": systemPrompt]]]
            }
        } else {
            payload["contents"] = self.buildContents(request.resolvedMessages, modelID: context.modelID)
            if let systemPrompt {
                payload["systemInstruction"] = ["parts": [["text": systemPrompt]]]
            }
        }
        var generationConfig: [String: Any] = [:]
        if let maxTokens = context.maxTokens {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if let temperature = request.policy.temperature {
            generationConfig["temperature"] = temperature
        }
        if let topP = request.policy.topP {
            generationConfig["topP"] = topP
        }
        if let topK = request.policy.topK {
            generationConfig["topK"] = topK
        }
        switch request.responseFormat {
        case .text:
            break
        case .jsonObject:
            generationConfig["responseMimeType"] = "application/json"
        case .jsonSchema(_, let schema, _):
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseJsonSchema"] = ProviderWireJSON.foundation(schema)
        }
        if let thinking = self.thinkingConfig(request: request, context: context) {
            generationConfig["thinkingConfig"] = thinking
        }
        if !generationConfig.isEmpty {
            payload["generationConfig"] = generationConfig
        }
        if !request.tools.isEmpty {
            payload["tools"] = [[
                "functionDeclarations": request.tools.sorted(by: { $0.name < $1.name }).map { tool -> [String: Any] in
                    var declaration: [String: Any] = [
                        "name": tool.name,
                        "parametersJsonSchema": ProviderWireJSON.foundation(tool.parameters),
                    ]
                    if !tool.description.isEmpty {
                        declaration["description"] = tool.description
                    }
                    return declaration
                },
            ]]
            if let toolConfig = self.toolConfig(request.toolChoice) {
                payload["toolConfig"] = toolConfig
            }
        }
        return payload
    }

    /// Thinking config (upstream `buildGoogleSimpleThinking` / `getDisabledGoogleThinkingConfig`).
    static func thinkingConfig(request: ModelGenerationRequest, context: BuildContext) -> [String: Any]? {
        guard let level = request.policy.thinkingLevel ?? ThinkLevel.normalize(request.metadata["thinkingLevel"]) else {
            return nil
        }
        if let model = context.model, !model.reasoning {
            return nil
        }
        let id = context.modelID.lowercased()
        let isGemma4 = id.contains("gemma-4") || id.contains("gemma4")
        let isGemini3Pro = self.matchesGemini3(id, family: "pro") || id.contains("gemini-pro-latest")
        let isGemini3Flash = self.matchesGemini3(id, family: "flash") || id.contains("gemini-flash-latest")
            || id.contains("gemini-flash-lite-latest")
        if let map = context.model?.thinkingLevelMap, case .value(let native) = map.mapping(for: level.providerTransportLevel) {
            return ["thinkingLevel": native.uppercased(), "includeThoughts": level != .off]
        }
        switch level {
        case .off:
            if isGemini3Pro {
                return ["thinkingLevel": "LOW"]
            }
            if isGemini3Flash {
                return ["thinkingLevel": "LOW"]
            }
            if isGemma4 || id.contains("gemini-2.5-pro") {
                return nil
            }
            return ["thinkingBudget": 0]
        case .adaptive:
            if isGemma4 {
                return ["includeThoughts": true, "thinkingLevel": "HIGH"]
            }
            if isGemini3Pro || isGemini3Flash {
                return ["includeThoughts": true]
            }
            return ["includeThoughts": true, "thinkingBudget": -1]
        default:
            let effort: String
            switch level {
            case .minimal:
                effort = "minimal"
            case .low:
                effort = "low"
            case .medium:
                effort = "medium"
            default:
                effort = "high"
            }
            if isGemini3Pro || isGemini3Flash || isGemma4 {
                return ["includeThoughts": true, "thinkingLevel": self.googleThinkingLevel(effort, pro: isGemini3Pro, gemma: isGemma4, flash: isGemini3Flash)]
            }
            return ["includeThoughts": true, "thinkingBudget": self.googleBudget(id, effort: effort)]
        }
    }

    private static func matchesGemini3(_ id: String, family: String) -> Bool {
        guard let range = id.range(of: "gemini-3") else { return false }
        var rest = id[range.upperBound...]
        if rest.first == "." {
            rest = rest.dropFirst().drop(while: \.isNumber)
        }
        return rest.hasPrefix("-\(family)")
    }

    private static func googleThinkingLevel(_ effort: String, pro: Bool, gemma: Bool, flash: Bool) -> String {
        if pro {
            return effort == "minimal" || effort == "low" ? "LOW" : "HIGH"
        }
        if gemma {
            return effort == "minimal" || effort == "low" ? "MINIMAL" : "HIGH"
        }
        switch effort {
        case "minimal":
            return flash ? "LOW" : "MINIMAL"
        case "low":
            return "LOW"
        case "medium":
            return "MEDIUM"
        default:
            return "HIGH"
        }
    }

    private static func googleBudget(_ id: String, effort: String) -> Int {
        let budgets: [String: Int]
        if id.contains("2.5-pro") {
            budgets = ["minimal": 128, "low": 2_048, "medium": 8_192, "high": 32_768]
        } else if id.contains("2.5-flash-lite") {
            budgets = ["minimal": 512, "low": 2_048, "medium": 8_192, "high": 24_576]
        } else if id.contains("2.5-flash") {
            budgets = ["minimal": 128, "low": 2_048, "medium": 8_192, "high": 24_576]
        } else {
            return -1
        }
        return budgets[effort] ?? -1
    }

    private static func toolConfig(_ choice: ModelToolChoice) -> [String: Any]? {
        switch choice {
        case .auto:
            return nil
        case .none:
            return ["functionCallingConfig": ["mode": "NONE"]]
        case .required:
            return ["functionCallingConfig": ["mode": "ANY"]]
        case .named(let name):
            return ["functionCallingConfig": ["mode": "ANY", "allowedFunctionNames": [name]]]
        }
    }

    /// Dummy signature Google documents for replaying function calls whose thought signature is unknown.
    static let skipThoughtSignatureValidator = "skip_thought_signature_validator"

    private static func buildContents(_ messages: [ModelMessage], modelID: String) -> [[String: Any]] {
        let requiresSignatures = modelID.lowercased().contains("gemini-3")
        var contents: [[String: Any]] = []
        var toolNamesByID: [String: String] = [:]
        func append(role: String, parts: [[String: Any]]) {
            guard !parts.isEmpty else { return }
            if var last = contents.last, (last["role"] as? String) == role, var lastParts = last["parts"] as? [[String: Any]] {
                lastParts.append(contentsOf: parts)
                last["parts"] = lastParts
                contents[contents.count - 1] = last
            } else {
                contents.append(["role": role, "parts": parts])
            }
        }
        for message in messages {
            switch message {
            case .system:
                continue
            case .user(let content):
                append(role: "user", parts: content.compactMap(self.inputPart))
            case .assistant(let parts):
                var converted: [[String: Any]] = []
                for part in parts {
                    switch part {
                    case .text(let text):
                        if !text.isEmpty {
                            converted.append(["text": text])
                        }
                    case .thinking(let text, let signature):
                        if let signature, !signature.isEmpty {
                            converted.append(["text": text, "thought": true, "thoughtSignature": signature])
                        }
                    case .toolCall(let call):
                        toolNamesByID[call.id] = call.name
                        var part: [String: Any] = ["functionCall": ["name": call.name, "args": ProviderWireJSON.argumentsObject(call.argumentsJSON)]]
                        if let signature = GoogleThoughtSignatureCache.shared.signature(forCallID: call.id) {
                            part["thoughtSignature"] = signature
                        } else if requiresSignatures {
                            part["thoughtSignature"] = self.skipThoughtSignatureValidator
                        }
                        converted.append(part)
                    }
                }
                append(role: "model", parts: converted)
            case .toolResult(let result):
                let name = result.toolName.isEmpty ? (toolNamesByID[result.toolCallID] ?? result.toolCallID) : result.toolName
                let text = ProviderContentText.toolResultText(result)
                let key = result.isError ? "error" : "output"
                var parts: [[String: Any]] = [["functionResponse": ["name": name, "response": [key: text]]]]
                for part in result.content {
                    if case .image = part, let inline = self.inputPart(part) {
                        parts.append(inline)
                    }
                }
                append(role: "user", parts: parts)
            }
        }
        return contents
    }

    private static func inputPart(_ part: ModelContentPart) -> [String: Any]? {
        switch part {
        case .text(let text):
            return text.isEmpty ? nil : ["text": text]
        case .image(let attachment):
            let mime = MultimodalAttachmentUtilities.normalizedMimeType(for: attachment)
            return ["inline_data": ["mime_type": mime, "data": attachment.data.base64EncodedString()]]
        case .attachment(let attachment):
            let mime = MultimodalAttachmentUtilities.normalizedMimeType(for: attachment)
            if mime.hasPrefix("audio/") || mime.hasPrefix("video/") || mime == "application/pdf" {
                return ["inline_data": ["mime_type": mime, "data": attachment.data.base64EncodedString()]]
            }
            return ["text": ProviderContentText.flatten([part])]
        }
    }

    private static func foundationPart(_ part: GeminiInputPart) -> [String: Any] {
        switch part {
        case .text(let text):
            return ["text": text]
        case .inlineData(let mimeType, let data):
            return ["inline_data": ["mime_type": mimeType, "data": data]]
        }
    }

    // MARK: - Response

    static func usage(_ value: AnyCodable?) -> ModelUsage? {
        guard let value, value.dictionaryValue != nil else { return nil }
        let prompt = value.wireInt("promptTokenCount") ?? 0
        let cached = value.wireInt("cachedContentTokenCount") ?? 0
        let candidates = value.wireInt("candidatesTokenCount") ?? 0
        let thoughts = value.wireInt("thoughtsTokenCount") ?? 0
        return ModelUsage(
            inputTokens: max(0, prompt - cached),
            outputTokens: candidates + thoughts,
            cacheReadTokens: cached,
            reasoningTokens: thoughts,
            totalTokens: value.wireInt("totalTokenCount") ?? (prompt + candidates + thoughts)
        )
    }

    static func stopReason(_ raw: String?) -> ModelStopReason? {
        guard let raw else { return nil }
        switch raw.uppercased() {
        case "STOP", "FINISH_REASON_UNSPECIFIED":
            return .stop
        case "MAX_TOKENS":
            return .length
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY":
            return .contentFilter
        case "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL":
            return .error
        default:
            return ModelStopReason(providerValue: raw)
        }
    }

    /// Applies one response (or stream chunk) to an assembler.
    static func apply(_ root: AnyCodable, assembler: inout ProviderStreamAssembler) -> [ModelStreamChunk] {
        var chunks: [ModelStreamChunk] = []
        if let model = root.wireString("modelVersion") {
            assembler.modelID = model
        }
        let candidate = root[wireKey: "candidates"]?.arrayValue?.first
        for part in candidate?[wireKey: "content"]?[wireKey: "parts"]?.arrayValue ?? [] {
            if let call = part[wireKey: "functionCall"] ?? part[wireKey: "function_call"], let name = call.wireString("name") {
                let index = assembler.nextToolCallIndex
                let arguments = call[wireKey: "args"]?.dictionaryValue.map(ProviderWireJSON.compactText) ?? "{}"
                let callID = call.wireString("id") ?? ProviderToolCallIDs.synthesize(index: index)
                if let signature = part.wireString("thoughtSignature") ?? part.wireString("thought_signature") {
                    GoogleThoughtSignatureCache.shared.store(signature, forCallID: callID)
                }
                chunks.append(assembler.appendToolCall(index: index, id: callID, name: name, argumentsDelta: arguments))
                continue
            }
            guard let text = part[wireKey: "text"]?.stringValue else { continue }
            if part[wireKey: "thought"]?.boolValue == true {
                if let chunk = assembler.appendReasoning(text) {
                    chunks.append(chunk)
                }
            } else if let chunk = assembler.appendText(text) {
                chunks.append(chunk)
            }
        }
        if let reason = self.stopReason(candidate?.wireString("finishReason")) {
            assembler.stopReason = reason
        }
        if let usage = self.usage(root[wireKey: "usageMetadata"]) {
            chunks.append(assembler.setUsage(usage))
        }
        return chunks
    }
}

/// Google Generative AI engine (Gemini API key and OAuth routes, Vertex).
struct GoogleGenerativeAIEngine: Sendable {
    let settings: ProviderEndpointSettings
    let exchange: ProviderHTTPExchange
    let inlineSystemPrompt: Bool
    let fallbackModelID: String

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
        let root = try ProviderWireJSON.decode(response.body)
        var assembler = ProviderStreamAssembler(providerID: self.settings.providerID, modelID: prepared.modelID)
        _ = GoogleGenerativeAIWire.apply(root, assembler: &assembler)
        assembler.modelID = prepared.modelID
        let parsed = assembler.response()
        let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !parsed.toolCalls.isEmpty else {
            throw OpenClawCoreError.unavailable("\(self.settings.providerID) response did not include generated text")
        }
        return ModelGenerationResponse(
            text: parsed.toolCalls.isEmpty ? text : parsed.text,
            providerID: parsed.providerID,
            modelID: prepared.modelID,
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
            var parser = ServerSentEventParser()
            var rawBody = ""
            var sawEvent = false
            for try await line in lines {
                if !sawEvent, rawBody.utf8.count < 1_048_576 {
                    rawBody += line + "\n"
                }
                guard let event = parser.consume(line), let object = ProviderWireJSON.object(from: event.data) else { continue }
                sawEvent = true
                GoogleGenerativeAIWire.apply(AnyCodable(.object(object)), assembler: &assembler).forEach { continuation.yield($0) }
            }
            if let event = parser.finish(), let object = ProviderWireJSON.object(from: event.data) {
                sawEvent = true
                GoogleGenerativeAIWire.apply(AnyCodable(.object(object)), assembler: &assembler).forEach { continuation.yield($0) }
            }
            if !sawEvent, let data = rawBody.data(using: .utf8), let root = try? ProviderWireJSON.decode(data) {
                let elements = root.arrayValue ?? [root]
                for element in elements {
                    GoogleGenerativeAIWire.apply(element, assembler: &assembler).forEach { continuation.yield($0) }
                }
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
        let modelID = request.resolvedModelID ?? ModelGenerationRequest.normalized(settings.defaultModelID) ?? self.fallbackModelID
        let model = settings.modelDefinition(for: modelID)
        try ProviderRequestValidation.validate(request, providerID: settings.providerID, model: model)
        var baseString = settings.resolvedBaseURLString(for: request, defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta")
        if settings.api == .googleVertex || baseString.contains("{location}") || baseString.contains("{region}") {
            let location = settings.region
                ?? ProviderRuntimeParams.string(settings.runtime.providerConfig?.params, keys: ["location", "region"])
            baseString = ProviderEndpointTemplates.vertexBaseURL(baseString, location: location)
        }
        guard let baseURL = URL(string: baseString), baseURL.scheme != nil else {
            throw OpenClawCoreError.invalidConfiguration("\(settings.providerID) base URL is invalid")
        }
        let method = stream ? "streamGenerateContent" : "generateContent"
        var components = URLComponents(url: baseURL.appendingPathComponent("models/\(modelID):\(method)"), resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        if stream {
            queryItems.append(URLQueryItem(name: "alt", value: "sse"))
        }
        var urlRequest: URLRequest
        switch settings.authMode {
        case .apiKey:
            let apiKey = try ProviderRequestResolution.resolveAPIKey(configured: settings.apiKey, request: request, providerID: settings.providerID)
            queryItems.append(URLQueryItem(name: "key", value: apiKey))
            components?.queryItems = queryItems
            guard let url = components?.url else {
                throw OpenClawCoreError.invalidConfiguration("\(settings.providerID) endpoint is invalid")
            }
            urlRequest = settings.makeJSONRequest(url: url, request: request, model: model, streaming: stream)
        case .bearerToken, .oauthToken:
            components?.queryItems = queryItems.isEmpty ? nil : queryItems
            guard let url = components?.url else {
                throw OpenClawCoreError.invalidConfiguration("\(settings.providerID) endpoint is invalid")
            }
            urlRequest = settings.makeJSONRequest(url: url, request: request, model: model, streaming: stream)
            let token = try ProviderRequestResolution.resolveAccessToken(
                configured: settings.accessToken ?? settings.apiKey,
                request: request,
                providerID: settings.providerID
            )
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .awsSDK:
            throw OpenClawCoreError.invalidConfiguration("\(settings.providerID) does not support aws-sdk auth mode")
        case .none:
            components?.queryItems = queryItems.isEmpty ? nil : queryItems
            guard let url = components?.url else {
                throw OpenClawCoreError.invalidConfiguration("\(settings.providerID) endpoint is invalid")
            }
            urlRequest = settings.makeJSONRequest(url: url, request: request, model: model, streaming: stream)
        }
        _ = settings.applyRequestAuthOverride(to: &urlRequest)
        ProviderRequestResolution.applyHeaders(settings.mergedHeaders(for: request, model: model), request: &urlRequest)
        let context = GoogleGenerativeAIWire.BuildContext(
            modelID: modelID,
            model: model,
            maxTokens: settings.maxTokens(for: request, model: model),
            inlineSystemPrompt: self.inlineSystemPrompt
        )
        urlRequest.httpBody = try ProviderWireJSON.encode(GoogleGenerativeAIWire.buildPayload(request: request, context: context))
        return Prepared(urlRequest: urlRequest, modelID: modelID)
    }
}

/// In-process cache of Gemini thought signatures keyed by tool-call id.
///
/// Gemini 3 requires the `thoughtSignature` of each function call to be replayed with it; the SDK
/// tool-call contract carries only id, name and arguments, so signatures are remembered here for
/// the lifetime of the process (bounded). Unknown signatures on Gemini 3 replays fall back to the
/// documented `skip_thought_signature_validator` value.
final class GoogleThoughtSignatureCache: @unchecked Sendable {
    static let shared = GoogleThoughtSignatureCache()

    private let lock = NSLock()
    private var signatures: [String: String] = [:]
    private var order: [String] = []
    private let capacity = 1_024

    func store(_ signature: String, forCallID callID: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.signatures[callID] == nil {
            self.order.append(callID)
        }
        self.signatures[callID] = signature
        while self.order.count > self.capacity {
            let evicted = self.order.removeFirst()
            self.signatures.removeValue(forKey: evicted)
        }
    }

    func signature(forCallID callID: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.signatures[callID]
    }
}
