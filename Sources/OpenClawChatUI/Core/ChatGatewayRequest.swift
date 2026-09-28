import Foundation
import OpenClawProtocol

// Ported from upstream OpenClaw 2026.9.6 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatGatewayRequest.swift`.
// The `GatewayNodeSession.request(_:)` adapter lives in `ChatGatewayNodeSessionRequest.swift` so this file
// only depends on Foundation and OpenClawProtocol.

/// A pure gateway RPC description: method, params, and client-side timeout.
public struct OpenClawChatGatewayRequest: Sendable, Equatable {
    /// Gateway method.
    public let method: String
    /// Request params.
    public let params: [String: AnyCodable]
    /// Client timeout in milliseconds (`0` disables the client timeout, e.g. compaction).
    public let timeoutMs: Double

    /// Creates a request.
    public init(method: String, params: [String: AnyCodable] = [:], timeoutMs: Double) {
        self.method = method
        self.params = params
        self.timeoutMs = timeoutMs
    }
}

/// How `sessions.patch` encodes an unread change.
public enum OpenClawChatSessionUnreadPatch: Sendable, Equatable {
    /// Mark unread.
    case markUnread
    /// Mark read unconditionally.
    case read
    /// Mark read only if the row was not re-marked unread since `expectedMarkedUnreadAt`.
    case automaticRead(expectedMarkedUnreadAt: Double?)

    /// Chooses the patch for an unread value, honoring the gateway's read-acknowledgement contract.
    public static func routed(
        unread: Bool?,
        expectedMarkedUnreadAt: Double??,
        supportsReadContract: Bool) -> Self?
    {
        guard let unread else { return nil }
        guard !unread else { return .markUnread }
        guard supportsReadContract else { return .read }
        if let expectedMarkedUnreadAt {
            return .automaticRead(expectedMarkedUnreadAt: expectedMarkedUnreadAt)
        }
        return .read
    }
}

/// How bare session keys are resolved against the selected agent.
public enum OpenClawChatSessionTargetPolicy: Sendable {
    /// Keep bare keys; pass the override agent separately.
    case preserveBareKeys
    /// Rewrite bare keys to `agent:<id>:<key>`.
    case scopeBareKeysToSelectedAgent
}

/// A session key plus the explicit agent the gateway should route it to.
public struct OpenClawChatSessionTarget: Sendable, Equatable {
    /// Session key.
    public let sessionKey: String
    /// Explicit agent (only for keys whose owner the key itself does not encode).
    public let agentID: String?

    /// Creates a session target.
    public init(sessionKey: String, agentID: String?) {
        self.sessionKey = sessionKey
        self.agentID = agentID
    }

    /// Resolves a raw key.
    ///
    /// Agent-qualified keys keep only the override agent; `agent:`-prefixed or `unknown` keys get no agent;
    /// `global` uses the override or selected agent; bare keys follow `policy`.
    public static func resolve(
        _ rawSessionKey: String,
        selectedAgentID: String?,
        overrideAgentID: String? = nil,
        policy: OpenClawChatSessionTargetPolicy) -> Self
    {
        let sessionKey = rawSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = self.normalizedAgentID(selectedAgentID)
        let override = self.normalizedAgentID(overrideAgentID)

        if OpenClawChatSessionKey.agentID(from: sessionKey) != nil {
            return Self(sessionKey: sessionKey, agentID: override)
        }
        let lowercasedKey = sessionKey.lowercased()
        if lowercasedKey.hasPrefix("agent:") || lowercasedKey == "unknown" {
            return Self(sessionKey: sessionKey, agentID: nil)
        }
        if lowercasedKey == "global" {
            return Self(sessionKey: sessionKey, agentID: override ?? selected)
        }

        switch policy {
        case .preserveBareKeys:
            return Self(sessionKey: sessionKey, agentID: override)
        case .scopeBareKeysToSelectedAgent:
            guard let agentID = override ?? selected else {
                return Self(sessionKey: sessionKey, agentID: nil)
            }
            return Self(sessionKey: "agent:\(agentID):\(sessionKey)", agentID: nil)
        }
    }

