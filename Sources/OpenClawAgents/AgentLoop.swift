import Foundation
import OpenClawCore
import OpenClawMedia
import OpenClawModels
import OpenClawProtocol
import OpenClawSkills

// Model-driven agent loop (upstream `docs/concepts/agent-loop.md`, `src/agents/embedded-agent-*`).
//
// One run: append the user message to the session transcript, then repeat
//   assemble context → call the model with visible tools → append the assistant message →
//   execute proposed tool calls (hooks, approvals, schema validation) → append tool results
// until the model stops calling tools, every result asks to terminate, the run is aborted, or the
// iteration cap is reached. Events stream as `AgentEventFrame`s (lifecycle/assistant/thinking/
// tool/usage/compaction/approval).

/// Loop settings (SDK-owned defaults; upstream has no fixed iteration constant).
public struct AgentLoopConfiguration: Sendable, Equatable {
    /// Default cap on model turns that end in tool calls.
    public static let defaultMaxToolIterations = 24

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

    /// Creates loop settings.
    /// - Parameters:
    ///   - maxToolIterations: Maximum model turns per run (minimum 1).
    ///   - baseSystemPrompt: Optional base system prompt.
    ///   - contextWindowTokens: Optional model context window for automatic compaction.
    ///   - compaction: Compaction settings.
    ///   - toolResultEventMaxChars: Tool result preview size in events.
    ///   - transcriptWorkingDirectory: Working directory recorded in transcript headers.
    public init(
        maxToolIterations: Int = AgentLoopConfiguration.defaultMaxToolIterations,
        baseSystemPrompt: String? = nil,
        contextWindowTokens: Int? = nil,
        compaction: ContextCompactionSettings = ContextCompactionSettings(),
        toolResultEventMaxChars: Int = 2_000,
        transcriptWorkingDirectory: String = ""
    ) {
        self.maxToolIterations = max(1, maxToolIterations)
        self.baseSystemPrompt = baseSystemPrompt
        self.contextWindowTokens = contextWindowTokens.map { max(1, $0) }
        self.compaction = compaction
        self.toolResultEventMaxChars = max(64, toolResultEventMaxChars)
        self.transcriptWorkingDirectory = transcriptWorkingDirectory
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

    /// Creates an approval request.
    public init(
        title: String,
        description: String,
        severity: String = "warning",
        timeoutMs: Int64? = nil,
        allowedDecisions: [ApprovalDecision] = [.allowOnce, .allowAlways, .deny],
        pluginID: String? = nil
    ) {
        self.title = title
        self.description = description
        self.severity = severity
        self.timeoutMs = timeoutMs
        self.allowedDecisions = allowedDecisions
        self.pluginID = pluginID
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

/// Hook seams of the loop (the plugin/hook runtime bridges typed hooks into these).
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

/// Collects legacy events and tool results during a run.
final class AgentRunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentRunEvent] = []
    private var results: [AgentToolResult] = []

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

    var snapshot: (events: [AgentRunEvent], results: [AgentToolResult]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        return (self.events, self.results)
    }
}

/// Everything a run needs (captured by value so the loop runs off the runtime actor).
struct AgentLoopDependencies: Sendable {
    let toolRegistry: AgentToolRegistry
    let modelRouter: ModelRouter
    let mediaPipeline: MediaPipeline
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
    let promptContributors: @Sendable (_ sessionKey: String, _ sessionRecord: SessionRecord?) async -> [String]
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

/// The model-driven loop for one run.
struct AgentLoop: Sendable {
    let deps: AgentLoopDependencies

    private static let mutationToolNames: Set<String> = ["write", "edit", "apply_patch", "exec", "process"]

