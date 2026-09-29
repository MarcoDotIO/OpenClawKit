import Foundation
import OpenClawCore
import OpenClawProtocol

// Model request/response contract v2: transcript messages, tool definitions and calls, response
// formats, usage and stop reasons. Shapes follow upstream `packages/llm-core/src/types.ts`
// (UserMessage/AssistantMessage/ToolResultMessage, Tool, ToolCall, Usage, StopReason).
//
// Providers only *propose* tool calls. Executing them, and asking for approval first, is owned by
// the host or the agent loop; no provider in this module runs a tool.

// MARK: - Messages

/// Conversation role of a ``ModelMessage``.
public enum ModelMessageRole: String, Codable, Sendable, Equatable, CaseIterable {
    /// Additional system/developer instructions inside the transcript.
    case system
    /// User turn.
    case user
    /// Assistant turn.
    case assistant
    /// Tool result answering an assistant tool call (upstream role `toolResult`).
    case tool
}

/// Content part of a system message, user message, or tool result.
///
/// Wire shape: `{"type":"text","text":…}`, `{"type":"image","attachment":{…}}` and
/// `{"type":"attachment","attachment":{…}}`. Decoding also accepts the upstream image block
/// `{"type":"image","data":"<base64>","mimeType":…}`.
public enum ModelContentPart: Sendable, Equatable, Codable {
    /// Plain text.
    case text(String)
    /// Image input.
    case image(MediaAttachment)
    /// Non-image media or file input (audio, video, documents).
    case attachment(MediaAttachment)

    /// Text payload for `.text` parts.
    public var text: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }

    /// Media payload for `.image` and `.attachment` parts.
    public var mediaAttachment: MediaAttachment? {
        switch self {
        case .text:
            return nil
        case .image(let attachment), .attachment(let attachment):
            return attachment
        }
    }

    /// Wraps an attachment as `.image` for `image/*` MIME types and `.attachment` otherwise.
    /// - Parameter attachment: Media attachment.
    /// - Returns: The matching content part.
    public static func media(_ attachment: MediaAttachment) -> ModelContentPart {
        attachment.mimeType.lowercased().hasPrefix("image/") ? .image(attachment) : .attachment(attachment)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case attachment
        case data
        case mimeType
    }

    /// Decodes a content part.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            if let attachment = try container.decodeIfPresent(MediaAttachment.self, forKey: .attachment) {
                self = .image(attachment)
                return
            }
            let base64 = try container.decode(String.self, forKey: .data)
            guard let data = Data(base64Encoded: base64) else {
                throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "Invalid base64 image data")
            }
            self = .image(MediaAttachment(mimeType: try container.decode(String.self, forKey: .mimeType), data: data))
        case "attachment":
            self = .attachment(try container.decode(MediaAttachment.self, forKey: .attachment))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content part type \(type)")
        }
    }

    /// Encodes a content part.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .image(let attachment):
            try container.encode("image", forKey: .type)
            try container.encode(attachment, forKey: .attachment)
        case .attachment(let attachment):
            try container.encode("attachment", forKey: .type)
            try container.encode(attachment, forKey: .attachment)
        }
    }
}

/// Content part of an assistant turn.
///
/// Wire shape follows upstream llm-core blocks: `{"type":"text","text":…}`,
/// `{"type":"thinking","thinking":…,"thinkingSignature":…}` and
/// `{"type":"toolCall","id":…,"name":…,"arguments":{…}}`.
public enum ModelAssistantPart: Sendable, Equatable, Codable {
    /// Visible assistant text.
    case text(String)
    /// Provider reasoning text with an optional opaque replay signature.
    case thinking(String, signature: String?)
    /// Proposed tool call. The host or agent loop decides whether and how to execute it.
    case toolCall(ModelToolCall)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case thinkingSignature
    }

    /// Decodes an assistant part.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "thinking":
            self = .thinking(
                try container.decode(String.self, forKey: .thinking),
                signature: try container.decodeIfPresent(String.self, forKey: .thinkingSignature)
            )
        case "toolCall":
            self = .toolCall(try ModelToolCall(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown assistant part type \(type)")
        }
    }

    /// Encodes an assistant part.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .thinking(let value, let signature):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("thinking", forKey: .type)
            try container.encode(value, forKey: .thinking)
            try container.encodeIfPresent(signature, forKey: .thinkingSignature)
        case .toolCall(let call):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("toolCall", forKey: .type)
            try call.encode(to: encoder)
        }
    }
}