    private static func normalizedAgentID(_ agentID: String?) -> String? {
        let normalized = agentID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }
}

/// Typed builders for every gateway method the chat surface calls.
public enum OpenClawChatGatewayRequests {
    private static let defaultTimeoutMs: Double = 15000
    private static let mutationTimeoutMs: Double = 15000
    private static let archiveMutationTimeoutMs: Double = 10 * 60 * 1000
    private static let shortTimeoutMs: Double = 10000
    private static let compactionTimeoutMs: Double = 0

    /// `agents.list`.
    public static func agentsList(timeoutMs: Double = 15000) -> OpenClawChatGatewayRequest {
        OpenClawChatGatewayRequest(method: "agents.list", timeoutMs: timeoutMs)
    }

    /// `models.list`; session-scoped requests ask for the configured view with details.
    public static func modelsList(agentID: String?, sessionKey: String? = nil) -> OpenClawChatGatewayRequest {
        var params: [String: AnyCodable] = [:]
        self.add(agentID, to: &params, key: "agentId")
        self.add(sessionKey, to: &params, key: "sessionKey")
        if sessionKey != nil {
            params["view"] = AnyCodable("configured")
            params["includeDetails"] = AnyCodable(true)
        }
        return OpenClawChatGatewayRequest(
            method: "models.list",
            params: params,
            timeoutMs: self.defaultTimeoutMs)
    }

    /// `skills.status` for the composer capability catalog.
    public static func composerSkillsStatus(agentID: String?) -> OpenClawChatGatewayRequest {
        var params: [String: AnyCodable] = [:]
        self.add(agentID, to: &params, key: "agentId")
        return OpenClawChatGatewayRequest(
            method: "skills.status",
            params: params,
            timeoutMs: self.defaultTimeoutMs)
    }

    /// `config.get` for the composer capability catalog.
    public static func composerConfigGet() -> OpenClawChatGatewayRequest {
        OpenClawChatGatewayRequest(method: "config.get", timeoutMs: self.defaultTimeoutMs)
    }

    /// `tools.effective` for the composer capability catalog.
    public static func composerToolsEffective(
        sessionKey: String,
        agentID: String?) -> OpenClawChatGatewayRequest
    {
        var params: [String: AnyCodable] = ["sessionKey": AnyCodable(sessionKey)]
        self.add(agentID, to: &params, key: "agentId")
        return OpenClawChatGatewayRequest(
            method: "tools.effective",
            params: params,
            timeoutMs: self.defaultTimeoutMs)
    }

