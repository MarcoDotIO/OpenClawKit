import Foundation
import OpenClawProtocol

// Ported from upstream OpenClaw 2026.9.6 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatTransport.swift`.
//
// Source compatibility: the pre-2026.3.0 requirements `listModels()` and `listSessions(limit:)` stay as
// deprecated requirements. The canonical `listModels(agentID:)` and `listSessions(limit:search:archived:)`
// defaults bridge to them, so existing conformers keep returning data instead of silently falling back
// to "not supported".

/// Event pushed by a chat transport.
///
/// - Note: 2026.3.0 added cases. Exhaustive `switch` statements in host code need the new cases
///   (or a `default:`).
public enum OpenClawChatTransportEvent: Sendable {
    /// Gateway health changed.
    case health(ok: Bool)
    /// Gateway tick (drives periodic health polling).
    case tick
    /// Chat metadata or configuration changed.
    case chatMetadataChanged
    /// A session row changed (`sessions.changed`).
    case sessionsChanged(OpenClawChatSessionsChangedEvent)
    /// A session observer digest arrived (`session.observer`).
    case sessionObserver(SessionObserverDigest)
    /// A chat run event (`chat`).
    case chat(OpenClawChatEventPayload)
    /// A durable transcript row (`session.message`).
    case sessionMessage(OpenClawSessionMessageEventPayload)
    /// An agent stream event (`agent`).
    case agent(OpenClawAgentEventPayload)
    /// Session-scoped tool progress for runs this client did not start (`session.tool`).
    case sessionTool(OpenClawAgentEventPayload)
    /// A durable progress card changed (`progressCard.changed`).
    case progressCardChanged(ProgressCardChangedEvent)
    /// A background task changed (`task`).
    case task(OpenClawChatTaskEvent)
    /// An `ask_user` question was requested.
    case questionRequested(QuestionRecord)
    /// An `ask_user` question was resolved.
    case questionResolved(OpenClawQuestionResolvedEvent)
    /// The transport switched to a different physical gateway route.
    case routeChanged
    /// The event stream skipped sequence numbers; state must be re-read.
    case seqGap
}

/// `task` event payload.
public enum OpenClawChatTaskEvent: Sendable, Decodable {
    /// A task was created or updated.
    case upserted(TaskSummary)
    /// A task was deleted.
    case deleted(taskID: String)
    /// Tasks were restored (re-list them).
    case restored

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(Action.self, forKey: .action)
        switch action {
        case .upserted:
            self = try .upserted(container.decode(TaskSummary.self, forKey: .task))
        case .deleted:
            self = try .deleted(taskID: container.decode(String.self, forKey: .taskID))
        case .restored:
            self = .restored
        }
    }

    private enum Action: String, Decodable {
        case upserted
        case deleted
        case restored
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case task
        case taskID = "taskId"
    }
}

/// `question.resolved` event payload.
public struct OpenClawQuestionResolvedEvent: Codable, Sendable {
    /// Question identifier.
    public let id: String
    /// Terminal status.
    public let status: QuestionStatus
    /// Gateway-normalized answers.
    public let answers: QuestionAnswers?

    /// Creates a resolved-question event.
    public init(id: String, status: QuestionStatus, answers: QuestionAnswers? = nil) {
        self.id = id
        self.status = status
        self.answers = answers
    }
}

/// `sessions.changed` event payload.
///
/// Fields fall back to the nested `session` snapshot. Presence flags distinguish an explicit `null`
/// (clear) from an absent key (leave unchanged).
public struct OpenClawChatSessionsChangedEvent: Codable, Sendable, Equatable {
    /// Session key (`sessionKey`, `key`, or nested `session.sessionKey`/`session.key`).
    public let sessionKey: String?
    /// Owning agent.
    public let agentId: String?
    /// Parent session key.
    public let parentSessionKey: String?
    /// Spawning session key.
    public let spawnedBy: String?
    /// Change reason (`patch`, `groups`, `rewind`, `branch-switch`, `create`, ...); empty when absent.
    public let reason: String
    /// Lifecycle phase (`start`, `end`, `error`).
    public let phase: String?
    /// Run identifier.
    public let runId: String?
    /// Full row snapshot, when the gateway sends one.
    public let session: OpenClawChatSessionEntry?
    /// Update timestamp.
    public let updatedAt: Double?
    /// Last-read timestamp.
    public let lastReadAt: Double?
    /// Color tag.
    public let color: String?
    /// Declared agent status.
    public let agentStatus: OpenClawChatSessionAgentStatus?
    /// Observer digest.
    public let observerDigest: OpenClawChatSessionObserverDigest?
    /// Run status.
    public let status: String?
    /// Last run error.
    public let lastRunError: String?
    /// Whether a run is active.
    public let hasActiveRun: Bool?
    /// Active run identifiers.
    public let activeRunIds: [String]?
    /// Run start timestamp.
    public let startedAt: Double?
    /// Run end timestamp.
    public let endedAt: Double?
    /// Swarm group.
    public let swarmGroupId: String?
    /// Swarm note kind (`phase`, `log`).
    public let kind: String?
    /// Swarm note text.
    public let text: String?
    /// Swarm phase of a child row.
    public let swarmPhase: String?
    package let colorPresent: Bool
    package let agentStatusPresent: Bool
    package let observerDigestPresent: Bool
    package let statusPresent: Bool
    package let lastRunErrorPresent: Bool
    package let activeRunIdsPresent: Bool

    /// Creates a sessions-changed event.
    public init(
        sessionKey: String?,
        agentId: String? = nil,
        parentSessionKey: String? = nil,
        spawnedBy: String? = nil,
        reason: String = "",
        phase: String? = nil,
        runId: String? = nil,
        session: OpenClawChatSessionEntry? = nil,
        updatedAt: Double? = nil,
        lastReadAt: Double? = nil,
        color: String? = nil,
        agentStatus: OpenClawChatSessionAgentStatus? = nil,
        observerDigest: OpenClawChatSessionObserverDigest? = nil,
        status: String? = nil,
        lastRunError: String? = nil,
        hasActiveRun: Bool? = nil,
        activeRunIds: [String]? = nil,
        startedAt: Double? = nil,
        endedAt: Double? = nil,
        swarmGroupId: String? = nil,
        kind: String? = nil,
        text: String? = nil,
        swarmPhase: String? = nil,
        colorPresent: Bool? = nil,
        agentStatusPresent: Bool? = nil,
        observerDigestPresent: Bool? = nil,
        statusPresent: Bool? = nil,
        lastRunErrorPresent: Bool? = nil,
        activeRunIdsPresent: Bool? = nil)
    {
        self.sessionKey = sessionKey
        self.agentId = agentId
        self.parentSessionKey = parentSessionKey
        self.spawnedBy = spawnedBy
        self.reason = reason
        self.phase = phase
        self.runId = runId
        self.session = session
        self.updatedAt = updatedAt
        self.lastReadAt = lastReadAt
        self.color = colorPresent == true ? color : (color ?? session?.color)
        self.colorPresent = colorPresent ?? (color != nil || session?.color != nil)
        self.agentStatus = agentStatus
        self.observerDigest = observerDigest
        self.status = status
        self.lastRunError = lastRunError
        self.hasActiveRun = hasActiveRun
        self.activeRunIds = activeRunIds ?? session?.activeRunIds
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.swarmGroupId = swarmGroupId
        self.kind = kind
        self.text = text
        self.swarmPhase = swarmPhase
        self.agentStatusPresent = agentStatusPresent ?? (agentStatus != nil)
        self.observerDigestPresent = observerDigestPresent ?? (observerDigest != nil)
        self.statusPresent = statusPresent ?? (status != nil)
        self.lastRunErrorPresent = lastRunErrorPresent ?? (lastRunError != nil)
        self.activeRunIdsPresent = activeRunIdsPresent ?? (activeRunIds != nil || session?.activeRunIds != nil)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(OpenClawChatSessionEntry.self, forKey: .session)
        let nested = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .session)

        func decode<T: Decodable>(_ type: T.Type, forKey key: CodingKeys) throws -> T? {
            if container.contains(key) {
                return try container.decodeIfPresent(type, forKey: key)
            }
            return try nested?.decodeIfPresent(type, forKey: key)
        }

