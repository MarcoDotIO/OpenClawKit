import Foundation
import OpenClawCore
import OpenClawProtocol

// Embedded sub-agents (upstream `docs/tools/subagents.md`, `docs/tools/subagents/tool-reference.md`):
// `sessions_spawn` (in-process subset), `subagents` (list/kill/steer) and `sessions_yield`, with
// `task_completion` announcements delivered to the parent session.

/// Sub-agent settings (SDK counterpart of `agents.defaults.subagents`).
public struct SubagentConfiguration: Sendable, Equatable {
    /// Maximum spawn depth below a top-level session (default 1).
    public var maxDepth: Int
    /// Maximum concurrently running children per parent (default 4).
    public var maxConcurrent: Int
    /// Default child run timeout in seconds (`0` = none).
    public var defaultRunTimeoutSeconds: Int
    /// Token cap for `context: "fork"`; larger parents start isolated with a note.
    public var forkMaxTokens: Int
    /// Tools removed from children (sessions, messaging, sub-agent and agent-management tools).
    public var childToolDeny: [String]

    /// Creates settings.
    public init(
        maxDepth: Int = 1,
        maxConcurrent: Int = 4,
        defaultRunTimeoutSeconds: Int = 0,
        forkMaxTokens: Int = 40_000,
        childToolDeny: [String] = ["sessions", "sessions_*", "message", "subagents", "agents_*", "conversations_*"]
    ) {
        self.maxDepth = max(0, maxDepth)
        self.maxConcurrent = max(1, maxConcurrent)
        self.defaultRunTimeoutSeconds = max(0, defaultRunTimeoutSeconds)
        self.forkMaxTokens = max(0, forkMaxTokens)
        self.childToolDeny = childToolDeny
    }
}

/// Parameters of `sessions_spawn` supported by the embedded runtime.
public struct SubagentSpawnParams: Sendable, Equatable {
    /// Delegated task.
    public var task: String
    /// Short task name (`^[a-z][a-z0-9_-]{0,63}$`).
    public var taskName: String?
    /// Display label.
    public var label: String?
    /// Target agent (defaults to the parent's agent).
    public var agentID: String?
    /// Model ref (`provider/model` or model id).
    public var model: String?
    /// Thinking level.
    public var thinking: ThinkLevel?
    /// Run timeout in seconds (`0` = none).
    public var runTimeoutSeconds: Int?
    /// Context mode.
    public var context: SubagentContextMode
    /// Delete the child session after completion.
    public var deleteOnCompletion: Bool
    /// Announce completion to the parent (default true).
    public var expectsCompletionMessage: Bool

    /// Creates spawn parameters.
    public init(
        task: String,
        taskName: String? = nil,
        label: String? = nil,
        agentID: String? = nil,
        model: String? = nil,
        thinking: ThinkLevel? = nil,
        runTimeoutSeconds: Int? = nil,
        context: SubagentContextMode = .isolated,
        deleteOnCompletion: Bool = false,
        expectsCompletionMessage: Bool = true
    ) {
        self.task = task
        self.taskName = taskName
        self.label = label
        self.agentID = agentID
        self.model = model
        self.thinking = thinking
        self.runTimeoutSeconds = runTimeoutSeconds
        self.context = context
        self.deleteOnCompletion = deleteOnCompletion
        self.expectsCompletionMessage = expectsCompletionMessage
    }

    /// Parameters rejected by the embedded runtime.
    public static let unsupportedKeys: Set<String> = [
        "visible", "worktree", "projectId", "thread", "resumeSessionId", "streamTo", "deliver", "channel", "to",
        "accountId", "threadId", "replyTo",
    ]