/// Result of executing a tool call, fed back to the model on the next turn.
public struct ModelToolResult: Sendable, Equatable, Codable {
    /// Identifier of the assistant tool call this result answers.
    public var toolCallID: String
    /// Name of the tool that ran.
    public var toolName: String
    /// Content returned to the model.
    public var content: [ModelContentPart]
    /// Whether the tool failed. Errors are reported here, never thrown into the transcript.
    public var isError: Bool
    /// Optional structured details for logs and UI; not sent to providers.
    public var details: AnyCodable?

    /// Creates a tool result.
    /// - Parameters:
    ///   - toolCallID: Identifier of the answered tool call.
    ///   - toolName: Tool name.
    ///   - content: Content returned to the model.
    ///   - isError: Whether the tool failed.
    ///   - details: Optional structured details.
    public init(
        toolCallID: String,
        toolName: String,
        content: [ModelContentPart],
        isError: Bool = false,
        details: AnyCodable? = nil
    ) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.content = content
        self.isError = isError
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case toolCallID = "toolCallId"
        case toolName
        case content
        case isError
        case details
    }

    /// Decodes a tool result; `isError` defaults to `false`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.toolCallID = try container.decode(String.self, forKey: .toolCallID)
        self.toolName = try container.decode(String.self, forKey: .toolName)
        self.content = try container.decodeIfPresent([ModelContentPart].self, forKey: .content) ?? []
        self.isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        self.details = try container.decodeIfPresent(AnyCodable.self, forKey: .details)
    }
}

/// One transcript message sent to a model provider.
///
/// Wire shape follows upstream llm-core messages: `{"role":"user","content":[…]}` (string content
/// is accepted when decoding), `{"role":"assistant","content":[…]}`, `{"role":"system","content":[…]}`
/// and `{"role":"toolResult","toolCallId":…,"toolName":…,"content":[…],"isError":…}`.
public enum ModelMessage: Sendable, Equatable, Codable {
    /// Additional system/developer instructions. ``ModelGenerationRequest/systemPrompt`` stays the
    /// primary system prompt.
    case system(content: [ModelContentPart])
    /// User turn.
    case user(content: [ModelContentPart])
    /// Assistant turn, including proposed tool calls.
    case assistant(content: [ModelAssistantPart])
    /// Tool result answering an assistant tool call.
    case toolResult(ModelToolResult)

    /// Creates a text-only system message.
    /// - Parameter text: Instruction text.
    /// - Returns: A system message.
    public static func system(_ text: String) -> ModelMessage {
        .system(content: [.text(text)])
    }

    /// Creates a text-only user message.
    /// - Parameter text: User text.
    /// - Returns: A user message.
    public static func user(_ text: String) -> ModelMessage {
        .user(content: [.text(text)])
    }

    /// Creates a text-only assistant message.
    /// - Parameter text: Assistant text.
    /// - Returns: An assistant message.
    public static func assistant(_ text: String) -> ModelMessage {
        .assistant(content: [.text(text)])
    }

    /// Role of this message.
    public var role: ModelMessageRole {
        switch self {
        case .system:
            return .system
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .toolResult:
            return .tool
        }
    }

    /// Concatenated visible text of this message (assistant thinking and tool calls excluded).
    public var text: String {
        switch self {
        case .system(let content), .user(let content):
            return content.compactMap(\.text).joined()
        case .assistant(let content):
            return content.compactMap { part in
                if case .text(let value) = part { return value }
                return nil
            }.joined()
        case .toolResult(let result):
            return result.content.compactMap(\.text).joined()
        }
    }

