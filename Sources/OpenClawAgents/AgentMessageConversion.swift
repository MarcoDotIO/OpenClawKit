import Foundation
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

/// Conversions between transcript ``AgentMessage`` values and provider-facing ``ModelMessage``
/// values (upstream `convertToLlm`).
public enum AgentMessageConversion {
    /// Prefix wrapped around compaction summaries replayed to the model.
    public static let compactionSummaryPrefix = """
    The conversation history before this point was compacted into the following summary:

    <summary>

    """
    /// Suffix wrapped around compaction summaries replayed to the model.
    public static let compactionSummarySuffix = "\n</summary>"
    /// Prefix wrapped around branch summaries replayed to the model.
    public static let branchSummaryPrefix = """
    The following is a summary of a branch that this conversation came back from:

    <summary>

    """
    /// Suffix wrapped around branch summaries replayed to the model.
    public static let branchSummarySuffix = "</summary>"

    /// Result text inserted for a replayed tool call that has no result (upstream `flushToolCalls`).
    public static let missingToolResultText = "No result provided"
    /// Text that replaces a failed or aborted assistant turn with visible text on replay (upstream
    /// `FAILED_ASSISTANT_REPLAY_TEXT`).
    public static let failedAssistantReplayText =
        "[This turn failed before it completed. Do not redo its work without confirming with the user first.]"

    /// Converts transcript messages to model messages (custom roles become user turns), repairing
    /// tool-call pairing the way upstream `transformMessages` does, so an interrupted or damaged
    /// transcript never makes providers reject the request:
    /// - every assistant tool call is followed by a result: a missing one gets an `isError`
    ///   "No result provided" result before the next non-result message (or at the end);
    /// - tool results that answer no pending call (orphans, duplicates) are dropped;
    /// - assistant turns that ended in `error`/`aborted` are dropped (with tool calls or no visible
    ///   text) or replaced by a short "turn failed" marker.
    /// - Parameter messages: Transcript messages.
    /// - Returns: Model messages.
    public static func modelMessages(from messages: [AgentMessage]) -> [ModelMessage] {
        var result: [ModelMessage] = []
        var pending: [AgentToolCallBlock] = []
        var answered: Set<String> = []
        func flushPendingCalls() {
            for call in pending where !answered.contains(call.id) {
                result.append(.toolResult(ModelToolResult(
                    toolCallID: call.id,
                    toolName: call.name,
                    content: [.text(Self.missingToolResultText)],
                    isError: true
                )))
            }
            pending = []
            answered = []
        }
        for message in messages {
            switch message {
            case .assistant(let assistant):
                flushPendingCalls()
                if assistant.stopReason == .error || assistant.stopReason == .aborted {
                    let hasVisibleText = !assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if assistant.toolCalls.isEmpty, hasVisibleText {
                        result.append(.assistant(content: [.text(Self.failedAssistantReplayText)]))
                    }
                    continue
                }
                guard let converted = Self.modelMessage(from: message) else { continue }
                result.append(converted)
                pending = assistant.toolCalls
            case .toolResult(let toolResult):
                guard pending.contains(where: { $0.id == toolResult.toolCallId }), answered.insert(toolResult.toolCallId).inserted,
                      let converted = Self.modelMessage(from: message)
                else {
                    continue
                }
                result.append(converted)
            default:
                guard let converted = Self.modelMessage(from: message) else { continue }
                flushPendingCalls()
                result.append(converted)
            }
        }
        flushPendingCalls()
        return result
    }

    /// Converts one transcript message.
    /// - Parameter message: Transcript message.
    /// - Returns: The model message, or `nil` for roles that stay out of model context.
    public static func modelMessage(from message: AgentMessage) -> ModelMessage? {
        switch message {
        case .user(let user):
            return .user(content: user.content.blocks.compactMap(Self.contentPart(from:)))
        case .assistant(let assistant):
            return .assistant(content: assistant.content.compactMap(Self.assistantPart(from:)))
        case .toolResult(let result):
            return .toolResult(
                ModelToolResult(
                    toolCallID: result.toolCallId,
                    toolName: result.toolName,
                    content: result.content.compactMap(Self.contentPart(from:)),
                    isError: result.isError,
                    details: result.details
                )
            )
        case .other(let role, let raw):
            if raw["excludeFromContext"]?.boolValue == true {
                return nil
            }
            switch role {
            case "compactionSummary":
                let summary = raw["summary"]?.stringValue ?? ""
                return .user(content: [.text(Self.compactionSummaryPrefix + summary + Self.compactionSummarySuffix)])
            case "branchSummary":
                let summary = raw["summary"]?.stringValue ?? ""
                return .user(content: [.text(Self.branchSummaryPrefix + summary + Self.branchSummarySuffix)])
            case "custom":
                let content = raw["content"].flatMap { try? AgentJSONCoding.decode(AgentMessageContent.self, from: $0) }
                return .user(content: (content?.blocks ?? []).compactMap(Self.contentPart(from:)))
            case "bashExecution":
                return .user(content: [.text(Self.bashExecutionText(raw))])
            default:
                return nil
            }
        }
    }

