import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

// Session goals (upstream `packages/gateway-protocol/src/schema/sessions-goal.ts`, `docs/tools/goal.md`,
// `src/agents/tools/goal-tools.ts`). The goal lives on `SessionRecord.goal`; the loop injects
// `Current session goal: <objective> (<status>)` into the system prompt while it is open.

/// Goal update action (upstream `sessions.goal.update` actions).
public enum SessionGoalAction: String, Codable, Sendable, Equatable, CaseIterable {
    /// Replace the objective.
    case edit
    /// Pause.
    case pause
    /// Resume.
    case resume
    /// Mark complete.
    case complete
    /// Mark blocked.
    case block
}

/// Error raised by ``SessionGoalManager``.
public enum SessionGoalError: Error, LocalizedError, Sendable, Equatable {
    /// Invalid request.
    case invalid(String)
    /// No session store or unknown session.
    case unavailable(String)

    /// Human-readable message.
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message):
            return message
        }
    }
}

/// Goal operations shared by the goal tools and the `sessions.goal.*` RPCs.
public actor SessionGoalManager {
    private let store: SessionStore
    private var operations: [String: [String: AnyCodable]] = [:]
    private var operationOrder: [String] = []

    /// Creates a manager.
    /// - Parameter store: Session store holding the goals.
    public init(store: SessionStore) {
        self.store = store
    }

    /// Current goal of a session.
    /// - Parameter sessionKey: Session key.
    /// - Returns: The goal.
    public func goal(sessionKey: String) async -> SessionGoal? {
        await self.store.recordForKey(sessionKey)?.goal
    }

    /// Creates a goal (fails while an open goal exists).
    /// - Parameters:
    ///   - objective: Objective (1...16000 characters).
    ///   - tokenBudget: Optional token budget.
    ///   - sessionKey: Session key.
    /// - Returns: The goal.
    /// - Throws: ``SessionGoalError``.
    @discardableResult
    public func create(objective: String, tokenBudget: Int64? = nil, sessionKey: String) async throws -> SessionGoal {
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= SessionGoal.maxObjectiveLength else {
            throw SessionGoalError.invalid("objective must be 1-\(SessionGoal.maxObjectiveLength) characters")
        }
        guard let record = await self.store.recordForKey(sessionKey) else {
            throw SessionGoalError.unavailable("unknown session: \(sessionKey)")
        }
        if let existing = record.goal, existing.status.isOpen {
            throw SessionGoalError.invalid("session already has an open goal; complete or edit it first")
        }
        let goal = SessionGoal(
            objective: trimmed,
            nowMs: SessionTranscriptClock.nowMs(),
            tokenStart: record.totalTokens ?? 0,
            tokenBudget: tokenBudget.flatMap { $0 > 0 ? $0 : nil }
        )
        await self.store.update(forKey: sessionKey) { $0.goal = goal }
        try? await self.store.save()
        return goal
    }

    /// Applies an update action.
    /// - Parameters:
    ///   - action: Action.
    ///   - objective: New objective (`edit`).
    ///   - note: Status note (≤ 2000 characters).
    ///   - sessionKey: Session key.
    ///   - goalID: Expected goal id.
    /// - Returns: The updated goal.
    /// - Throws: ``SessionGoalError``.
    @discardableResult
    public func update(
        action: SessionGoalAction,
        objective: String? = nil,
        note: String? = nil,
        sessionKey: String,
        goalID: String? = nil
    ) async throws -> SessionGoal {
        guard var goal = await self.store.recordForKey(sessionKey)?.goal else {
            throw SessionGoalError.invalid("session has no goal")
        }
        if let goalID, goalID != goal.id {
            throw SessionGoalError.invalid("goal changed (expected \(goalID))")
        }
        if let note, note.count > SessionGoal.maxNoteLength {
            throw SessionGoalError.invalid("note must be at most \(SessionGoal.maxNoteLength) characters")
        }
        let now = SessionTranscriptClock.nowMs()
        switch action {
        case .edit:
            guard let objective = objective?.trimmingCharacters(in: .whitespacesAndNewlines), !objective.isEmpty,
                  objective.count <= SessionGoal.maxObjectiveLength
            else {
                throw SessionGoalError.invalid("edit requires an objective of 1-\(SessionGoal.maxObjectiveLength) characters")
            }
            goal.objective = objective
        case .pause:
            goal.status = .paused
            goal.pausedAt = now
        case .resume:
            goal.status = .active
        case .complete:
            goal.status = .complete
            goal.completedAt = now
        case .block:
            goal.status = .blocked
            goal.blockedAt = now
        }
        if let note {
            goal.lastStatusNote = note
        }
        goal.updatedAt = now
        let updated = goal
        await self.store.update(forKey: sessionKey) { $0.goal = updated }
        try? await self.store.save()
        return updated
    }

    /// Clears the goal.
    /// - Parameter sessionKey: Session key.
    /// - Returns: The cleared goal.
    @discardableResult
    public func clear(sessionKey: String) async -> SessionGoal? {
        let previous = await self.store.recordForKey(sessionKey)?.goal
        await self.store.update(forKey: sessionKey) { $0.goal = nil }
        try? await self.store.save()
        return previous
    }

    /// Registers `sessions.goal.update` and `sessions.goal.clear` (operationId idempotency).
    /// - Parameter registrar: Gateway registrar.
    public func registerGatewayMethods(on registrar: some GatewayMethodRegistrar) async {
        await registrar.register(method: "sessions.goal.update", descriptor: nil) { [weak self] request in
            guard let self else { throw GatewayMethodError.unavailable("goal manager released") }
            return try await self.handle(request, clear: false)
        }
        await registrar.register(method: "sessions.goal.clear", descriptor: nil) { [weak self] request in
            guard let self else { throw GatewayMethodError.unavailable("goal manager released") }
            return try await self.handle(request, clear: true)
        }
    }

    private func handle(_ request: GatewayMethodRequest, clear: Bool) async throws -> AnyCodable {
        let params = request.params
        guard let sessionKey = params["sessionKey"]?.stringValue, let goalID = params["goalId"]?.stringValue,
              let operationID = params["operationId"]?.stringValue, !operationID.isEmpty, operationID.count <= 128
        else {
            throw GatewayMethodError.invalidRequest("sessionKey, goalId and operationId (<= 128 chars) are required")
        }
        if var replay = self.operations[operationID] {
            replay["replayed"] = AnyCodable(true)
            return AnyCodable(replay)
        }
        guard let record = await self.store.recordForKey(sessionKey) else {
            throw GatewayMethodError.invalidRequest("unknown session: \(sessionKey)")
        }
        if let sessionID = params["sessionId"]?.stringValue, sessionID != record.sessionID {
            throw GatewayMethodError.invalidRequest("session changed (sessionId mismatch)")
        }
        var result: [String: AnyCodable] = [
            "operationId": AnyCodable(operationID),
            "sessionId": AnyCodable(record.sessionID ?? ""),
            "goalId": AnyCodable(goalID),
        ]
        do {
            if clear {
                guard record.goal?.id == goalID else {
                    throw SessionGoalError.invalid("goal changed (expected \(goalID))")
                }
                await self.clear(sessionKey: sessionKey)
                result["action"] = AnyCodable("clear")
                result["status"] = AnyCodable("cleared")
            } else {
                guard let action = params["action"]?.stringValue.flatMap(SessionGoalAction.init(rawValue:)) else {
                    throw SessionGoalError.invalid("invalid action (use edit|pause|resume|complete|block)")
                }
                let goal = try await self.update(
                    action: action,
                    objective: params["objective"]?.stringValue,
                    note: params["note"]?.stringValue,
                    sessionKey: sessionKey,
                    goalID: goalID
                )
                result["action"] = AnyCodable(action.rawValue)
                result["status"] = AnyCodable("updated")
                result["goal"] = (try? AnyCodable(encoding: goal)) ?? .nullValue
            }
        } catch let error as SessionGoalError {
            throw GatewayMethodError.invalidRequest(error.localizedDescription)
        }
        self.operations[operationID] = result
        self.operationOrder.append(operationID)
        if self.operationOrder.count > 1_024 {
            self.operations[self.operationOrder.removeFirst()] = nil
        }
        return AnyCodable(result)
    }
}