        if container.contains(.sessionKey) {
            self.sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
        } else if container.contains(.key) {
            self.sessionKey = try container.decodeIfPresent(String.self, forKey: .key)
        } else if nested?.contains(.sessionKey) == true {
            self.sessionKey = try nested?.decodeIfPresent(String.self, forKey: .sessionKey)
        } else {
            self.sessionKey = try nested?.decodeIfPresent(String.self, forKey: .key)
        }
        self.agentId = try decode(String.self, forKey: .agentId)
        self.parentSessionKey = try decode(String.self, forKey: .parentSessionKey)
        self.spawnedBy = try decode(String.self, forKey: .spawnedBy)
        self.reason = try decode(String.self, forKey: .reason) ?? ""
        self.phase = try decode(String.self, forKey: .phase)
        self.runId = try decode(String.self, forKey: .runId)
        self.updatedAt = try decode(Double.self, forKey: .updatedAt)
        self.lastReadAt = try decode(Double.self, forKey: .lastReadAt)
        self.color = try decode(String.self, forKey: .color)
        self.colorPresent = container.contains(.color) || nested?.contains(.color) == true
        self.agentStatus = try decode(OpenClawChatSessionAgentStatus.self, forKey: .agentStatus)
        self.observerDigest = try decode(OpenClawChatSessionObserverDigest.self, forKey: .observerDigest)
        self.status = try decode(String.self, forKey: .status)
        self.lastRunError = try decode(String.self, forKey: .lastRunError)
        self.hasActiveRun = try decode(Bool.self, forKey: .hasActiveRun)
        self.activeRunIds = try decode([String].self, forKey: .activeRunIds)
        self.startedAt = try decode(Double.self, forKey: .startedAt)
        self.endedAt = try decode(Double.self, forKey: .endedAt)
        self.swarmGroupId = try decode(String.self, forKey: .swarmGroupId)
        self.kind = try decode(String.self, forKey: .kind)
        self.text = try decode(String.self, forKey: .text)
        self.swarmPhase = try decode(String.self, forKey: .swarmPhase)
        self.agentStatusPresent = container.contains(.agentStatus) || nested?.contains(.agentStatus) == true
        self.observerDigestPresent = container.contains(.observerDigest) || nested?.contains(.observerDigest) == true
        self.statusPresent = container.contains(.status) || nested?.contains(.status) == true
        self.lastRunErrorPresent = container.contains(.lastRunError) || nested?.contains(.lastRunError) == true
        self.activeRunIdsPresent = container.contains(.activeRunIds) || nested?.contains(.activeRunIds) == true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.sessionKey, forKey: .sessionKey)
        try container.encodeIfPresent(self.agentId, forKey: .agentId)
        try container.encodeIfPresent(self.parentSessionKey, forKey: .parentSessionKey)
        try container.encodeIfPresent(self.spawnedBy, forKey: .spawnedBy)
        try container.encodeIfPresent(self.reason, forKey: .reason)
        try container.encodeIfPresent(self.phase, forKey: .phase)
        try container.encodeIfPresent(self.runId, forKey: .runId)
        try container.encodeIfPresent(self.session, forKey: .session)
        try container.encodeIfPresent(self.updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(self.lastReadAt, forKey: .lastReadAt)
        if self.colorPresent {
            try container.encode(self.color, forKey: .color)
        }
        try container.encodeIfPresent(self.agentStatus, forKey: .agentStatus)
        try container.encodeIfPresent(self.observerDigest, forKey: .observerDigest)
        try container.encodeIfPresent(self.status, forKey: .status)
        try container.encodeIfPresent(self.lastRunError, forKey: .lastRunError)
        try container.encodeIfPresent(self.hasActiveRun, forKey: .hasActiveRun)
        if self.activeRunIdsPresent {
            if let activeRunIds {
                try container.encode(activeRunIds, forKey: .activeRunIds)
            } else {
                try container.encodeNil(forKey: .activeRunIds)
            }
        }
        try container.encodeIfPresent(self.startedAt, forKey: .startedAt)
        try container.encodeIfPresent(self.endedAt, forKey: .endedAt)
        try container.encodeIfPresent(self.swarmGroupId, forKey: .swarmGroupId)
        try container.encodeIfPresent(self.kind, forKey: .kind)
        try container.encodeIfPresent(self.text, forKey: .text)
        try container.encodeIfPresent(self.swarmPhase, forKey: .swarmPhase)
    }

    private enum CodingKeys: String, CodingKey {
        case session
        case key
        case sessionKey
        case agentId
        case parentSessionKey
        case spawnedBy
        case reason
        case phase
        case runId
        case updatedAt
        case lastReadAt
        case color
        case agentStatus
        case observerDigest
        case status
        case lastRunError
        case hasActiveRun
        case activeRunIds
        case startedAt
        case endedAt
        case swarmGroupId
        case kind
        case text
        case swarmPhase
    }
}

