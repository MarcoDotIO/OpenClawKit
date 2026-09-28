import Foundation
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

// Context engines (upstream `src/context-engine/types.ts`, `docs/concepts/context-engine.md`) and the
// built-in legacy summarization compaction (`docs/concepts/compaction.md`,
// `packages/agent-core/src/harness/compaction/*`).

/// What started a compaction.
public enum ContextCompactionTrigger: String, Codable, Sendable, Equatable, CaseIterable {
    /// The estimated context exceeded the model window minus the reserve.
    case auto
    /// A provider rejected the request as too large; the loop compacts once and retries.
    case overflow
    /// `sessions.compact` or `/compact`.
    case manual
}

/// Inputs to ``ContextEngine/assemble(_:)``.
public struct ContextAssembleParams: Sendable {
    /// Transcript session id.
    public var sessionID: String
    /// Session key.
    public var sessionKey: String
    /// Context-window messages from the transcript.
    public var messages: [AgentMessage]
    /// Token budget for the assembled context.
    public var tokenBudget: Int?
    /// Tool names visible to the model this turn.
    public var availableTools: Set<String>
    /// Model identifier.
    public var model: String?
    /// Latest user prompt.
    public var prompt: String?

    /// Creates assemble parameters.
    public init(
        sessionID: String,
        sessionKey: String,
        messages: [AgentMessage],
        tokenBudget: Int? = nil,
        availableTools: Set<String> = [],
        model: String? = nil,
        prompt: String? = nil
    ) {
        self.sessionID = sessionID
        self.sessionKey = sessionKey
        self.messages = messages
        self.tokenBudget = tokenBudget
        self.availableTools = availableTools
        self.model = model
        self.prompt = prompt
    }
}

/// Output of ``ContextEngine/assemble(_:)``.
public struct ContextAssembleResult: Sendable {
    /// Messages sent to the model.
    public var messages: [AgentMessage]
    /// Estimated tokens of ``messages``.
    public var estimatedTokens: Int
    /// Extra system-prompt text contributed by the engine.
    public var systemPromptAddition: String?

    /// Creates an assemble result.
    public init(messages: [AgentMessage], estimatedTokens: Int, systemPromptAddition: String? = nil) {
        self.messages = messages
        self.estimatedTokens = estimatedTokens
        self.systemPromptAddition = systemPromptAddition
    }
}

/// Inputs to ``ContextEngine/compact(_:)``.
public struct ContextCompactParams: Sendable {
    /// Transcript session id.
    public var sessionID: String
    /// Session key.
    public var sessionKey: String
    /// Target token budget (`nil` = engine default).
    public var tokenBudget: Int?
    /// Compact even when the context fits the budget.
    public var force: Bool
    /// Current token count, when known.
    public var currentTokenCount: Int?
    /// Operator focus (`/compact <focus>`), capped at 800 code points.
    public var customInstructions: String?
    /// What started the compaction.
    public var trigger: ContextCompactionTrigger
    /// Model that answers the session (fallback summarizer model).
    public var sessionModel: String?

    /// Creates compact parameters.
    public init(
        sessionID: String,
        sessionKey: String,
        tokenBudget: Int? = nil,
        force: Bool = false,
        currentTokenCount: Int? = nil,
        customInstructions: String? = nil,
        trigger: ContextCompactionTrigger = .manual,
        sessionModel: String? = nil
    ) {
        self.sessionID = sessionID
        self.sessionKey = sessionKey
        self.tokenBudget = tokenBudget
        self.force = force
        self.currentTokenCount = currentTokenCount
        self.customInstructions = customInstructions
        self.trigger = trigger
        self.sessionModel = sessionModel
    }
}

/// Output of ``ContextEngine/compact(_:)``.
public struct ContextCompactResult: Sendable, Equatable {
    /// Whether the engine ran without error.
    public var ok: Bool
    /// Whether history was replaced by a summary.
    public var compacted: Bool
    /// Why compaction did not happen (or failed).
    public var reason: String?
    /// New summary.
    public var summary: String?
    /// First entry kept verbatim.
    public var firstKeptEntryId: String?
    /// Estimated tokens before.
    public var tokensBefore: Int
    /// Estimated tokens after.
    public var tokensAfter: Int?

