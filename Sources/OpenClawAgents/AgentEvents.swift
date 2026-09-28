import Foundation
import OpenClawCore
import OpenClawProtocol

/// Agent event stream name (upstream `AgentEventStream`); open vocabulary.
public struct AgentEventStream: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    /// Stream name.
    public let rawValue: String

    /// Creates a stream name.
    /// - Parameter rawValue: Stream name.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a stream name from a literal.
    /// - Parameter value: Stream name.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// Decodes a stream name.
    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the stream name.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    /// Run lifecycle: `{phase: start|finishing|end|error, startedAt?, endedAt?, error?, timedOut?, aborted?}`.
    public static let lifecycle: AgentEventStream = "lifecycle"
    /// Assistant text: `{itemId, text, delta, replace?}`.
    public static let assistant: AgentEventStream = "assistant"
    /// Reasoning text: `{itemId, text, delta}`.
    public static let thinking: AgentEventStream = "thinking"
    /// Tool calls: `{phase: start|update|result, name, toolCallId, parentToolCallId?, args, meta?, isError, result}`.
    public static let tool: AgentEventStream = "tool"
    /// Token usage: `{input, output, cacheRead, cacheWrite, totalTokens}`.
    public static let usage: AgentEventStream = "usage"
    /// Compaction: `{phase: start|end, trigger, tokensBefore, tokensAfter?, compacted?}`.
    public static let compaction: AgentEventStream = "compaction"
    /// Approvals: `{phase: requested|resolved, kind, status, title, approvalId?, toolCallId?}`.
    public static let approval: AgentEventStream = "approval"
    /// Errors that do not end the run.
    public static let error: AgentEventStream = "error"
}

/// One agent event (upstream `AgentEventSchema`: `{runId, seq, stream, ts, spawnedBy?, isHeartbeat?, data}`).
///
/// `seq` is monotonic per run starting at 0; `ts` is epoch milliseconds (`Int64`).
public struct AgentEventFrame: Codable, Sendable, Equatable {
    /// Run identifier.
    public var runID: String
    /// Per-run sequence number (from 0).
    public var seq: Int
    /// Stream name.
    public var stream: AgentEventStream
    /// Event time (ms).
    public var ts: Int64
    /// Parent session key for spawned (sub-agent) runs.
    public var spawnedBy: String?
    /// Whether the run is a heartbeat run.
    public var isHeartbeat: Bool?
    /// Session key of the run (SDK field; not part of the upstream wire event).
    public var sessionKey: String?
    /// Stream-specific data.
    public var data: [String: AnyCodable]

    /// Creates an event frame.
    public init(
        runID: String,
        seq: Int,
        stream: AgentEventStream,
        ts: Int64,
        spawnedBy: String? = nil,
        isHeartbeat: Bool? = nil,
        sessionKey: String? = nil,
        data: [String: AnyCodable]
    ) {
        self.runID = runID
        self.seq = seq
        self.stream = stream
        self.ts = ts
        self.spawnedBy = spawnedBy
        self.isHeartbeat = isHeartbeat
        self.sessionKey = sessionKey
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case seq
        case stream
        case ts
        case spawnedBy
        case isHeartbeat
        case sessionKey
        case data
    }

    /// Upstream `agent` gateway event payload (`sessionKey` included as an SDK extension field).
    public var gatewayPayload: AnyCodable {
        var payload: [String: AnyCodable] = [
            "runId": AnyCodable(self.runID),
            "seq": AnyCodable(self.seq),
            "stream": AnyCodable(self.stream.rawValue),
            "ts": AnyCodable(self.ts),
            "data": AnyCodable(self.data),
        ]
        if let spawnedBy { payload["spawnedBy"] = AnyCodable(spawnedBy) }
        if let isHeartbeat { payload["isHeartbeat"] = AnyCodable(isHeartbeat) }
        if let sessionKey { payload["sessionKey"] = AnyCodable(sessionKey) }
        return AnyCodable(payload)
    }

    /// Generated protocol event (`AgentEvent`); `ts` saturates to `Int` on 32-bit platforms.
    public var protocolEvent: AgentEvent {
        AgentEvent(
            runid: self.runID,
            seq: self.seq,
            stream: self.stream.rawValue,
            ts: Int(clamping: self.ts),
            spawnedby: self.spawnedBy,
            isheartbeat: self.isHeartbeat,
            data: self.data
        )
    }

    /// Lifecycle phase of a `lifecycle` event.
    public var lifecyclePhase: String? {
        self.stream == .lifecycle ? self.data["phase"]?.stringValue : nil
    }
}

/// Final status reported by ``EmbeddedAgentRuntime/wait(runID:timeoutMs:)`` (upstream `agent.wait`).
public struct AgentRunWaitResult: Sendable, Equatable {
    /// `ok`, `error` or `timeout`.
    public var status: String
    /// Run identifier.
    public var runID: String
    /// Session key.
    public var sessionKey: String?
    /// Start time (ms).
    public var startedAt: Int64?
    /// End time (ms).
    public var endedAt: Int64?
    /// Error message for `error`.
    public var error: String?
    /// Final visible output for `ok`.
    public var output: String?

    /// Creates a wait result.
    public init(
        status: String,
        runID: String,
        sessionKey: String? = nil,
        startedAt: Int64? = nil,
        endedAt: Int64? = nil,
        error: String? = nil,
        output: String? = nil
    ) {
        self.status = status
        self.runID = runID
        self.sessionKey = sessionKey
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.error = error
        self.output = output
    }

    /// Upstream wire payload.
    public var payload: [String: AnyCodable] {
        var payload: [String: AnyCodable] = ["runId": AnyCodable(self.runID), "status": AnyCodable(self.status)]
        if let sessionKey { payload["sessionKey"] = AnyCodable(sessionKey) }
        if let startedAt { payload["startedAt"] = AnyCodable(startedAt) }
        if let endedAt { payload["endedAt"] = AnyCodable(endedAt) }
        if let error { payload["error"] = AnyCodable(error) }
        if let output { payload["output"] = AnyCodable(output) }
        return payload
    }
}

/// Per-run event emitter handing out monotonic sequence numbers.
final class AgentEventSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    let runID: String
    let sessionKey: String
    let spawnedBy: String?
    private let sink: @Sendable (AgentEventFrame) -> Void

    init(runID: String, sessionKey: String, spawnedBy: String?, sink: @escaping @Sendable (AgentEventFrame) -> Void) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.spawnedBy = spawnedBy
        self.sink = sink
    }

    /// Emits one frame. The sink runs under the lock so concurrent emitters (parallel tool batches)
    /// deliver frames in `seq` order; sinks must not block or re-enter the sequencer.
    @discardableResult
    func emit(_ stream: AgentEventStream, _ data: [String: AnyCodable]) -> AgentEventFrame {
        self.lock.lock()
        defer { self.lock.unlock() }
        let frame = AgentEventFrame(
            runID: self.runID,
            seq: self.next,
            stream: stream,
            ts: SessionTranscriptClock.nowMs(),
            spawnedBy: self.spawnedBy,
            sessionKey: self.sessionKey,
            data: data
        )
        self.next += 1
        self.sink(frame)
        return frame
    }
}
