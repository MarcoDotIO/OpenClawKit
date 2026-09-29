import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

/// Options for ``EmbeddedAgentRuntime/attach(to:options:)``.
public struct AgentGatewayOptions: Sendable, Equatable {
    /// Forward runtime `AgentEventFrame`s as `agent` gateway events.
    public var forwardAgentEvents: Bool
    /// Forward approval changes as `exec.approval.*` / `plugin.approval.*` events.
    public var forwardApprovalEvents: Bool
    /// Forward question changes as `question.requested` / `question.resolved` events.
    public var forwardQuestionEvents: Bool
    /// Project runs onto protocol-v4 `chat` events (`status`, `delta`, `final`, `aborted`, `error`).
    public var forwardChatEvents: Bool
    /// Emit `session.message` / `session.tool` for subscribed sessions and lifecycle `sessions.changed`.
    public var forwardSessionEvents: Bool
    /// Default timeout (ms) of runs started by `agent`, `sessions.send` or `chat.send` (`nil` = no timeout).
    public var runTimeoutMs: Int?

    /// Creates options.
    /// - Parameters:
    ///   - forwardAgentEvents: Forward `agent` events.
    ///   - forwardApprovalEvents: Forward approval events.
    ///   - forwardQuestionEvents: Forward question events.
    ///   - forwardChatEvents: Project runs onto `chat` events.
    ///   - forwardSessionEvents: Emit `session.message`, `session.tool` and lifecycle `sessions.changed`.
    ///   - runTimeoutMs: Default run timeout.
    public init(
        forwardAgentEvents: Bool = true,
        forwardApprovalEvents: Bool = true,
        forwardQuestionEvents: Bool = true,
        forwardChatEvents: Bool = true,
        forwardSessionEvents: Bool = true,
        runTimeoutMs: Int? = nil
    ) {
        self.forwardAgentEvents = forwardAgentEvents
        self.forwardApprovalEvents = forwardApprovalEvents
        self.forwardQuestionEvents = forwardQuestionEvents
        self.forwardChatEvents = forwardChatEvents
        self.forwardSessionEvents = forwardSessionEvents
        self.runTimeoutMs = runTimeoutMs
    }
}

public extension EmbeddedAgentRuntime {
    /// Methods registered by ``registerGatewayMethods(on:fallbacks:options:)``.
    static let gatewayMethodNames: [String] = [
        "agent", "sessions.create", "sessions.send", "sessions.steer", "sessions.abort", "sessions.compact",
        "sessions.patch", "sessions.reset", "sessions.delete",
        "chat.history", "chat.send", "chat.abort", "agent.wait",
        "approval.get", "approval.resolve", "approval.history",
        "exec.approval.get", "exec.approval.list", "exec.approval.request", "exec.approval.waitDecision",
        "exec.approval.resolve", "exec.approval.grants.list", "exec.approval.grants.revoke",
        "plugin.approval.list", "plugin.approval.request", "plugin.approval.waitDecision", "plugin.approval.resolve",
        "question.request", "question.waitAnswer", "question.resolve", "question.get", "question.list",
    ]

    /// Registers every runtime handler on an in-process gateway server and bridges runtime events
    /// into the server's event stream.
    ///
    /// Registers ``gatewayMethodNames``, the tool inventory methods (``toolGatewayMethodNames``) and
    /// the transcript DAG / search methods (``sessionBranchGatewayMethodNames``). One subscription to
    /// ``events(bufferingNewest:)`` feeds `agent`, `chat` (protocol v4), `session.tool`,
    /// `session.message` and lifecycle `sessions.changed` events; approvals and questions forward as
    /// `exec.approval.*` / `plugin.approval.*` and `question.*`.
    /// - Parameters:
    ///   - server: Gateway server.
    ///   - options: Bridging options.
    func attach(to server: GatewayServer, options: AgentGatewayOptions = AgentGatewayOptions()) async {
        let fallbacks = AgentGatewayFallbacks(
            agentWait: await server.builtinHandler(for: "agent.wait")
        )
        await self.registerGatewayMethods(on: server, fallbacks: fallbacks, options: options)
        await self.registerToolGatewayMethods(on: server)
        await self.registerSessionBranchGatewayMethods(on: server)
        if options.forwardAgentEvents || options.forwardChatEvents || options.forwardSessionEvents {
            let bridge = AgentGatewayEventBridge(runtime: self, server: server, options: options)
            let events = self.events(bufferingNewest: 4096)
            Task { [weak server] in
                for await frame in events {
                    guard server != nil else { return }
                    await bridge.handle(frame)
                }
            }
        }
        if options.forwardApprovalEvents {
            await self.approvals.addListener { [weak server] approval in
                guard let server else { return }
                let family = approval.kind == .exec ? "exec" : "plugin"
                let phase = approval.state == .pending ? "requested" : "resolved"
                await server.broadcast(event: "\(family).approval.\(phase)", payload: AnyCodable(approval.snapshotPayload))
            }
        }
        if options.forwardQuestionEvents {
            await self.questions.addListener { [weak server] question in
                guard let server else { return }
                if question.status == .pending {
                    await server.broadcast(event: GatewayEventName.questionRequested.rawValue, payload: AnyCodable(question.payload))
                } else {
                    await server.broadcast(event: GatewayEventName.questionResolved.rawValue, payload: AnyCodable(question.resolvedEventPayload))
                }
            }
        }
    }

