import Foundation
import OpenClawCore
import OpenClawProtocol

// Built-in in-process handlers. Each accepts the legacy OpenClawKit payload shape and the upstream
// OpenClaw 2026.9.6 shape where the two overlap (for example `runId`/`runID`, `agentId`/`agentID`,
// `model`/`modelOverride`), and answers with a payload both decoders accept.
extension GatewayServer {
    func invokeBuiltin(_ builtin: BuiltinMethod, request: GatewayMethodRequest) async throws -> AnyCodable? {
        switch builtin {
        case .agentRun:
            return try await self.handleAgentRun(request)
        case .agentWait:
            return try GatewayPayloadCodec.encode(try await self.handleAgentWait(request))
        case .sessionsList:
            return try await self.handleSessionsList(request)
        case .sessionsGet:
            let params = try request.decodeParams(GatewaySessionGetParams.self)
            let record = await self.sessionStore.recordForKey(params.key)
            var payload = try GatewayPayloadCodec.encode(GatewaySessionGetResult(session: record.map(Self.sessionInfo(from:)))).dictionaryValue ?? [:]
            if let record {
                payload["entry"] = Self.recordPayload(record)
            }
            return AnyCodable(payload)
        case .sessionsPatch:
            return try await self.handleSessionPatch(request)
        case .sessionsReset:
            return try await self.handleSessionReset(request)
        case .sessionsDelete:
            return try await self.handleSessionDelete(request)
        case .sessionsCreate:
            return try await self.handleSessionsCreate(request)
        case .sessionsSend:
            return try await self.handleSessionsSend(request)
        case .sessionsAbort:
            return try await self.handleSessionsAbort(request)
        case .sessionsSubscribe:
            return try await self.handleSessionsSubscribe(request)
        case .sessionsMessagesSubscribe:
            return try self.handleMessagesSubscribe(request, subscribe: true)
        case .sessionsMessagesUnsubscribe:
            return try self.handleMessagesSubscribe(request, subscribe: false)
        case .sessionsGroupsList, .sessionsGroupsDefaults, .sessionsGroupsPut, .sessionsGroupsRename,
             .sessionsGroupsUpdate, .sessionsGroupsDelete:
            return try await self.handleSessionGroups(builtin, request: request)
        case .modelsList:
            let models = try await self.handlers.listModels()
            return try GatewayPayloadCodec.encode(GatewayModelsListWirePayload(models: models))
        case .skillsList:
            return try GatewayPayloadCodec.encode(GatewaySkillsListResult(skills: try await self.handlers.listSkills()))
        case .skillsInvoke:
            let params = try request.decodeParams(GatewaySkillInvokeParams.self)
            return try GatewayPayloadCodec.encode(try await self.handlers.invokeSkill(params))
        case .secretsList:
            let keys = await self.secretVault.listSecretKeys()
            return try GatewayPayloadCodec.encode(GatewaySecretsListResult(secrets: keys.map(GatewaySecretDescriptor.init(key:))))
        case .secretsSet:
            let params = try request.decodeParams(GatewaySecretSetParams.self)
            try await self.secretVault.setSecret(params.value, for: params.key)
            return try GatewayPayloadCodec.encode(GatewaySecretMutationResult(key: params.key))
        case .secretsDelete:
            let params = try request.decodeParams(GatewaySecretDeleteParams.self)
            let deleted = try await self.secretVault.deleteSecret(for: params.key)
            return try GatewayPayloadCodec.encode(GatewaySecretMutationResult(key: params.key, deleted: deleted))
        case .secretsStoreList:
            return try await self.handleSecretsStoreList(request)
        case .secretsStoreSet:
            return try await self.handleSecretsStoreSet(request)
        case .secretsStoreDelete:
            return try await self.handleSecretsStoreDelete(request)
        case .browserRequest:
            return try GatewayPayloadCodec.encode(try await self.handleBrowserRequest(request))
        case .systemPresence:
            return AnyCodable(self.presenceEntries())
        case .nodeList, .nodePairList, .nodePairApprove, .nodePairReject, .nodePairRemove, .nodeRename:
            return try await self.handleNodeBuiltin(builtin, request: request)
        }
    }

