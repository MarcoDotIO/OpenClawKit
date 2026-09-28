import Foundation
import OpenClawProtocol

// Typed hook payloads (upstream `src/plugins/hook-types.ts`, OpenClaw 2026.9.6). Every struct is
// Codable with upstream camelCase keys so it round-trips through ``HookContext/event`` and
// ``HookResult/payload``. Message and transcript values stay `AnyCodable` because their concrete
// types live in higher modules.

// MARK: - Tool hooks

/// `before_tool_call` event.
public struct BeforeToolCallEvent: Codable, Sendable, Equatable {
    /// Tool name.
    public var toolName: String
    /// Tool arguments.
    public var params: [String: AnyCodable]
    /// Host discriminator for tools that share names (for example `code_mode_exec`).
    public var toolKind: String?
    /// Host input family (for example `javascript`).
    public var toolInputKind: String?
    /// Agent run identifier.
    public var runId: String?
    /// Tool call identifier.
    public var toolCallId: String?
    /// Best-effort destination paths derived from `params`.
    public var derivedPaths: [String]?

    /// Creates a `before_tool_call` event.
    /// - Parameters:
    ///   - toolName: Tool name.
    ///   - params: Tool arguments.
    ///   - toolKind: Tool discriminator.
    ///   - toolInputKind: Input family.
    ///   - runId: Run identifier.
    ///   - toolCallId: Tool call identifier.
    ///   - derivedPaths: Derived destination paths.
    public init(
        toolName: String,
        params: [String: AnyCodable] = [:],
        toolKind: String? = nil,
        toolInputKind: String? = nil,
        runId: String? = nil,
        toolCallId: String? = nil,
        derivedPaths: [String]? = nil
    ) {
        self.toolName = toolName
        self.params = params
        self.toolKind = toolKind
        self.toolInputKind = toolInputKind
        self.runId = runId
        self.toolCallId = toolCallId
        self.derivedPaths = derivedPaths
    }
}

/// Severity of a hook approval request.
public enum HookApprovalSeverity: String, Codable, Sendable, Equatable {
    /// Informational.
    case info
    /// Warning.
    case warning
    /// Critical.
    case critical
}

/// Decision an operator may make on a hook approval request.
public enum HookApprovalDecision: String, Codable, Sendable, Equatable {
    /// Allow this call once.
    case allowOnce = "allow-once"
    /// Allow this call and similar calls from now on.
    case allowAlways = "allow-always"
    /// Deny the call.
    case deny
}

/// Approval requested by a `before_tool_call` handler.
public struct HookApprovalRequest: Codable, Sendable, Equatable {
    /// Approval title.
    public var title: String
    /// Approval description.
    public var description: String
    /// Severity.
    public var severity: HookApprovalSeverity?
    /// Approval timeout in milliseconds (unresolved approvals deny).
    public var timeoutMs: Int?
    /// Text returned as the blocked tool result when the approval times out.
    public var timeoutReason: String?
    /// Decisions offered to the operator.
    public var allowedDecisions: [HookApprovalDecision]?
    /// Plugin that requested the approval (filled in by the registry when known).
    public var pluginId: String?

    /// Creates an approval request.
    /// - Parameters:
    ///   - title: Title.
    ///   - description: Description.
    ///   - severity: Severity.
    ///   - timeoutMs: Timeout in milliseconds.
    ///   - timeoutReason: Timeout text.
    ///   - allowedDecisions: Offered decisions.
    ///   - pluginId: Requesting plugin.
    public init(
        title: String,
        description: String,
        severity: HookApprovalSeverity? = nil,
        timeoutMs: Int? = nil,
        timeoutReason: String? = nil,
        allowedDecisions: [HookApprovalDecision]? = nil,
        pluginId: String? = nil
    ) {
        self.title = title
        self.description = description
        self.severity = severity
        self.timeoutMs = timeoutMs
        self.timeoutReason = timeoutReason
        self.allowedDecisions = allowedDecisions
        self.pluginId = pluginId
    }
}

/// `before_tool_call` result.
public struct BeforeToolCallDecision: Codable, Sendable, Equatable {
    /// Replacement tool arguments.
    public var params: [String: AnyCodable]?
    /// Blocks the call (terminal); `false` is a no-op.
    public var block: Bool?
    /// Reason shown when the call is blocked.
    public var blockReason: String?
    /// Requests an owner approval before the call runs.
    public var requireApproval: HookApprovalRequest?