    /// Converts a model response into a transcript assistant message.
    /// - Parameters:
    ///   - response: Provider response.
    ///   - visibleText: Sanitized visible text to store (defaults to the response text).
    ///   - stopReason: Override stop reason (for example `aborted`).
    ///   - errorMessage: Optional error text.
    ///   - timestamp: Timestamp (ms).
    /// - Returns: The assistant message.
    public static func assistantMessage(
        from response: ModelGenerationResponse,
        visibleText: String? = nil,
        stopReason: AgentStopReason? = nil,
        errorMessage: String? = nil,
        timestamp: Int64
    ) -> AgentAssistantMessage {
        var content: [AgentContentBlock] = []
        // Keep the reasoning signature so Anthropic thinking replays before tool use on the next turn
        // (a signed block with empty text is redacted thinking and must be replayed too).
        let signature = response.reasoningSignature?.isEmpty == false ? response.reasoningSignature : nil
        if let reasoning = response.reasoningText, !reasoning.isEmpty {
            content.append(.thinking(AgentThinkingBlock(thinking: reasoning, thinkingSignature: signature)))
        } else if let signature {
            content.append(.thinking(AgentThinkingBlock(thinking: "", thinkingSignature: signature)))
        }
        let text = visibleText ?? response.text
        if !text.isEmpty {
            content.append(.text(text))
        }
        content.append(contentsOf: response.toolCalls.map { call in
            .toolCall(AgentToolCallBlock(id: call.id, name: call.name, arguments: call.arguments ?? [:]))
        })
        return AgentAssistantMessage(
            content: content,
            provider: response.providerID,
            model: response.modelID ?? "",
            usage: Self.tokenUsage(from: response.usage),
            stopReason: stopReason ?? Self.stopReason(from: response.stopReason),
            errorMessage: errorMessage,
            timestamp: timestamp
        )
    }

    /// Maps provider usage to transcript usage.
    /// - Parameter usage: Provider usage.
    /// - Returns: Transcript usage (zero when `nil`).
    public static func tokenUsage(from usage: ModelUsage?) -> AgentTokenUsage {
        guard let usage else { return .zero }
        return AgentTokenUsage(
            input: usage.inputTokens,
            output: usage.outputTokens,
            cacheRead: usage.cacheReadTokens,
            cacheWrite: usage.cacheWriteTokens,
            totalTokens: usage.totalTokens
        )
    }

    /// Maps a provider stop reason to the upstream five-value vocabulary.
    /// - Parameter reason: Provider stop reason.
    /// - Returns: `stop`, `length`, `toolUse`, `error` or `aborted`.
    public static func stopReason(from reason: ModelStopReason) -> AgentStopReason {
        switch reason {
        case .length:
            return .length
        case .toolUse:
            return .toolUse
        case .error:
            return .error
        case .aborted:
            return .aborted
        case .stop, .stopSequence, .contentFilter, .refusal, .other:
            return .stop
        }
    }

    /// Converts a tool output into a transcript tool-result message.
    /// - Parameters:
    ///   - result: Tool result.
    ///   - timestamp: Timestamp (ms).
    /// - Returns: The tool-result message.
    public static func toolResultMessage(from result: AgentToolResult, timestamp: Int64) -> AgentToolResultMessage {
        AgentToolResultMessage(
            toolCallId: result.toolCallID ?? AgentToolCall.makeID(),
            toolName: result.name,
            content: result.output.content.map(Self.contentBlock(from:)),
            details: result.output.details,
            isError: result.isError,
            timestamp: timestamp
        )
    }

    /// Converts a tool content block into a transcript content block.
    /// - Parameter block: Tool content block.
    /// - Returns: The transcript block.
    public static func contentBlock(from block: AgentToolContentBlock) -> AgentContentBlock {
        switch block {
        case .text(let text):
            return .text(text)
        case .image(let data, let mimeType):
            return .image(data: data, mimeType: mimeType)
        }
    }

    /// Converts a media attachment into an image block (non-images return `nil`).
    /// - Parameter attachment: Attachment.
    /// - Returns: An image block.
    public static func imageBlock(from attachment: MediaAttachment) -> AgentContentBlock? {
        guard attachment.mimeType.lowercased().hasPrefix("image/") else { return nil }
        return .image(data: attachment.data.base64EncodedString(), mimeType: attachment.mimeType)
    }

    private static func contentPart(from block: AgentContentBlock) -> ModelContentPart? {
        switch block {
        case .text(let text, _):
            return .text(text)
        case .image(let data, let mimeType):
            guard let bytes = Data(base64Encoded: data) else { return nil }
            return .image(MediaAttachment(mimeType: mimeType, data: bytes))
        case .thinking, .toolCall, .unknown:
            return nil
        }
    }

    private static func assistantPart(from block: AgentContentBlock) -> ModelAssistantPart? {
        switch block {
        case .text(let text, _):
            return .text(text)
        case .thinking(let thinking):
            return .thinking(thinking.thinking, signature: thinking.thinkingSignature)
        case .toolCall(let call):
            return .toolCall(ModelToolCall(id: call.id, name: call.name, arguments: call.arguments))
        case .image, .unknown:
            return nil
        }
    }

    private static func bashExecutionText(_ raw: [String: AnyCodable]) -> String {
        let command = raw["command"]?.stringValue ?? ""
        let output = raw["output"]?.stringValue ?? ""
        var text = "Ran `\(command)`\n"
        text += output.isEmpty ? "(no output)" : "```\n\(output)\n```"
        if raw["cancelled"]?.boolValue == true {
            text += "\n\n(command cancelled)"
        } else if let code = raw["exitCode"]?.intValue, code != 0 {
            text += "\n\nCommand exited with code \(code)"
        }
        if raw["truncated"]?.boolValue == true, let path = raw["fullOutputPath"]?.stringValue {
            text += "\n\n[Output truncated. Full output: \(path)]"
        }
        return text
    }
}

enum AgentJSONCoding {
    static func decode<T: Decodable>(_ type: T.Type, from value: AnyCodable) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}
