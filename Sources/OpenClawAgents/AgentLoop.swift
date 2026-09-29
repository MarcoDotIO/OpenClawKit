import Foundation
import OpenClawCore
import OpenClawMedia
import OpenClawModels
import OpenClawProtocol
import OpenClawSkills

// Model-driven agent loop (upstream `docs/concepts/agent-loop.md`, `src/agents/embedded-agent-*`).
//
// One run: resolve the provider/model (`before_model_resolve`), gate the run (`before_agent_run`),
// prepare media and skills, append the user message, run `before_prompt_build`, then repeat
//   assemble context → call the model with visible tools (`llm_input`/`llm_output`) → append the
//   assistant message → execute proposed tool calls (hooks, approvals, schema validation) → append
//   tool results (`tool_result_persist`)
// until the model stops calling tools, every result asks to terminate, the run is aborted, or the
// iteration cap is reached. Every transcript write passes `before_message_write`; the final reply
// passes `message_sending`/`message_sent` and the run ends with `agent_end`. Events stream as
// `AgentEventFrame`s (lifecycle/assistant/thinking/tool/usage/compaction/approval).

/// Loop settings (SDK-owned defaults; upstream has no fixed iteration constant).
public struct AgentLoopConfiguration: Sendable, Equatable {
    /// Default cap on model turns that end in tool calls.
    public static let defaultMaxToolIterations = 24
    /// Context window at or below which Tool Search activates for small catalogs (Apple on-device model).
    public static let defaultSmallContextWindowTokens = 8_192
    /// Visible tool count above which small-context models get Tool Search.
    public static let defaultSmallContextToolSearchThreshold = 8

    /// Maximum model turns per run.
    public var maxToolIterations: Int
    /// Optional base identity/runtime system prompt placed before bootstrap and skills.
    public var baseSystemPrompt: String?
    /// Model context window in tokens; enables automatic compaction when set.
    public var contextWindowTokens: Int?
    /// Compaction settings.
    public var compaction: ContextCompactionSettings
    /// Maximum characters of a sanitized tool result in `tool` events.
    public var toolResultEventMaxChars: Int
    /// Working directory recorded in new transcript headers.
    public var transcriptWorkingDirectory: String
    /// Agent fast-mode default (upstream `agents.defaults.fastModeDefault`), used when neither the
    /// request nor the session sets fast mode.
    public var fastModeDefault: FastMode?
    /// Prompt-cache preferences forwarded to providers (`nil` leaves caching to the provider).
    public var promptCache: ModelPromptCachePolicy?
    /// Agent runtime id used to resolve thinking profiles (`openclaw`, `auto`, `codex`, …); `nil`
    /// follows upstream and never synthesizes `ultra`.
    public var agentRuntimeID: String?
    /// Provider configurations keyed by provider id; used to resolve model inputs (media
    /// understanding) and context windows. Catalog entries fill providers missing here.
    public var providerConfigs: [String: ModelProviderConfig]
    /// Converts media the model cannot read (OCR text, video frames, transcripts) before dispatch.
    public var mediaUnderstanding: Bool
    /// Media-understanding hints (`ocrImages`, `mediaUnderstanding`, `transcriptionLocale`; see
    /// `MediaUnderstandingInputPolicy`), also forwarded to providers as local runtime hints.
    public var mediaUnderstandingHints: [String: String]
    /// Skill settings passed to the workspace skill registry.
    public var skills: SkillsConfiguration?
    /// Forces a skill prompt mode; `nil` picks the v6 catalog when the model can call tools and a
    /// `read` tool is available, otherwise inlines skill bodies.
    public var skillPromptMode: SkillPromptMode?
    /// Offers a path-jailed ``SkillReadTool`` in catalog mode when no `read` tool is registered.
    public var providesSkillReadTool: Bool
    /// Context window at or below which Tool Search activates for catalogs above
    /// ``smallContextToolSearchThreshold`` tools.
    public var smallContextWindowTokens: Int
    /// Visible tool count above which small-context models get Tool Search.
    public var smallContextToolSearchThreshold: Int
    /// Runs `message_sending`/`message_sent` hooks on the final reply. Turn off when a channel
    /// layer delivers the reply and emits these hooks itself.
    public var emitsReplyHooks: Bool

    /// Creates loop settings.
    /// - Parameters:
    ///   - maxToolIterations: Maximum model turns per run (minimum 1).
    ///   - baseSystemPrompt: Optional base system prompt.
    ///   - contextWindowTokens: Optional model context window for automatic compaction.
    ///   - compaction: Compaction settings.
    ///   - toolResultEventMaxChars: Tool result preview size in events.
    ///   - transcriptWorkingDirectory: Working directory recorded in transcript headers.
    ///   - fastModeDefault: Agent fast-mode default.
    ///   - promptCache: Prompt-cache preferences.
    ///   - agentRuntimeID: Agent runtime id for thinking profiles.
    ///   - providerConfigs: Provider configurations keyed by provider id.
    ///   - mediaUnderstanding: Convert unreadable media before dispatch.
    ///   - mediaUnderstandingHints: Media-understanding hints.
    ///   - skills: Skill settings.
    ///   - skillPromptMode: Forced skill prompt mode.
    ///   - providesSkillReadTool: Offer the jailed `read` tool in catalog mode.
    ///   - smallContextWindowTokens: Small-context threshold for Tool Search.
    ///   - smallContextToolSearchThreshold: Tool count threshold for small-context Tool Search.
    ///   - emitsReplyHooks: Run reply delivery hooks.
    public init(
        maxToolIterations: Int = AgentLoopConfiguration.defaultMaxToolIterations,
        baseSystemPrompt: String? = nil,
        contextWindowTokens: Int? = nil,
        compaction: ContextCompactionSettings = ContextCompactionSettings(),
        toolResultEventMaxChars: Int = 2_000,
        transcriptWorkingDirectory: String = "",
        fastModeDefault: FastMode? = nil,
        promptCache: ModelPromptCachePolicy? = nil,
        agentRuntimeID: String? = nil,
        providerConfigs: [String: ModelProviderConfig] = [:],
        mediaUnderstanding: Bool = true,
        mediaUnderstandingHints: [String: String] = [:],
        skills: SkillsConfiguration? = nil,
        skillPromptMode: SkillPromptMode? = nil,
        providesSkillReadTool: Bool = true,
        smallContextWindowTokens: Int = AgentLoopConfiguration.defaultSmallContextWindowTokens,
        smallContextToolSearchThreshold: Int = AgentLoopConfiguration.defaultSmallContextToolSearchThreshold,
        emitsReplyHooks: Bool = true
    ) {
        self.maxToolIterations = max(1, maxToolIterations)
        self.baseSystemPrompt = baseSystemPrompt
        self.contextWindowTokens = contextWindowTokens.map { max(1, $0) }
        self.compaction = compaction
        self.toolResultEventMaxChars = max(64, toolResultEventMaxChars)
        self.transcriptWorkingDirectory = transcriptWorkingDirectory
        self.fastModeDefault = fastModeDefault
        self.promptCache = promptCache
        self.agentRuntimeID = agentRuntimeID
        self.providerConfigs = providerConfigs
        self.mediaUnderstanding = mediaUnderstanding
        self.mediaUnderstandingHints = mediaUnderstandingHints
        self.skills = skills
        self.skillPromptMode = skillPromptMode
        self.providesSkillReadTool = providesSkillReadTool
        self.smallContextWindowTokens = max(0, smallContextWindowTokens)
        self.smallContextToolSearchThreshold = max(1, smallContextToolSearchThreshold)
        self.emitsReplyHooks = emitsReplyHooks
    }
}