    /// Parses model-authored tool arguments.
    /// - Parameter arguments: Tool arguments.
    /// - Returns: Parameters.
    /// - Throws: ``SubagentError/invalid(_:)``.
    public static func parse(_ arguments: [String: AnyCodable]) throws -> SubagentSpawnParams {
        guard let task = arguments["task"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
            throw SubagentError.invalid("sessions_spawn requires a non-empty task")
        }
        if let runtime = arguments["runtime"]?.stringValue, runtime != "subagent" {
            throw SubagentError.invalid("runtime \"\(runtime)\" is not supported in embedded runtime")
        }
        if let placement = arguments["placement"]?.dictionaryValue, placement["kind"]?.stringValue != "local" {
            throw SubagentError.invalid("placement is not supported in embedded runtime")
        }
        if let key = arguments.keys.sorted().first(where: { Self.unsupportedKeys.contains($0) }) {
            throw SubagentError.invalid("\(key) is not supported in embedded runtime")
        }
        let taskName = arguments["taskName"]?.stringValue
        if let taskName, !Self.isValidTaskName(taskName) {
            throw SubagentError.invalid("taskName must match ^[a-z][a-z0-9_-]{0,63}$")
        }
        var timeout: Int?
        if let raw = arguments["runTimeoutSeconds"] {
            guard let seconds = raw.intValue, seconds >= 0 else {
                throw SubagentError.invalid("runTimeoutSeconds must be an integer >= 0")
            }
            timeout = seconds
        }
        let context: SubagentContextMode
        switch arguments["context"]?.stringValue {
        case nil, "isolated":
            context = .isolated
        case "fork":
            context = .fork
        case let other?:
            throw SubagentError.invalid("invalid context \(other) (use isolated|fork)")
        }
        return SubagentSpawnParams(
            task: task,
            taskName: taskName,
            label: arguments["label"]?.stringValue,
            agentID: arguments["agentId"]?.stringValue,
            model: arguments["model"]?.stringValue,
            thinking: ThinkLevel.normalize(arguments["thinking"]?.stringValue),
            runTimeoutSeconds: timeout,
            context: context,
            deleteOnCompletion: arguments["cleanup"]?.stringValue == "delete",
            expectsCompletionMessage: arguments["expectsCompletionMessage"]?.boolValue ?? true
        )
    }

    static func isValidTaskName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, scalars.count <= 64, (97...122).contains(first.value) else { return false }
        return scalars.dropFirst().allSatisfy { (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "_" || $0 == "-" }
    }
}

/// Errors raised by ``SubagentManager``.
public enum SubagentError: Error, LocalizedError, Sendable, Equatable {
    /// Invalid or unsupported parameters.
    case invalid(String)
    /// A limit (depth or concurrency) was reached.
    case limitReached(String)
    /// The target did not resolve.
    case targetNotFound(String)

    /// Human-readable message.
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .limitReached(let message):
            return message
        case .targetNotFound(let target):
            return "No sub-agent matches \(target)"
        }
    }
}

/// One sub-agent known to a parent session.
public struct SubagentRecord: Sendable, Equatable {
    /// Task name (or generated label).
    public var taskName: String
    /// Child session key.
    public var childSessionKey: String
    /// Parent session key.
    public var parentSessionKey: String
    /// Current run id.
    public var runID: String
    /// `running`, `ok`, `error`, `timeout` or `killed`.
    public var status: String
    /// Start time (ms).
    public var startedAt: Int64
    /// End time (ms).
    public var endedAt: Int64?
    /// Last assistant text.
    public var result: String?
    /// Ledger task id.
    public var taskID: String?
    /// Context mode actually used.
    public var context: SubagentContextMode

    /// `subagents list` row.
    public var payload: [String: AnyCodable] {
        var payload: [String: AnyCodable] = [
            "taskName": AnyCodable(self.taskName),
            "childSessionKey": AnyCodable(self.childSessionKey),
            "runId": AnyCodable(self.runID),
            "status": AnyCodable(self.status),
            "startedAt": AnyCodable(self.startedAt),
        ]
        if let endedAt { payload["endedAt"] = AnyCodable(endedAt) }
        if let taskID { payload["taskId"] = AnyCodable(taskID) }
        return payload
    }
}

