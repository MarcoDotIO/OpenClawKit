import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

// Background task ledger (upstream `packages/gateway-protocol/src/schema/tasks.ts`,
// `docs/automation/tasks.md`). Tasks are records of detached work (sub-agents, cron runs, long tools);
// chat and heartbeat runs do not create tasks.

/// Task lifecycle status (upstream `TaskLedgerStatus`).
public enum AgentTaskStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// Waiting to start.
    case queued
    /// Running.
    case running
    /// Finished successfully.
    case completed
    /// Failed.
    case failed
    /// Cancelled.
    case cancelled
    /// Timed out.
    case timedOut = "timed_out"

    /// Whether the status is terminal.
    public var isTerminal: Bool {
        switch self {
        case .queued, .running:
            return false
        case .completed, .failed, .cancelled, .timedOut:
            return true
        }
    }
}

/// Kind of work a task tracks.
public enum AgentTaskKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Embedded sub-agent run.
    case subagent
    /// Scheduled automation run.
    case cron
    /// Long-running tool.
    case tool
}

/// Live execution state of a task (upstream `TaskExecution`).
public struct AgentTaskExecution: Codable, Sendable, Equatable {
    /// Tool currently running.
    public struct CurrentTool: Codable, Sendable, Equatable {
        /// Tool name.
        public var name: String
        /// Start time (ms).
        public var startedAt: Int64
    }

    /// What the task waits for.
    public struct Wait: Codable, Sendable, Equatable {
        /// `children`, `external`, `agent_messages`, `approval` or `user_input`.
        public var kind: String
        /// Pending dependency count.
        public var pendingCount: Int?
    }

    /// `queued`, `running`, `waiting`, `finished` or `unknown`.
    public var state: String
    /// Tool currently running.
    public var currentTool: CurrentTool?
    /// Last activity time (ms).
    public var lastActivityAt: Int64?
    /// Wait reason.
    public var wait: Wait?
}

/// One task record (upstream `TaskSummary`).
public struct AgentTaskRecord: Codable, Sendable, Equatable {
    /// Task id.
    public var id: String
    /// Task kind.
    public var kind: AgentTaskKind
    /// Runtime (`embedded`).
    public var runtime: String
    /// Status.
    public var status: AgentTaskStatus
    /// Display title.
    public var title: String?
    /// Agent id.
    public var agentID: String?
    /// Owning (parent) session.
    public var sessionKey: String?
    /// Child session (sub-agents).
    public var childSessionKey: String?
    /// Whether the child has a transcript.
    public var hasTranscript: Bool?
    /// Run id.
    public var runID: String?
    /// Parent task.
    public var parentTaskID: String?
    /// Source id (cron job id).
    public var sourceID: String?
    /// Creation time (ms).
    public var createdAt: Int64
    /// Last update (ms).
    public var updatedAt: Int64
    /// Start time (ms).
    public var startedAt: Int64?
    /// End time (ms).
    public var endedAt: Int64?
    /// Tool calls made.
    public var toolUseCount: Int
    /// Last tool name.
    public var lastToolName: String?
    /// Live execution state.
    public var execution: AgentTaskExecution?
    /// Last activity line (≤ 200 characters).
    public var lastActivity: String?
    /// Progress summary.
    public var progressSummary: String?
    /// Terminal summary.
    public var terminalSummary: String?
    /// Error message.
    public var error: String?
    /// Delivery status of the completion announcement.
    public var deliveryStatus: String?
    /// `succeeded` or `blocked`.
    public var terminalOutcome: String?
    /// Final result text (returned by `tasks.get` only).
    public var result: String?
    /// Task prompt (returned by `tasks.get` only).
    public var prompt: String?