    /// `artifacts.download`.
    public static func artifactDownload(
        sessionKey: String,
        agentID: String?,
        artifactId: String) -> OpenClawChatGatewayRequest
    {
        var params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(sessionKey),
            "artifactId": AnyCodable(artifactId),
        ]
        self.add(agentID, to: &params, key: "agentId")
        return OpenClawChatGatewayRequest(
            method: "artifacts.download",
            params: params,
            timeoutMs: self.defaultTimeoutMs)
    }

    /// `chat.metadata`; the key's own agent wins over the fallback.
    public static func chatMetadata(
        sessionKey: String,
        fallbackAgentID: String?,
        includeSessionKey: Bool = false) -> OpenClawChatGatewayRequest
    {
        var params: [String: AnyCodable] = [:]
        self.add(
            OpenClawChatSessionKey.agentID(from: sessionKey) ?? fallbackAgentID,
            to: &params,
            key: "agentId")
        if includeSessionKey {
            self.add(sessionKey, to: &params, key: "sessionKey")
        }
        return OpenClawChatGatewayRequest(
            method: "chat.metadata",
            params: params,
            timeoutMs: self.defaultTimeoutMs)
    }

    /// `question.list`.
    public static func questionList() -> OpenClawChatGatewayRequest {
        OpenClawChatGatewayRequest(method: "question.list", timeoutMs: self.defaultTimeoutMs)
    }

    /// `tasks.list`.
    public static func tasksList(
        sessionKey: String,
        agentID: String?,
        limit: Int = 200) -> OpenClawChatGatewayRequest
    {
        var params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(sessionKey),
            "limit": AnyCodable(limit),
        ]
        self.add(agentID, to: &params, key: "agentId")
        return OpenClawChatGatewayRequest(
            method: "tasks.list",
            params: params,
            timeoutMs: self.defaultTimeoutMs)
    }

    /// `question.get`.
    public static func questionGet(id: String) -> OpenClawChatGatewayRequest {
        OpenClawChatGatewayRequest(
            method: "question.get",
            params: ["id": AnyCodable(id)],
            timeoutMs: self.defaultTimeoutMs)
    }

    /// `question.resolve` with answers.
    public static func resolveQuestion(
        id: String,
        answers: [String: [String]],
        secretStoreAllowedHosts: [String]? = nil) -> OpenClawChatGatewayRequest
    {
        let answerValues = answers.mapValues { values in AnyCodable(values.map { AnyCodable($0) }) }
        var params: [String: AnyCodable] = [
            "id": AnyCodable(id),
            "answers": AnyCodable(["answers": AnyCodable(answerValues)]),
        ]
        if let secretStoreAllowedHosts {
            params["secretStoreAllowedHosts"] = AnyCodable(secretStoreAllowedHosts.map { AnyCodable($0) })
        }
        return OpenClawChatGatewayRequest(
            method: "question.resolve",
            params: params,
            timeoutMs: self.mutationTimeoutMs)
    }

    /// `question.resolve` cancellation.
    public static func cancelQuestion(id: String) -> OpenClawChatGatewayRequest {
        OpenClawChatGatewayRequest(
            method: "question.resolve",
            params: [
                "id": AnyCodable(id),
                "cancel": AnyCodable(true),
            ],
            timeoutMs: self.mutationTimeoutMs)
    }

    /// `sessions.list` with paging (`limit`/`offset`), search, archive, and agent filters.
    public static func sessionsList(
        limit: Int?,
        search: String?,
        archived: Bool,
        agentID: String? = nil,
        includeGlobal: Bool = true,
        includeUnknown: Bool = false,
        activeMinutes: Int? = nil,
        spawnedBy: String? = nil,
        offset: Int? = nil,
        configuredAgentsOnly: Bool? = nil,
        timeoutMs: Double = 15000) -> OpenClawChatGatewayRequest
    {
        var params: [String: AnyCodable] = [
            "includeGlobal": AnyCodable(includeGlobal),
            "includeUnknown": AnyCodable(includeUnknown),
        ]
        if let agentID = normalized(agentID) {
            params["agentId"] = AnyCodable(agentID)
        }
        if let limit {
            params["limit"] = AnyCodable(limit)
        }
        if let activeMinutes {
            params["activeMinutes"] = AnyCodable(activeMinutes)
        }
        if let spawnedBy = normalized(spawnedBy) {
            params["spawnedBy"] = AnyCodable(spawnedBy)
        }
        if let offset {
            params["offset"] = AnyCodable(offset)
        }
        if let configuredAgentsOnly {
            params["configuredAgentsOnly"] = AnyCodable(configuredAgentsOnly)
        }
        let normalizedSearch = self.normalized(search)
        if let normalizedSearch {
            params["search"] = AnyCodable(normalizedSearch)
        }
        if archived {
            params["archived"] = AnyCodable(true)
        }
        return OpenClawChatGatewayRequest(
            method: "sessions.list",
            params: params,
            timeoutMs: timeoutMs)
    }

    /// `sessions.groups.list`.
    public static func sessionGroupsList() -> OpenClawChatGatewayRequest {
        OpenClawChatGatewayRequest(
            method: "sessions.groups.list",
            timeoutMs: self.defaultTimeoutMs)
    }

    /// `sessions.groups.put`.
    public static func sessionGroupsPut(names: [String]) -> OpenClawChatGatewayRequest {
        OpenClawChatGatewayRequest(
            method: "sessions.groups.put",
            params: ["names": AnyCodable(names.map { AnyCodable($0) })],
            timeoutMs: self.mutationTimeoutMs)
    }

    /// `sessions.groups.rename`.
    public static func sessionGroupsRename(
        name: String,
        to: String) -> OpenClawChatGatewayRequest
    {
        OpenClawChatGatewayRequest(
            method: "sessions.groups.rename",
            params: [
                "name": AnyCodable(name),
                "to": AnyCodable(to),
            ],
            timeoutMs: self.mutationTimeoutMs)
    }

    /// `sessions.groups.delete`.
    public static func sessionGroupsDelete(name: String) -> OpenClawChatGatewayRequest {
        OpenClawChatGatewayRequest(
            method: "sessions.groups.delete",
            params: ["name": AnyCodable(name)],
            timeoutMs: self.mutationTimeoutMs)
    }

    /// `sessions.create`.
    public static func createSession(
        key: String,
        agentID: String?,
        label: String?,
        parentSessionKey: String?,
        worktree: Bool?,
        worktreeBaseRef: String? = nil) -> OpenClawChatGatewayRequest
    {
        var params = ["key": AnyCodable(key)]
        self.add(agentID, to: &params, key: "agentId")
        self.add(label, to: &params, key: "label", trim: false)
        self.add(parentSessionKey, to: &params, key: "parentSessionKey", trim: false)
        if let worktree {
            params["worktree"] = AnyCodable(worktree)
        }
        self.add(worktreeBaseRef, to: &params, key: "worktreeBaseRef")
        return OpenClawChatGatewayRequest(
            method: "sessions.create",
            params: params,
            timeoutMs: self.mutationTimeoutMs)
    }

    /// `sessions.create` for the `/new` command, asking the gateway to run command hooks.
    public static func createSessionFromNewCommand(
        key: String,
        agentID: String?,
        parentSessionKey: String?) -> OpenClawChatGatewayRequest
    {
        var params = ["key": AnyCodable(key), "emitCommandHooks": AnyCodable(true)]
        self.add(agentID, to: &params, key: "agentId")
        self.add(parentSessionKey, to: &params, key: "parentSessionKey", trim: false)
        return OpenClawChatGatewayRequest(
            method: "sessions.create",
            params: params,
            timeoutMs: self.mutationTimeoutMs)
    }

    /// `chat.abort`.
    public static func abortRun(
        sessionKey: String,
        agentID: String?,
        runID: String,
        requestTimeoutMs: Int = 10000) -> OpenClawChatGatewayRequest
    {
        var params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(sessionKey),
            "runId": AnyCodable(runID),
        ]
        self.add(agentID, to: &params, key: "agentId")
        return OpenClawChatGatewayRequest(
            method: "chat.abort",
            params: params,
            timeoutMs: Double(requestTimeoutMs))
    }

    /// `sessions.patch` for thinking/fast/verbose preferences.
    public static func patchSessionPreferences(
        sessionKey: String,
        agentID: String?,
        thinkingLevel: String?? = nil,
        fastMode: OpenClawChatFastMode?? = nil,
        verboseLevel: String?? = nil) -> OpenClawChatGatewayRequest
    {
        self.patchSessionSettings(
            sessionKey: sessionKey,
            agentID: agentID,
            thinkingLevel: thinkingLevel,
            fastMode: fastMode,
            verboseLevel: verboseLevel)
    }

    /// `sessions.patch` for session settings. Inner `nil` values encode explicit JSON `null` (clear).
    public static func patchSessionSettings(
        sessionKey: String,
        agentID: String?,
        expectedSessionID: String? = nil,
        expectedPermissionMode: OpenClawChatPermissionMode?? = nil,
        expectedToolOverrides: OpenClawChatSessionToolOverrides?? = nil,
        model: String?? = nil,
        thinkingLevel: String?? = nil,
        fastMode: OpenClawChatFastMode?? = nil,
        verboseLevel: String?? = nil,
        permissionMode: OpenClawChatPermissionMode?? = nil,
        toolOverrides: OpenClawChatSessionToolOverrides?? = nil,
        supportsSessionSettingsContract: Bool = false,
        supportsSessionSettingsCAS: Bool = false) -> OpenClawChatGatewayRequest
    {
        var params = self.sessionParams(sessionKey: sessionKey, agentID: agentID)
        if let model {
            params["model"] = model.map { AnyCodable($0) } ?? AnyCodable.nullValue
        }
        if let thinkingLevel {
            params["thinkingLevel"] = thinkingLevel.map { AnyCodable($0) } ?? AnyCodable.nullValue
        }
        if let fastMode {
            params["fastMode"] = fastMode.map(self.fastModeValue) ?? AnyCodable.nullValue
        }
        if let verboseLevel {
            params["verboseLevel"] = verboseLevel.map { AnyCodable($0) } ?? AnyCodable.nullValue
        }
        if supportsSessionSettingsContract {
            self.add(expectedSessionID, to: &params, key: "expectedSessionId")
            if let permissionMode {
                params["permissionMode"] = permissionMode.map { AnyCodable($0.rawValue) } ?? AnyCodable.nullValue
            }
            if let toolOverrides {
                params["toolOverrides"] = toolOverrides.map(self.toolOverridesValue) ?? AnyCodable.nullValue
            }
        }
        if supportsSessionSettingsCAS, let expectedToolOverrides {
            params["expectedToolOverrides"] = expectedToolOverrides
                .map(self.toolOverridesValue) ?? AnyCodable.nullValue
        }
        if supportsSessionSettingsCAS, let expectedPermissionMode {
            params["expectedPermissionMode"] = expectedPermissionMode
                .map { AnyCodable($0.rawValue) } ?? AnyCodable.nullValue
        }
        return OpenClawChatGatewayRequest(
            method: "sessions.patch",
            params: params,
            timeoutMs: self.mutationTimeoutMs)
    }

    private static func fastModeValue(_ mode: OpenClawChatFastMode) -> AnyCodable {
        switch mode {
        case .off: AnyCodable(false)
        case .on: AnyCodable(true)
        case .automatic: AnyCodable("auto")
        }
    }

    private static func toolOverridesValue(_ overrides: OpenClawChatSessionToolOverrides) -> AnyCodable {
        var value: [String: AnyCodable] = [:]
        if let webSearch = overrides.webSearch {
            value["webSearch"] = AnyCodable(webSearch)
        }
        if !overrides.skills.isEmpty {
            value["skills"] = AnyCodable(overrides.skills.mapValues { AnyCodable($0) })
        }
        if !overrides.mcpServers.isEmpty {
            value["mcpServers"] = AnyCodable(overrides.mcpServers.mapValues { AnyCodable($0) })
        }
        if !overrides.mcpToolsDeny.isEmpty {
            value["mcpToolsDeny"] = AnyCodable(overrides.mcpToolsDeny.mapValues { tools in
                AnyCodable(tools.map { AnyCodable($0) })
            })
        }
        return AnyCodable(value)
    }

    /// `sessions.patch` for label/category/color/pin/archive/unread. Archive mutations get a 10-minute timeout.
    public static func patchSession(
        sessionKey: String,
        agentID: String?,
        expectedSessionID: String? = nil,
        label: String??,
        category: String??,
        color: String?? = nil,
        pinned: Bool?,
        archived: Bool?,
        unreadPatch: OpenClawChatSessionUnreadPatch?) -> OpenClawChatGatewayRequest
    {
        var params = self.sessionParams(sessionKey: sessionKey, agentID: agentID)
        if let expectedSessionID = expectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expectedSessionID.isEmpty
        {
            params["expectedSessionId"] = AnyCodable(expectedSessionID)
        }
        if let label {
            params["label"] = label.map { AnyCodable($0) } ?? AnyCodable.nullValue
        }
        if let category {
            params["category"] = category.map { AnyCodable($0) } ?? AnyCodable.nullValue
        }
        if let color {
            params["color"] = color.map { AnyCodable($0) } ?? AnyCodable.nullValue
        }
        if let pinned {
            params["pinned"] = AnyCodable(pinned)
        }
        if let archived {
            params["archived"] = AnyCodable(archived)
        }
        switch unreadPatch {
        case .markUnread:
            params["unread"] = AnyCodable(true)
        case .read:
            params["unread"] = AnyCodable(false)
        case let .automaticRead(expectedMarkedUnreadAt):
            params["unread"] = AnyCodable(false)
            params["expectedMarkedUnreadAt"] = expectedMarkedUnreadAt.map { AnyCodable($0) } ?? AnyCodable.nullValue
        case nil:
            break
        }
        return OpenClawChatGatewayRequest(
            method: "sessions.patch",
            params: params,
            timeoutMs: archived == true ? self.archiveMutationTimeoutMs : self.mutationTimeoutMs)
    }

    /// `sessions.delete` (also deletes the transcript).
    public static func deleteSession(
        sessionKey: String,
        agentID: String?) -> OpenClawChatGatewayRequest
    {
        var params = self.sessionParams(sessionKey: sessionKey, agentID: agentID)
        params["deleteTranscript"] = AnyCodable(true)
        return OpenClawChatGatewayRequest(
            method: "sessions.delete",
            params: params,
            timeoutMs: self.archiveMutationTimeoutMs)
    }

    /// `sessions.create` fork.
    public static func forkSession(
        parentSessionKey: String,
        agentID: String?,
        fromLastCompleted: Bool = false) -> OpenClawChatGatewayRequest
    {
        var params: [String: AnyCodable] = [
            "parentSessionKey": AnyCodable(parentSessionKey),
            "fork": AnyCodable(true),
        ]
        if fromLastCompleted {
            params["forkFrom"] = AnyCodable("last-completed")
        }
        self.add(agentID, to: &params, key: "agentId")
        return OpenClawChatGatewayRequest(
            method: "sessions.create",
            params: params,
            timeoutMs: self.mutationTimeoutMs)
    }

    /// `sessions.rewind`.
    public static func rewindSession(
        sessionKey: String,
        agentID: String?,
        entryId: String) -> OpenClawChatGatewayRequest
    {
        var params = self.sessionParams(
            sessionKey: sessionKey,
            agentID: agentID,
            key: "sessionKey")
        self.add(entryId, to: &params, key: "entryId")
        return OpenClawChatGatewayRequest(
            method: "sessions.rewind",
            params: params,
            timeoutMs: self.mutationTimeoutMs)
    }

    /// `sessions.fork` (fork at a message).
    public static func forkAtMessage(
        sessionKey: String,
        agentID: String?,
        entryId: String) -> OpenClawChatGatewayRequest
    {
        var params = self.sessionParams(
            sessionKey: sessionKey,
            agentID: agentID,
            key: "sessionKey")
        self.add(entryId, to: &params, key: "entryId")
        return OpenClawChatGatewayRequest(
            method: "sessions.fork",
            params: params,
            timeoutMs: self.mutationTimeoutMs)
    }

    /// `sessions.branches.list`.
    public static func listSessionBranches(
        sessionKey: String,
        agentID: String?) -> OpenClawChatGatewayRequest
    {
        let params = self.sessionParams(
            sessionKey: sessionKey,
            agentID: agentID,
            key: "sessionKey")
        return OpenClawChatGatewayRequest(
            method: "sessions.branches.list",
            params: params,
            timeoutMs: self.defaultTimeoutMs)
    }

    /// `sessions.branches.switch`.
    public static func switchSessionBranch(
        sessionKey: String,
        agentID: String?,
        leafEntryId: String) -> OpenClawChatGatewayRequest
    {
        var params = self.sessionParams(
            sessionKey: sessionKey,
            agentID: agentID,
            key: "sessionKey")
        self.add(leafEntryId, to: &params, key: "leafEntryId")
        return OpenClawChatGatewayRequest(
            method: "sessions.branches.switch",
            params: params,
            timeoutMs: self.mutationTimeoutMs)
    }

    /// `sessions.subscribe`.
    public static func subscribeSessions(timeoutMs: Double = 10000) -> OpenClawChatGatewayRequest {
        OpenClawChatGatewayRequest(
            method: "sessions.subscribe",
            timeoutMs: timeoutMs)
    }

    /// `sessions.observer.visibility`.
    public static func setSessionObserverVisibility(
        _ visible: Bool,
        timeoutMs: Double = 10000) -> OpenClawChatGatewayRequest
    {
        OpenClawChatGatewayRequest(
            method: "sessions.observer.visibility",
            params: ["visible": AnyCodable(visible)],
            timeoutMs: timeoutMs)
    }

    /// `sessions.messages.subscribe`.
    public static func subscribeSessionMessages(
        sessionKey: String,
        agentID: String?) -> OpenClawChatGatewayRequest
    {
        OpenClawChatGatewayRequest(
            method: "sessions.messages.subscribe",
            params: self.sessionParams(sessionKey: sessionKey, agentID: agentID),
            timeoutMs: self.shortTimeoutMs)
    }

    /// `sessions.reset`.
    public static func resetSession(
        sessionKey: String,
        agentID: String?) -> OpenClawChatGatewayRequest
    {
        OpenClawChatGatewayRequest(
            method: "sessions.reset",
            params: self.sessionParams(sessionKey: sessionKey, agentID: agentID),
            timeoutMs: self.shortTimeoutMs)
    }

    /// `sessions.compact` (no client timeout).
    public static func compactSession(
        sessionKey: String,
        agentID: String?,
        maxLines: Int? = nil) -> OpenClawChatGatewayRequest
    {
        var params = self.sessionParams(sessionKey: sessionKey, agentID: agentID)
        if let maxLines {
            params["maxLines"] = AnyCodable(maxLines)
        }
        return OpenClawChatGatewayRequest(
            method: "sessions.compact",
            params: params,
            timeoutMs: self.compactionTimeoutMs)
    }

    /// `chat.history`.
    public static func history(
        sessionKey: String,
        agentID: String?,
        limit: Int? = nil,
        maxChars: Int? = nil,
        inputRunIDs: [String]? = nil,
        timeoutMs: Int? = nil) -> OpenClawChatGatewayRequest
    {
        var params: [String: AnyCodable] = ["sessionKey": AnyCodable(sessionKey)]
        self.add(agentID, to: &params, key: "agentId")
        if let limit {
            params["limit"] = AnyCodable(limit)
        }
        if let maxChars {
            params["maxChars"] = AnyCodable(maxChars)
        }
        if let inputRunIDs, !inputRunIDs.isEmpty {
            params["inputRunIds"] = AnyCodable(inputRunIDs.map { AnyCodable($0) })
        }
        return OpenClawChatGatewayRequest(
            method: "chat.history",
            params: params,
            timeoutMs: timeoutMs.map(Double.init) ?? self.defaultTimeoutMs)
    }

    /// `progressCard.get`; `agentId` is sent only when the key does not already imply it.
    public static func progressCardGet(sessionKey: String, agentID: String?) -> OpenClawChatGatewayRequest {
        let target = OpenClawChatSessionTarget.resolve(
            sessionKey,
            selectedAgentID: nil,
            overrideAgentID: agentID,
            policy: .scopeBareKeysToSelectedAgent)
        var params: [String: AnyCodable] = ["sessionKey": AnyCodable(target.sessionKey)]
        // Released gateways reject extra fields; qualified keys already carry their owner.
        if target.agentID != OpenClawChatSessionKey.agentID(from: target.sessionKey)?.lowercased() {
            self.add(target.agentID, to: &params, key: "agentId")
        }
        return OpenClawChatGatewayRequest(
            method: "progressCard.get",
            params: params,
            timeoutMs: self.defaultTimeoutMs)
    }

    /// `commands.list` (text scope with args).
    public static func commandsList(
        sessionKey: String?,
        fallbackAgentID: String?) -> OpenClawChatGatewayRequest
    {
        var params: [String: AnyCodable] = [
            "scope": AnyCodable("text"),
            "includeArgs": AnyCodable(true),
        ]
        self.add(
            sessionKey.flatMap(OpenClawChatSessionKey.agentID) ?? fallbackAgentID,
            to: &params,
            key: "agentId")
        return OpenClawChatGatewayRequest(
            method: "commands.list",
            params: params,
            timeoutMs: self.defaultTimeoutMs)
    }

    /// `chat.send`; with settings CAS the expected permission mode and tool overrides are sent
    /// (explicit `null` when unset).
    public static func sendMessage(
        sessionKey: String,
        agentID: String?,
        expectedSessionRoutingContract: String?,
        expectedSessionSettings: OpenClawChatSessionSettingsExpectation? = nil,
        supportsSessionSettingsCAS: Bool = false,
        message: String,
        thinking: String?,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload],
        runTimeoutMs: Int? = nil,
        requestTimeoutMs: Int = 30000) -> OpenClawChatGatewayRequest
    {
        var params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(sessionKey),
            "message": AnyCodable(message),
            "idempotencyKey": AnyCodable(idempotencyKey),
        ]
        self.add(agentID, to: &params, key: "agentId")
        self.add(
            expectedSessionRoutingContract,
            to: &params,
            key: "expectedSessionRoutingContract")
        self.add(thinking, to: &params, key: "thinking")
        if supportsSessionSettingsCAS, let expectedSessionSettings {
            params["expectedPermissionMode"] = expectedSessionSettings.permissionMode
                .map { AnyCodable($0.rawValue) } ?? AnyCodable.nullValue
            params["expectedToolOverrides"] = expectedSessionSettings.toolOverrides
                .map(self.toolOverridesValue) ?? AnyCodable.nullValue
        }
        if let runTimeoutMs {
            params["timeoutMs"] = AnyCodable(runTimeoutMs)
        }
        if !attachments.isEmpty {
            let encoded = attachments.map { attachment in
                AnyCodable([
                    "type": AnyCodable(attachment.type),
                    "mimeType": AnyCodable(attachment.mimeType),
                    "fileName": AnyCodable(attachment.fileName),
                    "content": AnyCodable(attachment.content),
                ])
            }
            params["attachments"] = AnyCodable(encoded)
        }
        return OpenClawChatGatewayRequest(
            method: "chat.send",
            params: params,
            timeoutMs: Double(requestTimeoutMs))
    }

    /// `agent.wait`; the request timeout adds a grace period to the server-side wait.
    public static func agentWait(
        runID: String,
        timeoutMs: Int,
        requestGraceMs: Int = 5000) -> OpenClawChatGatewayRequest
    {
        OpenClawChatGatewayRequest(
            method: "agent.wait",
            params: [
                "runId": AnyCodable(runID),
                "timeoutMs": AnyCodable(timeoutMs),
            ],
            timeoutMs: Double(timeoutMs + requestGraceMs))
    }

    /// `health`.
    public static func health(timeoutMs: Int) -> OpenClawChatGatewayRequest {
        OpenClawChatGatewayRequest(
            method: "health",
            timeoutMs: Double(max(1, timeoutMs)))
    }

    private static func sessionParams(
        sessionKey: String,
        agentID: String?,
        key: String = "key") -> [String: AnyCodable]
    {
        var params = [key: AnyCodable(sessionKey)]
        self.add(agentID, to: &params, key: "agentId")
        return params
    }

    private static func add(
        _ value: String?,
        to params: inout [String: AnyCodable],
        key: String,
        trim: Bool = true)
    {
        let value = trim ? self.normalized(value) : value
        if let value {
            params[key] = AnyCodable(value)
        }
    }

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }
}
