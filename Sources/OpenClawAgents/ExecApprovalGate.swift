import Foundation
import OpenClawCore
import OpenClawProtocol

// Exec approval semantics for runtimes that host an `exec` tool (upstream
// `docs/gateway/permission-modes.md`, CHANGELOG 2026.9.4 #141987 auto-review, 2026.9.5 #146517).

/// Verdict of an automatic (LLM) exec reviewer.
public enum ExecReviewVerdict: Sendable, Equatable {
    /// Run the command.
    case allow
    /// Do not run the command; the reason goes back to the agent (terminal for that command).
    case deny(reason: String)
    /// Ask a human.
    case ask(reason: String?)
}

/// Input to an ``ExecAutoReviewer``.
public struct ExecReviewRequest: Sendable, Equatable {
    /// Command text.
    public var command: String
    /// Working directory.
    public var cwd: String?
    /// Session key.
    public var sessionKey: String
    /// Agent id.
    public var agentID: String?
    /// Run id.
    public var runID: String?

    /// Creates a review request.
    public init(command: String, cwd: String? = nil, sessionKey: String, agentID: String? = nil, runID: String? = nil) {
        self.command = command
        self.cwd = cwd
        self.sessionKey = sessionKey
        self.agentID = agentID
        self.runID = runID
    }
}

/// Automatic exec reviewer (throwing counts as a review failure, which asks a human).
public typealias ExecAutoReviewer = @Sendable (ExecReviewRequest) async throws -> ExecReviewVerdict

/// Outcome of ``ExecApprovalGate/evaluate(command:cwd:permissionMode:configuredMode:sessionKey:agentID:runID:toolCallID:)``.
public enum ExecGateDecision: Sendable, Equatable {
    /// Who allowed the command.
    public enum AllowSource: String, Sendable, Equatable {
        /// `full` access.
        case fullAccess = "full-access"
        /// Allowlist fast path.
        case allowlist
        /// Standing `allow-always` grant.
        case grant
        /// Automatic reviewer.
        case reviewer
        /// Human approval.
        case human
    }

    /// Who denied the command.
    public enum DenySource: String, Sendable, Equatable {
        /// The permission mode forbids exec (`read-only`) or the allowlist missed with ask off.
        case policy
        /// Automatic reviewer denial (no human card).
        case reviewer
        /// Human denial, or an approval that expired or was cancelled before a decision (only an
        /// explicit denial closes the command).
        case human
        /// The same command was already explicitly denied (by a human or the reviewer) in this
        /// session; it is never re-presented.
        case closed
    }

    /// Run the command.
    case allow(source: AllowSource)
    /// Do not run the command; `reason` is returned to the agent.
    case deny(reason: String, source: DenySource)

