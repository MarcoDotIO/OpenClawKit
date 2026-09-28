import Foundation
import OpenClawCore
import OpenClawProtocol

// Unified approval broker (upstream `packages/gateway-protocol/src/schema/approvals.ts`,
// `src/gateway/server-methods/approval*.ts`, `exec-approval.ts`, `plugin-approval.ts`).
// Wire kinds/decisions/terminal reasons reuse the generated protocol enums (`ApprovalKind`,
// `ApprovalDecision`, `ApprovalTerminalReason`); records use Int64 milliseconds and project to the
// upstream JSON snapshot shape through `snapshotPayload`.

/// Lifecycle state of an ``AgentApproval``.
public enum AgentApprovalState: String, Codable, Sendable, Equatable, CaseIterable {
    /// Waiting for a reviewer decision.
    case pending
    /// Allowed by a reviewer.
    case allowed
    /// Denied (by a reviewer, a malformed verdict, a missing route, or storage failure).
    case denied
    /// Deadline passed without a decision (fails closed).
    case expired
    /// Cancelled by its runtime owner (run aborted, gateway restart, permission change).
    case cancelled

    /// Whether the state is terminal.
    public var isTerminal: Bool {
        self != .pending
    }
}

/// Reviewer attribution for a resolution (channel reviewer or operator device).
public struct AgentApprovalReviewer: Codable, Sendable, Equatable {
    /// Channel the reviewer answered from.
    public var channel: String?
    /// Channel account.
    public var accountID: String?
    /// Channel sender.
    public var senderID: String?
    /// Operator device identifier.
    public var deviceID: String?

    /// Creates reviewer attribution.
    public init(channel: String? = nil, accountID: String? = nil, senderID: String? = nil, deviceID: String? = nil) {
        self.channel = channel
        self.accountID = accountID
        self.senderID = senderID
        self.deviceID = deviceID
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case accountID = "accountId"
        case senderID = "senderId"
        case deviceID = "deviceId"
    }

    /// Upstream resolver attribution `{kind: device|channel|runtime|system, id?}`.
    var resolverPayload: [String: AnyCodable] {
        if let deviceID {
            return ["kind": AnyCodable("device"), "id": AnyCodable(deviceID)]
        }
        if let channel {
            let id = [channel, self.accountID, self.senderID].compactMap { $0 }.joined(separator: ":")
            return ["kind": AnyCodable("channel"), "id": AnyCodable(id)]
        }
        return ["kind": AnyCodable("runtime")]
    }
}

/// Reviewer-safe presentation of an approval (upstream `ApprovalPresentationSchema`).
public struct AgentApprovalPresentation: Codable, Sendable, Equatable {
    /// Approval owner kind.
    public var kind: ApprovalKind
    /// Title (plugin and system-agent approvals; exec approvals show the command).
    public var title: String
    /// Description.
    public var description: String?
    /// Longer detail text (plugin approvals).
    public var detail: String?
    /// Severity: `info`, `warning` or `critical` (plugin approvals).
    public var severity: String?
    /// Command text (exec approvals).
    public var commandText: String?
    /// Short command preview (exec approvals).
    public var commandPreview: String?
    /// Warning shown to the reviewer.
    public var warningText: String?
    /// Exec host.
    public var host: String?
    /// Exec node.
    public var nodeID: String?
    /// Requesting agent.
    public var agentID: String?
    /// Plugin id (plugin approvals).
    public var pluginID: String?
    /// Tool name (plugin/MCP approvals).
    public var toolName: String?
    /// SHA-256 of the proposal (system-agent approvals).
    public var proposalHash: String?
    /// Decisions the reviewer may choose (always contains `deny`).
    public var allowedDecisions: [ApprovalDecision]

    /// Creates an exec presentation.
    /// - Parameters:
    ///   - commandText: Command text.
    ///   - commandPreview: Optional short preview.
    ///   - warningText: Optional warning.
    ///   - host: Optional exec host.
    ///   - agentID: Optional agent id.
    ///   - allowedDecisions: Allowed decisions.
    /// - Returns: The presentation.
    public static func exec(
        commandText: String,
        commandPreview: String? = nil,
        warningText: String? = nil,
        host: String? = nil,
        agentID: String? = nil,
        allowedDecisions: [ApprovalDecision] = [.allowOnce, .allowAlways, .deny]
    ) -> AgentApprovalPresentation {
        AgentApprovalPresentation(
            kind: .exec,
            title: "Run command",
            commandText: commandText,
            commandPreview: commandPreview,
            warningText: warningText,
            host: host,
            agentID: agentID,
            allowedDecisions: allowedDecisions
        )
    }