    /// Registers session, chat, approval and question handlers on a registrar.
    ///
    /// Upstream wire keys are accepted (`key`/`sessionKey`, `runId`); `sessions.patch`, `sessions.reset`
    /// and `sessions.delete` replace the gateway built-ins so permission-mode changes cancel pending
    /// approvals and transcripts rotate or disappear with their sessions. Session mutations emit
    /// `sessions.changed`; `agent`, `sessions.create`, `sessions.send` and `chat.send` honor
    /// `idempotencyKey` (the key becomes the run id, as upstream, and a retry within 10 minutes returns
    /// the first answer).
    /// - Parameters:
    ///   - registrar: Target registrar (usually a ``GatewayServer``).
    ///   - fallbacks: Built-in handlers to fall back to (for runs this runtime does not own).
    ///   - options: Run options.
    func registerGatewayMethods(
        on registrar: some GatewayMethodRegistrar,
        fallbacks: AgentGatewayFallbacks = AgentGatewayFallbacks(),
        options: AgentGatewayOptions = AgentGatewayOptions()
    ) async {
        let handlers = AgentGatewayHandlers(
            runtime: self,
            fallbacks: fallbacks,
            options: options,
            idempotency: GatewayIdempotencyCache(),
            sessionGroups: (registrar as? GatewayServer)?.sessionGroups
        )
        for (method, handler) in handlers.table() {
            await registrar.register(method: method, descriptor: nil, handler: handler)
        }
    }
}

/// Built-in handlers the runtime's handlers fall back to.
public struct AgentGatewayFallbacks: Sendable {
    /// Built-in `agent.wait` (runs started by the gateway's own `agent` handler).
    public var agentWait: GatewayMethodHandler?

    /// Creates fallbacks.
    /// - Parameter agentWait: Built-in `agent.wait` handler.
    public init(agentWait: GatewayMethodHandler? = nil) {
        self.agentWait = agentWait
    }
}

/// Decodes upstream attachment objects (`{type?, mimeType?, fileName?, content|data}`, base64 or a
/// `data:` URL) into runtime ``MediaAttachment``s; entries without decodable bytes are skipped.
enum AgentGatewayAttachments {
    static func decode(_ raw: [AnyCodable]?) -> [MediaAttachment] {
        guard let raw else { return [] }
        return raw.compactMap { value in
            guard let object = value.dictionaryValue else { return nil }
            var mimeType = object["mimeType"]?.stringValue ?? object["mediaType"]?.stringValue
            guard var encoded = object["content"]?.stringValue ?? object["data"]?.stringValue else { return nil }
            if encoded.hasPrefix("data:"), let comma = encoded.firstIndex(of: ",") {
                let header = encoded[encoded.index(encoded.startIndex, offsetBy: 5)..<comma]
                if mimeType == nil, let type = header.split(separator: ";").first, !type.isEmpty {
                    mimeType = String(type)
                }
                encoded = String(encoded[encoded.index(after: comma)...])
            }
            guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else { return nil }
            let kind = object["type"]?.stringValue
            let resolvedType = mimeType ?? (kind == "image" ? "image/png" : "application/octet-stream")
            return MediaAttachment(mimeType: resolvedType, data: data, fileName: object["fileName"]?.stringValue)
        }
    }
}

struct AgentGatewayHandlers: Sendable {
    let runtime: EmbeddedAgentRuntime
    let fallbacks: AgentGatewayFallbacks
    let options: AgentGatewayOptions
    let idempotency: GatewayIdempotencyCache
    let sessionGroups: GatewaySessionGroupCatalog?

