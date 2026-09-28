import Foundation
import OpenClawProtocol

// Session transcript model mirroring upstream OpenClaw 2026.9.6:
// - `packages/llm-core/src/types.ts` (UserMessage/AssistantMessage/ToolResultMessage, content blocks, Usage)
// - `packages/agent-core/src/types.ts` (AgentMessage custom roles: bashExecution, custom,
//   branchSummary, compactionSummary)
// - `src/agents/sessions/session-manager-types.ts` (SessionHeader and SessionEntry union)
// Wire shapes matter because `chat.history` and `tasks.history` return messages as AgentMessage JSON.

// MARK: - Content blocks

/// Provider reasoning block (upstream `ThinkingContent`).
public struct AgentThinkingBlock: Codable, Sendable, Equatable {
    /// Reasoning text.
    public var thinking: String
    /// Opaque replay signature.
    public var thinkingSignature: String?
    /// Whether the reasoning was redacted by a safety filter.
    public var redacted: Bool?

    /// Creates a thinking block.
    /// - Parameters:
    ///   - thinking: Reasoning text.
    ///   - thinkingSignature: Opaque replay signature.
    ///   - redacted: Whether the reasoning was redacted.
    public init(thinking: String, thinkingSignature: String? = nil, redacted: Bool? = nil) {
        self.thinking = thinking
        self.thinkingSignature = thinkingSignature
        self.redacted = redacted
    }
}

/// Assistant tool call block (upstream `ToolCall`).
public struct AgentToolCallBlock: Codable, Sendable, Equatable {
    /// Tool call identifier.
    public var id: String
    /// Tool name.
    public var name: String
    /// Tool arguments.
    public var arguments: [String: AnyCodable]
    /// Google-specific opaque thought signature.
    public var thoughtSignature: String?
    /// Optional execution-mode hint (`sequential` or `parallel`).
    public var executionMode: String?

    /// Creates a tool call block.
    /// - Parameters:
    ///   - id: Tool call identifier.
    ///   - name: Tool name.
    ///   - arguments: Tool arguments.
    ///   - thoughtSignature: Optional thought signature.
    ///   - executionMode: Optional execution-mode hint.
    public init(
        id: String,
        name: String,
        arguments: [String: AnyCodable] = [:],
        thoughtSignature: String? = nil,
        executionMode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
        self.executionMode = executionMode
    }
}

/// Transcript content block: text, image, thinking, or tool call (upstream llm-core blocks).
///
/// Wire shapes: `{"type":"text","text":…}`, `{"type":"image","data":…,"mimeType":…}`,
/// `{"type":"thinking","thinking":…,"thinkingSignature"?,"redacted"?}` and
/// `{"type":"toolCall","id":…,"name":…,"arguments":{…}}`. Unknown block types round-trip through
/// ``unknown(type:raw:)``.
public enum AgentContentBlock: Codable, Sendable, Equatable {
    /// Text content, with an optional provider text signature.
    case text(String, signature: String? = nil)
    /// Base64 image content.
    case image(data: String, mimeType: String)
    /// Provider reasoning.
    case thinking(AgentThinkingBlock)
    /// Assistant tool call.
    case toolCall(AgentToolCallBlock)
    /// Block type this SDK does not model, kept verbatim.
    case unknown(type: String, raw: [String: AnyCodable])

    /// Text of a `.text` block.
    public var text: String? {
        guard case .text(let value, _) = self else { return nil }
        return value
    }

    /// Tool call of a `.toolCall` block.
    public var toolCall: AgentToolCallBlock? {
        guard case .toolCall(let call) = self else { return nil }
        return call
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case textSignature
        case data
        case mimeType
    }