    /// Upstream `TaskSummary` JSON (`result` and `prompt` only when `includeDetails`).
    /// - Parameter includeDetails: Include `result` and `prompt`.
    /// - Returns: The payload.
    public func payload(includeDetails: Bool = false) -> [String: AnyCodable] {
        var payload: [String: AnyCodable] = [
            "id": AnyCodable(self.id),
            "taskId": AnyCodable(self.id),
            "kind": AnyCodable(self.kind.rawValue),
            "runtime": AnyCodable(self.runtime),
            "status": AnyCodable(self.status.rawValue),
            "createdAt": AnyCodable(self.createdAt),
            "updatedAt": AnyCodable(self.updatedAt),
            "toolUseCount": AnyCodable(self.toolUseCount),
        ]
        func set(_ key: String, _ value: String?) {
            if let value { payload[key] = AnyCodable(value) }
        }
        set("title", self.title)
        set("agentId", self.agentID)
        set("sessionKey", self.sessionKey)
        set("childSessionKey", self.childSessionKey)
        set("runId", self.runID)
        set("parentTaskId", self.parentTaskID)
        set("sourceId", self.sourceID)
        set("lastToolName", self.lastToolName)
        set("lastActivity", self.lastActivity)
        set("progressSummary", self.progressSummary)
        set("terminalSummary", self.terminalSummary)
        set("error", self.error)
        set("deliveryStatus", self.deliveryStatus)
        set("terminalOutcome", self.terminalOutcome)
        if let hasTranscript { payload["hasTranscript"] = AnyCodable(hasTranscript) }
        if let startedAt { payload["startedAt"] = AnyCodable(startedAt) }
        if let endedAt { payload["endedAt"] = AnyCodable(endedAt) }
        if let execution { payload["execution"] = (try? AnyCodable(encoding: execution)) ?? .nullValue }
        if includeDetails {
            set("result", self.result)
            set("prompt", self.prompt)
        }
        return payload
    }
}

