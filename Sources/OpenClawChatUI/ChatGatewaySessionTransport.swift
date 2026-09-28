import Foundation
import OpenClawKit
import OpenClawProtocol
import OSLog

// Turnkey gateway-backed chat transport. Adapted from upstream OpenClaw 2026.9.6
// `apps/ios/Sources/Chat/IOSGatewayChatTransport.swift` (+ComposerCapabilities) and the session-group
// and full-message operations of `apps/macos/Sources/OpenClaw/WebChatSwiftUI.swift`. Upstream ships
// only the shared protocol; each app writes its own adapter. App-specific loaders (media artifacts,
// source favicons) stay with the host app and keep the protocol defaults.

private let gatewaySessionChatLogger = Logger(subsystem: "ai.openclaw", category: "chat.gateway-transport")

/// Chat transport over one ``GatewayNodeSession`` operator connection.
///
/// Every durable or queued operation (outbox flush, settings, session mutations, groups, new
/// session, Swarm) captures a ``GatewayNodeSessionRoute`` lease first, so work suspended behind a
/// reconnect or a gateway switch is cancelled instead of being retargeted to another connection.
///
/// ```swift
/// let transport = OpenClawGatewaySessionChatTransport(gateway: session, gatewayStableID: gatewayID)
/// let viewModel = OpenClawChatViewModel(sessionKey: "main", transport: transport)
/// OpenClawChatView(viewModel: viewModel)
/// ```
public struct OpenClawGatewaySessionChatTransport: OpenClawChatGatewayTransport {
    /// How the durable outbox binds replays to the gateway's session routing contract.
    public enum OutboxRouteSafety: Sendable, Equatable {
        /// Default. Queued commands carry the gateway's session routing contract and replay only
        /// when the gateway advertises `chat-send-routing-contract` (and settings CAS). Against
        /// older gateways queued work stays parked and only live sends are allowed.
        case strict
        /// Opt-in for gateways without `chat-send-routing-contract`. Flushes still bind to one
        /// gateway connection, but queued commands are not fenced on the routing contract or on
        /// session settings, so a changed main-session alias or permission mode can apply to a
        /// replayed message.
        case bestEffort
    }

    /// Gateway operator session the transport sends through.
    public let gateway: GatewayNodeSession
    /// Normalized (trimmed, lowercased) agent that bare session keys resolve to.
    public let chatGatewayAgentID: String?
    /// Stable gateway id route leases must match byte-exactly (`deviceAuthGatewayID`), when set.
    public let gatewayStableID: String?
    /// Outbox replay policy.
    public let outboxRouteSafety: OutboxRouteSafety

    /// Creates a transport.
    ///
    /// - Parameters:
    ///   - gateway: Connected (or connecting) operator session.
    ///   - agentID: Agent bare session keys resolve to; `nil` uses the gateway default.
    ///   - gatewayStableID: When set, route leases (and therefore outbox flushes) are only taken
    ///     while the session is connected to the gateway with this `deviceAuthGatewayID`. Pass the
    ///     same id you use for ``OpenClawChatTranscriptCache``/outbox storage.
    ///   - outboxRouteSafety: ``OutboxRouteSafety/strict`` unless the gateway predates
    ///     `chat-send-routing-contract` and the app accepts unfenced replays.
    public init(
        gateway: GatewayNodeSession,
        agentID: String? = nil,
        gatewayStableID: String? = nil,
        outboxRouteSafety: OutboxRouteSafety = .strict)
    {
        self.gateway = gateway
        let normalized = agentID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.chatGatewayAgentID = normalized?.isEmpty == false ? normalized : nil
        let stableID = gatewayStableID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gatewayStableID = stableID?.isEmpty == false ? gatewayStableID : nil
        self.outboxRouteSafety = outboxRouteSafety
    }

    // MARK: - OpenClawChatGatewayTransport

    /// Sends a request on the session's current connection.
    public func requestChatGateway(_ request: OpenClawChatGatewayRequest) async throws -> Data {
        try await self.gateway.request(request)
    }

    /// Resolves bare keys to ``chatGatewayAgentID`` (`agent:<id>:<key>`), keeping qualified keys.
    public func sessionTarget(
        for sessionKey: String,
        overrideAgentID: String? = nil) -> OpenClawChatSessionTarget
    {
        OpenClawChatSessionTarget.resolve(
            sessionKey,
            selectedAgentID: self.chatGatewayAgentID,
            overrideAgentID: overrideAgentID,
            policy: .scopeBareKeysToSelectedAgent)
    }

    /// A copy scoped to another agent, sharing the same connection and route guards.
    public func scoped(toAgentID agentID: String) -> (any OpenClawChatTransport)? {
        OpenClawGatewaySessionChatTransport(
            gateway: self.gateway,
            agentID: agentID,
            gatewayStableID: self.gatewayStableID,
            outboxRouteSafety: self.outboxRouteSafety)
    }

    /// Whether queued commands must carry the gateway's session routing contract.
    public var outboxRequiresSessionRoutingContract: Bool {
        self.outboxRouteSafety == .strict
    }

    /// `commands.list` is available on every gateway this transport targets.
    public var supportsSlashCommandCatalog: Bool {
        true
    }

    /// The composer capability catalog is loaded from `config.get`, `skills.status` and `tools.effective`.
    public var supportsComposerCapabilities: Bool {
        true
    }

    // MARK: - Route leases

    /// The live route, restricted to ``gatewayStableID`` when set.
    public func currentRoute() async -> GatewayNodeSessionRoute? {
        if let gatewayStableID {
            return await self.gateway.currentRoute(ifGatewayID: gatewayStableID)
        }
        return await self.gateway.currentRoute()
    }