/// One immutable transport route used by an entire outbox flush. Route-aware
/// transports bind both sends and confirmation reads to the same connection;
/// a gateway switch then cancels the old work instead of retargeting it.
public struct OpenClawChatTransportRouteLease: Sendable {
    /// Untargeted send (session key, message, thinking, idempotency key, attachments).
    public typealias SendMessage = @Sendable (
        _ sessionKey: String,
        _ message: String,
        _ thinking: String,
        _ idempotencyKey: String,
        _ attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    /// Untargeted history read.
    public typealias RequestHistory = @Sendable (String) async throws -> OpenClawChatHistoryPayload
    /// Agent- and settings-targeted send.
    public typealias SendTargetedMessageWithSettings = @Sendable (
        _ sessionKey: String,
        _ agentID: String?,
        _ expectedSessionSettings: OpenClawChatSessionSettingsExpectation?,
        _ message: String,
        _ thinking: String,
        _ idempotencyKey: String,
        _ attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    /// Agent-targeted history read.
    public typealias RequestTargetedHistory = @Sendable (
        _ sessionKey: String,
        _ agentID: String?) async throws -> OpenClawChatHistoryPayload

    private let sendTargetedMessageImpl: SendTargetedMessageWithSettings
    private let requestTargetedHistoryImpl: RequestTargetedHistory
    /// Routing contract the lease was captured under.
    public let sessionRoutingContract: String?
    /// Whether the captured gateway supports settings compare-and-swap on `chat.send`.
    public let supportsSessionSettingsCAS: Bool

    /// Creates a lease from untargeted closures (targets are ignored).
    public init(
        sendMessage: @escaping SendMessage,
        requestHistory: @escaping RequestHistory,
        sessionRoutingContract: String? = nil,
        supportsSessionSettingsCAS: Bool = false)
    {
        self.sessionRoutingContract = sessionRoutingContract
        self.supportsSessionSettingsCAS = supportsSessionSettingsCAS
        self.sendTargetedMessageImpl = { sessionKey, _, _, message, thinking, idempotencyKey, attachments in
            try await sendMessage(sessionKey, message, thinking, idempotencyKey, attachments)
        }
        self.requestTargetedHistoryImpl = { sessionKey, _ in
            try await requestHistory(sessionKey)
        }
    }

    /// Creates a lease from targeted closures.
    public init(
        sendTargetedMessageWithSettings: @escaping SendTargetedMessageWithSettings,
        requestTargetedHistory: @escaping RequestTargetedHistory,
        sessionRoutingContract: String? = nil,
        supportsSessionSettingsCAS: Bool = false)
    {
        self.sessionRoutingContract = sessionRoutingContract
        self.supportsSessionSettingsCAS = supportsSessionSettingsCAS
        self.sendTargetedMessageImpl = sendTargetedMessageWithSettings
        self.requestTargetedHistoryImpl = requestTargetedHistory
    }

    /// Sends one message on the captured route.
    public func sendMessage(
        sessionKey: String,
        agentID: String? = nil,
        expectedSessionSettings: OpenClawChatSessionSettingsExpectation? = nil,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        try await self.sendTargetedMessageImpl(
            sessionKey,
            agentID,
            expectedSessionSettings,
            message,
            thinking,
            idempotencyKey,
            attachments)
    }

    /// Reads history on the captured route.
    public func requestHistory(
        sessionKey: String,
        agentID: String? = nil) async throws -> OpenClawChatHistoryPayload
    {
        try await self.requestTargetedHistoryImpl(sessionKey, agentID)
    }
}

/// Result of acquiring an outbox route lease.
public enum OpenClawChatTransportRouteLeaseResult: Sendable {
    /// A lease bound to the current route.
    case available(OpenClawChatTransportRouteLease)
    /// No safe lease; `allowsLiveSend` keeps the legacy live-only path open.
    case unavailable(reason: String?, allowsLiveSend: Bool = false)
}

/// One physical gateway connection captured before a settings mutation waits
/// behind earlier mutations for the same session.
public struct OpenClawChatSessionSettingsRouteLease: Sendable {
    /// Settings patch on the captured route.
    public typealias PatchSessionSettings = @Sendable (
        _ sessionKey: String,
        _ agentID: String?,
        _ patch: OpenClawChatSessionSettingsPatch) async throws -> OpenClawChatModelPatchResult?

    private let patchSessionSettingsImpl: PatchSessionSettings

    /// Creates a settings lease.
    public init(patchSessionSettings: @escaping PatchSessionSettings) {
        self.patchSessionSettingsImpl = patchSessionSettings
    }

    /// Applies a settings patch on the captured route.
    public func patchSessionSettings(
        sessionKey: String,
        agentID: String?,
        patch: OpenClawChatSessionSettingsPatch) async throws -> OpenClawChatModelPatchResult?
    {
        try await self.patchSessionSettingsImpl(sessionKey, agentID, patch)
    }
}

/// One physical gateway connection captured before a session mutation waits
/// behind an earlier mutation for the same session.
public struct OpenClawChatSessionMutationRouteLease: Sendable {
    /// Untargeted patch (label/category/color are tri-state: outer nil leaves, inner nil clears).
    public typealias PatchSession = @Sendable (
        _ key: String,
        _ expectedSessionID: String?,
        _ expectedMarkedUnreadAt: Double??,
        _ label: String??,
        _ category: String??,
        _ color: String??,
        _ pinned: Bool?,
        _ archived: Bool?,
        _ unread: Bool?) async throws -> Void
    /// Untargeted delete.
    public typealias DeleteSession = @Sendable (_ key: String) async throws -> Void
    /// Targeted patch.
    public typealias PatchTarget = @Sendable (
        _ target: OpenClawChatSessionTarget,
        _ expectedSessionID: String?,
        _ expectedMarkedUnreadAt: Double??,
        _ label: String??,
        _ category: String??,
        _ color: String??,
        _ pinned: Bool?,
        _ archived: Bool?,
        _ unread: Bool?) async throws -> Void
    /// Targeted delete.
    public typealias DeleteTarget = @Sendable (_ target: OpenClawChatSessionTarget) async throws -> Void

    private let patchSessionImpl: PatchTarget
    private let deleteSessionImpl: DeleteTarget?

    /// Creates a lease from untargeted closures; agent-targeted mutations fail as not dispatched.
    public init(
        patchSession: @escaping PatchSession,
        deleteSession: DeleteSession? = nil)
    {
        self
            .patchSessionImpl =
            { target, expectedID, expectedUnreadAt, label, category, color, pinned, archived, unread in
                guard target.agentID == nil else { throw OpenClawChatTransportSendError.notDispatched }
                try await patchSession(
                    target.sessionKey, expectedID, expectedUnreadAt, label, category, color, pinned, archived, unread)
            }
        if let deleteSession {
            self.deleteSessionImpl = { target in
                guard target.agentID == nil else { throw OpenClawChatTransportSendError.notDispatched }
                try await deleteSession(target.sessionKey)
            }
        } else {
            self.deleteSessionImpl = nil
        }
    }

    /// Creates a lease from targeted closures.
    public init(patchTarget: @escaping PatchTarget, deleteTarget: DeleteTarget?) {
        self.patchSessionImpl = patchTarget
        self.deleteSessionImpl = deleteTarget
    }

    /// The caller binds requests to its captured connection. Resolve targets at
    /// invocation time because transport copies can share mutable agent routing.
    public init(
        sessionTarget: @escaping @Sendable (String) -> OpenClawChatSessionTarget,
        unreadAckContract: Bool?,
        request: @escaping @Sendable (OpenClawChatGatewayRequest) async throws -> Data)
    {
        self.init(
            patchTarget: { requested, expectedID, expectedUnreadAt, label, category, color, pinned, archived, unread in
                guard unread != false || unreadAckContract != nil else {
                    throw OpenClawChatTransportSendError.notDispatched
                }
                let target = requested.agentID == nil ? sessionTarget(requested.sessionKey) : requested
                _ = try await request(OpenClawChatGatewayRequests.patchSession(
                    sessionKey: target.sessionKey,
                    agentID: target.agentID,
                    expectedSessionID: expectedID,
                    label: label,
                    category: category,
                    color: color,
                    pinned: pinned,
                    archived: archived,
                    unreadPatch: .routed(
                        unread: unread,
                        expectedMarkedUnreadAt: expectedUnreadAt,
                        supportsReadContract: unreadAckContract == true)))
            },
            deleteTarget: { requested in
                let target = requested.agentID == nil ? sessionTarget(requested.sessionKey) : requested
                _ = try await request(OpenClawChatGatewayRequests.deleteSession(
                    sessionKey: target.sessionKey,
                    agentID: target.agentID))
            })
    }

    /// Patches a session on the captured route.
    public func patchSession(
        key: String,
        agentID: String? = nil,
        expectedSessionID: String? = nil,
        expectedMarkedUnreadAt: Double?? = nil,
        label: String??,
        category: String??,
        color: String?? = nil,
        pinned: Bool?,
        archived: Bool?,
        unread: Bool?) async throws
    {
        try await self.patchSessionImpl(
            OpenClawChatSessionTarget(sessionKey: key, agentID: agentID),
            expectedSessionID,
            expectedMarkedUnreadAt,
            label,
            category,
            color,
            pinned,
            archived,
            unread)
    }

    /// Deletes a session on the captured route.
    public func deleteSession(key: String, agentID: String? = nil) async throws {
        guard let deleteSessionImpl else {
            throw OpenClawChatTransportSendError.notDispatched
        }
        try await deleteSessionImpl(OpenClawChatSessionTarget(sessionKey: key, agentID: agentID))
    }
}

/// One physical gateway connection captured while a group catalog is shown.
/// Group replacement submits the complete catalog, so list and mutations must
/// never retarget independently when the selected gateway changes.
public struct OpenClawChatSessionGroupsRouteLease: Sendable {
    /// Lists groups.
    public typealias ListGroups = @Sendable () async throws -> OpenClawChatSessionGroupsResponse?
    /// Replaces the group catalog.
    public typealias PutGroups = @Sendable ([String]) async throws -> OpenClawChatSessionGroupsMutationResponse
    /// Renames a group.
    public typealias RenameGroup = @Sendable (String, String) async throws -> OpenClawChatSessionGroupsMutationResponse
    /// Deletes a group.
    public typealias DeleteGroup = @Sendable (String) async throws -> OpenClawChatSessionGroupsMutationResponse

    private let listGroupsImpl: ListGroups
    private let putGroupsImpl: PutGroups
    private let renameGroupImpl: RenameGroup
    private let deleteGroupImpl: DeleteGroup

    /// Creates a groups lease.
    public init(
        listGroups: @escaping ListGroups,
        putGroups: @escaping PutGroups,
        renameGroup: @escaping RenameGroup,
        deleteGroup: @escaping DeleteGroup)
    {
        self.listGroupsImpl = listGroups
        self.putGroupsImpl = putGroups
        self.renameGroupImpl = renameGroup
        self.deleteGroupImpl = deleteGroup
    }

    /// Lists groups on the captured route.
    public func listGroups() async throws -> OpenClawChatSessionGroupsResponse? {
        try await self.listGroupsImpl()
    }

    /// Replaces the catalog on the captured route.
    public func putGroups(names: [String]) async throws -> OpenClawChatSessionGroupsMutationResponse {
        try await self.putGroupsImpl(names)
    }

    /// Renames a group on the captured route.
    public func renameGroup(name: String, to: String) async throws -> OpenClawChatSessionGroupsMutationResponse {
        try await self.renameGroupImpl(name, to)
    }

    /// Deletes a group on the captured route.
    public func deleteGroup(name: String) async throws -> OpenClawChatSessionGroupsMutationResponse {
        try await self.deleteGroupImpl(name)
    }
}

/// One physical gateway connection captured while new-session options are
/// shown. Agent capabilities and the resulting create request share the route.
public struct OpenClawChatNewSessionRouteLease: Sendable {
    /// Lists agents.
    public typealias ListAgents = @Sendable () async throws -> OpenClawChatAgentsListResponse?
    /// Creates a session (key, label, agent, parent, worktree, worktree base ref).
    public typealias CreateSession = @Sendable (
        _ key: String,
        _ label: String?,
        _ agentID: String?,
        _ parentSessionKey: String?,
        _ worktree: Bool?,
        _ worktreeBaseRef: String?) async throws -> OpenClawChatCreateSessionResponse

    private let listAgentsImpl: ListAgents
    private let createSessionImpl: CreateSession

    /// Creates a new-session lease.
    public init(
        listAgents: @escaping ListAgents,
        createSession: @escaping CreateSession)
    {
        self.listAgentsImpl = listAgents
        self.createSessionImpl = createSession
    }

    /// Lists agents on the captured route.
    public func listAgents() async throws -> OpenClawChatAgentsListResponse? {
        try await self.listAgentsImpl()
    }

    /// Creates a session on the captured route.
    public func createSession(
        key: String,
        label: String?,
        agentID: String?,
        parentSessionKey: String?,
        worktree: Bool?,
        worktreeBaseRef: String?) async throws -> OpenClawChatCreateSessionResponse
    {
        try await self.createSessionImpl(
            key,
            label,
            agentID,
            parentSessionKey,
            worktree,
            worktreeBaseRef)
    }
}

/// The transport rejected a send before it reached its request channel. This
/// is the only failure class safe for automatic outbox retry.
public enum OpenClawChatTransportSendError: Error, Sendable {
    /// The request never left the client.
    case notDispatched
}

/// Progress card fetch failures.
public enum OpenClawChatProgressCardError: LocalizedError, Sendable {
    /// The gateway cannot scope the card to the requested agent.
    case ownerScopeUnavailable

    /// Localized description.
    public var errorDescription: String? {
        OpenClawChatTransportUpgradeMessage.progressCardAgentScope
    }
}

/// User-facing gateway upgrade messages.
public enum OpenClawChatTransportUpgradeMessage {
    /// Shown when progress cards need agent-scoped `progressCard.get`.
    public static let progressCardAgentScope =
        String(localized: "Update the gateway to load progress cards for this agent.")
    /// Shown when queued sends need the session routing contract.
    public static let routingContract = String(
        localized: "Update the gateway before sending queued messages. This version requires safe delivery routing.")
}

/// Terminal state of a run observed through `agent.wait`.
public enum OpenClawChatRunTerminalState: Sendable, Equatable {
    /// The run completed.
    case completed
    /// The run failed with a user-facing message.
    case failed(message: String)
}

/// Result of one `agent.wait` observation.
public enum OpenClawChatRunObservation: Sendable, Equatable {
    /// The run reached a terminal state.
    case terminal(OpenClawChatRunTerminalState)
    /// The run is still in flight; wait again.
    case checkAgain
    /// The transport cannot observe runs.
    case unavailable

    /// Maps an `agent.wait` response.
    ///
    /// `timeout` is terminal only with lifecycle evidence (timeout phase `preflight`/`provider`/`post_turn`,
    /// a timeout stop reason, an end time, error, liveness state, yield, abort, or a started provider outside
    /// the queue); a bare wait deadline is not terminal.
    public static func fromWaitResponse(
        status: String?,
        endedAt: Double? = nil,
        error: String? = nil,
        stopReason: String? = nil,
        livenessState: String? = nil,
        yielded: Bool? = nil,
        pendingError: Bool? = nil,
        timeoutPhase: String? = nil,
        providerStarted: Bool? = nil,
        aborted: Bool? = nil) -> Self
    {
        let status = Self.normalized(status)
        if status == "pending" {
            return .checkAgain
        }
        if ["ok", "completed", "success", "succeeded"].contains(status) {
            return .terminal(.completed)
        }
        if [
            "error", "failed", "aborted", "cancelled", "canceled", "killed", "timed_out",
        ].contains(status) {
            return .terminal(.failed(message: Self.failureMessage(
                status: status,
                error: error,
                stopReason: stopReason,
                aborted: aborted)))
        }
        guard status == "timeout" else { return .unavailable }
        guard pendingError != true else { return .checkAgain }

        let timeoutPhase = Self.normalized(timeoutPhase)
        let stopReason = Self.normalized(stopReason)
        let terminalTimeout = ["preflight", "provider", "post_turn"].contains(timeoutPhase) ||
            ["timeout", "timed_out"].contains(stopReason) ||
            endedAt != nil ||
            !Self.normalized(error).isEmpty ||
            !stopReason.isEmpty ||
            !Self.normalized(livenessState).isEmpty ||
            yielded == true ||
            aborted == true ||
            (providerStarted == true && timeoutPhase != "queue" && timeoutPhase != "gateway_draining")
        return terminalTimeout
            ? .terminal(.failed(message: Self.failureMessage(
                status: status,
                error: error,
                stopReason: stopReason,
                aborted: aborted)))
            : .checkAgain
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func failureMessage(
        status: String,
        error: String?,
        stopReason: String?,
        aborted: Bool?) -> String
    {
        if let error = error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return error
        }
        let stopReason = Self.normalized(stopReason)
        if aborted == true || status == "aborted" || stopReason == "aborted" {
            return "Run aborted"
        }
        if ["cancelled", "canceled", "killed"].contains(status) ||
            ["cancelled", "canceled", "killed", "restart", "rpc", "stop", "user"].contains(stopReason)
        {
            return "Run cancelled"
        }
        if status == "timeout" || status == "timed_out" ||
            stopReason == "timeout" || stopReason == "timed_out"
        {
            return "Run timed out"
        }
        return "Chat failed"
    }
}

/// `chat.metadata` capability flags.
public struct OpenClawChatMetadataCapabilities: Codable, Sendable, Equatable {
    /// Whether Swarm is enabled (false when absent).
    public let swarmEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case swarmEnabled
    }

    /// Creates metadata capabilities.
    public init(swarmEnabled: Bool = false) {
        self.swarmEnabled = swarmEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.swarmEnabled = if container.contains(.swarmEnabled) {
            try container.decode(Bool.self, forKey: .swarmEnabled)
        } else {
            false
        }
    }
}

/// Model catalog for the model picker.
public struct OpenClawChatModelCatalogSnapshot: Sendable, Equatable {
    /// Choices.
    public let choices: [OpenClawChatModelChoice]
    /// Whether availability flags are session-scoped (session-aware `models.list`).
    public let availabilityIsSessionScoped: Bool
    /// Whether the gateway's catalog refresh failed.
    public let refreshFailed: Bool