    /// Creates a plugin (tool) presentation.
    /// - Parameters:
    ///   - title: Title (≤ 80 characters).
    ///   - description: Description (≤ 512 characters).
    ///   - detail: Optional detail.
    ///   - severity: `info`, `warning` or `critical`.
    ///   - pluginID: Optional plugin id.
    ///   - toolName: Optional tool name.
    ///   - agentID: Optional agent id.
    ///   - allowedDecisions: Allowed decisions.
    /// - Returns: The presentation.
    public static func plugin(
        title: String,
        description: String,
        detail: String? = nil,
        severity: String = "warning",
        pluginID: String? = nil,
        toolName: String? = nil,
        agentID: String? = nil,
        allowedDecisions: [ApprovalDecision] = [.allowOnce, .allowAlways, .deny]
    ) -> AgentApprovalPresentation {
        AgentApprovalPresentation(
            kind: .plugin,
            title: String(title.prefix(80)),
            description: String(description.prefix(512)),
            detail: detail,
            severity: ["info", "warning", "critical"].contains(severity) ? severity : "warning",
            agentID: agentID,
            pluginID: pluginID,
            toolName: toolName,
            allowedDecisions: allowedDecisions
        )
    }

    /// Creates a presentation.
    public init(
        kind: ApprovalKind,
        title: String,
        description: String? = nil,
        detail: String? = nil,
        severity: String? = nil,
        commandText: String? = nil,
        commandPreview: String? = nil,
        warningText: String? = nil,
        host: String? = nil,
        nodeID: String? = nil,
        agentID: String? = nil,
        pluginID: String? = nil,
        toolName: String? = nil,
        proposalHash: String? = nil,
        allowedDecisions: [ApprovalDecision] = [.allowOnce, .deny]
    ) {
        self.kind = kind
        self.title = title
        self.description = description
        self.detail = detail
        self.severity = severity
        self.commandText = commandText
        self.commandPreview = commandPreview
        self.warningText = warningText
        self.host = host
        self.nodeID = nodeID
        self.agentID = agentID
        self.pluginID = pluginID
        self.toolName = toolName
        self.proposalHash = proposalHash
        var decisions: [ApprovalDecision] = []
        for decision in allowedDecisions where !decisions.contains(decision) {
            decisions.append(decision)
        }
        if !decisions.contains(.deny) {
            decisions.append(.deny)
        }
        self.allowedDecisions = decisions
    }

    /// Upstream wire shape for this presentation.
    public var payload: [String: AnyCodable] {
        let decisions = AnyCodable(self.allowedDecisions.map { AnyCodable($0.rawValue) })
        switch self.kind {
        case .exec:
            return [
                "kind": AnyCodable("exec"),
                "commandText": AnyCodable(self.commandText ?? self.title),
                "commandPreview": AnyCodable(self.commandPreview),
                "warningText": AnyCodable(self.warningText),
                "host": AnyCodable(self.host),
                "nodeId": AnyCodable(self.nodeID),
                "agentId": AnyCodable(self.agentID),
                "allowedDecisions": decisions,
            ]
        case .plugin:
            var payload: [String: AnyCodable] = [
                "kind": AnyCodable("plugin"),
                "title": AnyCodable(self.title),
                "description": AnyCodable(self.description ?? self.title),
                "severity": AnyCodable(self.severity ?? "warning"),
                "pluginId": AnyCodable(self.pluginID),
                "toolName": AnyCodable(self.toolName),
                "agentId": AnyCodable(self.agentID),
                "allowedDecisions": decisions,
            ]
            if let detail {
                payload["detail"] = AnyCodable(detail)
            }
            return payload
        case .systemAgent:
            return [
                "kind": AnyCodable("system-agent"),
                "title": AnyCodable(self.title),
                "description": AnyCodable(self.description ?? self.title),
                "proposalHash": AnyCodable(self.proposalHash ?? String(repeating: "0", count: 64)),
                "agentId": AnyCodable(self.agentID),
                "allowedDecisions": AnyCodable([AnyCodable("allow-once"), AnyCodable("deny")]),
            ]
        }
    }
}

/// One approval record held by ``ApprovalBroker``.
public struct AgentApproval: Codable, Sendable, Equatable {
    /// Approval identifier (UUID).
    public var id: String
    /// Deep-link path (SDK-owned `/approvals/<id>`).
    public var urlPath: String
    /// Approval owner kind.
    public var kind: ApprovalKind
    /// Reviewer-safe presentation.
    public var presentation: AgentApprovalPresentation
    /// Creation time (ms).
    public var createdAtMs: Int64
    /// Expiry time (ms).
    public var expiresAtMs: Int64
    /// Lifecycle state.
    public var state: AgentApprovalState
    /// Recorded decision (allowed/denied states).
    public var decision: ApprovalDecision?
    /// Terminal reason.
    public var reason: ApprovalTerminalReason?
    /// Resolution time (ms).
    public var resolvedAtMs: Int64?
    /// Reviewer attribution.
    public var reviewer: AgentApprovalReviewer?
    /// Raising session.
    public var sessionKey: String?
    /// Requesting agent.
    public var agentID: String?
    /// Requesting run.
    public var runID: String?
    /// Tool call awaiting the decision.
    public var toolCallID: String?
    /// Grant key minted by `allow-always` (exec command prefix, `plugin:<id>:<tool>`, `mcp:<server>:<tool>`).
    public var grantKey: String?