    /// Creates a compact result.
    public init(
        ok: Bool,
        compacted: Bool,
        reason: String? = nil,
        summary: String? = nil,
        firstKeptEntryId: String? = nil,
        tokensBefore: Int,
        tokensAfter: Int? = nil
    ) {
        self.ok = ok
        self.compacted = compacted
        self.reason = reason
        self.summary = summary
        self.firstKeptEntryId = firstKeptEntryId
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
    }
}

/// Sub-agent context mode.
public enum SubagentContextMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Fresh transcript.
    case isolated
    /// Copy of the parent's active path.
    case fork
}

/// Why a sub-agent ended (upstream `onSubagentEnded` reasons).
public enum SubagentEndReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// Session deleted.
    case deleted
    /// Run completed.
    case completed
    /// Cleaned up by a sweep.
    case swept
    /// Released by its parent.
    case released
}

/// Pluggable owner of model context: ingestion, assembly and compaction.
///
/// Every requirement except ``id``, ``assemble(_:)`` and ``compact(_:)`` has a default.
public protocol ContextEngine: Sendable {
    /// Engine identifier (`plugins.slots.contextEngine`).
    var id: String { get }

    /// Observes a new transcript message. Return `true` when the engine consumed it.
    /// - Parameters:
    ///   - sessionID: Transcript session id.
    ///   - sessionKey: Session key.
    ///   - message: Appended message.
    func ingest(sessionID: String, sessionKey: String, message: AgentMessage) async -> Bool

    /// Assembles the model context for a turn.
    /// - Parameter params: Assemble parameters.
    /// - Returns: Messages and optional system-prompt addition.
    func assemble(_ params: ContextAssembleParams) async throws -> ContextAssembleResult

    /// Compacts a session.
    /// - Parameter params: Compact parameters.
    /// - Returns: The outcome.
    func compact(_ params: ContextCompactParams) async throws -> ContextCompactResult

    /// Runs after each turn.
    /// - Parameters:
    ///   - sessionID: Transcript session id.
    ///   - sessionKey: Session key.
    func afterTurn(sessionID: String, sessionKey: String) async

    /// Prepares a sub-agent spawn; the returned closure rolls the preparation back.
    /// - Parameters:
    ///   - parentSessionKey: Parent session key.
    ///   - childSessionKey: Child session key.
    ///   - contextMode: Context mode.
    /// - Returns: Optional rollback handle.
    func prepareSubagentSpawn(
        parentSessionKey: String,
        childSessionKey: String,
        contextMode: SubagentContextMode
    ) async throws -> (@Sendable () async -> Void)?

    /// Observes a sub-agent ending.
    /// - Parameters:
    ///   - childSessionKey: Child session key.
    ///   - reason: End reason.
    func onSubagentEnded(childSessionKey: String, reason: SubagentEndReason) async
}

public extension ContextEngine {
    /// Default: not consumed.
    func ingest(sessionID _: String, sessionKey _: String, message _: AgentMessage) async -> Bool {
        false
    }

    /// Default: no-op.
    func afterTurn(sessionID _: String, sessionKey _: String) async {}

    /// Default: nothing to roll back.
    func prepareSubagentSpawn(
        parentSessionKey _: String,
        childSessionKey _: String,
        contextMode _: SubagentContextMode
    ) async throws -> (@Sendable () async -> Void)? {
        nil
    }

    /// Default: no-op.
    func onSubagentEnded(childSessionKey _: String, reason _: SubagentEndReason) async {}
}

/// Registry of context engines with one selected engine (default `legacy`).
public actor ContextEngineRegistry {
    private var engines: [String: any ContextEngine] = [:]
    private var selectedID: String

    /// Creates a registry.
    /// - Parameters:
    ///   - engines: Initial engines.
    ///   - selectedID: Selected engine id (default `legacy`).
    public init(engines: [any ContextEngine] = [], selectedID: String = LegacyContextEngine.engineID) {
        for engine in engines {
            self.engines[engine.id] = engine
        }
        self.selectedID = selectedID
    }

    /// Registers (or replaces) an engine.
    /// - Parameter engine: Engine.
    public func register(_ engine: any ContextEngine) {
        self.engines[engine.id] = engine
    }

    /// Selects an engine by id.
    /// - Parameter id: Engine id.
    /// - Throws: ``OpenClawCoreError/invalidConfiguration(_:)`` for unknown ids.
    public func select(_ id: String) throws {
        guard self.engines[id] != nil else {
            throw OpenClawCoreError.invalidConfiguration("Unknown context engine: \(id)")
        }
        self.selectedID = id
    }

    /// Selected engine id.
    public func selectedEngineID() -> String {
        self.selectedID
    }

    /// Selected engine, falling back to `legacy`.
    public func selected() -> (any ContextEngine)? {
        self.engines[self.selectedID] ?? self.engines[LegacyContextEngine.engineID]
    }

    /// Registered engine ids.
    public func engineIDs() -> [String] {
        self.engines.keys.sorted()
    }
}