    // MARK: - Agent

    /// `agent` / `agent.run`: `{runId, status: "accepted", sessionKey, agentId, acceptedAt}`.
    ///
    /// A retry with the same `idempotencyKey` within 10 minutes returns the first acceptance instead
    /// of starting a second run.
    private func handleAgentRun(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let params = try Self.agentRequest(from: request)
        guard params.text != nil else {
            throw GatewayMethodError.invalidRequest("\(request.method) requires message")
        }
        let idempotencyKey = params.idempotencyKey.map { "agent:\($0)" }
        return try await self.agentIdempotency.run(key: idempotencyKey) { [weak self] in
            guard let self else { throw GatewayMethodError.unavailable("gateway server is no longer available") }
            return try await self.startAgentRun(params)
        }
    }

    private func startAgentRun(_ params: GatewayAgentRequest) async throws -> AnyCodable? {
        let execution = try await self.handlers.runAgent(params)
        let agentID = SessionKey.normalizeAgentID(params.agentID ?? SessionKey.agentID(from: params.sessionKey, fallback: self.defaultAgentID))
        let acceptedAt = gatewayNowMs()
        self.trackRun(execution, sessionKey: params.sessionKey, agentID: agentID, startedAt: acceptedAt)
        return try GatewayPayloadCodec.encode(
            GatewayAgentAccepted(runID: execution.runID, sessionKey: params.sessionKey, agentID: agentID, acceptedAt: acceptedAt)
        )
    }

    func trackRun(_ execution: GatewayAgentExecution, sessionKey: String, agentID: String, startedAt: Int64) {
        self.agentRuns[execution.runID] = execution.task
        self.trackedRuns[execution.runID] = TrackedRun(sessionKey: sessionKey, agentID: agentID, startedAt: startedAt)
    }

    /// Decodes the legacy `GatewayAgentRequest` shape, falling back to (or enriching from) upstream `AgentParams`.
    ///
    /// Upstream `timeout` is seconds and becomes `timeoutMs`; channel delivery fields (`to`,
    /// `replyTo`, `channel`, `accountId`, `threadId`, …) are accepted and ignored in embedded mode.
    /// - Parameter request: `agent` / `agent.run` request.
    /// - Returns: The normalized request.
    /// - Throws: `INVALID_REQUEST` when neither shape decodes.
    public static func agentRequest(from request: GatewayMethodRequest) throws -> GatewayAgentRequest {
        let legacy = Result { try GatewayPayloadCodec.decode(GatewayAgentRequest.self, from: request.rawParams) }
        let upstream = try? GatewayPayloadCodec.decode(AgentParams.self, from: request.rawParams)
        let upstreamTimeoutMs = upstream?.timeout.map { min(max($0, 0), Int.max / 1000) * 1000 }
        let params = request.params
        switch legacy {
        case .success(let legacy):
            return GatewayAgentRequest(
                sessionKey: legacy.sessionKey,
                prompt: legacy.prompt,
                message: legacy.message ?? upstream?.message,
                modelProviderID: legacy.modelProviderID ?? Self.normalizedText(upstream?.provider),
                modelID: legacy.modelID ?? Self.normalizedText(upstream?.model),
                timeoutMs: legacy.timeoutMs ?? upstreamTimeoutMs,
                deliver: legacy.deliver ?? upstream?.deliver,
                agentID: Self.normalizedText(legacy.agentID),
                sessionID: Self.normalizedText(legacy.sessionID),
                thinking: Self.normalizedText(legacy.thinking),
                extraSystemPrompt: Self.normalizedText(legacy.extraSystemPrompt),
                label: Self.normalizedText(legacy.label),
                promptMode: legacy.promptMode ?? params["promptMode"]?.stringValue,
                bootstrapContextMode: legacy.bootstrapContextMode ?? params["bootstrapContextMode"]?.stringValue,
                cwd: Self.normalizedText(legacy.cwd),
                attachments: legacy.attachments,
                idempotencyKey: Self.normalizedText(legacy.idempotencyKey)
            )
        case .failure(let error):
            guard let upstream else {
                throw GatewayMethodError.invalidParams(method: request.method, underlying: error)
            }
            return GatewayAgentRequest(
                sessionKey: Self.normalizedText(upstream.sessionkey) ?? "main",
                message: upstream.message,
                modelProviderID: Self.normalizedText(upstream.provider),
                modelID: Self.normalizedText(upstream.model),
                timeoutMs: upstreamTimeoutMs,
                deliver: upstream.deliver,
                agentID: Self.normalizedText(upstream.agentid),
                sessionID: Self.normalizedText(upstream.sessionid),
                thinking: Self.normalizedText(upstream.thinking),
                extraSystemPrompt: Self.normalizedText(upstream.extrasystemprompt),
                label: Self.normalizedText(upstream.label),
                promptMode: upstream.promptmode?.stringValue,
                bootstrapContextMode: upstream.bootstrapcontextmode?.stringValue,
                cwd: Self.normalizedText(upstream.cwd),
                attachments: upstream.attachments,
                idempotencyKey: Self.normalizedText(upstream.idempotencykey)
            )
        }
    }