/// Context passed to tool-call hooks.
public struct AgentToolCallHookContext: Sendable, Equatable {
    /// Run identifier.
    public var runID: String
    /// Session key.
    public var sessionKey: String
    /// Agent identifier.
    public var agentID: String
    /// Tool call identifier.
    public var toolCallID: String
    /// Tool name as proposed by the model.
    public var toolName: String
    /// Tool arguments (after earlier rewrites).
    public var arguments: [String: AnyCodable]
    /// Tool descriptor, when the tool is registered.
    public var descriptor: AgentToolDescriptor?
}

/// Approval requested by a `before_tool_call` hook (upstream `HookApprovalRequest`).
public struct AgentToolApprovalRequest: Sendable, Equatable {
    /// Title (≤ 80 characters).
    public var title: String
    /// Description (≤ 512 characters).
    public var description: String
    /// Severity: `info`, `warning` or `critical`.
    public var severity: String
    /// Deadline (ms).
    public var timeoutMs: Int64?
    /// Allowed decisions (deny is always added).
    public var allowedDecisions: [ApprovalDecision]
    /// Owning plugin.
    public var pluginID: String?
    /// Text returned as the blocked tool result when the approval expires (upstream `timeoutReason`).
    public var timeoutReason: String?

    /// Creates an approval request.
    /// - Parameters:
    ///   - title: Title.
    ///   - description: Description.
    ///   - severity: Severity.
    ///   - timeoutMs: Deadline in milliseconds.
    ///   - allowedDecisions: Allowed decisions.
    ///   - pluginID: Owning plugin.
    ///   - timeoutReason: Result text when the approval expires.
    public init(
        title: String,
        description: String,
        severity: String = "warning",
        timeoutMs: Int64? = nil,
        allowedDecisions: [ApprovalDecision] = [.allowOnce, .allowAlways, .deny],
        pluginID: String? = nil,
        timeoutReason: String? = nil
    ) {
        self.title = title
        self.description = description
        self.severity = severity
        self.timeoutMs = timeoutMs
        self.allowedDecisions = allowedDecisions
        self.pluginID = pluginID
        self.timeoutReason = timeoutReason
    }

    /// Creates the request from a typed hook approval request.
    /// - Parameter request: Hook approval request.
    public init(_ request: HookApprovalRequest) {
        self.init(
            title: request.title,
            description: request.description,
            severity: request.severity?.rawValue ?? "warning",
            timeoutMs: request.timeoutMs.map(Int64.init),
            allowedDecisions: request.allowedDecisions?.compactMap { ApprovalDecision(rawValue: $0.rawValue) }
                ?? [.allowOnce, .allowAlways, .deny],
            pluginID: request.pluginId,
            timeoutReason: request.timeoutReason
        )
    }
}

/// Decision returned by a `before_tool_call` hook.
public enum AgentBeforeToolCallDecision: Sendable, Equatable {
    /// Run the tool unchanged.
    case proceed
    /// Run the tool with rewritten arguments.
    case rewrite([String: AnyCodable])
    /// Do not run the tool; the model receives an error result with the reason.
    case block(reason: String)
    /// Ask a human first (an unresolved approval denies).
    case requireApproval(AgentToolApprovalRequest)
}

/// Closure hook seams of the loop.
///
/// Typed plugin hooks registered on the runtime's shared ``HookRegistry`` run in addition to these
/// closures, after them (``AgentLoopHooks/beforeToolCall`` first, then `before_tool_call` handlers
/// seeing the rewritten arguments).
public struct AgentLoopHooks: Sendable {
    /// Runs before each tool call.
    public var beforeToolCall: (@Sendable (AgentToolCallHookContext) async -> AgentBeforeToolCallDecision)?
    /// Runs after each tool call.
    public var afterToolCall: (@Sendable (AgentToolCallHookContext, AgentToolResult) async -> Void)?
    /// Observes compaction (`tokensAfter` is `nil` before compaction).
    public var onCompaction: (@Sendable (_ sessionKey: String, _ trigger: ContextCompactionTrigger, _ tokensBefore: Int, _ tokensAfter: Int?) async -> Void)?

    /// Creates hooks.
    public init(
        beforeToolCall: (@Sendable (AgentToolCallHookContext) async -> AgentBeforeToolCallDecision)? = nil,
        afterToolCall: (@Sendable (AgentToolCallHookContext, AgentToolResult) async -> Void)? = nil,
        onCompaction: (@Sendable (String, ContextCompactionTrigger, Int, Int?) async -> Void)? = nil
    ) {
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.onCompaction = onCompaction
    }

    /// Hooks that forward every seam to typed ``HookRegistry`` handlers (`before_tool_call` with
    /// block, parameter rewrite or approval; `after_tool_call`; `before_compaction`/`after_compaction`).
    ///
    /// Use this for loops that do not receive the registry directly. Do not combine it with passing
    /// the same registry as the runtime's `hookRegistry`, or handlers run twice.
    /// - Parameter registry: Shared hook registry.
    /// - Returns: Bridging hooks.
    public static func bridging(_ registry: HookRegistry) -> AgentLoopHooks {
        AgentLoopHooks(
            beforeToolCall: { context in
                let decision = await registry.runBeforeToolCall(
                    BeforeToolCallEvent(
                        toolName: context.toolName,
                        params: context.arguments,
                        runId: context.runID,
                        toolCallId: context.toolCallID
                    ),
                    context: HookContext(runID: context.runID, sessionKey: context.sessionKey, agentID: context.agentID)
                )
                return Self.decision(from: decision)
            },
            afterToolCall: { context, result in
                await registry.emitObserving(
                    .afterToolCall,
                    event: AgentLoop.afterToolCallEvent(context: context, result: result),
                    context: HookContext(runID: context.runID, sessionKey: context.sessionKey, agentID: context.agentID)
                )
            },
            onCompaction: { sessionKey, _, tokensBefore, tokensAfter in
                let event = CompactionHookEvent(sessionKey: sessionKey, messageCount: 0, tokensBefore: tokensBefore, tokensAfter: tokensAfter)
                await registry.emitObserving(
                    tokensAfter == nil ? .beforeCompaction : .afterCompaction,
                    event: event,
                    context: HookContext(sessionKey: sessionKey)
                )
            }
        )
    }

    /// Maps a merged typed decision onto a closure decision (block wins, then approval, then rewrite).
    /// - Parameter decision: Merged `before_tool_call` decision.
    /// - Returns: The closure decision.
    public static func decision(from decision: BeforeToolCallDecision?) -> AgentBeforeToolCallDecision {
        guard let decision else { return .proceed }
        if decision.block == true {
            return .block(reason: decision.blockReason ?? AgentLoop.defaultHookBlockReason)
        }
        if let approval = decision.requireApproval {
            return .requireApproval(AgentToolApprovalRequest(approval))
        }
        if let params = decision.params {
            return .rewrite(params)
        }
        return .proceed
    }
}

