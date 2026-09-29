import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawMedia
import OpenClawModels
import OpenClawProtocol
import OpenClawSkills

/// Errors surfaced by the embedded agent runtime.
public enum AgentRuntimeError: Error, LocalizedError, Sendable {
    /// A requested tool name is not registered.
    case toolNotFound(String)
    /// A run exceeded the configured timeout window.
    case timedOut(runID: String)
    /// A run was aborted with ``EmbeddedAgentRuntime/abort(runID:)``.
    case aborted(runID: String)
    /// The operation needs a transcript store and the runtime has none.
    case transcriptUnavailable
    /// A `before_agent_run` hook blocked the run; `message` is the user-facing block message that
    /// replaced the prompt in the transcript.
    case blocked(message: String)

    /// Human-readable message.
    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .timedOut(let runID):
            return "Agent run timed out: \(runID)"
        case .aborted(let runID):
            return "Agent run aborted: \(runID)"
        case .transcriptUnavailable:
            return "This runtime has no session transcript store"
        case .blocked(let message):
            return message
        }
    }
}

/// Timeline event emitted during agent run execution (legacy summary of the run).
public struct AgentRunEvent: Sendable, Equatable {
    /// Event kinds emitted by a run.
    public enum Kind: String, Sendable {
        case runStarted
        case toolStarted
        case toolCompleted
        case runCompleted
    }

    public let runID: String
    public let kind: Kind
    public let toolName: String?

    /// Creates a run lifecycle event.
    /// - Parameters:
    ///   - runID: Correlated run identifier.
    ///   - kind: Event type.
    ///   - toolName: Optional tool associated with event.
    public init(runID: String, kind: Kind, toolName: String? = nil) {
        self.runID = runID
        self.kind = kind
        self.toolName = toolName
    }
}

/// Input payload for a single agent run.
public struct AgentRunRequest: Sendable {
    public let runID: String
    public let sessionKey: String
    public let prompt: String
    /// Forced tool calls executed before the first model turn.
    public let toolCalls: [AgentToolCall]
    public let modelProviderID: String?
    public let modelID: String?
    public let thinkingLevel: ThinkLevel?
    public let reasoningLevel: ReasoningLevel?
    public let verboseLevel: VerboseLevel?
    public let responseUsage: UsageDisplayLevel?
    public let elevatedLevel: ElevatedLevel?
    public let fastMode: Bool?
    public let workspaceRootPath: String?
    public let attachments: [MediaAttachment]
    /// Agent identifier (defaults to the runtime default agent).
    public let agentID: String?
    /// Per-run tool policy replacing the runtime policy.
    public let toolPolicy: ToolPolicy?
    /// Per-run cap on model turns (defaults to ``AgentLoopConfiguration/maxToolIterations``).
    public let maxToolIterations: Int?
    /// Extra system-prompt section for this run (for example a sub-agent task brief).
    public let extraSystemPrompt: String?
    /// Transcript session to use when the runtime has no session store.
    public let sessionID: String?
    /// Parent session key for spawned (sub-agent) runs.
    public let spawnedBy: String?
    /// Per-model-call timeout hint (ms) forwarded to providers.
    public let modelTimeoutMs: Int?
    /// Record the prompt as a hidden instruction (not shown in chat history) instead of a user message.
    public let hiddenPrompt: Bool

    /// Creates a run request.
    /// - Parameters:
    ///   - runID: Optional external run identifier.
    ///   - sessionKey: Session key used for routing/memory.
    ///   - prompt: User prompt payload.
    ///   - toolCalls: Ordered tool calls to execute before model generation.
    ///   - modelProviderID: Optional provider override.
    ///   - workspaceRootPath: Optional workspace root for skill/bootstrap prompt injection.
    ///   - attachments: Optional multimodal attachments to normalize and reference in prompt context.
    ///   - agentID: Agent identifier.
    ///   - toolPolicy: Per-run tool policy.
    ///   - maxToolIterations: Per-run iteration cap.
    ///   - extraSystemPrompt: Extra system-prompt section.
    ///   - sessionID: Transcript session override.
    ///   - spawnedBy: Parent session key for spawned runs.
    ///   - modelTimeoutMs: Per-model-call timeout hint.
    ///   - hiddenPrompt: Record the prompt as a hidden instruction.
    public init(
        runID: String = UUID().uuidString,
        sessionKey: String,
        prompt: String,
        toolCalls: [AgentToolCall] = [],
        modelProviderID: String? = nil,
        modelID: String? = nil,
        thinkingLevel: ThinkLevel? = nil,
        reasoningLevel: ReasoningLevel? = nil,
        verboseLevel: VerboseLevel? = nil,
        responseUsage: UsageDisplayLevel? = nil,
        elevatedLevel: ElevatedLevel? = nil,
        fastMode: Bool? = nil,
        workspaceRootPath: String? = nil,
        attachments: [MediaAttachment] = [],
        agentID: String? = nil,
        toolPolicy: ToolPolicy? = nil,
        maxToolIterations: Int? = nil,
        extraSystemPrompt: String? = nil,
        sessionID: String? = nil,
        spawnedBy: String? = nil,
        modelTimeoutMs: Int? = nil,
        hiddenPrompt: Bool = false
    ) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.prompt = prompt
        self.toolCalls = toolCalls
        self.modelProviderID = modelProviderID
        self.modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.thinkingLevel = thinkingLevel
        self.reasoningLevel = reasoningLevel
        self.verboseLevel = verboseLevel
        self.responseUsage = responseUsage
        self.elevatedLevel = elevatedLevel
        self.fastMode = fastMode
        self.workspaceRootPath = workspaceRootPath
        self.attachments = attachments
        self.agentID = agentID
        self.toolPolicy = toolPolicy
        self.maxToolIterations = maxToolIterations.map { max(1, $0) }
        self.extraSystemPrompt = extraSystemPrompt
        self.sessionID = sessionID
        self.spawnedBy = spawnedBy
        self.modelTimeoutMs = modelTimeoutMs
        self.hiddenPrompt = hiddenPrompt
    }
}