    /// Captures one connection for a whole outbox flush.
    public func acquireOutboxRouteLease() async -> OpenClawChatTransportRouteLeaseResult {
        guard let route = await self.currentRoute(),
              let supportsRoutingContract = await self.gateway.supportsServerCapability(
                  .chatSendRoutingContract,
                  ifCurrentRoute: route)
        else { return .unavailable(reason: nil) }
        let supportsSettingsCAS = await self.gateway.supportsServerCapability(
            .sessionSettingsCAS,
            ifCurrentRoute: route) == true
        let transport = self
        guard supportsRoutingContract else {
            guard self.outboxRouteSafety == .bestEffort else {
                return .unavailable(
                    reason: OpenClawChatTransportUpgradeMessage.routingContract,
                    allowsLiveSend: true)
            }
            return .available(OpenClawChatTransportRouteLease(
                sendTargetedMessageWithSettings: { key, agent, settings, text, thinking, id, attachments in
                    try await transport.sendMessage(
                        sessionKey: key,
                        agentID: agent,
                        expectedSessionRoutingContract: nil,
                        expectedSessionSettings: supportsSettingsCAS ? settings : nil,
                        message: text,
                        thinking: thinking,
                        idempotencyKey: id,
                        attachments: attachments,
                        ifCurrentRoute: route,
                        distinguishPreDispatchRouteChange: true)
                },
                requestTargetedHistory: { sessionKey, agentID in
                    try await transport.requestHistory(
                        sessionKey: sessionKey,
                        agentID: agentID,
                        ifCurrentRoute: route)
                },
                sessionRoutingContract: nil,
                supportsSessionSettingsCAS: supportsSettingsCAS))
        }
        guard let routingContract = try? await self.sessionRoutingContract(ifCurrentRoute: route)
        else { return .unavailable(reason: nil) }
        return .available(OpenClawChatTransportRouteLease(
            sendTargetedMessageWithSettings: { key, agent, settings, text, thinking, id, attachments in
                try await transport.sendMessage(
                    sessionKey: key,
                    agentID: agent,
                    expectedSessionRoutingContract: routingContract,
                    expectedSessionSettings: settings,
                    message: text,
                    thinking: thinking,
                    idempotencyKey: id,
                    attachments: attachments,
                    ifCurrentRoute: route,
                    distinguishPreDispatchRouteChange: true)
            },
            requestTargetedHistory: { sessionKey, agentID in
                try await transport.requestHistory(
                    sessionKey: sessionKey,
                    agentID: agentID,
                    ifCurrentRoute: route)
            },
            sessionRoutingContract: routingContract,
            supportsSessionSettingsCAS: supportsSettingsCAS))
    }

    /// Captures one connection for Swarm capability and child-session reads.
    public func acquireSwarmRouteLease() async -> OpenClawChatSwarmRouteLease? {
        guard let route = await self.currentRoute() else { return nil }
        let transport = self
        return OpenClawChatSwarmRouteLease(
            isEnabled: { sessionKey in
                try await transport.isSwarmEnabled(sessionKey: sessionKey, ifCurrentRoute: route)
            },
            listChildSessions: { parentKey in
                try await transport.listChildSessions(parentKey: parentKey, ifCurrentRoute: route)
            })
    }

    /// Captures one connection for queued settings mutations.
    public func acquireSessionSettingsRouteLease() async -> OpenClawChatSessionSettingsRouteLease? {
        guard let route = await self.currentRoute() else { return nil }
        let transport = self
        return OpenClawChatSessionSettingsRouteLease { sessionKey, agentID, patch in
            try await transport.patchSessionSettings(
                sessionKey: sessionKey,
                agentID: agentID,
                patch: patch,
                ifCurrentRoute: route)
        }
    }

    /// Captures one connection for queued session mutations (patch, delete).
    public func acquireSessionMutationRouteLease() async -> OpenClawChatSessionMutationRouteLease? {
        guard let route = await self.currentRoute() else { return nil }
        let unreadAckContract = await self.gateway.supportsServerCapability(
            .sessionUnreadAckContract,
            ifCurrentRoute: route)
        let transport = self
        return OpenClawChatSessionMutationRouteLease(
            sessionTarget: { transport.sessionTarget(for: $0) },
            unreadAckContract: unreadAckContract,
            request: { request in
                try await transport.requestRouted(request, ifCurrentRoute: route)
            })
    }

    /// Captures one connection while a group catalog is shown and edited.
    public func acquireSessionGroupsRouteLease() async -> OpenClawChatSessionGroupsRouteLease? {
        guard let route = await self.currentRoute() else { return nil }
        let transport = self
        return OpenClawChatSessionGroupsRouteLease(
            listGroups: {
                let data = try await transport.requestRouted(
                    OpenClawChatGatewayRequests.sessionGroupsList(),
                    ifCurrentRoute: route)
                return try JSONDecoder().decode(OpenClawChatSessionGroupsResponse.self, from: data)
            },
            putGroups: { names in
                let data = try await transport.requestRouted(
                    OpenClawChatGatewayRequests.sessionGroupsPut(names: names),
                    ifCurrentRoute: route)
                return try JSONDecoder().decode(OpenClawChatSessionGroupsMutationResponse.self, from: data)
            },
            renameGroup: { name, newName in
                let data = try await transport.requestRouted(
                    OpenClawChatGatewayRequests.sessionGroupsRename(name: name, to: newName),
                    ifCurrentRoute: route)
                return try JSONDecoder().decode(OpenClawChatSessionGroupsMutationResponse.self, from: data)
            },
            deleteGroup: { name in
                let data = try await transport.requestRouted(
                    OpenClawChatGatewayRequests.sessionGroupsDelete(name: name),
                    ifCurrentRoute: route)
                return try JSONDecoder().decode(OpenClawChatSessionGroupsMutationResponse.self, from: data)
            })
    }

    /// Captures one connection for the new-session sheet (agent list plus create).
    public func acquireNewSessionRouteLease() async -> OpenClawChatNewSessionRouteLease? {
        guard let route = await self.currentRoute() else { return nil }
        let transport = self
        return OpenClawChatNewSessionRouteLease(
            listAgents: {
                let data = try await transport.requestRouted(
                    OpenClawChatGatewayRequests.agentsList(),
                    ifCurrentRoute: route)
                return try OpenClawChatGatewayPayloadCodec.decodeAgentsList(data)
            },
            createSession: { key, label, agentID, parentSessionKey, worktree, worktreeBaseRef in
                let request = transport.createSessionRequest(
                    key: key,
                    label: label,
                    agentID: agentID,
                    parentSessionKey: parentSessionKey,
                    worktree: worktree,
                    worktreeBaseRef: worktreeBaseRef)
                let data = try await transport.requestRouted(request, ifCurrentRoute: route)
                return try JSONDecoder().decode(OpenClawChatCreateSessionResponse.self, from: data)
            })
    }

