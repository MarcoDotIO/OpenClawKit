import Foundation
import OpenClawProtocol

// Cron/automation job model mirroring upstream `packages/gateway-protocol/src/schema/cron.ts`
// (OpenClaw 2026.9.6). Timestamps are Int64 milliseconds so 32-bit watchOS never overflows.
// Unsupported upstream schedule and payload kinds round-trip untouched.

/// When a job runs.
public enum CronSchedule: Codable, Sendable, Equatable {
    /// Once at an ISO-8601 instant (`{"kind":"at","at":…}`).
    case at(String)
    /// Every `everyMs`, aligned to `anchorMs` (defaults to the job's creation time).
    case every(everyMs: Int64, anchorMs: Int64?)
    /// Five-field cron expression evaluated in `tz` (default: the device time zone), plus a
    /// deterministic per-job `staggerMs` offset.
    case cron(expr: String, tz: String?, staggerMs: Int64?)
    /// An upstream kind the SDK does not run (`on-exit`, `stream`), kept verbatim.
    case unsupported(kind: String, raw: [String: AnyCodable])

    /// Wire kind.
    public var kind: String {
        switch self {
        case .at: return "at"
        case .every: return "every"
        case .cron: return "cron"
        case .unsupported(let kind, _): return kind
        }
    }

    /// Decodes a schedule.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: AnyCodable].self)
        let kind = raw["kind"]?.stringValue ?? ""
        switch kind {
        case "at":
            guard let at = raw["at"]?.stringValue else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "at schedule requires at"))
            }
            self = .at(at)
        case "every":
            guard let every = raw["everyMs"]?.int64Value, every > 0 else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "every schedule requires everyMs >= 1"))
            }
            self = .every(everyMs: every, anchorMs: raw["anchorMs"]?.int64Value)
        case "cron":
            guard let expr = raw["expr"]?.stringValue else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "cron schedule requires expr"))
            }
            self = .cron(expr: expr, tz: raw["tz"]?.stringValue, staggerMs: raw["staggerMs"]?.int64Value)
        default:
            self = .unsupported(kind: kind, raw: raw)
        }
    }

    /// Encodes the upstream shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .at(let at):
            try container.encode(["kind": AnyCodable("at"), "at": AnyCodable(at)])
        case .every(let everyMs, let anchorMs):
            var object: [String: AnyCodable] = ["kind": AnyCodable("every"), "everyMs": AnyCodable(everyMs)]
            if let anchorMs { object["anchorMs"] = AnyCodable(anchorMs) }
            try container.encode(object)
        case .cron(let expr, let tz, let staggerMs):
            var object: [String: AnyCodable] = ["kind": AnyCodable("cron"), "expr": AnyCodable(expr)]
            if let tz { object["tz"] = AnyCodable(tz) }
            if let staggerMs { object["staggerMs"] = AnyCodable(staggerMs) }
            try container.encode(object)
        case .unsupported(_, let raw):
            try container.encode(raw)
        }
    }
}

/// Agent-turn payload fields.
public struct CronAgentTurnPayload: Codable, Sendable, Equatable {
    /// Message sent to the agent.
    public var message: String
    /// Model override.
    public var model: String?
    /// Fallback models.
    public var fallbacks: [String]?
    /// Thinking level.
    public var thinking: String?
    /// Run timeout in seconds.
    public var timeoutSeconds: Double?
    /// Use a light context.
    public var lightContext: Bool?
    /// Tool allowlist for the run.
    public var toolsAllow: [String]?

    /// Creates an agent-turn payload.
    /// - Parameters:
    ///   - message: Message.
    ///   - model: Model.
    ///   - fallbacks: Fallbacks.
    ///   - thinking: Thinking level.
    ///   - timeoutSeconds: Timeout.
    ///   - lightContext: Light context.
    ///   - toolsAllow: Tool allowlist.
    public init(
        message: String,
        model: String? = nil,
        fallbacks: [String]? = nil,
        thinking: String? = nil,
        timeoutSeconds: Double? = nil,
        lightContext: Bool? = nil,
        toolsAllow: [String]? = nil
    ) {
        self.message = message
        self.model = model
        self.fallbacks = fallbacks
        self.thinking = thinking
        self.timeoutSeconds = timeoutSeconds
        self.lightContext = lightContext
        self.toolsAllow = toolsAllow
    }
}