    /// Decodes a content block.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(
                try container.decode(String.self, forKey: .text),
                signature: try container.decodeIfPresent(String.self, forKey: .textSignature)
            )
        case "image":
            self = .image(
                data: try container.decode(String.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType)
            )
        case "thinking":
            self = .thinking(try AgentThinkingBlock(from: decoder))
        case "toolCall":
            self = .toolCall(try AgentToolCallBlock(from: decoder))
        default:
            var raw = try [String: AnyCodable](from: decoder)
            raw["type"] = nil
            self = .unknown(type: type, raw: raw)
        }
    }

    /// Encodes a content block.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let value, let signature):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
            try container.encodeIfPresent(signature, forKey: .textSignature)
        case .image(let data, let mimeType):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case .thinking(let block):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("thinking", forKey: .type)
            try block.encode(to: encoder)
        case .toolCall(let call):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("toolCall", forKey: .type)
            try call.encode(to: encoder)
        case .unknown(let type, let raw):
            var object = raw
            object["type"] = AnyCodable(type)
            try object.encode(to: encoder)
        }
    }
}

/// User/custom message content: a plain string or content blocks (both are valid upstream).
public enum AgentMessageContent: Codable, Sendable, Equatable {
    /// Plain string content.
    case string(String)
    /// Content blocks.
    case blocks([AgentContentBlock])

    /// Content as blocks (a string becomes one text block).
    public var blocks: [AgentContentBlock] {
        switch self {
        case .string(let text):
            return [.text(text)]
        case .blocks(let blocks):
            return blocks
        }
    }

    /// Concatenated text.
    public var text: String {
        switch self {
        case .string(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap(\.text).joined(separator: "\n")
        }
    }

    /// Decodes a string or a block array.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .string(text)
        } else {
            self = .blocks(try container.decode([AgentContentBlock].self))
        }
    }

    /// Encodes the string or block array.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text):
            try container.encode(text)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

// MARK: - Usage and stop reason

/// Cost breakdown of one response (upstream `Usage.cost`).
public struct AgentTokenCost: Codable, Sendable, Equatable {
    /// Input cost.
    public var input: Double
    /// Output cost.
    public var output: Double
    /// Cache-read cost.
    public var cacheRead: Double
    /// Cache-write cost.
    public var cacheWrite: Double
    /// Total cost.
    public var total: Double

    /// Zero cost.
    public static let zero = AgentTokenCost()

    /// Creates a cost breakdown.
    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, total: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.total = total
    }

    /// Decodes a cost breakdown; missing counters are zero.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.input = try container.decodeIfPresent(Double.self, forKey: .input) ?? 0
        self.output = try container.decodeIfPresent(Double.self, forKey: .output) ?? 0
        self.cacheRead = try container.decodeIfPresent(Double.self, forKey: .cacheRead) ?? 0
        self.cacheWrite = try container.decodeIfPresent(Double.self, forKey: .cacheWrite) ?? 0
        self.total = try container.decodeIfPresent(Double.self, forKey: .total) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead
        case cacheWrite
        case total
    }
}

/// Token accounting of one assistant message (upstream `Usage`).
public struct AgentTokenUsage: Codable, Sendable, Equatable {
    /// Uncached input tokens.
    public var input: Int
    /// Output tokens.
    public var output: Int
    /// Cache-read input tokens.
    public var cacheRead: Int
    /// Cache-write input tokens.
    public var cacheWrite: Int
    /// Total tokens.
    public var totalTokens: Int
    /// Cost breakdown.
    public var cost: AgentTokenCost

    /// Zero usage.
    public static let zero = AgentTokenUsage()

    /// Creates usage counters.
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, totalTokens: Int? = nil, cost: AgentTokenCost = .zero) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.totalTokens = totalTokens ?? (input + output + cacheRead + cacheWrite)
        self.cost = cost
    }

    /// Decodes usage; missing counters are zero.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let input = try container.decodeIfPresent(Int.self, forKey: .input) ?? 0
        let output = try container.decodeIfPresent(Int.self, forKey: .output) ?? 0
        let cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        let cacheWrite = try container.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        self.init(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            totalTokens: try container.decodeIfPresent(Int.self, forKey: .totalTokens),
            cost: try container.decodeIfPresent(AgentTokenCost.self, forKey: .cost) ?? .zero
        )
    }

    private enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead
        case cacheWrite
        case totalTokens
        case cost
    }

    /// Adds two usage records counter by counter.
    /// - Parameters:
    ///   - lhs: First usage record.
    ///   - rhs: Second usage record.
    /// - Returns: Summed usage.
    public static func + (lhs: AgentTokenUsage, rhs: AgentTokenUsage) -> AgentTokenUsage {
        AgentTokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            cost: AgentTokenCost(
                input: lhs.cost.input + rhs.cost.input,
                output: lhs.cost.output + rhs.cost.output,
                cacheRead: lhs.cost.cacheRead + rhs.cost.cacheRead,
                cacheWrite: lhs.cost.cacheWrite + rhs.cost.cacheWrite,
                total: lhs.cost.total + rhs.cost.total
            )
        )
    }
}

