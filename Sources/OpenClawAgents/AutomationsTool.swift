import Foundation
import OpenClawCore
import OpenClawProtocol

/// Delivers a `systemEvent` / wake text into a session (for example by enqueuing a system message).
public typealias AutomationSystemEventSink = @Sendable (_ sessionKey: String, _ text: String) async throws -> Void

/// Runs automation jobs on the embedded agent runtime.
///
/// `agentTurn` jobs run ``EmbeddedAgentRuntime/run(_:timeoutMs:)`` in the job's resolved session
/// (isolated jobs get `agent:<id>:cron:<jobId>:<runId>`). `systemEvent` jobs go to the system-event
/// sink when one is configured, and otherwise run as an agent turn with the event text.
public struct EmbeddedAgentAutomationExecutor: Sendable {
    private let runtime: EmbeddedAgentRuntime
    private let systemEventSink: AutomationSystemEventSink?
    private let workspaceRootPath: String?
    private let defaultTimeoutMs: Int

    /// Creates the executor.
    /// - Parameters:
    ///   - runtime: Embedded runtime.
    ///   - systemEventSink: System-event sink.
    ///   - workspaceRootPath: Workspace for prompt assembly.
    ///   - defaultTimeoutMs: Timeout when the payload has none.
    public init(
        runtime: EmbeddedAgentRuntime,
        systemEventSink: AutomationSystemEventSink? = nil,
        workspaceRootPath: String? = nil,
        defaultTimeoutMs: Int = 120_000
    ) {
        self.runtime = runtime
        self.systemEventSink = systemEventSink
        self.workspaceRootPath = workspaceRootPath
        self.defaultTimeoutMs = defaultTimeoutMs
    }

    /// The executor as a scheduler callback.
    public var executor: AutomationJobExecutor {
        { run in try await self.execute(run) }
    }

    /// Runs one job.
    /// - Parameter run: Run.
    /// - Returns: Outcome.
    public func execute(_ run: AutomationJobRun) async throws -> AutomationRunOutcome {
        switch run.job.payload {
        case .systemEvent(let text, _):
            if let systemEventSink {
                try await systemEventSink(run.sessionKey, text)
                return AutomationRunOutcome(status: .ok, summary: text)
            }
            return try await self.runTurn(prompt: text, run: run, payload: nil)
        case .agentTurn(let payload):
            return try await self.runTurn(prompt: payload.message, run: run, payload: payload)
        case .unsupported(let kind, _):
            return AutomationRunOutcome(status: .skipped, error: "payload kind \(kind) is not supported")
        }
    }

    private func runTurn(prompt: String, run: AutomationJobRun, payload: CronAgentTurnPayload?) async throws -> AutomationRunOutcome {
        var providerID: String?
        var modelID: String?
        if let model = payload?.model, !model.isEmpty {
            let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
            providerID = parts.first
            modelID = parts.count > 1 ? parts[1] : nil
        }
        let request = AgentRunRequest(
            runID: run.runID,
            sessionKey: run.sessionKey,
            prompt: prompt,
            modelProviderID: providerID,
            modelID: modelID,
            thinkingLevel: payload?.thinking.flatMap { ThinkLevel.normalize($0) },
            workspaceRootPath: self.workspaceRootPath
        )
        // `timeoutSeconds` comes from a (possibly model-authored) job payload: clamp before converting.
        let timeoutMs = RuntimeTime.clampedInt(payload?.timeoutSeconds.map { $0 * 1_000 }, to: 1...Int.max) ?? self.defaultTimeoutMs
        let result = try await self.runtime.run(request, timeoutMs: max(1, timeoutMs))
        return AutomationRunOutcome(status: .ok, summary: String(result.output.prefix(500)))
    }
}

/// The `automations` agent tool (upstream scheduler tool; `cron` is a permanent alias).
///
/// Actions: `status`, `list`, `get`, `add`, `update` (partial `job` patch, `null` clears), `remove`,
/// `run` (`runMode` `due` or `force`), `runs`, `next_check` (`in` duration, for example `15m`), and
/// `wake` (`text` system event). Schedule kinds `on-exit`/`stream` and payload kinds
/// `command`/`script`/`heartbeat` are rejected with an actionable error.
public struct AutomationsTool: AgentTool {
    /// Tool name.
    public let name = "automations"
    private let scheduler: CronScheduler
    private let systemEventSink: AutomationSystemEventSink?
    private let defaultAgentID: String