    /// Tool calls proposed by an assistant message.
    public var toolCalls: [ModelToolCall] {
        guard case .assistant(let content) = self else { return [] }
        return content.compactMap { part in
            if case .toolCall(let call) = part { return call }
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
    }

    /// Decodes a message.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(String.self, forKey: .role)
        switch role {
        case "system", "developer":
            self = .system(content: try Self.decodeContent(container))
        case "user":
            self = .user(content: try Self.decodeContent(container))
        case "assistant":
            if let text = try? container.decode(String.self, forKey: .content) {
                self = .assistant(content: [.text(text)])
            } else {
                self = .assistant(content: try container.decodeIfPresent([ModelAssistantPart].self, forKey: .content) ?? [])
            }
        case "toolResult", "tool":
            self = .toolResult(try ModelToolResult(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .role, in: container, debugDescription: "Unknown message role \(role)")
        }
    }

    /// Encodes a message.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system(let content):
            try container.encode("system", forKey: .role)
            try container.encode(content, forKey: .content)
        case .user(let content):
            try container.encode("user", forKey: .role)
            try container.encode(content, forKey: .content)
        case .assistant(let content):
            try container.encode("assistant", forKey: .role)
            try container.encode(content, forKey: .content)
        case .toolResult(let result):
            try container.encode("toolResult", forKey: .role)
            try result.encode(to: encoder)
        }
    }

    private static func decodeContent(_ container: KeyedDecodingContainer<CodingKeys>) throws -> [ModelContentPart] {
        if let text = try? container.decode(String.self, forKey: .content) {
            return [.text(text)]
        }
        return try container.decodeIfPresent([ModelContentPart].self, forKey: .content) ?? []
    }
}

// MARK: - Tools

/// Tool declaration sent to a model provider (upstream llm-core `Tool`).
public struct ModelToolDefinition: Codable, Sendable, Equatable {
    /// Model-facing tool name.
    public var name: String
    /// Description shown to the model.
    public var description: String
    /// JSON Schema object describing the tool arguments.
    public var parameters: [String: AnyCodable]
    /// Requests strict schema adherence from providers that support it (`nil` = provider default).
    public var strict: Bool?

    /// Empty-object parameter schema: `{"type":"object","properties":{},"additionalProperties":false}`.
    public static let emptyParametersSchema: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable([String: AnyCodable]()),
        "additionalProperties": AnyCodable(false),
    ]

    /// Creates a tool declaration.
    /// - Parameters:
    ///   - name: Model-facing tool name.
    ///   - description: Description shown to the model.
    ///   - parameters: JSON Schema object for the arguments.
    ///   - strict: Optional strict-schema request.
    public init(
        name: String,
        description: String = "",
        parameters: [String: AnyCodable] = ModelToolDefinition.emptyParametersSchema,
        strict: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case parameters
        case strict
    }

    /// Decodes a tool declaration; missing `description`/`parameters` take their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.parameters = try container.decodeIfPresent([String: AnyCodable].self, forKey: .parameters)
            ?? Self.emptyParametersSchema
        self.strict = try container.decodeIfPresent(Bool.self, forKey: .strict)
    }
}

/// Tool call proposed by a model (upstream llm-core `ToolCall`).
///
/// Providers never execute tool calls; the host or agent loop owns execution and approval.
/// Arguments are kept as the provider-emitted JSON text so partially streamed or repaired payloads
/// survive unchanged; ``arguments`` parses them.
public struct ModelToolCall: Codable, Sendable, Equatable, Hashable {
    /// Provider-assigned call identifier, echoed back in the matching ``ModelToolResult``.
    public var id: String
    /// Tool name.
    public var name: String
    /// Arguments as JSON text; valid calls encode a JSON object.
    public var argumentsJSON: String