/// Assistant stop reason (upstream `StopReason`: `stop|length|toolUse|error|aborted`); other values round-trip.
public struct AgentStopReason: RawRepresentable, Codable, Sendable, Equatable, Hashable, ExpressibleByStringLiteral {
    /// Raw value.
    public let rawValue: String

    /// Creates a stop reason.
    /// - Parameter rawValue: Raw value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a stop reason from a literal.
    /// - Parameter value: Raw value.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// Decodes a stop reason string.
    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the stop reason string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    /// Natural end of turn.
    public static let stop: AgentStopReason = "stop"
    /// Output token limit reached.
    public static let length: AgentStopReason = "length"
    /// The model requested tool calls.
    public static let toolUse: AgentStopReason = "toolUse"
    /// Provider or runtime error.
    public static let error: AgentStopReason = "error"
    /// The run was aborted.
    public static let aborted: AgentStopReason = "aborted"
}

// MARK: - Messages

/// User turn (upstream `UserMessage`).
public struct AgentUserMessage: Codable, Sendable, Equatable {
    /// Message content.
    public var content: AgentMessageContent
    /// Timestamp (ms).
    public var timestamp: Int64

    /// Creates a user message.
    /// - Parameters:
    ///   - content: Message content.
    ///   - timestamp: Timestamp (ms).
    public init(content: AgentMessageContent, timestamp: Int64) {
        self.content = content
        self.timestamp = timestamp
    }
}

/// Assistant turn (upstream `AssistantMessage`).
public struct AgentAssistantMessage: Codable, Sendable, Equatable {
    /// Content blocks (text, thinking, tool calls).
    public var content: [AgentContentBlock]
    /// Provider identifier.
    public var provider: String
    /// Model identifier.
    public var model: String
    /// Provider API identifier.
    public var api: String?
    /// Provider response identifier.
    public var responseId: String?
    /// Token usage.
    public var usage: AgentTokenUsage
    /// Stop reason.
    public var stopReason: AgentStopReason
    /// Error message when `stopReason` is `error` or `aborted`.
    public var errorMessage: String?
    /// Timestamp (ms).
    public var timestamp: Int64

    /// Creates an assistant message.
    public init(
        content: [AgentContentBlock],
        provider: String,
        model: String,
        api: String? = nil,
        responseId: String? = nil,
        usage: AgentTokenUsage = .zero,
        stopReason: AgentStopReason = .stop,
        errorMessage: String? = nil,
        timestamp: Int64
    ) {
        self.content = content
        self.provider = provider
        self.model = model
        self.api = api
        self.responseId = responseId
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }

    /// Decodes an assistant message; a string `content` becomes one text block.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .content) {
            self.content = [.text(text)]
        } else {
            self.content = try container.decodeIfPresent([AgentContentBlock].self, forKey: .content) ?? []
        }
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        self.api = try container.decodeIfPresent(String.self, forKey: .api)
        self.responseId = try container.decodeIfPresent(String.self, forKey: .responseId)
        self.usage = try container.decodeIfPresent(AgentTokenUsage.self, forKey: .usage) ?? .zero
        self.stopReason = try container.decodeIfPresent(AgentStopReason.self, forKey: .stopReason) ?? .stop
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        self.timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case content
        case provider
        case model
        case api
        case responseId
        case usage
        case stopReason
        case errorMessage
        case timestamp
    }

    /// Tool calls in order.
    public var toolCalls: [AgentToolCallBlock] {
        self.content.compactMap(\.toolCall)
    }

    /// Visible text (text blocks joined without separators, as providers stream them).
    public var text: String {
        self.content.compactMap(\.text).joined()
    }
}