/// Context handed to system-prompt contributors for one model turn
/// (see ``EmbeddedAgentRuntime/addPromptContributor(_:)``).
public struct AgentPromptContext: Sendable {
    /// Run identifier.
    public var runID: String
    /// Session key.
    public var sessionKey: String
    /// Agent identifier.
    public var agentID: String
    /// Session record, when a session store exists.
    public var session: SessionRecord?
    /// Provider that will answer the turn.
    public var providerID: String?
    /// Model that will answer the turn.
    public var modelID: String?
    /// Contract-v2 capabilities of the provider.
    public var capabilities: ModelProviderCapabilities
    /// Names of the tools offered to the model this turn.
    public var availableToolNames: Set<String>

    /// Creates a prompt context.
    /// - Parameters:
    ///   - runID: Run identifier.
    ///   - sessionKey: Session key.
    ///   - agentID: Agent identifier.
    ///   - session: Session record.
    ///   - providerID: Provider identifier.
    ///   - modelID: Model identifier.
    ///   - capabilities: Provider capabilities.
    ///   - availableToolNames: Offered tool names.
    public init(
        runID: String,
        sessionKey: String,
        agentID: String,
        session: SessionRecord? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        capabilities: ModelProviderCapabilities = .legacy,
        availableToolNames: Set<String> = []
    ) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.agentID = agentID
        self.session = session
        self.providerID = providerID
        self.modelID = modelID
        self.capabilities = capabilities
        self.availableToolNames = availableToolNames
    }
}

/// Error raised when loop detection trips.
public struct AgentLoopDetectedError: Error, LocalizedError, Sendable, Equatable {
    /// Repeated tool name.
    public let toolName: String
    /// Repeat count.
    public let repeats: Int

    /// Human-readable message.
    public var errorDescription: String? {
        "Tool loop detected: \(self.toolName) repeated identical calls \(self.repeats) times"
    }
}

/// Why a run was cancelled.
enum AgentRunCancellation: Sendable {
    case aborted
    case timedOut
}

/// Cross-task run control (abort vs timeout).
final class AgentRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: AgentRunCancellation?

    func mark(_ reason: AgentRunCancellation) {
        self.lock.lock()
        if self.reason == nil {
            self.reason = reason
        }
        self.lock.unlock()
    }

    var cancellation: AgentRunCancellation? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.reason
    }
}

/// Collects legacy events, tool results and transcript writes during a run.
final class AgentRunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentRunEvent] = []
    private var results: [AgentToolResult] = []
    private var messages: [AgentMessage] = []

    func record(_ event: AgentRunEvent) {
        self.lock.lock()
        self.events.append(event)
        self.lock.unlock()
    }

    func record(_ result: AgentToolResult) {
        self.lock.lock()
        self.results.append(result)
        self.lock.unlock()
    }

    func record(_ message: AgentMessage) {
        self.lock.lock()
        self.messages.append(message)
        self.lock.unlock()
    }

    var snapshot: (events: [AgentRunEvent], results: [AgentToolResult]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        return (self.events, self.results)
    }

    var writtenMessages: [AgentMessage] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.messages
    }
}

/// Everything a run needs (captured by value so the loop runs off the runtime actor).
struct AgentLoopDependencies: Sendable {
    let toolRegistry: AgentToolRegistry
    /// Tools offered to this run only (the jailed skill `read` tool, `music_analyze`, …).
    let runTools: AgentToolRegistry
    let modelRouter: ModelRouter
    let mediaPipeline: MediaPipeline
    let mediaServices: MediaUnderstandingServices
    let transcriptStore: (any SessionTranscriptStore)?
    let sessionStore: SessionStore?
    let contextEngines: ContextEngineRegistry
    let approvalBroker: ApprovalBroker
    let tools: AgentToolsConfiguration
    let configuration: AgentLoopConfiguration
    let hooks: AgentLoopHooks
    let hookRegistry: HookRegistry?
    let diagnostics: RuntimeDiagnosticSink?
    let defaultAgentID: String
    let internalEvents: @Sendable (String) async -> [String]
    let promptContributors: @Sendable (AgentPromptContext) async -> [String]
}

/// Accumulates one streamed model turn (readable after cancellation for partial output).
final class AgentStreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var rawText = ""
    private(set) var visibleText = ""
    private(set) var reasoningText = ""

    func appendText(_ text: String) -> (visible: String, delta: String, replace: Bool) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.rawText += text
        let previous = self.visibleText
        let current = ProviderVisibleTextSanitizer.sanitizeVisibleText(self.rawText)
        self.visibleText = current
        let replace = !current.hasPrefix(previous)
        let shared = zip(previous, current).prefix { $0 == $1 }.count
        return (current, String(current.dropFirst(shared)), replace)
    }

    func appendReasoning(_ text: String) -> String {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.reasoningText += text
        return self.reasoningText
    }

    var partialVisibleText: String {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.visibleText
    }
}

/// Provider, model and request-shaping facts resolved once per run.
struct AgentRunModelContext: Sendable {
    let providerID: String?
    let modelID: String?
    let capabilities: ModelProviderCapabilities
    let providerConfig: ModelProviderConfig?
    let modelDefinition: ModelDefinitionConfig?
    let thinkingLevel: ThinkLevel?
    let fastMode: FastMode?

    var usesContractV2: Bool {
        self.capabilities.supportsTools || self.capabilities.supportsTranscript
    }

    /// Resolved context window (`contextTokens`, then `contextWindow`) when the model is known.
    var contextWindow: Int? {
        guard let definition = self.modelDefinition else { return nil }
        if let tokens = definition.contextTokens, tokens > 0 { return tokens }
        return definition.contextWindow > 0 ? definition.contextWindow : nil
    }
}

/// Prompt-build hook contributions applied to every model turn of a run.
struct AgentPromptBuildOverrides: Sendable {
    var systemPrompt: String?
    var prependContext: String?
    var appendContext: String?
    var prependSystemContext: String?
    var appendSystemContext: String?
    var toolsAllow: [String]?

    init(_ result: BeforePromptBuildResult?) {
        self.systemPrompt = result?.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.prependContext = result?.prependContext?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.appendContext = result?.appendContext?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.prependSystemContext = result?.prependSystemContext
        self.appendSystemContext = result?.appendSystemContext
        self.toolsAllow = result?.toolsAllow
    }

    /// Applies the user-prompt context around a prompt string.
    func wrapPrompt(_ prompt: String) -> String {
        var text = prompt
        if let prependContext {
            text = "\(prependContext)\n\n\(text)"
        }
        if let appendContext {
            text = "\(text)\n\n\(appendContext)"
        }
        return text
    }

