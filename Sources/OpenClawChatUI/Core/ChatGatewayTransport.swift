import Foundation
import OpenClawProtocol

/// Shared RPC application layer. Platform adapters retain route acquisition,
/// dispatch fencing, event subscriptions, and their session-target policy.
///
/// Conforming types implement the requirements below and inherit
/// gateway-backed implementations of the session, question, task, command,
/// and branch operations of ``OpenClawChatTransport``.
public protocol OpenClawChatGatewayTransport: OpenClawChatTransport {
    /// Agent the transport is scoped to (used for bare session keys and command catalogs).
    var chatGatewayAgentID: String? { get }
    /// Resolves the wire target for a session key under the platform's targeting policy.
    func sessionTarget(for sessionKey: String, overrideAgentID: String?) -> OpenClawChatSessionTarget
    /// Sends a gateway request and returns the raw response payload.
    func requestChatGateway(_ request: OpenClawChatGatewayRequest) async throws -> Data
    /// Sends a transcript-branch action; platforms may route it through a stricter authority check.
    func requestChatSessionAction(_ request: OpenClawChatGatewayRequest) async throws -> Data
}

extension OpenClawChatGatewayTransport {
    /// Default: sends branch actions through ``requestChatGateway(_:)``.
    public func requestChatSessionAction(_ request: OpenClawChatGatewayRequest) async throws -> Data {
        try await self.requestChatGateway(request)
    }