    /// Whether the approval allows the operation.
    public var isAllowed: Bool {
        self.state == .allowed
    }

    /// Upstream `ApprovalSnapshot` JSON (pending or terminal).
    public var snapshotPayload: [String: AnyCodable] {
        var payload: [String: AnyCodable] = [
            "id": AnyCodable(self.id),
            "urlPath": AnyCodable(self.urlPath),
            "createdAtMs": AnyCodable(self.createdAtMs),
            "expiresAtMs": AnyCodable(self.expiresAtMs),
            "presentation": AnyCodable(self.presentation.payload),
            "status": AnyCodable(self.state.rawValue),
        ]
        if self.state == .pending {
            if let sessionKey {
                payload["sourceSessionKey"] = AnyCodable(sessionKey)
            }
            return payload
        }
        payload["resolvedAtMs"] = AnyCodable(self.resolvedAtMs ?? self.expiresAtMs)
        var source: [String: AnyCodable] = [:]
        if let agentID {
            source["agentId"] = AnyCodable(agentID)
        }
        if let sessionKey {
            source["sessionKey"] = AnyCodable(sessionKey)
        }
        if !source.isEmpty {
            payload["source"] = AnyCodable(source)
        }
        payload["resolver"] = AnyCodable(self.reviewer?.resolverPayload ?? ["kind": AnyCodable(self.reason == .user ? "runtime" : "system")])
        if let decision {
            payload["decision"] = AnyCodable(decision.rawValue)
        }
        if let reason {
            payload["reason"] = AnyCodable(reason.rawValue)
        }
        return payload
    }

    /// Legacy `exec.approval.list` / `plugin.approval.list` row `{id, request, createdAtMs, expiresAtMs, approvalKind}`.
    public var legacyListPayload: [String: AnyCodable] {
        var request: [String: AnyCodable] = [:]
        switch self.kind {
        case .exec:
            request["command"] = AnyCodable(self.presentation.commandText ?? "")
            request["host"] = AnyCodable(self.presentation.host)
        case .plugin, .systemAgent:
            request["title"] = AnyCodable(self.presentation.title)
            request["description"] = AnyCodable(self.presentation.description)
            request["severity"] = AnyCodable(self.presentation.severity)
            request["pluginId"] = AnyCodable(self.presentation.pluginID)
            request["toolName"] = AnyCodable(self.presentation.toolName)
        }
        request["agentId"] = AnyCodable(self.agentID)
        request["sessionKey"] = AnyCodable(self.sessionKey)
        request["runId"] = AnyCodable(self.runID)
        request["toolCallId"] = AnyCodable(self.toolCallID)
        return [
            "id": AnyCodable(self.id),
            "approvalKind": AnyCodable(self.kind.rawValue),
            "request": AnyCodable(request),
            "createdAtMs": AnyCodable(self.createdAtMs),
            "expiresAtMs": AnyCodable(self.expiresAtMs),
        ]
    }

    /// Legacy `*.approval.waitDecision` result `{id, decision, createdAtMs, expiresAtMs, terminalReason}`.
    public var legacyWaitPayload: [String: AnyCodable] {
        [
            "id": AnyCodable(self.id),
            "decision": AnyCodable(self.state == .allowed || self.state == .denied ? self.decision?.rawValue : nil),
            "createdAtMs": AnyCodable(self.createdAtMs),
            "expiresAtMs": AnyCodable(self.expiresAtMs),
            "terminalReason": AnyCodable(self.reason?.rawValue),
        ]
    }

