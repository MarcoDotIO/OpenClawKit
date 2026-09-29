import Foundation
import OpenClawCore
import OpenClawProtocol

// Built-in session lifecycle (`sessions.create`, `sessions.send`, `sessions.abort`) and session
// organization (`sessions.groups.*`) for servers without an attached runtime. Runs go through
// `GatewayServerHandlers.runAgent`; an attached `EmbeddedAgentRuntime` replaces these handlers with
// runtime-backed ones.
extension GatewayServer {
    /// Session key for a new session without an explicit key (upstream `buildDashboardSessionKey`).
    /// - Parameter agentID: Owning agent.
    /// - Returns: `agent:<agentId>:dashboard:<uuid>`.
    public static func generatedSessionKey(agentID: String) -> String {
        "agent:\(SessionKey.normalizeAgentID(agentID)):dashboard:\(UUID().uuidString.lowercased())"
    }

    /// Params of `sessions.create` that describe the initial run or the create call itself rather
    /// than session state; they are stripped before the params are applied as a patch.
    public static let sessionCreateNonPatchFields: Set<String> = [
        "message", "task", "timeoutMs", "idempotencyKey", "attachments", "mentions", "parentSessionKey",
        "spawnDepth", "fork", "forkFrom", "incognito", "visibility", "catalogId", "emitCommandHooks",
        "succeedsParent", "displayName", "titleSource", "projectId", "projectGitUrl", "repository",
        "worktree", "worktreeSource", "worktreeBaseRef", "worktreeName", "cwd",
    ]

    // MARK: - sessions.create

    /// `sessions.create` → `{ok, key, sessionId, entry, runStarted?, runId?, runError?}`
    /// (upstream `SessionsCreateResult`). A `message` (or `task`) starts the first run.
    func handleSessionsCreate(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let idempotencyKey = request.stringParam("idempotencyKey").map { "sessions.create:\($0)" }
        return try await self.agentIdempotency.run(key: idempotencyKey) { [weak self] in
            guard let self else { throw GatewayMethodError.unavailable("gateway server is no longer available") }
            return try await self.createSession(request)
        }
    }

    private func createSession(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let agentID = SessionKey.normalizeAgentID(request.stringParam("agentId") ?? self.defaultAgentID)
        let key = request.stringParam("key") ?? Self.generatedSessionKey(agentID: agentID)
        var raw = request.params
        raw["key"] = AnyCodable(key)
        for field in Self.sessionCreateNonPatchFields {
            raw[field] = nil
        }
        let patchRequest = GatewayMethodRequest(
            id: request.id,
            method: "sessions.patch",
            rawParams: AnyCodable(raw),
            descriptor: request.descriptor,
            connection: request.connection,
            events: request.events
        )
        var record = try await Self.applySessionPatch(patchRequest, store: self.sessionStore, defaultAgentID: agentID).record
        let parent = request.stringParam("parentSessionKey")
        let spawnDepth = request.params["spawnDepth"]?.intValue
        if parent != nil || spawnDepth != nil {
            record = await self.sessionStore.update(forKey: key) { record in
                if let parent { record.spawnedBy = parent }
                if let spawnDepth { record.spawnDepth = spawnDepth }
            } ?? record
        }
        if record.sessionID == nil {
            record = await self.sessionStore.resolveOrCreate(sessionKey: key, defaultAgentID: agentID, route: nil)
        }
        try? await self.sessionStore.save()
        if let category = record.category {
            await self.sessionGroups.register(category)
        }
        var payload: [String: AnyCodable] = [
            "ok": AnyCodable(true),
            "key": AnyCodable(key),
            "entry": Self.recordPayload(record),
            "session": (try? GatewayPayloadCodec.encode(Self.sessionInfo(from: record))) ?? .nullValue,
        ]
        if let sessionID = record.sessionID {
            payload["sessionId"] = AnyCodable(sessionID)
        }
        await self.emitSessionsChanged(sessionKey: key, reason: "create")
        if let message = request.stringParam("message", "task") {
            do {
                let accepted = try await self.startSessionRun(sessionKey: key, message: message, agentID: record.agentID, request: request, record: record)
                payload["runStarted"] = AnyCodable(true)
                payload["runId"] = AnyCodable(accepted)
            } catch {
                payload["runStarted"] = AnyCodable(false)
                payload["runError"] = try GatewayPayloadCodec.encode(GatewayMethodError.errorShape(for: error))
            }
        }
        return AnyCodable(payload)
    }

