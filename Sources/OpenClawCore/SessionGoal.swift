import Foundation

/// Lifecycle status of a ``SessionGoal`` (upstream `SessionGoalSchema.status`).
public enum SessionGoalStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// The agent is working toward the goal.
    case active
    /// Paused by the user or the agent.
    case paused
    /// Blocked on something outside the agent's control.
    case blocked
    /// Stopped because a provider usage limit was hit.
    case usageLimited = "usage_limited"
    /// Stopped because the goal's token budget was exceeded.
    case budgetLimited = "budget_limited"
    /// Completed.
    case complete

    /// Whether the goal still counts as the session's open goal (every status except `complete`).
    public var isOpen: Bool {
        self != .complete
    }
}

/// Durable objective attached to one session (upstream `SessionGoalSchema`, schema version 1).
///
/// Timestamps are milliseconds since the epoch. `tokensUsed` accumulates run usage after the goal
/// starts; exceeding `tokenBudget` moves the goal to ``SessionGoalStatus/budgetLimited``.
public struct SessionGoal: Codable, Sendable, Equatable {
    /// Schema version (always `1`).
    public var schemaVersion: Int
    /// Goal identifier.
    public var id: String
    /// Objective text (1...16000 characters).
    public var objective: String
    /// Lifecycle status.
    public var status: SessionGoalStatus
    /// Creation time (ms).
    public var createdAt: Int64
    /// Last update time (ms).
    public var updatedAt: Int64
    /// Session token total when the goal started.
    public var tokenStart: Int64
    /// Whether `tokenStart` was taken from a fresh session.
    public var tokenStartFresh: Bool?
    /// Tokens used since the goal started.
    public var tokensUsed: Int64
    /// Optional token budget.
    public var tokenBudget: Int64?
    /// Continuation turns spent on the goal.
    public var continuationTurns: Int
    /// Latest status note.
    public var lastStatusNote: String?
    /// Time the goal was paused (ms).
    public var pausedAt: Int64?
    /// Time the goal was blocked (ms).
    public var blockedAt: Int64?
    /// Time the goal was completed (ms).
    public var completedAt: Int64?
    /// Time the goal hit a usage limit (ms).
    public var usageLimitedAt: Int64?
    /// Time the goal exceeded its budget (ms).
    public var budgetLimitedAt: Int64?

    /// Maximum objective length in characters.
    public static let maxObjectiveLength = 16_000
    /// Maximum status-note length in characters.
    public static let maxNoteLength = 2_000

    /// Creates a goal.
    /// - Parameters:
    ///   - id: Goal identifier; defaults to a new UUID.
    ///   - objective: Objective text.
    ///   - status: Initial status.
    ///   - nowMs: Creation time in milliseconds.
    ///   - tokenStart: Session token total at creation.
    ///   - tokenBudget: Optional token budget.
    public init(
        id: String = UUID().uuidString.lowercased(),
        objective: String,
        status: SessionGoalStatus = .active,
        nowMs: Int64,
        tokenStart: Int64 = 0,
        tokenBudget: Int64? = nil
    ) {
        self.schemaVersion = 1
        self.id = id
        self.objective = objective
        self.status = status
        self.createdAt = nowMs
        self.updatedAt = nowMs
        self.tokenStart = tokenStart
        self.tokenStartFresh = nil
        self.tokensUsed = 0
        self.tokenBudget = tokenBudget
        self.continuationTurns = 0
        self.lastStatusNote = nil
        self.pausedAt = nil
        self.blockedAt = nil
        self.completedAt = nil
        self.usageLimitedAt = nil
        self.budgetLimitedAt = nil
    }

    /// System-prompt line injected while the goal is open: `Current session goal: <objective> (<status>)`.
    public var promptLine: String {
        "Current session goal: \(self.objective) (\(self.status.rawValue))"
    }

    /// Adds run usage and applies the token budget.
    /// - Parameters:
    ///   - tokens: Tokens used by a run.
    ///   - nowMs: Current time in milliseconds.
    public mutating func recordUsage(_ tokens: Int64, nowMs: Int64) {
        guard tokens > 0, self.status == .active else { return }
        self.tokensUsed += tokens
        self.updatedAt = nowMs
        if let budget = self.tokenBudget, budget > 0, self.tokensUsed > budget {
            self.status = .budgetLimited
            self.budgetLimitedAt = nowMs
        }
    }
}