/// Request passed to a ``ContextSummarizer``.
public struct ContextSummaryRequest: Sendable, Equatable {
    /// System prompt (upstream `SUMMARIZATION_SYSTEM_PROMPT`).
    public var systemPrompt: String
    /// User prompt: serialized conversation, previous summary, instructions, focus.
    public var prompt: String
    /// Maximum output tokens.
    public var maxTokens: Int
    /// Requested summarizer model (`provider/model` or model id).
    public var model: String?
    /// Session key.
    public var sessionKey: String
}

/// Produces compaction summaries.
public typealias ContextSummarizer = @Sendable (ContextSummaryRequest) async throws -> String

/// Compaction settings (upstream `DEFAULT_COMPACTION_SETTINGS`, `agents.defaults.compaction`).
public struct ContextCompactionSettings: Codable, Sendable, Equatable {
    /// Whether automatic compaction runs (default `true`).
    public var enabled: Bool
    /// Tokens reserved for the reply (default 16384).
    public var reserveTokens: Int
    /// Approximate recent-context tokens kept verbatim (default 20000).
    public var keepRecentTokens: Int
    /// Summarizer model override (`provider/model` or alias); `nil` uses the session model.
    public var model: String?

    /// Creates settings.
    public init(enabled: Bool = true, reserveTokens: Int = 16_384, keepRecentTokens: Int = 20_000, model: String? = nil) {
        self.enabled = enabled
        self.reserveTokens = max(0, reserveTokens)
        self.keepRecentTokens = max(0, keepRecentTokens)
        self.model = model
    }
}

/// Built-in engine: pass-through assembly plus summarization compaction (upstream legacy engine,
/// `mode: "default"`; the `safeguard` quality audit is not implemented).
///
/// Compaction keeps about ``ContextCompactionSettings/keepRecentTokens`` of the tail verbatim, never
/// splits an assistant tool call from its results, summarizes the head (images become
/// `[image data omitted from summary input]` markers), writes a `compaction` transcript entry, and
/// rejects a replacement that does not strictly reduce the context.
public struct LegacyContextEngine: ContextEngine {
    /// Engine identifier.
    public static let engineID = "legacy"
    /// Maximum operator focus length (code points).
    public static let maxFocusLength = 800
    /// Maximum summary length (characters).
    public static let maxSummaryChars = 16_000
    /// Summarizer system prompt.
    public static let systemPrompt = """
    You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, \
    then produce a structured summary following the exact format specified.

    Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
    """

    /// Engine identifier.
    public let id = LegacyContextEngine.engineID
    private let transcriptStore: any SessionTranscriptStore
    private let summarizer: ContextSummarizer
    private let settings: ContextCompactionSettings

    /// Creates the legacy engine.
    /// - Parameters:
    ///   - transcriptStore: Transcript store holding the sessions.
    ///   - settings: Compaction settings.
    ///   - summarizer: Summary generator.
    public init(
        transcriptStore: any SessionTranscriptStore,
        settings: ContextCompactionSettings = ContextCompactionSettings(),
        summarizer: @escaping ContextSummarizer
    ) {
        self.transcriptStore = transcriptStore
        self.settings = settings
        self.summarizer = summarizer
    }

    /// Pass-through assembly.
    public func assemble(_ params: ContextAssembleParams) async throws -> ContextAssembleResult {
        ContextAssembleResult(messages: params.messages, estimatedTokens: TokenEstimator.estimate(params.messages))
    }