    /// Upgrade hint when availability is not session-scoped.
    public var message: String? {
        if !self.availabilityIsSessionScoped {
            return String(
                localized: "Update your Gateway to use session model choices. Slash commands are still available.")
        }
        return nil
    }

    /// Creates a catalog snapshot.
    public init(
        choices: [OpenClawChatModelChoice],
        availabilityIsSessionScoped: Bool,
        refreshFailed: Bool = false)
    {
        self.choices = choices
        self.availabilityIsSessionScoped = availabilityIsSessionScoped
        self.refreshFailed = refreshFailed
    }
}

/// Media kind for gateway artifact loading.
public enum OpenClawChatMediaKind: String, Sendable {
    /// Image media.
    case image
    /// Audio media.
    case audio
    /// Video media.
    case video
    /// Any exported file.
    case file

    /// HTTP `Accept` header for the kind.
    public var acceptHeader: String {
        self == .file ? "*/*" : "\(rawValue)/*"
    }

    /// Whether a response MIME type matches the kind.
    public func acceptsMIMEType(_ mimeType: String) -> Bool {
        // Files are exported, never rendered. The Gateway owns document admission.
        self == .file ? !mimeType.isEmpty : mimeType.hasPrefix("\(rawValue)/")
    }

    /// Whether a managed artifact identifier matches the kind.
    public func acceptsManagedArtifactID(_ artifactID: String) -> Bool {
        let normalized = artifactID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return switch self {
        case .image:
            normalized.hasPrefix("artifact_managed_image_")
        case .audio, .video, .file:
            normalized.hasPrefix("artifact_managed_media_")
        }
    }
}

/// Media bytes loaded in memory.
public struct OpenClawChatMediaData: Sendable {
    /// Bytes.
    public let data: Data
    /// MIME type.
    public let mimeType: String