    func run(
        _ request: AgentRunRequest,
        streaming: Bool,
        events: AgentEventSequencer,
        recorder: AgentRunRecorder,
        control: AgentRunControl
    ) async throws -> AgentRunResult {
        let runID = request.runID
        let startedAt = SessionTranscriptClock.nowMs()
        let agentID = SessionKey.normalizeAgentID(request.agentID ?? self.deps.defaultAgentID)
        events.emit(.lifecycle, ["phase": AnyCodable("start"), "startedAt": AnyCodable(startedAt)])
        recorder.record(AgentRunEvent(runID: runID, kind: .runStarted))

        // Session and transcript.
        let sessionRecord = await self.deps.sessionStore?.resolveOrCreate(
            sessionKey: request.sessionKey,
            defaultAgentID: agentID,
            route: nil
        )
        let transcript: any SessionTranscriptStore = self.deps.transcriptStore ?? InMemorySessionTranscriptStore()
        let sessionID = sessionRecord?.sessionID
            ?? request.sessionID
            ?? (self.deps.transcriptStore != nil ? SessionTranscriptIdentity.sessionID(forKey: request.sessionKey) : "run-\(runID)")
        try await transcript.ensureSession(
            id: sessionID,
            cwd: request.workspaceRootPath ?? self.deps.configuration.transcriptWorkingDirectory,
            parentSession: sessionRecord?.parentSessionID
        )

        // Inputs.
        let attachments = try await Self.normalizeAttachments(request.attachments, using: self.deps.mediaPipeline)
        let workspace = try await Self.loadWorkspacePrompt(request.workspaceRootPath)
        let legacyPrompt = Self.composeLegacyPrompt(basePrompt: request.prompt, workspace: workspace, attachments: attachments)
        var userText = request.prompt
        if !attachments.isEmpty {
            userText += "\n\n" + Self.composeAttachmentSection(attachments)
        }
        var userBlocks: [AgentContentBlock] = [.text(userText)]
        userBlocks.append(contentsOf: attachments.compactMap(AgentMessageConversion.imageBlock(from:)))
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
                transcript: transcript
            )
        }
        let promptMessage: AgentMessage = request.hiddenPrompt
            ? .custom(customType: "hidden_prompt", content: .blocks(userBlocks), display: false, timestamp: SessionTranscriptClock.nowMs())
            : .user(AgentUserMessage(content: .blocks(userBlocks), timestamp: SessionTranscriptClock.nowMs()))
        try await self.appendMessage(promptMessage, sessionID: sessionID, sessionKey: request.sessionKey, transcript: transcript)

        let context = AgentToolInvocationContext(runID: runID, sessionKey: request.sessionKey, agentID: agentID)
        let policy = Self.effectivePolicy(base: self.deps.tools.policy, request: request, session: sessionRecord)
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
            try await self.appendMessage(.assistant(forced), sessionID: sessionID, sessionKey: request.sessionKey, transcript: transcript)
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

                let probe = ModelGenerationRequest(
                    sessionKey: request.sessionKey,
                    prompt: request.prompt,
                    providerID: request.modelProviderID,
                    modelID: request.modelID
                )
                let primary = await self.deps.modelRouter.primaryProvider(for: probe)
                let capabilities = primary?.capabilities ?? .legacy
                let usesContractV2 = capabilities.supportsTools || capabilities.supportsTranscript