    /// Creates a `before_tool_call` result.
    /// - Parameters:
    ///   - params: Replacement arguments.
    ///   - block: Block flag.
    ///   - blockReason: Block reason.
    ///   - requireApproval: Approval request.
    public init(
        params: [String: AnyCodable]? = nil,
        block: Bool? = nil,
        blockReason: String? = nil,
        requireApproval: HookApprovalRequest? = nil
    ) {
        self.params = params
        self.block = block
        self.blockReason = blockReason
        self.requireApproval = requireApproval
    }
}

/// `after_tool_call` event (observe-only).
public struct AfterToolCallEvent: Codable, Sendable, Equatable {
    /// Tool name.
    public var toolName: String
    /// Tool arguments.
    public var params: [String: AnyCodable]
    /// Agent run identifier.
    public var runId: String?
    /// Tool call identifier.
    public var toolCallId: String?
    /// Tool result value.
    public var result: AnyCodable?
    /// Error description when the call failed.
    public var error: String?
    /// Duration in milliseconds.
    public var durationMs: Int?

    /// Creates an `after_tool_call` event.
    /// - Parameters:
    ///   - toolName: Tool name.
    ///   - params: Arguments.
    ///   - runId: Run identifier.
    ///   - toolCallId: Tool call identifier.
    ///   - result: Result value.
    ///   - error: Error description.
    ///   - durationMs: Duration in milliseconds.
    public init(
        toolName: String,
        params: [String: AnyCodable] = [:],
        runId: String? = nil,
        toolCallId: String? = nil,
        result: AnyCodable? = nil,
        error: String? = nil,
        durationMs: Int? = nil
    ) {
        self.toolName = toolName
        self.params = params
        self.runId = runId
        self.toolCallId = toolCallId
        self.result = result
        self.error = error
        self.durationMs = durationMs
    }
}

/// `tool_result_persist` event.
public struct ToolResultPersistEvent: Codable, Sendable, Equatable {
    /// Tool name.
    public var toolName: String?
    /// Tool call identifier.
    public var toolCallId: String?
    /// Tool result message about to be persisted.
    public var message: AnyCodable
    /// Whether the result was synthesized by the runtime.
    public var isSynthetic: Bool?

    /// Creates a `tool_result_persist` event.
    /// - Parameters:
    ///   - toolName: Tool name.
    ///   - toolCallId: Tool call identifier.
    ///   - message: Message.
    ///   - isSynthetic: Synthetic flag.
    public init(toolName: String? = nil, toolCallId: String? = nil, message: AnyCodable, isSynthetic: Bool? = nil) {
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.message = message
        self.isSynthetic = isSynthetic
    }
}

/// `tool_result_persist` result.
public struct ToolResultPersistResult: Codable, Sendable, Equatable {
    /// Replacement message.
    public var message: AnyCodable?

    /// Creates a `tool_result_persist` result.
    /// - Parameter message: Replacement message.
    public init(message: AnyCodable? = nil) {
        self.message = message
    }
}

/// `before_message_write` event.
public struct BeforeMessageWriteEvent: Codable, Sendable, Equatable {
    /// Message about to be written.
    public var message: AnyCodable
    /// Session key.
    public var sessionKey: String?
    /// Agent identifier.
    public var agentId: String?

    /// Creates a `before_message_write` event.
    /// - Parameters:
    ///   - message: Message.
    ///   - sessionKey: Session key.
    ///   - agentId: Agent identifier.
    public init(message: AnyCodable, sessionKey: String? = nil, agentId: String? = nil) {
        self.message = message
        self.sessionKey = sessionKey
        self.agentId = agentId
    }
}

/// `before_message_write` result.
public struct BeforeMessageWriteResult: Codable, Sendable, Equatable {
    /// Blocks the write (terminal).
    public var block: Bool?
    /// Replacement message.
    public var message: AnyCodable?

    /// Creates a `before_message_write` result.
    /// - Parameters:
    ///   - block: Block flag.
    ///   - message: Replacement message.
    public init(block: Bool? = nil, message: AnyCodable? = nil) {
        self.block = block
        self.message = message
    }
}

// MARK: - Agent lifecycle hooks