    /// Creates the tool.
    /// - Parameters:
    ///   - scheduler: Scheduler.
    ///   - systemEventSink: Sink for `wake` text.
    ///   - defaultAgentID: Agent used for new jobs when the call has none.
    public init(scheduler: CronScheduler, systemEventSink: AutomationSystemEventSink? = nil, defaultAgentID: String = "main") {
        self.scheduler = scheduler
        self.systemEventSink = systemEventSink
        self.defaultAgentID = defaultAgentID
    }

    /// Supported actions.
    public static let actions = ["status", "list", "get", "add", "update", "remove", "run", "runs", "next_check", "wake"]

    /// JSON Schema of the parameters.
    public static let parametersSchema: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "action": AnyCodable(["type": AnyCodable("string"), "enum": AnyCodable(Self.actions.map { AnyCodable($0) })]),
            "job": AnyCodable([
                "type": AnyCodable("object"),
                "additionalProperties": AnyCodable(true),
                "description": AnyCodable(
                    "Job fields. action=\"add\": full job {name, schedule {kind at|every|cron}, payload {kind systemEvent|agentTurn}, "
                        + "sessionTarget, wakeMode}. action=\"update\": partial patch; null clears."
                ),
            ]),
            "jobId": AnyCodable(["type": AnyCodable("string")]),
            "id": AnyCodable(["type": AnyCodable("string")]),
            "includeDisabled": AnyCodable(["type": AnyCodable("boolean")]),
            "limit": AnyCodable(["type": AnyCodable("integer"), "minimum": AnyCodable(1)]),
            "offset": AnyCodable(["type": AnyCodable("integer"), "minimum": AnyCodable(0)]),
            "in": AnyCodable(["type": AnyCodable("string"), "description": AnyCodable("Relative duration for action=\"next_check\" (for example 15m)")]),
            "text": AnyCodable(["type": AnyCodable("string"), "description": AnyCodable("systemEvent text for action=\"wake\"")]),
            "mode": AnyCodable(["type": AnyCodable("string"), "enum": AnyCodable(["next-heartbeat", "now"])]),
            "runMode": AnyCodable(["type": AnyCodable("string"), "enum": AnyCodable(["due", "force"])]),
        ]),
        "required": AnyCodable(["action"]),
        "additionalProperties": AnyCodable(true),
    ]

    /// Model- and UI-facing description.
    public var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "Automations",
            description: "Schedule and manage automations (cron jobs): one-shot reminders (at), intervals (every) and cron expressions with "
                + "time zones that post a system event or run an agent turn. Use action=\"list\" before editing, and \"runs\" to inspect history.",
            parameters: Self.parametersSchema,
            sectionID: "automation",
            defaultProfiles: [.coding, .messaging],
            risk: .medium
        )
    }

    /// Runs one action.
    public func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        let arguments = invocation.arguments
        guard let action = arguments["action"]?.stringValue, Self.actions.contains(action) else {
            throw OpenClawCoreError.invalidConfiguration("automations: action must be one of \(Self.actions.joined(separator: ", "))")
        }
        let jobID = arguments["jobId"]?.stringValue ?? arguments["id"]?.stringValue
        switch action {
        case "status":
            return .json(try AnyCodable(encoding: await self.scheduler.status()))
        case "list":
            let includeDisabled = arguments["includeDisabled"]?.boolValue ?? false
            let all = await self.scheduler.automationJobList(includeDisabled: includeDisabled)
            let offset = max(0, arguments["offset"]?.intValue ?? 0)
            let limit = max(1, arguments["limit"]?.intValue ?? 50)
            let page = Array(all.dropFirst(offset).prefix(limit))
            var result: [String: AnyCodable] = ["jobs": try AnyCodable(encoding: page), "total": AnyCodable(all.count)]
            if offset + page.count < all.count { result["nextOffset"] = AnyCodable(offset + page.count) }
            return .json(AnyCodable(result))
        case "get":
            guard let jobID, let job = await self.scheduler.automationJob(id: jobID) else {
                throw OpenClawCoreError.invalidConfiguration("automations: unknown job \(jobID ?? "(missing jobId)")")
            }
            return .json(try AnyCodable(encoding: job))
        case "add":
            guard let raw = arguments["job"]?.dictionaryValue else {
                throw OpenClawCoreError.invalidConfiguration("automations: action=\"add\" requires a job object")
            }
            let job = try AutomationJobDraft.job(from: raw, sessionKey: invocation.sessionKey, agentID: invocation.agentID ?? self.defaultAgentID)
            return .json(try AnyCodable(encoding: try await self.scheduler.addJob(job)))
        case "update":
            guard let jobID, let existing = await self.scheduler.automationJob(id: jobID) else {
                throw OpenClawCoreError.invalidConfiguration("automations: unknown job \(jobID ?? "(missing jobId)")")
            }
            let patch = arguments["job"]?.dictionaryValue ?? [:]
            let patched = try AutomationJobDraft.apply(patch: patch, to: existing)
            let updated = try await self.scheduler.updateJob(id: jobID) { $0 = patched }
            return .json(try AnyCodable(encoding: updated))
        case "remove":
            guard let jobID else { throw OpenClawCoreError.invalidConfiguration("automations: action=\"remove\" requires jobId") }
            return .json(AnyCodable(["removed": AnyCodable(try await self.scheduler.removeJob(id: jobID)), "jobId": AnyCodable(jobID)]))
        case "run":
            guard let jobID else { throw OpenClawCoreError.invalidConfiguration("automations: action=\"run\" requires jobId") }
            let force = arguments["runMode"]?.stringValue == "force"
            guard let record = try await self.scheduler.runJob(id: jobID, force: force) else {
                return .json(AnyCodable(["ran": AnyCodable(false), "reason": AnyCodable("not due")]))
            }
            return .json(try AnyCodable(encoding: record))
        case "runs":
            let limit = max(1, arguments["limit"]?.intValue ?? 20)
            let offset = max(0, arguments["offset"]?.intValue ?? 0)
            return .json(AnyCodable(["runs": try AnyCodable(encoding: await self.scheduler.runs(jobID: jobID, limit: limit, offset: offset))]))
        case "next_check":
            guard let raw = arguments["in"]?.stringValue, let delayMs = AutomationJobDraft.parseDurationMs(raw) else {
                throw OpenClawCoreError.invalidConfiguration("automations: action=\"next_check\" requires a duration such as 15m")
            }
            let at = Date().addingTimeInterval(Double(delayMs) / 1_000)
            let formatter = ISO8601DateFormatter()
            let job = AutomationJob(
                name: "next check",
                deleteAfterRun: true,
                agentId: invocation.agentID ?? self.defaultAgentID,
                sessionKey: invocation.sessionKey,
                schedule: .at(formatter.string(from: at)),
                payload: .systemEvent(text: arguments["text"]?.stringValue ?? "Scheduled check-in: review pending work.", toolsAllow: nil),
                sessionTarget: invocation.sessionKey == nil ? .main : .current
            )
            return .json(try AnyCodable(encoding: try await self.scheduler.addJob(job)))
        default:
            if let text = arguments["text"]?.stringValue, !text.isEmpty {
                let sessionKey = invocation.sessionKey ?? "agent:\(invocation.agentID ?? self.defaultAgentID):main"
                guard let systemEventSink else {
                    throw OpenClawCoreError.unavailable("automations: wake text needs a system event sink")
                }
                try await systemEventSink(sessionKey, text)
            }
            let records = await self.scheduler.runDueJobs()
            return .json(AnyCodable(["ok": AnyCodable(true), "ranDueJobs": AnyCodable(records.count)]))
        }
    }
}

