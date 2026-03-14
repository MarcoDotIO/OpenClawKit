import Foundation
import OpenClawCore
import OpenClawProtocol

/// Browser-request handler injected into the in-process gateway server.
public typealias GatewayBrowserRequestHandler = @Sendable (GatewayBrowserRequestParams) async throws -> GatewayBrowserResponse

/// Agent-run handler injected into the in-process gateway server.
public typealias GatewayAgentRunHandler = @Sendable (GatewayAgentRequest) async throws -> GatewayAgentExecution

/// Models-list handler injected into the in-process gateway server.
public typealias GatewayModelsListHandler = @Sendable () async throws -> [GatewayModelCatalogEntry]

/// Skills-list handler injected into the in-process gateway server.
public typealias GatewaySkillsListHandler = @Sendable () async throws -> [GatewaySkillDescriptor]

/// Skill-invoke handler injected into the in-process gateway server.
public typealias GatewaySkillInvokeHandler = @Sendable (GatewaySkillInvokeParams) async throws -> GatewaySkillInvokeResult

/// Long-running agent execution tracked by the gateway server.
public struct GatewayAgentExecution: Sendable {
    public let runID: String
    public let task: Task<GatewayAgentWaitResult, Error>

    public init(runID: String, task: Task<GatewayAgentWaitResult, Error>) {
        self.runID = runID
        self.task = task
    }
}

/// Closure-backed handlers used by `GatewayServer` for higher-level runtime features.
public struct GatewayServerHandlers: Sendable {
    public let runAgent: GatewayAgentRunHandler
    public let listModels: GatewayModelsListHandler
    public let listSkills: GatewaySkillsListHandler
    public let invokeSkill: GatewaySkillInvokeHandler
    public let browserRequest: GatewayBrowserRequestHandler?

    public init(
        runAgent: @escaping GatewayAgentRunHandler = { _ in
            throw OpenClawCoreError.unavailable("Agent execution is not configured for this gateway server")
        },
        listModels: @escaping GatewayModelsListHandler = {
            throw OpenClawCoreError.unavailable("Model catalog is not configured for this gateway server")
        },
        listSkills: @escaping GatewaySkillsListHandler = {
            throw OpenClawCoreError.unavailable("Skill listing is not configured for this gateway server")
        },
        invokeSkill: @escaping GatewaySkillInvokeHandler = { _ in
            throw OpenClawCoreError.unavailable("Skill invocation is not configured for this gateway server")
        },
        browserRequest: GatewayBrowserRequestHandler? = nil
    ) {
        self.runAgent = runAgent
        self.listModels = listModels
        self.listSkills = listSkills
        self.invokeSkill = invokeSkill
        self.browserRequest = browserRequest
    }
}

private struct GatewaySecretIndex: Codable, Sendable {
    let version: Int
    var keys: [String]
}

/// Small metadata wrapper that adds list semantics on top of `CredentialStore`.
public actor GatewaySecretVault {
    private let credentialStore: any CredentialStore
    private let indexURL: URL?
    private var keys: Set<String>

    public init(credentialStore: any CredentialStore, indexURL: URL? = nil) {
        self.credentialStore = credentialStore
        self.indexURL = indexURL
        self.keys = []
        if let indexURL, FileManager.default.fileExists(atPath: indexURL.path),
           let data = try? Data(contentsOf: indexURL),
           let payload = try? JSONDecoder().decode(GatewaySecretIndex.self, from: data)
        {
            self.keys = Set(payload.keys)
        }
    }

    public func listSecretKeys() -> [String] {
        self.keys.sorted()
    }

    public func setSecret(_ value: String, for key: String) async throws {
        let normalizedKey = try Self.normalizedKey(key)
        try await self.credentialStore.saveSecret(value, for: normalizedKey)
        self.keys.insert(normalizedKey)
        try self.persistIndexIfNeeded()
    }

    public func deleteSecret(for key: String) async throws -> Bool {
        let normalizedKey = try Self.normalizedKey(key)
        let existed = self.keys.contains(normalizedKey)
        try await self.credentialStore.deleteSecret(for: normalizedKey)
        self.keys.remove(normalizedKey)
        try self.persistIndexIfNeeded()
        return existed
    }

    private func persistIndexIfNeeded() throws {
        guard let indexURL else {
            return
        }
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = GatewaySecretIndex(version: 1, keys: self.keys.sorted())
        let data = try JSONEncoder().encode(payload)
        try data.write(to: indexURL, options: [.atomic])
    }

    private static func normalizedKey(_ key: String) throws -> String {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Secret key must not be empty")
        }
        return normalized
    }
}