/// `before_agent_run` event (fail-closed gate).
public struct BeforeAgentRunEvent: Codable, Sendable, Equatable {
    /// User message that triggered the run.
    public var prompt: String
    /// Session history loaded before the prompt is submitted.
    public var messages: [AnyCodable]
    /// Active system prompt.
    public var systemPrompt: String?
    /// Account identity.
    public var accountId: String?
    /// Channel the message came from.
    public var channelId: String?
    /// Sender identity.
    public var senderId: String?
    /// Trusted sender-is-owner bit.
    public var senderIsOwner: Bool?

    /// Creates a `before_agent_run` event.
    /// - Parameters:
    ///   - prompt: Prompt.
    ///   - messages: History.
    ///   - systemPrompt: System prompt.
    ///   - accountId: Account identity.
    ///   - channelId: Channel identity.
    ///   - senderId: Sender identity.
    ///   - senderIsOwner: Owner bit.
    public init(
        prompt: String,
        messages: [AnyCodable] = [],
        systemPrompt: String? = nil,
        accountId: String? = nil,
        channelId: String? = nil,
        senderId: String? = nil,
        senderIsOwner: Bool? = nil
    ) {
        self.prompt = prompt
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.accountId = accountId
        self.channelId = channelId
        self.senderId = senderId
        self.senderIsOwner = senderIsOwner
    }
}

/// Pass/block decision returned by gate hooks (`{"outcome":"pass"}` / `{"outcome":"block",…}`).
public enum InputGateDecision: Codable, Sendable, Equatable {
    /// Proceed normally.
    case pass
    /// Stop the request. `reason` is plugin-internal (never shown); `message` is user-facing.
    case block(reason: String, message: String? = nil, category: String? = nil, metadata: [String: AnyCodable]? = nil)

    /// Whether the decision blocks.
    public var isBlock: Bool {
        if case .block = self { return true }
        return false
    }

    /// Upstream user-facing replacement text for a block (`Your message could not be sent: …`).
    /// - Parameter blockedBy: Optional plugin name to attribute.
    /// - Returns: The text, or `nil` for `.pass`.
    public func blockMessage(blockedBy: String? = nil) -> String? {
        guard case .block(_, let message, _, _) = self else { return nil }
        let prefix = "Your message could not be sent"
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let attribution = blockedBy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return attribution.isEmpty ? "\(prefix): \(trimmed)" : "\(prefix): \(trimmed) (blocked by \(attribution))"
        }
        return attribution.isEmpty ? "\(prefix): blocked" : "\(prefix): blocked by \(attribution)"
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case reason
        case message
        case category
        case metadata
    }

    /// Decodes a gate decision; anything but `pass`/`block` decodes as a block (fail closed).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
        if outcome == "pass" {
            self = .pass
            return
        }
        self = .block(
            reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "invalid gate decision",
            message: try container.decodeIfPresent(String.self, forKey: .message),
            category: try container.decodeIfPresent(String.self, forKey: .category),
            metadata: try container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
        )
    }

    /// Encodes a gate decision.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pass:
            try container.encode("pass", forKey: .outcome)
        case .block(let reason, let message, let category, let metadata):
            try container.encode("block", forKey: .outcome)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(message, forKey: .message)
            try container.encodeIfPresent(category, forKey: .category)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }
    }
}

/// Attachment metadata for `before_model_resolve`.
public struct BeforeModelResolveAttachment: Codable, Sendable, Equatable {
    /// `image`, `video`, `audio`, `document` or `other`.
    public var kind: String
    /// MIME type.
    public var mimeType: String?

    /// Creates attachment metadata.
    /// - Parameters:
    ///   - kind: Attachment kind.
    ///   - mimeType: MIME type.
    public init(kind: String, mimeType: String? = nil) {
        self.kind = kind
        self.mimeType = mimeType
    }
}

/// `before_model_resolve` event.
public struct BeforeModelResolveEvent: Codable, Sendable, Equatable {
    /// User prompt.
    public var prompt: String
    /// Attachment metadata.
    public var attachments: [BeforeModelResolveAttachment]?

    /// Creates a `before_model_resolve` event.
    /// - Parameters:
    ///   - prompt: Prompt.
    ///   - attachments: Attachments.
    public init(prompt: String, attachments: [BeforeModelResolveAttachment]? = nil) {
        self.prompt = prompt
        self.attachments = attachments
    }
}