    /// Creates media data.
    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// Streamable media URL.
public struct OpenClawChatMediaStream: Sendable {
    /// Stream URL.
    public let url: URL
    /// MIME type.
    public let mimeType: String?
    /// Byte size.
    public let sizeBytes: Int?

    /// Creates a media stream.
    public init(url: URL, mimeType: String? = nil, sizeBytes: Int? = nil) {
        self.url = url
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
    }
}

/// Result of loading a media artifact.
public enum OpenClawChatLoadedMedia: Sendable {
    /// Bytes in memory.
    case data(OpenClawChatMediaData)
    /// A streamable URL.
    case stream(OpenClawChatMediaStream)
    /// The gateway is still preparing (transcoding) the media.
    case preparing
}

/// One physical Gateway route for Swarm capability discovery and child paging.
/// All pages use the captured route so a reconnect cannot combine two servers.
public struct OpenClawChatSwarmRouteLease: Sendable {
    /// Whether Swarm is enabled for a session.
    public typealias IsEnabled = @Sendable (_ sessionKey: String) async throws -> Bool
    /// Lists child sessions of a parent.
    public typealias ListChildSessions = @Sendable (_ parentKey: String) async throws -> [OpenClawChatSessionEntry]

    private let isEnabledImpl: IsEnabled
    private let listChildSessionsImpl: ListChildSessions

    /// Creates a Swarm lease.
    public init(
        isEnabled: @escaping IsEnabled,
        listChildSessions: @escaping ListChildSessions)
    {
        self.isEnabledImpl = isEnabled
        self.listChildSessionsImpl = listChildSessions
    }

    /// Checks Swarm enablement on the captured route.
    public func isEnabled(sessionKey: String) async throws -> Bool {
        try await self.isEnabledImpl(sessionKey)
    }

    /// Lists child sessions on the captured route.
    public func listChildSessions(parentKey: String) async throws -> [OpenClawChatSessionEntry] {
        try await self.listChildSessionsImpl(parentKey)
    }
}

/// Transport contract between the chat view model and a gateway (or a fixture/embedded backend).
///
/// Only `requestHistory`, the untargeted `sendMessage`, `requestHealth`, and `events()` are
/// required; every other requirement has a default that throws "not supported", returns an empty
/// or `nil` result, or wraps live calls in a route lease. Gateway-backed transports should override
/// the lease acquisition methods with route-checked implementations.
public protocol OpenClawChatTransport: Sendable {
    /// A fixed agent fallback sharing the same Gateway connection and route guards.
    func scoped(toAgentID agentID: String) -> (any OpenClawChatTransport)?
    /// Creates a session (`sessions.create`).
    func createSession(
        key: String,
        label: String?,
        parentSessionKey: String?,
        worktree: Bool?) async throws -> OpenClawChatCreateSessionResponse
    /// Creates a session with agent and worktree options (`sessions.create`).
    func createSession(
        key: String,
        label: String?,
        agentID: String?,
        parentSessionKey: String?,
        worktree: Bool?,
        worktreeBaseRef: String?) async throws -> OpenClawChatCreateSessionResponse