    /// Applies the user-prompt context to the last user message of a model transcript.
    func wrapLastUserMessage(_ messages: [ModelMessage]) -> [ModelMessage] {
        guard self.prependContext != nil || self.appendContext != nil,
              let index = messages.lastIndex(where: { $0.role == .user }),
              case .user(var content) = messages[index]
        else {
            return messages
        }
        if let prependContext {
            if let first = content.firstIndex(where: { $0.text != nil }), let text = content[first].text {
                content[first] = .text("\(prependContext)\n\n\(text)")
            } else {
                content.insert(.text(prependContext), at: 0)
            }
        }
        if let appendContext {
            if let last = content.lastIndex(where: { $0.text != nil }), let text = content[last].text {
                content[last] = .text("\(text)\n\n\(appendContext)")
            } else {
                content.append(.text(appendContext))
            }
        }
        var copy = messages
        copy[index] = .user(content: content)
        return copy
    }

    /// Applies the system prompt override and plugin system context.
    func systemPrompt(base: String?) -> String? {
        let replaced = self.systemPrompt ?? base
        return AgentHookSystemContext.compose(base: replaced, prepend: self.prependSystemContext, append: self.appendSystemContext)
            ?? replaced
    }

    /// Filters descriptors by `toolsAllow` (`*` keeps everything).
    func filterTools(_ descriptors: [AgentToolDescriptor]) -> [AgentToolDescriptor] {
        guard let toolsAllow else { return descriptors }
        let allowed = Set(toolsAllow.map { AgentToolRegistry.canonicalName($0) })
        if allowed.contains("*") { return descriptors }
        return descriptors.filter { allowed.contains(AgentToolRegistry.canonicalName($0.name)) }
    }
}

/// The model-driven loop for one run.
struct AgentLoop: Sendable {
    let deps: AgentLoopDependencies

    static let mutationToolNames: Set<String> = ["write", "edit", "apply_patch", "exec", "process"]
    /// Upstream default reason for `before_tool_call` blocks without a reason.
    static let defaultHookBlockReason = "Tool call blocked by plugin hook"

    func run(
        _ originalRequest: AgentRunRequest,
        streaming: Bool,
        events: AgentEventSequencer,
        recorder: AgentRunRecorder,
        control: AgentRunControl
    ) async throws -> AgentRunResult {
        let startedAt = SessionTranscriptClock.nowMs()
        let agentID = SessionKey.normalizeAgentID(originalRequest.agentID ?? self.deps.defaultAgentID)
        let hooks = AgentLoopHookEmitter(
            registry: self.deps.hookRegistry,
            runID: originalRequest.runID,
            sessionKey: originalRequest.sessionKey,
            agentID: agentID
        )
        events.emit(.lifecycle, ["phase": AnyCodable("start"), "startedAt": AnyCodable(startedAt)])
        recorder.record(AgentRunEvent(runID: originalRequest.runID, kind: .runStarted))
        do {
            let result = try await self.runBody(
                originalRequest,
                agentID: agentID,
                startedAt: startedAt,
                hooks: hooks,
                streaming: streaming,
                events: events,
                recorder: recorder,
                control: control
            )
            let messages = recorder.writtenMessages
            await hooks.observe(.agentEnd) {
                AgentEndHookEvent(
                    runId: originalRequest.runID,
                    messages: AgentLoopHookEmitter.encode(messages),
                    success: true,
                    durationMs: Int(max(0, SessionTranscriptClock.nowMs() - startedAt))
                )
            }
            return result
        } catch {
            let messages = recorder.writtenMessages
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            await hooks.observe(.agentEnd) {
                AgentEndHookEvent(
                    runId: originalRequest.runID,
                    messages: AgentLoopHookEmitter.encode(messages),
                    success: false,
                    error: description,
                    durationMs: Int(max(0, SessionTranscriptClock.nowMs() - startedAt))
                )
            }
            throw error
        }
    }