/// Actor running embedded sub-agents on an ``EmbeddedAgentRuntime``.
public actor SubagentManager {
    private let runtime: EmbeddedAgentRuntime
    private let ledger: TaskLedger?
    private let configuration: SubagentConfiguration
    private var records: [String: SubagentRecord] = [:]
    private var order: [String] = []
    /// Per-run policy and agent of the run that yielded, reused by the wake run.
    private var wakeContexts: [String: (toolPolicy: ToolPolicy?, agentID: String?)] = [:]
    private var depths: [String: Int] = [:]

    /// Creates a manager.
    /// - Parameters:
    ///   - runtime: Runtime executing parent and child runs.
    ///   - ledger: Optional task ledger recording child runs.
    ///   - configuration: Limits and defaults.
    public init(runtime: EmbeddedAgentRuntime, ledger: TaskLedger? = nil, configuration: SubagentConfiguration = SubagentConfiguration()) {
        self.runtime = runtime
        self.ledger = ledger
        self.configuration = configuration
    }

    /// Registers `sessions_spawn`, `subagents` and `sessions_yield` on the runtime.
    public func registerTools() async {
        await self.runtime.registerTool(SessionsSpawnTool(manager: self))
        await self.runtime.registerTool(SubagentsTool(manager: self))
        await self.runtime.registerTool(SessionsYieldTool(manager: self))
    }

    /// Spawns a child run.
    ///
    /// The child inherits the parent's restrictions (upstream `subagent-spawn-session-patch`): its
    /// session record copies the parent's permission mode, sandbox mode, tool overrides and spawned
    /// workspace, and its run policy is the parent's effective policy (the parent run's per-run
    /// policy, else the runtime policy, plus the parent session's read-only and override denies)
    /// minus ``SubagentConfiguration/childToolDeny``. A read-only parent never gets a writable child.
    /// - Parameters:
    ///   - params: Spawn parameters.
    ///   - parentSessionKey: Requesting session.
    ///   - parentAgentID: Requesting agent.
    ///   - parentRunID: Requesting run, whose per-run tool policy the child inherits.
    /// - Returns: The accepted child record.
    /// - Throws: ``SubagentError``.
    @discardableResult
    public func spawn(
        _ params: SubagentSpawnParams,
        parentSessionKey: String,
        parentAgentID: String? = nil,
        parentRunID: String? = nil
    ) async throws -> SubagentRecord {
        let parentDepth = await self.depth(of: parentSessionKey)
        guard parentDepth + 1 <= self.configuration.maxDepth else {
            throw SubagentError.limitReached("sub-agent spawn depth limit (\(self.configuration.maxDepth)) reached")
        }
        let running = self.records.values.filter { $0.parentSessionKey == parentSessionKey && $0.status == "running" }.count
        guard running < self.configuration.maxConcurrent else {
            throw SubagentError.limitReached("sub-agent concurrency limit (\(self.configuration.maxConcurrent)) reached")
        }
        let inheritedAgent = parentAgentID ?? SessionKey.agentID(from: parentSessionKey, fallback: self.runtime.defaultAgentID)
        let agentID = SessionKey.normalizeAgentID(params.agentID ?? inheritedAgent)
        let childKey = SessionKey.subagentKey(agentID: agentID)
        let taskName = params.taskName ?? "task-\(self.order.count + 1)"
        self.depths[childKey] = parentDepth + 1

        let parentRecord = await self.runtime.sessionStore?.recordForKey(parentSessionKey)
        if let store = self.runtime.sessionStore {
            _ = await store.resolveOrCreate(sessionKey: childKey, defaultAgentID: agentID, route: nil)
            await store.update(forKey: childKey) { record in
                record.spawnedBy = parentSessionKey
                record.spawnDepth = parentDepth + 1
                record.label = params.label ?? taskName
                record.permissionMode = parentRecord?.permissionMode
                record.sandboxMode = parentRecord?.sandboxMode
                record.toolOverrides = parentRecord?.toolOverrides
                if let workspace = parentRecord?.spawnedWorkspaceDir {
                    record.spawnedWorkspaceDir = workspace
                }
            }
        }

        var context = params.context
        var note: String?
        if context == .fork {
            let forked = try await self.forkTranscript(from: parentSessionKey, to: childKey)
            if !forked {
                context = .isolated
                note = "The parent context exceeded the fork size cap, so this sub-agent started with isolated context."
            }
        }
        if let engine = await self.runtime.contextEngines.selected() {
            _ = try? await engine.prepareSubagentSpawn(parentSessionKey: parentSessionKey, childSessionKey: childKey, contextMode: context)
        }

        let childPolicy = await self.childPolicy(parentSessionKey: parentSessionKey, parentRunID: parentRunID)
        let modelParts = params.model?.split(separator: "/", maxSplits: 1).map(String.init) ?? []
        var prompt = "[Subagent Task]\n\(params.task)"
        if let note {
            prompt += "\n\n\(note)"
        }
        let request = AgentRunRequest(
            sessionKey: childKey,
            prompt: prompt,
            modelProviderID: modelParts.count == 2 ? modelParts[0] : nil,
            modelID: modelParts.count == 2 ? modelParts[1] : params.model,
            thinkingLevel: params.thinking,
            agentID: agentID,
            toolPolicy: childPolicy,
            extraSystemPrompt: "You are a sub-agent working on one delegated task for a parent session. "
                + "Complete the task and reply with the result; the parent receives your final message.",
            spawnedBy: parentSessionKey
        )
        let task = await self.ledger?.create(
            kind: .subagent,
            title: params.label ?? taskName,
            agentID: agentID,
            sessionKey: parentSessionKey,
            childSessionKey: childKey,
            runID: request.runID,
            prompt: params.task
        )
        let timeoutSeconds = params.runTimeoutSeconds ?? self.configuration.defaultRunTimeoutSeconds
        let runID = await self.runtime.start(request, timeoutMs: timeoutSeconds > 0 ? timeoutSeconds * 1_000 : nil, streaming: true)
        let record = SubagentRecord(
            taskName: taskName,
            childSessionKey: childKey,
            parentSessionKey: parentSessionKey,
            runID: runID,
            status: "running",
            startedAt: SessionTranscriptClock.nowMs(),
            taskID: task?.id,
            context: context
        )
        self.records[childKey] = record
        self.order.append(childKey)
        await self.emitSubagentHook(
            .subagentSpawned,
            SubagentHookEvent(childSessionKey: childKey, agentId: agentID, runId: runID, label: params.label ?? taskName, mode: context.rawValue),
            parentSessionKey: parentSessionKey
        )
        Task {
            let outcome = await self.runtime.wait(runID: runID)
            await self.complete(childKey: childKey, runID: runID, outcome: outcome, params: params)
        }
        return record
    }

    /// Run policy for a child: the parent's effective policy (its run's per-run policy, else the
    /// runtime policy, plus the parent session's denies) minus the child deny list.
    private func childPolicy(parentSessionKey: String, parentRunID: String?) async -> ToolPolicy {
        let base = await self.runtime.currentToolsConfiguration().policy
        var parentRunPolicy: ToolPolicy?
        if let parentRunID, let context = await self.runtime.activeRunContext(runID: parentRunID) {
            parentRunPolicy = context.toolPolicy
        }
        let parentRecord = await self.runtime.sessionStore?.recordForKey(parentSessionKey)
        return AgentLoop.effectivePolicy(base: base, requestPolicy: parentRunPolicy, session: parentRecord)
            .denying(self.configuration.childToolDeny)
    }

    /// Emits a typed sub-agent hook on the runtime's shared registry.
    private func emitSubagentHook(_ hook: HookName, _ event: SubagentHookEvent, parentSessionKey: String) async {
        guard let registry = self.runtime.hookRegistry, await registry.hasHandlers(for: hook) else { return }
        await registry.emitObserving(hook, event: event, context: HookContext(runID: event.runId, sessionKey: parentSessionKey, agentID: event.agentId))
    }

    /// Children of a parent, oldest first.
    /// - Parameter parentSessionKey: Parent session.
    /// - Returns: Records.
    public func children(of parentSessionKey: String) -> [SubagentRecord] {
        self.order.compactMap { self.records[$0] }.filter { $0.parentSessionKey == parentSessionKey }
    }

    /// Resolves a target (`all`, `last`, 1-based index, task name or prefix, session key, run id).
    /// - Parameters:
    ///   - target: Target text.
    ///   - parentSessionKey: Parent session.
    /// - Returns: Matching records.
    public func resolve(target: String, parentSessionKey: String) -> [SubagentRecord] {
        let children = self.children(of: parentSessionKey)
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "all":
            return children
        case "last":
            return children.last.map { [$0] } ?? []
        default:
            break
        }
        if let index = Int(trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed), index >= 1, index <= children.count {
            return [children[index - 1]]
        }
        if let exact = children.first(where: { $0.taskName == trimmed || $0.childSessionKey == trimmed || $0.runID == trimmed }) {
            return [exact]
        }
        let prefixed = children.filter { $0.taskName.hasPrefix(trimmed) }
        return prefixed.count == 1 ? prefixed : []
    }

    /// Kills matching running children.
    /// - Parameters:
    ///   - target: Target text.
    ///   - parentSessionKey: Parent session.
    /// - Returns: Killed records.
    /// - Throws: ``SubagentError/targetNotFound(_:)``.
    @discardableResult
    public func kill(target: String, parentSessionKey: String) async throws -> [SubagentRecord] {
        let matches = self.resolve(target: target, parentSessionKey: parentSessionKey)
        guard !matches.isEmpty else { throw SubagentError.targetNotFound(target) }
        var killed: [SubagentRecord] = []
        for record in matches where record.status == "running" {
            await self.runtime.abort(runID: record.runID)
            var updated = record
            updated.status = "killed"
            updated.endedAt = SessionTranscriptClock.nowMs()
            self.records[record.childSessionKey] = updated
            killed.append(updated)
        }
        return killed
    }

    /// Sends a message to a child (interrupting its current run). The new child run inherits the
    /// parent's current restrictions like a spawn does.
    /// - Parameters:
    ///   - target: Target text.
    ///   - message: Message.
    ///   - parentSessionKey: Parent session.
    ///   - parentRunID: Steering run, whose per-run tool policy the child inherits.
    /// - Returns: The new child run id.
    /// - Throws: ``SubagentError``.
    public func steer(target: String, message: String, parentSessionKey: String, parentRunID: String? = nil) async throws -> String {
        let matches = self.resolve(target: target, parentSessionKey: parentSessionKey)
        guard matches.count == 1, let record = matches.first else { throw SubagentError.targetNotFound(target) }
        if record.status == "running" {
            await self.runtime.abort(runID: record.runID)
        }
        let request = AgentRunRequest(
            sessionKey: record.childSessionKey,
            prompt: message,
            agentID: SessionKey.agentID(from: record.childSessionKey, fallback: self.runtime.defaultAgentID),
            toolPolicy: await self.childPolicy(parentSessionKey: parentSessionKey, parentRunID: parentRunID),
            spawnedBy: parentSessionKey
        )
        let runID = await self.runtime.start(request, streaming: true)
        var updated = record
        updated.runID = runID
        updated.status = "running"
        updated.endedAt = nil
        self.records[record.childSessionKey] = updated
        Task {
            let outcome = await self.runtime.wait(runID: runID)
            await self.complete(childKey: record.childSessionKey, runID: runID, outcome: outcome, params: nil)
        }
        return runID
    }

    /// Prompt of the run that wakes a yielded parent (the completions arrive as internal events).
    static let wakePrompt = "[Subagent completion] Sub-agent results arrived; continue with them."

    /// Marks a parent as yielded: the next child completion wakes it with a new run. When
    /// completions already arrived while the parent was working, it wakes as soon as it is idle.
    /// The wake run keeps the yielding run's per-run tool policy and agent.
    /// - Parameters:
    ///   - parentSessionKey: Parent session.
    ///   - runID: The yielding run.
    public func markYielded(_ parentSessionKey: String, runID: String? = nil) async {
        if let runID, let context = await self.runtime.activeRunContext(runID: runID) {
            self.wakeContexts[parentSessionKey] = context
        }
        // The runtime checks for queued completions and marks the yield in one actor turn; a
        // completion enqueued in between claims the yield instead (see `complete`), so exactly one
        // side schedules the wake.
        if await self.runtime.markYieldedUnlessEventsPending(sessionKey: parentSessionKey) {
            self.scheduleWake(parentSessionKey)
        }
    }

    /// Starts a parent run once the parent's current runs have finished.
    private func scheduleWake(_ parentSessionKey: String) {
        let runtime = self.runtime
        let context = self.wakeContexts.removeValue(forKey: parentSessionKey)
        Task {
            for runID in await runtime.activeRunIDs(sessionKey: parentSessionKey) {
                _ = await runtime.wait(runID: runID)
            }
            let request = AgentRunRequest(
                sessionKey: parentSessionKey,
                prompt: Self.wakePrompt,
                agentID: context?.agentID,
                toolPolicy: context?.toolPolicy
            )
            _ = await runtime.start(request, streaming: true)
        }
    }

    private func depth(of sessionKey: String) async -> Int {
        if let known = self.depths[sessionKey] {
            return known
        }
        return await self.runtime.sessionStore?.recordForKey(sessionKey)?.spawnDepth ?? 0
    }

    private func forkTranscript(from parent: String, to child: String) async throws -> Bool {
        guard let transcript = self.runtime.transcriptStore else { return false }
        let parentID = await self.runtime.transcriptSessionID(for: parent)
        guard try await transcript.header(sessionID: parentID) != nil else { return true }
        let messages = try await transcript.contextMessages(sessionID: parentID)
        guard TokenEstimator.estimate(messages) <= self.configuration.forkMaxTokens else { return false }
        let childID = await self.runtime.transcriptSessionID(for: child)
        try await transcript.ensureSession(id: childID, cwd: "", parentSession: parentID)
        for message in messages {
            try await transcript.appendMessage(message, sessionID: childID)
        }
        return true
    }

    private func complete(childKey: String, runID: String, outcome: AgentRunWaitResult?, params: SubagentSpawnParams?) async {
        guard var record = self.records[childKey], record.runID == runID else { return }
        let status = record.status == "killed" ? "killed" : (outcome?.status ?? "unknown")
        record.status = status
        record.endedAt = SessionTranscriptClock.nowMs()
        record.result = outcome?.output
        self.records[childKey] = record
        if let taskID = record.taskID {
            let taskStatus: AgentTaskStatus
            switch status {
            case "ok":
                taskStatus = .completed
            case "timeout":
                taskStatus = .timedOut
            case "killed":
                taskStatus = .cancelled
            default:
                taskStatus = .failed
            }
            await self.ledger?.finish(id: taskID, status: taskStatus, result: outcome?.output, error: outcome?.error)
        }
        if let engine = await self.runtime.contextEngines.selected() {
            await engine.onSubagentEnded(childSessionKey: childKey, reason: .completed)
        }
        await self.emitSubagentHook(
            .subagentEnded,
            SubagentHookEvent(
                childSessionKey: childKey,
                runId: runID,
                label: record.taskName,
                mode: record.context.rawValue,
                outcome: status,
                error: outcome?.error
            ),
            parentSessionKey: record.parentSessionKey
        )
        let announce = params?.expectsCompletionMessage ?? true
        if announce, status != "killed" {
            let event = Self.completionEvent(record: record, outcome: outcome)
            // Enqueue and claim a pending yield atomically; the woken run drains the event.
            if await self.runtime.enqueueInternalEventClaimingYield(event, sessionKey: record.parentSessionKey) {
                self.scheduleWake(record.parentSessionKey)
            }
        }
        if params?.deleteOnCompletion == true {
            _ = try? await self.runtime.deleteSession(sessionKey: childKey)
        }
    }

    /// `task_completion` internal event text (upstream `AgentInternalEvent`).
    static func completionEvent(record: SubagentRecord, outcome: AgentRunWaitResult?) -> String {
        let status: String
        switch record.status {
        case "ok", "timeout", "error":
            status = record.status
        default:
            status = "unknown"
        }
        let statusLabel = ["ok": "completed", "timeout": "timed out", "error": "failed"][status] ?? "finished"
        let event: [String: AnyCodable] = [
            "type": AnyCodable("task_completion"),
            "source": AnyCodable("subagent"),
            "childSessionKey": AnyCodable(record.childSessionKey),
            "announceType": AnyCodable("subagent_completion"),
            "taskLabel": AnyCodable(record.taskName),
            "status": AnyCodable(status),
            "statusLabel": AnyCodable(statusLabel),
            "result": AnyCodable(outcome?.output ?? outcome?.error ?? ""),
            "replyInstruction": AnyCodable("Use the sub-agent result to continue the parent task; summarize it for the user if relevant."),
        ]
        let json = AgentToolOutput.renderText(AnyCodable(event))
        return "[Subagent completion] \(record.taskName) \(statusLabel).\n\(json)"
    }
}