/// Tool result turn (upstream `ToolResultMessage`).
public struct AgentToolResultMessage: Codable, Sendable, Equatable {
    /// Identifier of the answered tool call.
    public var toolCallId: String
    /// Tool name.
    public var toolName: String
    /// Result content (text and images).
    public var content: [AgentContentBlock]
    /// Structured details for UI and logs.
    public var details: AnyCodable?
    /// Whether the tool failed.
    public var isError: Bool
    /// Timestamp (ms).
    public var timestamp: Int64

    /// Creates a tool result message.
    public init(
        toolCallId: String,
        toolName: String,
        content: [AgentContentBlock],
        details: AnyCodable? = nil,
        isError: Bool = false,
        timestamp: Int64
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.details = details
        self.isError = isError
        self.timestamp = timestamp
    }

    /// Decodes a tool result; string or single-object content is normalized to blocks.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.toolCallId = try container.decode(String.self, forKey: .toolCallId)
        self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName) ?? ""
        if let text = try? container.decode(String.self, forKey: .content) {
            self.content = [.text(text)]
        } else if let block = try? container.decode(AgentContentBlock.self, forKey: .content) {
            self.content = [block]
        } else {
            self.content = try container.decodeIfPresent([AgentContentBlock].self, forKey: .content) ?? []
        }
        self.details = try container.decodeIfPresent(AnyCodable.self, forKey: .details)
        self.isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        self.timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case toolCallId
        case toolName
        case content
        case details
        case isError
        case timestamp
    }

    /// Concatenated text.
    public var text: String {
        self.content.compactMap(\.text).joined(separator: "\n")
    }
}

/// Agent transcript message (upstream `AgentMessage`), discriminated on `role`.
///
/// `user`, `assistant` and `toolResult` are modeled; every other role (`compactionSummary`,
/// `branchSummary`, `custom`, `bashExecution`, and future roles) round-trips losslessly through
/// ``other(role:raw:)``.
public enum AgentMessage: Codable, Sendable, Equatable {
    /// User turn.
    case user(AgentUserMessage)
    /// Assistant turn.
    case assistant(AgentAssistantMessage)
    /// Tool result.
    case toolResult(AgentToolResultMessage)
    /// Any other role, kept verbatim (without the `role` key).
    case other(role: String, raw: [String: AnyCodable])

    /// Message role.
    public var role: String {
        switch self {
        case .user:
            return "user"
        case .assistant:
            return "assistant"
        case .toolResult:
            return "toolResult"
        case .other(let role, _):
            return role
        }
    }

    /// Timestamp (ms), `0` when absent.
    public var timestamp: Int64 {
        switch self {
        case .user(let message):
            return message.timestamp
        case .assistant(let message):
            return message.timestamp
        case .toolResult(let message):
            return message.timestamp
        case .other(_, let raw):
            return raw["timestamp"]?.int64Value ?? 0
        }
    }

    /// Visible text of the message (summaries for summary roles).
    public var text: String {
        switch self {
        case .user(let message):
            return message.content.text
        case .assistant(let message):
            return message.text
        case .toolResult(let message):
            return message.text
        case .other(_, let raw):
            if let summary = raw["summary"]?.stringValue {
                return summary
            }
            if let text = raw["content"]?.stringValue {
                return text
            }
            return raw["content"]?.arrayValue?.compactMap { $0.dictionaryValue?["text"]?.stringValue }.joined(separator: "\n") ?? ""
        }
    }

    /// Creates a user text message.
    /// - Parameters:
    ///   - text: Message text.
    ///   - timestamp: Timestamp (ms).
    /// - Returns: A user message.
    public static func userText(_ text: String, timestamp: Int64) -> AgentMessage {
        .user(AgentUserMessage(content: .string(text), timestamp: timestamp))
    }