/// Output payload for a completed agent run.
public struct AgentRunResult: Sendable {
    public let runID: String
    public let sessionKey: String
    /// Visible text of the final assistant turn.
    public let output: String
    public let toolResults: [AgentToolResult]
    public let events: [AgentRunEvent]
    public let attachments: [MediaAttachment]
    /// Provider that answered the last model turn.
    public let providerID: String?
    /// Model that answered the last model turn.
    public let modelID: String?
    /// Transcript session of the run.
    public let sessionID: String?
    /// Token usage summed over every model turn.
    public let usage: AgentTokenUsage
    /// Number of model turns.
    public let iterations: Int

    /// Creates a run result.
    /// - Parameters:
    ///   - runID: Run identifier.
    ///   - sessionKey: Session key resolved for the run.
    ///   - output: Model output text.
    ///   - toolResults: Tool execution outputs.
    ///   - events: Lifecycle events emitted during run.
    ///   - attachments: Normalized multimodal attachments used during prompt generation.
    ///   - providerID: Provider of the last model turn.
    ///   - modelID: Model of the last model turn.
    ///   - sessionID: Transcript session.
    ///   - usage: Summed token usage.
    ///   - iterations: Model turns.
    public init(
        runID: String,
        sessionKey: String,
        output: String,
        toolResults: [AgentToolResult],
        events: [AgentRunEvent],
        attachments: [MediaAttachment] = [],
        providerID: String? = nil,
        modelID: String? = nil,
        sessionID: String? = nil,
        usage: AgentTokenUsage = .zero,
        iterations: Int = 0
    ) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.output = output
        self.toolResults = toolResults
        self.events = events
        self.attachments = attachments
        self.providerID = providerID
        self.modelID = modelID
        self.sessionID = sessionID
        self.usage = usage
        self.iterations = iterations
    }
}

/// Output payload for runs executed with an intent graph.
public struct IntentGraphRunResult: Sendable {
    /// Intent graph used to represent this run plan.
    public let graph: IntentGraph
    /// Completed run payload.
    public let result: AgentRunResult

    /// Creates an intent-graph run result.
    /// - Parameters:
    ///   - graph: Intent graph generated for the run.
    ///   - result: Completed run payload.
    public init(graph: IntentGraph, result: AgentRunResult) {
        self.graph = graph
        self.result = result
    }
}

/// Stream chunk emitted during a streaming agent run.
public struct AgentRunStreamChunk: Sendable, Equatable {
    /// Correlated run identifier.
    public let runID: String
    /// Session key for this run.
    public let sessionKey: String
    /// Incremental text payload.
    public let text: String
    /// Indicates whether this is the terminal stream chunk.
    public let isFinal: Bool

    /// Creates a stream chunk payload.
    /// - Parameters:
    ///   - runID: Correlated run identifier.
    ///   - sessionKey: Session key.
    ///   - text: Incremental text.
    ///   - isFinal: Terminal marker.
    public init(runID: String, sessionKey: String, text: String, isFinal: Bool) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.text = text
        self.isFinal = isFinal
    }
}

/// Deterministic transcript session ids for session keys when no session store assigns one.
public enum SessionTranscriptIdentity {
    /// File-safe transcript id derived from a session key (`key-<fnv1a64 hex>`).
    /// - Parameter key: Session key.
    /// - Returns: Stable session id.
    public static func sessionID(forKey key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "key-" + String(hash, radix: 16)
    }
}

/// Per-session serial lanes: runs on the same session key never interleave transcript writes.
actor AgentSessionLanes {
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: String) async {
        if self.busy.insert(key).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: String) {
        if var queue = self.waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            self.waiters[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            self.busy.remove(key)
        }
    }

    func isBusy(_ key: String) -> Bool {
        self.busy.contains(key)
    }
}

/// Fan-out of runtime-wide agent events.
final class AgentEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<AgentEventFrame>.Continuation] = [:]

    func subscribe(bufferingNewest limit: Int) -> AsyncStream<AgentEventFrame> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AgentEventFrame>.makeStream(bufferingPolicy: .bufferingNewest(max(1, limit)))
        self.lock.lock()
        self.subscribers[id] = continuation
        self.lock.unlock()
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    func publish(_ frame: AgentEventFrame) {
        self.lock.lock()
        let continuations = Array(self.subscribers.values)
        self.lock.unlock()
        for continuation in continuations {
            continuation.yield(frame)
        }
    }

    private func remove(_ id: UUID) {
        self.lock.lock()
        self.subscribers[id] = nil
        self.lock.unlock()
    }
}