    /// Reads a session transcript (`chat.history`).
    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload
    /// Tri-state hello-catalog negotiation: true/false when the connected
    /// gateway's advertised method set answers, nil when no catalog is known
    /// (disconnected, pre-catalog gateway, or non-gateway transport).
    func gatewayAdvertisesMethod(_ method: String) async -> Bool?
    /// Fetches the durable progress card (`progressCard.get`).
    func fetchProgressCard(sessionKey: String, agentID: String?) async throws -> ProgressCard?
    /// Fetches the untruncated transcript row for a truncated message.
    func requestFullMessage(sessionKey: String, messageID: String) async throws -> OpenClawChatMessage?
    /// Lists model choices (`models.list`), scoped to an agent when given.
    func listModels(agentID: String?) async throws -> [OpenClawChatModelChoice]
    /// Legacy model listing.
    ///
    /// Kept so conformers written before 2026.3.0 still compile and return data: the default
    /// `listModels(agentID:)` bridges to this requirement when `agentID` is `nil`.
    @available(*, deprecated, message: "Implement listModels(agentID:) instead.")
    func listModels() async throws -> [OpenClawChatModelChoice]
    /// Captures a route-bound context for the model sign-in sheet.
    func acquireModelSignInContext(agentID: String?) async -> OpenClawChatModelSignInContext?
    /// Loads the session-aware model catalog.
    func loadModelCatalog(
        sessionKey: String,
        agentID: String?) async throws -> OpenClawChatModelCatalogSnapshot
    /// Whether the transport can load composer capabilities.
    var supportsComposerCapabilities: Bool { get }
    /// Loads the composer capability catalog.
    func loadComposerCapabilityCatalog(
        sessionKey: String,
        agentID: String?) async -> OpenClawChatComposerCapabilityCatalog
    /// Whether Swarm is enabled for a session.
    func isSwarmEnabled(sessionKey: String) async throws -> Bool
    /// Whether the transport can list slash commands.
    var supportsSlashCommandCatalog: Bool { get }
    /// Lists slash commands (`commands.list`).
    func listCommands(sessionKey: String) async throws -> [OpenClawChatCommandChoice]
    /// Sends a message (`chat.send`).
    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    /// Sends a message targeted at an agent and routing contract.
    func sendMessage(
        sessionKey: String,
        agentID: String?,
        expectedSessionRoutingContract: String?,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    /// Sends a message with a full routing/settings target.
    func sendMessage(
        sessionKey: String,
        target: OpenClawChatSendTarget,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse

    /// Captures the current route for a durable outbox flush. Implementations
    /// backed by a mutable gateway must override this with route-checked calls.
    func acquireOutboxRouteLease() async -> OpenClawChatTransportRouteLeaseResult
    /// Whether durable outbox commands must carry a session routing contract.
    var outboxRequiresSessionRoutingContract: Bool { get }

    /// Aborts a run (`chat.abort`).
    func abortRun(sessionKey: String, runId: String) async throws
    /// Legacy session listing.
    ///
    /// Kept so conformers written before 2026.3.0 still compile and return data: the default
    /// `listSessions(limit:search:archived:)` bridges to this requirement when there is no search and
    /// archived rows are not requested.
    @available(*, deprecated, message: "Implement listSessions(limit:search:archived:) instead.")
    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse
    /// Lists sessions (`sessions.list`).
    func listSessions(
        limit: Int?,
        search: String?,
        archived: Bool) async throws -> OpenClawChatSessionsListResponse
    /// Lists sessions scoped to an agent (`sessions.list`).
    func listSessions(
        limit: Int?,
        search: String?,
        archived: Bool,
        agentID: String?) async throws -> OpenClawChatSessionsListResponse
    /// Lists child sessions of a parent.
    func listChildSessions(parentKey: String) async throws -> [OpenClawChatSessionEntry]
    /// Captures a Swarm route lease.
    func acquireSwarmRouteLease() async -> OpenClawChatSwarmRouteLease?
    /// Lists agents (`agents.list`).
    func listAgents() async throws -> OpenClawChatAgentsListResponse?
    /// Captures a new-session route lease.
    func acquireNewSessionRouteLease() async -> OpenClawChatNewSessionRouteLease?
    /// Lists session groups (`sessions.groups.list`).
    func listSessionGroups() async throws -> OpenClawChatSessionGroupsResponse?
    /// Replaces the session group catalog (`sessions.groups.put`).
    func putSessionGroups(names: [String]) async throws -> OpenClawChatSessionGroupsMutationResponse
    /// Renames a session group (`sessions.groups.rename`).
    func renameSessionGroup(name: String, to: String) async throws -> OpenClawChatSessionGroupsMutationResponse
    /// Deletes a session group (`sessions.groups.delete`).
    func deleteSessionGroup(name: String) async throws -> OpenClawChatSessionGroupsMutationResponse
    /// Captures a session-groups route lease.
    func acquireSessionGroupsRouteLease() async -> OpenClawChatSessionGroupsRouteLease?
    // Keep optional patch fields aligned with the writer; protocol requirements cannot declare their defaults.
    // swiftlint:disable:next function_parameter_count
    /// Patches session metadata (`sessions.patch`). Tri-state fields: outer nil leaves, inner nil clears.
    func patchSession(
        key: String,
        expectedSessionID: String?,
        label: String??,
        category: String??,
        color: String??,
        pinned: Bool?,
        archived: Bool?,
        unread: Bool?) async throws
    /// Captures a session-mutation route lease.
    func acquireSessionMutationRouteLease() async -> OpenClawChatSessionMutationRouteLease?
    /// Deletes a session (`sessions.delete`).
    func deleteSession(key: String) async throws
    /// Forks a session (`sessions.create` with `fork`).
    func forkSession(parentKey: String) async throws -> String
    /// Forks a session from its last completed turn.
    func forkSession(parentKey: String, fromLastCompleted: Bool) async throws -> String
    /// Forks an agent-owned session.
    func forkSession(parentKey: String, fromLastCompleted: Bool, agentID: String?) async throws -> String
    /// Rewinds a session to a transcript entry (`sessions.rewind`).
    func rewindSession(sessionKey: String, entryId: String) async throws -> OpenClawChatRewindResponse
    /// Forks a session at a transcript entry (`sessions.fork`).
    func forkSessionAtMessage(
        sessionKey: String,
        entryId: String) async throws -> OpenClawChatForkAtMessageResponse
    /// Lists transcript branches (`sessions.branches.list`).
    func listSessionBranches(
        sessionKey: String,
        agentID: String?) async throws -> OpenClawChatSessionBranchesResponse
    /// Switches the active branch (`sessions.branches.switch`).
    func switchSessionBranch(sessionKey: String, agentID: String?, leafEntryId: String) async throws
    /// Legacy model patch.
    func setSessionModel(sessionKey: String, model: String?) async throws
    /// Patches the session model and returns the authoritative result.
    func patchSessionModel(
        sessionKey: String,
        agentID: String?,
        model: String?) async throws -> OpenClawChatModelPatchResult?
    /// Legacy thinking patch.
    func setSessionThinking(sessionKey: String, thinkingLevel: String) async throws
    /// Applies a settings patch (`sessions.patch`).
    func patchSessionSettings(
        sessionKey: String,
        agentID: String?,
        patch: OpenClawChatSessionSettingsPatch) async throws -> OpenClawChatModelPatchResult?
    /// Mutable gateway transports must capture the physical connection here;
    /// queued settings work must never resolve its route after waiting.
    func acquireSessionSettingsRouteLease() async -> OpenClawChatSessionSettingsRouteLease?

    /// Checks gateway health (`health`).
    func requestHealth(timeoutMs: Int) async throws -> Bool
    /// Lists pending questions (`question.list`).
    func listQuestions() async throws -> [QuestionRecord]
    /// Lists tasks for a session (`tasks.list`).
    func listTasks(sessionKey: String, agentID: String?) async throws -> [TaskSummary]
    /// Fetches one question (`question.get`).
    func getQuestion(id: String) async throws -> QuestionRecord
    /// Answers a question (`question.resolve`).
    func resolveQuestion(
        id: String,
        answers: [String: [String]],
        secretStoreAllowedHosts: [String]?) async throws -> QuestionAnswers
    /// Cancels a question (`question.resolve` with `cancel`).
    func cancelQuestion(id: String) async throws
    /// Waits for a run to finish (`agent.wait`).
    func waitForRunCompletion(runId: String, timeoutMs: Int) async -> OpenClawChatRunObservation
    /// Push event stream.
    func events() -> AsyncStream<OpenClawChatTransportEvent>
    /// Resolves an inline widget resource, replacing a failed one.
    func resolveInlineWidgetResource(
        path: String,
        replacing failedResource: OpenClawChatWidgetResource?) async -> OpenClawChatWidgetResource?
    /// Resolves an inline widget URL (legacy URL-only transports).
    func resolveInlineWidgetURL(path: String, replacing failedURL: URL?) async -> URL?
    /// Loads a media artifact (`artifacts.download`).
    func loadMediaArtifact(
        sessionKey: String,
        artifactId: String,
        kind: OpenClawChatMediaKind,
        playback: OpenClawChatPlaybackMode?) async throws -> OpenClawChatLoadedMedia?

    /// Loads the source-preview context for the connected gateway.
    func loadSourceContext() async -> OpenClawChatSourceContext?
    /// Loads a favicon through the gateway proxy.
    func loadSourceFavicon(host: String) async -> Data?

    /// Subscribes push events to a session.
    func setActiveSessionKey(_ sessionKey: String) async throws
    /// Resets a session (`sessions.reset`).
    func resetSession(sessionKey: String) async throws
    /// Compacts a session (`sessions.compact`).
    func compactSession(sessionKey: String) async throws
}

extension OpenClawChatTransport {
    private static func unsupported(_ operation: String) -> NSError {
        NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "\(operation) not supported by this transport"])
    }

    /// Default: no source context.
    public func loadSourceContext() async -> OpenClawChatSourceContext? {
        nil
    }

    /// Default: no favicons.
    public func loadSourceFavicon(host _: String) async -> Data? {
        nil
    }

    /// Default: no agent-scoped copies.
    public func scoped(toAgentID _: String) -> (any OpenClawChatTransport)? {
        nil
    }

    /// Default: composer capabilities unsupported.
    public var supportsComposerCapabilities: Bool {
        false
    }

    /// Default: empty catalog.
    public func loadComposerCapabilityCatalog(
        sessionKey _: String,
        agentID _: String?) async -> OpenClawChatComposerCapabilityCatalog
    {
        OpenClawChatComposerCapabilityCatalog()
    }

    /// Default: no method catalog known.
    public func gatewayAdvertisesMethod(_: String) async -> Bool? {
        nil
    }

    /// Default: no progress card.
    public func fetchProgressCard(sessionKey _: String, agentID _: String?) async throws -> ProgressCard? {
        nil
    }

    /// Default: media loading unsupported.
    public func loadMediaArtifact(
        sessionKey _: String,
        artifactId _: String,
        kind _: OpenClawChatMediaKind,
        playback _: OpenClawChatPlaybackMode?) async throws -> OpenClawChatLoadedMedia?
    {
        nil
    }

    /// Default: Swarm disabled.
    public func isSwarmEnabled(sessionKey _: String) async throws -> Bool {
        false
    }

    /// Default: a live-call Swarm lease.
    public func acquireSwarmRouteLease() async -> OpenClawChatSwarmRouteLease? {
        let transport = self
        return OpenClawChatSwarmRouteLease(
            isEnabled: { try await transport.isSwarmEnabled(sessionKey: $0) },
            listChildSessions: { try await transport.listChildSessions(parentKey: $0) })
    }

    /// Default: no questions.
    public func listQuestions() async throws -> [QuestionRecord] {
        []
    }

    /// Default: no tasks.
    public func listTasks(sessionKey _: String, agentID _: String?) async throws -> [TaskSummary] {
        []
    }

    /// Default: throws "not supported".
    public func getQuestion(id _: String) async throws -> QuestionRecord {
        throw Self.unsupported("question.get")
    }

    /// Default: throws "not supported".
    public func resolveQuestion(
        id _: String,
        answers _: [String: [String]],
        secretStoreAllowedHosts _: [String]?) async throws -> QuestionAnswers
    {
        throw Self.unsupported("question.resolve")
    }

    /// Default: throws "not supported".
    public func cancelQuestion(id _: String) async throws {
        throw Self.unsupported("question.resolve cancellation")
    }

    /// Default: no full message.
    public func requestFullMessage(sessionKey _: String, messageID _: String) async throws -> OpenClawChatMessage? {
        nil
    }