    /// `agent.wait {runId, timeoutMs?}` → `{runId, status: ok|error|timeout, startedAt, endedAt?, error?}`
    /// (plus the SDK extras `sessionKey` and `output`). A timed-out wait keeps tracking the run.
    private func handleAgentWait(_ request: GatewayMethodRequest) async throws -> GatewayAgentWaitResult {
        let params = try request.decodeParams(GatewayAgentWaitParams.self)
        guard let task = self.agentRuns[params.runID] else {
            throw GatewayMethodError.unavailable("Agent run '\(params.runID)' is not tracked by this gateway server")
        }
        let tracked = self.trackedRuns[params.runID]
        let result: GatewayAgentWaitResult
        if let timeoutMs = params.timeoutMs, timeoutMs > 0 {
            result = try await withThrowingTaskGroup(of: GatewayAgentWaitResult.self) { group in
                group.addTask {
                    try await task.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    return GatewayAgentWaitResult(runID: params.runID, status: "timeout", sessionKey: tracked?.sessionKey)
                }
                let first = try await group.next() ?? GatewayAgentWaitResult(runID: params.runID, status: "timeout")
                group.cancelAll()
                return first
            }
        } else {
            result = try await task.value
        }
        let terminal = result.status == "ok" || result.status == "error"
        if terminal {
            self.agentRuns.removeValue(forKey: params.runID)
            self.trackedRuns.removeValue(forKey: params.runID)
        }
        return result.stamped(startedAt: tracked?.startedAt, endedAt: terminal ? gatewayNowMs() : nil)
    }

    // MARK: - Sessions