/// Actor persisting task records and deriving their state from agent events.
public actor TaskLedger {
    /// Retention of terminal records (7 days; upstream docs).
    public static let terminalRetentionMs: Int64 = 7 * 86_400_000

    /// Cancels the run behind a task; returns whether a run was cancelled.
    public typealias Canceller = @Sendable (AgentTaskRecord) async -> Bool

    private var tasks: [String: AgentTaskRecord] = [:]
    private var subscribers: [UUID: AsyncStream<AgentTaskRecord>.Continuation] = [:]
    private var listeners: [@Sendable (AgentTaskRecord) async -> Void] = []
    private var canceller: Canceller?
    private let fileURL: URL?
    private let clock: @Sendable () -> Int64

    /// Creates a ledger.
    /// - Parameters:
    ///   - fileURL: Optional JSON file persisting records.
    ///   - clock: Millisecond clock.
    public init(fileURL: URL? = nil, clock: @escaping @Sendable () -> Int64 = { SessionTranscriptClock.nowMs() }) {
        self.fileURL = fileURL
        self.clock = clock
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([AgentTaskRecord].self, from: data)
        {
            self.tasks = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        }
    }

    /// Sets the canceller used by ``cancel(id:reason:)``.
    /// - Parameter canceller: Canceller.
    public func setCanceller(_ canceller: @escaping Canceller) {
        self.canceller = canceller
    }

    /// Follows a runtime's events and cancels tasks through its `abort(runID:)`.
    /// - Parameter runtime: Runtime.
    public func attach(to runtime: EmbeddedAgentRuntime) {
        let events = runtime.events()
        Task { [weak self] in
            for await frame in events {
                guard let self else { return }
                await self.observe(frame)
            }
        }
        self.canceller = { [weak runtime] task in
            guard let runtime, let runID = task.runID else { return false }
            return await runtime.abort(runID: runID)
        }
    }

    /// Stream of task changes (for Live Activities and widgets).
    /// - Parameter limit: Buffered updates per subscriber.
    /// - Returns: The stream.
    public func updates(bufferingNewest limit: Int = 128) -> AsyncStream<AgentTaskRecord> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AgentTaskRecord>.makeStream(bufferingPolicy: .bufferingNewest(max(1, limit)))
        self.subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// Adds a change listener (used to emit `task` gateway events).
    /// - Parameter listener: Listener.
    public func addListener(_ listener: @escaping @Sendable (AgentTaskRecord) async -> Void) {
        self.listeners.append(listener)
    }

    private func removeSubscriber(_ id: UUID) {
        self.subscribers[id] = nil
    }

    /// Creates a task.
    @discardableResult
    public func create(
        kind: AgentTaskKind,
        title: String? = nil,
        agentID: String? = nil,
        sessionKey: String? = nil,
        childSessionKey: String? = nil,
        runID: String? = nil,
        parentTaskID: String? = nil,
        sourceID: String? = nil,
        prompt: String? = nil
    ) -> AgentTaskRecord {
        let now = self.clock()
        let record = AgentTaskRecord(
            id: UUID().uuidString.lowercased(),
            kind: kind,
            runtime: "embedded",
            status: .queued,
            title: title,
            agentID: agentID,
            sessionKey: sessionKey,
            childSessionKey: childSessionKey,
            hasTranscript: childSessionKey != nil,
            runID: runID,
            parentTaskID: parentTaskID,
            sourceID: sourceID,
            createdAt: now,
            updatedAt: now,
            toolUseCount: 0,
            execution: AgentTaskExecution(state: "queued"),
            prompt: prompt
        )
        self.store(record)
        return record
    }

    /// Mutates a task.
    /// - Parameters:
    ///   - id: Task id.
    ///   - body: Mutation.
    /// - Returns: The updated record.
    @discardableResult
    public func update(id: String, _ body: @Sendable (inout AgentTaskRecord) -> Void) -> AgentTaskRecord? {
        guard var record = self.tasks[id] else { return nil }
        body(&record)
        record.updatedAt = max(record.updatedAt, self.clock())
        self.store(record)
        return record
    }

    /// Updates tasks from an agent event of their run.
    /// - Parameter frame: Agent event.
    public func observe(_ frame: AgentEventFrame) {
        guard let id = self.tasks.values.first(where: { $0.runID == frame.runID && !$0.status.isTerminal })?.id,
              var record = self.tasks[id]
        else {
            return
        }
        let now = frame.ts
        record.updatedAt = max(record.updatedAt, now)
        var execution = record.execution ?? AgentTaskExecution(state: "running")
        execution.lastActivityAt = now
        switch frame.stream {
        case .lifecycle:
            switch frame.data["phase"]?.stringValue {
            case "start":
                record.status = .running
                record.startedAt = record.startedAt ?? now
                execution.state = "running"
            case "end":
                record.status = .completed
                record.endedAt = now
                record.terminalOutcome = "succeeded"
                execution.state = "finished"
                execution.currentTool = nil
            case "error":
                if frame.data["timedOut"]?.boolValue == true {
                    record.status = .timedOut
                } else if frame.data["aborted"]?.boolValue == true {
                    record.status = .cancelled
                } else {
                    record.status = .failed
                }
                record.error = frame.data["error"]?.stringValue
                record.endedAt = now
                execution.state = "finished"
                execution.currentTool = nil
            default:
                break
            }
        case .tool:
            let name = frame.data["name"]?.stringValue
            switch frame.data["phase"]?.stringValue {
            case "start":
                record.toolUseCount += 1
                record.lastToolName = name
                execution.currentTool = name.map { AgentTaskExecution.CurrentTool(name: $0, startedAt: now) }
                record.lastActivity = name.map { "Running \($0)" }
            case "result":
                execution.currentTool = nil
            default:
                break
            }
        case .assistant:
            if let text = frame.data["text"]?.stringValue, !text.isEmpty {
                record.lastActivity = String(text.suffix(200))
                record.result = text
            }
        case .approval:
            execution.wait = frame.data["phase"]?.stringValue == "requested" ? AgentTaskExecution.Wait(kind: "approval", pendingCount: 1) : nil
            execution.state = execution.wait == nil ? "running" : "waiting"
        default:
            break
        }
        record.execution = execution
        if record.status.isTerminal {
            record.terminalSummary = record.terminalSummary ?? record.lastActivity
        }
        self.store(record)
    }

    /// Records the outcome of a run that finished outside the event stream.
    /// - Parameters:
    ///   - id: Task id.
    ///   - status: Terminal status.
    ///   - result: Result text.
    ///   - error: Error text.
    public func finish(id: String, status: AgentTaskStatus, result: String? = nil, error: String? = nil) {
        guard var record = self.tasks[id], !record.status.isTerminal else { return }
        let now = self.clock()
        record.status = status
        record.endedAt = now
        record.updatedAt = now
        record.result = result ?? record.result
        record.error = error ?? record.error
        record.terminalOutcome = status == .completed ? "succeeded" : record.terminalOutcome
        record.terminalSummary = record.terminalSummary ?? result.map { String($0.prefix(200)) }
        record.execution?.state = "finished"
        record.execution?.currentTool = nil
        self.store(record)
    }

    /// Returns a task.
    /// - Parameter id: Task id.
    /// - Returns: The record.
    public func get(id: String) -> AgentTaskRecord? {
        self.tasks[id]
    }

    /// Task tracking a run, if any.
    /// - Parameter runID: Run id.
    /// - Returns: The record.
    public func task(forRunID runID: String) -> AgentTaskRecord? {
        self.tasks.values.first { $0.runID == runID }
    }

    /// Lists tasks (upstream `tasks.list`).
    /// - Parameters:
    ///   - statuses: Status filter.
    ///   - agentID: Agent filter.
    ///   - sessionKey: Session filter (parent or child).
    ///   - limit: Page size (`1...500`, default 100).
    ///   - cursor: Offset cursor.
    ///   - sortBy: `updatedAt` (default) or `endedAt`, newest first.
    /// - Returns: Tasks and the next cursor.
    public func list(
        statuses: Set<AgentTaskStatus>? = nil,
        agentID: String? = nil,
        sessionKey: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        sortBy: String? = nil
    ) -> (tasks: [AgentTaskRecord], nextCursor: String?) {
        self.prune()
        let filtered = self.tasks.values.filter { task in
            (statuses == nil || statuses?.contains(task.status) == true)
                && (agentID == nil || task.agentID == agentID)
                && (sessionKey == nil || task.sessionKey == sessionKey || task.childSessionKey == sessionKey)
        }
        let sorted = filtered.sorted { lhs, rhs in
            let left = sortBy == "endedAt" ? (lhs.endedAt ?? 0) : lhs.updatedAt
            let right = sortBy == "endedAt" ? (rhs.endedAt ?? 0) : rhs.updatedAt
            return left == right ? lhs.id < rhs.id : left > right
        }
        let pageSize = min(500, max(1, limit ?? 100))
        let start = cursor.flatMap(Int.init) ?? 0
        guard start < sorted.count else { return ([], nil) }
        let end = min(sorted.count, start + pageSize)
        return (Array(sorted[start..<end]), end < sorted.count ? String(end) : nil)
    }

    /// Cancels a task's run (upstream `tasks.cancel`).
    /// - Parameters:
    ///   - id: Task id.
    ///   - reason: Optional reason.
    /// - Returns: Whether the task exists, whether it was cancelled, and the record.
    public func cancel(id: String, reason: String? = nil) async -> (found: Bool, cancelled: Bool, task: AgentTaskRecord?) {
        guard let record = self.tasks[id] else {
            return (false, false, nil)
        }
        guard !record.status.isTerminal else {
            return (true, false, record)
        }
        let cancelled = await self.canceller?(record) ?? false
        let updated = self.update(id: id) { task in
            if !task.status.isTerminal {
                task.status = .cancelled
                task.endedAt = task.endedAt ?? task.updatedAt
                task.error = reason ?? task.error
                task.execution?.state = "finished"
            }
        }
        return (true, cancelled || updated?.status == .cancelled, updated)
    }

    private func store(_ record: AgentTaskRecord) {
        self.tasks[record.id] = record
        for continuation in self.subscribers.values {
            continuation.yield(record)
        }
        let listeners = self.listeners
        if !listeners.isEmpty {
            Task {
                for listener in listeners {
                    await listener(record)
                }
            }
        }
        self.persist()
    }

    private func prune() {
        let cutoff = self.clock() - Self.terminalRetentionMs
        let expired = self.tasks.values.filter { $0.status.isTerminal && ($0.endedAt ?? $0.updatedAt) < cutoff }.map(\.id)
        guard !expired.isEmpty else { return }
        for id in expired {
            self.tasks[id] = nil
        }
        self.persist()
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self.tasks.values.sorted { $0.createdAt < $1.createdAt }) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }

    // MARK: - Gateway

    /// Registers `tasks.list/get/history/cancel` and emits `task` events on the server.
    /// - Parameters:
    ///   - server: Gateway server.
    ///   - runtime: Runtime whose transcripts back `tasks.history`.
    public func attach(to server: GatewayServer, runtime: EmbeddedAgentRuntime) async {
        self.addListener { [weak server] task in
            await server?.broadcast(event: GatewayEventName.task.rawValue, payload: AnyCodable(task.payload()))
        }
        await server.register(method: "tasks.list", descriptor: nil) { [weak self] request in
            guard let self else { throw GatewayMethodError.unavailable("task ledger released") }
            var statuses: Set<AgentTaskStatus>?
            if let raw = request.params["status"] {
                let values = raw.arrayValue?.compactMap(\.stringValue) ?? raw.stringValue.map { [$0] } ?? []
                statuses = Set(values.compactMap(AgentTaskStatus.init(rawValue:)))
            }
            let page = await self.list(
                statuses: statuses,
                agentID: request.params["agentId"]?.stringValue,
                sessionKey: request.params["sessionKey"]?.stringValue,
                limit: request.params["limit"]?.intValue,
                cursor: request.params["cursor"]?.stringValue,
                sortBy: request.params["sortBy"]?.stringValue
            )
            var payload: [String: AnyCodable] = ["tasks": AnyCodable(page.tasks.map { AnyCodable($0.payload()) })]
            if let next = page.nextCursor { payload["nextCursor"] = AnyCodable(next) }
            return AnyCodable(payload)
        }
        await server.register(method: "tasks.get", descriptor: nil) { [weak self] request in
            guard let self else { throw GatewayMethodError.unavailable("task ledger released") }
            guard let id = request.stringParam("taskId"), let task = await self.get(id: id) else {
                throw GatewayMethodError.invalidRequest("unknown task id")
            }
            return AnyCodable(["task": AnyCodable(task.payload(includeDetails: true))])
        }
        await server.register(method: "tasks.history", descriptor: nil) { [weak self, weak runtime] request in
            guard let self, let runtime else { throw GatewayMethodError.unavailable("task ledger released") }
            guard let id = request.stringParam("taskId"), let task = await self.get(id: id) else {
                throw GatewayMethodError.invalidRequest("unknown task id")
            }
            guard let sessionKey = task.childSessionKey ?? task.sessionKey else {
                return AnyCodable(["messages": AnyCodable([AnyCodable]())])
            }
            let messages = (try? await runtime.history(sessionKey: sessionKey)) ?? []
            let limit = min(200, max(1, request.params["limit"]?.intValue ?? 200))
            let start = request.params["cursor"]?.stringValue.flatMap(Int.init) ?? 0
            let page = start < messages.count ? Array(messages[start..<min(messages.count, start + limit)]) : []
            var payload: [String: AnyCodable] = ["messages": (try? AnyCodable(encoding: page)) ?? AnyCodable([AnyCodable]())]
            if start + limit < messages.count { payload["nextCursor"] = AnyCodable(String(start + limit)) }
            return AnyCodable(payload)
        }
        await server.register(method: "tasks.cancel", descriptor: nil) { [weak self] request in
            guard let self else { throw GatewayMethodError.unavailable("task ledger released") }
            guard let id = request.stringParam("taskId") else {
                throw GatewayMethodError.invalidRequest("tasks.cancel requires taskId")
            }
            let outcome = await self.cancel(id: id, reason: request.stringParam("reason"))
            var payload: [String: AnyCodable] = ["found": AnyCodable(outcome.found), "cancelled": AnyCodable(outcome.cancelled)]
            if let task = outcome.task { payload["task"] = AnyCodable(task.payload()) }
            if let reason = request.stringParam("reason") { payload["reason"] = AnyCodable(reason) }
            return AnyCodable(payload)
        }
    }
}