    /// Default: wraps ``resolveInlineWidgetURL(path:replacing:)``.
    public func resolveInlineWidgetResource(
        path: String,
        replacing failedResource: OpenClawChatWidgetResource?) async -> OpenClawChatWidgetResource?
    {
        guard let url = await resolveInlineWidgetURL(path: path, replacing: failedResource?.url) else { return nil }
        return OpenClawChatWidgetResource(url: url)
    }

    /// Default: no widget URL.
    public func resolveInlineWidgetURL(path _: String, replacing _: URL?) async -> URL? {
        nil
    }

    /// Default: no routing contract required.
    public var outboxRequiresSessionRoutingContract: Bool {
        false
    }

    /// Default: a live-call outbox lease.
    public func acquireOutboxRouteLease() async -> OpenClawChatTransportRouteLeaseResult {
        let transport = self
        return .available(OpenClawChatTransportRouteLease(
            sendMessage: { sessionKey, message, thinking, idempotencyKey, attachments in
                try await transport.sendMessage(
                    sessionKey: sessionKey,
                    message: message,
                    thinking: thinking,
                    idempotencyKey: idempotencyKey,
                    attachments: attachments)
            },
            requestHistory: { sessionKey in
                try await transport.requestHistory(sessionKey: sessionKey)
            }))
    }

    /// Default: a live-call settings lease.
    public func acquireSessionSettingsRouteLease() async -> OpenClawChatSessionSettingsRouteLease? {
        let transport = self
        return OpenClawChatSessionSettingsRouteLease { sessionKey, agentID, patch in
            try await transport.patchSessionSettings(
                sessionKey: sessionKey,
                agentID: agentID,
                patch: patch)
        }
    }

    /// Default: a live-call session-mutation lease.
    public func acquireSessionMutationRouteLease() async -> OpenClawChatSessionMutationRouteLease? {
        let transport = self
        return OpenClawChatSessionMutationRouteLease(
            patchSession: { key, expectedSessionID, _, label, category, color, pinned, archived, unread in
                try await transport.patchSession(
                    key: key,
                    expectedSessionID: expectedSessionID,
                    label: label,
                    category: category,
                    color: color,
                    pinned: pinned,
                    archived: archived,
                    unread: unread)
            },
            deleteSession: { key in
                try await transport.deleteSession(key: key)
            })
    }

    /// Default: a live-call session-groups lease.
    public func acquireSessionGroupsRouteLease() async -> OpenClawChatSessionGroupsRouteLease? {
        let transport = self
        return OpenClawChatSessionGroupsRouteLease(
            listGroups: { try await transport.listSessionGroups() },
            putGroups: { try await transport.putSessionGroups(names: $0) },
            renameGroup: { try await transport.renameSessionGroup(name: $0, to: $1) },
            deleteGroup: { try await transport.deleteSessionGroup(name: $0) })
    }

    /// Default: a live-call new-session lease.
    public func acquireNewSessionRouteLease() async -> OpenClawChatNewSessionRouteLease? {
        let transport = self
        return OpenClawChatNewSessionRouteLease(
            listAgents: { try await transport.listAgents() },
            createSession: { key, label, agentID, parentSessionKey, worktree, worktreeBaseRef in
                try await transport.createSession(
                    key: key,
                    label: label,
                    agentID: agentID,
                    parentSessionKey: parentSessionKey,
                    worktree: worktree,
                    worktreeBaseRef: worktreeBaseRef)
            })
    }

    /// Default: ignores the target and sends untargeted.
    public func sendMessage(
        sessionKey: String,
        agentID _: String?,
        expectedSessionRoutingContract _: String?,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        try await self.sendMessage(
            sessionKey: sessionKey,
            message: message,
            thinking: thinking,
            idempotencyKey: idempotencyKey,
            attachments: attachments)
    }

    /// Default: forwards agent and routing contract.
    public func sendMessage(
        sessionKey: String,
        target: OpenClawChatSendTarget,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        try await self.sendMessage(
            sessionKey: sessionKey,
            agentID: target.agentID,
            expectedSessionRoutingContract: target.expectedSessionRoutingContract,
            message: message,
            thinking: thinking,
            idempotencyKey: idempotencyKey,
            attachments: attachments)
    }

    /// Default: throws "not supported".
    public func createSession(
        key _: String,
        label _: String?,
        parentSessionKey _: String?,
        worktree _: Bool?) async throws -> OpenClawChatCreateSessionResponse
    {
        throw Self.unsupported("sessions.create")
    }

    /// Default: forwards plain requests; fails closed for agent or base-ref options.
    public func createSession(
        key: String,
        label: String?,
        agentID: String?,
        parentSessionKey: String?,
        worktree: Bool?,
        worktreeBaseRef: String?) async throws -> OpenClawChatCreateSessionResponse
    {
        // Fail closed: a transport on this default cannot honor agent/base-ref
        // selection; delegating would report success while creating the wrong session.
        guard agentID == nil, worktreeBaseRef == nil else {
            throw Self.unsupported("sessions.create agent/base-ref options")
        }
        return try await self.createSession(
            key: key,
            label: label,
            parentSessionKey: parentSessionKey,
            worktree: worktree)
    }

    /// Default: no subscription.
    public func setActiveSessionKey(_: String) async throws {}

    /// Default: run observation unavailable.
    public func waitForRunCompletion(runId _: String, timeoutMs _: Int) async -> OpenClawChatRunObservation {
        .unavailable
    }

    /// Default: throws "not supported".
    public func resetSession(sessionKey _: String) async throws {
        throw Self.unsupported("sessions.reset")
    }

    /// Default: throws "not supported".
    public func compactSession(sessionKey _: String) async throws {
        throw Self.unsupported("sessions.compact")
    }

    /// Default: throws "not supported".
    public func abortRun(sessionKey _: String, runId _: String) async throws {
        throw Self.unsupported("chat.abort")
    }

    /// Default for the legacy requirement: throws "not supported".
    @available(*, deprecated, message: "Implement listSessions(limit:search:archived:) instead.")
    public func listSessions(limit _: Int?) async throws -> OpenClawChatSessionsListResponse {
        throw Self.unsupported("sessions.list")
    }

    /// Default: no child sessions.
    public func listChildSessions(parentKey _: String) async throws -> [OpenClawChatSessionEntry] {
        []
    }

    /// Existing custom transports retain their own roster scope until they adopt explicit agent routing.
    public func listSessions(
        limit: Int?,
        search: String?,
        archived: Bool,
        agentID _: String?) async throws -> OpenClawChatSessionsListResponse
    {
        try await self.listSessions(limit: limit, search: search, archived: archived)
    }

    /// Convenience for callers that only select archive state. Transports must
    /// implement the canonical `listSessions(limit:search:archived:)`
    /// requirement; same-name methods on a conformer are shadowed by this
    /// sugar and never called through the protocol.
    public func listSessions(limit: Int?, archived: Bool) async throws -> OpenClawChatSessionsListResponse {
        try await self.listSessions(limit: limit, search: nil, archived: archived)
    }

    /// Default: no agents.
    public func listAgents() async throws -> OpenClawChatAgentsListResponse? {
        nil
    }

    /// Default: no groups.
    public func listSessionGroups() async throws -> OpenClawChatSessionGroupsResponse? {
        nil
    }

    /// Default: throws "not supported".
    public func putSessionGroups(names _: [String]) async throws -> OpenClawChatSessionGroupsMutationResponse {
        throw Self.unsupported("sessions.groups.put")
    }

    /// Default: throws "not supported".
    public func renameSessionGroup(
        name _: String,
        to _: String) async throws -> OpenClawChatSessionGroupsMutationResponse
    {
        throw Self.unsupported("sessions.groups.rename")
    }

    /// Default: throws "not supported".
    public func deleteSessionGroup(name _: String) async throws -> OpenClawChatSessionGroupsMutationResponse {
        throw Self.unsupported("sessions.groups.delete")
    }

    // No parameter defaults: a call that omits a patch field must fail to compile instead of
    // silently binding here (past the conforming witness) when the requirement gains a field.
    // swiftlint:disable:next function_parameter_count
    /// Default: throws "not supported".
    public func patchSession(
        key _: String,
        expectedSessionID _: String?,
        label _: String??,
        category _: String??,
        color _: String??,
        pinned _: Bool?,
        archived _: Bool?,
        unread _: Bool?) async throws
    {
        throw Self.unsupported("sessions.patch")
    }