/// `sessions_spawn` tool (embedded subset).
struct SessionsSpawnTool: AgentTool {
    let name = "sessions_spawn"
    let manager: SubagentManager

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "Spawn Sub-agent",
            description: "Spawn a sub-agent session that works on one delegated task in the background and announces its result. "
                + "Use context \"fork\" only when the task depends on this conversation.",
            displaySummary: "Spawn subagent session.",
            parameters: [
                "type": AnyCodable("object"),
                "required": AnyCodable(["task"]),
                "properties": AnyCodable([
                    "task": AnyCodable(["type": AnyCodable("string"), "minLength": AnyCodable(1)]),
                    "taskName": AnyCodable(["type": AnyCodable("string"), "pattern": AnyCodable("^[a-z][a-z0-9_-]{0,63}$")]),
                    "label": AnyCodable(["type": AnyCodable("string")]),
                    "agentId": AnyCodable(["type": AnyCodable("string")]),
                    "model": AnyCodable(["type": AnyCodable("string")]),
                    "thinking": AnyCodable(["type": AnyCodable("string")]),
                    "runTimeoutSeconds": AnyCodable(["type": AnyCodable("integer"), "minimum": AnyCodable(0)]),
                    "context": AnyCodable(["type": AnyCodable("string"), "enum": AnyCodable(["isolated", "fork"])]),
                    "cleanup": AnyCodable(["type": AnyCodable("string"), "enum": AnyCodable(["delete", "keep"])]),
                    "expectsCompletionMessage": AnyCodable(["type": AnyCodable("boolean")]),
                    "runtime": AnyCodable(["type": AnyCodable("string")]),
                ]),
            ],
            sectionID: "sessions",
            defaultProfiles: [.coding, .messaging],
            risk: .medium
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        guard let parent = invocation.sessionKey else {
            return .error("sessions_spawn requires a session")
        }
        do {
            let params = try SubagentSpawnParams.parse(invocation.arguments)
            let record = try await self.manager.spawn(params, parentSessionKey: parent, parentAgentID: invocation.agentID, parentRunID: invocation.runID)
            var details: [String: AnyCodable] = [
                "status": AnyCodable("accepted"),
                "childSessionKey": AnyCodable(record.childSessionKey),
                "runId": AnyCodable(record.runID),
                "context": AnyCodable(record.context.rawValue),
            ]
            if let model = params.model {
                details["resolvedModel"] = AnyCodable(model)
                if let provider = model.split(separator: "/", maxSplits: 1).first, model.contains("/") {
                    details["resolvedProvider"] = AnyCodable(String(provider))
                }
            }
            return .json(AnyCodable(details))
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

/// `subagents` tool: list, kill and steer children.
struct SubagentsTool: AgentTool {
    let name = "subagents"
    let manager: SubagentManager

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "Sub-agents",
            description: "List, kill or steer this session's sub-agents. Targets: task name or prefix, 1-based index, "
                + "session key, run id, \"last\" or \"all\".",
            parameters: [
                "type": AnyCodable("object"),
                "required": AnyCodable(["action"]),
                "properties": AnyCodable([
                    "action": AnyCodable(["type": AnyCodable("string"), "enum": AnyCodable(["list", "kill", "steer"])]),
                    "target": AnyCodable(["type": AnyCodable("string")]),
                    "message": AnyCodable(["type": AnyCodable("string")]),
                ]),
            ],
            sectionID: "sessions",
            defaultProfiles: [.coding, .messaging]
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        guard let parent = invocation.sessionKey else { return .error("subagents requires a session") }
        let target = invocation.arguments["target"]?.stringValue ?? "last"
        do {
            switch invocation.arguments["action"]?.stringValue {
            case "list":
                let rows = await self.manager.children(of: parent).map { AnyCodable($0.payload) }
                return .json(AnyCodable(["subagents": AnyCodable(rows)]))
            case "kill":
                let killed = try await self.manager.kill(target: target, parentSessionKey: parent)
                return .json(AnyCodable(["killed": AnyCodable(killed.map { AnyCodable($0.payload) })]))
            case "steer":
                guard let message = invocation.arguments["message"]?.stringValue, !message.isEmpty else {
                    return .error("steer requires a message")
                }
                let runID = try await self.manager.steer(target: target, message: message, parentSessionKey: parent, parentRunID: invocation.runID)
                return .json(AnyCodable(["status": AnyCodable("steered"), "runId": AnyCodable(runID)]))
            default:
                return .error("action must be list, kill or steer")
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

/// `sessions_yield` tool: ends the turn; the next turn starts when a child completes.
struct SessionsYieldTool: AgentTool {
    let name = "sessions_yield"
    let manager: SubagentManager

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "Yield",
            description: "End this turn and wait for sub-agent results; the session resumes when a sub-agent completes.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["message": AnyCodable(["type": AnyCodable("string")])]),
            ],
            sectionID: "sessions",
            defaultProfiles: [.coding, .messaging],
            catalogMode: .directOnly
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        if let parent = invocation.sessionKey {
            await self.manager.markYielded(parent, runID: invocation.runID)
        }
        let message = invocation.arguments["message"]?.stringValue ?? "Waiting for sub-agent results."
        return AgentToolOutput(content: [.text(message)], details: AnyCodable(["status": AnyCodable("yielded")]), terminate: true)
    }
}