/// `before_model_resolve` result.
public struct BeforeModelResolveResult: Codable, Sendable, Equatable {
    /// Model override.
    public var modelOverride: String?
    /// Provider override.
    public var providerOverride: String?

    /// Creates a `before_model_resolve` result.
    /// - Parameters:
    ///   - modelOverride: Model override.
    ///   - providerOverride: Provider override.
    public init(modelOverride: String? = nil, providerOverride: String? = nil) {
        self.modelOverride = modelOverride
        self.providerOverride = providerOverride
    }
}

/// `before_prompt_build` event.
public struct BeforePromptBuildEvent: Codable, Sendable, Equatable {
    /// Prompt.
    public var prompt: String
    /// Current request before projection.
    public var currentUserMessage: String?
    /// Session messages prepared for the run.
    public var messages: [AnyCodable]

    /// Creates a `before_prompt_build` event.
    /// - Parameters:
    ///   - prompt: Prompt.
    ///   - currentUserMessage: Current request.
    ///   - messages: Messages.
    public init(prompt: String, currentUserMessage: String? = nil, messages: [AnyCodable] = []) {
        self.prompt = prompt
        self.currentUserMessage = currentUserMessage
        self.messages = messages
    }
}

/// `before_prompt_build` result.
public struct BeforePromptBuildResult: Codable, Sendable, Equatable {
    /// Replacement system prompt (the highest-priority definition wins).
    public var systemPrompt: String?
    /// Context prepended to the user prompt.
    public var prependContext: String?
    /// Context appended to the user prompt.
    public var appendContext: String?
    /// Context prepended to the system prompt (cache friendly).
    public var prependSystemContext: String?
    /// Context appended to the system prompt.
    public var appendSystemContext: String?
    /// Narrows the tools offered for this turn (empty disables optional tools).
    public var toolsAllow: [String]?

    /// Creates a `before_prompt_build` result.
    /// - Parameters:
    ///   - systemPrompt: System prompt.
    ///   - prependContext: Prepended context.
    ///   - appendContext: Appended context.
    ///   - prependSystemContext: Prepended system context.
    ///   - appendSystemContext: Appended system context.
    ///   - toolsAllow: Tool allowlist.
    public init(
        systemPrompt: String? = nil,
        prependContext: String? = nil,
        appendContext: String? = nil,
        prependSystemContext: String? = nil,
        appendSystemContext: String? = nil,
        toolsAllow: [String]? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.prependContext = prependContext
        self.appendContext = appendContext
        self.prependSystemContext = prependSystemContext
        self.appendSystemContext = appendSystemContext
        self.toolsAllow = toolsAllow
    }
}

/// `before_agent_reply` event.
public struct BeforeAgentReplyEvent: Codable, Sendable, Equatable {
    /// Cleaned inbound body.
    public var cleanedBody: String

    /// Creates a `before_agent_reply` event.
    /// - Parameter cleanedBody: Cleaned body.
    public init(cleanedBody: String) {
        self.cleanedBody = cleanedBody
    }
}

/// `before_agent_reply` result (claiming).
public struct BeforeAgentReplyResult: Codable, Sendable, Equatable {
    /// Whether the handler claimed the reply.
    public var handled: Bool
    /// Reply payload (upstream `ReplyPayload`) when claimed.
    public var reply: AnyCodable?
    /// Reason for diagnostics.
    public var reason: String?

    /// Creates a `before_agent_reply` result.
    /// - Parameters:
    ///   - handled: Claimed flag.
    ///   - reply: Reply payload.
    ///   - reason: Reason.
    public init(handled: Bool, reply: AnyCodable? = nil, reason: String? = nil) {
        self.handled = handled
        self.reply = reply
        self.reason = reason
    }
}

/// `llm_input` event (observe-only).
public struct LLMInputHookEvent: Codable, Sendable, Equatable {
    /// Run identifier.
    public var runId: String
    /// Session identifier.
    public var sessionId: String
    /// Provider identifier.
    public var provider: String
    /// Model identifier.
    public var model: String
    /// System prompt.
    public var systemPrompt: String?
    /// Prompt.
    public var prompt: String
    /// History messages.
    public var historyMessages: [AnyCodable]
    /// Number of images.
    public var imagesCount: Int
    /// Tool declarations.
    public var tools: [AnyCodable]?