    /// Creates a `compactionSummary` message (upstream `createCompactionSummaryMessage`).
    /// - Parameters:
    ///   - summary: Summary text.
    ///   - tokensBefore: Estimated tokens before compaction.
    ///   - timestamp: Timestamp (ms).
    /// - Returns: The summary message.
    public static func compactionSummary(_ summary: String, tokensBefore: Int, timestamp: Int64) -> AgentMessage {
        .other(role: "compactionSummary", raw: [
            "summary": AnyCodable(summary),
            "tokensBefore": AnyCodable(tokensBefore),
            "timestamp": AnyCodable(timestamp),
        ])
    }

    /// Creates a `branchSummary` message (upstream `createBranchSummaryMessage`).
    /// - Parameters:
    ///   - summary: Summary text.
    ///   - fromID: Entry id the branch was summarized from.
    ///   - timestamp: Timestamp (ms).
    /// - Returns: The summary message.
    public static func branchSummary(_ summary: String, fromID: String, timestamp: Int64) -> AgentMessage {
        .other(role: "branchSummary", raw: [
            "summary": AnyCodable(summary),
            "fromId": AnyCodable(fromID),
            "timestamp": AnyCodable(timestamp),
        ])
    }

    /// Creates a `custom` message (upstream `createCustomMessage`).
    /// - Parameters:
    ///   - customType: Application discriminator.
    ///   - content: Content replayed into model context.
    ///   - display: Whether UIs display the message.
    ///   - details: Optional metadata.
    ///   - timestamp: Timestamp (ms).
    /// - Returns: The custom message.
    public static func custom(
        customType: String,
        content: AgentMessageContent,
        display: Bool,
        details: AnyCodable? = nil,
        timestamp: Int64
    ) -> AgentMessage {
        var raw: [String: AnyCodable] = [
            "customType": AnyCodable(customType),
            "display": AnyCodable(display),
            "timestamp": AnyCodable(timestamp),
        ]
        raw["content"] = try? AnyCodable(encoding: content)
        if let details {
            raw["details"] = details
        }
        return .other(role: "custom", raw: raw)
    }

    private enum RoleKey: String, CodingKey {
        case role
    }

    /// Decodes a message by `role`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RoleKey.self)
        let role = try container.decode(String.self, forKey: .role)
        switch role {
        case "user":
            self = .user(try AgentUserMessage(from: decoder))
        case "assistant":
            self = .assistant(try AgentAssistantMessage(from: decoder))
        case "toolResult":
            self = .toolResult(try AgentToolResultMessage(from: decoder))
        default:
            var raw = try [String: AnyCodable](from: decoder)
            raw["role"] = nil
            self = .other(role: role, raw: raw)
        }
    }

    /// Encodes the message with its `role`.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .user(let message):
            var container = encoder.container(keyedBy: RoleKey.self)
            try container.encode("user", forKey: .role)
            try message.encode(to: encoder)
        case .assistant(let message):
            var container = encoder.container(keyedBy: RoleKey.self)
            try container.encode("assistant", forKey: .role)
            try message.encode(to: encoder)
        case .toolResult(let message):
            var container = encoder.container(keyedBy: RoleKey.self)
            try container.encode("toolResult", forKey: .role)
            try message.encode(to: encoder)
        case .other(let role, let raw):
            var object = raw
            object["role"] = AnyCodable(role)
            try object.encode(to: encoder)
        }
    }

    /// Whether the message asks to stay out of model context (`excludeFromContext: true`).
    public var isExcludedFromContext: Bool {
        guard case .other(_, let raw) = self else { return false }
        return raw["excludeFromContext"]?.boolValue == true
    }
}

// MARK: - Session header and entries

/// Transcript file header (upstream `SessionHeader`).
public struct SessionTranscriptHeader: Codable, Sendable, Equatable {
    /// Current transcript format version.
    public static let currentVersion = 3

