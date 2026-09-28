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
        let params = try request.decodeParams(GatewaySessionPatchParams.self)
        let raw = request.params
        let key = params.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw GatewayMethodError.invalidRequest("Session key must not be empty")
        }
        let agentID = Self.normalizedText(params.agentID) ?? request.stringParam("agentId")
        var record = await self.sessionStore.recordForKey(key) ?? SessionRecord(
            key: key,
            agentID: agentID ?? self.defaultAgentID,
            updatedAtMs: Self.nowMs()
        )
        record.updatedAtMs = Self.nowMs()
        if let agentID {
            record.agentID = agentID
        }
        // Upstream clears a field with an explicit JSON null; legacy clients omit unchanged fields.
        func isCleared(_ keys: String...) -> Bool {
            keys.contains { raw[$0]?.isNull == true }
        }
        if let label = params.label {
            record.label = Self.normalizedText(label)
        } else if isCleared("label") {
            record.label = nil
        }
        if let model = params.modelOverride ?? raw["model"]?.stringValue {
            record.modelOverride = Self.normalizedText(model)
        } else if isCleared("modelOverride", "model") {
            record.modelOverride = nil
        }
        if let fastMode = raw["fastMode"]?.boolValue {
            record.fastMode = fastMode
        } else if isCleared("fastMode") {
            record.fastMode = nil
        }
        if let thinkingLevel = params.thinkingLevel {
            record.thinkingLevel = ThinkLevel.normalize(thinkingLevel)
        } else if isCleared("thinkingLevel") {
            record.thinkingLevel = nil
        }
        if let verboseLevel = params.verboseLevel {
            record.verboseLevel = VerboseLevel.normalize(verboseLevel)
        } else if isCleared("verboseLevel") {
            record.verboseLevel = nil
        }
        if let reasoningLevel = params.reasoningLevel {
            record.reasoningLevel = ReasoningLevel.normalize(reasoningLevel)
        } else if isCleared("reasoningLevel") {
            record.reasoningLevel = nil
        }
        if let responseUsage = params.responseUsage {
            record.responseUsage = UsageDisplayLevel.normalize(responseUsage)
        } else if isCleared("responseUsage") {
            record.responseUsage = nil
        }
        if let elevatedLevel = params.elevatedLevel {
            record.elevatedLevel = ElevatedLevel.normalize(elevatedLevel)
        } else if isCleared("elevatedLevel") {
            record.elevatedLevel = nil
        }
        if let groupActivation = params.groupActivation {
            record.groupActivation = Self.normalizeGroupActivation(groupActivation)
        } else if isCleared("groupActivation") {
            record.groupActivation = nil
        }
        if let sendPolicy = params.sendPolicy {
            record.sendPolicy = Self.normalizeSendPolicy(sendPolicy)
        } else if isCleared("sendPolicy") {
            record.sendPolicy = nil
        }
        if let execHost = params.execHost {
            record.execHost = Self.normalizeExecHost(execHost)
        } else if isCleared("execHost") {
            record.execHost = nil
        }
        if let execSecurity = params.execSecurity {
            record.execSecurity = Self.normalizeExecSecurity(execSecurity)
        } else if isCleared("execSecurity") {
            record.execSecurity = nil
        }
        if let execAsk = params.execAsk {
            record.execAsk = Self.normalizeExecAsk(execAsk)
        } else if isCleared("execAsk") {
            record.execAsk = nil
        }
        if let execNode = params.execNode {
            record.execNode = Self.normalizedText(execNode)
        } else if isCleared("execNode") {
            record.execNode = nil
        }
        await self.sessionStore.upsert(record)
        try await self.sessionStore.save()
        return GatewaySessionMutationResult(key: key, session: Self.sessionInfo(from: record))
    }

    private func handleSessionReset(_ request: GatewayMethodRequest) async throws -> GatewaySessionMutationResult {
        let params = try request.decodeParams(GatewaySessionKeyParams.self)
        guard let existing = await self.sessionStore.recordForKey(params.key) else {
            return GatewaySessionMutationResult(key: params.key, session: nil)
        }
        let reset = SessionRecord(
            key: existing.key,
            agentID: existing.agentID,
            updatedAtMs: Self.nowMs(),
            lastRoute: existing.lastRoute
        )
        await self.sessionStore.upsert(reset)
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

    private static func normalizeSendPolicy(_ raw: String) -> SendPolicy? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "allow", "on", "true", "yes":
            return .allow
        case "deny", "off", "false", "no":
            return .deny
        default:
            return nil
        }
    }

    private static func normalizeGroupActivation(_ raw: String) -> GroupActivation? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "always":
            return .always
        case "mention", "mentions":
            return .mention
        default:
            return nil
        }
    }

    private static func normalizeExecHost(_ raw: String) -> ExecHost? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sandbox":
            return .sandbox
        case "gateway":
            return .gateway
        case "node":
            return .node
        default:
            return nil
        }
    }

    private static func normalizeExecSecurity(_ raw: String) -> ExecSecurity? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "") {
        case "deny":
            return .deny
        case "allowlist":
            return .allowlist
        case "full":
            return .full
        default:
            return nil
        }
    }

    private static func normalizeExecAsk(_ raw: String) -> ExecAsk? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "off":
            return .off
        case "on-miss", "onmiss":
            return .onMiss
        case "always":
            return .always
        default:
            return nil
        }
    }

    private static func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
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