    /// Creates an `llm_input` event.
    /// - Parameters:
    ///   - runId: Run identifier.
    ///   - sessionId: Session identifier.
    ///   - provider: Provider.
    ///   - model: Model.
    ///   - systemPrompt: System prompt.
    ///   - prompt: Prompt.
    ///   - historyMessages: History.
    ///   - imagesCount: Image count.
    ///   - tools: Tool declarations.
    public init(
        runId: String,
        sessionId: String,
        provider: String,
        model: String,
        systemPrompt: String? = nil,
        prompt: String,
        historyMessages: [AnyCodable] = [],
        imagesCount: Int = 0,
        tools: [AnyCodable]? = nil
    ) {
        self.runId = runId
        self.sessionId = sessionId
        self.provider = provider
        self.model = model
        self.systemPrompt = systemPrompt
        self.prompt = prompt
        self.historyMessages = historyMessages
        self.imagesCount = imagesCount
        self.tools = tools
    }
}

/// `llm_output` event (observe-only).
public struct LLMOutputHookEvent: Codable, Sendable, Equatable {
    /// Run identifier.
    public var runId: String
    /// Session identifier.
    public var sessionId: String
    /// Provider identifier.
    public var provider: String
    /// Model identifier.
    public var model: String
    /// Assistant texts produced by the call.
    public var assistantTexts: [String]
    /// Token usage (`input`, `output`, `cacheRead`, `cacheWrite`, `total`).
    public var usage: [String: Int]?
    /// Requested reasoning effort.
    public var reasoningEffort: String?

    /// Creates an `llm_output` event.
    /// - Parameters:
    ///   - runId: Run identifier.
    ///   - sessionId: Session identifier.
    ///   - provider: Provider.
    ///   - model: Model.
    ///   - assistantTexts: Assistant texts.
    ///   - usage: Usage.
    ///   - reasoningEffort: Reasoning effort.
    public init(
        runId: String,
        sessionId: String,
        provider: String,
        model: String,
        assistantTexts: [String] = [],
        usage: [String: Int]? = nil,
        reasoningEffort: String? = nil
    ) {
        self.runId = runId
        self.sessionId = sessionId
        self.provider = provider
        self.model = model
        self.assistantTexts = assistantTexts
        self.usage = usage
        self.reasoningEffort = reasoningEffort
    }
}

/// `model_call_started` / `model_call_ended` event.
public struct ModelCallHookEvent: Codable, Sendable, Equatable {
    /// Run identifier.
    public var runId: String
    /// Call identifier.
    public var callId: String
    /// Session key.
    public var sessionKey: String?
    /// Provider identifier.
    public var provider: String
    /// Model identifier.
    public var model: String
    /// Duration in milliseconds (`model_call_ended`).
    public var durationMs: Int?
    /// `completed` or `error` (`model_call_ended`).
    public var outcome: String?
    /// Error category (`model_call_ended`).
    public var errorCategory: String?

    /// Creates a model call event.
    /// - Parameters:
    ///   - runId: Run identifier.
    ///   - callId: Call identifier.
    ///   - sessionKey: Session key.
    ///   - provider: Provider.
    ///   - model: Model.
    ///   - durationMs: Duration.
    ///   - outcome: Outcome.
    ///   - errorCategory: Error category.
    public init(
        runId: String,
        callId: String,
        sessionKey: String? = nil,
        provider: String,
        model: String,
        durationMs: Int? = nil,
        outcome: String? = nil,
        errorCategory: String? = nil
    ) {
        self.runId = runId
        self.callId = callId
        self.sessionKey = sessionKey
        self.provider = provider
        self.model = model
        self.durationMs = durationMs
        self.outcome = outcome
        self.errorCategory = errorCategory
    }
}

/// `agent_end` event (observe-only).
public struct AgentEndHookEvent: Codable, Sendable, Equatable {
    /// Run identifier.
    public var runId: String?
    /// Final transcript messages.
    public var messages: [AnyCodable]
    /// Whether the run succeeded.
    public var success: Bool
    /// Error description.
    public var error: String?
    /// Duration in milliseconds.
    public var durationMs: Int?