/// What a job does when it fires.
public enum CronPayload: Codable, Sendable, Equatable {
    /// Enqueue a system message into the target session.
    case systemEvent(text: String, toolsAllow: [String]?)
    /// Run an agent turn.
    case agentTurn(CronAgentTurnPayload)
    /// An upstream kind the SDK does not run (`command`, `script`, `heartbeat`), kept verbatim.
    case unsupported(kind: String, raw: [String: AnyCodable])

    /// Wire kind.
    public var kind: String {
        switch self {
        case .systemEvent: return "systemEvent"
        case .agentTurn: return "agentTurn"
        case .unsupported(let kind, _): return kind
        }
    }

    /// Tool allowlist, when declared.
    public var toolsAllow: [String]? {
        switch self {
        case .systemEvent(_, let toolsAllow): return toolsAllow
        case .agentTurn(let payload): return payload.toolsAllow
        case .unsupported: return nil
        }
    }

    /// Decodes a payload.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: AnyCodable].self)
        switch raw["kind"]?.stringValue {
        case "systemEvent":
            guard let text = raw["text"]?.stringValue, !text.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "systemEvent requires text"))
            }
            self = .systemEvent(text: text, toolsAllow: raw["toolsAllow"]?.arrayValue?.compactMap(\.stringValue))
        case "agentTurn":
            guard let message = raw["message"]?.stringValue, !message.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "agentTurn requires message"))
            }
            self = .agentTurn(
                CronAgentTurnPayload(
                    message: message,
                    model: raw["model"]?.stringValue,
                    fallbacks: raw["fallbacks"]?.arrayValue?.compactMap(\.stringValue),
                    thinking: raw["thinking"]?.stringValue,
                    timeoutSeconds: raw["timeoutSeconds"]?.doubleValue,
                    lightContext: raw["lightContext"]?.boolValue,
                    toolsAllow: raw["toolsAllow"]?.arrayValue?.compactMap(\.stringValue)
                )
            )
        default:
            self = .unsupported(kind: raw["kind"]?.stringValue ?? "", raw: raw)
        }
    }

    /// Encodes the upstream shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .systemEvent(let text, let toolsAllow):
            var object: [String: AnyCodable] = ["kind": AnyCodable("systemEvent"), "text": AnyCodable(text)]
            if let toolsAllow { object["toolsAllow"] = AnyCodable(toolsAllow.map { AnyCodable($0) }) }
            try container.encode(object)
        case .agentTurn(let payload):
            var object = (try? AnyCodable(encoding: payload))?.dictionaryValue ?? [:]
            object["kind"] = AnyCodable("agentTurn")
            try container.encode(object)
        case .unsupported(_, let raw):
            try container.encode(raw)
        }
    }
}

/// Session a job runs in.
public enum CronSessionTarget: Codable, Sendable, Equatable, Hashable {
    /// The agent's main session.
    case main
    /// A fresh session per run (`agent:<id>:cron:<jobId>:<runId>`).
    case isolated
    /// The session that created the job (`sessionKey`), else main.
    case current
    /// An explicit session key (`session:<key>`).
    case session(String)

    /// Wire value.
    public var rawValue: String {
        switch self {
        case .main: return "main"
        case .isolated: return "isolated"
        case .current: return "current"
        case .session(let key): return "session:\(key)"
        }
    }

    /// Parses a wire value.
    /// - Parameter rawValue: Wire value.
    public init?(rawValue: String) {
        switch rawValue {
        case "main": self = .main
        case "isolated": self = .isolated
        case "current": self = .current
        default:
            guard rawValue.hasPrefix("session:"), rawValue.count > "session:".count else { return nil }
            self = .session(String(rawValue.dropFirst("session:".count)))
        }
    }