    func runBody(
        _ originalRequest: AgentRunRequest,
        agentID: String,
        startedAt: Int64,
        hooks: AgentLoopHookEmitter,
        streaming: Bool,
        events: AgentEventSequencer,
        recorder: AgentRunRecorder,
        control: AgentRunControl
    ) async throws -> AgentRunResult {
        let runID = originalRequest.runID

        // Session and transcript.
        let sessionRecord = await self.deps.sessionStore?.resolveOrCreate(
            sessionKey: originalRequest.sessionKey,
            defaultAgentID: agentID,
            route: nil
        )
        let transcript: any SessionTranscriptStore = self.deps.transcriptStore ?? InMemorySessionTranscriptStore()
        let sessionID = sessionRecord?.sessionID
            ?? originalRequest.sessionID
            ?? (self.deps.transcriptStore != nil ? SessionTranscriptIdentity.sessionID(forKey: originalRequest.sessionKey) : "run-\(runID)")
        let isNewTranscript = self.deps.transcriptStore != nil ? (try await transcript.header(sessionID: sessionID)) == nil : false
        try await transcript.ensureSession(
            id: sessionID,
            cwd: originalRequest.workspaceRootPath ?? self.deps.configuration.transcriptWorkingDirectory,
            parentSession: sessionRecord?.parentSessionID
        )
        if isNewTranscript {
            let parent = sessionRecord?.parentSessionID
            await hooks.observe(.sessionStart) {
                SessionLifecycleHookEvent(sessionId: sessionID, sessionKey: originalRequest.sessionKey, resumedFrom: parent)
            }
        }

        // Model selection (`before_model_resolve`) and request shaping.
        let resolveAttachments = originalRequest.attachments.map { attachment in
            BeforeModelResolveAttachment(kind: MediaPipeline.classify(mimeType: attachment.mimeType).rawValue, mimeType: attachment.mimeType)
        }
        let modelOverride = await hooks.beforeModelResolve {
            BeforeModelResolveEvent(prompt: originalRequest.prompt, attachments: resolveAttachments.isEmpty ? nil : resolveAttachments)
        }
        let request = originalRequest.applyingModelOverride(modelOverride)
        let model = await self.resolveModelContext(request: request, session: sessionRecord)
        let usesContractV2 = model.usesContractV2

        // `before_agent_run` gate (fail-closed): a block persists the redacted user turn and fails the run.
        let priorMessages = try await transcript.contextMessages(sessionID: sessionID)
        let gate = await hooks.beforeAgentRun {
            BeforeAgentRunEvent(
                prompt: request.prompt,
                messages: AgentLoopHookEmitter.encode(priorMessages),
                systemPrompt: self.deps.configuration.baseSystemPrompt
            )
        }
        if case .block(let reason, let message, _, _) = gate {
            // The merged gate does not name the blocking plugin, so the hook name stands in (upstream uses
            // the same form when a handler fails).
            let blockText = AgentHookSystemContext.blockMessage(message, blockedBy: HookName.beforeAgentRun.rawValue)
            try await self.appendMessage(
                .user(AgentUserMessage(content: .blocks([.text(blockText)]), timestamp: SessionTranscriptClock.nowMs())),
                sessionID: sessionID,
                sessionKey: request.sessionKey,
                transcript: transcript,
                hooks: hooks,
                recorder: recorder
            )
            await self.emitDiagnostic("run.blocked", request: request, metadata: ["hook": HookName.beforeAgentRun.rawValue, "reason": reason])
            throw AgentRuntimeError.blocked(message: blockText)
        }

        // Inputs: attachments (with media understanding), workspace bootstrap and skills.
        let normalized = try await Self.normalizeAttachments(request.attachments, using: self.deps.mediaPipeline)
        let attachments = await self.applyMediaUnderstanding(normalized, model: model, request: request)
        let policy = Self.effectivePolicy(base: self.deps.tools.policy, request: request, session: sessionRecord)
        let workspace = try await self.prepareWorkspace(request: request, model: model, policy: policy, session: sessionRecord)
        await self.registerRunTools(attachments: normalized)
        let derivedTexts = attachments.compactMap(Self.derivedText(from:))
        let listedAttachments = attachments.filter { Self.derivedText(from: $0) == nil }
        let legacyPrompt = Self.composeLegacyPrompt(
            basePrompt: request.prompt,
            workspace: workspace,
            attachments: listedAttachments,
            derivedTexts: derivedTexts
        )
        var userText = request.prompt
        if !listedAttachments.isEmpty {
            userText += "\n\n" + Self.composeAttachmentSection(listedAttachments)
        }
        var userBlocks: [AgentContentBlock] = [.text(userText)]
        userBlocks.append(contentsOf: derivedTexts.map { AgentContentBlock.text($0) })
        userBlocks.append(contentsOf: listedAttachments.compactMap(AgentMessageConversion.imageBlock(from:)))
        let internalEvents = await self.deps.internalEvents(request.sessionKey)
        if !internalEvents.isEmpty {
            try await self.appendMessage(
                .custom(
                    customType: "internal_events",
                    content: .string(internalEvents.joined(separator: "\n\n")),
                    display: false,
                    timestamp: SessionTranscriptClock.nowMs()
                ),
                sessionID: sessionID,
                sessionKey: request.sessionKey,
                transcript: transcript,
                hooks: hooks,
                recorder: recorder
            )
        }
        let promptMessage: AgentMessage = request.hiddenPrompt
            ? .custom(customType: "hidden_prompt", content: .blocks(userBlocks), display: false, timestamp: SessionTranscriptClock.nowMs())
            : .user(AgentUserMessage(content: .blocks(userBlocks), timestamp: SessionTranscriptClock.nowMs()))
        try await self.appendMessage(
            promptMessage,
            sessionID: sessionID,
            sessionKey: request.sessionKey,
            transcript: transcript,
            hooks: hooks,
            recorder: recorder
        )

        // `before_prompt_build`: context and system-prompt contributions for every turn of the run.
        let promptBuildMessages = try await transcript.contextMessages(sessionID: sessionID)
        let promptBuild = AgentPromptBuildOverrides(
            await hooks.beforePromptBuild {
                BeforePromptBuildEvent(
                    prompt: request.prompt,
                    currentUserMessage: request.prompt,
                    messages: AgentLoopHookEmitter.encode(promptBuildMessages)
                )
            }
        )

        let context = AgentToolInvocationContext(runID: runID, sessionKey: request.sessionKey, agentID: agentID)
        var loopHistory: [String] = []

        // Forced pre-model tool calls (legacy `AgentRunRequest.toolCalls`).
        if !request.toolCalls.isEmpty {
            let calls = request.toolCalls.map { AgentToolCall(id: $0.id ?? AgentToolCall.makeID(), name: $0.name, arguments: $0.arguments) }
            let forced = AgentAssistantMessage(
                content: calls.map { .toolCall(AgentToolCallBlock(id: $0.id ?? "", name: $0.name, arguments: $0.arguments)) },
                provider: "openclawkit",
                model: "forced-tool-calls",
                stopReason: .toolUse,
                timestamp: SessionTranscriptClock.nowMs()
            )
            try await self.appendMessage(
                .assistant(forced),
                sessionID: sessionID,
                sessionKey: request.sessionKey,
                transcript: transcript,
                hooks: hooks,
                recorder: recorder
            )
            _ = try await self.executeBatch(
                calls,
                context: context,
                agentID: agentID,
                policy: policy,
                enforcePolicy: false,
                searchCatalog: nil,
                sessionID: sessionID,
                request: request,
                transcript: transcript,
                hooks: hooks,
                events: events,
                recorder: recorder,
                loopHistory: &loopHistory
            )
        }

        var finalText = ""
        var usageTotal = AgentTokenUsage.zero
        var lastProviderID: String?
        var lastModelID: String?
        var overflowRetried = false
        var iteration = 0
        var stopDetail: String?
        let accumulator = AgentStreamAccumulator()

        do {
            while true {
                try Task.checkCancellation()
                if iteration >= (request.maxToolIterations ?? self.deps.configuration.maxToolIterations) {
                    stopDetail = "max_tool_iterations"
                    break
                }
                iteration += 1

                let toolView = await self.toolView(policy: policy, model: model, session: sessionRecord, promptBuild: promptBuild)
                let descriptors = toolView.visible
                var contextMessages = try await transcript.contextMessages(sessionID: sessionID)
                let engine = await self.deps.contextEngines.selected()
                var systemAddition: String?
                if let engine {
                    let assembled = try await engine.assemble(
                        ContextAssembleParams(
                            sessionID: sessionID,
                            sessionKey: request.sessionKey,
                            messages: contextMessages,
                            tokenBudget: self.deps.configuration.contextWindowTokens,
                            availableTools: Set(descriptors.map(\.name)),
                            model: request.modelID,
                            prompt: request.prompt
                        )
                    )
                    contextMessages = assembled.messages
                    systemAddition = assembled.systemPromptAddition
                }

                if usesContractV2, let window = self.deps.configuration.contextWindowTokens, self.deps.configuration.compaction.enabled {
                    let estimated = TokenEstimator.estimate(contextMessages)
                        + TokenEstimator.estimateToolSchemas(descriptors.map { ($0.name, $0.description, $0.parameters) })
                    if estimated > window - self.deps.configuration.compaction.reserveTokens {
                        if try await self.compact(
                            trigger: .auto,
                            sessionID: sessionID,
                            request: request,
                            tokensBefore: estimated,
                            messageCount: contextMessages.count,
                            tokenBudget: nil,
                            hooks: hooks,
                            events: events
                        ) {
                            contextMessages = try await transcript.contextMessages(sessionID: sessionID)
                        }
                    }
                }

                let composedSystemPrompt = await self.composeSystemPrompt(
                    workspace: workspace,
                    request: request,
                    session: sessionRecord,
                    addition: systemAddition,
                    directory: toolView.catalog?.configuration.mode == .directory ? toolView.catalog?.directoryPrompt() : nil,
                    promptContext: AgentPromptContext(
                        runID: runID,
                        sessionKey: request.sessionKey,
                        agentID: agentID,
                        session: sessionRecord,
                        providerID: model.providerID,
                        modelID: model.modelID,
                        capabilities: model.capabilities,
                        availableToolNames: Set(descriptors.map(\.name))
                    )
                )
                let systemPrompt = promptBuild.systemPrompt(base: composedSystemPrompt)
                let modelMessages = usesContractV2
                    ? promptBuild.wrapLastUserMessage(AgentMessageConversion.modelMessages(from: contextMessages))
                    : []
                let modelTools = usesContractV2 && model.capabilities.supportsTools ? descriptors.modelToolDefinitions : []
                let modelRequest = self.makeModelRequest(
                    from: request,
                    model: model,
                    runStartedAt: startedAt,
                    legacyPrompt: promptBuild.wrapPrompt(legacyPrompt),
                    systemPrompt: usesContractV2 ? systemPrompt : nil,
                    messages: modelMessages,
                    tools: modelTools,
                    streamTokens: streaming
                )
                let callProvider = model.providerID ?? request.modelProviderID ?? ""
                let callModel = model.modelID ?? request.modelID ?? ""
                let callID = "\(runID):\(iteration)"
                await hooks.observe(.llmInput) {
                    LLMInputHookEvent(
                        runId: runID,
                        sessionId: sessionID,
                        provider: callProvider,
                        model: callModel,
                        systemPrompt: modelRequest.systemPrompt,
                        prompt: request.prompt,
                        historyMessages: AgentLoopHookEmitter.encode(modelMessages),
                        imagesCount: Self.imageCount(modelMessages, attachments: modelRequest.attachments),
                        tools: modelTools.isEmpty ? nil : modelTools.compactMap { HookPayloadCoding.encode($0) }
                    )
                }
                await hooks.observe(.modelCallStarted) {
                    ModelCallHookEvent(runId: runID, callId: callID, sessionKey: request.sessionKey, provider: callProvider, model: callModel)
                }
                let callStartedAt = SessionTranscriptClock.nowMs()

                let response: ModelGenerationResponse
                do {
                    if streaming {
                        response = try await self.streamModel(
                            modelRequest,
                            providerID: callProvider,
                            iteration: iteration,
                            runID: runID,
                            accumulator: accumulator,
                            events: events
                        )
                    } else {
                        response = try await self.deps.modelRouter.generate(modelRequest)
                    }
                } catch where !(error is CancellationError) && CompactionPlanner.isContextOverflowError(error) && !overflowRetried && usesContractV2 {
                    await Self.observeModelCallEnded(
                        hooks,
                        runID: runID,
                        callID: callID,
                        request: request,
                        provider: callProvider,
                        model: callModel,
                        startedAt: callStartedAt,
                        error: error
                    )
                    overflowRetried = true
                    iteration -= 1
                    let overflow = error as? any ModelContextOverflowReporting
                    let estimated = overflow?.overflowTokenCount ?? TokenEstimator.estimate(contextMessages)
                    let budget = overflow?.overflowContextSize.map { max(1, $0 - self.deps.configuration.compaction.reserveTokens) }
                    _ = try await self.compact(
                        trigger: .overflow,
                        sessionID: sessionID,
                        request: request,
                        tokensBefore: estimated,
                        messageCount: contextMessages.count,
                        tokenBudget: budget,
                        hooks: hooks,
                        events: events
                    )
                    continue
                } catch {
                    await Self.observeModelCallEnded(
                        hooks,
                        runID: runID,
                        callID: callID,
                        request: request,
                        provider: callProvider,
                        model: callModel,
                        startedAt: callStartedAt,
                        error: error
                    )
                    throw error
                }
                await Self.observeModelCallEnded(
                    hooks,
                    runID: runID,
                    callID: callID,
                    request: request,
                    provider: response.providerID,
                    model: response.modelID ?? callModel,
                    startedAt: callStartedAt,
                    error: nil
                )

                try Task.checkCancellation()
                lastProviderID = response.providerID
                lastModelID = response.modelID
                let visible = ProviderVisibleTextSanitizer.sanitizeVisibleText(response.text)
                let reasoningEffort = model.thinkingLevel?.rawValue
                await hooks.observe(.llmOutput) {
                    LLMOutputHookEvent(
                        runId: runID,
                        sessionId: sessionID,
                        provider: response.providerID,
                        model: response.modelID ?? callModel,
                        assistantTexts: visible.isEmpty ? [] : [visible],
                        usage: AgentLoopHookEmitter.usageMap(response.usage),
                        reasoningEffort: reasoningEffort
                    )
                }
                if !streaming {
                    let itemID = "\(runID):assistant:\(iteration)"
                    if let reasoning = response.reasoningText, !reasoning.isEmpty {
                        events.emit(.thinking, ["itemId": AnyCodable(itemID), "text": AnyCodable(reasoning), "delta": AnyCodable(reasoning)])
                    }
                    if !visible.isEmpty {
                        events.emit(.assistant, ["itemId": AnyCodable(itemID), "text": AnyCodable(visible), "delta": AnyCodable(visible)])
                    }
                }
                // Tools the provider already ran in-process are recorded before the final answer.
                if !response.executedToolCalls.isEmpty {
                    try await self.recordExecutedToolCalls(
                        response,
                        sessionID: sessionID,
                        request: request,
                        transcript: transcript,
                        hooks: hooks,
                        events: events,
                        recorder: recorder
                    )
                }
                let assistant = AgentMessageConversion.assistantMessage(
                    from: response,
                    visibleText: visible,
                    timestamp: SessionTranscriptClock.nowMs()
                )
                try await self.appendMessage(
                    .assistant(assistant),
                    sessionID: sessionID,
                    sessionKey: request.sessionKey,
                    transcript: transcript,
                    hooks: hooks,
                    recorder: recorder
                )
                if let usage = response.usage {
                    let turnUsage = AgentMessageConversion.tokenUsage(from: usage)
                    usageTotal = usageTotal + turnUsage
                    events.emit(.usage, [
                        "input": AnyCodable(turnUsage.input),
                        "output": AnyCodable(turnUsage.output),
                        "cacheRead": AnyCodable(turnUsage.cacheRead),
                        "cacheWrite": AnyCodable(turnUsage.cacheWrite),
                        "totalTokens": AnyCodable(turnUsage.totalTokens),
                    ])
                }
                if !visible.isEmpty {
                    finalText = visible
                }
                guard usesContractV2, !response.toolCalls.isEmpty else {
                    break
                }
                let calls = response.toolCalls.map(AgentToolCall.init)
                let results = try await self.executeBatch(
                    calls,
                    context: context,
                    agentID: agentID,
                    policy: policy,
                    enforcePolicy: true,
                    searchCatalog: toolView.catalog,
                    sessionID: sessionID,
                    request: request,
                    transcript: transcript,
                    hooks: hooks,
                    events: events,
                    recorder: recorder,
                    loopHistory: &loopHistory
                )
                if !results.isEmpty, results.allSatisfy(\.output.terminate) {
                    stopDetail = "tool_terminate"
                    break
                }
            }
        } catch {
            try? await self.recordInterruptedTurn(
                error: error,
                control: control,
                accumulator: accumulator,
                sessionID: sessionID,
                request: request,
                transcript: transcript
            )
            throw error
        }

        events.emit(.lifecycle, ["phase": AnyCodable("finishing")])
        if let engine = await self.deps.contextEngines.selected() {
            await engine.afterTurn(sessionID: sessionID, sessionKey: request.sessionKey)
        }
        if usageTotal.totalTokens > 0 {
            await self.deps.sessionStore?.recordUsage(tokens: Int64(usageTotal.totalTokens), forKey: request.sessionKey)
        }
        var replyCancelled = false
        if self.deps.configuration.emitsReplyHooks, !finalText.isEmpty {
            let draft = finalText
            let sending = await hooks.messageSending {
                MessageSendingEvent(to: request.sessionKey, content: draft, metadata: ["runId": AnyCodable(runID)])
            }
            if sending?.cancel == true {
                replyCancelled = true
                finalText = ""
            } else if let rewritten = sending?.content {
                finalText = rewritten
            }
            let sent = finalText
            let cancelled = replyCancelled
            let cancelReason = sending?.cancelReason
            await hooks.observe(.messageSent) {
                MessageSentHookEvent(
                    to: request.sessionKey,
                    content: sent,
                    success: !cancelled,
                    sessionKey: request.sessionKey,
                    error: cancelled ? (cancelReason ?? "cancelled by message_sending") : nil
                )
            }
        }
        recorder.record(AgentRunEvent(runID: runID, kind: .runCompleted))
        var endData: [String: AnyCodable] = [
            "phase": AnyCodable("end"),
            "startedAt": AnyCodable(startedAt),
            "endedAt": AnyCodable(SessionTranscriptClock.nowMs()),
            "iterations": AnyCodable(iteration),
        ]
        if let stopDetail {
            endData["reason"] = AnyCodable(stopDetail)
        }
        if let lastProviderID {
            endData["provider"] = AnyCodable(lastProviderID)
        }
        if let lastModelID {
            endData["model"] = AnyCodable(lastModelID)
        }
        if replyCancelled {
            endData["replyCancelled"] = AnyCodable(true)
        }
        events.emit(.lifecycle, endData)
        let snapshot = recorder.snapshot
        return AgentRunResult(
            runID: runID,
            sessionKey: request.sessionKey,
            output: finalText,
            toolResults: snapshot.results,
            events: snapshot.events,
            attachments: attachments,
            providerID: lastProviderID,
            modelID: lastModelID,
            sessionID: sessionID,
            usage: usageTotal,
            iterations: iteration
        )
    }