    /// Always `session`.
    public var type: String
    /// Format version.
    public var version: Int?
    /// Session (transcript) identifier.
    public var id: String
    /// Creation time (ISO-8601).
    public var timestamp: String
    /// Working directory of the session.
    public var cwd: String
    /// Parent transcript session (after a reset or fork).
    public var parentSession: String?

    /// Creates a header.
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - cwd: Working directory.
    ///   - parentSession: Parent transcript session.
    ///   - timestamp: Creation time (ISO-8601); defaults to now.
    public init(id: String, cwd: String, parentSession: String? = nil, timestamp: String = SessionTranscriptClock.isoNow()) {
        self.type = "session"
        self.version = Self.currentVersion
        self.id = id
        self.timestamp = timestamp
        self.cwd = cwd
        self.parentSession = parentSession
    }
}

/// Reason recorded by a transcript `reset` entry (upstream `ResetReason`).
public enum SessionResetReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// `/new`.
    case new
    /// `/reset` or `sessions.reset`.
    case reset
    /// Idle expiry.
    case idle
    /// Daily rollover.
    case daily
    /// Stale cron session.
    case cronStale = "cron-stale"
}

/// Compaction entry payload (upstream `CompactionEntry`).
public struct SessionCompactionData: Codable, Sendable, Equatable {
    /// Summary replacing the compacted history.
    public var summary: String
    /// First entry kept verbatim after the summary.
    public var firstKeptEntryId: String
    /// Estimated context tokens before compaction.
    public var tokensBefore: Int
    /// Estimated context tokens after compaction.
    public var tokensAfter: Int?
    /// Engine-specific details.
    public var details: AnyCodable?
    /// Whether a hook produced the compaction.
    public var fromHook: Bool?

    /// Creates compaction data.
    public init(
        summary: String,
        firstKeptEntryId: String,
        tokensBefore: Int,
        tokensAfter: Int? = nil,
        details: AnyCodable? = nil,
        fromHook: Bool? = nil
    ) {
        self.summary = summary
        self.firstKeptEntryId = firstKeptEntryId
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.details = details
        self.fromHook = fromHook
    }
}

/// One transcript entry (upstream `SessionEntry` union) with common `{type, id, parentId, timestamp}` fields.
public struct SessionTranscriptEntry: Codable, Sendable, Equatable {
    /// Entry payload by type.
    public enum Payload: Sendable, Equatable {
        /// `message`.
        case message(AgentMessage)
        /// `thinking_level_change`.
        case thinkingLevelChange(String)
        /// `model_change`.
        case modelChange(provider: String, modelID: String)
        /// `compaction`.
        case compaction(SessionCompactionData)
        /// `reset`.
        case reset(reason: SessionResetReason, firstKeptEntryID: String?)
        /// `branch_summary`.
        case branchSummary(fromID: String, summary: String, details: AnyCodable?)
        /// `custom` (persisted, excluded from model context).
        case custom(customType: String, data: AnyCodable?)
        /// `label`.
        case label(targetID: String, label: String?)
        /// `session_info`.
        case sessionInfo(name: String?)
        /// `custom_message` (participates in model context).
        case customMessage(customType: String, content: AgentMessageContent, display: Bool, details: AnyCodable?)
        /// Unknown entry type, kept verbatim (without the common fields).
        case unknown(type: String, raw: [String: AnyCodable])
    }

    /// Entry identifier.
    public var id: String
    /// Parent entry identifier (`nil` for the first entry).
    public var parentID: String?
    /// Entry time (ISO-8601).
    public var timestamp: String
    /// Entry payload.
    public var payload: Payload

    /// Creates an entry.
    /// - Parameters:
    ///   - id: Entry identifier; defaults to a random 8-byte hex id.
    ///   - parentID: Parent entry identifier (stores link appended entries to the current leaf).
    ///   - timestamp: Entry time (ISO-8601); defaults to now.
    ///   - payload: Entry payload.
    public init(
        id: String = SessionTranscriptEntry.makeID(),
        parentID: String? = nil,
        timestamp: String = SessionTranscriptClock.isoNow(),
        payload: Payload
    ) {
        self.id = id
        self.parentID = parentID
        self.timestamp = timestamp
        self.payload = payload
    }