    /// Captures one connection for the model sign-in sheet (`models.authLogin`).
    public func acquireModelSignInContext(agentID: String?) async -> OpenClawChatModelSignInContext? {
        guard let route = await self.currentRoute(),
              await self.gateway.supportsServerMethod("models.authLogin", ifCurrentRoute: route) == true,
              let agentID = agentID ?? self.chatGatewayAgentID
        else { return nil }
        let gateway = self.gateway
        return OpenClawChatModelSignInContext(
            agentID: agentID,
            request: { method, params in
                try await gateway.request(
                    OpenClawChatGatewayRequest(method: method, params: params, timeoutMs: 26 * 60 * 1000),
                    ifCurrentRoute: route)
            },
            isCurrent: { await gateway.supportsServerMethod("models.authLogin", ifCurrentRoute: route) == true })
    }

    // MARK: - Sessions

    /// Lists sessions for ``chatGatewayAgentID``.
    public func listSessions(
        limit: Int?,
        search: String?,
        archived: Bool) async throws -> OpenClawChatSessionsListResponse
    {
        try await self.listSessions(limit: limit, search: search, archived: archived, agentID: self.chatGatewayAgentID)
    }

    /// Lists sessions for an agent (`sessions.list`).
    public func listSessions(
        limit: Int?,
        search: String?,
        archived: Bool,
        agentID: String?) async throws -> OpenClawChatSessionsListResponse
    {
        let request = OpenClawChatGatewayRequests.sessionsList(
            limit: limit,
            search: search,
            archived: archived,
            agentID: agentID)
        let data = try await self.gateway.request(request)
        return try OpenClawChatGatewayPayloadCodec.decodeSessionsList(data, agentID: agentID)
    }

    /// Lists every child session spawned by `parentKey` (paged `sessions.list` with `spawnedBy`).
    public func listChildSessions(parentKey: String) async throws -> [OpenClawChatSessionEntry] {
        try await self.listChildSessions(parentKey: parentKey, ifCurrentRoute: nil)
    }

    /// Lists agents (`agents.list`).
    public func listAgents() async throws -> OpenClawChatAgentsListResponse? {
        let data = try await self.gateway.request(OpenClawChatGatewayRequests.agentsList())
        return try OpenClawChatGatewayPayloadCodec.decodeAgentsList(data)
    }

    /// Lists session groups (`sessions.groups.list`).
    public func listSessionGroups() async throws -> OpenClawChatSessionGroupsResponse? {
        let data = try await self.gateway.request(OpenClawChatGatewayRequests.sessionGroupsList())
        return try JSONDecoder().decode(OpenClawChatSessionGroupsResponse.self, from: data)
    }

    /// Replaces the session group catalog (`sessions.groups.put`).
    public func putSessionGroups(names: [String]) async throws -> OpenClawChatSessionGroupsMutationResponse {
        let data = try await self.gateway.request(OpenClawChatGatewayRequests.sessionGroupsPut(names: names))
        return try JSONDecoder().decode(OpenClawChatSessionGroupsMutationResponse.self, from: data)
    }

    /// Renames a session group (`sessions.groups.rename`).
    public func renameSessionGroup(
        name: String,
        to newName: String) async throws -> OpenClawChatSessionGroupsMutationResponse
    {
        let data = try await self.gateway.request(OpenClawChatGatewayRequests.sessionGroupsRename(name: name, to: newName))
        return try JSONDecoder().decode(OpenClawChatSessionGroupsMutationResponse.self, from: data)
    }

    /// Deletes a session group (`sessions.groups.delete`).
    public func deleteSessionGroup(name: String) async throws -> OpenClawChatSessionGroupsMutationResponse {
        let data = try await self.gateway.request(OpenClawChatGatewayRequests.sessionGroupsDelete(name: name))
        return try JSONDecoder().decode(OpenClawChatSessionGroupsMutationResponse.self, from: data)
    }

    /// Creates a session (`sessions.create`); an explicit agent wins over the key and parent owners.
    public func createSession(
        key: String,
        label: String?,
        agentID: String?,
        parentSessionKey: String?,
        worktree: Bool?,
        worktreeBaseRef: String?) async throws -> OpenClawChatCreateSessionResponse
    {
        let request = self.createSessionRequest(
            key: key,
            label: label,
            agentID: agentID,
            parentSessionKey: parentSessionKey,
            worktree: worktree,
            worktreeBaseRef: worktreeBaseRef)
        let data = try await self.gateway.request(request)
        return try JSONDecoder().decode(OpenClawChatCreateSessionResponse.self, from: data)
    }

    /// Patches session metadata on a captured route; fails as not dispatched when disconnected.
    public func patchSession(
        key: String,
        expectedSessionID: String?,
        label: String??,
        category: String??,
        color: String??,
        pinned: Bool?,
        archived: Bool?,
        unread: Bool?) async throws
    {
        guard let routeLease = await self.acquireSessionMutationRouteLease() else {
            throw OpenClawChatTransportSendError.notDispatched
        }
        try await routeLease.patchSession(
            key: key,
            expectedSessionID: expectedSessionID,
            label: label,
            category: category,
            color: color,
            pinned: pinned,
            archived: archived,
            unread: unread)
    }

    /// Forks a session.
    public func forkSession(parentKey: String) async throws -> String {
        try await self.forkSession(parentKey: parentKey, fromLastCompleted: false)
    }

    /// Forks a session, optionally from its last completed turn.
    public func forkSession(parentKey: String, fromLastCompleted: Bool) async throws -> String {
        try await self.forkSession(parentKey: parentKey, fromLastCompleted: fromLastCompleted, agentID: nil)
    }

    /// Forks an agent-owned session (`sessions.create` with `fork`).
    public func forkSession(parentKey: String, fromLastCompleted: Bool, agentID: String?) async throws -> String {
        let target = self.sessionTarget(for: parentKey, overrideAgentID: agentID)
        let childAgentID = target.agentID ?? OpenClawChatSessionKey.agentID(from: target.sessionKey)
        let request = OpenClawChatGatewayRequests.forkSession(
            parentSessionKey: target.sessionKey,
            agentID: childAgentID,
            fromLastCompleted: fromLastCompleted)
        let data = try await self.gateway.request(request)
        return try JSONDecoder().decode(OpenClawChatCreateSessionResponse.self, from: data).key
    }