/// In-process gateway dispatcher that fronts sessions, secrets, and injected runtime handlers.
public actor GatewayServer {
    private let sessionStore: SessionStore
    private let secretVault: GatewaySecretVault
    private let defaultAgentID: String
    private let handlers: GatewayServerHandlers
    private var agentRuns: [String: Task<GatewayAgentWaitResult, Error>] = [:]

    public init(
        sessionStore: SessionStore,
        secretVault: GatewaySecretVault,
        defaultAgentID: String = "main",
        handlers: GatewayServerHandlers = GatewayServerHandlers()
    ) {
        self.sessionStore = sessionStore
        self.secretVault = secretVault
        self.defaultAgentID = defaultAgentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : defaultAgentID
        self.handlers = handlers
    }

    /// Dispatches one gateway request frame to a typed response.
    /// - Parameter request: Raw request frame.
    /// - Returns: Encoded response frame.
    public func handle(_ request: RequestFrame) async -> ResponseFrame {
        do {
            switch request.method {
            case "agent", "agent.run":
                let payload = try await self.handleAgentRun(request.params, method: request.method)
                return try self.successResponse(id: request.id, payload: payload)
            case "agent.wait":
                let payload = try await self.handleAgentWait(request.params)
                return try self.successResponse(id: request.id, payload: payload)
            case "sessions.list":
                return try self.successResponse(
                    id: request.id,
                    payload: GatewaySessionListResult(sessions: await self.listSessions())
                )
            case "sessions.get":
                let params = try self.decodeParams(GatewaySessionGetParams.self, from: request.params, method: request.method)
                let record = await self.sessionStore.recordForKey(params.key)
                return try self.successResponse(
                    id: request.id,
                    payload: GatewaySessionGetResult(session: record.map(Self.sessionInfo(from:)))
                )
            case "sessions.patch":
                let payload = try await self.handleSessionPatch(request.params, method: request.method)
                return try self.successResponse(id: request.id, payload: payload)
            case "sessions.reset":
                let payload = try await self.handleSessionReset(request.params, method: request.method)
                return try self.successResponse(id: request.id, payload: payload)
            case "sessions.delete":
                let payload = try await self.handleSessionDelete(request.params, method: request.method)
                return try self.successResponse(id: request.id, payload: payload)
            case "models.list":
                return try self.successResponse(
                    id: request.id,
                    payload: GatewayModelsListResult(models: try await self.handlers.listModels())
                )
            case "skills.list":
                return try self.successResponse(
                    id: request.id,
                    payload: GatewaySkillsListResult(skills: try await self.handlers.listSkills())
                )
            case "skills.invoke":
                let params = try self.decodeParams(GatewaySkillInvokeParams.self, from: request.params, method: request.method)
                return try self.successResponse(id: request.id, payload: try await self.handlers.invokeSkill(params))
            case "secrets.list":
                let keys = await self.secretVault.listSecretKeys()
                let payload = GatewaySecretsListResult(
                    secrets: keys.map(GatewaySecretDescriptor.init(key:))
                )
                return try self.successResponse(id: request.id, payload: payload)
            case "secrets.set":
                let params = try self.decodeParams(GatewaySecretSetParams.self, from: request.params, method: request.method)
                try await self.secretVault.setSecret(params.value, for: params.key)
                return try self.successResponse(id: request.id, payload: GatewaySecretMutationResult(key: params.key))
            case "secrets.delete":
                let params = try self.decodeParams(GatewaySecretDeleteParams.self, from: request.params, method: request.method)
                let deleted = try await self.secretVault.deleteSecret(for: params.key)
                return try self.successResponse(
                    id: request.id,
                    payload: GatewaySecretMutationResult(key: params.key, deleted: deleted)
                )
            case "browser.request":
                let payload = try await self.handleBrowserRequest(request.params, method: request.method)
                return try self.successResponse(id: request.id, payload: payload)
            default:
                return self.errorResponse(
                    id: request.id,
                    code: .invalidRequest,
                    message: "Unsupported gateway method: \(request.method)"
                )
            }
        } catch {
            return self.errorResponse(
                id: request.id,
                code: Self.errorCode(for: error),
                message: error.localizedDescription
            )
        }
    }

    private func handleAgentRun(_ payload: AnyCodable?, method: String) async throws -> GatewayAgentAccepted {
        let params = try self.decodeParams(GatewayAgentRequest.self, from: payload, method: method)
        let execution = try await self.handlers.runAgent(params)
        self.agentRuns[execution.runID] = execution.task
        return GatewayAgentAccepted(runID: execution.runID)
    }

    private func handleAgentWait(_ payload: AnyCodable?) async throws -> GatewayAgentWaitResult {
        let params = try self.decodeParams(GatewayAgentWaitParams.self, from: payload, method: "agent.wait")
        guard let task = self.agentRuns[params.runID] else {
            throw OpenClawCoreError.unavailable("Agent run '\(params.runID)' is not tracked by this gateway server")
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

    private func listSessions() async -> [GatewaySessionInfo] {
        let records = await self.sessionStore.allRecords()
        return records.map(Self.sessionInfo(from:))
    }

    private func handleSessionPatch(_ payload: AnyCodable?, method: String) async throws -> GatewaySessionMutationResult {
        let params = try self.decodeParams(GatewaySessionPatchParams.self, from: payload, method: method)
        let key = params.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Session key must not be empty")
        }
        var record = await self.sessionStore.recordForKey(key) ?? SessionRecord(
            key: key,
            agentID: Self.normalizedText(params.agentID) ?? self.defaultAgentID,
            updatedAtMs: Self.nowMs()
        )
        record.updatedAtMs = Self.nowMs()
        if let agentID = Self.normalizedText(params.agentID) {
            record.agentID = agentID
        }
        if let label = params.label {
            record.label = Self.normalizedText(label)
        }
        if let modelOverride = params.modelOverride {
            record.modelOverride = Self.normalizedText(modelOverride)
        }
        if let thinkingLevel = params.thinkingLevel {
            record.thinkingLevel = ThinkLevel.normalize(thinkingLevel)
        }
        if let verboseLevel = params.verboseLevel {
            record.verboseLevel = VerboseLevel.normalize(verboseLevel)
        }
        if let reasoningLevel = params.reasoningLevel {
            record.reasoningLevel = ReasoningLevel.normalize(reasoningLevel)
        }
        if let responseUsage = params.responseUsage {
            record.responseUsage = UsageDisplayLevel.normalize(responseUsage)
        }
        if let elevatedLevel = params.elevatedLevel {
            record.elevatedLevel = ElevatedLevel.normalize(elevatedLevel)
        }
        if let groupActivation = params.groupActivation {
            record.groupActivation = Self.normalizeGroupActivation(groupActivation)
        }
        if let sendPolicy = params.sendPolicy {
            record.sendPolicy = Self.normalizeSendPolicy(sendPolicy)
        }
        if let execHost = params.execHost {
            record.execHost = Self.normalizeExecHost(execHost)
        }
        if let execSecurity = params.execSecurity {
            record.execSecurity = Self.normalizeExecSecurity(execSecurity)
        }
        if let execAsk = params.execAsk {
            record.execAsk = Self.normalizeExecAsk(execAsk)
        }
        if let execNode = params.execNode {
            record.execNode = Self.normalizedText(execNode)
        }
        await self.sessionStore.upsert(record)
        try await self.sessionStore.save()
        return GatewaySessionMutationResult(key: key, session: Self.sessionInfo(from: record))
    }

    private func handleSessionReset(_ payload: AnyCodable?, method: String) async throws -> GatewaySessionMutationResult {
        let params = try self.decodeParams(GatewaySessionKeyParams.self, from: payload, method: method)
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

    private func handleSessionDelete(_ payload: AnyCodable?, method: String) async throws -> GatewaySessionMutationResult {
        let params = try self.decodeParams(GatewaySessionKeyParams.self, from: payload, method: method)
        let deleted = await self.sessionStore.deleteRecord(forKey: params.key)
        if deleted {
            try await self.sessionStore.save()
        }
        return GatewaySessionMutationResult(key: params.key, deleted: deleted)
    }

    private func handleBrowserRequest(_ payload: AnyCodable?, method: String) async throws -> GatewayBrowserResponse {
        guard let browserRequest = self.handlers.browserRequest else {
            throw OpenClawCoreError.unavailable("Browser request handling is not configured for this gateway server")
        }
        let params = try self.decodeParams(GatewayBrowserRequestParams.self, from: payload, method: method)
        let sanitized = try Self.sanitizedBrowserRequest(params)
        return try await browserRequest(sanitized)
    }

    private func decodeParams<T: Decodable>(_ type: T.Type, from payload: AnyCodable?, method: String) throws -> T {
        do {
            return try GatewayPayloadCodec.decode(type, from: payload)
        } catch {
            throw OpenClawCoreError.invalidConfiguration("Invalid \(method) params: \(error)")
        }
    }

    private func successResponse<T: Encodable>(id: String, payload: T) throws -> ResponseFrame {
        ResponseFrame(
            type: "res",
            id: id,
            ok: true,
            payload: try GatewayPayloadCodec.encode(payload),
            error: nil
        )
    }

    private func errorResponse(id: String, code: ErrorCode, message: String) -> ResponseFrame {
        let errorShape = ErrorShape(
            code: code.rawValue,
            message: message,
            details: nil,
            retryable: nil,
            retryafterms: nil
        )
        let errorPayload: [String: AnyCodable]?
        if let encoded = try? GatewayPayloadCodec.encode(errorShape), case .object(let object) = encoded.value {
            errorPayload = object
        } else {
            errorPayload = [
                "code": AnyCodable(code.rawValue),
                "message": AnyCodable(message),
            ]
        }
        return ResponseFrame(
            type: "res",
            id: id,
            ok: false,
            payload: nil,
            error: errorPayload
        )
    }

    private static func errorCode(for error: Error) -> ErrorCode {
        if let error = error as? OpenClawCoreError {
            switch error {
            case .invalidConfiguration:
                return .invalidRequest
            case .unavailable:
                return .unavailable
            }
        }
        return .unavailable
    }

    private static func sessionInfo(from record: SessionRecord) -> GatewaySessionInfo {
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

    private static func sanitizedBrowserRequest(_ params: GatewayBrowserRequestParams) throws -> GatewayBrowserRequestParams {
        let method = params.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard method == "GET" || method == "POST" || method == "DELETE" else {
            throw OpenClawCoreError.invalidConfiguration("Invalid browser.request method: \(params.method)")
        }
        let path = params.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/") else {
            throw OpenClawCoreError.invalidConfiguration("browser.request path must start with '/'")
        }
        if Self.isBlockedBrowserProfileMutation(path: path, method: method) {
            throw OpenClawCoreError.invalidConfiguration("browser.request cannot mutate browser profiles")
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

    private static func normalizedText(_ value: String?) -> String? {
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