    /// Decodes a session target.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = CronSessionTarget(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid sessionTarget \(raw)"))
        }
        self = value
    }

    /// Encodes the wire value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

/// Whether a job waits for the next heartbeat or wakes the agent immediately.
public enum CronWakeMode: String, Codable, Sendable, Equatable {
    /// Wait for the next heartbeat.
    case nextHeartbeat = "next-heartbeat"
    /// Wake now.
    case now
}

/// Outcome of one run.
public enum CronRunStatus: String, Codable, Sendable, Equatable {
    /// Succeeded.
    case ok
    /// Failed.
    case error
    /// Skipped (disabled, unsupported kind, or already running).
    case skipped
}

/// Scheduler-owned state of a job.
public struct CronJobState: Codable, Sendable, Equatable {
    /// Next due time.
    public var nextRunAtMs: Int64?
    /// Start time of the in-flight run.
    public var runningAtMs: Int64?
    /// Last run start.
    public var lastRunAtMs: Int64?
    /// Last run status.
    public var lastRunStatus: CronRunStatus?
    /// Last error.
    public var lastError: String?
    /// Last run duration.
    public var lastDurationMs: Int64?
    /// Consecutive failures.
    public var consecutiveErrors: Int?

    /// Creates state.
    /// - Parameters:
    ///   - nextRunAtMs: Next run.
    ///   - runningAtMs: Running since.
    ///   - lastRunAtMs: Last run.
    ///   - lastRunStatus: Last status.
    ///   - lastError: Last error.
    ///   - lastDurationMs: Last duration.
    ///   - consecutiveErrors: Consecutive errors.
    public init(
        nextRunAtMs: Int64? = nil,
        runningAtMs: Int64? = nil,
        lastRunAtMs: Int64? = nil,
        lastRunStatus: CronRunStatus? = nil,
        lastError: String? = nil,
        lastDurationMs: Int64? = nil,
        consecutiveErrors: Int? = nil
    ) {
        self.nextRunAtMs = nextRunAtMs
        self.runningAtMs = runningAtMs
        self.lastRunAtMs = lastRunAtMs
        self.lastRunStatus = lastRunStatus
        self.lastError = lastError
        self.lastDurationMs = lastDurationMs
        self.consecutiveErrors = consecutiveErrors
    }
}

/// A scheduled automation job (upstream `CronJob` shape).
public struct AutomationJob: Codable, Sendable, Equatable, Identifiable {
    /// Stable identifier.
    public var id: String
    /// Name.
    public var name: String
    /// Description.
    public var description: String?
    /// Whether the job runs when due.
    public var enabled: Bool
    /// Delete after a successful run (defaults to `true` for `at` jobs).
    public var deleteAfterRun: Bool?
    /// Owning agent.
    public var agentId: String?
    /// Session that created the job (used by `current`).
    public var sessionKey: String?
    /// Creation time.
    public var createdAtMs: Int64
    /// Last update time.
    public var updatedAtMs: Int64
    /// Schedule.
    public var schedule: CronSchedule
    /// Payload.
    public var payload: CronPayload
    /// Target session.
    public var sessionTarget: CronSessionTarget
    /// Wake mode.
    public var wakeMode: CronWakeMode
    /// Scheduler state.
    public var state: CronJobState
    /// Upstream fields the SDK does not interpret (`delivery`, `failureAlert`, `owner`, …).
    public var extra: [String: AnyCodable]