    func table() -> [(String, GatewayMethodHandler)] {
        [
            ("agent", { try await self.agent($0) }),
            ("sessions.create", { try await self.sessionsCreate($0) }),
            ("sessions.send", { try await self.sessionsSend($0, steer: false) }),
            ("sessions.steer", { try await self.sessionsSend($0, steer: true) }),
            ("sessions.abort", { try await self.sessionsAbort($0) }),
            ("sessions.compact", { try await self.sessionsCompact($0) }),
            ("sessions.patch", { try await self.sessionsPatch($0) }),
            ("sessions.reset", { try await self.sessionsReset($0) }),
            ("sessions.delete", { try await self.sessionsDelete($0) }),
            ("chat.history", { try await self.chatHistory($0) }),
            ("chat.send", { try await self.chatSend($0) }),
            ("chat.abort", { try await self.chatAbort($0) }),
            ("agent.wait", { try await self.agentWait($0) }),
            ("approval.get", { try await self.approvalGet($0) }),
            ("approval.resolve", { try await self.approvalResolve($0, kind: nil) }),
            ("approval.history", { try await self.approvalHistory($0) }),
            ("exec.approval.get", { try await self.legacyApprovalGet($0) }),
            ("exec.approval.list", { _ in await self.legacyApprovalList(kind: .exec) }),
            ("exec.approval.request", { try await self.legacyApprovalRequest($0, kind: .exec) }),
            ("exec.approval.waitDecision", { try await self.legacyApprovalWait($0) }),
            ("exec.approval.resolve", { try await self.approvalResolve($0, kind: .exec) }),
            ("exec.approval.grants.list", { try await self.grantsList($0) }),
            ("exec.approval.grants.revoke", { try await self.grantsRevoke($0) }),
            ("plugin.approval.list", { _ in await self.legacyApprovalList(kind: .plugin) }),
            ("plugin.approval.request", { try await self.legacyApprovalRequest($0, kind: .plugin) }),
            ("plugin.approval.waitDecision", { try await self.legacyApprovalWait($0) }),
            ("plugin.approval.resolve", { try await self.approvalResolve($0, kind: .plugin) }),
            ("question.request", { try await self.questionRequest($0) }),
            ("question.waitAnswer", { try await self.questionWait($0) }),
            ("question.resolve", { try await self.questionResolve($0) }),
            ("question.get", { try await self.questionGet($0) }),
            ("question.list", { _ in AnyCodable(["questions": AnyCodable(await self.runtime.questions.list().map { AnyCodable($0.payload) })]) }),
        ]
    }

    // MARK: - Helpers