    /// Creates a tool call from raw JSON argument text.
    /// - Parameters:
    ///   - id: Call identifier.
    ///   - name: Tool name.
    ///   - argumentsJSON: JSON object text.
    public init(id: String, name: String, argumentsJSON: String = "{}") {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    /// Creates a tool call from structured arguments (encoded as compact, key-sorted JSON).
    /// - Parameters:
    ///   - id: Call identifier.
    ///   - name: Tool name.
    ///   - arguments: Argument object.
    public init(id: String, name: String, arguments: [String: AnyCodable]) {
        self.init(id: id, name: name, argumentsJSON: Self.encodeArguments(arguments))
    }

    /// Parsed arguments, or `nil` when ``argumentsJSON`` is not a JSON object.
    public var arguments: [String: AnyCodable]? {
        let trimmed = self.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        return try? JSONDecoder().decode([String: AnyCodable].self, from: Data(trimmed.utf8))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case arguments
        case argumentsJSON
    }

    /// Decodes a tool call. `arguments` may be a JSON object (upstream shape) or a JSON string
    /// (OpenAI shape); `argumentsJSON` is also accepted.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        if let object = try? container.decode([String: AnyCodable].self, forKey: .arguments) {
            self.argumentsJSON = Self.encodeArguments(object)
        } else if let text = try? container.decode(String.self, forKey: .arguments) {
            self.argumentsJSON = text
        } else {
            self.argumentsJSON = try container.decodeIfPresent(String.self, forKey: .argumentsJSON) ?? "{}"
        }
    }

    /// Encodes `arguments` as a JSON object when ``argumentsJSON`` parses, else as `argumentsJSON` text.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.name, forKey: .name)
        if let arguments = self.arguments {
            try container.encode(arguments, forKey: .arguments)
        } else {
            try container.encode(self.argumentsJSON, forKey: .argumentsJSON)
        }
    }

    static func encodeArguments(_ arguments: [String: AnyCodable]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(arguments) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Incremental tool-call fragment emitted while streaming.
public struct ModelToolCallDelta: Codable, Sendable, Equatable {
    /// Position of the call within the assistant turn; fragments with the same index belong together.
    public var index: Int
    /// Call identifier, usually present on the first fragment only.
    public var id: String?
    /// Tool name, usually present on the first fragment only.
    public var name: String?
    /// Fragment of the JSON argument text.
    public var argumentsDelta: String

    /// Creates a tool-call fragment.
    /// - Parameters:
    ///   - index: Position of the call within the turn.
    ///   - id: Optional call identifier.
    ///   - name: Optional tool name.
    ///   - argumentsDelta: Argument text fragment.
    public init(index: Int, id: String? = nil, name: String? = nil, argumentsDelta: String = "") {
        self.index = index
        self.id = id
        self.name = name
        self.argumentsDelta = argumentsDelta
    }
}

/// How the model may use the declared tools.
///
/// Wire shape: `"auto"`, `"none"`, `"required"` or `{"type":"tool","name":…}`.
public enum ModelToolChoice: Sendable, Equatable, Hashable, Codable {
    /// The model decides whether to call tools (provider default).
    case auto
    /// The model must not call tools.
    case none
    /// The model must call at least one tool.
    case required
    /// The model must call the named tool.
    case named(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case name
    }

    /// Decodes a tool choice.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            switch raw {
            case "auto":
                self = .auto
            case "none":
                self = .none
            case "required", "any":
                self = .required
            default:
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unknown tool choice \(raw)")
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .named(try container.decode(String.self, forKey: .name))
    }

    /// Encodes a tool choice.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .auto:
            var container = encoder.singleValueContainer()
            try container.encode("auto")
        case .none:
            var container = encoder.singleValueContainer()
            try container.encode("none")
        case .required:
            var container = encoder.singleValueContainer()
            try container.encode("required")
        case .named(let name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("tool", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

// MARK: - Response format

/// Requested output format.
///
/// Wire shape: `{"type":"text"}`, `{"type":"json_object"}` or
/// `{"type":"json_schema","name":…,"schema":{…},"strict":…}`.
public enum ModelResponseFormat: Sendable, Equatable, Codable {
    /// Free-form text (default).
    case text
    /// Any valid JSON object.
    case jsonObject
    /// JSON constrained by a schema, for providers that support constrained decoding.
    case jsonSchema(name: String, schema: [String: AnyCodable], strict: Bool)

    /// Schema of a `.jsonSchema` format, else `nil`.
    public var jsonSchema: [String: AnyCodable]? {
        guard case .jsonSchema(_, let schema, _) = self else { return nil }
        return schema
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case schema
        case strict
    }

    /// Decodes a response format.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text
        case "json_object":
            self = .jsonObject
        case "json_schema":
            self = .jsonSchema(
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? "response",
                schema: try container.decode([String: AnyCodable].self, forKey: .schema),
                strict: try container.decodeIfPresent(Bool.self, forKey: .strict) ?? false
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown response format \(type)")
        }
    }

    /// Encodes a response format.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text:
            try container.encode("text", forKey: .type)
        case .jsonObject:
            try container.encode("json_object", forKey: .type)
        case .jsonSchema(let name, let schema, let strict):
            try container.encode("json_schema", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(schema, forKey: .schema)
            try container.encode(strict, forKey: .strict)
        }
    }
}

// MARK: - Usage and stop reason

/// Token accounting for one provider response (upstream llm-core `Usage`).
///
/// As upstream, `inputTokens` excludes cache reads and writes, and `reasoningTokens` is the part of
/// `outputTokens` spent on reasoning (not added to the total).
public struct ModelUsage: Codable, Sendable, Equatable {
    /// Uncached input (prompt) tokens.
    public var inputTokens: Int
    /// Output (completion) tokens, including reasoning tokens.
    public var outputTokens: Int
    /// Input tokens served from the provider prompt cache.
    public var cacheReadTokens: Int
    /// Input tokens written to the provider prompt cache.
    public var cacheWriteTokens: Int
    /// Output tokens spent on reasoning.
    public var reasoningTokens: Int
    /// Total tokens billed for the response.
    public var totalTokens: Int

    /// Usage with every counter at zero.
    public static let zero = ModelUsage()

    /// Creates usage counters. Negative values clamp to zero.
    /// - Parameters:
    ///   - inputTokens: Uncached input tokens.
    ///   - outputTokens: Output tokens.
    ///   - cacheReadTokens: Cache-read input tokens.
    ///   - cacheWriteTokens: Cache-write input tokens.
    ///   - reasoningTokens: Reasoning output tokens.
    ///   - totalTokens: Total tokens; defaults to input + output + cache read + cache write.
    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        reasoningTokens: Int = 0,
        totalTokens: Int? = nil
    ) {
        self.inputTokens = Swift.max(0, inputTokens)
        self.outputTokens = Swift.max(0, outputTokens)
        self.cacheReadTokens = Swift.max(0, cacheReadTokens)
        self.cacheWriteTokens = Swift.max(0, cacheWriteTokens)
        self.reasoningTokens = Swift.max(0, reasoningTokens)
        self.totalTokens = Swift.max(
            0,
            totalTokens ?? (self.inputTokens + self.outputTokens + self.cacheReadTokens + self.cacheWriteTokens)
        )
    }

    /// Alias of ``cacheReadTokens`` (OpenAI "cached input tokens").
    public var cachedInputTokens: Int {
        self.cacheReadTokens
    }

    /// Adds two usage records counter by counter (for multi-turn runs).
    /// - Parameters:
    ///   - lhs: First usage record.
    ///   - rhs: Second usage record.
    /// - Returns: Summed usage.
    public static func + (lhs: ModelUsage, rhs: ModelUsage) -> ModelUsage {
        ModelUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens
        )
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input"
        case outputTokens = "output"
        case cacheReadTokens = "cacheRead"
        case cacheWriteTokens = "cacheWrite"
        case reasoningTokens = "reasoning"
        case totalTokens
    }

    /// Decodes usage with upstream keys; missing counters are zero.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inputTokens: try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
            outputTokens: try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0,
            cacheReadTokens: try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0,
            cacheWriteTokens: try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0,
            reasoningTokens: try container.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0,
            totalTokens: try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        )
    }
}