    /// Creates a `message` entry.
    /// - Parameter message: Message.
    /// - Returns: The entry.
    public static func message(_ message: AgentMessage) -> SessionTranscriptEntry {
        SessionTranscriptEntry(payload: .message(message))
    }

    /// Wire `type` of the entry.
    public var type: String {
        switch self.payload {
        case .message:
            return "message"
        case .thinkingLevelChange:
            return "thinking_level_change"
        case .modelChange:
            return "model_change"
        case .compaction:
            return "compaction"
        case .reset:
            return "reset"
        case .branchSummary:
            return "branch_summary"
        case .custom:
            return "custom"
        case .label:
            return "label"
        case .sessionInfo:
            return "session_info"
        case .customMessage:
            return "custom_message"
        case .unknown(let type, _):
            return type
        }
    }

    /// Message carried by a `message` entry.
    public var message: AgentMessage? {
        guard case .message(let message) = self.payload else { return nil }
        return message
    }

    /// Entry time in milliseconds (`0` when the timestamp does not parse).
    public var timestampMs: Int64 {
        SessionTranscriptClock.milliseconds(fromISO: self.timestamp) ?? 0
    }

    /// Random 8-byte hex entry identifier (upstream `generateSessionEntryId`).
    /// - Returns: A 16-character lowercase hex id.
    public static func makeID() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case parentID = "parentId"
        case timestamp
        case message
        case thinkingLevel
        case provider
        case modelID = "modelId"
        case reason
        case firstKeptEntryID = "firstKeptEntryId"
        case fromID = "fromId"
        case summary
        case details
        case customType
        case data
        case targetID = "targetId"
        case label
        case name
        case content
        case display
    }

    private static let commonKeys: Set<String> = ["type", "id", "parentId", "timestamp"]

    /// Decodes an entry by `type`; unknown types are kept verbatim.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        self.id = try container.decode(String.self, forKey: .id)
        self.parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        switch type {
        case "message":
            self.payload = .message(try container.decode(AgentMessage.self, forKey: .message))
        case "thinking_level_change":
            self.payload = .thinkingLevelChange(try container.decode(String.self, forKey: .thinkingLevel))
        case "model_change":
            self.payload = .modelChange(
                provider: try container.decode(String.self, forKey: .provider),
                modelID: try container.decode(String.self, forKey: .modelID)
            )
        case "compaction":
            self.payload = .compaction(try SessionCompactionData(from: decoder))
        case "reset":
            let reason = SessionResetReason(rawValue: try container.decode(String.self, forKey: .reason)) ?? .reset
            self.payload = .reset(reason: reason, firstKeptEntryID: try container.decodeIfPresent(String.self, forKey: .firstKeptEntryID))
        case "branch_summary":
            self.payload = .branchSummary(
                fromID: try container.decode(String.self, forKey: .fromID),
                summary: try container.decode(String.self, forKey: .summary),
                details: try container.decodeIfPresent(AnyCodable.self, forKey: .details)
            )
        case "custom":
            self.payload = .custom(
                customType: try container.decode(String.self, forKey: .customType),
                data: try container.decodeIfPresent(AnyCodable.self, forKey: .data)
            )
        case "label":
            self.payload = .label(
                targetID: try container.decode(String.self, forKey: .targetID),
                label: try container.decodeIfPresent(String.self, forKey: .label)
            )
        case "session_info":
            self.payload = .sessionInfo(name: try container.decodeIfPresent(String.self, forKey: .name))
        case "custom_message":
            self.payload = .customMessage(
                customType: try container.decode(String.self, forKey: .customType),
                content: try container.decode(AgentMessageContent.self, forKey: .content),
                display: try container.decodeIfPresent(Bool.self, forKey: .display) ?? true,
                details: try container.decodeIfPresent(AnyCodable.self, forKey: .details)
            )
        default:
            let raw = try [String: AnyCodable](from: decoder).filter { !Self.commonKeys.contains($0.key) }
            self.payload = .unknown(type: type, raw: raw)
        }
    }

    /// Encodes the entry with its common fields.
    public func encode(to encoder: Encoder) throws {
        if case .unknown(let type, let raw) = self.payload {
            var object = raw
            object["type"] = AnyCodable(type)
            object["id"] = AnyCodable(self.id)
            object["parentId"] = AnyCodable(self.parentID)
            object["timestamp"] = AnyCodable(self.timestamp)
            try object.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.type, forKey: .type)
        try container.encode(self.id, forKey: .id)
        // Upstream writes `parentId: null` for root entries.
        try container.encode(self.parentID, forKey: .parentID)
        try container.encode(self.timestamp, forKey: .timestamp)
        switch self.payload {
        case .message(let message):
            try container.encode(message, forKey: .message)
        case .thinkingLevelChange(let level):
            try container.encode(level, forKey: .thinkingLevel)
        case .modelChange(let provider, let modelID):
            try container.encode(provider, forKey: .provider)
            try container.encode(modelID, forKey: .modelID)
        case .compaction(let data):
            try data.encode(to: encoder)
        case .reset(let reason, let firstKept):
            try container.encode(reason.rawValue, forKey: .reason)
            try container.encodeIfPresent(firstKept, forKey: .firstKeptEntryID)
        case .branchSummary(let fromID, let summary, let details):
            try container.encode(fromID, forKey: .fromID)
            try container.encode(summary, forKey: .summary)
            try container.encodeIfPresent(details, forKey: .details)
        case .custom(let customType, let data):
            try container.encode(customType, forKey: .customType)
            try container.encodeIfPresent(data, forKey: .data)
        case .label(let targetID, let label):
            try container.encode(targetID, forKey: .targetID)
            try container.encodeIfPresent(label, forKey: .label)
        case .sessionInfo(let name):
            try container.encodeIfPresent(name, forKey: .name)
        case .customMessage(let customType, let content, let display, let details):
            try container.encode(customType, forKey: .customType)
            try container.encode(content, forKey: .content)
            try container.encode(display, forKey: .display)
            try container.encodeIfPresent(details, forKey: .details)
        case .unknown:
            break
        }
    }
}