    // MARK: - Model resolution

    /// Resolves the serving provider, model, capabilities, thinking level and fast mode once per run.
    func resolveModelContext(request: AgentRunRequest, session: SessionRecord?) async -> AgentRunModelContext {
        let probe = ModelGenerationRequest(
            sessionKey: request.sessionKey,
            prompt: request.prompt,
            providerID: request.modelProviderID,
            modelID: request.modelID
        )
        let primary = await self.deps.modelRouter.primaryProvider(for: probe)
        let providerID = primary?.id ?? request.modelProviderID
        let providerConfig = providerID.flatMap { self.providerConfig(for: $0) }
        let modelID = request.modelID ?? providerConfig?.defaultModel?.id
        let definition: ModelDefinitionConfig? = modelID.flatMap { id in
            providerConfig?.models.first { $0.id == id }
                ?? providerID.flatMap { OpenClawReferenceProviderCatalog.catalogModel(providerID: $0, modelID: id)?.definitionConfig() }
        }
        let requestedThinking = request.thinkingLevel ?? session?.thinkingLevel
        let thinking = Self.resolveThinkingLevel(
            requestedThinking,
            providerID: providerID,
            modelID: modelID,
            agentRuntime: self.deps.configuration.agentRuntimeID
        )
        let fastMode: FastMode? = request.fastMode.map(FastMode.init(enabled:))
            ?? session?.fastModeSetting.flatMap { FastMode(rawValue: $0.rawValue) }
            ?? self.deps.configuration.fastModeDefault
        return AgentRunModelContext(
            providerID: providerID,
            modelID: modelID,
            capabilities: primary?.capabilities ?? .legacy,
            providerConfig: providerConfig,
            modelDefinition: definition,
            thinkingLevel: thinking,
            fastMode: fastMode
        )
    }