    /// `sessions.list`: `{ts, count, totalCount, offset, hasMore, nextOffset?, sessions}` with rows in
    /// both the legacy and the upstream `SessionRow` shape.
    ///
    /// Filters: `agentId`, `search` (key/label), `label`, `group` (category), `pinned`, `archived`
    /// (`true`/`"only"`, `false`/`"exclude"`, or absent for all), `spawnedBy`, `excludeSubagents`,
    /// `limit`, `offset`. Rows sort pinned first, then by `updatedAt` descending.
    func handleSessionsList(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let params = request.params
        var records = await self.sessionStore.allRecords()
        if let agentID = request.stringParam("agentId") {
            let normalized = SessionKey.normalizeAgentID(agentID)
            records = records.filter { SessionKey.normalizeAgentID($0.agentID) == normalized }
        }
        if let search = request.stringParam("search")?.lowercased() {
            records = records.filter { record in
                record.key.lowercased().contains(search)
                    || (record.label?.lowercased().contains(search) ?? false)
                    || (record.autoLabel?.lowercased().contains(search) ?? false)
            }
        }
        if let label = request.stringParam("label") {
            records = records.filter { $0.label == label }
        }
        if let group = request.stringParam("group") {
            records = records.filter { $0.category == group }
        }
        if let pinned = params["pinned"]?.boolValue {
            records = records.filter { $0.pinned == pinned }
        }
        let archivedFilter: Bool?
        if let flag = params["archived"]?.boolValue {
            archivedFilter = flag
        } else {
            switch params["archived"]?.stringValue {
            case "only": archivedFilter = true
            case "exclude": archivedFilter = false
            default: archivedFilter = nil
            }
        }
        if let archivedFilter {
            records = records.filter { $0.archived == archivedFilter }
        }
        if let spawnedBy = request.stringParam("spawnedBy") {
            records = records.filter { $0.spawnedBy == spawnedBy }
        }
        if params["excludeSubagents"]?.boolValue == true {
            records = records.filter { !$0.isChildSession }
        }
        records.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.updatedAtMs != rhs.updatedAtMs { return lhs.updatedAtMs > rhs.updatedAtMs }
            return lhs.key < rhs.key
        }
        let total = records.count
        let offset = max(0, params["offset"]?.intValue ?? 0)
        let limit = params["limit"]?.intValue.map { max(1, $0) }
        var page = Array(records.dropFirst(offset))
        if let limit {
            page = Array(page.prefix(limit))
        }
        var payload = try GatewayPayloadCodec.encode(GatewaySessionListResult(sessions: page.map(Self.sessionInfo(from:)))).dictionaryValue ?? [:]
        payload["ts"] = AnyCodable(gatewayNowMs())
        payload["count"] = AnyCodable(page.count)
        payload["totalCount"] = AnyCodable(total)
        payload["offset"] = AnyCodable(offset)
        let hasMore = offset + page.count < total
        payload["hasMore"] = AnyCodable(hasMore)
        if hasMore {
            payload["nextOffset"] = AnyCodable(offset + page.count)
        }
        return AnyCodable(payload)
    }

    /// `sessions.patch`: applies legacy or upstream params, answers
    /// `{ok, key, session, entry}` and emits `sessions.changed {reason: "patch"}`.
    private func handleSessionPatch(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        _ = try request.decodeParams(GatewaySessionPatchParams.self)
        let outcome = try await Self.applySessionPatch(request, store: self.sessionStore, defaultAgentID: self.defaultAgentID)
        try await self.sessionStore.save()
        if let category = outcome.record.category {
            await self.sessionGroups.register(category)
        }
        await self.emitSessionsChanged(sessionKey: outcome.record.key, reason: outcome.created ? "create" : "patch")
        return try Self.mutationPayload(key: outcome.record.key, record: outcome.record)
    }

    /// Applies `sessions.patch` params through ``SessionStore/applyPatch(_:defaultAgentID:grantedScopes:)``,
    /// mapping patch errors to gateway errors (retired `execSecurity`/`execAsk` → `INVALID_REQUEST`,
    /// `permissionMode: full` without `operator.admin` → `FORBIDDEN`).
    public static func applySessionPatch(
        _ request: GatewayMethodRequest,
        store: SessionStore,
        defaultAgentID: String
    ) async throws -> SessionPatchOutcome {
        do {
            return try await store.applyPatch(
                request.params,
                defaultAgentID: defaultAgentID,
                grantedScopes: request.connection.role == "operator" ? Set(request.connection.scopes) : nil
            )
        } catch let error as SessionPatchError {
            switch error {
            case .invalid(let message):
                throw GatewayMethodError.invalidRequest(message)
            case .missingScope(let scope, _):
                throw GatewayMethodError.missingScope(scope)
            }
        }
    }

    /// `sessions.reset {key, agentId?, reason?}` (upstream `SessionsResetParams`).
    private func handleSessionReset(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let key = try Self.requireSessionKey(request)
        guard let reset = await self.sessionStore.rotateSession(forKey: key) else {
            return try GatewayPayloadCodec.encode(GatewaySessionMutationResult(key: key, session: nil))
        }
        try await self.sessionStore.save()
        await self.emitSessionsChanged(sessionKey: key, reason: "reset")
        return try Self.mutationPayload(key: key, record: reset)
    }

    /// `sessions.delete {key, agentId?, …}` → `{ok, key, deleted, archived: []}` (upstream `SessionsDeleteResult`).
    private func handleSessionDelete(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let key = try Self.requireSessionKey(request)
        let existing = await self.sessionStore.recordForKey(key)
        if request.params["archivedOnly"]?.boolValue == true, existing?.archived != true {
            throw GatewayMethodError.invalidRequest("sessions.delete archivedOnly requires an archived session")
        }
        let deleted = await self.sessionStore.deleteRecord(forKey: key)
        if deleted {
            try await self.sessionStore.save()
            await self.emitSessionsChanged(sessionKey: key, reason: "delete", extra: existing.map { ["agentId": AnyCodable($0.agentID)] } ?? [:])
        }
        return try GatewayPayloadCodec.encode(GatewaySessionMutationResult(key: key, deleted: deleted, archived: []))
    }

    // MARK: - Secret store (upstream `secrets.store.*`)

    private func handleSecretsStoreList(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        _ = try request.decodeParams(SecretsStoreListParams.self)
        var entries: [AnyCodable] = []
        for metadata in await self.secretVault.listMetadata() where Self.isSecretStoreName(metadata.name) {
            var entry: [String: AnyCodable] = [
                "name": AnyCodable(metadata.name),
                "scopeKind": AnyCodable("team"),
                "scopeId": AnyCodable(""),
                "createdAtMs": AnyCodable(metadata.createdAtMs),
                "updatedAtMs": AnyCodable(metadata.updatedAtMs),
                "kind": AnyCodable(metadata.kind.rawValue),
            ]
            if let updatedBy = metadata.updatedBy {
                entry["updatedBy"] = AnyCodable(updatedBy)
            }
            switch metadata.kind {
            case .env:
                entry["value"] = AnyCodable(try await self.secretVault.loadSecret(for: metadata.name) ?? "")
            case .secret:
                entry["allowedHosts"] = AnyCodable(metadata.allowedHosts ?? [])
            }
            entries.append(AnyCodable(entry))
        }
        return AnyCodable(["entries": AnyCodable(entries)])
    }

    private func handleSecretsStoreSet(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let params = try request.decodeParams(SecretsStoreSetParams.self)
        try Self.validateSecretStoreName(params.name)
        guard params.value.utf8.count <= Self.secretStoreMaxValueBytes else {
            throw GatewayMethodError.invalidRequest("secrets.store.set value exceeds \(Self.secretStoreMaxValueBytes) bytes")
        }
        guard let kind = params.kind.stringValue.flatMap(GatewaySecretKind.init(rawValue:)) else {
            throw GatewayMethodError.invalidRequest("secrets.store.set kind must be \"secret\" or \"env\"")
        }
        if let hosts = params.allowedhosts {
            guard hosts.count <= 128, Set(hosts).count == hosts.count,
                  hosts.allSatisfy({ !$0.isEmpty && $0.count <= 253 })
            else {
                throw GatewayMethodError.invalidRequest("secrets.store.set allowedHosts must be at most 128 unique host names")
            }
        }
        let updatedBy = Self.normalizedText(request.connection.displayName)
            ?? Self.normalizedText(request.connection.clientID)
            ?? "gateway"
        try await self.secretVault.setSecret(
            params.value,
            for: params.name,
            kind: kind,
            allowedHosts: kind == .secret ? (params.allowedhosts ?? []) : nil,
            updatedBy: updatedBy
        )
        return try GatewayPayloadCodec.encode(SecretsStoreMutationResult(ok: true, reloaded: false))
    }

    private func handleSecretsStoreDelete(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let params = try request.decodeParams(SecretsStoreDeleteParams.self)
        try Self.validateSecretStoreName(params.name)
        _ = try await self.secretVault.deleteSecret(for: params.name)
        return try GatewayPayloadCodec.encode(SecretsStoreMutationResult(ok: true, reloaded: false))
    }

    static let secretStoreMaxValueBytes = 64 * 1024

    /// Upstream secret-store names match `^[A-Z][A-Z0-9_]{0,127}$`.
    static func isSecretStoreName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, scalars.count <= 128, ("A"..."Z").contains(first) else {
            return false
        }
        return scalars.dropFirst().allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    private static func validateSecretStoreName(_ name: String) throws {
        guard Self.isSecretStoreName(name) else {
            throw GatewayMethodError.invalidRequest("secret store name must match ^[A-Z][A-Z0-9_]{0,127}$")
        }
    }

    // MARK: - Browser

    private func handleBrowserRequest(_ request: GatewayMethodRequest) async throws -> GatewayBrowserResponse {
        guard let browserRequest = self.handlers.browserRequest else {
            throw GatewayMethodError.unavailable("Browser request handling is not configured for this gateway server")
        }
        let params = try request.decodeParams(GatewayBrowserRequestParams.self)
        let sanitized = try Self.sanitizedBrowserRequest(params)
        return try await browserRequest(sanitized)
    }

    // MARK: - Helpers

    /// Session summary of a record: the legacy fields plus the 2026.3.0 session fields
    /// (permission mode, trace level, organization state, …) with `Int64` timestamps.
    /// - Parameter record: Session record.
    /// - Returns: The session summary.
    public static func sessionInfo(from record: SessionRecord) -> GatewaySessionInfo {
        GatewaySessionInfo(
            key: record.key,
            agentID: record.agentID,
            updatedAtMs: record.updatedAtMs,
            channel: record.lastRoute?.channel,
            accountID: record.lastRoute?.accountID,
            peerID: record.lastRoute?.peerID,
            label: record.label,
            modelOverride: record.modelOverride,
            thinkingLevel: record.thinkingLevel?.rawValue,
            verboseLevel: record.verboseLevel?.rawValue,
            reasoningLevel: record.reasoningLevel?.rawValue,
            responseUsage: record.responseUsage?.rawValue,
            elevatedLevel: record.elevatedLevel?.rawValue,
            groupActivation: record.groupActivation?.rawValue,
            sendPolicy: record.sendPolicy?.rawValue,
            execHost: record.execHost?.rawValue,
            execSecurity: record.execSecurity?.rawValue,
            execAsk: record.execAsk?.rawValue,
            execNode: record.execNode,
            sessionID: record.sessionID,
            permissionMode: record.permissionMode?.rawValue,
            sandboxMode: record.sandboxMode,
            traceLevel: record.traceLevel?.rawValue,
            fastMode: record.fastModeSetting?.rawValue,
            archived: record.archived,
            pinned: record.pinned,
            unread: record.unread,
            archivedAtMs: record.archivedAtMs,
            pinnedAtMs: record.pinnedAtMs,
            markedUnreadAtMs: record.markedUnreadAtMs,
            lastReadAtMs: record.lastReadAtMs,
            createdAtMs: record.createdAtMs,
            autoLabel: record.autoLabel,
            icon: record.icon,
            color: record.color,
            category: record.category,
            contextWindow: record.contextWindow,
            agentRuntime: record.agentRuntime,
            spawnedBy: record.spawnedBy,
            spawnDepth: record.spawnDepth,
            parentSessionID: record.parentSessionID,
            totalTokens: record.totalTokens,
            toolOverrides: record.toolOverrides.flatMap { try? GatewayPayloadCodec.encode($0) }
        )
    }

    /// The full session record as an `entry` object (kept for compatibility).
    /// - Parameter record: Session record.
    /// - Returns: JSON object, or `null` when the record does not encode.
    public static func recordPayload(_ record: SessionRecord) -> AnyCodable {
        (try? AnyCodable(encoding: record)) ?? .nullValue
    }

    /// Mutation response `{ok, key, session?, deleted?, entry?}` shared by the session handlers.
    /// - Parameters:
    ///   - key: Session key.
    ///   - record: Updated record.
    ///   - deleted: Whether the session was deleted.
    /// - Returns: The payload.
    /// - Throws: Encoding errors.
    public static func mutationPayload(key: String, record: SessionRecord?, deleted: Bool? = nil) throws -> AnyCodable {
        try GatewayPayloadCodec.encode(
            GatewaySessionMutationResult(
                key: key,
                session: record.map(Self.sessionInfo(from:)),
                deleted: deleted,
                entry: record.map(Self.recordPayload)
            )
        )
    }

    static func requireSessionKey(_ request: GatewayMethodRequest) throws -> String {
        guard let key = request.stringParam("key", "sessionKey") else {
            throw GatewayMethodError.invalidRequest("\(request.method) requires a session key")
        }
        return key
    }

    static func sanitizedBrowserRequest(_ params: GatewayBrowserRequestParams) throws -> GatewayBrowserRequestParams {
        let method = params.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard method == "GET" || method == "POST" || method == "DELETE" else {
            throw GatewayMethodError.invalidRequest("Invalid browser.request method: \(params.method)")
        }
        let path = params.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/") else {
            throw GatewayMethodError.invalidRequest("browser.request path must start with '/'")
        }
        if Self.isBlockedBrowserProfileMutation(path: path, method: method) {
            throw GatewayMethodError.invalidRequest("browser.request cannot mutate browser profiles")
        }
        return GatewayBrowserRequestParams(
            method: method,
            path: path,
            query: params.query,
            body: params.body,
            timeoutMs: params.timeoutMs,
            workspaceRoot: nil,
            spawnedWorkspaceRoot: nil
        )
    }

    private static func isBlockedBrowserProfileMutation(path: String, method: String) -> Bool {
        let normalizedPath = path.lowercased()
        guard normalizedPath.contains("profile") else {
            return false
        }
        return method == "POST" || method == "DELETE"
    }

    static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

/// `models.list` payload whose rows carry both the legacy `GatewayModelCatalogEntry` keys and the
/// upstream `ModelChoice` required keys (`id`, `name`, `provider`), so either decoder accepts it.
private struct GatewayModelsListWirePayload: Encodable {
    let models: [GatewayModelsListWireRow]

    init(models: [GatewayModelCatalogEntry]) {
        self.models = models.map(GatewayModelsListWireRow.init(entry:))
    }
}

private struct GatewayModelsListWireRow: Encodable {
    let entry: GatewayModelCatalogEntry

    private enum CodingKeys: String, CodingKey {
        case providerID
        case modelID
        case displayName
        case api
        case authMode
        case id
        case name
        case provider
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.entry.providerID, forKey: .providerID)
        try container.encode(self.entry.modelID, forKey: .modelID)
        try container.encode(self.entry.displayName, forKey: .displayName)
        try container.encodeIfPresent(self.entry.api, forKey: .api)
        try container.encodeIfPresent(self.entry.authMode, forKey: .authMode)
        try container.encode(self.entry.modelID, forKey: .id)
        try container.encode(self.entry.displayName, forKey: .name)
        try container.encode(self.entry.providerID, forKey: .provider)
    }
}