/// Why a provider stopped generating (upstream llm-core `StopReason`, extended).
///
/// Encodes as its ``rawValue`` string; ``init(providerValue:)`` maps provider-native values such as
/// Anthropic `end_turn`/`max_tokens`/`tool_use` or OpenAI `stop`/`length`/`tool_calls`.
public enum ModelStopReason: Sendable, Equatable, Hashable, Codable {
    /// Natural end of the turn (`stop`, `end_turn`).
    case stop
    /// Output token limit reached (`length`, `max_tokens`).
    case length
    /// The model proposed tool calls and expects results.
    case toolUse
    /// A caller-provided stop sequence matched.
    case stopSequence
    /// Output was blocked by a provider safety filter.
    case contentFilter
    /// The model declined to answer.
    case refusal
    /// The provider reported an error.
    case error
    /// Generation was cancelled.
    case aborted
    /// Any other provider-native reason, preserved verbatim.
    case other(String)

    /// Maps a canonical or provider-native stop reason; unknown values become `.other`.
    /// - Parameter providerValue: Raw stop/finish reason.
    public init(providerValue: String) {
        let collapsed = String(
            String.UnicodeScalarView(
                providerValue.lowercased().unicodeScalars.filter { $0 != "_" && $0 != "-" && $0 != " " }
            )
        )
        switch collapsed {
        case "stop", "endturn", "completed", "complete", "finished":
            self = .stop
        case "length", "maxtokens", "maxoutputtokens":
            self = .length
        case "tooluse", "toolcalls", "toolcall", "functioncall":
            self = .toolUse
        case "stopsequence":
            self = .stopSequence
        case "contentfilter", "safety", "blocklist", "prohibitedcontent", "spii", "recitation":
            self = .contentFilter
        case "refusal":
            self = .refusal
        case "error":
            self = .error
        case "aborted", "abort", "cancelled", "canceled":
            self = .aborted
        default:
            self = .other(providerValue)
        }
    }