    /// Configured provider config, else the reference catalog's. Apple Foundation Models uses the
    /// probed on-device model facts (OS 27 vision adds image input) over the static catalog row.
    func providerConfig(for providerID: String) -> ModelProviderConfig? {
        let configs = self.deps.configuration.providerConfigs
        if let config = configs[providerID] {
            return config
        }
        let canonical = OpenClawReferenceProviderCatalog.normalize(providerID: providerID)
        if let config = configs[canonical] {
            return config
        }
        let catalog = OpenClawReferenceProviderCatalog.entry(for: canonical)?.config
        guard FoundationModelsProvider.handles(providerID: canonical), var config = catalog else {
            return catalog
        }
        let facts = FoundationModelsProvider.systemModelFacts()
        if facts.available, let index = config.models.firstIndex(where: { $0.id == FoundationModelsProvider.systemModelID }) {
            config.models[index] = FoundationModelsProvider.modelDefinition(facts: facts)
        }
        return config
    }

    /// Clamps a thinking level to what a catalog-known model supports (upstream
    /// `resolveSupportedThinkingLevelFromProfile`); unknown models keep the requested level. `ultra`
    /// is runtime orchestration only, so transports receive `max`.
    static func resolveThinkingLevel(_ level: ThinkLevel?, providerID: String?, modelID: String?, agentRuntime: String?) -> ThinkLevel? {
        guard let level else { return nil }
        guard let providerID, let modelID,
              OpenClawReferenceProviderCatalog.catalogModel(providerID: providerID, modelID: modelID) != nil
        else {
            return level.providerTransportLevel
        }
        let profile = OpenClawReferenceProviderCatalog.thinkingProfile(providerID: providerID, modelID: modelID, agentRuntime: agentRuntime)
        return profile.resolveSupported(level).providerTransportLevel
    }

    // MARK: - Model