    /// Compacts a session (`sessions.compact`); the gateway owns the deadline.
    public func compactSession(sessionKey: String) async throws {
        let target = self.sessionTarget(for: sessionKey)
        let request = OpenClawChatGatewayRequests.compactSession(
            sessionKey: target.sessionKey,
            agentID: target.agentID)
        let data = try await self.gateway.request(request)
        try OpenClawSessionsCompactResponse.requireSuccess(from: data)
    }

    // MARK: - Models and settings

    /// Lists model choices (`models.list`).
    public func listModels(agentID: String?) async throws -> [OpenClawChatModelChoice] {
        let data = try await self.gateway.request(OpenClawChatGatewayRequests.modelsList(agentID: agentID))
        return try OpenClawChatGatewayPayloadCodec.decodeModelChoices(data)
    }

    /// Loads the session-scoped model catalog when the gateway publishes one.
    public func loadModelCatalog(
        sessionKey: String,
        agentID: String?) async throws -> OpenClawChatModelCatalogSnapshot
    {
        guard let route = await self.currentRoute() else { throw CancellationError() }
        let sessionScoped = await self.gateway.supportsServerCapability(
            .publishedModelCatalog,
            ifCurrentRoute: route) == true
        guard sessionScoped else {
            return OpenClawChatModelCatalogSnapshot(choices: [], availabilityIsSessionScoped: false)
        }
        let request = OpenClawChatGatewayRequests.modelsList(
            agentID: agentID ?? self.chatGatewayAgentID,
            sessionKey: sessionKey)
        let data = try await self.gateway.request(request, ifCurrentRoute: route)
        return try OpenClawChatGatewayPayloadCodec.decodeModelCatalog(data)
    }

    /// Legacy model patch.
    public func setSessionModel(sessionKey: String, model: String?) async throws {
        _ = try await self.patchSessionModel(sessionKey: sessionKey, agentID: nil, model: model)
    }

    /// Applies a settings patch (`sessions.patch`), with CAS fields when the gateway supports them.
    public func patchSessionSettings(
        sessionKey: String,
        agentID: String?,
        patch: OpenClawChatSessionSettingsPatch) async throws -> OpenClawChatModelPatchResult?
    {
        try await self.patchSessionSettings(
            sessionKey: sessionKey,
            agentID: agentID,
            patch: patch,
            ifCurrentRoute: nil)
    }

    /// Whether Swarm is enabled for a session (`chat.metadata`).
    public func isSwarmEnabled(sessionKey: String) async throws -> Bool {
        try await self.isSwarmEnabled(sessionKey: sessionKey, ifCurrentRoute: nil)
    }

    // MARK: - History and sending