/// Branch summary returned by ``SessionTranscriptStore/branches(sessionID:)``.
public struct SessionTranscriptBranch: Codable, Sendable, Equatable {
    /// Leaf entry of the branch.
    public var leafEntryId: String
    /// First user-message text on the branch tip side (≤ 80 characters).
    public var headline: String
    /// Messages on the branch path.
    public var messageCount: Int
    /// Leaf entry time (ms).
    public var updatedAt: Int64
    /// Whether the branch is the active path.
    public var active: Bool

    /// Creates a branch summary.
    public init(leafEntryId: String, headline: String, messageCount: Int, updatedAt: Int64, active: Bool) {
        self.leafEntryId = leafEntryId
        self.headline = headline
        self.messageCount = messageCount
        self.updatedAt = updatedAt
        self.active = active
    }
}

/// Time helpers for transcript timestamps (ISO-8601 strings with milliseconds, UTC).
public enum SessionTranscriptClock {
    /// Current time as ISO-8601 (`2026-09-28T12:00:00.000Z`).
    /// - Returns: The timestamp.
    public static func isoNow() -> String {
        Self.iso(fromMilliseconds: Int64((Date().timeIntervalSince1970 * 1000).rounded()))
    }

    /// Current time in epoch milliseconds.
    /// - Returns: Milliseconds since the epoch.
    public static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    /// Formats epoch milliseconds as ISO-8601 with milliseconds.
    /// - Parameter milliseconds: Epoch milliseconds.
    /// - Returns: The timestamp.
    public static func iso(fromMilliseconds milliseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    /// Parses an ISO-8601 timestamp (with or without fractional seconds) to epoch milliseconds.
    /// - Parameter iso: Timestamp string.
    /// - Returns: Milliseconds, or `nil` when unparseable.
    public static func milliseconds(fromISO iso: String) -> Int64? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: iso) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        return nil
    }
}