    func streamModel(
        _ request: ModelGenerationRequest,
        providerID: String,
        iteration: Int,
        runID: String,
        accumulator: AgentStreamAccumulator,
        events: AgentEventSequencer
    ) async throws -> ModelGenerationResponse {
        let itemID = "\(runID):assistant:\(iteration)"
        let stream = await self.deps.modelRouter.generateStream(request)
        let turnAccumulator = AgentStreamAccumulator()
        var partialCalls: [Int: (id: String?, name: String?, arguments: String)] = [:]
        var finalCalls: [ModelToolCall] = []
        var executedCalls: [ModelExecutedToolCall] = []
        var usage: ModelUsage?
        var stopReason: ModelStopReason?
        var reasoningSignature: String?
        for try await chunk in stream {
            try Task.checkCancellation()
            // Text deltas accumulate; the `.final` chunk usually carries no text.
            if !chunk.text.isEmpty {
                _ = accumulator.appendText(chunk.text)
                let update = turnAccumulator.appendText(chunk.text)
                if !update.delta.isEmpty || update.replace {
                    var data: [String: AnyCodable] = [
                        "itemId": AnyCodable(itemID),
                        "text": AnyCodable(update.visible),
                        "delta": AnyCodable(update.delta),
                    ]
                    if update.replace {
                        data["replace"] = AnyCodable(true)
                    }
                    events.emit(.assistant, data)
                }
            }
            if let reasoning = chunk.reasoningText, !reasoning.isEmpty {
                let text = turnAccumulator.appendReasoning(reasoning)
                events.emit(.thinking, ["itemId": AnyCodable(itemID), "text": AnyCodable(text), "delta": AnyCodable(reasoning)])
            }
            if let delta = chunk.toolCallDelta {
                var partial = partialCalls[delta.index] ?? (nil, nil, "")
                partial.id = partial.id ?? delta.id
                partial.name = partial.name ?? delta.name
                partial.arguments += delta.argumentsDelta
                partialCalls[delta.index] = partial
            }
            if let chunkUsage = chunk.usage {
                usage = chunkUsage
            }
            if let signature = chunk.reasoningSignature, !signature.isEmpty {
                reasoningSignature = signature
            }
            if !chunk.executedToolCalls.isEmpty {
                executedCalls = chunk.executedToolCalls
            }
            if chunk.isFinal {
                stopReason = chunk.stopReason ?? stopReason
                if !chunk.toolCalls.isEmpty {
                    finalCalls = chunk.toolCalls
                }
            }
        }
        // Stream iteration ends silently when the task is cancelled; surface the cancellation.
        try Task.checkCancellation()
        if finalCalls.isEmpty, !partialCalls.isEmpty {
            finalCalls = partialCalls.keys.sorted().compactMap { index in
                guard let partial = partialCalls[index], let name = partial.name else { return nil }
                var repairer = ToolCallArgumentRepairer()
                let arguments = (try? repairer.parseArguments(partial.arguments, provider: .anthropicCompatible)) ?? [:]
                return ModelToolCall(id: partial.id ?? AgentToolCall.makeID(), name: name, arguments: arguments)
            }
        }
        return ModelGenerationResponse(
            text: turnAccumulator.rawText,
            providerID: providerID.isEmpty ? (request.providerID ?? "stream") : providerID,
            modelID: request.modelID,
            toolCalls: finalCalls,
            usage: usage,
            stopReason: stopReason,
            reasoningText: turnAccumulator.reasoningText.isEmpty ? nil : turnAccumulator.reasoningText,
            reasoningSignature: reasoningSignature,
            executedToolCalls: executedCalls
        )
    }

    static func observeModelCallEnded(
        _ hooks: AgentLoopHookEmitter,
        runID: String,
        callID: String,
        request: AgentRunRequest,
        provider: String,
        model: String,
        startedAt: Int64,
        error: Error?
    ) async {
        let duration = Int(max(0, SessionTranscriptClock.nowMs() - startedAt))
        let category: String? = error.map { error in
            if error is CancellationError { return "aborted" }
            return CompactionPlanner.isContextOverflowError(error) ? "context_overflow" : "provider_error"
        }
        await hooks.observe(.modelCallEnded) {
            ModelCallHookEvent(
                runId: runID,
                callId: callID,
                sessionKey: request.sessionKey,
                provider: provider,
                model: model,
                durationMs: duration,
                outcome: error == nil ? "completed" : "error",
                errorCategory: category
            )
        }
    }

    func compact(
        trigger: ContextCompactionTrigger,
        sessionID: String,
        request: AgentRunRequest,
        tokensBefore: Int,
        messageCount: Int,
        tokenBudget: Int?,
        hooks: AgentLoopHookEmitter,
        events: AgentEventSequencer
    ) async throws -> Bool {
        guard let engine = await self.deps.contextEngines.selected() else { return false }
        events.emit(.compaction, ["phase": AnyCodable("start"), "trigger": AnyCodable(trigger.rawValue), "tokensBefore": AnyCodable(tokensBefore)])
        await self.deps.hooks.onCompaction?(request.sessionKey, trigger, tokensBefore, nil)
        await hooks.observe(.beforeCompaction, metadata: ["trigger": AnyCodable(trigger.rawValue)]) {
            CompactionHookEvent(sessionKey: request.sessionKey, messageCount: messageCount, tokensBefore: tokensBefore)
        }
        let result = try await engine.compact(
            ContextCompactParams(
                sessionID: sessionID,
                sessionKey: request.sessionKey,
                tokenBudget: tokenBudget ?? self.deps.configuration.contextWindowTokens.map { $0 - self.deps.configuration.compaction.reserveTokens },
                force: trigger != .auto,
                currentTokenCount: tokensBefore,
                trigger: trigger,
                sessionModel: request.modelID.map { model in request.modelProviderID.map { "\($0)/\(model)" } ?? model }
            )
        )
        var data: [String: AnyCodable] = [
            "phase": AnyCodable("end"),
            "trigger": AnyCodable(trigger.rawValue),
            "tokensBefore": AnyCodable(result.tokensBefore),
            "compacted": AnyCodable(result.compacted),
        ]
        if let tokensAfter = result.tokensAfter {
            data["tokensAfter"] = AnyCodable(tokensAfter)
        }
        if let reason = result.reason {
            data["reason"] = AnyCodable(reason)
        }
        events.emit(.compaction, data)
        await self.deps.hooks.onCompaction?(request.sessionKey, trigger, result.tokensBefore, result.tokensAfter ?? result.tokensBefore)
        await hooks.observe(.afterCompaction, metadata: ["trigger": AnyCodable(trigger.rawValue), "compacted": AnyCodable(result.compacted)]) {
            CompactionHookEvent(
                sessionKey: request.sessionKey,
                messageCount: messageCount,
                tokensBefore: result.tokensBefore,
                tokensAfter: result.tokensAfter ?? result.tokensBefore
            )
        }
        return result.compacted
    }
}

extension AgentRunRequest {
    /// Copy with `before_model_resolve` overrides applied (a `provider/model` model override also sets
    /// the provider).
    func applyingModelOverride(_ result: BeforeModelResolveResult?) -> AgentRunRequest {
        guard let result else { return self }
        var providerID = result.providerOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        var modelID = result.modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        if let model = modelID, providerID == nil {
            let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, OpenClawReferenceProviderCatalog.entry(for: parts[0]) != nil {
                providerID = parts[0]
                modelID = parts[1]
            }
        }
        guard providerID != nil || modelID != nil else { return self }
        return AgentRunRequest(
            runID: self.runID,
            sessionKey: self.sessionKey,
            prompt: self.prompt,
            toolCalls: self.toolCalls,
            modelProviderID: providerID ?? self.modelProviderID,
            modelID: modelID ?? self.modelID,
            thinkingLevel: self.thinkingLevel,
            reasoningLevel: self.reasoningLevel,
            verboseLevel: self.verboseLevel,
            responseUsage: self.responseUsage,
            elevatedLevel: self.elevatedLevel,
            fastMode: self.fastMode,
            workspaceRootPath: self.workspaceRootPath,
            attachments: self.attachments,
            agentID: self.agentID,
            toolPolicy: self.toolPolicy,
            maxToolIterations: self.maxToolIterations,
            extraSystemPrompt: self.extraSystemPrompt,
            sessionID: self.sessionID,
            spawnedBy: self.spawnedBy,
            modelTimeoutMs: self.modelTimeoutMs,
            hiddenPrompt: self.hiddenPrompt
        )
    }
}

extension String {
    /// `nil` when empty.
    var nonEmpty: String? {
        self.isEmpty ? nil : self
    }
}