/// Builds and patches ``AutomationJob`` values from tool/RPC JSON.
public enum AutomationJobDraft {
    /// Builds a new job from upstream `CronAddParams`-shaped JSON (id and timestamps are assigned).
    /// - Parameters:
    ///   - raw: Job fields.
    ///   - sessionKey: Calling session (used by `current`).
    ///   - agentID: Default agent.
    /// - Returns: The job.
    public static func job(from raw: [String: AnyCodable], sessionKey: String?, agentID: String?) throws -> AutomationJob {
        var object = raw
        let nowMs = AutomationClock.nowMs()
        object["id"] = object["id"] ?? AnyCodable(UUID().uuidString.lowercased())
        object["createdAtMs"] = AnyCodable(nowMs)
        object["updatedAtMs"] = AnyCodable(nowMs)
        object["enabled"] = object["enabled"] ?? AnyCodable(true)
        object["sessionTarget"] = object["sessionTarget"] ?? AnyCodable("main")
        object["wakeMode"] = object["wakeMode"] ?? AnyCodable("now")
        if object["agentId"] == nil || object["agentId"]?.isNull == true, let agentID { object["agentId"] = AnyCodable(agentID) }
        if object["sessionKey"] == nil, let sessionKey { object["sessionKey"] = AnyCodable(sessionKey) }
        object.removeValue(forKey: "state")
        return try self.decode(object)
    }