/// Goal tools (`get_goal`, `create_goal`, `update_goal`).
public enum SessionGoalTools {
    /// Creates the three goal tools.
    /// - Parameter manager: Goal manager.
    /// - Returns: Tools to register.
    public static func tools(manager: SessionGoalManager) -> [any AgentTool] {
        [GetGoalTool(manager: manager), CreateGoalTool(manager: manager), UpdateGoalTool(manager: manager)]
    }

    static func goalOutput(_ goal: SessionGoal?) -> AgentToolOutput {
        guard let goal else {
            return AgentToolOutput(content: [.text("No goal is set for this session.")], details: .nullValue)
        }
        let details = (try? AnyCodable(encoding: goal)) ?? .nullValue
        return AgentToolOutput(content: [.text("\(goal.promptLine)\n\n\(AgentToolOutput.renderText(details))")], details: details)
    }
}

struct GetGoalTool: AgentTool {
    let name = "get_goal"
    let manager: SessionGoalManager

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "Get Goal",
            description: "Get current thread goal",
            sectionID: "agents",
            defaultProfiles: [.coding],
            risk: .low
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        guard let sessionKey = invocation.sessionKey else { return .error("get_goal requires a session") }
        return SessionGoalTools.goalOutput(await self.manager.goal(sessionKey: sessionKey))
    }
}