    /// Canonical string form (`stop`, `length`, `toolUse`, `stopSequence`, `contentFilter`, `refusal`,
    /// `error`, `aborted`, or the preserved provider value).
    public var rawValue: String {
        switch self {
        case .stop:
            return "stop"
        case .length:
            return "length"
        case .toolUse:
            return "toolUse"
        case .stopSequence:
            return "stopSequence"
        case .contentFilter:
            return "contentFilter"
        case .refusal:
            return "refusal"
        case .error:
            return "error"
        case .aborted:
            return "aborted"
        case .other(let value):
            return value
        }
    }

    /// Decodes a stop reason from its string form.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(providerValue: try container.decode(String.self))
    }

    /// Encodes the canonical string form.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

// MARK: - Capabilities

/// Features a provider implementation declares for contract v2 requests.
///
/// Providers that predate contract v2 report ``legacy`` (everything `false`): they read `prompt`,
/// `systemPrompt` and `attachments` only and never return tool calls. Callers should not send
/// tools to a provider that does not declare ``supportsTools``.
public struct ModelProviderCapabilities: Codable, Sendable, Equatable {
    /// Streams incremental chunks from `generateStream`.
    public var supportsStreaming: Bool
    /// Accepts ``ModelGenerationRequest/tools`` and returns ``ModelGenerationResponse/toolCalls``.
    public var supportsTools: Bool
    /// Can return several tool calls in one turn.
    public var supportsParallelToolCalls: Bool
    /// Honors ``ModelResponseFormat/jsonSchema(name:schema:strict:)``.
    public var supportsJSONSchema: Bool
    /// Accepts image content parts.
    public var supportsImages: Bool
    /// Returns reasoning text or usage.
    public var supportsReasoning: Bool
    /// Maps ``ModelGenerationRequest/messages`` natively instead of flattening them to text.
    public var supportsTranscript: Bool

    /// Capabilities of providers that predate contract v2.
    public static let legacy = ModelProviderCapabilities()

    /// Creates a capability set; every flag defaults to `false`.
    /// - Parameters:
    ///   - supportsStreaming: Streams incremental chunks.
    ///   - supportsTools: Accepts tools and returns tool calls.
    ///   - supportsParallelToolCalls: Returns several tool calls per turn.
    ///   - supportsJSONSchema: Honors JSON-schema response formats.
    ///   - supportsImages: Accepts image input.
    ///   - supportsReasoning: Returns reasoning output.
    ///   - supportsTranscript: Maps transcript messages natively.
    public init(
        supportsStreaming: Bool = false,
        supportsTools: Bool = false,
        supportsParallelToolCalls: Bool = false,
        supportsJSONSchema: Bool = false,
        supportsImages: Bool = false,
        supportsReasoning: Bool = false,
        supportsTranscript: Bool = false
    ) {
        self.supportsStreaming = supportsStreaming
        self.supportsTools = supportsTools
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.supportsJSONSchema = supportsJSONSchema
        self.supportsImages = supportsImages
        self.supportsReasoning = supportsReasoning
        self.supportsTranscript = supportsTranscript
    }
}