    /// Whether the command may run.
    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// Decides whether a runtime-hosted exec command may run.
///
/// Rules:
/// - `read-only` (exec mode `deny`) denies; `full` allows.
/// - Allowlisted commands and active `allow-always` grants run without prompting. The allowlist hook
///   receives the command text exactly as it will run; multi-line commands skip the allowlist fast
///   path. Grants are bound to the exact argv (see ``ApprovalBroker/execGrantKey(command:cwd:)``);
///   a chain runs on grants only when every segment has its own grant, and substitutions,
///   redirections, shells, wrappers and interpreters never run on a grant or offer `allow-always`.
/// - `allowlist` mode (ask off) denies misses.
/// - `guarded` (exec mode `ask`) asks a human through the ``ApprovalBroker``.
/// - `workspace` (exec mode `auto`) asks the automatic reviewer: `allow` runs; `deny` is terminal for the
///   command and returns the reason to the agent without a human card; `ask` or a reviewer failure asks a
///   human; three consecutive reviewer denials in a session escalate the next command to a human.
/// - An explicitly denied command (human or reviewer) is closed for the session: it is never
///   re-presented or retried. An approval that expires or is cancelled denies only that attempt.
public actor ExecApprovalGate {
    /// Consecutive reviewer denials that escalate to a human.
    public static let reviewerEscalationThreshold = 3

    private let broker: ApprovalBroker
    private let reviewer: ExecAutoReviewer?
    private let allowlist: @Sendable (String) -> Bool
    private let approvalTimeoutMs: Int64?
    private var consecutiveDenials: [String: Int] = [:]
    private var closedCommands: Set<String> = []

    /// Creates a gate.
    /// - Parameters:
    ///   - broker: Broker for human approvals and grants.
    ///   - reviewer: Automatic reviewer used in `workspace` mode (`nil` asks a human).
    ///   - approvalTimeoutMs: Human approval deadline.
    ///   - allowlist: Allowlist fast path, called with the raw command text (for example
    ///     `ExecAllowlistEvaluator.allows(commandText:)`, which checks every chain segment).
    public init(
        broker: ApprovalBroker,
        reviewer: ExecAutoReviewer? = nil,
        approvalTimeoutMs: Int64? = nil,
        allowlist: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        self.broker = broker
        self.reviewer = reviewer
        self.approvalTimeoutMs = approvalTimeoutMs
        self.allowlist = allowlist
    }

    /// Evaluates a command.
    /// - Parameters:
    ///   - command: Command text.
    ///   - cwd: Working directory.
    ///   - permissionMode: Session permission mode (`nil` = configured default).
    ///   - configuredMode: Configured exec mode used when the session has no mode (default `full`).
    ///   - sessionKey: Session key.
    ///   - agentID: Agent id.
    ///   - runID: Run id.
    ///   - toolCallID: Tool call id.
    /// - Returns: The decision.
    public func evaluate(
        command: String,
        cwd: String? = nil,
        permissionMode: SessionPermissionMode?,
        configuredMode: ExecMode = .full,
        sessionKey: String,
        agentID: String? = nil,
        runID: String? = nil,
        toolCallID: String? = nil
    ) async -> ExecGateDecision {
        let mode = permissionMode?.execMode ?? configuredMode
        let closedKey = "\(sessionKey)\u{1F}\(Self.normalizedCommandText(command))"
        switch mode {
        case .deny:
            return .deny(reason: "Exec is denied in this session (permission mode read-only).", source: .policy)
        case .full:
            return .allow(source: .fullAccess)
        case .allowlist, .ask, .auto:
            break
        }
        if self.closedCommands.contains(closedKey) {
            return .deny(reason: "This command was already denied in this session; choose a different approach.", source: .closed)
        }
        // The hook sees the text that will run. Newlines separate shell commands, so multi-line text
        // never takes the fast path (hooks that do not split chains would match only the first line).
        if !command.contains(where: \.isNewline), self.allowlist(command) {
            return .allow(source: .allowlist)
        }
        if await self.coveredByGrants(command: command, cwd: cwd, agentID: agentID) {
            return .allow(source: .grant)
        }
        let request = HumanRequest(
            command: command,
            cwd: cwd,
            closedKey: closedKey,
            sessionKey: sessionKey,
            agentID: agentID,
            runID: runID,
            toolCallID: toolCallID
        )
        switch mode {
        case .allowlist:
            return .deny(reason: "Command is not on the exec allowlist.", source: .policy)
        case .ask:
            return await self.askHuman(request, warning: nil)
        case .auto:
            let escalate = (self.consecutiveDenials[sessionKey] ?? 0) >= Self.reviewerEscalationThreshold
            guard let reviewer, !escalate else {
                let warning = escalate ? "Escalated after \(Self.reviewerEscalationThreshold) consecutive reviewer denials." : nil
                return await self.askHuman(request, warning: warning)
            }
            let verdict: ExecReviewVerdict
            do {
                verdict = try await reviewer(
                    ExecReviewRequest(command: command, cwd: cwd, sessionKey: sessionKey, agentID: agentID, runID: runID)
                )
            } catch {
                verdict = .ask(reason: "Automatic review failed: \(error.localizedDescription)")
            }
            switch verdict {
            case .allow:
                self.consecutiveDenials[sessionKey] = 0
                return .allow(source: .reviewer)
            case .deny(let reason):
                self.consecutiveDenials[sessionKey, default: 0] += 1
                self.closedCommands.insert(closedKey)
                return .deny(
                    reason: "Automatic review denied this command: \(reason). Choose a materially safer alternative or ask the user.",
                    source: .reviewer
                )
            case .ask(let reason):
                return await self.askHuman(request, warning: reason)
            }
        case .deny, .full:
            return .deny(reason: "unreachable", source: .policy)
        }
    }

    /// Command text with each line's whitespace runs collapsed (newlines are kept), used as the
    /// closed-command identity.
    /// - Parameter command: Command text.
    /// - Returns: Normalized text.
    static func normalizedCommandText(_ command: String) -> String {
        command.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Whether active grants cover the command: a simple command needs its own grant; a chain needs a
    /// grant for every segment; anything the chain splitter refuses (substitution, redirection,
    /// background jobs) never runs on a grant.
    private func coveredByGrants(command: String, cwd: String?, agentID: String?) async -> Bool {
        guard let segments = ExecShellWords.splitCommandChain(command), !segments.isEmpty else { return false }
        for segment in segments {
            guard let key = ApprovalBroker.execGrantKey(command: segment, cwd: cwd),
                  await self.broker.hasGrant(kind: .exec, key: key, agentID: agentID)
            else {
                return false
            }
        }
        return true
    }

    /// Clears closed commands and denial counters of a session (for example after `sessions.reset`).
    /// - Parameter sessionKey: Session key.
    public func reset(sessionKey: String) {
        self.consecutiveDenials[sessionKey] = nil
        self.closedCommands = self.closedCommands.filter { !$0.hasPrefix("\(sessionKey)\u{1F}") }
    }

    private struct HumanRequest: Sendable {
        let command: String
        let cwd: String?
        let closedKey: String
        let sessionKey: String
        let agentID: String?
        let runID: String?
        let toolCallID: String?
    }

    private func askHuman(_ request: HumanRequest, warning: String?) async -> ExecGateDecision {
        // Chains, shells, wrappers and interpreters get no grant key, so the card offers allow-once only.
        let grantKey = ApprovalBroker.execGrantKey(command: request.command, cwd: request.cwd)
        let approval = await self.broker.requestAndWait(
            presentation: .exec(
                commandText: request.command,
                warningText: warning,
                agentID: request.agentID,
                allowedDecisions: grantKey == nil ? [.allowOnce, .deny] : [.allowOnce, .allowAlways, .deny]
            ),
            sessionKey: request.sessionKey,
            agentID: request.agentID,
            runID: request.runID,
            toolCallID: request.toolCallID,
            grantKey: grantKey,
            timeoutMs: self.approvalTimeoutMs
        )
        if approval.isAllowed {
            self.consecutiveDenials[request.sessionKey] = 0
            return .allow(source: .human)
        }
        let reason = approval.reason?.rawValue ?? approval.state.rawValue
        guard approval.state == .denied else {
            // Expiry and cancellation are not decisions: deny this attempt without closing the command.
            return .deny(
                reason: "The approval \(approval.state.rawValue) before a decision (\(reason)); ask the user before trying again.",
                source: .human
            )
        }
        self.closedCommands.insert(request.closedKey)
        return .deny(reason: "The command was not approved (\(approval.state.rawValue): \(reason)); do not retry it.", source: .human)
    }
}

/// Reconciles an approval backfill (`exec.approval.list` / `plugin.approval.list`) with live
/// `*.approval.requested` / `*.approval.resolved` events.
///
/// Start the event listener before listing; feed events and the list in any order. Requests that race
/// the list are not lost, and approvals resolved while the list was in flight are not resurrected.
public struct ApprovalBackfillReconciler: Sendable, Equatable {
    /// Pending approvals keyed by id (raw wire payloads).
    public private(set) var pending: [String: [String: AnyCodable]] = [:]
    private var resolved: Set<String> = []

    /// Creates an empty reconciler.
    public init() {}

    /// Applies a `*.approval.requested` event.
    /// - Parameters:
    ///   - id: Approval id.
    ///   - payload: Event payload.
    public mutating func applyRequested(id: String, payload: [String: AnyCodable]) {
        guard !self.resolved.contains(id) else { return }
        self.pending[id] = payload
    }

    /// Applies a `*.approval.resolved` event (a tombstone keeps the id from coming back).
    /// - Parameter id: Approval id.
    public mutating func applyResolved(id: String) {
        self.resolved.insert(id)
        self.pending[id] = nil
    }

    /// Applies a backfill list: listed ids not tombstoned become pending; pending ids missing from the
    /// list are kept only when they arrived through events (they may postdate the list snapshot).
    /// - Parameter items: Listed rows (`{id, …}`).
    public mutating func applyList(_ items: [[String: AnyCodable]]) {
        for item in items {
            guard let id = item["id"]?.stringValue, !self.resolved.contains(id) else { continue }
            self.pending[id] = self.pending[id] ?? item
        }
    }

    /// Pending approval ids, sorted.
    public var pendingIDs: [String] {
        self.pending.keys.sorted()
    }
}