/// Actor that runs model-driven agent loops with tool calling, session lanes and streaming events.
///
/// A run appends the user message to the session transcript, calls the routed model with the
/// policy-filtered tools, executes proposed tool calls (schema validation, hooks, approvals), feeds
/// results back, and repeats until the model stops calling tools (see ``AgentLoopConfiguration``).
/// Providers that predate model contract v2 (``ModelProviderCapabilities/legacy``) receive the
/// legacy single prompt and answer in one turn.
///
/// - Transcripts: pass a ``SessionTranscriptStore`` to keep multi-turn history; without one, each
///   run uses a throwaway in-memory transcript (2026.2 behavior).
/// - Gateway: the runtime no longer connects to `ws://127.0.0.1:18789` or sends `agent.run`;
///   `gatewayClient` is an optional dependency for tools that talk to a remote gateway.
public actor EmbeddedAgentRuntime {
    private struct ActiveRun {
        let task: Task<AgentRunResult, Error>
        let control: AgentRunControl
        let sessionKey: String
        let startedAt: Int64
        let spawnedBy: String?
        /// Per-run tool policy of the request (inherited by sub-agents and wake runs).
        let toolPolicy: ToolPolicy?
        /// Agent of the request.
        let agentID: String?
        /// Run timeout timer, cancelled when the run finishes.
        var timeoutTask: Task<Void, Never>?
    }

    /// Optional gateway client for tools that need a remote gateway.
    nonisolated public let gatewayClient: GatewayClient?
    /// Tool registry.
    nonisolated public let toolRegistry: AgentToolRegistry
    /// Model router.
    nonisolated public let modelRouter: ModelRouter
    /// Session store (optional).
    nonisolated public let sessionStore: SessionStore?
    /// Transcript store (optional).
    nonisolated public let transcriptStore: (any SessionTranscriptStore)?
    /// Approval broker.
    nonisolated public let approvals: ApprovalBroker
    /// Question broker.
    nonisolated public let questions: QuestionBroker
    /// Context engines.
    nonisolated public let contextEngines: ContextEngineRegistry
    /// Default agent id.
    nonisolated public let defaultAgentID: String
    /// Shared typed hook registry (plugins register handlers here); `nil` when hooks are disabled.
    nonisolated public let hookRegistry: HookRegistry?

    private let mediaPipeline: MediaPipeline
    private let mediaServices: MediaUnderstandingServices
    private let diagnosticsSink: RuntimeDiagnosticSink?
    private var toolsConfiguration: AgentToolsConfiguration
    private var loopConfiguration: AgentLoopConfiguration
    private var hooks: AgentLoopHooks
    private let lanes = AgentSessionLanes()
    private let eventHub = AgentEventHub()
    private var activeRuns: [String: ActiveRun] = [:]
    private var completedRuns: [String: AgentRunWaitResult] = [:]
    private var completedOrder: [String] = []
    private var runWaiters: [String: [UUID: CheckedContinuation<AgentRunWaitResult?, Never>]] = [:]
    private var internalEventQueues: [String: [String]] = [:]
    /// Sessions that yielded (`sessions_yield`) and wait for the next sub-agent completion.
    private var yieldedSessions: Set<String> = []
    private var promptContributors: [@Sendable (AgentPromptContext) async -> String?] = []
    private static let completedRunLimit = 512

    /// Creates an embedded runtime.
    /// - Parameters:
    ///   - gatewayClient: Optional gateway client for tools that need a remote gateway.
    ///   - toolRegistry: Registry used to resolve tool calls (defaults to one holding `llm-task`).
    ///   - modelRouter: Router for model provider selection.
    ///   - mediaPipeline: Media pipeline used to normalize multimodal attachments.
    ///   - diagnosticsSink: Optional diagnostics event sink.
    ///   - sessionStore: Optional session store (assigns transcript session ids, records usage).
    ///   - transcriptStore: Optional transcript store for multi-turn history.
    ///   - approvalBroker: Approval broker.
    ///   - questionBroker: Question broker.
    ///   - contextEngines: Context engine registry (defaults to the legacy engine when a transcript store exists).
    ///   - toolsConfiguration: Tool policy, loop detection and tool search settings.
    ///   - loopConfiguration: Loop settings.
    ///   - hooks: Loop closure hooks.
    ///   - hookRegistry: Shared typed hook registry; runs emit the lifecycle hooks (`before_agent_run`,
    ///     `before_model_resolve`, `before_prompt_build`, `llm_input`/`llm_output`, `before_tool_call`,
    ///     `after_tool_call`, `tool_result_persist`, `before_message_write`, `message_sending`/`message_sent`,
    ///     compaction, session lifecycle and `agent_end`).
    ///   - defaultAgentID: Default agent id.
    ///   - mediaUnderstandingServices: On-device services converting media the model cannot read.
    public init(
        gatewayClient: GatewayClient? = nil,
        toolRegistry: AgentToolRegistry? = nil,
        modelRouter: ModelRouter = ModelRouter(),
        mediaPipeline: MediaPipeline = MediaPipeline(),
        diagnosticsSink: RuntimeDiagnosticSink? = nil,
        sessionStore: SessionStore? = nil,
        transcriptStore: (any SessionTranscriptStore)? = nil,
        approvalBroker: ApprovalBroker = ApprovalBroker(),
        questionBroker: QuestionBroker = QuestionBroker(),
        contextEngines: ContextEngineRegistry? = nil,
        toolsConfiguration: AgentToolsConfiguration = AgentToolsConfiguration(),
        loopConfiguration: AgentLoopConfiguration = AgentLoopConfiguration(),
        hooks: AgentLoopHooks = AgentLoopHooks(),
        hookRegistry: HookRegistry? = nil,
        defaultAgentID: String = SessionKey.defaultAgentID,
        mediaUnderstandingServices: MediaUnderstandingServices = .platformDefault
    ) {
        self.gatewayClient = gatewayClient
        self.modelRouter = modelRouter
        self.mediaPipeline = mediaPipeline
        self.mediaServices = mediaUnderstandingServices
        self.diagnosticsSink = diagnosticsSink
        self.toolRegistry = toolRegistry ?? AgentToolRegistry(tools: [LLMTaskTool(modelRouter: modelRouter)])
        self.sessionStore = sessionStore
        self.transcriptStore = transcriptStore
        self.approvals = approvalBroker
        self.questions = questionBroker
        if let contextEngines {
            self.contextEngines = contextEngines
        } else if let transcriptStore {
            self.contextEngines = ContextEngineRegistry(
                engines: [
                    LegacyContextEngine(
                        transcriptStore: transcriptStore,
                        settings: loopConfiguration.compaction,
                        summarizer: LegacyContextEngine.modelRouterSummarizer(modelRouter)
                    ),
                ]
            )
        } else {
            self.contextEngines = ContextEngineRegistry()
        }
        self.toolsConfiguration = toolsConfiguration
        self.loopConfiguration = loopConfiguration
        self.hooks = hooks
        self.hookRegistry = hookRegistry
        self.defaultAgentID = SessionKey.normalizeAgentID(defaultAgentID)
    }

    // MARK: - Configuration

    /// Registers a tool implementation for runtime use.
    /// - Parameter tool: Tool instance to register.
    public func registerTool(_ tool: any AgentTool) async {
        await self.toolRegistry.register(tool)
    }

    /// Registers the built-in `ask_user` tool backed by ``questions``.
    public func registerAskUserTool() async {
        await self.toolRegistry.register(AskUserTool(broker: self.questions))
    }

    /// Registers a model provider for runtime routing.
    /// - Parameter provider: Provider implementation.
    public func registerModelProvider(_ provider: any ModelProvider) async {
        await self.modelRouter.register(provider)
    }

    /// Updates default model provider used when request does not specify one.
    /// - Parameter id: Registered provider identifier.
    public func setDefaultModelProviderID(_ id: String) async throws {
        try await self.modelRouter.setDefaultProviderID(id)
    }

    /// Replaces the tool configuration (policy, loop detection, tool search).
    /// - Parameter configuration: Tool configuration.
    public func setToolsConfiguration(_ configuration: AgentToolsConfiguration) {
        self.toolsConfiguration = configuration
    }

    /// Current tool configuration.
    public func currentToolsConfiguration() -> AgentToolsConfiguration {
        self.toolsConfiguration
    }

    /// Replaces the loop configuration.
    /// - Parameter configuration: Loop configuration.
    public func setLoopConfiguration(_ configuration: AgentLoopConfiguration) {
        self.loopConfiguration = configuration
    }

    /// Current loop configuration.
    public func currentLoopConfiguration() -> AgentLoopConfiguration {
        self.loopConfiguration
    }

    /// Replaces the loop hooks.
    /// - Parameter hooks: Hooks.
    public func setHooks(_ hooks: AgentLoopHooks) {
        self.hooks = hooks
    }

    /// Current loop hooks (Foundation Models sessions gate their tool calls with them).
    func currentHooks() -> AgentLoopHooks {
        self.hooks
    }

    /// Adds a system-prompt contributor evaluated for every model turn (for example a tool directory).
    /// - Parameter contributor: Returns a section for the session, or `nil`.
    public func addSystemPromptContributor(_ contributor: @escaping @Sendable (_ sessionKey: String, _ session: SessionRecord?) async -> String?) {
        self.promptContributors.append { context in
            await contributor(context.sessionKey, context.session)
        }
    }

    /// Adds a system-prompt contributor that sees the turn's provider, model and offered tools (for
    /// example the memory-recall section, which only applies when memory tools are offered).
    /// - Parameter contributor: Returns a section for the turn, or `nil`.
    public func addPromptContributor(_ contributor: @escaping @Sendable (AgentPromptContext) async -> String?) {
        self.promptContributors.append(contributor)
    }

    /// Queues an internal event (for example a sub-agent completion) delivered to the session's next run.
    /// - Parameters:
    ///   - text: Event text injected as hidden context.
    ///   - sessionKey: Target session.
    public func enqueueInternalEvent(_ text: String, sessionKey: String) {
        self.internalEventQueues[sessionKey, default: []].append(text)
    }

    /// Pending internal events of a session.
    /// - Parameter sessionKey: Session key.
    /// - Returns: Queued event texts.
    public func pendingInternalEvents(sessionKey: String) -> [String] {
        self.internalEventQueues[sessionKey] ?? []
    }

    private func drainInternalEvents(_ sessionKey: String) -> [String] {
        self.internalEventQueues.removeValue(forKey: sessionKey) ?? []
    }

    /// Marks a session as yielded unless internal events are already queued for it. The check and
    /// the mark happen in one actor turn, so a completion racing the yield is never lost.
    /// - Parameter sessionKey: Session key.
    /// - Returns: `true` when events are queued (wake the session now instead of waiting).
    func markYieldedUnlessEventsPending(sessionKey: String) -> Bool {
        if !(self.internalEventQueues[sessionKey] ?? []).isEmpty {
            self.yieldedSessions.remove(sessionKey)
            return true
        }
        self.yieldedSessions.insert(sessionKey)
        return false
    }

    /// Queues an internal event and claims the session's yield in the same actor turn.
    /// - Parameters:
    ///   - text: Event text.
    ///   - sessionKey: Target session.
    /// - Returns: `true` when the session was yielded (the caller wakes it; the event is delivered by
    ///   the woken run).
    func enqueueInternalEventClaimingYield(_ text: String, sessionKey: String) -> Bool {
        self.internalEventQueues[sessionKey, default: []].append(text)
        return self.yieldedSessions.remove(sessionKey) != nil
    }

    private func promptSections(_ context: AgentPromptContext) async -> [String] {
        var sections: [String] = []
        for contributor in self.promptContributors {
            if let section = await contributor(context) {
                sections.append(section)
            }
        }
        return sections
    }

    /// System-prompt sections contributed for a context (used by embedded sessions outside the loop).
    /// - Parameter context: Prompt context.
    /// - Returns: Non-empty sections in registration order.
    public func promptContributions(for context: AgentPromptContext) async -> [String] {
        await self.promptSections(context).filter { !$0.isEmpty }
    }

    // MARK: - Events

    /// Subscribes to every run's agent events (upstream `agent` gateway events).
    /// - Parameter limit: Buffered frames per subscriber.
    /// - Returns: Event stream; cancel iteration to unsubscribe.
    nonisolated public func events(bufferingNewest limit: Int = 512) -> AsyncStream<AgentEventFrame> {
        self.eventHub.subscribe(bufferingNewest: limit)
    }

    // MARK: - Runs

    /// Executes an agent run and returns its result.
    /// - Parameters:
    ///   - request: Run request payload.
    ///   - timeoutMs: Timeout in milliseconds (whole run).
    /// - Returns: Run result containing output, tool results, and lifecycle events.
    /// - Throws: ``AgentRuntimeError/timedOut(runID:)``, ``AgentRuntimeError/aborted(runID:)`` or the failure.
    public func run(_ request: AgentRunRequest, timeoutMs: Int = 30_000) async throws -> AgentRunResult {
        let task = self.launch(request, timeoutMs: timeoutMs, streaming: false, frameSink: nil)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Starts a run in the background and returns its identifier (poll with ``wait(runID:timeoutMs:)``).
    /// - Parameters:
    ///   - request: Run request payload.
    ///   - timeoutMs: Optional run timeout (ms).
    ///   - streaming: Stream model output as `assistant` delta events.
    /// - Returns: The run identifier.
    @discardableResult
    public func start(_ request: AgentRunRequest, timeoutMs: Int? = nil, streaming: Bool = true) -> String {
        _ = self.launch(request, timeoutMs: timeoutMs, streaming: streaming, frameSink: nil)
        return request.runID
    }

    /// Executes a run and streams its agent events (lifecycle, assistant, thinking, tool, usage, …).
    ///
    /// The stream finishes after the terminal `lifecycle` event (`end` or `error`); it throws the run
    /// error. Cancelling iteration aborts the run.
    /// - Parameters:
    ///   - request: Run request payload.
    ///   - timeoutMs: Optional run timeout (ms).
    /// - Returns: The event stream.
    nonisolated public func runEvents(_ request: AgentRunRequest, timeoutMs: Int? = nil) -> AsyncThrowingStream<AgentEventFrame, Error> {
        AsyncThrowingStream { continuation in
            let starter = Task {
                let task = await self.launch(request, timeoutMs: timeoutMs, streaming: true) { frame in
                    continuation.yield(frame)
                }
                do {
                    _ = try await task.value
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    starter.cancel()
                    Task { await self.abort(runID: request.runID) }
                }
            }
        }
    }

    /// Executes an agent run and streams incremental visible output (adapter over ``runEvents(_:timeoutMs:)``).
    /// - Parameters:
    ///   - request: Run request payload.
    ///   - timeoutMs: Run timeout (ms).
    /// - Returns: Stream of output chunks ending with an empty `isFinal` chunk.
    public func runStream(
        _ request: AgentRunRequest,
        timeoutMs: Int = 30_000
    ) -> AsyncThrowingStream<AgentRunStreamChunk, Error> {
        let events = self.runEvents(request, timeoutMs: max(1, timeoutMs))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in events {
                        if frame.stream == .assistant, let delta = frame.data["delta"]?.stringValue, !delta.isEmpty {
                            continuation.yield(AgentRunStreamChunk(runID: request.runID, sessionKey: request.sessionKey, text: delta, isFinal: false))
                        }
                    }
                    continuation.yield(AgentRunStreamChunk(runID: request.runID, sessionKey: request.sessionKey, text: "", isFinal: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
    }

    /// Aborts a run: cancels its task and its pending approvals and questions. The transcript keeps
    /// partial assistant output with `stopReason: aborted`.
    /// - Parameter runID: Run identifier.
    /// - Returns: `true` when the run was active.
    @discardableResult
    public func abort(runID: String) async -> Bool {
        guard let active = self.activeRuns[runID] else {
            return false
        }
        active.control.mark(.aborted)
        active.task.cancel()
        await self.approvals.cancel(runID: runID)
        await self.questions.cancel(runID: runID)
        return true
    }

    /// Aborts every active run of a session.
    /// - Parameter sessionKey: Session key.
    /// - Returns: Aborted run identifiers.
    @discardableResult
    public func abort(sessionKey: String) async -> [String] {
        let ids = self.activeRuns.filter { $0.value.sessionKey == sessionKey }.map(\.key).sorted()
        for id in ids {
            await self.abort(runID: id)
        }
        return ids
    }

    /// Identifiers of active runs, optionally for one session.
    /// - Parameter sessionKey: Optional session filter.
    /// - Returns: Run identifiers.
    public func activeRunIDs(sessionKey: String? = nil) -> [String] {
        self.activeRuns.filter { sessionKey == nil || $0.value.sessionKey == sessionKey }.map(\.key).sorted()
    }

    /// Waits for a run (upstream `agent.wait`).
    /// - Parameters:
    ///   - runID: Run identifier.
    ///   - timeoutMs: Optional wait bound; elapsing returns status `timeout`.
    /// - Returns: The wait result, or `nil` for unknown runs.
    public func wait(runID: String, timeoutMs: Int? = nil) async -> AgentRunWaitResult? {
        guard let active = self.activeRuns[runID] else {
            return self.completedRuns[runID]
        }
        let token = UUID()
        let finished: AgentRunWaitResult? = await withCheckedContinuation { continuation in
            self.runWaiters[runID, default: [:]][token] = continuation
            if let timeoutMs, timeoutMs > 0 {
                let sleepNs = RuntimeTime.sleepNanoseconds(milliseconds: timeoutMs)
                Task {
                    try? await Task.sleep(nanoseconds: sleepNs)
                    self.expireRunWaiter(runID, token: token)
                }
            }
        }
        return finished ?? AgentRunWaitResult(status: "timeout", runID: runID, sessionKey: active.sessionKey, startedAt: active.startedAt)
    }

    private func expireRunWaiter(_ runID: String, token: UUID) {
        guard let continuation = self.runWaiters[runID]?.removeValue(forKey: token) else { return }
        if self.runWaiters[runID]?.isEmpty == true {
            self.runWaiters[runID] = nil
        }
        continuation.resume(returning: nil)
    }

    // MARK: - Sessions

    /// Transcript session id of a session key.
    /// - Parameter sessionKey: Session key.
    /// - Returns: The session id (store-assigned, or derived when there is no session store).
    public func transcriptSessionID(for sessionKey: String) async -> String {
        if let record = await self.sessionStore?.recordForKey(sessionKey), let sessionID = record.sessionID {
            return sessionID
        }
        return SessionTranscriptIdentity.sessionID(forKey: sessionKey)
    }

    /// Messages on the session's active transcript path (for `chat.history`).
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - limit: Optional maximum number of trailing messages.
    /// - Returns: Messages, oldest first.
    /// - Throws: ``AgentRuntimeError/transcriptUnavailable`` without a transcript store.
    public func history(sessionKey: String, limit: Int? = nil) async throws -> [AgentMessage] {
        guard let transcriptStore else {
            throw AgentRuntimeError.transcriptUnavailable
        }
        let sessionID = await self.transcriptSessionID(for: sessionKey)
        guard try await transcriptStore.header(sessionID: sessionID) != nil else {
            return []
        }
        // Hidden custom messages (internal events, hidden prompts) stay out of chat history.
        let messages = try await transcriptStore.activePath(sessionID: sessionID).compactMap(\.message).filter { message in
            if case .other("custom", let raw) = message, raw["display"]?.boolValue == false {
                return false
            }
            return true
        }
        guard let limit, limit > 0, messages.count > limit else {
            return messages
        }
        return Array(messages.suffix(limit))
    }

    /// Compacts a session transcript on demand (`sessions.compact`, `/compact`).
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - customInstructions: Optional operator focus.
    /// - Returns: The compaction outcome.
    /// - Throws: ``AgentRuntimeError/transcriptUnavailable`` or engine errors.
    public func compact(sessionKey: String, customInstructions: String? = nil) async throws -> ContextCompactResult {
        guard let transcriptStore else {
            throw AgentRuntimeError.transcriptUnavailable
        }
        guard let engine = await self.contextEngines.selected() else {
            return ContextCompactResult(ok: false, compacted: false, reason: "no context engine", tokensBefore: 0)
        }
        let sessionID = await self.transcriptSessionID(for: sessionKey)
        guard try await transcriptStore.header(sessionID: sessionID) != nil else {
            return ContextCompactResult(ok: true, compacted: false, reason: "no transcript", tokensBefore: 0)
        }
        await self.lanes.acquire(sessionKey)
        do {
            let record = await self.sessionStore?.recordForKey(sessionKey)
            let messageCount = try await transcriptStore.contextMessages(sessionID: sessionID).count
            await self.hooks.onCompaction?(sessionKey, .manual, 0, nil)
            await self.observeHook(.beforeCompaction, sessionKey: sessionKey, metadata: ["trigger": AnyCodable("manual")]) {
                CompactionHookEvent(sessionKey: sessionKey, messageCount: messageCount)
            }
            let result = try await engine.compact(
                ContextCompactParams(
                    sessionID: sessionID,
                    sessionKey: sessionKey,
                    force: true,
                    customInstructions: customInstructions,
                    trigger: .manual,
                    sessionModel: record?.modelOverride
                )
            )
            await self.hooks.onCompaction?(sessionKey, .manual, result.tokensBefore, result.tokensAfter ?? result.tokensBefore)
            await self.observeHook(
                .afterCompaction,
                sessionKey: sessionKey,
                metadata: ["trigger": AnyCodable("manual"), "compacted": AnyCodable(result.compacted)]
            ) {
                CompactionHookEvent(
                    sessionKey: sessionKey,
                    messageCount: messageCount,
                    tokensBefore: result.tokensBefore,
                    tokensAfter: result.tokensAfter ?? result.tokensBefore
                )
            }
            await self.lanes.release(sessionKey)
            return result
        } catch {
            await self.lanes.release(sessionKey)
            throw error
        }
    }

    /// Resets a session: records a `reset` entry and rotates the session to a new transcript.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - reason: Reset reason.
    /// - Returns: The rotated record (when a session store exists).
    @discardableResult
    public func resetSession(sessionKey: String, reason: SessionResetReason = .reset) async throws -> SessionRecord? {
        await self.abort(sessionKey: sessionKey)
        let oldSessionID = await self.transcriptSessionID(for: sessionKey)
        await self.emitSessionEnding(sessionKey: sessionKey, sessionID: oldSessionID, reason: reason.rawValue, isReset: true)
        if let transcriptStore, try await transcriptStore.header(sessionID: oldSessionID) != nil {
            try await transcriptStore.append(SessionTranscriptEntry(payload: .reset(reason: reason, firstKeptEntryID: nil)), sessionID: oldSessionID)
        }
        guard let sessionStore else { return nil }
        let rotated = await sessionStore.rotateSession(forKey: sessionKey)
        if let rotated, let newSessionID = rotated.sessionID, let transcriptStore {
            try await transcriptStore.ensureSession(id: newSessionID, cwd: self.loopConfiguration.transcriptWorkingDirectory, parentSession: oldSessionID)
            await self.observeHook(.sessionStart, sessionKey: sessionKey) {
                SessionLifecycleHookEvent(sessionId: newSessionID, sessionKey: sessionKey, resumedFrom: oldSessionID)
            }
        }
        try? await sessionStore.save()
        return rotated
    }

    /// Deletes a session record and its transcript.
    /// - Parameter sessionKey: Session key.
    /// - Returns: `true` when a record or transcript existed.
    @discardableResult
    public func deleteSession(sessionKey: String) async throws -> Bool {
        await self.abort(sessionKey: sessionKey)
        let sessionID = await self.transcriptSessionID(for: sessionKey)
        await self.emitSessionEnding(sessionKey: sessionKey, sessionID: sessionID, reason: "deleted", isReset: false)
        var existed = false
        if let transcriptStore, try await transcriptStore.header(sessionID: sessionID) != nil {
            try await transcriptStore.delete(sessionID: sessionID)
            existed = true
        }
        if let sessionStore, await sessionStore.deleteRecord(forKey: sessionKey) {
            existed = true
            try? await sessionStore.save()
        }
        return existed
    }

    /// Emits `before_reset` (resets only) and `session_end` for a session that has a transcript.
    private func emitSessionEnding(sessionKey: String, sessionID: String, reason: String, isReset: Bool) async {
        guard let hookRegistry, let transcriptStore else { return }
        let wantsReset = isReset ? await hookRegistry.hasHandlers(for: .beforeReset) : false
        let wantsEnd = await hookRegistry.hasHandlers(for: .sessionEnd)
        guard wantsReset || wantsEnd, let header = try? await transcriptStore.header(sessionID: sessionID) else { return }
        let messages = (try? await transcriptStore.contextMessages(sessionID: sessionID)) ?? []
        let context = HookContext(sessionKey: sessionKey)
        if wantsReset {
            await hookRegistry.emitObserving(
                .beforeReset,
                event: AgentSessionResetHookEvent(messages: AgentLoopHookEmitter.encode(messages), reason: reason),
                context: context
            )
        }
        if wantsEnd {
            let started = SessionTranscriptClock.milliseconds(fromISO: header.timestamp)
            let duration = started.map { RuntimeTime.elapsedMilliseconds(since: $0) }
            await hookRegistry.emitObserving(
                .sessionEnd,
                event: SessionLifecycleHookEvent(
                    sessionId: sessionID,
                    sessionKey: sessionKey,
                    messageCount: messages.count,
                    durationMs: duration,
                    reason: reason
                ),
                context: context
            )
        }
    }

    /// Emits an observe-only hook when handlers exist.
    private func observeHook<Event: Encodable & Sendable>(
        _ hook: HookName,
        sessionKey: String,
        metadata: [String: AnyCodable] = [:],
        _ event: @Sendable () -> Event
    ) async {
        guard let hookRegistry, await hookRegistry.hasHandlers(for: hook) else { return }
        await hookRegistry.emitObserving(hook, event: event(), context: HookContext(sessionKey: sessionKey, metadata: metadata))
    }

    // MARK: - Intent graph

    /// Builds an intent graph for a run request without executing the run.
    /// - Parameter request: Run request payload.
    /// - Returns: Deterministic intent graph representation.
    public func makeIntentGraph(for request: AgentRunRequest) -> IntentGraph {
        var nodes: [IntentGraphNode] = []
        var edges: [IntentGraphEdge] = []

        let runNodeID = "run:\(request.runID)"
        let promptNodeID = "prompt:\(request.runID)"
        let modelNodeID = "model:\(request.runID)"
        let outputNodeID = "output:\(request.runID)"

        nodes.append(
            IntentGraphNode(
                id: runNodeID,
                kind: .run,
                title: "Agent Run",
                metadata: [
                    "runID": request.runID,
                    "sessionKey": request.sessionKey,
                    "requestedProviderID": request.modelProviderID ?? "",
                ]
            )
        )
        nodes.append(
            IntentGraphNode(
                id: promptNodeID,
                kind: .prompt,
                title: "Prompt",
                metadata: [
                    "length": String(request.prompt.count),
                    "hasWorkspaceRoot": String(request.workspaceRootPath != nil),
                    "attachmentCount": String(request.attachments.count),
                ]
            )
        )
        nodes.append(
            IntentGraphNode(
                id: modelNodeID,
                kind: .model,
                title: "Model Route",
                metadata: [
                    "requestedProviderID": request.modelProviderID ?? "",
                ]
            )
        )
        nodes.append(
            IntentGraphNode(
                id: outputNodeID,
                kind: .output,
                title: "Output",
                metadata: [
                    "toolCallCount": String(request.toolCalls.count),
                ]
            )
        )

        edges.append(IntentGraphEdge(sourceID: runNodeID, targetID: promptNodeID, kind: .initiates))
        edges.append(IntentGraphEdge(sourceID: promptNodeID, targetID: modelNodeID, kind: .feeds))
        edges.append(IntentGraphEdge(sourceID: modelNodeID, targetID: outputNodeID, kind: .produces))

        if let workspaceRootPath = request.workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspaceRootPath.isEmpty
        {
            let skillNodeID = "skill:\(request.runID)"
            nodes.append(
                IntentGraphNode(
                    id: skillNodeID,
                    kind: .skill,
                    title: "Workspace Skills",
                    metadata: ["workspaceRootPath": workspaceRootPath]
                )
            )
            edges.append(IntentGraphEdge(sourceID: runNodeID, targetID: skillNodeID, kind: .reads))
            edges.append(IntentGraphEdge(sourceID: skillNodeID, targetID: modelNodeID, kind: .feeds))
        }

        for (index, call) in request.toolCalls.enumerated() {
            let toolNodeID = "tool:\(request.runID):\(index)"
            nodes.append(
                IntentGraphNode(
                    id: toolNodeID,
                    kind: .tool,
                    title: call.name,
                    metadata: [
                        "order": String(index),
                        "argumentCount": String(call.arguments.count),
                    ]
                )
            )
            edges.append(IntentGraphEdge(sourceID: runNodeID, targetID: toolNodeID, kind: .invokes))
            edges.append(IntentGraphEdge(sourceID: toolNodeID, targetID: modelNodeID, kind: .feeds))
        }

        let sortedNodes = nodes.sorted(by: { $0.id < $1.id })
        let sortedEdges = edges.sorted {
            if $0.sourceID != $1.sourceID {
                return $0.sourceID < $1.sourceID
            }
            if $0.targetID != $1.targetID {
                return $0.targetID < $1.targetID
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        return IntentGraph(
            runID: request.runID,
            sessionKey: request.sessionKey,
            nodes: sortedNodes,
            edges: sortedEdges
        )
    }

    /// Executes a run request and returns both execution result and intent graph.
    /// - Parameters:
    ///   - request: Run request payload.
    ///   - timeoutMs: Timeout in milliseconds.
    /// - Returns: Combined graph + run result payload.
    public func runIntentGraph(
        _ request: AgentRunRequest,
        timeoutMs: Int = 30_000
    ) async throws -> IntentGraphRunResult {
        let graph = self.makeIntentGraph(for: request)
        let result = try await self.run(request, timeoutMs: timeoutMs)
        return IntentGraphRunResult(graph: graph, result: result)
    }

    // MARK: - Launch

    private func makeDependencies() -> AgentLoopDependencies {
        AgentLoopDependencies(
            toolRegistry: self.toolRegistry,
            runTools: AgentToolRegistry(),
            modelRouter: self.modelRouter,
            mediaPipeline: self.mediaPipeline,
            mediaServices: self.mediaServices,
            transcriptStore: self.transcriptStore,
            sessionStore: self.sessionStore,
            contextEngines: self.contextEngines,
            approvalBroker: self.approvals,
            tools: self.toolsConfiguration,
            configuration: self.loopConfiguration,
            hooks: self.hooks,
            hookRegistry: self.hookRegistry,
            diagnostics: self.diagnosticsSink,
            defaultAgentID: self.defaultAgentID,
            internalEvents: { [weak self] key in await self?.drainInternalEvents(key) ?? [] },
            promptContributors: { [weak self] context in await self?.promptSections(context) ?? [] }
        )
    }

    /// Starts a run, or returns the task of the active run that already uses `request.runID`
    /// (approvals, questions and waiters are keyed by run id, so two live runs never share one; a
    /// duplicate start behaves like upstream's `in_flight` answer).
    private func launch(
        _ request: AgentRunRequest,
        timeoutMs: Int?,
        streaming: Bool,
        frameSink: (@Sendable (AgentEventFrame) -> Void)?
    ) -> Task<AgentRunResult, Error> {
        if let existing = self.activeRuns[request.runID] {
            return existing.task
        }
        // A reused id starts fresh: waiters must not see the previous run's result.
        if self.completedRuns.removeValue(forKey: request.runID) != nil {
            self.completedOrder.removeAll { $0 == request.runID }
        }
        let control = AgentRunControl()
        let hub = self.eventHub
        let sequencer = AgentEventSequencer(runID: request.runID, sessionKey: request.sessionKey, spawnedBy: request.spawnedBy) { frame in
            frameSink?(frame)
            hub.publish(frame)
        }
        let loop = AgentLoop(deps: self.makeDependencies())
        let lanes = self.lanes
        let sessionStore = self.sessionStore
        let startedAt = SessionTranscriptClock.nowMs()
        let diagnostics = self.diagnosticsSink
        let task = Task { () throws -> AgentRunResult in
            await Self.emit(diagnostics, "run.started", request, [
                "providerID": request.modelProviderID ?? "",
                "requestedProviderID": request.modelProviderID ?? "",
                "toolCallCount": String(request.toolCalls.count),
                "attachmentCount": String(request.attachments.count),
                "streaming": String(streaming),
            ])
            await Self.emit(diagnostics, "model.call.started", request, [
                "providerID": request.modelProviderID ?? "",
                "requestedProviderID": request.modelProviderID ?? "",
                "attachmentCount": String(request.attachments.count),
                "streaming": String(streaming),
            ])
            await lanes.acquire(request.sessionKey)
            do {
                try Task.checkCancellation()
                let result = try await loop.run(request, streaming: streaming, events: sequencer, recorder: AgentRunRecorder(), control: control)
                await lanes.release(request.sessionKey)
                try? await sessionStore?.save()
                let latency = String(max(0, SessionTranscriptClock.nowMs() - startedAt))
                await Self.emit(diagnostics, "model.call.completed", request, [
                    "providerID": result.providerID ?? request.modelProviderID ?? "",
                    "modelID": result.modelID ?? "",
                    "latencyMs": latency,
                    "attachmentCount": String(result.attachments.count),
                    "streaming": String(streaming),
                ])
                await Self.emit(diagnostics, "run.completed", request, [
                    "latencyMs": latency,
                    "providerID": result.providerID ?? request.modelProviderID ?? "",
                    "modelID": result.modelID ?? "",
                    "outputLength": String(result.output.count),
                    "attachmentCount": String(result.attachments.count),
                    "streaming": String(streaming),
                ])
                return result
            } catch {
                await lanes.release(request.sessionKey)
                let mapped = Self.mapError(error, runID: request.runID, control: control)
                let timedOut = control.cancellation == .timedOut
                var data: [String: AnyCodable] = [
                    "phase": AnyCodable("error"),
                    "startedAt": AnyCodable(startedAt),
                    "endedAt": AnyCodable(SessionTranscriptClock.nowMs()),
                    "error": AnyCodable(mapped.localizedDescription),
                ]
                if timedOut {
                    data["timedOut"] = AnyCodable(true)
                }
                if control.cancellation == .aborted {
                    data["aborted"] = AnyCodable(true)
                }
                sequencer.emit(.lifecycle, data)
                let latency = String(max(0, SessionTranscriptClock.nowMs() - startedAt))
                await Self.emit(diagnostics, "model.call.failed", request, [
                    "providerID": request.modelProviderID ?? "",
                    "requestedProviderID": request.modelProviderID ?? "",
                    "error": String(describing: mapped),
                    "timedOut": String(timedOut),
                    "attachmentCount": String(request.attachments.count),
                    "streaming": String(streaming),
                ])
                await Self.emit(diagnostics, "run.failed", request, [
                    "latencyMs": latency,
                    "providerID": request.modelProviderID ?? "",
                    "requestedProviderID": request.modelProviderID ?? "",
                    "timedOut": String(timedOut),
                    "error": String(describing: mapped),
                    "attachmentCount": String(request.attachments.count),
                    "streaming": String(streaming),
                ])
                throw mapped
            }
        }
        var active = ActiveRun(
            task: task,
            control: control,
            sessionKey: request.sessionKey,
            startedAt: startedAt,
            spawnedBy: request.spawnedBy,
            toolPolicy: request.toolPolicy,
            agentID: request.agentID
        )
        if let timeoutMs {
            let timeoutNs = RuntimeTime.sleepNanoseconds(milliseconds: max(1, timeoutMs))
            active.timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNs)
                } catch {
                    return
                }
                if self.markTimedOut(request.runID, control: control) {
                    task.cancel()
                }
            }
        }
        self.activeRuns[request.runID] = active
        Task {
            let outcome = await task.result
            self.finishRun(request, control: control, startedAt: startedAt, outcome: outcome)
        }
        return task
    }

    /// Per-run tool policy and agent of an active run (sub-agent spawns and wake runs inherit them).
    /// - Parameter runID: Run identifier.
    /// - Returns: The run's policy and agent, or `nil` when the run is not active.
    func activeRunContext(runID: String) -> (toolPolicy: ToolPolicy?, agentID: String?)? {
        guard let active = self.activeRuns[runID] else { return nil }
        return (active.toolPolicy, active.agentID)
    }

    /// Marks a run timed out; a stale timer of an earlier run with the same id does nothing.
    private func markTimedOut(_ runID: String, control: AgentRunControl) -> Bool {
        guard self.activeRuns[runID]?.control === control else { return false }
        control.mark(.timedOut)
        Task {
            await self.approvals.cancel(runID: runID)
            await self.questions.cancel(runID: runID)
        }
        return true
    }

    private func finishRun(_ request: AgentRunRequest, control: AgentRunControl, startedAt: Int64, outcome: Result<AgentRunResult, Error>) {
        guard let active = self.activeRuns[request.runID], active.control === control else { return }
        active.timeoutTask?.cancel()
        self.activeRuns[request.runID] = nil
        let endedAt = SessionTranscriptClock.nowMs()
        let result: AgentRunWaitResult
        switch outcome {
        case .success(let value):
            result = AgentRunWaitResult(
                status: "ok",
                runID: request.runID,
                sessionKey: request.sessionKey,
                startedAt: startedAt,
                endedAt: endedAt,
                output: value.output
            )
        case .failure(let error):
            let isTimeout: Bool
            if case AgentRuntimeError.timedOut = error {
                isTimeout = true
            } else {
                isTimeout = false
            }
            result = AgentRunWaitResult(
                status: isTimeout ? "timeout" : "error",
                runID: request.runID,
                sessionKey: request.sessionKey,
                startedAt: startedAt,
                endedAt: endedAt,
                error: error.localizedDescription
            )
        }
        self.completedRuns[request.runID] = result
        for waiter in (self.runWaiters.removeValue(forKey: request.runID) ?? [:]).values {
            waiter.resume(returning: result)
        }
        self.completedOrder.append(request.runID)
        if self.completedOrder.count > Self.completedRunLimit {
            let overflow = self.completedOrder.count - Self.completedRunLimit
            for id in self.completedOrder.prefix(overflow) {
                self.completedRuns[id] = nil
            }
            self.completedOrder.removeFirst(overflow)
        }
    }

    private static func mapError(_ error: Error, runID: String, control: AgentRunControl) -> Error {
        switch control.cancellation {
        case .timedOut:
            return AgentRuntimeError.timedOut(runID: runID)
        case .aborted:
            return AgentRuntimeError.aborted(runID: runID)
        case nil:
            if error is CancellationError {
                return AgentRuntimeError.aborted(runID: runID)
            }
            return error
        }
    }

    private static func emit(
        _ sink: RuntimeDiagnosticSink?,
        _ name: String,
        _ request: AgentRunRequest,
        _ metadata: [String: String]
    ) async {
        guard let sink else { return }
        await sink(RuntimeDiagnosticEvent(subsystem: "runtime", name: name, runID: request.runID, sessionKey: request.sessionKey, metadata: metadata))
    }
}