    private func requireSessionKey(_ request: GatewayMethodRequest) throws -> String {
        guard let key = request.stringParam("key", "sessionKey")?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw GatewayMethodError.invalidRequest("\(request.method) requires a session key")
        }
        return key
    }

    private func requireString(_ request: GatewayMethodRequest, _ keys: String...) throws -> String {
        for key in keys {
            if let value = request.params[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        throw GatewayMethodError.invalidRequest("\(request.method) requires \(keys.first ?? "a value")")
    }

    private func requireSessionStore() throws -> SessionStore {
        guard let store = self.runtime.sessionStore else {
            throw GatewayMethodError.unavailable("This runtime has no session store")
        }
        return store
    }

    private static func object(_ payload: [String: AnyCodable]) -> AnyCodable {
        AnyCodable(payload)
    }

    private func emitSessionsChanged(_ request: GatewayMethodRequest, key: String, record: SessionRecord?, reason: String) async {
        await request.events.emit(
            .sessionsChanged,
            payload: GatewayServer.sessionsChangedPayload(sessionKey: key, record: record, reason: reason)
        )
    }

    private func registerGroup(of record: SessionRecord) async {
        if let category = record.category {
            await self.sessionGroups?.register(category)
        }
    }

    /// Starts a runtime run; the idempotency key (when present) becomes the run id, as upstream.
    private func startRun(
        sessionKey: String,
        message: String,
        request: GatewayMethodRequest,
        record: SessionRecord?,
        overrides: GatewayAgentRequest? = nil
    ) async -> String {
        let thinking = ThinkLevel.normalize(overrides?.thinking ?? request.params["thinking"]?.stringValue) ?? record?.thinkingLevel
        let timeoutMs = overrides?.timeoutMs ?? request.params["timeoutMs"]?.intValue ?? self.options.runTimeoutMs
        let model = record?.modelOverride
        let parts = model?.split(separator: "/", maxSplits: 1).map(String.init) ?? []
        let idempotencyKey = overrides?.idempotencyKey ?? request.stringParam("idempotencyKey")
        let attachments = AgentGatewayAttachments.decode(overrides?.attachments ?? request.params["attachments"]?.arrayValue)
        let run = AgentRunRequest(
            runID: idempotencyKey ?? UUID().uuidString.lowercased(),
            sessionKey: sessionKey,
            prompt: message,
            modelProviderID: overrides?.modelProviderID ?? (parts.count == 2 ? parts[0] : nil),
            modelID: overrides?.modelID ?? (parts.count == 2 ? parts[1] : model),
            thinkingLevel: thinking,
            reasoningLevel: record?.reasoningLevel,
            verboseLevel: record?.verboseLevel,
            responseUsage: record?.responseUsage,
            elevatedLevel: record?.elevatedLevel,
            fastMode: record?.fastMode,
            workspaceRootPath: overrides?.cwd,
            attachments: attachments,
            agentID: record?.agentID ?? overrides?.agentID ?? request.stringParam("agentId"),
            extraSystemPrompt: overrides?.extraSystemPrompt,
            spawnedBy: record?.spawnedBy
        )
        return await self.runtime.start(run, timeoutMs: timeoutMs, streaming: true)
    }

    // MARK: - Agent

    /// `agent` (upstream `AgentParams`): `{runId, status: "accepted", sessionKey, agentId, acceptedAt}`.
    private func agent(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let params = try GatewayServer.agentRequest(from: request)
        guard let message = params.text else {
            throw GatewayMethodError.invalidRequest("agent requires message")
        }
        return try await self.idempotency.run(key: params.idempotencyKey.map { "agent:\($0)" }) {
            let agentID = SessionKey.normalizeAgentID(params.agentID ?? SessionKey.agentID(from: params.sessionKey, fallback: self.runtime.defaultAgentID))
            var record = await self.runtime.sessionStore?.resolveOrCreate(sessionKey: params.sessionKey, defaultAgentID: agentID, route: nil)
            if let label = params.label, record?.label != label {
                record = await self.runtime.sessionStore?.update(forKey: params.sessionKey) { $0.label = label } ?? record
            }
            let acceptedAt = SessionTranscriptClock.nowMs()
            let runID = await self.startRun(sessionKey: params.sessionKey, message: message, request: request, record: record, overrides: params)
            return try GatewayPayloadCodec.encode(
                GatewayAgentAccepted(runID: runID, sessionKey: params.sessionKey, agentID: record?.agentID ?? agentID, acceptedAt: acceptedAt)
            )
        }
    }

    // MARK: - Sessions

    private func sessionsCreate(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let store = try self.requireSessionStore()
        return try await self.idempotency.run(key: request.stringParam("idempotencyKey").map { "sessions.create:\($0)" }) {
            try await self.createSession(request, store: store)
        }
    }

    private func createSession(_ request: GatewayMethodRequest, store: SessionStore) async throws -> AnyCodable? {
        let agentID = SessionKey.normalizeAgentID(request.stringParam("agentId") ?? self.runtime.defaultAgentID)
        let key = request.stringParam("key") ?? GatewayServer.generatedSessionKey(agentID: agentID)
        var raw = request.params
        raw["key"] = AnyCodable(key)
        for field in GatewayServer.sessionCreateNonPatchFields {
            raw[field] = nil
        }
        let outcome = try await GatewayServer.applySessionPatch(
            GatewayMethodRequest(
                id: request.id,
                method: "sessions.patch",
                rawParams: AnyCodable(raw),
                descriptor: request.descriptor,
                connection: request.connection,
                events: request.events
            ),
            store: store,
            defaultAgentID: agentID
        )
        var record = outcome.record
        let parent = request.stringParam("parentSessionKey")
        let spawnDepth = request.params["spawnDepth"]?.intValue
        if parent != nil || spawnDepth != nil {
            record = await store.update(forKey: key) { record in
                if let parent { record.spawnedBy = parent }
                if let spawnDepth { record.spawnDepth = spawnDepth }
            } ?? record
        }
        if record.sessionID == nil {
            record = await store.resolveOrCreate(sessionKey: key, defaultAgentID: agentID, route: nil)
        }
        try? await store.save()
        await self.registerGroup(of: record)
        var payload: [String: AnyCodable] = [
            "ok": AnyCodable(true),
            "key": AnyCodable(key),
            "sessionId": AnyCodable(record.sessionID),
            "entry": GatewayServer.recordPayload(record),
            "session": (try? GatewayPayloadCodec.encode(GatewayServer.sessionInfo(from: record))) ?? .nullValue,
        ]
        await self.emitSessionsChanged(request, key: key, record: record, reason: "create")
        if let message = (request.stringParam("message") ?? request.stringParam("task"))?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty
        {
            let runID = await self.startRun(sessionKey: key, message: message, request: request, record: record)
            payload["runStarted"] = AnyCodable(true)
            payload["runId"] = AnyCodable(runID)
        }
        return Self.object(payload)
    }

    /// `sessions.send` / `sessions.steer` → `{ok, key, runId, status: "started", runStarted: true}`.
    private func sessionsSend(_ request: GatewayMethodRequest, steer: Bool) async throws -> AnyCodable? {
        let key = try self.requireSessionKey(request)
        let message = try self.requireString(request, "message", "text")
        let idempotencyKey = request.stringParam("idempotencyKey").map { "\(request.method):\(key):\($0)" }
        return try await self.idempotency.run(key: idempotencyKey) {
            if steer {
                // Steering interrupts the active run and continues with the new message.
                await self.runtime.abort(sessionKey: key)
            }
            let record = await self.runtime.sessionStore?.resolveOrCreate(
                sessionKey: key,
                defaultAgentID: request.stringParam("agentId") ?? self.runtime.defaultAgentID,
                route: nil
            )
            let runID = await self.startRun(sessionKey: key, message: message, request: request, record: record)
            return Self.object([
                "ok": AnyCodable(true),
                "key": AnyCodable(key),
                "runId": AnyCodable(runID),
                "status": AnyCodable("started"),
                "runStarted": AnyCodable(true),
            ])
        }
    }

    /// `sessions.abort {key?, runId?}` → `{ok, abortedRunId, status: "aborted" | "no-active-run"}`
    /// (plus `aborted`/`runIds`). Runs the runtime does not own fall back to the built-in abort.
    private func sessionsAbort(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        var aborted: [String] = []
        if let runID = request.stringParam("runId", "runID") {
            if await self.runtime.abort(runID: runID) {
                aborted.append(runID)
            }
        } else {
            let key = try self.requireSessionKey(request)
            aborted = await self.runtime.abort(sessionKey: key)
        }
        return GatewayServer.abortPayload(abortedRunIDs: aborted)
    }

    private func sessionsCompact(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let key = try self.requireSessionKey(request)
        do {
            let result = try await self.runtime.compact(sessionKey: key, customInstructions: request.stringParam("instructions", "focus"))
            var payload: [String: AnyCodable] = [
                "ok": AnyCodable(result.ok),
                "key": AnyCodable(key),
                "compacted": AnyCodable(result.compacted),
                "tokensBefore": AnyCodable(result.tokensBefore),
            ]
            if let reason = result.reason { payload["reason"] = AnyCodable(reason) }
            if let tokensAfter = result.tokensAfter { payload["tokensAfter"] = AnyCodable(tokensAfter) }
            if let firstKept = result.firstKeptEntryId { payload["firstKeptEntryId"] = AnyCodable(firstKept) }
            if result.compacted {
                let record = await self.runtime.sessionStore?.recordForKey(key)
                await request.events.emit(
                    .sessionsChanged,
                    payload: GatewayServer.sessionsChangedPayload(sessionKey: key, record: record, reason: "compact", extra: ["compacted": AnyCodable(true)])
                )
            }
            return Self.object(payload)
        } catch AgentRuntimeError.transcriptUnavailable {
            throw GatewayMethodError.unavailable("sessions.compact requires a transcript store")
        }
    }

    private func sessionsPatch(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let store = try self.requireSessionStore()
        let outcome = try await GatewayServer.applySessionPatch(request, store: store, defaultAgentID: self.runtime.defaultAgentID)
        try? await store.save()
        if outcome.permissionModeChanged, !outcome.created {
            // Pending approvals from the old permissions are cancelled, not granted.
            await self.runtime.approvals.cancel(sessionKey: outcome.record.key)
        }
        await self.registerGroup(of: outcome.record)
        await self.emitSessionsChanged(request, key: outcome.record.key, record: outcome.record, reason: outcome.created ? "create" : "patch")
        return try GatewayServer.mutationPayload(key: outcome.record.key, record: outcome.record)
    }

    private func sessionsReset(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let key = try self.requireSessionKey(request)
        let reason = request.params["reason"]?.stringValue.flatMap(SessionResetReason.init(rawValue:)) ?? .reset
        let record = try await self.runtime.resetSession(sessionKey: key, reason: reason)
        await self.emitSessionsChanged(request, key: key, record: record, reason: "reset")
        return try GatewayServer.mutationPayload(key: key, record: record)
    }

    /// `sessions.delete` → `{ok, key, deleted, archived: []}` (upstream `SessionsDeleteResult`).
    private func sessionsDelete(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let key = try self.requireSessionKey(request)
        let existing = await self.runtime.sessionStore?.recordForKey(key)
        if request.params["archivedOnly"]?.boolValue == true, existing?.archived != true {
            throw GatewayMethodError.invalidRequest("sessions.delete archivedOnly requires an archived session")
        }
        let deleted = try await self.runtime.deleteSession(sessionKey: key)
        if deleted {
            var extra: [String: AnyCodable] = [:]
            if let existing { extra["agentId"] = AnyCodable(existing.agentID) }
            await request.events.emit(
                .sessionsChanged,
                payload: GatewayServer.sessionsChangedPayload(sessionKey: key, record: nil, reason: "delete", extra: extra)
            )
        }
        return try GatewayPayloadCodec.encode(GatewaySessionMutationResult(key: key, deleted: deleted, archived: []))
    }

    // MARK: - Chat

    private func chatHistory(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let key = try self.requireSessionKey(request)
        do {
            let messages = try await self.runtime.history(sessionKey: key, limit: request.params["limit"]?.intValue)
            let sessionID = await self.runtime.transcriptSessionID(for: key)
            return Self.object([
                "sessionKey": AnyCodable(key),
                "sessionId": AnyCodable(sessionID),
                "messages": try AnyCodable(encoding: messages),
            ])
        } catch AgentRuntimeError.transcriptUnavailable {
            return Self.object(["sessionKey": AnyCodable(key), "messages": AnyCodable([AnyCodable]())])
        }
    }

    /// `chat.send {sessionKey, message, idempotencyKey, …}` → `{runId, status: "in_flight"}`; the
    /// idempotency key is the run id (upstream `clientRunId`), so `chat` events match before the ack.
    private func chatSend(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let key = try self.requireSessionKey(request)
        let message = try self.requireString(request, "message")
        return try await self.idempotency.run(key: request.stringParam("idempotencyKey").map { "chat.send:\($0)" }) {
            let record = await self.runtime.sessionStore?.resolveOrCreate(
                sessionKey: key,
                defaultAgentID: request.stringParam("agentId") ?? self.runtime.defaultAgentID,
                route: nil
            )
            let runID = await self.startRun(sessionKey: key, message: message, request: request, record: record)
            return Self.object(["runId": AnyCodable(runID), "status": AnyCodable("in_flight")])
        }
    }

    /// `chat.abort {sessionKey, runId?}` → `{ok, aborted, runIds}` (upstream chat-abort handler).
    private func chatAbort(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        var aborted: [String] = []
        if let runID = request.stringParam("runId", "runID") {
            if await self.runtime.abort(runID: runID) {
                aborted.append(runID)
            }
        } else {
            let key = try self.requireSessionKey(request)
            aborted = await self.runtime.abort(sessionKey: key)
        }
        return Self.object([
            "ok": AnyCodable(true),
            "aborted": AnyCodable(!aborted.isEmpty),
            "runIds": AnyCodable(aborted.map { AnyCodable($0) }),
        ])
    }

    /// `agent.wait {runId, timeoutMs?}` → `{runId, status, startedAt, endedAt?, error?, sessionKey, output?}`.
    private func agentWait(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let params = try request.decodeParams(GatewayAgentWaitParams.self)
        guard let result = await self.runtime.wait(runID: params.runID, timeoutMs: params.timeoutMs) else {
            if let fallback = self.fallbacks.agentWait {
                return try await fallback(request)
            }
            throw GatewayMethodError.unavailable("Agent run '\(params.runID)' is not tracked by this gateway server")
        }
        return try GatewayPayloadCodec.encode(
            GatewayAgentWaitResult(
                runID: result.runID,
                status: result.status,
                sessionKey: result.sessionKey,
                output: result.output,
                error: result.error,
                startedAt: result.startedAt,
                endedAt: result.endedAt
            )
        )
    }

    // MARK: - Approvals

    private static func decision(_ raw: String?) throws -> ApprovalDecision {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "allow-once", "allow", "approve", "approved", "once":
            return .allowOnce
        case "allow-always", "always":
            return .allowAlways
        case "deny", "denied", "reject":
            return .deny
        default:
            throw GatewayMethodError.invalidRequest("invalid decision (use allow-once|allow-always|deny)")
        }
    }

    private static func reviewer(_ value: AnyCodable?) -> AgentApprovalReviewer? {
        guard let object = value?.dictionaryValue else { return nil }
        return AgentApprovalReviewer(
            channel: object["channel"]?.stringValue,
            accountID: object["accountId"]?.stringValue,
            senderID: object["senderId"]?.stringValue
        )
    }

    private func approvalGet(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let id = try self.requireString(request, "id")
        guard let approval = await self.runtime.approvals.get(id: id) else {
            throw GatewayMethodError.approvalNotFound(id)
        }
        return Self.object(["approval": AnyCodable(approval.snapshotPayload)])
    }

    private func approvalResolve(_ request: GatewayMethodRequest, kind: ApprovalKind?) async throws -> AnyCodable? {
        let id = try self.requireString(request, "id")
        let decision = try Self.decision(request.params["decision"]?.stringValue)
        let requestedKind = kind ?? request.params["kind"]?.stringValue.flatMap(ApprovalKind.init(rawValue:))
        var reviewer = Self.reviewer(request.params["reviewer"])
        if reviewer == nil, let deviceID = request.connection.deviceID {
            reviewer = AgentApprovalReviewer(deviceID: deviceID)
        }
        do {
            let (applied, approval) = try await self.runtime.approvals.resolve(
                id: id,
                decision: decision,
                kind: requestedKind,
                reviewer: reviewer,
                grantExpiresInDays: request.params["grantExpiresInDays"]?.intValue
            )
            if kind != nil {
                // Legacy exec/plugin resolvers answer `{ok, id, decision, applied}`.
                return Self.object([
                    "ok": AnyCodable(true),
                    "id": AnyCodable(id),
                    "decision": AnyCodable(decision.rawValue),
                    "applied": AnyCodable(applied),
                ])
            }
            return Self.object(["applied": AnyCodable(applied), "approval": AnyCodable(approval.snapshotPayload)])
        } catch let error as ApprovalBrokerError {
            switch error {
            case .notFound:
                throw GatewayMethodError.approvalNotFound(id)
            default:
                throw GatewayMethodError.invalidRequest(error.localizedDescription)
            }
        }
    }

    private func approvalHistory(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let kind = request.params["kind"]?.stringValue.flatMap(ApprovalKind.init(rawValue:))
        let page = await self.runtime.approvals.history(
            cursor: request.params["cursor"]?.stringValue,
            limit: request.params["limit"]?.intValue,
            kind: kind
        )
        var payload: [String: AnyCodable] = ["items": AnyCodable(page.items.map { AnyCodable($0.snapshotPayload) })]
        if let next = page.nextCursor {
            payload["nextCursor"] = AnyCodable(next)
        }
        return Self.object(payload)
    }

    private func legacyApprovalGet(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let id = try self.requireString(request, "id")
        guard let approval = await self.runtime.approvals.get(id: id), approval.state == .pending else {
            throw GatewayMethodError.approvalNotFound(id)
        }
        return Self.object([
            "id": AnyCodable(approval.id),
            "commandText": AnyCodable(approval.presentation.commandText ?? approval.presentation.title),
            "commandPreview": AnyCodable(approval.presentation.commandPreview),
            "allowedDecisions": AnyCodable(approval.presentation.allowedDecisions.map { AnyCodable($0.rawValue) }),
            "host": AnyCodable(approval.presentation.host),
            "nodeId": AnyCodable(approval.presentation.nodeID),
            "agentId": AnyCodable(approval.agentID),
            "expiresAtMs": AnyCodable(approval.expiresAtMs),
        ])
    }

    private func legacyApprovalList(kind: ApprovalKind) async -> AnyCodable? {
        AnyCodable(await self.runtime.approvals.pending(kind: kind).map { AnyCodable($0.legacyListPayload) })
    }

    private func legacyApprovalRequest(_ request: GatewayMethodRequest, kind: ApprovalKind) async throws -> AnyCodable? {
        let params = request.params
        let presentation: AgentApprovalPresentation
        let grantKey: String?
        switch kind {
        case .exec:
            let command = try self.requireString(request, "command")
            presentation = .exec(
                commandText: command,
                warningText: params["warningText"]?.stringValue,
                host: params["host"]?.stringValue,
                agentID: params["agentId"]?.stringValue,
                allowedDecisions: (params["unavailableDecisions"]?.arrayValue?.contains(AnyCodable("allow-always")) == true)
                    ? [.allowOnce, .deny] : [.allowOnce, .allowAlways, .deny]
            )
            grantKey = ApprovalBroker.execGrantKey(command: command)
        case .plugin, .systemAgent:
            let title = try self.requireString(request, "title")
            presentation = .plugin(
                title: title,
                description: params["description"]?.stringValue ?? title,
                detail: params["detail"]?.stringValue,
                severity: params["severity"]?.stringValue ?? "warning",
                pluginID: params["pluginId"]?.stringValue,
                toolName: params["toolName"]?.stringValue,
                agentID: params["agentId"]?.stringValue
            )
            grantKey = params["toolName"]?.stringValue.map { ApprovalBroker.pluginGrantKey(pluginID: params["pluginId"]?.stringValue, toolName: $0) }
        }
        let approval = await self.runtime.approvals.request(
            id: params["id"]?.stringValue,
            presentation: presentation,
            sessionKey: params["sessionKey"]?.stringValue,
            agentID: params["agentId"]?.stringValue,
            runID: params["runId"]?.stringValue,
            toolCallID: params["toolCallId"]?.stringValue,
            grantKey: grantKey,
            timeoutMs: params["timeoutMs"]?.int64Value
        )
        if params["twoPhase"]?.boolValue == true {
            return Self.object([
                "status": AnyCodable("accepted"),
                "id": AnyCodable(approval.id),
                "createdAtMs": AnyCodable(approval.createdAtMs),
                "expiresAtMs": AnyCodable(approval.expiresAtMs),
            ])
        }
        let terminal = try await self.runtime.approvals.waitDecision(id: approval.id)
        return AnyCodable(terminal.legacyWaitPayload)
    }

    private func legacyApprovalWait(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let id = try self.requireString(request, "id")
        do {
            let approval = try await self.runtime.approvals.waitDecision(id: id, timeoutMs: request.params["timeoutMs"]?.int64Value)
            return AnyCodable(approval.legacyWaitPayload)
        } catch {
            throw GatewayMethodError.approvalNotFound(id)
        }
    }

    private func grantsList(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let grants = await self.runtime.approvals.listGrants(limit: request.params["limit"]?.intValue ?? 500)
        return Self.object([
            "grants": AnyCodable(grants.filter { $0.kind == .exec }.map { grant in
                AnyCodable([
                    "grantId": AnyCodable(grant.id),
                    "mintedByApprovalId": AnyCodable(grant.mintedByApprovalID),
                    "agentId": AnyCodable(grant.agentID ?? self.runtime.defaultAgentID),
                    "cronJobId": AnyCodable("embedded"),
                    "cronJobName": .nullValue,
                    "command": AnyCodable(String(grant.key.dropFirst("exec:".count).prefix(512))),
                    "cwd": .nullValue,
                    "createdAtMs": AnyCodable(grant.createdAtMs),
                    "expiresAtMs": AnyCodable(grant.expiresAtMs),
                    "revokedAtMs": AnyCodable(grant.revokedAtMs),
                    "revokedBy": .nullValue,
                    "lastUsedAtMs": AnyCodable(grant.lastUsedAtMs),
                    "useCount": AnyCodable(grant.useCount),
                ] as [String: AnyCodable])
            }),
        ])
    }

    private func grantsRevoke(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let grantID = try self.requireString(request, "grantId")
        return Self.object(["outcome": AnyCodable(await self.runtime.approvals.revokeGrant(grantID))])
    }

    // MARK: - Questions

    private func questionRequest(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        guard let rawQuestions = request.params["questions"]?.arrayValue else {
            throw GatewayMethodError.invalidRequest("question.request requires questions")
        }
        var prompts: [AgentQuestionPrompt] = []
        for raw in rawQuestions {
            guard let object = raw.dictionaryValue else {
                throw GatewayMethodError.invalidRequest("question entries must be objects")
            }
            if object["secretStore"] != nil {
                throw GatewayMethodError.unavailable("secretStore question bindings are not supported by the embedded runtime")
            }
            do {
                prompts.append(try AgentJSONCoding.decode(AgentQuestionPrompt.self, from: raw))
            } catch {
                throw GatewayMethodError.invalidRequest("invalid question: \(error.localizedDescription)")
            }
        }
        do {
            let record = try await self.runtime.questions.request(
                id: request.params["id"]?.stringValue,
                questions: prompts,
                agentID: request.params["agentId"]?.stringValue,
                sessionKey: request.params["sessionKey"]?.stringValue,
                runID: request.params["runId"]?.stringValue,
                timeoutMs: request.params["timeoutMs"]?.int64Value
            )
            return Self.object(["id": AnyCodable(record.id), "expiresAtMs": AnyCodable(record.expiresAtMs)])
        } catch let error as QuestionBrokerError {
            throw GatewayMethodError.invalidRequest(error.localizedDescription)
        }
    }

    private func questionWait(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let id = try self.requireString(request, "id")
        do {
            let result = try await self.runtime.questions.waitAnswer(id: id, timeoutMs: request.params["timeoutMs"]?.int64Value)
            return AnyCodable(result.payload(includeResolutionID: request.params["includeResolutionId"]?.boolValue == true))
        } catch {
            throw GatewayMethodError.invalidRequest(error.localizedDescription)
        }
    }

    private func questionResolve(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let id = try self.requireString(request, "id")
        let resolvedBy = request.params["resolvedBy"]?.stringValue ?? request.connection.displayName ?? request.connection.clientID
        do {
            if request.params["cancel"]?.boolValue == true {
                try await self.runtime.questions.cancel(id: id, resolvedBy: resolvedBy)
                return Self.object(["status": AnyCodable("cancelled")])
            }
            let rawAnswers = request.params["answers"]?.dictionaryValue?["answers"]?.dictionaryValue
                ?? request.params["answers"]?.dictionaryValue
                ?? [:]
            var answers: [String: [String]] = [:]
            for (questionID, value) in rawAnswers {
                answers[questionID] = value.arrayValue?.compactMap(\.stringValue) ?? value.stringValue.map { [$0] } ?? []
            }
            let record = try await self.runtime.questions.resolve(
                id: id,
                answers: answers,
                resolvedBy: resolvedBy,
                resolutionID: request.params["resolutionId"]?.stringValue
            )
            return Self.object([
                "status": AnyCodable("answered"),
                "answers": AnyCodable(["answers": AgentQuestion.answersPayload(record.answers ?? [:])]),
            ])
        } catch let error as QuestionBrokerError {
            throw GatewayMethodError.invalidRequest(error.localizedDescription)
        }
    }

    private func questionGet(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let id = try self.requireString(request, "id")
        guard let record = await self.runtime.questions.get(id: id) else {
            throw GatewayMethodError.invalidRequest("unknown question id: \(id)")
        }
        return Self.object(["question": AnyCodable(record.payload)])
    }
}