                let toolView = await self.toolView(policy: policy)
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
                            events: events
                        ) {
                            contextMessages = try await transcript.contextMessages(sessionID: sessionID)
                        }
                    }
                }

                let systemPrompt = await self.composeSystemPrompt(
                    workspace: workspace,
                    request: request,
                    session: sessionRecord,
                    addition: systemAddition,
                    directory: toolView.catalog?.configuration.mode == .directory ? toolView.catalog?.directoryPrompt() : nil
                )
                let modelRequest = Self.makeModelRequest(
                    from: request,
                    legacyPrompt: legacyPrompt,
                    systemPrompt: usesContractV2 ? systemPrompt : nil,
                    messages: usesContractV2 ? AgentMessageConversion.modelMessages(from: contextMessages) : [],
                    tools: usesContractV2 && capabilities.supportsTools ? descriptors.modelToolDefinitions : [],
                    streamTokens: streaming
                )

                let response: ModelGenerationResponse
                do {
                    if streaming {
                        response = try await self.streamModel(modelRequest, iteration: iteration, runID: runID, accumulator: accumulator, events: events)
                    } else {
                        response = try await self.deps.modelRouter.generate(modelRequest)
                    }
                } catch where !(error is CancellationError) && CompactionPlanner.isContextOverflowError(error) && !overflowRetried && usesContractV2 {
                    overflowRetried = true
                    iteration -= 1
                    let estimated = TokenEstimator.estimate(contextMessages)
                    _ = try await self.compact(trigger: .overflow, sessionID: sessionID, request: request, tokensBefore: estimated, events: events)
                    continue
                }

                try Task.checkCancellation()
                lastProviderID = response.providerID
                lastModelID = response.modelID
                let visible = ProviderVisibleTextSanitizer.sanitizeVisibleText(response.text)
                if !streaming {
                    let itemID = "\(runID):assistant:\(iteration)"
                    if let reasoning = response.reasoningText, !reasoning.isEmpty {
                        events.emit(.thinking, ["itemId": AnyCodable(itemID), "text": AnyCodable(reasoning), "delta": AnyCodable(reasoning)])
                    }
                    if !visible.isEmpty {
                        events.emit(.assistant, ["itemId": AnyCodable(itemID), "text": AnyCodable(visible), "delta": AnyCodable(visible)])
                    }
                }
                let assistant = AgentMessageConversion.assistantMessage(
                    from: response,
                    visibleText: visible,
                    timestamp: SessionTranscriptClock.nowMs()
                )
                try await self.appendMessage(.assistant(assistant), sessionID: sessionID, sessionKey: request.sessionKey, transcript: transcript)
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

    // MARK: - Model

    private func streamModel(
        _ request: ModelGenerationRequest,
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
        var usage: ModelUsage?
        var stopReason: ModelStopReason?
        for try await chunk in stream {
            try Task.checkCancellation()
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
            providerID: request.providerID ?? "stream",
            modelID: request.modelID,
            toolCalls: finalCalls,
            usage: usage,
            stopReason: stopReason,
            reasoningText: turnAccumulator.reasoningText.isEmpty ? nil : turnAccumulator.reasoningText
        )
    }

    private func compact(
        trigger: ContextCompactionTrigger,
        sessionID: String,
        request: AgentRunRequest,
        tokensBefore: Int,
        events: AgentEventSequencer
    ) async throws -> Bool {
        guard let engine = await self.deps.contextEngines.selected() else { return false }
        events.emit(.compaction, ["phase": AnyCodable("start"), "trigger": AnyCodable(trigger.rawValue), "tokensBefore": AnyCodable(tokensBefore)])
        await self.deps.hooks.onCompaction?(request.sessionKey, trigger, tokensBefore, nil)
        let result = try await engine.compact(
            ContextCompactParams(
                sessionID: sessionID,
                sessionKey: request.sessionKey,
                tokenBudget: self.deps.configuration.contextWindowTokens.map { $0 - self.deps.configuration.compaction.reserveTokens },
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
        return result.compacted
    }

    // MARK: - Tools

    struct ToolView: Sendable {
        let visible: [AgentToolDescriptor]
        let catalog: ToolSearchCatalog?
    }

    /// Policy-filtered tools; large catalogs move behind Tool Search control tools.
    private func toolView(policy: ToolPolicy) async -> ToolView {
        let descriptors = policy.filter(await self.deps.toolRegistry.descriptors())
        let configuration = self.deps.tools.toolSearch ?? .embeddedDefault
        let catalog = ToolSearchCatalog(descriptors: descriptors, configuration: configuration)
        guard catalog.isActive else {
            return ToolView(visible: descriptors, catalog: nil)
        }
        return ToolView(visible: catalog.modelVisibleDescriptors, catalog: catalog)
    }

    /// Runs a Tool Search control call (`tool_search`, `tool_describe`, `tool_call`).
    private func executeSearchControl(
        _ call: AgentToolCall,
        catalog: ToolSearchCatalog,
        context: AgentToolInvocationContext,
        agentID: String,
        policy: ToolPolicy,
        request: AgentRunRequest,
        events: AgentEventSequencer,
        recorder: AgentRunRecorder
    ) async throws -> AgentToolResult {
        let toolCallID = call.id ?? AgentToolCall.makeID()
        switch call.name {
        case ToolSearchCatalog.searchToolName:
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: catalog.runSearch(call.arguments))
        case ToolSearchCatalog.describeToolName:
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: catalog.runDescribe(call.arguments))
        default:
            guard let targetID = call.arguments["id"]?.stringValue, let descriptor = catalog.descriptor(for: targetID) else {
                return AgentToolResult(
                    name: call.name,
                    toolCallID: toolCallID,
                    output: .error("Unknown tool id: \(call.arguments["id"]?.stringValue ?? ""); use tool_search first")
                )
            }
            let arguments = call.arguments["args"]?.dictionaryValue ?? [:]
            if let violation = Self.schemaViolation(arguments, descriptor: descriptor) {
                return AgentToolResult(
                    name: call.name,
                    toolCallID: toolCallID,
                    output: .error("Invalid arguments for \(descriptor.name): \(violation). Expected \(ToolSearchCatalog.inputSignature(descriptor))")
                )
            }
            let inner = try await self.executeOne(
                AgentToolCall(id: "\(toolCallID).inner", name: descriptor.name, arguments: arguments),
                descriptor: descriptor,
                context: AgentToolInvocationContext(
                    runID: context.runID,
                    sessionKey: context.sessionKey,
                    agentID: context.agentID,
                    parentToolCallID: toolCallID
                ),
                agentID: agentID,
                policy: policy,
                enforcePolicy: true,
                request: request,
                events: events,
                recorder: recorder
            )
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: inner.output, durationMs: inner.durationMs)
        }
    }

    static func effectivePolicy(base: ToolPolicy, request: AgentRunRequest, session: SessionRecord?) -> ToolPolicy {
        var policy = request.toolPolicy ?? base
        var deny: [String] = []
        if session?.permissionMode == .readOnly {
            deny.append(contentsOf: Self.mutationToolNames)
        }
        if let overrides = session?.toolOverrides {
            if overrides.webSearch == false {
                deny.append("web_search")
            }
            for (server, enabled) in overrides.mcpServers ?? [:] where !enabled {
                deny.append("\(server)\(CoreToolCatalog.mcpToolNameSeparator)*")
            }
            for (server, tools) in overrides.mcpToolsDeny ?? [:] {
                deny.append(contentsOf: tools.map { "\(server)\(CoreToolCatalog.mcpToolNameSeparator)\($0)" })
            }
        }
        if !deny.isEmpty {
            policy = policy.denying(deny)
        }
        return policy
    }

    private func executeBatch(
        _ calls: [AgentToolCall],
        context: AgentToolInvocationContext,
        agentID: String,
        policy: ToolPolicy,
        enforcePolicy: Bool,
        searchCatalog: ToolSearchCatalog?,
        sessionID: String,
        request: AgentRunRequest,
        transcript: any SessionTranscriptStore,
        events: AgentEventSequencer,
        recorder: AgentRunRecorder,
        loopHistory: inout [String]
    ) async throws -> [AgentToolResult] {
        var descriptors: [String: AgentToolDescriptor] = [:]
        var controlCalls: Set<Int> = []
        for (index, call) in calls.enumerated() {
            if let tool = await self.deps.toolRegistry.tool(named: call.name) {
                descriptors[call.name] = tool.descriptor
            } else if searchCatalog != nil, ToolSearchCatalog.controlToolNames.contains(call.name) {
                controlCalls.insert(index)
            }
        }
        let controlCallIndices = controlCalls
        let resolvedDescriptors = descriptors
        let dispatch: @Sendable (Int, AgentToolCall) async throws -> AgentToolResult = { index, call in
            let controlCalls = controlCallIndices
            let descriptors = resolvedDescriptors
            if controlCalls.contains(index), let searchCatalog {
                return try await self.executeSearchControl(
                    call,
                    catalog: searchCatalog,
                    context: context,
                    agentID: agentID,
                    policy: policy,
                    request: request,
                    events: events,
                    recorder: recorder
                )
            }
            return try await self.executeOne(
                call,
                descriptor: descriptors[call.name],
                context: context,
                agentID: agentID,
                policy: policy,
                enforcePolicy: enforcePolicy,
                request: request,
                events: events,
                recorder: recorder
            )
        }
        let parallel = calls.count > 1 && calls.allSatisfy { descriptors[$0.name]?.executionMode == .parallel }
        var results: [AgentToolResult] = []
        if parallel {
            results = try await withThrowingTaskGroup(of: (Int, AgentToolResult).self) { group in
                for (index, call) in calls.enumerated() {
                    group.addTask {
                        (index, try await dispatch(index, call))
                    }
                }
                var ordered: [(Int, AgentToolResult)] = []
                for try await item in group {
                    ordered.append(item)
                }
                return ordered.sorted { $0.0 < $1.0 }.map(\.1)
            }
        } else {
            for (index, call) in calls.enumerated() {
                try Task.checkCancellation()
                results.append(try await dispatch(index, call))
            }
        }
        for result in results {
            recorder.record(result)
            let message = AgentMessageConversion.toolResultMessage(from: result, timestamp: SessionTranscriptClock.nowMs())
            try await self.appendMessage(.toolResult(message), sessionID: sessionID, sessionKey: request.sessionKey, transcript: transcript)
        }
        if self.deps.tools.loopDetection.enabled {
            let detection = self.deps.tools.loopDetection
            for (call, result) in zip(calls, results) {
                let argumentsJSON = ModelToolCall(id: "", name: call.name, arguments: call.arguments).argumentsJSON
                let signature = "\(AgentToolRegistry.canonicalName(call.name))|\(argumentsJSON)|\(result.output.text)"
                loopHistory.append(signature)
                if loopHistory.count > detection.window {
                    loopHistory.removeFirst(loopHistory.count - detection.window)
                }
                let repeats = loopHistory.filter { $0 == signature }.count
                if repeats >= detection.threshold {
                    await self.emitDiagnostic("tool.loop.detected", request: request, metadata: ["toolName": call.name, "repeats": String(repeats)])
                    throw AgentLoopDetectedError(toolName: call.name, repeats: repeats)
                }
            }
        }
        return results
    }

    private func executeOne(
        _ call: AgentToolCall,
        descriptor: AgentToolDescriptor?,
        context: AgentToolInvocationContext,
        agentID: String,
        policy: ToolPolicy,
        enforcePolicy: Bool,
        request: AgentRunRequest,
        events: AgentEventSequencer,
        recorder: AgentRunRecorder
    ) async throws -> AgentToolResult {
        let toolCallID = call.id ?? AgentToolCall.makeID()
        var arguments = call.arguments
        events.emit(.tool, [
            "phase": AnyCodable("start"),
            "name": AnyCodable(call.name),
            "toolCallId": AnyCodable(toolCallID),
            "args": AnyCodable(arguments),
        ])
        recorder.record(AgentRunEvent(runID: request.runID, kind: .toolStarted, toolName: call.name))
        await self.emitDiagnostic("tool.call.started", request: request, metadata: ["toolName": call.name, "toolCallId": toolCallID])

        let startedAt = Date()
        var hookContext = AgentToolCallHookContext(
            runID: request.runID,
            sessionKey: request.sessionKey,
            agentID: agentID,
            toolCallID: toolCallID,
            toolName: call.name,
            arguments: arguments,
            descriptor: descriptor
        )
        var result: AgentToolResult?

        if let descriptor {
            if enforcePolicy, !policy.allows(descriptor) {
                result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Tool \(call.name) is not allowed by the current tool policy"))
            } else if let violation = Self.schemaViolation(arguments, descriptor: descriptor) {
                result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Invalid arguments for \(call.name): \(violation)"))
            }
        } else {
            result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Tool not found: \(call.name)"))
        }

        if result == nil, let beforeToolCall = self.deps.hooks.beforeToolCall {
            switch await beforeToolCall(hookContext) {
            case .proceed:
                break
            case .rewrite(let rewritten):
                arguments = rewritten
                hookContext.arguments = rewritten
            case .block(let reason):
                result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Tool call blocked: \(reason)"))
            case .requireApproval(let approvalRequest):
                let presentation = AgentApprovalPresentation.plugin(
                    title: approvalRequest.title,
                    description: approvalRequest.description,
                    severity: approvalRequest.severity,
                    pluginID: approvalRequest.pluginID,
                    toolName: call.name,
                    agentID: agentID,
                    allowedDecisions: approvalRequest.allowedDecisions
                )
                let grantKey: String
                if case .mcp(let server, let toolName) = descriptor?.source {
                    grantKey = ApprovalBroker.mcpGrantKey(server: server, tool: toolName)
                } else {
                    grantKey = ApprovalBroker.pluginGrantKey(pluginID: approvalRequest.pluginID, toolName: call.name)
                }
                let started = await self.deps.approvalBroker.begin(
                    presentation: presentation,
                    sessionKey: request.sessionKey,
                    agentID: agentID,
                    runID: request.runID,
                    toolCallID: toolCallID,
                    grantKey: grantKey,
                    timeoutMs: approvalRequest.timeoutMs
                )
                var approval = started
                if started.state == .pending {
                    events.emit(.approval, started.agentEventData)
                    approval = await self.deps.approvalBroker.waitUntilTerminal(started)
                    events.emit(.approval, approval.agentEventData)
                }
                try Task.checkCancellation()
                if !approval.isAllowed {
                    let reason = approval.reason?.rawValue ?? approval.state.rawValue
                    result = AgentToolResult(
                        name: call.name,
                        toolCallID: toolCallID,
                        output: .error("Tool call was not approved (\(approval.state.rawValue): \(reason)); do not retry it")
                    )
                }
            }
        }

        if result == nil {
            let invokeCall = AgentToolCall(id: toolCallID, name: call.name, arguments: arguments)
            let update: AgentToolUpdateHandler = { partial in
                var data: [String: AnyCodable] = [
                    "phase": AnyCodable("update"),
                    "name": AnyCodable(call.name),
                    "toolCallId": AnyCodable(toolCallID),
                ]
                if let progress = partial.progress {
                    var meta: [String: AnyCodable] = [:]
                    if let message = progress.message { meta["message"] = AnyCodable(message) }
                    if let fraction = progress.fraction { meta["fraction"] = AnyCodable(fraction) }
                    data["meta"] = AnyCodable(meta)
                }
                if !partial.text.isEmpty {
                    data["partialResult"] = AnyCodable(String(partial.text.prefix(2_000)))
                }
                events.emit(.tool, data)
            }
            result = try await self.deps.toolRegistry.invoke(invokeCall, context: context, update: update)
        }

        guard var finished = result else {
            throw CancellationError()
        }
        if finished.durationMs == nil {
            finished = AgentToolResult(
                name: finished.name,
                toolCallID: finished.toolCallID,
                output: finished.output,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
            )
        }
        await self.deps.hooks.afterToolCall?(hookContext, finished)
        if let hookRegistry = self.deps.hookRegistry {
            _ = try? await hookRegistry.emit(
                .afterToolCall,
                context: HookContext(
                    runID: request.runID,
                    sessionKey: request.sessionKey,
                    metadata: [
                        "toolName": AnyCodable(call.name),
                        "toolCallId": AnyCodable(toolCallID),
                        "isError": AnyCodable(finished.isError),
                        "durationMs": AnyCodable(finished.durationMs ?? 0),
                    ]
                )
            )
        }
        recorder.record(AgentRunEvent(runID: request.runID, kind: .toolCompleted, toolName: call.name))
        let preview = String(finished.output.text.prefix(self.deps.configuration.toolResultEventMaxChars))
        events.emit(.tool, [
            "phase": AnyCodable("result"),
            "name": AnyCodable(call.name),
            "toolCallId": AnyCodable(toolCallID),
            "isError": AnyCodable(finished.isError),
            "result": AnyCodable(preview),
            "durationMs": AnyCodable(finished.durationMs ?? 0),
        ])
        await self.emitDiagnostic(
            finished.isError ? "tool.call.failed" : "tool.call.completed",
            request: request,
            metadata: ["toolName": call.name, "toolCallId": toolCallID, "durationMs": String(finished.durationMs ?? 0)]
        )
        return finished
    }

    static func schemaViolation(_ arguments: [String: AnyCodable], descriptor: AgentToolDescriptor) -> String? {
        // Tools that declare no schema (the default empty object, typical of v1 tools) accept any arguments.
        if descriptor.parameters == AgentToolDescriptor.emptyParametersSchema {
            return nil
        }
        return JSONSchemaValidator.firstViolation(instance: AnyCodable(.object(arguments)), against: descriptor.parameters)
    }

    // MARK: - Transcript

    private func appendMessage(
        _ message: AgentMessage,
        sessionID: String,
        sessionKey: String,
        transcript: any SessionTranscriptStore
    ) async throws {
        try await transcript.appendMessage(message, sessionID: sessionID)
        if let engine = await self.deps.contextEngines.selected() {
            _ = await engine.ingest(sessionID: sessionID, sessionKey: sessionKey, message: message)
        }
    }

    private func recordInterruptedTurn(
        error: Error,
        control: AgentRunControl,
        accumulator: AgentStreamAccumulator,
        sessionID: String,
        request: AgentRunRequest,
        transcript: any SessionTranscriptStore
    ) async throws {
        let aborted = error is CancellationError || control.cancellation != nil
        let partial = accumulator.partialVisibleText
        guard aborted || !partial.isEmpty else { return }
        let message = AgentAssistantMessage(
            content: partial.isEmpty ? [] : [.text(partial)],
            provider: request.modelProviderID ?? "",
            model: request.modelID ?? "",
            stopReason: aborted ? .aborted : .error,
            errorMessage: aborted ? (control.cancellation == .timedOut ? "timed out" : "aborted") : error.localizedDescription,
            timestamp: SessionTranscriptClock.nowMs()
        )
        try await transcript.appendMessage(.assistant(message), sessionID: sessionID)
    }

    // MARK: - Prompts

    struct WorkspacePrompt: Sendable {
        var bootstrap: String?
        var skills: String?
    }

    static func loadWorkspacePrompt(_ workspaceRootPath: String?) async throws -> WorkspacePrompt {
        guard let trimmed = workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return WorkspacePrompt()
        }
        let root = URL(fileURLWithPath: trimmed)
        let skills = try await SkillRegistry(workspaceRoot: root).loadPromptSnapshot().prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let bootstrap = try await BootstrapContextLoader(workspaceRoot: root).loadPromptSnapshot().prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspacePrompt(bootstrap: bootstrap.isEmpty ? nil : bootstrap, skills: skills.isEmpty ? nil : skills)
    }

    /// Legacy single-message prompt (bootstrap, skills, attachments, `## User Request`) used for
    /// providers that predate contract v2; byte-identical to the 2026.2 composition.
    static func composeLegacyPrompt(basePrompt: String, workspace: WorkspacePrompt, attachments: [MediaAttachment]) -> String {
        var sections: [String] = []
        if let bootstrap = workspace.bootstrap {
            sections.append(bootstrap)
        }
        if let skills = workspace.skills {
            sections.append(skills)
        }
        if !attachments.isEmpty {
            sections.append(Self.composeAttachmentSection(attachments))
        }
        if sections.isEmpty {
            return basePrompt
        }
        sections.append("## User Request")
        sections.append(basePrompt)
        return sections.joined(separator: "\n\n")
    }

    private func composeSystemPrompt(
        workspace: WorkspacePrompt,
        request: AgentRunRequest,
        session: SessionRecord?,
        addition: String?,
        directory: String?
    ) async -> String? {
        var sections: [String] = []
        if let base = self.deps.configuration.baseSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            sections.append(base)
        }
        // The tool directory is cache-stable, so it precedes every dynamic section.
        if let directory {
            sections.append(directory)
        }
        if let bootstrap = workspace.bootstrap {
            sections.append(bootstrap)
        }
        if let skills = workspace.skills {
            sections.append(skills)
        }
        if let extra = request.extraSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            sections.append(extra)
        }
        if let addition = addition?.trimmingCharacters(in: .whitespacesAndNewlines), !addition.isEmpty {
            sections.append(addition)
        }
        if let goal = session?.goal, goal.status.isOpen {
            sections.append(goal.promptLine)
        }
        sections.append(contentsOf: await self.deps.promptContributors(request.sessionKey, session).filter { !$0.isEmpty })
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    static func composeAttachmentSection(_ attachments: [MediaAttachment]) -> String {
        var lines: [String] = ["## Attachments"]
        lines.reserveCapacity(attachments.count + 1)
        for attachment in attachments {
            let trimmedName = attachment.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = trimmedName.isEmpty ? "attachment-\(attachment.id.uuidString.prefix(8))" : trimmedName
            let kind = attachment.metadata["kind"] ?? "unknown"
            lines.append("- \(displayName) (\(attachment.mimeType), kind=\(kind), bytes=\(attachment.byteCount))")
        }
        return lines.joined(separator: "\n")
    }

    static func normalizeAttachments(_ attachments: [MediaAttachment], using mediaPipeline: MediaPipeline) async throws -> [MediaAttachment] {
        guard !attachments.isEmpty else { return [] }
        var normalized: [MediaAttachment] = []
        normalized.reserveCapacity(attachments.count)
        for attachment in attachments {
            normalized.append(try await mediaPipeline.prepare(attachment).attachment)
        }
        return normalized
    }

    static func makeModelRequest(
        from request: AgentRunRequest,
        legacyPrompt: String,
        systemPrompt: String?,
        messages: [ModelMessage],
        tools: [ModelToolDefinition],
        streamTokens: Bool
    ) -> ModelGenerationRequest {
        ModelGenerationRequest(
            sessionKey: request.sessionKey,
            prompt: legacyPrompt,
            systemPrompt: systemPrompt,
            providerID: request.modelProviderID,
            modelID: request.modelID,
            metadata: Self.modelControlMetadata(from: request),
            policy: ModelGenerationPolicy(
                streamTokens: streamTokens,
                requestTimeoutMs: request.modelTimeoutMs,
                reasoningEffort: Self.reasoningEffort(from: request.thinkingLevel, reasoningLevel: request.reasoningLevel),
                fastMode: request.fastMode,
                // `ultra` is runtime orchestration only; provider transports receive `max`.
                thinkingLevel: request.thinkingLevel?.providerTransportLevel,
                reasoningLevel: request.reasoningLevel,
                verboseLevel: request.verboseLevel,
                responseUsage: request.responseUsage,
                elevatedLevel: request.elevatedLevel
            ),
            messages: messages,
            tools: tools
        )
    }

    static func reasoningEffort(from thinkingLevel: ThinkLevel?, reasoningLevel: ReasoningLevel?) -> ModelReasoningEffort? {
        if reasoningLevel == .off {
            return nil
        }
        switch thinkingLevel {
        case .minimal, .low:
            return .low
        case .medium:
            return .medium
        case .high, .xhigh, .max, .ultra:
            // ModelReasoningEffort tops out at `.high`; richer effort mapping is provider-owned.
            return .high
        case .off, .adaptive, nil:
            return nil
        }
    }

    static func modelControlMetadata(from request: AgentRunRequest) -> [String: String] {
        var metadata: [String: String] = [:]
        if let thinkingLevel = request.thinkingLevel?.providerTransportLevel {
            metadata["thinkingLevel"] = thinkingLevel.rawValue
        }
        if let reasoningLevel = request.reasoningLevel {
            metadata["reasoningLevel"] = reasoningLevel.rawValue
        }
        if let verboseLevel = request.verboseLevel {
            metadata["verboseLevel"] = verboseLevel.rawValue
        }
        if let responseUsage = request.responseUsage {
            metadata["responseUsage"] = responseUsage.rawValue
        }
        if let elevatedLevel = request.elevatedLevel {
            metadata["elevatedLevel"] = elevatedLevel.rawValue
        }
        return metadata
    }

    private func emitDiagnostic(_ name: String, request: AgentRunRequest, metadata: [String: String]) async {
        guard let sink = self.deps.diagnostics else { return }
        await sink(RuntimeDiagnosticEvent(subsystem: "runtime", name: name, runID: request.runID, sessionKey: request.sessionKey, metadata: metadata))
    }
}