    /// Creates an `agent_end` event.
    /// - Parameters:
    ///   - runId: Run identifier.
    ///   - messages: Messages.
    ///   - success: Success flag.
    ///   - error: Error.
    ///   - durationMs: Duration.
    public init(runId: String? = nil, messages: [AnyCodable] = [], success: Bool, error: String? = nil, durationMs: Int? = nil) {
        self.runId = runId
        self.messages = messages
        self.success = success
        self.error = error
        self.durationMs = durationMs
    }
}

/// `before_compaction` / `after_compaction` event (observe-only).
public struct CompactionHookEvent: Codable, Sendable, Equatable {
    /// Session key.
    public var sessionKey: String?
    /// Messages in the transcript.
    public var messageCount: Int
    /// Messages being (or that were) compacted.
    public var compactedCount: Int?
    /// Estimated tokens before compaction.
    public var tokensBefore: Int?
    /// Estimated tokens after compaction (`after_compaction`).
    public var tokensAfter: Int?

    /// Creates a compaction event.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - messageCount: Message count.
    ///   - compactedCount: Compacted count.
    ///   - tokensBefore: Tokens before.
    ///   - tokensAfter: Tokens after.
    public init(sessionKey: String? = nil, messageCount: Int, compactedCount: Int? = nil, tokensBefore: Int? = nil, tokensAfter: Int? = nil) {
        self.sessionKey = sessionKey
        self.messageCount = messageCount
        self.compactedCount = compactedCount
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
    }
}

/// `session_start` / `session_end` event (observe-only).
public struct SessionLifecycleHookEvent: Codable, Sendable, Equatable {
    /// Session identifier.
    public var sessionId: String
    /// Session key.
    public var sessionKey: String?
    /// Previous session this one resumed from (`session_start`).
    public var resumedFrom: String?
    /// Messages in the session (`session_end`).
    public var messageCount: Int?
    /// Session duration in milliseconds (`session_end`).
    public var durationMs: Int?
    /// End reason: new, reset, idle, daily, compaction, deleted, shutdown, restart, unknown.
    public var reason: String?

    /// Creates a session lifecycle event.
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - sessionKey: Session key.
    ///   - resumedFrom: Resumed-from session.
    ///   - messageCount: Message count.
    ///   - durationMs: Duration.
    ///   - reason: End reason.
    public init(
        sessionId: String,
        sessionKey: String? = nil,
        resumedFrom: String? = nil,
        messageCount: Int? = nil,
        durationMs: Int? = nil,
        reason: String? = nil
    ) {
        self.sessionId = sessionId
        self.sessionKey = sessionKey
        self.resumedFrom = resumedFrom
        self.messageCount = messageCount
        self.durationMs = durationMs
        self.reason = reason
    }
}

/// `subagent_spawned` / `subagent_progress` / `subagent_ended` event (observe-only).
public struct SubagentHookEvent: Codable, Sendable, Equatable {
    /// Child session key.
    public var childSessionKey: String
    /// Child agent identifier.
    public var agentId: String?
    /// Child run identifier.
    public var runId: String?
    /// Optional label.
    public var label: String?
    /// `run` or `session`.
    public var mode: String?
    /// Progress phase (`started`/`ended`).
    public var phase: String?
    /// Outcome (`ok`, `error`, `timeout`, `killed`, …).
    public var outcome: String?
    /// End reason.
    public var reason: String?
    /// Error description.
    public var error: String?

    /// Creates a subagent event.
    /// - Parameters:
    ///   - childSessionKey: Child session key.
    ///   - agentId: Agent identifier.
    ///   - runId: Run identifier.
    ///   - label: Label.
    ///   - mode: Mode.
    ///   - phase: Phase.
    ///   - outcome: Outcome.
    ///   - reason: Reason.
    ///   - error: Error.
    public init(
        childSessionKey: String,
        agentId: String? = nil,
        runId: String? = nil,
        label: String? = nil,
        mode: String? = nil,
        phase: String? = nil,
        outcome: String? = nil,
        reason: String? = nil,
        error: String? = nil
    ) {
        self.childSessionKey = childSessionKey
        self.agentId = agentId
        self.runId = runId
        self.label = label
        self.mode = mode
        self.phase = phase
        self.outcome = outcome
        self.reason = reason
        self.error = error
    }
}