    /// Creates a job.
    /// - Parameters:
    ///   - id: Identifier.
    ///   - name: Name.
    ///   - description: Description.
    ///   - enabled: Enabled flag.
    ///   - deleteAfterRun: Delete after run.
    ///   - agentId: Agent.
    ///   - sessionKey: Creating session.
    ///   - createdAtMs: Creation time.
    ///   - updatedAtMs: Update time.
    ///   - schedule: Schedule.
    ///   - payload: Payload.
    ///   - sessionTarget: Target session.
    ///   - wakeMode: Wake mode.
    ///   - state: State.
    ///   - extra: Unknown fields.
    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        description: String? = nil,
        enabled: Bool = true,
        deleteAfterRun: Bool? = nil,
        agentId: String? = nil,
        sessionKey: String? = nil,
        createdAtMs: Int64 = AutomationClock.nowMs(),
        updatedAtMs: Int64? = nil,
        schedule: CronSchedule,
        payload: CronPayload,
        sessionTarget: CronSessionTarget = .main,
        wakeMode: CronWakeMode = .now,
        state: CronJobState = CronJobState(),
        extra: [String: AnyCodable] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.enabled = enabled
        self.deleteAfterRun = deleteAfterRun
        self.agentId = agentId
        self.sessionKey = sessionKey
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs ?? createdAtMs
        self.schedule = schedule
        self.payload = payload
        self.sessionTarget = sessionTarget
        self.wakeMode = wakeMode
        self.state = state
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "id", "name", "description", "enabled", "deleteAfterRun", "agentId", "sessionKey", "createdAtMs", "updatedAtMs",
        "schedule", "payload", "sessionTarget", "wakeMode", "state",
        "nextRunAtMs", "lastRunAtMs", "lastRunStatus", "lastRunError",
    ]

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { self.stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    /// Decodes a job (upstream `CronJob` JSON).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        self.id = try container.decode(String.self, forKey: AnyKey("id"))
        self.name = try container.decode(String.self, forKey: AnyKey("name"))
        self.description = try container.decodeIfPresent(String.self, forKey: AnyKey("description"))
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: AnyKey("enabled")) ?? true
        self.deleteAfterRun = try container.decodeIfPresent(Bool.self, forKey: AnyKey("deleteAfterRun"))
        self.agentId = try container.decodeIfPresent(String.self, forKey: AnyKey("agentId"))
        self.sessionKey = try container.decodeIfPresent(String.self, forKey: AnyKey("sessionKey"))
        self.createdAtMs = try container.decodeIfPresent(Int64.self, forKey: AnyKey("createdAtMs")) ?? AutomationClock.nowMs()
        self.updatedAtMs = try container.decodeIfPresent(Int64.self, forKey: AnyKey("updatedAtMs")) ?? self.createdAtMs
        self.schedule = try container.decode(CronSchedule.self, forKey: AnyKey("schedule"))
        self.payload = try container.decode(CronPayload.self, forKey: AnyKey("payload"))
        self.sessionTarget = try container.decodeIfPresent(CronSessionTarget.self, forKey: AnyKey("sessionTarget")) ?? .main
        self.wakeMode = try container.decodeIfPresent(CronWakeMode.self, forKey: AnyKey("wakeMode")) ?? .now
        self.state = try container.decodeIfPresent(CronJobState.self, forKey: AnyKey("state")) ?? CronJobState()
        var extra: [String: AnyCodable] = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extra[key.stringValue] = try container.decode(AnyCodable.self, forKey: key)
        }
        self.extra = extra
    }

    /// Encodes the upstream `CronJob` JSON (with top-level `nextRunAtMs`/`lastRun*` mirrors).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in self.extra where !Self.knownKeys.contains(key) {
            try container.encode(value, forKey: AnyKey(key))
        }
        try container.encode(self.id, forKey: AnyKey("id"))
        try container.encode(self.name, forKey: AnyKey("name"))
        try container.encodeIfPresent(self.description, forKey: AnyKey("description"))
        try container.encode(self.enabled, forKey: AnyKey("enabled"))
        try container.encodeIfPresent(self.deleteAfterRun, forKey: AnyKey("deleteAfterRun"))
        try container.encodeIfPresent(self.agentId, forKey: AnyKey("agentId"))
        try container.encodeIfPresent(self.sessionKey, forKey: AnyKey("sessionKey"))
        try container.encode(self.createdAtMs, forKey: AnyKey("createdAtMs"))
        try container.encode(self.updatedAtMs, forKey: AnyKey("updatedAtMs"))
        try container.encode(self.schedule, forKey: AnyKey("schedule"))
        try container.encode(self.payload, forKey: AnyKey("payload"))
        try container.encode(self.sessionTarget, forKey: AnyKey("sessionTarget"))
        try container.encode(self.wakeMode, forKey: AnyKey("wakeMode"))
        try container.encode(self.state, forKey: AnyKey("state"))
        try container.encodeIfPresent(self.state.nextRunAtMs, forKey: AnyKey("nextRunAtMs"))
        try container.encodeIfPresent(self.state.lastRunAtMs, forKey: AnyKey("lastRunAtMs"))
        try container.encodeIfPresent(self.state.lastRunStatus, forKey: AnyKey("lastRunStatus"))
        try container.encodeIfPresent(self.state.lastError, forKey: AnyKey("lastRunError"))
    }

    /// Whether the scheduler can run the job (schedule and payload kinds are supported).
    public var isRunnable: Bool {
        if case .unsupported = self.schedule { return false }
        if case .unsupported = self.payload { return false }
        return true
    }

    /// Next fire time strictly after `now` (`nil` for spent `at` jobs and unsupported schedules).
    /// - Parameters:
    ///   - now: Reference time in milliseconds.
    ///   - defaultTimeZone: Time zone for cron schedules without `tz`.
    /// - Returns: Next fire time in milliseconds.
    public func nextRunAtMs(after now: Int64, defaultTimeZone: TimeZone = .current) -> Int64? {
        switch self.schedule {
        case .at(let raw):
            guard let at = AutomationClock.parseAbsoluteTimeMs(raw) else { return nil }
            if self.state.lastRunAtMs != nil { return nil }
            return at
        case .every(let everyMs, let anchorMs):
            let anchor = anchorMs ?? self.createdAtMs
            if now < anchor { return anchor }
            let elapsed = now - anchor
            let periods = elapsed / everyMs + 1
            return anchor + periods * everyMs
        case .cron(let expr, let tz, let staggerMs):
            guard let expression = try? CronExpression(expr) else { return nil }
            let zone = tz.flatMap { TimeZone(identifier: $0) } ?? defaultTimeZone
            let stagger = Self.staggerOffset(jobID: self.id, staggerMs: staggerMs)
            let reference = Date(timeIntervalSince1970: Double(now - stagger) / 1_000)
            guard let next = expression.nextDate(after: reference, in: zone) else { return nil }
            return Int64((next.timeIntervalSince1970 * 1_000).rounded()) + stagger
        case .unsupported:
            return nil
        }
    }

    /// Deterministic stagger offset in `0..<staggerMs` derived from the job id (FNV-1a).
    /// - Parameters:
    ///   - jobID: Job identifier.
    ///   - staggerMs: Stagger window.
    /// - Returns: Offset in milliseconds.
    public static func staggerOffset(jobID: String, staggerMs: Int64?) -> Int64 {
        guard let staggerMs, staggerMs > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in jobID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int64(hash % UInt64(staggerMs))
    }
}

/// Millisecond clock and time parsing helpers for automations.
public enum AutomationClock {
    /// Current time in milliseconds since the epoch.
    public static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    /// Milliseconds for a date.
    /// - Parameter date: Date.
    /// - Returns: Milliseconds since the epoch.
    public static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    /// Parses an absolute time: ISO-8601 with offset (fractional seconds allowed), an offsetless
    /// ISO date-time (UTC), a date (`YYYY-MM-DD`, UTC midnight), or epoch milliseconds.
    /// - Parameter raw: Text.
    /// - Returns: Milliseconds since the epoch.
    public static func parseAbsoluteTimeMs(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isNumber), let ms = Int64(trimmed) { return ms }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return self.ms(date) }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return self.ms(date) }
        for suffix in ["Z", ":00Z", ".000Z"] {
            if let date = plain.date(from: trimmed + suffix) ?? withFraction.date(from: trimmed + suffix) { return self.ms(date) }
        }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        if let date = dateOnly.date(from: trimmed) { return self.ms(date) }
        return nil
    }
}