struct CreateGoalTool: AgentTool {
    let name = "create_goal"
    let manager: SessionGoalManager

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "Create Goal",
            description: "Create a thread goal. Fails while an open goal exists.",
            parameters: [
                "type": AnyCodable("object"),
                "required": AnyCodable(["objective"]),
                "additionalProperties": AnyCodable(false),
                "properties": AnyCodable([
                    "objective": AnyCodable(["type": AnyCodable("string"), "minLength": AnyCodable(1), "maxLength": AnyCodable(16_000)]),
                    "tokenBudget": AnyCodable(["type": AnyCodable("integer"), "minimum": AnyCodable(1)]),
                ]),
            ],
            sectionID: "agents",
            defaultProfiles: [.coding]
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        guard let sessionKey = invocation.sessionKey else { return .error("create_goal requires a session") }
        do {
            let goal = try await self.manager.create(
                objective: invocation.arguments["objective"]?.stringValue ?? "",
                tokenBudget: invocation.arguments["tokenBudget"]?.int64Value,
                sessionKey: sessionKey
            )
            return SessionGoalTools.goalOutput(goal)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

struct UpdateGoalTool: AgentTool {
    let name = "update_goal"
    let manager: SessionGoalManager

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "Update Goal",
            description: "Complete or block a thread goal (also edit, pause, resume).",
            parameters: [
                "type": AnyCodable("object"),
                "required": AnyCodable(["action"]),
                "additionalProperties": AnyCodable(false),
                "properties": AnyCodable([
                    "action": AnyCodable(["type": AnyCodable("string"), "enum": AnyCodable(["edit", "pause", "resume", "complete", "block"])]),
                    "objective": AnyCodable(["type": AnyCodable("string"), "maxLength": AnyCodable(16_000)]),
                    "note": AnyCodable(["type": AnyCodable("string"), "maxLength": AnyCodable(2_000)]),
                ]),
            ],
            sectionID: "agents",
            defaultProfiles: [.coding]
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        guard let sessionKey = invocation.sessionKey else { return .error("update_goal requires a session") }
        guard let action = invocation.arguments["action"]?.stringValue.flatMap(SessionGoalAction.init(rawValue:)) else {
            return .error("action must be edit, pause, resume, complete or block")
        }
        do {
            let goal = try await self.manager.update(
                action: action,
                objective: invocation.arguments["objective"]?.stringValue,
                note: invocation.arguments["note"]?.stringValue,
                sessionKey: sessionKey
            )
            return SessionGoalTools.goalOutput(goal)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