    /// Aborts a run with `chat.abort`.
    public func abortRun(sessionKey: String, runId: String) async throws {
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: nil)
        let request = OpenClawChatGatewayRequests.abortRun(
            sessionKey: target.sessionKey,
            agentID: target.agentID,
            runID: runId)
        _ = try await self.requestChatGateway(request)
    }

    /// Deletes a session and its transcript with `sessions.delete`.
    public func deleteSession(key: String) async throws {
        let target = self.sessionTarget(for: key, overrideAgentID: nil)
        let request = OpenClawChatGatewayRequests.deleteSession(
            sessionKey: target.sessionKey,
            agentID: target.agentID)
        _ = try await self.requestChatGateway(request)
    }

    /// Subscribes to the session's message events.
    public func setActiveSessionKey(_ sessionKey: String) async throws {
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: nil)
        let request = OpenClawChatGatewayRequests.subscribeSessionMessages(
            sessionKey: target.sessionKey,
            agentID: target.agentID)
        _ = try await self.requestChatGateway(request)
    }

    /// Resets a session with `sessions.reset`.
    public func resetSession(sessionKey: String) async throws {
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: nil)
        let request = OpenClawChatGatewayRequests.resetSession(
            sessionKey: target.sessionKey,
            agentID: target.agentID)
        _ = try await self.requestChatGateway(request)
    }

    /// Lists slash commands with `commands.list`.
    public func listCommands(sessionKey: String) async throws -> [OpenClawChatCommandChoice] {
        let request = OpenClawChatGatewayRequests.commandsList(
            sessionKey: sessionKey,
            fallbackAgentID: self.chatGatewayAgentID)
        let data = try await self.requestChatGateway(request)
        let decoded = try JSONDecoder().decode(CommandsListResult.self, from: data)
        return decoded.commands.map(OpenClawChatGatewayPayloadCodec.commandChoice)
    }

    /// Lists pending questions.
    public func listQuestions() async throws -> [QuestionRecord] {
        let data = try await self.requestChatGateway(OpenClawChatGatewayRequests.questionList())
        return try JSONDecoder().decode(QuestionListResult.self, from: data).questions
    }

    /// Lists the session's tasks.
    public func listTasks(sessionKey: String, agentID: String?) async throws -> [TaskSummary] {
        let data = try await self.requestChatGateway(OpenClawChatGatewayRequests.tasksList(
            sessionKey: sessionKey,
            agentID: agentID))
        return try JSONDecoder().decode(TasksListResult.self, from: data).tasks
    }

    /// Loads one question.
    public func getQuestion(id: String) async throws -> QuestionRecord {
        let data = try await self.requestChatGateway(OpenClawChatGatewayRequests.questionGet(id: id))
        return try JSONDecoder().decode(QuestionGetResult.self, from: data).question
    }

    /// Answers a question.
    public func resolveQuestion(
        id: String,
        answers: [String: [String]],
        secretStoreAllowedHosts: [String]?) async throws -> QuestionAnswers
    {
        let data = try await self.requestChatGateway(OpenClawChatGatewayRequests.resolveQuestion(
            id: id,
            answers: answers,
            secretStoreAllowedHosts: secretStoreAllowedHosts))
        return try OpenClawChatGatewayPayloadCodec.decodeQuestionAnswer(data)
    }

    /// Cancels a question.
    public func cancelQuestion(id: String) async throws {
        _ = try await self.requestChatGateway(
            OpenClawChatGatewayRequests.cancelQuestion(id: id))
    }

    /// Sets the session thinking level through a settings patch.
    public func setSessionThinking(sessionKey: String, thinkingLevel: String) async throws {
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: nil)
        _ = try await self.patchSessionSettings(
            sessionKey: target.sessionKey,
            agentID: target.agentID,
            patch: OpenClawChatSessionSettingsPatch(thinkingLevel: .some(thinkingLevel)))
    }

    /// Sets the session model through a settings patch.
    public func patchSessionModel(
        sessionKey: String,
        agentID: String?,
        model: String?) async throws -> OpenClawChatModelPatchResult?
    {
        try await self.patchSessionSettings(
            sessionKey: sessionKey,
            agentID: agentID,
            patch: OpenClawChatSessionSettingsPatch(model: .some(model)))
    }

    /// Creates a session without an agent override or worktree base ref.
    public func createSession(
        key: String,
        label: String?,
        parentSessionKey: String?,
        worktree: Bool?) async throws -> OpenClawChatCreateSessionResponse
    {
        try await self.createSession(
            key: key,
            label: label,
            agentID: nil,
            parentSessionKey: parentSessionKey,
            worktree: worktree,
            worktreeBaseRef: nil)
    }

    /// Rewinds a session to a message.
    public func rewindSession(
        sessionKey: String,
        entryId: String) async throws -> OpenClawChatRewindResponse
    {
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: nil)
        let request = OpenClawChatGatewayRequests.rewindSession(
            sessionKey: target.sessionKey,
            agentID: target.agentID,
            entryId: entryId)
        let data = try await self.requestChatSessionAction(request)
        return try JSONDecoder().decode(OpenClawChatRewindResponse.self, from: data)
    }

    /// Forks a session at a message.
    public func forkSessionAtMessage(
        sessionKey: String,
        entryId: String) async throws -> OpenClawChatForkAtMessageResponse
    {
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: nil)
        let request = OpenClawChatGatewayRequests.forkAtMessage(
            sessionKey: target.sessionKey,
            agentID: target.agentID,
            entryId: entryId)
        let data = try await self.requestChatSessionAction(request)
        return try JSONDecoder().decode(OpenClawChatForkAtMessageResponse.self, from: data)
    }

    /// Lists the session's transcript branches.
    public func listSessionBranches(
        sessionKey: String,
        agentID: String?) async throws -> OpenClawChatSessionBranchesResponse
    {
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: agentID)
        let request = OpenClawChatGatewayRequests.listSessionBranches(
            sessionKey: target.sessionKey,
            agentID: target.agentID)
        let data = try await self.requestChatSessionAction(request)
        return try JSONDecoder().decode(OpenClawChatSessionBranchesResponse.self, from: data)
    }

    /// Switches the session's active transcript branch.
    public func switchSessionBranch(sessionKey: String, agentID: String?, leafEntryId: String) async throws {
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: nil)
        let request = OpenClawChatGatewayRequests.switchSessionBranch(
            sessionKey: target.sessionKey,
            agentID: agentID ?? target.agentID,
            leafEntryId: leafEntryId)
        _ = try await self.requestChatSessionAction(request)
    }
}