    /// Reads a transcript (`chat.history`).
    public func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        try await self.requestHistory(sessionKey: sessionKey, agentID: nil, ifCurrentRoute: nil)
    }

    /// Reads the untruncated row for a truncated message (`chat.message.get`).
    public func requestFullMessage(sessionKey: String, messageID: String) async throws -> OpenClawChatMessage? {
        let target = self.sessionTarget(for: sessionKey)
        let data = try await self.gateway.request(Self.fullMessageRequest(
            sessionKey: target.sessionKey,
            agentID: target.agentID,
            messageID: messageID))
        let result = try JSONDecoder().decode(ChatMessageGetResult.self, from: data)
        guard result.ok, let encodedMessage = result.message else { return nil }
        return try JSONDecoder().decode(OpenClawChatMessage.self, from: JSONEncoder().encode(encodedMessage))
    }

    /// Sends a message on the current route (`chat.send`).
    ///
    /// Unlike upstream's app adapter, the untargeted overload is also route-checked so a transport
    /// bound to ``gatewayStableID`` never sends to another gateway.
    public func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        try await self.sendMessage(
            sessionKey: sessionKey,
            target: OpenClawChatSendTarget(
                agentID: nil,
                expectedSessionRoutingContract: nil,
                expectedSessionSettings: nil),
            message: message,
            thinking: thinking,
            idempotencyKey: idempotencyKey,
            attachments: attachments)
    }

    /// Sends a message targeted at an agent and routing contract.
    public func sendMessage(
        sessionKey: String,
        agentID: String?,
        expectedSessionRoutingContract: String?,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        try await self.sendMessage(
            sessionKey: sessionKey,
            target: OpenClawChatSendTarget(
                agentID: agentID,
                expectedSessionRoutingContract: expectedSessionRoutingContract,
                expectedSessionSettings: nil),
            message: message,
            thinking: thinking,
            idempotencyKey: idempotencyKey,
            attachments: attachments)
    }

    /// Sends a live message; the routing contract is only sent when the gateway can guard it.
    public func sendMessage(
        sessionKey: String,
        target: OpenClawChatSendTarget,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        guard let route = await self.currentRoute(),
              let supportsRoutingContract = await self.gateway.supportsServerCapability(
                  .chatSendRoutingContract,
                  ifCurrentRoute: route)
        else { throw OpenClawChatTransportSendError.notDispatched }
        let guardedContract = OpenClawChatSessionRoutingContract.expectedValue(
            target.expectedSessionRoutingContract,
            serverSupportsGuard: supportsRoutingContract)
        return try await self.sendMessage(
            sessionKey: sessionKey,
            agentID: target.agentID,
            expectedSessionRoutingContract: guardedContract,
            expectedSessionSettings: target.expectedSessionSettings,
            message: message,
            thinking: thinking,
            idempotencyKey: idempotencyKey,
            attachments: attachments,
            ifCurrentRoute: route,
            distinguishPreDispatchRouteChange: true)
    }

    /// Waits for a run on the current route (`agent.wait`).
    public func waitForRunCompletion(runId rawRunId: String, timeoutMs: Int) async -> OpenClawChatRunObservation {
        let runId = rawRunId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runId.isEmpty, let route = await self.currentRoute() else { return .unavailable }
        do {
            let request = OpenClawChatGatewayRequests.agentWait(runID: runId, timeoutMs: timeoutMs)
            let data = try await self.gateway.request(request, ifCurrentRoute: route)
            return try OpenClawChatGatewayPayloadCodec.decodeAgentWaitObservation(data)
        } catch {
            gatewaySessionChatLogger.warning("agent.wait failed \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    /// Checks gateway health (`health`).
    public func requestHealth(timeoutMs: Int) async throws -> Bool {
        let data = try await self.gateway.request(OpenClawChatGatewayRequests.health(timeoutMs: timeoutMs))
        return (try? JSONDecoder().decode(OpenClawGatewayHealthOK.self, from: data))?.ok ?? true
    }

    /// Whether the connected gateway's hello advertises `method`; `nil` when unknown.
    public func gatewayAdvertisesMethod(_ method: String) async -> Bool? {
        guard let route = await self.currentRoute() else { return nil }
        return await self.gateway.supportsServerMethod(method, ifCurrentRoute: route)
    }

    /// Fetches the durable progress card (`progressCard.get`).
    public func fetchProgressCard(sessionKey: String, agentID: String?) async throws -> ProgressCard? {
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: agentID)
        let request = OpenClawChatGatewayRequests.progressCardGet(
            sessionKey: target.sessionKey,
            agentID: target.agentID)
        guard let route = await self.currentRoute() else { throw CancellationError() }
        if request.params["agentId"] != nil {
            guard let supported = await self.gateway.supportsServerCapability(
                .progressCardAgentScope,
                ifCurrentRoute: route)
            else { throw CancellationError() }
            guard supported else { throw OpenClawChatProgressCardError.ownerScopeUnavailable }
        }
        let data = try await self.gateway.request(request, ifCurrentRoute: route)
        return try OpenClawChatGatewayPayloadCodec.decodeProgressCard(
            data,
            agentID: OpenClawChatSessionKey.agentID(from: target.sessionKey) ?? target.agentID)
    }

    /// Resolves a canvas widget against the operator canvas surface, rotating it once on failure.
    public func resolveInlineWidgetResource(
        path: String,
        replacing failedResource: OpenClawChatWidgetResource?) async -> OpenClawChatWidgetResource?
    {
        guard OpenClawChatWidgetURLResolver.supportsTarget(path) else { return nil }
        var surface = await self.gateway.currentCanvasHostRoute()
        if let failedResource, let current = surface,
           OpenClawChatWidgetURLResolver.resolve(surfaceURL: current.url, target: path) == failedResource.url
        {
            surface = await self.gateway.refreshCanvasHostRoute(replacing: current.url)
        }
        guard let surface,
              let url = OpenClawChatWidgetURLResolver.resolve(surfaceURL: surface.url, target: path),
              url != failedResource?.url
        else { return nil }
        return OpenClawChatWidgetResource(url: url, tlsFingerprintSHA256: surface.tlsFingerprintSHA256)
    }

    /// Resolves a canvas widget URL (URL-only callers).
    public func resolveInlineWidgetURL(path: String, replacing failedURL: URL?) async -> URL? {
        await self.resolveInlineWidgetResource(
            path: path,
            replacing: failedURL.map { OpenClawChatWidgetResource(url: $0) })?.url
    }

    // MARK: - Events

    /// Gateway push events mapped to chat events.
    ///
    /// On subscription and after every reconnect the transport re-sends `sessions.subscribe`
    /// (subscriptions are per socket). A reconnect onto a different connection context (endpoint,
    /// credentials or gateway) is reported as ``OpenClawChatTransportEvent/routeChanged``; a
    /// reconnect of the same context as ``OpenClawChatTransportEvent/seqGap``.
    public func events() -> AsyncStream<OpenClawChatTransportEvent> {
        let transport = self
        return AsyncStream(bufferingPolicy: .bufferingNewest(200)) { continuation in
            let task = Task {
                let subscription = await transport.gateway.makeServerEventSubscription(bufferingNewest: 200)
                defer { subscription.cancel() }
                var tracker = RouteTracker()
                if let route = await transport.currentRoute() {
                    _ = tracker.observe(route)
                    transport.subscribeSessions(ifCurrentRoute: route)
                }
                for await frame in subscription.events {
                    if Task.isCancelled { break }
                    guard var mapped = OpenClawChatGatewayPayloadCodec.event(from: frame) else { continue }
                    if tracker.shouldCheckRoute(after: mapped), let route = await transport.currentRoute() {
                        switch tracker.observe(route) {
                        case .unchanged:
                            break
                        case .reconnected:
                            transport.subscribeSessions(ifCurrentRoute: route)
                        case .contextChanged:
                            transport.subscribeSessions(ifCurrentRoute: route)
                            if case .seqGap = mapped {
                                mapped = .routeChanged
                            } else {
                                // The replacement was first noticed on another event: announce it first.
                                continuation.yield(.routeChanged)
                            }
                        }
                    }
                    continuation.yield(mapped)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Composer capabilities

    /// Loads the composer capability catalog for a session on one captured route.
    public func loadComposerCapabilityCatalog(
        sessionKey: String,
        agentID: String?) async -> OpenClawChatComposerCapabilityCatalog
    {
        guard let route = await self.currentRoute() else { return OpenClawChatComposerCapabilityCatalog() }
        async let operatorScopes = self.gateway.currentOperatorScopes(ifCurrentRoute: route)
        async let patchMethodAdvertised = self.gateway.supportsServerMethod("sessions.patch", ifCurrentRoute: route)
        async let settingsSupportRequest = self.sessionSettingsSupport(ifCurrentRoute: route)
        let scopes = await operatorScopes ?? []
        let canAdmin = scopes.contains("operator.admin")
        let canWrite = canAdmin || scopes.contains("operator.write")
        let canRead = canWrite || scopes.contains("operator.read")
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: agentID)
        let targetAgentID = target.agentID ?? OpenClawChatSessionKey.agentID(from: target.sessionKey)

        async let configRequest = self.composerResponse(
            OpenClawChatGatewayRequests.composerConfigGet(),
            method: "config.get",
            canRead: canRead,
            route: route)
        async let skillsRequest = self.composerResponse(
            OpenClawChatGatewayRequests.composerSkillsStatus(agentID: targetAgentID),
            method: "skills.status",
            canRead: canRead,
            route: route)
        async let toolsRequest = self.composerResponse(
            OpenClawChatGatewayRequests.composerToolsEffective(sessionKey: target.sessionKey, agentID: target.agentID),
            method: "tools.effective",
            canRead: canRead,
            route: route)
        let (configResponse, skillsResponse, toolsResponse, patchCapability, settingsSupport) = await (
            configRequest,
            skillsRequest,
            toolsRequest,
            patchMethodAdvertised,
            settingsSupportRequest)
        guard await self.gateway.currentRoute() == route else { return OpenClawChatComposerCapabilityCatalog() }
        return OpenClawGatewaySessionComposerCatalog.catalog(
            config: configResponse,
            skills: skillsResponse,
            tools: toolsResponse,
            patchCapability: patchCapability,
            settingsContract: settingsSupport.settingsContract,
            settingsCAS: settingsSupport.settingsCAS,
            canWrite: canWrite,
            canAdmin: canAdmin)
    }
}

// MARK: - Route-bound implementations

extension OpenClawGatewaySessionChatTransport {
    /// Sends a chat request bound to `route`; a route change before dispatch throws
    /// ``GatewayNodeSessionRequestError/routeChangedBeforeDispatch``.
    func requestRouted(
        _ request: OpenClawChatGatewayRequest,
        ifCurrentRoute route: GatewayNodeSessionRoute) async throws -> Data
    {
        try await self.gateway.request(request, ifCurrentRoute: route, distinguishPreDispatchRouteChange: true)
    }

    func sessionRoutingContract(ifCurrentRoute route: GatewayNodeSessionRoute) async throws -> String {
        let data = try await self.gateway.request(OpenClawChatGatewayRequests.agentsList(), ifCurrentRoute: route)
        return try OpenClawChatGatewayPayloadCodec.decodeSessionRoutingIdentity(data).contract
    }

    func sessionSettingsSupport(
        ifCurrentRoute route: GatewayNodeSessionRoute) async -> (settingsContract: Bool, settingsCAS: Bool)
    {
        async let settingsContract = self.gateway.supportsServerCapability(.sessionSettingsContract, ifCurrentRoute: route)
        async let settingsCAS = self.gateway.supportsServerCapability(.sessionSettingsCAS, ifCurrentRoute: route)
        return await (settingsContract == true, settingsCAS == true)
    }

    func createSessionRequest(
        key: String,
        label: String?,
        agentID: String?,
        parentSessionKey: String?,
        worktree: Bool?,
        worktreeBaseRef: String?) -> OpenClawChatGatewayRequest
    {
        let target = self.sessionTarget(for: key, overrideAgentID: agentID)
        let parentTarget = parentSessionKey.map { self.sessionTarget(for: $0) }
        let explicitAgentID = agentID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return OpenClawChatGatewayRequests.createSession(
            key: target.sessionKey,
            agentID: explicitAgentID?.isEmpty == false ? explicitAgentID : target.agentID ?? parentTarget?.agentID,
            label: label,
            parentSessionKey: parentTarget?.sessionKey,
            worktree: worktree,
            worktreeBaseRef: worktreeBaseRef)
    }

    func listChildSessions(
        parentKey: String,
        ifCurrentRoute route: GatewayNodeSessionRoute?) async throws -> [OpenClawChatSessionEntry]
    {
        try await OpenClawChatChildSessionPager.collect { offset in
            let request = OpenClawChatGatewayRequests.sessionsList(
                limit: 10000,
                search: nil,
                archived: false,
                includeGlobal: false,
                spawnedBy: parentKey,
                offset: offset,
                configuredAgentsOnly: true)
            let data = try await self.gateway.request(request, ifCurrentRoute: route)
            return try JSONDecoder().decode(OpenClawChatSessionsListResponse.self, from: data)
        }
    }

    func isSwarmEnabled(sessionKey: String, ifCurrentRoute route: GatewayNodeSessionRoute?) async throws -> Bool {
        let request = OpenClawChatGatewayRequests.chatMetadata(
            sessionKey: sessionKey,
            fallbackAgentID: self.chatGatewayAgentID)
        let data = try await self.gateway.request(request, ifCurrentRoute: route)
        return try JSONDecoder().decode(OpenClawChatMetadataCapabilities.self, from: data).swarmEnabled
    }

    func patchSessionSettings(
        sessionKey: String,
        agentID: String?,
        patch: OpenClawChatSessionSettingsPatch,
        ifCurrentRoute expectedRoute: GatewayNodeSessionRoute?) async throws -> OpenClawChatModelPatchResult?
    {
        let requiresSettingsContract = patch.expectedSessionID != nil ||
            patch.permissionMode != nil || patch.toolOverrides != nil
        let requiresSettingsCAS = patch.expectedPermissionMode != nil ||
            patch.expectedToolOverrides != nil || patch.permissionMode != nil || patch.toolOverrides != nil
        let fallbackRoute: GatewayNodeSessionRoute? = if requiresSettingsContract, expectedRoute == nil {
            await self.currentRoute()
        } else {
            nil
        }
        let settingsRoute = expectedRoute ?? fallbackRoute
        let settingsSupport = if let settingsRoute {
            await self.sessionSettingsSupport(ifCurrentRoute: settingsRoute)
        } else {
            (settingsContract: false, settingsCAS: false)
        }
        guard !requiresSettingsContract || settingsSupport.settingsContract else {
            throw OpenClawChatTransportSendError.notDispatched
        }
        guard !requiresSettingsCAS || settingsSupport.settingsCAS else {
            throw OpenClawChatTransportSendError.notDispatched
        }
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: agentID)
        let request = OpenClawChatGatewayRequests.patchSessionSettings(
            sessionKey: target.sessionKey,
            agentID: target.agentID,
            expectedSessionID: patch.expectedSessionID,
            expectedPermissionMode: patch.expectedPermissionMode,
            expectedToolOverrides: patch.expectedToolOverrides,
            model: patch.model,
            thinkingLevel: patch.thinkingLevel,
            fastMode: patch.fastMode,
            verboseLevel: patch.verboseLevel,
            permissionMode: patch.permissionMode,
            toolOverrides: patch.toolOverrides,
            supportsSessionSettingsContract: settingsSupport.settingsContract,
            supportsSessionSettingsCAS: settingsSupport.settingsCAS)
        let data = if let settingsRoute {
            try await self.requestRouted(request, ifCurrentRoute: settingsRoute)
        } else {
            try await self.gateway.request(request)
        }
        return try JSONDecoder().decode(OpenClawChatModelPatchResult.self, from: data)
    }

    func requestHistory(
        sessionKey: String,
        agentID: String? = nil,
        ifCurrentRoute expectedRoute: GatewayNodeSessionRoute?) async throws -> OpenClawChatHistoryPayload
    {
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: agentID)
        let request = OpenClawChatGatewayRequests.history(sessionKey: target.sessionKey, agentID: target.agentID)
        let data = try await self.gateway.request(request, ifCurrentRoute: expectedRoute)
        return try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: data)
    }

    // One parameter per chat.send field; keeping them flat mirrors the upstream adapter.
    // swiftlint:disable:next function_parameter_count
    func sendMessage(
        sessionKey: String,
        agentID: String? = nil,
        expectedSessionRoutingContract: String? = nil,
        expectedSessionSettings: OpenClawChatSessionSettingsExpectation? = nil,
        message: String,
        thinking: String?,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload],
        ifCurrentRoute expectedRoute: GatewayNodeSessionRoute?,
        distinguishPreDispatchRouteChange: Bool = false) async throws -> OpenClawChatSendResponse
    {
        let supportsSettingsCAS = if let expectedRoute {
            await self.gateway.supportsServerCapability(.sessionSettingsCAS, ifCurrentRoute: expectedRoute) == true
        } else {
            false
        }
        guard expectedSessionSettings == nil || supportsSettingsCAS else {
            throw OpenClawChatTransportSendError.notDispatched
        }
        let target = self.sessionTarget(for: sessionKey, overrideAgentID: agentID)
        let request = OpenClawChatGatewayRequests.sendMessage(
            sessionKey: target.sessionKey,
            agentID: target.agentID,
            expectedSessionRoutingContract: expectedSessionRoutingContract,
            expectedSessionSettings: expectedSessionSettings,
            supportsSessionSettingsCAS: supportsSettingsCAS,
            message: message,
            thinking: thinking,
            idempotencyKey: idempotencyKey,
            attachments: attachments)
        do {
            let data = try await self.gateway.request(
                request,
                ifCurrentRoute: expectedRoute,
                distinguishPreDispatchRouteChange: distinguishPreDispatchRouteChange)
            return try JSONDecoder().decode(OpenClawChatSendResponse.self, from: data)
        } catch is GatewayNodeSessionRequestError {
            // The captured route changed before the frame was sent: safe to retry automatically.
            throw OpenClawChatTransportSendError.notDispatched
        }
    }

    static func fullMessageRequest(
        sessionKey: String,
        agentID: String?,
        messageID: String) -> OpenClawChatGatewayRequest
    {
        // Same wire shape as the generated `ChatMessageGetParams`.
        var params: [String: OpenClawProtocol.AnyCodable] = [
            "sessionKey": OpenClawProtocol.AnyCodable(sessionKey),
            "messageId": OpenClawProtocol.AnyCodable(messageID),
            "maxChars": OpenClawProtocol.AnyCodable(500_000),
        ]
        if let agentID {
            params["agentId"] = OpenClawProtocol.AnyCodable(agentID)
        }
        return OpenClawChatGatewayRequest(method: "chat.message.get", params: params, timeoutMs: 15000)
    }

    /// Fire-and-forget `sessions.subscribe` on one socket.
    func subscribeSessions(ifCurrentRoute route: GatewayNodeSessionRoute) {
        let gateway = self.gateway
        Task {
            do {
                _ = try await gateway.request(OpenClawChatGatewayRequests.subscribeSessions(), ifCurrentRoute: route)
            } catch {
                gatewaySessionChatLogger.debug(
                    "sessions.subscribe failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    fileprivate func composerResponse(
        _ request: OpenClawChatGatewayRequest,
        method: String,
        canRead: Bool,
        route: GatewayNodeSessionRoute) async -> OpenClawGatewaySessionComposerCatalog.Response
    {
        guard canRead, await self.gateway.supportsServerMethod(method, ifCurrentRoute: route) == true
        else { return .unavailable }
        do {
            return try await .loaded(self.requestRouted(request, ifCurrentRoute: route))
        } catch {
            return .failed
        }
    }
}

/// Tracks socket and connection-context changes seen by one event subscription.
struct OpenClawGatewaySessionRouteTracker {
    enum Change: Equatable {
        case unchanged
        case reconnected
        case contextChanged
    }

    private var lastRoute: GatewayNodeSessionRoute?

    /// Route checks run until a route is known, then only on lifecycle events.
    func shouldCheckRoute(after event: OpenClawChatTransportEvent) -> Bool {
        guard self.lastRoute != nil else { return true }
        switch event {
        case .seqGap, .routeChanged, .tick, .health:
            return true
        default:
            return false
        }
    }

    mutating func observe(_ route: GatewayNodeSessionRoute) -> Change {
        defer { self.lastRoute = route }
        guard let lastRoute else { return .reconnected }
        if lastRoute == route { return .unchanged }
        return lastRoute.hasSameConnectionContext(as: route) ? .reconnected : .contextChanged
    }
}

private typealias RouteTracker = OpenClawGatewaySessionRouteTracker

/// Pure mapping from composer RPC payloads to the capability catalog (upstream iOS adapter).
enum OpenClawGatewaySessionComposerCatalog {
    enum Response {
        case unavailable
        case failed
        case loaded(Data)
    }

    private struct Surface<Value> {
        let value: Value?
        let loaded: Bool
        let failed: Bool
    }

    private struct ConfigSnapshot: Decodable {
        let runtimeConfig: RuntimeConfig
    }

    private struct RuntimeConfig: Decodable {
        let mcp: MCPConfig?
        let tools: ToolsConfig?
    }

    private struct MCPConfig: Decodable {
        let servers: [String: MCPServer]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.servers = try container.decodeIfPresent([String: MCPServer].self, forKey: .servers) ?? [:]
        }

        private enum CodingKeys: String, CodingKey { case servers }
    }

    private struct MCPServer: Decodable {
        let enabled: Bool?
    }

    private struct ToolsConfig: Decodable {
        let web: WebToolsConfig?
    }

    private struct WebToolsConfig: Decodable {
        let search: WebSearchConfig?
    }

    private struct WebSearchConfig: Decodable {
        let enabled: Bool?
    }

    // Every input is one independently loaded surface; the catalog combines them in one place.
    // swiftlint:disable:next function_parameter_count
    static func catalog(
        config configResponse: Response,
        skills skillsResponse: Response,
        tools toolsResponse: Response,
        patchCapability: Bool?,
        settingsContract: Bool,
        settingsCAS: Bool,
        canWrite: Bool,
        canAdmin: Bool) -> OpenClawChatComposerCapabilityCatalog
    {
        let patchAdvertised = patchCapability == true
        let sessionSettingsAvailable = settingsContract && patchAdvertised
        let configSurface = self.decode(configResponse, as: ConfigSnapshot.self)
        let skillsSurface = self.decode(skillsResponse, as: SkillsStatusReport.self)
        let toolsSurface = self.decode(toolsResponse, as: ToolsEffectiveResult.self)
        let config = configSurface.value
        let toolsByServer = self.toolsByServer(toolsSurface.value)
        let noticesByServer = self.noticesByServer(toolsSurface.value)
        let configuredServers = config?.runtimeConfig.mcp?.servers ?? [:]
        let connectorNames = Set(configuredServers.keys).union(toolsByServer.keys).sorted()
        let failedSurfaces = [
            configSurface.failed ? String(localized: "Web Search and Connectors") : nil,
            skillsSurface.failed ? String(localized: "Skills") : nil,
            toolsSurface.failed ? String(localized: "Tool Access") : nil,
        ].compactMap(\.self)
        let failureMessage = failedSurfaces.isEmpty
            ? nil
            : String(format: String(localized: "Could not load: %@. Retry."), failedSurfaces.joined(separator: ", "))
        return OpenClawChatComposerCapabilityCatalog(
            sessionSettingsAvailable: sessionSettingsAvailable,
            modelMutationAvailable: self.mutationAvailable(methodSupport: patchCapability, allowedByScope: canWrite),
            effortMutationAvailable: self.mutationAvailable(methodSupport: patchCapability, allowedByScope: canAdmin),
            webSearchBaseEnabled: config?.runtimeConfig.tools?.web?.search?.enabled != false,
            webSearchAvailable: configSurface.loaded,
            skills: (skillsSurface.value?.skills ?? []).map(self.skill).sorted { $0.name < $1.name },
            connectors: connectorNames.map { name in
                OpenClawChatComposerConnector(
                    name: name,
                    baseEnabled: configuredServers[name]?.enabled != false,
                    tools: toolsByServer[name] ?? [],
                    notice: noticesByServer[name])
            },
            skillsAvailable: skillsSurface.loaded,
            connectorsAvailable: configSurface.loaded,
            toolAccessAvailable: toolsSurface.loaded,
            permissionMutationAvailable: sessionSettingsAvailable && settingsCAS && patchAdvertised && canWrite,
            sessionSettingsCASAvailable: settingsCAS,
            toolOverrideMutationAvailable: sessionSettingsAvailable && patchAdvertised && settingsCAS && canAdmin,
            toolOverrideMutationRequiresGatewayUpgrade: sessionSettingsAvailable && !settingsCAS,
            canSelectFullPermission: sessionSettingsAvailable && settingsCAS && patchAdvertised && canAdmin,
            loadFailureMessage: failureMessage)
    }

    static func mutationAvailable(methodSupport: Bool?, allowedByScope: Bool) -> Bool {
        methodSupport == nil || (methodSupport == true && allowedByScope)
    }

    private static func decode<T: Decodable>(_ response: Response, as type: T.Type) -> Surface<T> {
        switch response {
        case let .loaded(data):
            do {
                return try Surface(value: JSONDecoder().decode(type, from: data), loaded: true, failed: false)
            } catch {
                return Surface(value: nil, loaded: false, failed: true)
            }
        case .failed:
            return Surface(value: nil, loaded: false, failed: true)
        case .unavailable:
            return Surface(value: nil, loaded: false, failed: false)
        }
    }

    static func skill(_ skill: SkillStatus) -> OpenClawChatComposerSkill {
        let missing = skill.missing
        let missingDependencies = !missing.bins.isEmpty || !missing.anyBins.isEmpty ||
            !missing.env.isEmpty || !missing.config.isEmpty || !missing.os.isEmpty
        return OpenClawChatComposerSkill(
            key: skill.skillKey,
            name: skill.name,
            baseEnabled: !skill.disabled,
            missingDependencies: missingDependencies,
            blocked: skill.blockedByAllowlist == true || skill.platformIncompatible == true,
            agentFiltered: skill.blockedByAgentFilter == true)
    }

    static func toolsByServer(_ result: ToolsEffectiveResult?) -> [String: [OpenClawChatComposerTool]] {
        var tools: [String: [OpenClawChatComposerTool]] = [:]
        for entry in result?.groups.flatMap(\.tools) ?? [] {
            guard entry.source.stringValue == "mcp",
                  let server = entry.mcpserver?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !server.isEmpty,
                  let name = entry.mcptoolname?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { continue }
            tools[server, default: []].append(OpenClawChatComposerTool(
                name: name,
                label: entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : entry.label,
                baseEnabled: true,
                sessionDenied: entry.deniedbysession == true))
        }
        return tools.mapValues { values in
            Dictionary(grouping: values, by: \.name).values.compactMap(\.first).sorted { $0.name < $1.name }
        }
    }

    private static func noticesByServer(_ result: ToolsEffectiveResult?) -> [String: String] {
        var notices: [String: String] = [:]
        for notice in result?.notices ?? [] {
            for server in notice.servers ?? [] where notices[server] == nil {
                notices[server] = notice.message
            }
        }
        return notices
    }
}