/// `cron_changed` event (observe-only).
public struct CronChangedHookEvent: Codable, Sendable, Equatable {
    /// `added`, `updated`, `removed`, `started`, `finished` or `scheduled`.
    public var action: String
    /// Job identifier.
    public var jobId: String
    /// Job snapshot in upstream `CronJob` wire shape.
    public var job: AnyCodable?
    /// Session target.
    public var sessionTarget: String?
    /// Owning agent.
    public var agentId: String?
    /// Run time in milliseconds since the epoch.
    public var runAtMs: Int64?
    /// Run duration in milliseconds.
    public var durationMs: Int64?
    /// Run status (`ok`, `error`, `skipped`).
    public var status: String?
    /// Error description.
    public var error: String?
    /// Run summary.
    public var summary: String?
    /// Session key used by the run.
    public var sessionKey: String?
    /// Run identifier.
    public var runId: String?
    /// Next run time in milliseconds since the epoch.
    public var nextRunAtMs: Int64?

    /// Creates a `cron_changed` event.
    /// - Parameters:
    ///   - action: Action.
    ///   - jobId: Job identifier.
    ///   - job: Job snapshot.
    ///   - sessionTarget: Session target.
    ///   - agentId: Agent identifier.
    ///   - runAtMs: Run time.
    ///   - durationMs: Duration.
    ///   - status: Status.
    ///   - error: Error.
    ///   - summary: Summary.
    ///   - sessionKey: Session key.
    ///   - runId: Run identifier.
    ///   - nextRunAtMs: Next run time.
    public init(
        action: String,
        jobId: String,
        job: AnyCodable? = nil,
        sessionTarget: String? = nil,
        agentId: String? = nil,
        runAtMs: Int64? = nil,
        durationMs: Int64? = nil,
        status: String? = nil,
        error: String? = nil,
        summary: String? = nil,
        sessionKey: String? = nil,
        runId: String? = nil,
        nextRunAtMs: Int64? = nil
    ) {
        self.action = action
        self.jobId = jobId
        self.job = job
        self.sessionTarget = sessionTarget
        self.agentId = agentId
        self.runAtMs = runAtMs
        self.durationMs = durationMs
        self.status = status
        self.error = error
        self.summary = summary
        self.sessionKey = sessionKey
        self.runId = runId
        self.nextRunAtMs = nextRunAtMs
    }
}

// MARK: - Message hooks

/// `message_received` event (observe-only).
public struct MessageReceivedHookEvent: Codable, Sendable, Equatable {
    /// Sender address.
    public var from: String
    /// Message content.
    public var content: String
    /// Timestamp in milliseconds since the epoch.
    public var timestamp: Int64?
    /// Message identifier.
    public var messageId: String?
    /// Sender identifier.
    public var senderId: String?
    /// Session key.
    public var sessionKey: String?

    /// Creates a `message_received` event.
    /// - Parameters:
    ///   - from: Sender.
    ///   - content: Content.
    ///   - timestamp: Timestamp.
    ///   - messageId: Message identifier.
    ///   - senderId: Sender identifier.
    ///   - sessionKey: Session key.
    public init(
        from: String,
        content: String,
        timestamp: Int64? = nil,
        messageId: String? = nil,
        senderId: String? = nil,
        sessionKey: String? = nil
    ) {
        self.from = from
        self.content = content
        self.timestamp = timestamp
        self.messageId = messageId
        self.senderId = senderId
        self.sessionKey = sessionKey
    }
}

/// `message_sending` event.
public struct MessageSendingEvent: Codable, Sendable, Equatable {
    /// Recipient address.
    public var to: String
    /// Message content.
    public var content: String
    /// Reply-to message identifier.
    public var replyToId: String?
    /// Thread identifier.
    public var threadId: String?
    /// Extra metadata.
    public var metadata: [String: AnyCodable]?

    /// Creates a `message_sending` event.
    /// - Parameters:
    ///   - to: Recipient.
    ///   - content: Content.
    ///   - replyToId: Reply-to identifier.
    ///   - threadId: Thread identifier.
    ///   - metadata: Metadata.
    public init(to: String, content: String, replyToId: String? = nil, threadId: String? = nil, metadata: [String: AnyCodable]? = nil) {
        self.to = to
        self.content = content
        self.replyToId = replyToId
        self.threadId = threadId
        self.metadata = metadata
    }
}