    /// Summarizes the transcript head and records a `compaction` entry.
    public func compact(_ params: ContextCompactParams) async throws -> ContextCompactResult {
        let path = try await self.transcriptStore.activePath(sessionID: params.sessionID)
        let window = CompactionPlanner.window(of: path)
        let contextMessages = SessionTranscriptPaths.contextMessages(for: path)
        let tokensBefore = params.currentTokenCount ?? TokenEstimator.estimate(contextMessages)
        if !params.force, let budget = params.tokenBudget, tokensBefore <= budget {
            return ContextCompactResult(ok: true, compacted: false, reason: "within budget", tokensBefore: tokensBefore)
        }
        guard let plan = CompactionPlanner.plan(entries: window.entries, keepRecentTokens: self.settings.keepRecentTokens) else {
            return ContextCompactResult(ok: true, compacted: false, reason: "nothing to compact", tokensBefore: tokensBefore)
        }
        let prompt = CompactionPlanner.summaryPrompt(
            messages: plan.head.compactMap(SessionTranscriptPaths.projectMessage),
            previousSummary: window.previousSummary,
            focus: params.customInstructions
        )
        var summary = try await self.summarizer(
            ContextSummaryRequest(
                systemPrompt: Self.systemPrompt,
                prompt: prompt,
                maxTokens: max(256, Int(Double(self.settings.reserveTokens) * 0.8)),
                model: self.settings.model ?? params.sessionModel,
                sessionKey: params.sessionKey
            )
        )
        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            return ContextCompactResult(ok: false, compacted: false, reason: "summarizer returned an empty summary", tokensBefore: tokensBefore)
        }
        if summary.count > Self.maxSummaryChars {
            summary = String(summary.prefix(Self.maxSummaryChars)) + "\n\n[Compaction summary truncated to fit budget]"
        }
        let keptMessages = plan.kept.compactMap(SessionTranscriptPaths.projectMessage)
        let tokensAfter = TokenEstimator.estimate(
            [AgentMessage.compactionSummary(summary, tokensBefore: tokensBefore, timestamp: 0)] + keptMessages
        )
        guard tokensAfter < tokensBefore else {
            return ContextCompactResult(
                ok: true,
                compacted: false,
                reason: "compaction would not reduce context (\(tokensAfter) >= \(tokensBefore) tokens)",
                tokensBefore: tokensBefore,
                tokensAfter: tokensAfter
            )
        }
        let data = SessionCompactionData(
            summary: summary,
            firstKeptEntryId: plan.firstKeptEntryID,
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            details: AnyCodable(["trigger": AnyCodable(params.trigger.rawValue), "mode": AnyCodable("default")])
        )
        try await self.transcriptStore.append(SessionTranscriptEntry(payload: .compaction(data)), sessionID: params.sessionID)
        return ContextCompactResult(
            ok: true,
            compacted: true,
            summary: summary,
            firstKeptEntryId: plan.firstKeptEntryID,
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter
        )
    }

    /// Summarizer backed by a model router (`model` may be `provider/model`).
    /// - Parameter router: Model router.
    /// - Returns: A summarizer.
    public static func modelRouterSummarizer(_ router: ModelRouter) -> ContextSummarizer {
        { request in
            var providerID: String?
            var modelID: String?
            if let model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    providerID = parts[0]
                    modelID = parts[1]
                } else {
                    modelID = model
                }
            }
            let response = try await router.generate(
                ModelGenerationRequest(
                    sessionKey: request.sessionKey,
                    prompt: request.prompt,
                    systemPrompt: request.systemPrompt,
                    providerID: providerID,
                    modelID: modelID,
                    policy: ModelGenerationPolicy(maxTokens: request.maxTokens)
                )
            )
            return ProviderVisibleTextSanitizer.sanitizeVisibleText(response.text)
        }
    }
}

/// Pure helpers behind legacy compaction (exposed for engines and tests).
public enum CompactionPlanner {
    /// Upstream summarization instructions (`SUMMARIZATION_PROMPT`).
    public static let summarizationInstructions = """
    The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

    Use this EXACT format:

    ## Goal
    [What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

    ## Constraints & Preferences
    - [Any constraints, preferences, or requirements mentioned by user]
    - [Or "(none)" if none were mentioned]

    ## Progress
    ### Done
    - [x] [Completed tasks/changes]

    ### In Progress
    - [ ] [Current work]

    ### Blocked
    - [Issues preventing progress, if any]

    ## Key Decisions
    - **[Decision]**: [Brief rationale]

    ## Next Steps
    1. [Ordered list of what should happen next]

    ## Critical Context
    - [Any data, examples, or references needed to continue]
    - [Or "(none)" if not applicable]

    Keep each section concise. Preserve exact file paths, function names, and error messages.
    """