    /// Applies a partial patch (`null` clears optional fields; `state` is scheduler-owned and ignored).
    /// - Parameters:
    ///   - patch: Patch fields.
    ///   - job: Existing job.
    /// - Returns: The patched job.
    public static func apply(patch: [String: AnyCodable], to job: AutomationJob) throws -> AutomationJob {
        var object = (try AnyCodable(encoding: job)).dictionaryValue ?? [:]
        for (key, value) in patch where !["id", "createdAtMs", "state"].contains(key) {
            if value.isNull {
                object.removeValue(forKey: key)
            } else if key == "payload", let patchPayload = value.dictionaryValue, var current = object["payload"]?.dictionaryValue,
                      patchPayload["kind"]?.stringValue == nil || patchPayload["kind"]?.stringValue == current["kind"]?.stringValue
            {
                for (field, fieldValue) in patchPayload {
                    current[field] = fieldValue.isNull ? nil : fieldValue
                }
                object["payload"] = AnyCodable(current)
            } else {
                object[key] = value
            }
        }
        return try self.decode(object)
    }

    /// Parses `30s`, `15m`, `2h`, `1d` (or plain seconds) into milliseconds.
    /// - Parameter raw: Duration text.
    /// - Returns: Milliseconds, or `nil` when invalid.
    public static func parseDurationMs(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let unit = trimmed.last else { return nil }
        let multipliers: [Character: Double] = ["s": 1_000, "m": 60_000, "h": 3_600_000, "d": 86_400_000]
        if let multiplier = multipliers[unit], let value = Double(trimmed.dropLast()), value > 0 {
            return AutomationClock.durationMs(value * multiplier)
        }
        if let seconds = Double(trimmed), seconds > 0 { return AutomationClock.durationMs(seconds * 1_000) }
        return nil
    }

    private static func decode(_ object: [String: AnyCodable]) throws -> AutomationJob {
        if let schedule = object["schedule"]?.dictionaryValue, let kind = schedule["kind"]?.stringValue, !["at", "every", "cron"].contains(kind) {
            throw OpenClawCoreError.invalidConfiguration(
                "schedule kind \"\(kind)\" is not supported by the embedded scheduler; use at (ISO time), every (everyMs) or cron (expr, tz)"
            )
        }
        if let payload = object["payload"]?.dictionaryValue, let kind = payload["kind"]?.stringValue, !["systemEvent", "agentTurn"].contains(kind) {
            throw OpenClawCoreError.invalidConfiguration(
                "payload kind \"\(kind)\" is not supported by the embedded scheduler; use systemEvent (text) or agentTurn (message)"
            )
        }
        do {
            let data = try JSONEncoder().encode(AnyCodable(object))
            return try JSONDecoder().decode(AutomationJob.self, from: data)
        } catch let error as DecodingError {
            throw OpenClawCoreError.invalidConfiguration("invalid cron job: \(error)")
        }
    }
}