    /// Agent `approval` stream data `{phase, kind, status, title, approvalId, toolCallId?}`.
    public var agentEventData: [String: AnyCodable] {
        let status: String
        switch self.state {
        case .pending:
            status = "pending"
        case .allowed:
            status = "approved"
        case .denied:
            status = "denied"
        case .expired, .cancelled:
            status = "failed"
        }
        var data: [String: AnyCodable] = [
            "phase": AnyCodable(self.state == .pending ? "requested" : "resolved"),
            "kind": AnyCodable(self.kind == .exec ? "exec" : (self.kind == .plugin ? "plugin" : "unknown")),
            "status": AnyCodable(status),
            "title": AnyCodable(self.presentation.kind == .exec ? (self.presentation.commandText ?? self.presentation.title) : self.presentation.title),
            "approvalId": AnyCodable(self.id),
        ]
        if let toolCallID {
            data["toolCallId"] = AnyCodable(toolCallID)
        }
        if let reason {
            data["reason"] = AnyCodable(reason.rawValue)
        }
        if self.kind == .exec, let command = self.presentation.commandText {
            data["command"] = AnyCodable(command)
        }
        return data
    }
}

/// Standing grant minted by an `allow-always` decision.
public struct AgentApprovalGrant: Codable, Sendable, Equatable {
    /// Grant identifier.
    public var id: String
    /// Approval kind.
    public var kind: ApprovalKind
    /// Grant key (see ``AgentApproval/grantKey``).
    public var key: String
    /// Agent the grant is scoped to (`nil` = any agent).
    public var agentID: String?
    /// Approval that minted the grant.
    public var mintedByApprovalID: String
    /// Creation time (ms).
    public var createdAtMs: Int64
    /// Expiry time (ms); `nil` = until revoked.
    public var expiresAtMs: Int64?
    /// Revocation time (ms).
    public var revokedAtMs: Int64?
    /// Last use (ms).
    public var lastUsedAtMs: Int64?
    /// Number of uses.
    public var useCount: Int

    /// Whether the grant is usable at `nowMs`.
    /// - Parameter nowMs: Current time (ms).
    /// - Returns: `true` when neither revoked nor expired.
    public func isActive(nowMs: Int64) -> Bool {
        self.revokedAtMs == nil && (self.expiresAtMs.map { $0 > nowMs } ?? true)
    }
}

/// Error raised by ``ApprovalBroker``.
public enum ApprovalBrokerError: Error, LocalizedError, Sendable, Equatable {
    /// Unknown approval id.
    case notFound(String)
    /// The approval kind does not match the resolver's kind.
    case kindMismatch(expected: ApprovalKind, actual: ApprovalKind)
    /// The decision is not allowed for this approval.
    case decisionNotAllowed(ApprovalDecision)
    /// `grantExpiresInDays` outside `1...3650`.
    case invalidGrantExpiry(Int)

    /// Human-readable message.
    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "unknown or expired approval id: \(id)"
        case .kindMismatch(let expected, let actual):
            return "approval kind mismatch (expected \(expected.rawValue), found \(actual.rawValue))"
        case .decisionNotAllowed(let decision):
            return "decision \(decision.rawValue) is not allowed for this approval"
        case .invalidGrantExpiry(let days):
            return "grantExpiresInDays must be within 1...3650 (got \(days))"
        }
    }
}