    /// Upstream update instructions (`UPDATE_SUMMARIZATION_PROMPT`, abbreviated heading list shared with the base format).
    public static let updateInstructions = """
    The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

    Update the existing structured summary with new information. RULES:
    - PRESERVE all existing information from the previous summary
    - ADD new progress, decisions, and context from the new messages
    - UPDATE the Progress section: move items from "In Progress" to "Done" when completed
    - UPDATE "Next Steps" based on what was accomplished
    - PRESERVE exact file paths, function names, and error messages
    - If something is no longer relevant, you may remove it

    Use the same EXACT format (Goal, Constraints & Preferences, Progress, Key Decisions, Next Steps, Critical Context).
    """

    /// Marker replacing image blocks in summarizer input.
    public static let imageOmissionMarker = "[image data omitted from summary input]"
    /// Marker replacing other non-text blocks.
    public static let nonTextOmissionMarker = "[non-text data omitted from summary input]"
    /// Aggregate statement once more than eight messages had omissions.
    public static let omissionOverflowMarker = "[More image/non-text data omitted from summary input]"
    /// Maximum characters of a tool result in summarizer input.
    public static let toolResultMaxChars = 4_000

    /// Current compaction window of a path: entries after the last boundary plus retained ones, and the
    /// previous summary when the boundary is a compaction.
    /// - Parameter path: Active path.
    /// - Returns: Window entries and previous summary.
    public static func window(of path: [SessionTranscriptEntry]) -> (entries: [SessionTranscriptEntry], previousSummary: String?) {
        guard let boundaryIndex = path.lastIndex(where: { entry in
            if case .compaction = entry.payload { return true }
            if case .reset = entry.payload { return true }
            return false
        }) else {
            return (path, nil)
        }
        var previousSummary: String?
        var firstKept: String?
        switch path[boundaryIndex].payload {
        case .compaction(let data):
            previousSummary = data.summary
            firstKept = data.firstKeptEntryId
        case .reset(_, let kept):
            firstKept = kept
        default:
            break
        }
        var entries: [SessionTranscriptEntry] = []
        if let firstKept, let index = path.firstIndex(where: { $0.id == firstKept }), index < boundaryIndex {
            entries.append(contentsOf: path[index..<boundaryIndex])
        }
        entries.append(contentsOf: path[(boundaryIndex + 1)...])
        return (entries, previousSummary)
    }

    /// Cut plan: summarized head, kept tail, and the first kept entry.
    public struct Plan: Sendable, Equatable {
        /// Entries summarized.
        public let head: [SessionTranscriptEntry]
        /// Entries kept verbatim.
        public let kept: [SessionTranscriptEntry]
        /// First kept entry id.
        public let firstKeptEntryID: String
    }

    /// Chooses the cut point keeping about `keepRecentTokens` of message-bearing entries, moving the
    /// boundary so a kept tool result is never separated from its assistant tool call.
    /// - Parameters:
    ///   - entries: Window entries.
    ///   - keepRecentTokens: Tail budget.
    /// - Returns: The plan, or `nil` when nothing can be summarized.
    public static func plan(entries: [SessionTranscriptEntry], keepRecentTokens: Int) -> Plan? {
        let messageIndices = entries.indices.filter { SessionTranscriptPaths.projectMessage(entries[$0]) != nil }
        guard messageIndices.count >= 2 else { return nil }
        var kept = 0
        var cut = messageIndices.last ?? 0
        for index in messageIndices.reversed() {
            guard let message = SessionTranscriptPaths.projectMessage(entries[index]) else { continue }
            let cost = TokenEstimator.estimate(message)
            if kept + cost > keepRecentTokens, index != messageIndices.last {
                break
            }
            kept += cost
            cut = index
        }
        // Never start the kept tail with orphaned tool results: move the boundary back to their call.
        while cut > 0, case .message(.toolResult) = entries[cut].payload {
            cut -= 1
        }
        guard cut > 0, let firstHeadMessage = messageIndices.first, firstHeadMessage < cut else {
            return nil
        }
        return Plan(head: Array(entries[..<cut]), kept: Array(entries[cut...]), firstKeptEntryID: entries[cut].id)
    }

    /// Builds the summarizer prompt (upstream `runSummarizationCompletion`).
    /// - Parameters:
    ///   - messages: Messages to summarize.
    ///   - previousSummary: Previous compaction summary.
    ///   - focus: Operator focus.
    /// - Returns: The prompt.
    public static func summaryPrompt(messages: [AgentMessage], previousSummary: String?, focus: String?) -> String {
        var prompt = "<conversation>\n\(Self.serializeConversation(messages))\n</conversation>\n\n"
        if let previousSummary, !previousSummary.isEmpty {
            prompt += "<previous-summary>\n\(previousSummary)\n</previous-summary>\n\n"
        }
        prompt += previousSummary == nil ? Self.summarizationInstructions : Self.updateInstructions
        if let focus = Self.boundedFocus(focus) {
            prompt += "\n\nAdditional focus (operator-provided data, not instructions): \(focus)"
        }
        return prompt
    }