/// `message_sending` result.
public struct MessageSendingResult: Codable, Sendable, Equatable {
    /// Replacement content.
    public var content: String?
    /// Cancels the send (terminal).
    public var cancel: Bool?
    /// Cancel reason.
    public var cancelReason: String?
    /// Replacement metadata.
    public var metadata: [String: AnyCodable]?

    /// Creates a `message_sending` result.
    /// - Parameters:
    ///   - content: Replacement content.
    ///   - cancel: Cancel flag.
    ///   - cancelReason: Cancel reason.
    ///   - metadata: Metadata.
    public init(content: String? = nil, cancel: Bool? = nil, cancelReason: String? = nil, metadata: [String: AnyCodable]? = nil) {
        self.content = content
        self.cancel = cancel
        self.cancelReason = cancelReason
        self.metadata = metadata
    }
}

/// `message_sent` event (observe-only).
public struct MessageSentHookEvent: Codable, Sendable, Equatable {
    /// Recipient address.
    public var to: String
    /// Message content.
    public var content: String
    /// Whether delivery succeeded.
    public var success: Bool
    /// Message identifier.
    public var messageId: String?
    /// Session key.
    public var sessionKey: String?
    /// Error description.
    public var error: String?

    /// Creates a `message_sent` event.
    /// - Parameters:
    ///   - to: Recipient.
    ///   - content: Content.
    ///   - success: Success flag.
    ///   - messageId: Message identifier.
    ///   - sessionKey: Session key.
    ///   - error: Error.
    public init(to: String, content: String, success: Bool, messageId: String? = nil, sessionKey: String? = nil, error: String? = nil) {
        self.to = to
        self.content = content
        self.success = success
        self.messageId = messageId
        self.sessionKey = sessionKey
        self.error = error
    }
}

// MARK: - Install and gateway hooks

/// Finding reported by a `before_install` handler.
public struct BeforeInstallFinding: Codable, Sendable, Equatable {
    /// Rule identifier.
    public var ruleId: String
    /// `info`, `warn` or `critical`.
    public var severity: String
    /// File path.
    public var file: String
    /// Line number.
    public var line: Int
    /// Message.
    public var message: String

    /// Creates a finding.
    /// - Parameters:
    ///   - ruleId: Rule identifier.
    ///   - severity: Severity.
    ///   - file: File.
    ///   - line: Line.
    ///   - message: Message.
    public init(ruleId: String, severity: String, file: String, line: Int, message: String) {
        self.ruleId = ruleId
        self.severity = severity
        self.file = file
        self.line = line
        self.message = message
    }
}

/// `before_install` event.
public struct BeforeInstallEvent: Codable, Sendable, Equatable {
    /// `skill` or `plugin`.
    public var targetType: String
    /// Install request kind (`skill-install`, `plugin-dir`, …).
    public var requestKind: String
    /// Name of the skill or plugin.
    public var name: String
    /// Source path or reference.
    public var source: String?

    /// Creates a `before_install` event.
    /// - Parameters:
    ///   - targetType: Target type.
    ///   - requestKind: Request kind.
    ///   - name: Name.
    ///   - source: Source.
    public init(targetType: String, requestKind: String, name: String, source: String? = nil) {
        self.targetType = targetType
        self.requestKind = requestKind
        self.name = name
        self.source = source
    }
}

/// `before_install` result.
public struct BeforeInstallResult: Codable, Sendable, Equatable {
    /// Findings.
    public var findings: [BeforeInstallFinding]?
    /// Blocks the install (terminal).
    public var block: Bool?
    /// Block reason.
    public var blockReason: String?

    /// Creates a `before_install` result.
    /// - Parameters:
    ///   - findings: Findings.
    ///   - block: Block flag.
    ///   - blockReason: Block reason.
    public init(findings: [BeforeInstallFinding]? = nil, block: Bool? = nil, blockReason: String? = nil) {
        self.findings = findings
        self.block = block
        self.blockReason = blockReason
    }
}

/// `gateway_start` / `gateway_stop` event (observe-only).
public struct GatewayLifecycleHookEvent: Codable, Sendable, Equatable {
    /// Listening port, when known.
    public var port: Int?
    /// Stop reason (`gateway_stop`).
    public var reason: String?

    /// Creates a gateway lifecycle event.
    /// - Parameters:
    ///   - port: Port.
    ///   - reason: Reason.
    public init(port: Int? = nil, reason: String? = nil) {
        self.port = port
        self.reason = reason
    }
}