    // MARK: - sessions.send

    /// `sessions.send {key, message, agentId?, thinking?, attachments?, timeoutMs?, idempotencyKey?}`
    /// → `{ok, key, runId, status: "started", runStarted: true}`.
    func handleSessionsSend(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let params = try request.decodeParams(SessionsSendParams.self)
        let key = params.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw GatewayMethodError.invalidRequest("sessions.send requires a session key")
        }
        guard let message = Self.normalizedText(params.message) else {
            throw GatewayMethodError.invalidRequest("sessions.send requires message")
        }
        let idempotencyKey = Self.normalizedText(params.idempotencykey).map { "sessions.send:\(key):\($0)" }
        return try await self.agentIdempotency.run(key: idempotencyKey) { [weak self] in
            guard let self else { throw GatewayMethodError.unavailable("gateway server is no longer available") }
            let record = await self.sessionStore.resolveOrCreate(
                sessionKey: key,
                defaultAgentID: Self.normalizedText(params.agentid) ?? self.defaultAgentID,
                route: nil
            )
            let runID = try await self.startSessionRun(sessionKey: key, message: message, agentID: record.agentID, request: request, record: record)
            return AnyCodable([
                "ok": AnyCodable(true),
                "key": AnyCodable(key),
                "runId": AnyCodable(runID),
                "status": AnyCodable("started"),
                "runStarted": AnyCodable(true),
            ])
        }
    }

    private func startSessionRun(
        sessionKey: String,
        message: String,
        agentID: String,
        request: GatewayMethodRequest,
        record: SessionRecord?
    ) async throws -> String {
        let model = record?.modelOverride
        let parts = model?.split(separator: "/", maxSplits: 1).map(String.init) ?? []
        let params = GatewayAgentRequest(
            sessionKey: sessionKey,
            message: message,
            modelProviderID: parts.count == 2 ? parts[0] : nil,
            modelID: parts.count == 2 ? parts[1] : model,
            timeoutMs: GatewayTimeouts.clampedIntMilliseconds(request.params["timeoutMs"]),
            agentID: agentID,
            sessionID: record?.sessionID,
            thinking: request.stringParam("thinking") ?? record?.thinkingLevel?.rawValue,
            attachments: request.params["attachments"]?.arrayValue,
            idempotencyKey: request.stringParam("idempotencyKey")
        )
        let execution = try await self.handlers.runAgent(params)
        self.trackRun(execution, sessionKey: sessionKey, agentID: agentID, startedAt: gatewayNowMs())
        return execution.runID
    }

    // MARK: - sessions.abort

    /// `sessions.abort {key?, runId?, agentId?}` → `{ok, abortedRunId, status: "aborted" | "no-active-run"}`
    /// (plus the SDK extras `aborted` and `runIds`). Without `runId`, the latest active run of the
    /// session is aborted. Finished and already-aborted runs answer `no-active-run`; an aborted run
    /// stays tracked until its task ends, so `agent.wait` still receives its terminal status.
    func handleSessionsAbort(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let runID = request.stringParam("runId", "runID")
        let key = request.stringParam("key", "sessionKey")
        guard runID != nil || key != nil else {
            throw GatewayMethodError.invalidRequest("sessions.abort requires key or runId")
        }
        var target: String?
        if let runID {
            if self.trackedRuns[runID]?.aborted == false {
                target = runID
            }
        } else if let key {
            target = self.trackedRuns
                .filter { $0.value.sessionKey == key && !$0.value.aborted }
                .max { $0.value.order < $1.value.order }?
                .key
        }
        var abortedIDs: [String] = []
        if let target, let task = self.agentRuns[target] {
            self.trackedRuns[target]?.aborted = true
            task.cancel()
            abortedIDs.append(target)
        }
        return Self.abortPayload(abortedRunIDs: abortedIDs)
    }

    /// Upstream `sessions.abort` / `chat.abort` answer (`abortedRunId` is `null` without an active run).
    /// - Parameter abortedRunIDs: Aborted runs, first one reported as `abortedRunId`.
    /// - Returns: The payload.
    public static func abortPayload(abortedRunIDs: [String]) -> AnyCodable {
        AnyCodable([
            "ok": AnyCodable(true),
            "abortedRunId": abortedRunIDs.first.map { AnyCodable($0) } ?? .nullValue,
            "status": AnyCodable(abortedRunIDs.isEmpty ? "no-active-run" : "aborted"),
            "aborted": AnyCodable(!abortedRunIDs.isEmpty),
            "runIds": AnyCodable(abortedRunIDs.map { AnyCodable($0) }),
        ])
    }

    // MARK: - sessions.groups.*

    func handleSessionGroups(_ builtin: BuiltinMethod, request: GatewayMethodRequest) async throws -> AnyCodable? {
        do {
            switch builtin {
            case .sessionsGroupsList:
                return try await self.groupsPayload(extra: [:], includeOK: false)
            case .sessionsGroupsDefaults:
                return AnyCodable(["defaults": try GatewayPayloadCodec.encode(await self.sessionGroups.defaults())])
            case .sessionsGroupsPut:
                let params = try request.decodeParams(SessionsGroupsPutParams.self)
                let counts = await self.groupMemberCounts()
                try await self.sessionGroups.put(names: params.names, sectionOrder: params.sectionorder, memberCounts: counts)
                await self.emitSessionsChanged(sessionKey: nil, reason: "groups")
                return try await self.groupsPayload(extra: [:], includeOK: true)
            case .sessionsGroupsRename:
                let params = try request.decodeParams(SessionsGroupsRenameParams.self)
                try await self.sessionGroups.rename(params.name, to: params.to)
                let updated = await self.moveGroupMembers(from: params.name, to: params.to)
                await self.emitSessionsChanged(sessionKey: nil, reason: "groups")
                return try await self.groupsPayload(extra: ["updatedSessions": AnyCodable(updated)], includeOK: true)
            case .sessionsGroupsDelete:
                let params = try request.decodeParams(SessionsGroupsDeleteParams.self)
                try await self.sessionGroups.delete(params.name)
                let updated = await self.moveGroupMembers(from: params.name, to: nil)
                await self.emitSessionsChanged(sessionKey: nil, reason: "groups")
                return try await self.groupsPayload(extra: ["updatedSessions": AnyCodable(updated)], includeOK: true)
            case .sessionsGroupsUpdate:
                let name = try Self.requiredParam(request, "name")
                let cwd = request.params["cwd"]?.stringValue
                if let cwd, !cwd.hasPrefix("/") {
                    throw GatewayMethodError.invalidRequest("session group cwd must be absolute")
                }
                let worktree = request.params["worktree"]?.boolValue ?? false
                let defaults = try await self.sessionGroups.updateDefaults(name: name, cwd: cwd, worktree: worktree)
                await self.emitSessionsChanged(sessionKey: nil, reason: "groups")
                return AnyCodable(["ok": AnyCodable(true), "defaults": try GatewayPayloadCodec.encode(defaults)])
            default:
                return nil
            }
        } catch let error as GatewaySessionGroupError {
            throw GatewayMethodError.invalidRequest(error.localizedDescription)
        }
    }

    private func groupsPayload(extra: [String: AnyCodable], includeOK: Bool) async throws -> AnyCodable {
        var payload = extra
        payload["groups"] = try GatewayPayloadCodec.encode(await self.sessionGroups.groups())
        payload["sectionOrder"] = AnyCodable(await self.sessionGroups.sectionOrder().map { AnyCodable($0) })
        if includeOK {
            payload["ok"] = AnyCodable(true)
        }
        return AnyCodable(payload)
    }

    private func groupMemberCounts() async -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in await self.sessionStore.allRecords() {
            if let category = record.category {
                counts[category, default: 0] += 1
            }
        }
        return counts
    }

    /// Moves every session of group `from` to `to` (`nil` clears the category); sessions are kept.
    private func moveGroupMembers(from: String, to: String?) async -> Int {
        let source = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = to?.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = 0
        for record in await self.sessionStore.allRecords() where record.category == source && source != target {
            await self.sessionStore.update(forKey: record.key) { $0.category = target }
            updated += 1
        }
        if updated > 0 {
            try? await self.sessionStore.save()
        }
        return updated
    }
}