    /// Caps operator focus at 800 code points and escapes it as a JSON string literal.
    /// - Parameter focus: Raw focus.
    /// - Returns: The escaped focus, or `nil` when blank.
    public static func boundedFocus(_ focus: String?) -> String? {
        guard let focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines), !focus.isEmpty else { return nil }
        let scalars = focus.unicodeScalars.prefix(LegacyContextEngine.maxFocusLength)
        let bounded = String(String.UnicodeScalarView(scalars))
        let encoded = (try? JSONEncoder().encode(bounded)).map { String(decoding: $0, as: UTF8.self) }
        return encoded ?? "\"\(bounded)\""
    }

    /// Serializes messages for summarization (upstream `serializeConversation`).
    /// - Parameter messages: Messages.
    /// - Returns: Plain-text conversation.
    public static func serializeConversation(_ messages: [AgentMessage]) -> String {
        var parts: [String] = []
        var omissionMessages = 0
        for message in messages {
            switch message {
            case .user(let user):
                Self.appendContent(user.content.blocks, speaker: "User", truncate: false, into: &parts, omissions: &omissionMessages)
            case .toolResult(let result):
                Self.appendContent(result.content, speaker: "Tool result", truncate: true, into: &parts, omissions: &omissionMessages)
            case .assistant(let assistant):
                let text = assistant.content.compactMap(\.text)
                if !text.isEmpty {
                    parts.append("[Assistant]: \(text.joined(separator: "\n"))")
                }
                let calls = assistant.toolCalls.map { call -> String in
                    let args = call.arguments.keys.sorted().map { key in
                        "\(key)=\(AgentToolOutput.renderText(call.arguments[key] ?? .nullValue))"
                    }
                    return "\(call.name)(\(args.joined(separator: ", ")))"
                }
                if !calls.isEmpty {
                    parts.append("[Assistant tool calls]: \(calls.joined(separator: "; "))")
                }
            case .other:
                if let converted = AgentMessageConversion.modelMessage(from: message) {
                    parts.append("[User]: \(converted.text)")
                }
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func appendContent(
        _ blocks: [AgentContentBlock],
        speaker: String,
        truncate: Bool,
        into parts: inout [String],
        omissions: inout Int
    ) {
        var markers: [String] = []
        var texts: [String] = []
        for block in blocks {
            switch block {
            case .text(let text, _):
                texts.append(text)
            case .image:
                if !markers.contains(Self.imageOmissionMarker) { markers.append(Self.imageOmissionMarker) }
            case .thinking, .toolCall, .unknown:
                if !markers.contains(Self.nonTextOmissionMarker) { markers.append(Self.nonTextOmissionMarker) }
            }
        }
        if !markers.isEmpty {
            if omissions == 8 {
                parts.append(Self.omissionOverflowMarker)
            }
            omissions += 1
        }
        var text = texts.joined(separator: "\n")
        if truncate, text.count > Self.toolResultMaxChars {
            let dropped = text.count - Self.toolResultMaxChars
            text = String(text.prefix(Self.toolResultMaxChars)) + "\n\n[... \(dropped) more characters truncated]"
        }
        let content = [omissions <= 8 ? markers.joined(separator: "\n") : "", text].filter { !$0.isEmpty }.joined(separator: "\n")
        if !content.isEmpty {
            parts.append("[\(speaker)]: \(content)")
        }
    }

    /// Whether a provider error means the request exceeded the model context (upstream overflow patterns).
    /// - Parameter error: Provider error.
    /// - Returns: `true` for context-overflow errors.
    public static func isContextOverflowError(_ error: Error) -> Bool {
        let description = [
            (error as? LocalizedError)?.errorDescription,
            String(describing: error),
        ].compactMap { $0?.lowercased() }.joined(separator: " ")
        return [
            "request_too_large",
            "context length exceeded",
            "context_length_exceeded",
            "input exceeds the maximum number of tokens",
            "input token count exceeds the maximum number of input tokens",
            "input is too long for the model",
            "ollama error: context length exceeded",
            "maximum context length",
            "prompt is too long",
        ].contains { description.contains($0) }
    }
}
