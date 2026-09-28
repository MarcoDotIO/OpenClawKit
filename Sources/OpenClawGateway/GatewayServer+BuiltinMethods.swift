import Foundation
import OpenClawCore
import OpenClawProtocol

// Built-in in-process handlers. Each accepts the legacy OpenClawKit payload shape and the upstream
// OpenClaw 2026.9.6 shape where the two overlap (for example `runId`/`runID`, `agentId`/`agentID`,
// `model`/`modelOverride`).
extension GatewayServer {
    func invokeBuiltin(_ builtin: BuiltinMethod, request: GatewayMethodRequest) async throws -> AnyCodable? {
        switch builtin {
        case .agentRun:
            return try GatewayPayloadCodec.encode(try await self.handleAgentRun(request))
        case .agentWait:
            return try GatewayPayloadCodec.encode(try await self.handleAgentWait(request))
        case .sessionsList:
            return try GatewayPayloadCodec.encode(GatewaySessionListResult(sessions: await self.listSessions()))
        case .sessionsGet:
            let params = try request.decodeParams(GatewaySessionGetParams.self)
            let record = await self.sessionStore.recordForKey(params.key)
            return try GatewayPayloadCodec.encode(GatewaySessionGetResult(session: record.map(Self.sessionInfo(from:))))
        case .sessionsPatch:
            return try GatewayPayloadCodec.encode(try await self.handleSessionPatch(request))
        case .sessionsReset:
            return try GatewayPayloadCodec.encode(try await self.handleSessionReset(request))
        case .sessionsDelete:
            return try GatewayPayloadCodec.encode(try await self.handleSessionDelete(request))
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
        }
    }

    // MARK: - Agent

    private func handleAgentRun(_ request: GatewayMethodRequest) async throws -> GatewayAgentAccepted {
        let params = try Self.agentRequest(from: request)
        let execution = try await self.handlers.runAgent(params)
        self.agentRuns[execution.runID] = execution.task
        return GatewayAgentAccepted(runID: execution.runID)
    }

    /// Decodes the legacy `GatewayAgentRequest` shape, falling back to (or enriching from) upstream `AgentParams`.
    static func agentRequest(from request: GatewayMethodRequest) throws -> GatewayAgentRequest {
        let legacy = Result { try GatewayPayloadCodec.decode(GatewayAgentRequest.self, from: request.rawParams) }
        let upstream = try? GatewayPayloadCodec.decode(AgentParams.self, from: request.rawParams)
        let upstreamTimeoutMs = upstream?.timeout.map { min(max($0, 0), Int.max / 1000) * 1000 }
        switch legacy {
        case .success(let legacy):
            guard let upstream else { return legacy }
            return GatewayAgentRequest(
                sessionKey: legacy.sessionKey,
                prompt: legacy.prompt,
                message: legacy.message ?? upstream.message,
                modelProviderID: legacy.modelProviderID ?? Self.normalizedText(upstream.provider),
                modelID: legacy.modelID ?? Self.normalizedText(upstream.model),
                timeoutMs: legacy.timeoutMs ?? upstreamTimeoutMs,
                deliver: legacy.deliver ?? upstream.deliver
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
                deliver: upstream.deliver
            )
        }
    }

    private func handleAgentWait(_ request: GatewayMethodRequest) async throws -> GatewayAgentWaitResult {
        let params = try request.decodeParams(GatewayAgentWaitParams.self)
        guard let task = self.agentRuns[params.runID] else {
            throw GatewayMethodError.unavailable("Agent run '\(params.runID)' is not tracked by this gateway server")
        }
        let result: GatewayAgentWaitResult
        if let timeoutMs = params.timeoutMs, timeoutMs > 0 {
            result = try await withThrowingTaskGroup(of: GatewayAgentWaitResult.self) { group in
                group.addTask {
                    try await task.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    return GatewayAgentWaitResult(runID: params.runID, status: "timeout")
                }
                let first = try await group.next() ?? GatewayAgentWaitResult(runID: params.runID, status: "timeout")
                group.cancelAll()
                return first
            }
        } else {
            result = try await task.value
        }
        if result.status == "ok" || result.status == "error" {
            self.agentRuns.removeValue(forKey: params.runID)
        }
        return result
    }

    // MARK: - Sessions

    private func listSessions() async -> [GatewaySessionInfo] {
        let records = await self.sessionStore.allRecords()
        return records.map(Self.sessionInfo(from:))
    }

    private func handleSessionPatch(_ request: GatewayMethodRequest) async throws -> GatewaySessionMutationResult {
        _ = try request.decodeParams(GatewaySessionPatchParams.self)
        let record = try await Self.applySessionPatch(request, store: self.sessionStore, defaultAgentID: self.defaultAgentID).record
        try await self.sessionStore.save()
        return GatewaySessionMutationResult(key: record.key, session: Self.sessionInfo(from: record))
    }

    /// Applies `sessions.patch` params through ``SessionStore/applyPatch(_:defaultAgentID:grantedScopes:)``,
    /// mapping patch errors to gateway errors (retired `execSecurity`/`execAsk` → `INVALID_REQUEST`,
    /// `permissionMode: full` without `operator.admin` → `FORBIDDEN`).
    static func applySessionPatch(
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

    private func handleSessionReset(_ request: GatewayMethodRequest) async throws -> GatewaySessionMutationResult {
        let params = try request.decodeParams(GatewaySessionKeyParams.self)
        guard let reset = await self.sessionStore.rotateSession(forKey: params.key) else {
            return GatewaySessionMutationResult(key: params.key, session: nil)
        }
        try await self.sessionStore.save()
        return GatewaySessionMutationResult(key: params.key, session: Self.sessionInfo(from: reset))
    }

    private func handleSessionDelete(_ request: GatewayMethodRequest) async throws -> GatewaySessionMutationResult {
        let params = try request.decodeParams(GatewaySessionKeyParams.self)
        let deleted = await self.sessionStore.deleteRecord(forKey: params.key)
        if deleted {
            try await self.sessionStore.save()
        }
        return GatewaySessionMutationResult(key: params.key, deleted: deleted)
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

    static func sessionInfo(from record: SessionRecord) -> GatewaySessionInfo {
        GatewaySessionInfo(
            key: record.key,
            agentID: record.agentID,
            updatedAtMs: Int(clamping: record.updatedAtMs),
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
            execNode: record.execNode
        )
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