/// Actor that owns pending approvals, the terminal history ring, and standing grants.
///
/// Semantics (upstream approval manager):
/// - The first ``resolve(id:decision:kind:reviewer:grantExpiresInDays:)`` wins; later callers get
///   `applied: false` plus the recorded snapshot.
/// - An unresolved approval denies: expiry records `expired/timeout`, runtime cancellation records
///   `cancelled/run-aborted`; callers treat anything but ``AgentApprovalState/allowed`` as denial.
/// - A denied request is closed: it is never re-presented.
/// - `allow-always` records a standing grant for the approval's ``AgentApproval/grantKey``.
public actor ApprovalBroker {
    /// Default approval timeout (ms).
    public static let defaultTimeoutMs: Int64 = 120_000
    /// Terminal history capacity.
    public static let defaultHistoryLimit = 500

    /// Change notification: the approval after the change.
    public typealias Listener = @Sendable (AgentApproval) async -> Void

    private var approvals: [String: AgentApproval] = [:]
    private var history: [AgentApproval] = []
    private var waiters: [String: [UUID: CheckedContinuation<AgentApproval?, Never>]] = [:]
    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private var grants: [String: AgentApprovalGrant] = [:]
    private var subscribers: [UUID: AsyncStream<AgentApproval>.Continuation] = [:]
    private var listeners: [Listener] = []
    private let historyLimit: Int
    private let grantsFileURL: URL?
    private let clock: @Sendable () -> Int64

    /// Creates a broker.
    /// - Parameters:
    ///   - historyLimit: Terminal history capacity (default 500).
    ///   - grantsFileURL: Optional JSON file persisting standing grants.
    ///   - clock: Millisecond clock (tests inject a fixed clock).
    public init(
        historyLimit: Int = ApprovalBroker.defaultHistoryLimit,
        grantsFileURL: URL? = nil,
        clock: @escaping @Sendable () -> Int64 = { SessionTranscriptClock.nowMs() }
    ) {
        self.historyLimit = max(1, historyLimit)
        self.grantsFileURL = grantsFileURL
        self.clock = clock
        if let grantsFileURL, let data = try? Data(contentsOf: grantsFileURL),
           let decoded = try? JSONDecoder().decode([AgentApprovalGrant].self, from: data)
        {
            self.grants = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        }
    }

    // MARK: - Observation

    /// Stream of approval changes (requested and resolved).
    /// - Parameter limit: Buffered updates per subscriber.
    /// - Returns: The stream; cancel iteration to unsubscribe.
    public func updates(bufferingNewest limit: Int = 128) -> AsyncStream<AgentApproval> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AgentApproval>.makeStream(bufferingPolicy: .bufferingNewest(max(1, limit)))
        self.subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// Adds a listener invoked for every change (used to bridge gateway events).
    /// - Parameter listener: Listener.
    public func addListener(_ listener: @escaping Listener) {
        self.listeners.append(listener)
    }

    private func removeSubscriber(_ id: UUID) {
        self.subscribers[id] = nil
    }

    private func publish(_ approval: AgentApproval) {
        for continuation in self.subscribers.values {
            continuation.yield(approval)
        }
        let listeners = self.listeners
        guard !listeners.isEmpty else { return }
        Task {
            for listener in listeners {
                await listener(approval)
            }
        }
    }

    // MARK: - Requests

    /// Creates a pending approval.
    /// - Parameters:
    ///   - id: Optional explicit id (default UUID).
    ///   - presentation: Reviewer-safe presentation (its kind is the approval kind).
    ///   - sessionKey: Raising session.
    ///   - agentID: Requesting agent.
    ///   - runID: Requesting run.
    ///   - toolCallID: Tool call awaiting the decision.
    ///   - grantKey: Grant key minted by `allow-always`.
    ///   - timeoutMs: Deadline (default 120 s).
    /// - Returns: The pending approval.
    @discardableResult
    public func request(
        id: String? = nil,
        presentation: AgentApprovalPresentation,
        sessionKey: String? = nil,
        agentID: String? = nil,
        runID: String? = nil,
        toolCallID: String? = nil,
        grantKey: String? = nil,
        timeoutMs: Int64? = nil
    ) -> AgentApproval {
        let now = self.clock()
        let approvalID = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? UUID().uuidString.lowercased()
        if let existing = self.approvals[approvalID] {
            return existing
        }
        let timeout = max(1, timeoutMs ?? Self.defaultTimeoutMs)
        let approval = AgentApproval(
            id: approvalID,
            urlPath: "/approvals/\(approvalID)",
            kind: presentation.kind,
            presentation: presentation,
            createdAtMs: now,
            expiresAtMs: now + timeout,
            state: .pending,
            sessionKey: sessionKey,
            agentID: agentID,
            runID: runID,
            toolCallID: toolCallID,
            grantKey: grantKey
        )
        self.approvals[approvalID] = approval
        self.expiryTasks[approvalID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
            await self?.expire(approvalID)
        }
        self.publish(approval)
        return approval
    }

    /// Waits for a decision.
    /// - Parameters:
    ///   - id: Approval id.
    ///   - timeoutMs: Optional wait bound; when it elapses first, the (still pending) approval is returned.
    /// - Returns: The approval (terminal unless the wait bound elapsed).
    /// - Throws: ``ApprovalBrokerError/notFound(_:)`` for unknown ids.
    public func waitDecision(id: String, timeoutMs: Int64? = nil) async throws -> AgentApproval {
        guard let approval = self.approvals[id] ?? self.history.first(where: { $0.id == id }) else {
            throw ApprovalBrokerError.notFound(id)
        }
        if approval.state.isTerminal {
            return approval
        }
        return await self.awaitTerminal(id, timeoutMs: timeoutMs) ?? self.current(id) ?? approval
    }

    /// Requests an approval and waits until it is terminal.
    /// - Parameters:
    ///   - presentation: Presentation.
    ///   - sessionKey: Raising session.
    ///   - agentID: Requesting agent.
    ///   - runID: Requesting run.
    ///   - toolCallID: Tool call.
    ///   - grantKey: Grant key; an active matching grant allows immediately without a request.
    ///   - timeoutMs: Deadline.
    /// - Returns: The terminal approval (or a synthetic allowed record for a grant hit).
    public func requestAndWait(
        presentation: AgentApprovalPresentation,
        sessionKey: String? = nil,
        agentID: String? = nil,
        runID: String? = nil,
        toolCallID: String? = nil,
        grantKey: String? = nil,
        timeoutMs: Int64? = nil
    ) async -> AgentApproval {
        let started = self.begin(
            presentation: presentation,
            sessionKey: sessionKey,
            agentID: agentID,
            runID: runID,
            toolCallID: toolCallID,
            grantKey: grantKey,
            timeoutMs: timeoutMs
        )
        return await self.waitUntilTerminal(started)
    }

    /// Starts an approval: returns a synthetic `allowed` record when an active grant covers
    /// `grantKey`, otherwise a new pending approval (see ``waitUntilTerminal(_:)``).
    /// - Parameters:
    ///   - presentation: Presentation.
    ///   - sessionKey: Raising session.
    ///   - agentID: Requesting agent.
    ///   - runID: Requesting run.
    ///   - toolCallID: Tool call.
    ///   - grantKey: Grant key.
    ///   - timeoutMs: Deadline.
    /// - Returns: The allowed grant record or the pending approval.
    public func begin(
        presentation: AgentApprovalPresentation,
        sessionKey: String? = nil,
        agentID: String? = nil,
        runID: String? = nil,
        toolCallID: String? = nil,
        grantKey: String? = nil,
        timeoutMs: Int64? = nil
    ) -> AgentApproval {
        if let grantKey, self.consumeGrant(kind: presentation.kind, key: grantKey, agentID: agentID) {
            let now = self.clock()
            return AgentApproval(
                id: "grant:\(grantKey)",
                urlPath: "/approvals/grant",
                kind: presentation.kind,
                presentation: presentation,
                createdAtMs: now,
                expiresAtMs: now,
                state: .allowed,
                decision: .allowAlways,
                reason: .user,
                resolvedAtMs: now,
                sessionKey: sessionKey,
                agentID: agentID,
                runID: runID,
                toolCallID: toolCallID,
                grantKey: grantKey
            )
        }
        return self.request(
            presentation: presentation,
            sessionKey: sessionKey,
            agentID: agentID,
            runID: runID,
            toolCallID: toolCallID,
            grantKey: grantKey,
            timeoutMs: timeoutMs
        )
    }

    /// Waits until an approval from ``begin(presentation:sessionKey:agentID:runID:toolCallID:grantKey:timeoutMs:)``
    /// is terminal; cancelling the waiting task cancels the approval (`run-aborted`).
    /// - Parameter approval: Started approval.
    /// - Returns: The terminal approval.
    public func waitUntilTerminal(_ approval: AgentApproval) async -> AgentApproval {
        guard approval.state == .pending else { return approval }
        let id = approval.id
        let resolved = await withTaskCancellationHandler {
            await self.awaitTerminal(id, timeoutMs: nil)
        } onCancel: {
            Task { await self.cancel(id: id, reason: .runAborted) }
        }
        return resolved ?? self.current(id) ?? approval
    }

    /// Suspends until the approval is terminal, or returns `nil` once `timeoutMs` elapses.
    private func awaitTerminal(_ id: String, timeoutMs: Int64?) async -> AgentApproval? {
        if let approval = self.current(id), approval.state.isTerminal {
            return approval
        }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            self.waiters[id, default: [:]][token] = continuation
            if let timeoutMs {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutMs)) * 1_000_000)
                    self.expireWaiter(id, token: token)
                }
            }
        }
    }

    private func expireWaiter(_ id: String, token: UUID) {
        guard let continuation = self.waiters[id]?.removeValue(forKey: token) else { return }
        if self.waiters[id]?.isEmpty == true {
            self.waiters[id] = nil
        }
        continuation.resume(returning: nil)
    }

    private func current(_ id: String) -> AgentApproval? {
        self.approvals[id] ?? self.history.first(where: { $0.id == id })
    }

    // MARK: - Resolution

    /// Resolves an approval; the first answer wins.
    /// - Parameters:
    ///   - id: Approval id.
    ///   - decision: Reviewer decision.
    ///   - kind: Expected kind (the legacy exec/plugin resolvers pass their kind).
    ///   - reviewer: Reviewer attribution.
    ///   - grantExpiresInDays: Expiry of an `allow-always` grant (`1...3650`; `nil` = until revoked).
    /// - Returns: Whether this call applied the decision, and the terminal approval.
    /// - Throws: ``ApprovalBrokerError``.
    public func resolve(
        id: String,
        decision: ApprovalDecision,
        kind: ApprovalKind? = nil,
        reviewer: AgentApprovalReviewer? = nil,
        grantExpiresInDays: Int? = nil
    ) throws -> (applied: Bool, approval: AgentApproval) {
        if let days = grantExpiresInDays, !(1...3650).contains(days) {
            throw ApprovalBrokerError.invalidGrantExpiry(days)
        }
        guard var approval = self.current(id) else {
            throw ApprovalBrokerError.notFound(id)
        }
        if let kind, kind != approval.kind {
            throw ApprovalBrokerError.kindMismatch(expected: kind, actual: approval.kind)
        }
        guard approval.state == .pending else {
            return (false, approval)
        }
        guard approval.presentation.allowedDecisions.contains(decision) else {
            throw ApprovalBrokerError.decisionNotAllowed(decision)
        }
        let now = self.clock()
        approval.state = decision == .deny ? .denied : .allowed
        approval.decision = decision
        approval.reason = .user
        approval.resolvedAtMs = now
        approval.reviewer = reviewer
        if decision == .allowAlways, let key = approval.grantKey {
            self.mintGrant(for: approval, key: key, expiresInDays: grantExpiresInDays, nowMs: now)
        }
        self.finish(approval)
        return (true, approval)
    }

    /// Denies an approval with a non-user reason (`malformed-verdict`, `no-route`, `storage-corrupt`).
    /// - Parameters:
    ///   - id: Approval id.
    ///   - reason: Terminal reason.
    /// - Returns: The terminal approval, or `nil` when unknown.
    @discardableResult
    public func deny(id: String, reason: ApprovalTerminalReason) -> AgentApproval? {
        guard var approval = self.approvals[id], approval.state == .pending else {
            return self.current(id)
        }
        approval.state = .denied
        approval.decision = .deny
        approval.reason = reason
        approval.resolvedAtMs = self.clock()
        self.finish(approval)
        return approval
    }

    /// Cancels one pending approval.
    /// - Parameters:
    ///   - id: Approval id.
    ///   - reason: Cancellation reason (default `run-aborted`).
    /// - Returns: The terminal approval, or `nil` when unknown.
    @discardableResult
    public func cancel(id: String, reason: ApprovalTerminalReason = .runAborted) -> AgentApproval? {
        guard var approval = self.approvals[id], approval.state == .pending else {
            return self.current(id)
        }
        approval.state = .cancelled
        approval.reason = reason
        approval.resolvedAtMs = self.clock()
        self.finish(approval)
        return approval
    }

    /// Cancels every pending approval raised by a run (`cancelled/run-aborted`).
    /// - Parameter runID: Run identifier.
    /// - Returns: Number of cancelled approvals.
    @discardableResult
    public func cancel(runID: String) -> Int {
        let ids = self.approvals.values.filter { $0.state == .pending && $0.runID == runID }.map(\.id)
        for id in ids {
            self.cancel(id: id, reason: .runAborted)
        }
        return ids.count
    }

    /// Cancels every pending approval of a session (for example after a permission-mode change).
    /// - Parameter sessionKey: Session key.
    /// - Returns: Number of cancelled approvals.
    @discardableResult
    public func cancel(sessionKey: String) -> Int {
        let ids = self.approvals.values.filter { $0.state == .pending && $0.sessionKey == sessionKey }.map(\.id)
        for id in ids {
            self.cancel(id: id, reason: .runAborted)
        }
        return ids.count
    }

    private func expire(_ id: String) {
        guard var approval = self.approvals[id], approval.state == .pending else { return }
        approval.state = .expired
        approval.reason = .timeout
        approval.resolvedAtMs = self.clock()
        self.finish(approval)
    }

    private func finish(_ approval: AgentApproval) {
        self.approvals[approval.id] = nil
        self.expiryTasks.removeValue(forKey: approval.id)?.cancel()
        self.history.insert(approval, at: 0)
        if self.history.count > self.historyLimit {
            self.history.removeLast(self.history.count - self.historyLimit)
        }
        for waiter in (self.waiters.removeValue(forKey: approval.id) ?? [:]).values {
            waiter.resume(returning: approval)
        }
        self.publish(approval)
    }

    // MARK: - Queries

    /// Returns an approval (pending or retained terminal).
    /// - Parameter id: Approval id.
    /// - Returns: The approval, if known.
    public func get(id: String) -> AgentApproval? {
        self.current(id)
    }

    /// Pending approvals, oldest first.
    /// - Parameter kind: Optional kind filter.
    /// - Returns: Pending approvals.
    public func pending(kind: ApprovalKind? = nil) -> [AgentApproval] {
        self.approvals.values
            .filter { kind == nil || $0.kind == kind }
            .sorted { $0.createdAtMs == $1.createdAtMs ? $0.id < $1.id : $0.createdAtMs < $1.createdAtMs }
    }

    /// Newest-first page of terminal approvals.
    /// - Parameters:
    ///   - cursor: Opaque cursor from a previous page.
    ///   - limit: Page size (`1...100`, default 50).
    ///   - kind: Optional kind filter.
    /// - Returns: Items and the next cursor.
    public func history(cursor: String? = nil, limit: Int? = nil, kind: ApprovalKind? = nil) -> (items: [AgentApproval], nextCursor: String?) {
        let pageSize = min(100, max(1, limit ?? 50))
        let filtered = self.history.filter { kind == nil || $0.kind == kind }
        let start = cursor.flatMap(Int.init) ?? 0
        guard start < filtered.count else { return ([], nil) }
        let end = min(filtered.count, start + pageSize)
        return (Array(filtered[start..<end]), end < filtered.count ? String(end) : nil)
    }

    // MARK: - Grants

    /// Active and revoked standing grants, newest first.
    /// - Parameter limit: Maximum grants (`1...500`).
    /// - Returns: Grants.
    public func listGrants(limit: Int = 500) -> [AgentApprovalGrant] {
        Array(self.grants.values.sorted { $0.createdAtMs > $1.createdAtMs }.prefix(min(500, max(1, limit))))
    }

    /// Revokes a grant.
    /// - Parameter grantID: Grant id.
    /// - Returns: `revoked`, `already-revoked` or `not-found` (upstream outcome values).
    @discardableResult
    public func revokeGrant(_ grantID: String) -> String {
        guard var grant = self.grants[grantID] else { return "not-found" }
        guard grant.revokedAtMs == nil else { return "already-revoked" }
        grant.revokedAtMs = self.clock()
        self.grants[grantID] = grant
        self.persistGrants()
        return "revoked"
    }

    /// Whether an active grant covers a key.
    /// - Parameters:
    ///   - kind: Approval kind.
    ///   - key: Grant key.
    ///   - agentID: Requesting agent.
    /// - Returns: `true` when a grant matches.
    public func hasGrant(kind: ApprovalKind, key: String, agentID: String? = nil) -> Bool {
        let now = self.clock()
        return self.grants.values.contains { grant in
            grant.kind == kind && grant.key == key && grant.isActive(nowMs: now) && (grant.agentID == nil || grant.agentID == agentID)
        }
    }

    private func consumeGrant(kind: ApprovalKind, key: String, agentID: String?) -> Bool {
        let now = self.clock()
        guard let match = self.grants.values.first(where: { grant in
            grant.kind == kind && grant.key == key && grant.isActive(nowMs: now) && (grant.agentID == nil || grant.agentID == agentID)
        }) else {
            return false
        }
        var updated = match
        updated.useCount += 1
        updated.lastUsedAtMs = now
        self.grants[match.id] = updated
        self.persistGrants()
        return true
    }

    private func mintGrant(for approval: AgentApproval, key: String, expiresInDays: Int?, nowMs: Int64) {
        let grant = AgentApprovalGrant(
            id: UUID().uuidString.lowercased(),
            kind: approval.kind,
            key: key,
            agentID: approval.agentID,
            mintedByApprovalID: approval.id,
            createdAtMs: nowMs,
            expiresAtMs: expiresInDays.map { nowMs + Int64($0) * 86_400_000 },
            revokedAtMs: nil,
            lastUsedAtMs: nil,
            useCount: 0
        )
        self.grants[grant.id] = grant
        self.persistGrants()
    }

    private func persistGrants() {
        guard let grantsFileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self.grants.values.sorted { $0.createdAtMs < $1.createdAtMs }) else { return }
        try? FileManager.default.createDirectory(at: grantsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: grantsFileURL, options: [.atomic])
    }

    // MARK: - Grant keys

    /// Grant key for an exec command: the executable plus its first non-flag argument.
    ///
    /// `git status -s` and `git status` share the key `exec:git status`; `rm -rf /` keys as `exec:rm`.
    /// - Parameter command: Command text.
    /// - Returns: The grant key.
    public static func execGrantKey(command: String) -> String {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = tokens.first else { return "exec:" }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if tokens.count > 1, !tokens[1].hasPrefix("-") {
            return "exec:\(name) \(tokens[1])"
        }
        return "exec:\(name)"
    }

    /// Grant key for a plugin tool: `plugin:<pluginId>:<toolName>`.
    /// - Parameters:
    ///   - pluginID: Plugin id (`nil` for core/client tools).
    ///   - toolName: Tool name.
    /// - Returns: The grant key.
    public static func pluginGrantKey(pluginID: String?, toolName: String) -> String {
        "plugin:\(pluginID ?? "core"):\(AgentToolRegistry.canonicalName(toolName))"
    }

    /// Grant key for an MCP tool: `mcp:<server>:<tool>`.
    /// - Parameters:
    ///   - server: MCP server name.
    ///   - tool: MCP tool name.
    /// - Returns: The grant key.
    public static func mcpGrantKey(server: String, tool: String) -> String {
        "mcp:\(server):\(tool)"
    }
}

extension String {
    var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