    /// Default: throws "not supported".
    public func deleteSession(key _: String) async throws {
        throw Self.unsupported("sessions.delete")
    }

    /// Default: throws "not supported".
    public func forkSession(parentKey _: String) async throws -> String {
        throw Self.unsupported("sessions.create fork")
    }

    /// Default: ignores `fromLastCompleted`.
    public func forkSession(parentKey: String, fromLastCompleted _: Bool) async throws -> String {
        try await self.forkSession(parentKey: parentKey)
    }

    /// Default: fails as not dispatched for agent-owned forks.
    public func forkSession(parentKey: String, fromLastCompleted: Bool, agentID: String?) async throws -> String {
        guard agentID == nil else { throw OpenClawChatTransportSendError.notDispatched }
        return try await self.forkSession(parentKey: parentKey, fromLastCompleted: fromLastCompleted)
    }

    /// Default: throws "not supported".
    public func rewindSession(
        sessionKey _: String,
        entryId _: String) async throws -> OpenClawChatRewindResponse
    {
        throw Self.unsupported("sessions.rewind")
    }

    /// Default: throws "not supported".
    public func forkSessionAtMessage(
        sessionKey _: String,
        entryId _: String) async throws -> OpenClawChatForkAtMessageResponse
    {
        throw Self.unsupported("sessions.fork")
    }

    /// Default: throws "not supported".
    public func listSessionBranches(
        sessionKey _: String,
        agentID _: String?) async throws -> OpenClawChatSessionBranchesResponse
    {
        throw Self.unsupported("sessions.branches.list")
    }

    /// Default: throws "not supported".
    public func switchSessionBranch(sessionKey _: String, agentID _: String?, leafEntryId _: String) async throws {
        throw Self.unsupported("sessions.branches.switch")
    }

    /// Default for the legacy requirement: throws "not supported".
    @available(*, deprecated, message: "Implement listModels(agentID:) instead.")
    public func listModels() async throws -> [OpenClawChatModelChoice] {
        throw Self.unsupported("models.list")
    }

    /// Default: no sign-in context.
    public func acquireModelSignInContext(agentID _: String?) async -> OpenClawChatModelSignInContext? {
        nil
    }

    /// Default: wraps `listModels(agentID:)` without session-scoped availability.
    public func loadModelCatalog(
        sessionKey _: String,
        agentID: String?) async throws -> OpenClawChatModelCatalogSnapshot
    {
        let choices = try await self.listModels(agentID: agentID)
        return OpenClawChatModelCatalogSnapshot(
            choices: choices,
            availabilityIsSessionScoped: false)
    }

    /// Default: slash-command catalog unsupported.
    public var supportsSlashCommandCatalog: Bool {
        false
    }

    /// Default: no commands.
    public func listCommands(sessionKey _: String) async throws -> [OpenClawChatCommandChoice] {
        []
    }

    /// Default: throws "not supported".
    public func setSessionModel(sessionKey _: String, model _: String?) async throws {
        throw Self.unsupported("sessions.patch(model)")
    }

    /// Default: wraps `setSessionModel(sessionKey:model:)`.
    public func patchSessionModel(
        sessionKey: String,
        agentID _: String?,
        model: String?) async throws -> OpenClawChatModelPatchResult?
    {
        try await self.setSessionModel(sessionKey: sessionKey, model: model)
        return nil
    }

    /// Default: throws "not supported".
    public func setSessionThinking(sessionKey _: String, thinkingLevel _: String) async throws {
        throw Self.unsupported("sessions.patch(thinkingLevel)")
    }

    /// Default: applies model and thinking through the legacy patch requirements.
    public func patchSessionSettings(
        sessionKey: String,
        agentID: String?,
        patch: OpenClawChatSessionSettingsPatch) async throws -> OpenClawChatModelPatchResult?
    {
        var result: OpenClawChatModelPatchResult?
        if let model = patch.model {
            result = try await self.patchSessionModel(
                sessionKey: sessionKey,
                agentID: agentID,
                model: model)
        }
        if let thinkingLevelUpdate = patch.thinkingLevel {
            guard let thinkingLevel = thinkingLevelUpdate else {
                throw Self.unsupported("sessions.patch(thinkingLevel=null)")
            }
            try await self.setSessionThinking(
                sessionKey: sessionKey,
                thinkingLevel: thinkingLevel)
            result = OpenClawChatModelPatchResult(
                key: result?.key ?? sessionKey,
                modelProvider: result?.modelProvider,
                model: result?.model,
                thinkingLevel: thinkingLevel,
                thinkingLevels: result?.thinkingLevels)
        }
        return result
    }
}

// The canonical listing requirements default to the legacy requirements so conformers written before
// 2026.3.0 keep returning data. The extension is deprecated only to express that bridge: calls made
// through `any OpenClawChatTransport` (as the view model does) never warn; a direct call on a concrete
// legacy conformer warns that the transport should implement the canonical requirement itself.
@available(*, deprecated, message: "Implement listModels(agentID:) and listSessions(limit:search:archived:) directly.")
extension OpenClawChatTransport {
    /// Default: bridges to the legacy `listModels()` for unscoped requests; scoped requests are unsupported.
    public func listModels(agentID: String?) async throws -> [OpenClawChatModelChoice] {
        guard agentID == nil else { throw Self.unsupported("models.list") }
        return try await self.listModels()
    }

    /// Default: bridges to the legacy `listSessions(limit:)` for unfiltered, non-archived requests.
    public func listSessions(
        limit: Int?,
        search: String?,
        archived: Bool) async throws -> OpenClawChatSessionsListResponse
    {
        let normalizedSearch = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSearch?.isEmpty != false, !archived else {
            throw Self.unsupported("sessions.list")
        }
        return try await self.listSessions(limit: limit)
    }
}

/// Gateway session routing contract (`scope|mainKey|defaultAgentId`).
public enum OpenClawChatSessionRoutingContract {
    /// `chat.send` error reason when the contract changed.
    public static let changedErrorReason = "session-routing-changed"

    /// Parsed contract components.
    public struct Components: Equatable, Sendable {
        /// Session scope (`agent`, `global`, ...).
        public let scope: String
        /// Main session key.
        public let mainKey: String
        /// Default agent.
        public let defaultAgentID: String
    }

    /// Live sends may proceed before routing identity is available. Queued
    /// replay acquires a separate route lease and never uses a nil contract.
    public static func expectedValue(
        _ contract: String?,
        serverSupportsGuard: Bool) -> String?
    {
        guard serverSupportsGuard else { return nil }
        return self.normalize(contract)
    }

    /// Builds a lowercased `scope|mainKey|defaultAgentId` contract.
    public static func make(
        scope: String?,
        mainKey: String?,
        defaultAgentID: String?) -> String?
    {
        let normalizedScope = self.normalize(scope)
        let normalizedMainKey = self.normalize(mainKey)
        let normalizedDefaultAgentID = self.normalize(defaultAgentID)
        guard let normalizedScope, let normalizedMainKey, let normalizedDefaultAgentID else { return nil }
        return "\(normalizedScope)|\(normalizedMainKey)|\(normalizedDefaultAgentID)"
    }

    /// Scope and agent ids cannot contain `|`; parse from both ends so an
    /// older custom main key containing the delimiter still round-trips.
    public static func parse(_ contract: String?) -> Components? {
        guard let normalized = normalize(contract),
              let firstSeparator = normalized.firstIndex(of: "|"),
              let lastSeparator = normalized.lastIndex(of: "|"),
              firstSeparator != lastSeparator
        else { return nil }
        let scope = String(normalized[..<firstSeparator])
        let mainKey = String(normalized[normalized.index(after: firstSeparator)..<lastSeparator])
        let defaultAgentID = String(normalized[normalized.index(after: lastSeparator)...])
        guard !scope.isEmpty, !mainKey.isEmpty, !defaultAgentID.isEmpty else { return nil }
        return Components(scope: scope, mainKey: mainKey, defaultAgentID: defaultAgentID)
    }

    private static func normalize(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }
}

/// Settings compare-and-swap contract.
package enum OpenClawChatSessionSettingsContract {
    /// `chat.send` error reason when the settings fence failed.
    package static let changedErrorReason = "session-settings-changed"
}
