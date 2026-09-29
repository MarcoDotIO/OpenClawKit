import Foundation
import OpenClawCore
import OpenClawProtocol

/// JSON helpers for provider wire payloads.
///
/// Payloads are built as `[String: Any]` trees (like upstream's object literals) so compat shaping
/// can add and strip fields, then normalized into ``AnyCodable`` and encoded with sorted keys for
/// deterministic bodies.
enum ProviderWireJSON {
    /// Encodes a payload tree with sorted keys.
    static func encode(_ object: [String: Any]) throws -> Data {
        guard let value = AnyCodable.fromFoundation(object) else {
            throw OpenClawCoreError.invalidConfiguration("Provider payload is not JSON encodable")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// Decodes a JSON body into a type-erased tree.
    static func decode(_ data: Data) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    /// Decodes one JSON text fragment (SSE data line, NDJSON line) into an object.
    static func object(from text: String) -> [String: AnyCodable]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(AnyCodable.self, from: data))?.dictionaryValue
    }

    /// Converts a schema/arguments dictionary to a Foundation tree for payload building.
    static func foundation(_ object: [String: AnyCodable]) -> [String: Any] {
        object.mapValues(\.foundationValue)
    }

    /// Parses tool-call argument text into a JSON object (empty object for blank or invalid text).
    static func argumentsObject(_ argumentsJSON: String) -> [String: Any] {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: AnyCodable].self, from: data)
        else {
            return [:]
        }
        return self.foundation(decoded)
    }

    /// Encodes a JSON object as compact, key-sorted text (tool-call arguments).
    static func compactText(_ object: [String: AnyCodable]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension AnyCodable {
    /// Object member lookup used by provider response parsers.
    subscript(wireKey key: String) -> AnyCodable? {
        self.dictionaryValue?[key]
    }

    /// String member lookup that ignores empty strings.
    func wireString(_ key: String) -> String? {
        guard let value = self.dictionaryValue?[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    /// Integer member lookup.
    func wireInt(_ key: String) -> Int? {
        self.dictionaryValue?[key]?.intValue
    }
}

/// Accumulates streamed provider events into chunks and a final response.
struct ProviderStreamAssembler {
    struct PartialToolCall {
        var id: String
        var name: String
        var arguments: String
    }

    let providerID: String
    var modelID: String
    private(set) var text = ""
    private(set) var reasoning = ""
    private(set) var reasoningSignature: String?
    /// Set when several signed reasoning blocks were merged, so no single signature is valid.
    var reasoningSignatureInvalid = false
    private var toolCallsByIndex: [Int: PartialToolCall] = [:]
    private var toolCallOrder: [Int] = []
    private var toolCallIndexByID: [String: Int] = [:]
    private var lastToolCallIndex: Int?
    private(set) var usage: ModelUsage?
    var stopReason: ModelStopReason?

    init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }

    /// Records a visible text delta.
    mutating func appendText(_ delta: String) -> ModelStreamChunk? {
        guard !delta.isEmpty else { return nil }
        self.text += delta
        return ModelStreamChunk(text: delta)
    }

    /// Records a reasoning delta.
    mutating func appendReasoning(_ delta: String) -> ModelStreamChunk? {
        guard !delta.isEmpty else { return nil }
        self.reasoning += delta
        return .reasoningDelta(delta)
    }

    /// Records an opaque reasoning signature (Anthropic thinking signatures).
    mutating func setReasoningSignature(_ signature: String) {
        self.reasoningSignature = (self.reasoningSignature ?? "") + signature
    }

    /// Records a tool-call fragment; `id` and `name` usually arrive on the first fragment.
    mutating func appendToolCall(index: Int, id: String?, name: String?, argumentsDelta: String) -> ModelStreamChunk {
        var call = self.toolCallsByIndex[index] ?? PartialToolCall(id: "", name: "", arguments: "")
        if self.toolCallsByIndex[index] == nil {
            self.toolCallOrder.append(index)
        }
        if let id, !id.isEmpty {
            call.id = id
        }
        if let name, !name.isEmpty {
            call.name = name
        }
        call.arguments += argumentsDelta
        self.toolCallsByIndex[index] = call
        return .toolCallUpdate(
            ModelToolCallDelta(
                index: index,
                id: id.flatMap { $0.isEmpty ? nil : $0 },
                name: name.flatMap { $0.isEmpty ? nil : $0 },
                argumentsDelta: argumentsDelta
            )
        )
    }

    /// Resolves the slot for a streamed tool-call fragment (upstream `openai-completions-stream.ts`):
    /// the stream `index` first, then a previously seen call `id`; a new id without an index gets the
    /// next free slot, and a fragment with neither continues the most recent call. Both aliases are
    /// bound so later fragments keyed either way land on the same call.
    mutating func resolveToolCallIndex(streamIndex: Int?, id: String?) -> Int {
        let id = id.flatMap { $0.isEmpty ? nil : $0 }
        let index: Int
        if let streamIndex {
            index = streamIndex
        } else if let id, let bound = self.toolCallIndexByID[id] {
            index = bound
        } else if id != nil {
            index = self.nextToolCallIndex
        } else {
            index = self.lastToolCallIndex ?? 0
        }
        if let id, self.toolCallIndexByID[id] == nil {
            self.toolCallIndexByID[id] = index
        }
        self.lastToolCallIndex = index
        return index
    }

    /// Replaces a tool call's accumulated arguments with a complete payload (for `…done` events).
    mutating func completeToolCall(index: Int, id: String?, name: String?, argumentsJSON: String?) {
        var call = self.toolCallsByIndex[index] ?? PartialToolCall(id: "", name: "", arguments: "")
        if self.toolCallsByIndex[index] == nil {
            self.toolCallOrder.append(index)
        }
        if let id, !id.isEmpty {
            call.id = id
        }
        if let name, !name.isEmpty {
            call.name = name
        }
        if let argumentsJSON {
            call.arguments = argumentsJSON
        }
        self.toolCallsByIndex[index] = call
    }

    /// Whether a tool call index is known.
    func hasToolCall(index: Int) -> Bool {
        self.toolCallsByIndex[index] != nil
    }

    /// Next unused tool-call index.
    var nextToolCallIndex: Int {
        (self.toolCallOrder.max() ?? -1) + 1
    }

    /// Records usage; returns a usage chunk.
    mutating func setUsage(_ usage: ModelUsage) -> ModelStreamChunk {
        self.usage = usage
        return .usageUpdate(usage)
    }

    /// Complete tool calls in arrival order; missing ids are synthesized.
    var toolCalls: [ModelToolCall] {
        self.toolCallOrder.compactMap { index in
            guard let call = self.toolCallsByIndex[index], !call.name.isEmpty else { return nil }
            let id = call.id.isEmpty ? ProviderToolCallIDs.synthesize(index: index) : call.id
            let arguments = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            return ModelToolCall(id: id, name: call.name, argumentsJSON: arguments.isEmpty ? "{}" : arguments)
        }
    }

    /// Final response for the assembled stream.
    func response() -> ModelGenerationResponse {
        let calls = self.toolCalls
        let stop: ModelStopReason?
        if let stopReason = self.stopReason {
            stop = (stopReason == .stop && !calls.isEmpty) ? .toolUse : stopReason
        } else {
            stop = nil
        }
        return ModelGenerationResponse(
            text: self.text,
            providerID: self.providerID,
            modelID: self.modelID,
            toolCalls: calls,
            usage: self.usage,
            stopReason: stop,
            reasoningText: self.reasoning.isEmpty ? nil : self.reasoning,
            reasoningSignature: self.reasoningSignatureInvalid ? nil : self.reasoningSignature
        )
    }
}

/// Tool-call id helpers.
enum ProviderToolCallIDs {
    /// Synthesizes a stable-looking id for providers that do not assign one (Gemini, Ollama).
    static func synthesize(index: Int) -> String {
        "call_\(index)_\(UUID().uuidString.prefix(8).lowercased())"
    }
}

/// Stream plumbing shared by the provider engines.
enum ProviderStreamSupport {
    /// Runs `body` in a task feeding an `AsyncThrowingStream`, cancelling the task on termination.
    ///
    /// Errors (including transport errors raised mid-body) finish the stream through
    /// ``ProviderErrorRedaction/sanitize(_:)`` so request URLs never reach consumers.
    static func makeStream(
        _ body: @escaping @Sendable (AsyncThrowingStream<ModelStreamChunk, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ProviderErrorRedaction.sanitize(error))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Consumes a chunk stream into a complete response (used by stream-only backends).
    static func collect(
        _ stream: AsyncThrowingStream<ModelStreamChunk, Error>,
        providerID: String,
        modelID: String
    ) async throws -> ModelGenerationResponse {
        var text = ""
        var reasoning = ""
        var final: ModelStreamChunk?
        var usage: ModelUsage?
        for try await chunk in stream {
            switch chunk.kind {
            case .text:
                text += chunk.text
            case .reasoning:
                reasoning += chunk.reasoningText ?? ""
            case .usage:
                usage = chunk.usage ?? usage
            case .toolCallDelta:
                break
            case .final:
                text += chunk.text
                final = chunk
            }
        }
        return ModelGenerationResponse(
            text: text,
            providerID: providerID,
            modelID: modelID,
            toolCalls: final?.toolCalls ?? [],
            usage: final?.usage ?? usage,
            stopReason: final?.stopReason,
            reasoningText: reasoning.isEmpty ? nil : reasoning,
            reasoningSignature: final?.reasoningSignature
        )
    }
}

/// Validation shared by every contract-v2 HTTP provider.
enum ProviderRequestValidation {
    /// Rejects tools for models whose compat declares `supportsTools == false`.
    static func validate(
        _ request: ModelGenerationRequest,
        providerID: String,
        model: ModelDefinitionConfig?
    ) throws {
        try request.validateToolSupport(supportsTools: model?.compat?.supportsTools, providerID: providerID)
    }

    /// Whether a request uses contract v2 features that simple adapters cannot express.
    static func usesContractV2(_ request: ModelGenerationRequest) -> Bool {
        !request.messages.isEmpty || !request.tools.isEmpty || request.responseFormat != .text || request.toolChoice != .auto
    }
}

/// Text helpers for content parts.
enum ProviderContentText {
    /// Joins text parts; non-text parts are described inline.
    static func flatten(_ parts: [ModelContentPart]) -> String {
        parts.compactMap { part -> String? in
            switch part {
            case .text(let text):
                return text
            case .image(let attachment), .attachment(let attachment):
                let name = MultimodalAttachmentUtilities.displayName(for: attachment)
                let mime = MultimodalAttachmentUtilities.normalizedMimeType(for: attachment)
                if let preview = MultimodalAttachmentUtilities.inlineTextPreview(for: attachment, mimeType: mime) {
                    return "Text attachment: \(name) (\(mime))\n\(preview)"
                }
                return "Attachment: \(name) (\(mime))"
            }
        }.joined(separator: "\n")
    }

    /// Text of a tool result, with a placeholder for empty output.
    static func toolResultText(_ result: ModelToolResult) -> String {
        let text = result.content.compactMap(\.text).joined(separator: "\n")
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if result.content.contains(where: { $0.mediaAttachment != nil }) {
            return "(see attached media)"
        }
        return result.isError ? "[tool error with no output]" : "(no output)"
    }

    /// Merged system prompt: request system prompt plus inline system messages.
    static func systemPrompt(for request: ModelGenerationRequest) -> String? {
        var parts: [String] = []
        if let system = ModelGenerationRequest.normalized(request.systemPrompt) {
            parts.append(system)
        }
        for message in request.resolvedMessages {
            if case .system(let content) = message {
                let text = self.flatten(content).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    parts.append(text)
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
