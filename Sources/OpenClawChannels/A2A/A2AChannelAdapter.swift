import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// HTTP response produced by host-routed channel handlers.
public struct ChannelHTTPHandlerResponse: Sendable, Equatable {
    /// HTTP status code.
    public var status: Int
    /// Response headers.
    public var headers: [String: String]
    /// Response body.
    public var body: Data

    /// Creates a response.
    /// - Parameters:
    ///   - status: Status code.
    ///   - headers: Headers.
    ///   - body: Body.
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Body decoded as UTF-8.
    public var bodyText: String {
        String(decoding: self.body, as: UTF8.self)
    }
}

/// Native Agent2Agent (A2A 1.0) channel (upstream `a2a` plugin).
///
/// - Inbound: route `GET /.well-known/agent-card.json`, `GET /.well-known/agent.json` and
///   `POST /a2a/v1` to ``handleHTTP(method:path:headers:body:requestOrigin:)``. Requests must carry
///   `Authorization: Bearer <token>` matching a configured peer (constant-time compare); that peer
///   is the sender. Per-peer sliding 60 s rate limit, 1 MiB request/response bodies, batches of at
///   most 30. `SendMessage` dispatches an ``InboundMessage`` with `peerID` `<peer>:<contextId>` (one
///   isolated session per peer and context) and blocks up to `replyTimeoutMs` for the reply, which
///   completes the task with an artifact; `GetTask` returns the caller's own tasks. Slash
///   messages are rejected: peers send tasks, never commands.
/// - Outbound: replies to `<peer>:<contextId>` complete the pending task; sends to `a2a:<peer>`
///   post `SendMessage` to the peer's `url` through ``A2AClient``.
///
/// Peers are admitted by bearer token, so ``ChannelsConfig/messagingPolicy(for:accountID:)``
/// evaluates `a2a` with `dmPolicy: allowlist` over the configured peer names.
public actor A2AChannelAdapter: InboundChannelAdapter, ReceiptingChannelAdapter, ChannelConfigurationReporting {
    /// Maximum request body size.
    public static let maxRequestBodyBytes = 1_024 * 1_024
    /// Maximum response body size.
    public static let maxResponseBodyBytes = 1_024 * 1_024
    /// Maximum JSON-RPC batch size (enforced even when rate limiting is disabled).
    public static let maxBatchRequests = 30
    /// Agent Card paths.
    public static let agentCardPaths: Set<String> = ["/.well-known/agent-card.json", "/.well-known/agent.json"]
    /// JSON-RPC endpoint path.
    public static let rpcPath = "/a2a/v1"

    /// Adapter channel identifier.
    public let id: ChannelID = .a2a

    private let config: A2AChannelConfig
    private let accountID: String?
    private let agentIDs: [String]
    private let instanceName: String?
    private let version: String
    private let client: A2AClient
    private let taskStore: A2ATaskStore
    private let now: @Sendable () -> Date

    private var started = false
    private var inboundHandler: InboundMessageHandler?
    private var peerRequestTimes: [String: [Date]] = [:]

    /// Creates an A2A adapter.
    /// - Parameters:
    ///   - config: `channels.a2a` settings (resolve SecretRefs first).
    ///   - accountID: Account id for routing.
    ///   - agentIDs: Configured agent ids (filtered by `exposeAgents` in the Agent Card).
    ///   - instanceName: Agent Card name (default `OpenClaw`).
    ///   - version: Agent Card version.
    ///   - transport: HTTP transport for outbound peer calls.
    ///   - taskStore: Task store.
    ///   - now: Clock for rate limiting.
    public init(
        config: A2AChannelConfig,
        accountID: String? = nil,
        agentIDs: [String] = ["main"],
        instanceName: String? = nil,
        version: String = A2AAgentCard.defaultVersion,
        transport: any ChannelHTTPTransport = HTTPClient(),
        taskStore: A2ATaskStore = A2ATaskStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.accountID = accountID?.channelTrimmedNonEmpty
        self.agentIDs = agentIDs
        self.instanceName = instanceName?.channelTrimmedNonEmpty
        self.version = version
        self.client = A2AClient(peers: config.validPeers, transport: transport)
        self.taskStore = taskStore
        self.now = now
    }

    /// Registers or clears the inbound callback.
    /// - Parameter handler: Inbound handler.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Configured when at least one valid peer has an inbound token.
    nonisolated public var configurationStatus: ChannelConfigurationStatus {
        self.config.isConfigured
            ? .configured
            : .unconfigured(reason: "A2A requires at least one channels.a2a.peers entry with a token.")
    }

    /// Outbound peer client.
    nonisolated public var peerClient: A2AClient {
        self.client
    }

    /// Starts the adapter (inbound arrives through ``handleHTTP(method:path:headers:body:requestOrigin:)``).
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("A2A channel is disabled")
        }
        guard self.config.isConfigured else {
            throw OpenClawCoreError.invalidConfiguration("A2A requires at least one channels.a2a.peers entry with a token.")
        }
        self.started = true
    }

    /// Stops the adapter and resolves pending waits.
    public func stop() async {
        self.started = false
        self.peerRequestTimes.removeAll()
        await self.taskStore.stop()
    }

    /// Reports configured peers.
    /// - Parameter timeoutMs: Unused.
    /// - Returns: Probe result.
    public func probe(timeoutMs _: Int) async -> ChannelProbeResult {
        if case .unconfigured(let reason) = self.configurationStatus {
            return ChannelProbeResult(ok: false, detail: reason)
        }
        return ChannelProbeResult(ok: true, detail: "\(self.config.validPeers.count) peer(s)")
    }

    // MARK: Outbound

    /// Sends a reply or an outbound task.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        _ = try await self.sendReturningReceipt(message)
    }

    /// Completes the pending task for `<peer>:<contextId>` or sends a task to `a2a:<peer>`.
    /// - Parameter message: Outbound payload.
    /// - Returns: Receipt carrying the task id.
    public func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt {
        guard self.started else {
            throw OpenClawCoreError.unavailable("A2A adapter is not started")
        }
        let target = message.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.lowercased().hasPrefix("a2a:"), let (peer, contextId) = Self.splitSessionPeer(target),
           self.config.validPeers[peer] != nil
        {
            guard let task = await self.taskStore.completeNext(contextId: contextId, text: message.text, ownerPeer: peer) else {
                throw ChannelSendError.rejected(status: 0, detail: "No pending A2A task for \(peer) in context \(contextId)")
            }
            return ChannelSendReceipt(platformMessageID: task.id)
        }
        let peer = A2AClient.peerName(fromTarget: target)
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("A2A outbound text is required")
        }
        let task = try await self.client.send(text: message.text, to: peer)
        return ChannelSendReceipt(platformMessageID: task.id)
    }

    // MARK: Inbound HTTP

    /// Public Agent Card.
    /// - Parameter requestOrigin: Origin of the request (used when `advertisedUrl` is unset).
    /// - Returns: Card.
    public func agentCard(requestOrigin: String? = nil) -> A2AAgentCard {
        let exposed = self.config.exposeAgents ?? []
        let agents = self.agentIDs.filter { exposed.isEmpty || exposed.contains($0) }
        let origin = self.config.advertisedUrl?.channelTrimmedNonEmpty ?? requestOrigin?.channelTrimmedNonEmpty ?? "http://localhost"
        var trimmedOrigin = origin
        while trimmedOrigin.hasSuffix("/") {
            trimmedOrigin.removeLast()
        }
        return A2AAgentCard(
            name: self.instanceName ?? "OpenClaw",
            description: "OpenClaw agent gateway using the Agent2Agent protocol.",
            supportedInterfaces: [A2AAgentCard.Interface(url: trimmedOrigin + Self.rpcPath)],
            version: self.version,
            skills: agents.map { A2AAgentCard.Skill(id: $0, name: $0, description: "OpenClaw agent \($0).", tags: ["openclaw"]) }
        )
    }

    /// Handles one HTTP request routed by the host.
    /// - Parameters:
    ///   - method: HTTP method.
    ///   - path: Request path (query ignored).
    ///   - headers: Request headers (`Authorization`).
    ///   - body: Raw request body.
    ///   - requestOrigin: Request origin for the Agent Card when `advertisedUrl` is unset.
    /// - Returns: Response to send.
    public func handleHTTP(
        method: String,
        path: String,
        headers: [String: String],
        body: Data,
        requestOrigin: String? = nil
    ) async -> ChannelHTTPHandlerResponse {
        let pathname = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let verb = method.uppercased()
        if verb == "GET", Self.agentCardPaths.contains(pathname) {
            return Self.json(status: 200, encodable: self.agentCard(requestOrigin: requestOrigin))
        }
        guard verb == "POST", pathname == Self.rpcPath else {
            return Self.json(status: 404, object: ["error": "Not found"])
        }
        guard self.started, let peer = self.resolvePeer(headers: headers) else {
            return Self.json(status: 401, object: ["error": "Unauthorized; configure channels.a2a.peers with a matching Bearer token"])
        }
        guard body.count <= Self.maxRequestBodyBytes else {
            return Self.json(status: 413, object: ["error": "Request body exceeds the 1 MiB limit"])
        }
        guard let payload = try? JSONDecoder().decode(AnyCodable.self, from: body) else {
            return Self.rpcResponse(Self.rpcError(id: .null, code: -32_700, message: "Parse error"))
        }
        if let batch = payload.arrayValue {
            guard !batch.isEmpty else {
                return Self.rpcResponse(Self.rpcError(id: .null, code: -32_600, message: "Invalid JSON-RPC request"))
            }
            guard batch.count <= Self.maxBatchRequests else {
                let message = self.isRateLimited(peer) ? "Peer is rate limited" : "A2A batch exceeds the \(Self.maxBatchRequests) request limit"
                return Self.rpcResponse(Self.rpcError(id: .null, code: -32_000, message: message))
            }
            let responses = await withTaskGroup(of: (Int, A2AJSONRPCResponse<AnyCodable>?).self) { group in
                for (index, entry) in batch.enumerated() {
                    group.addTask { (index, await self.processRPC(entry, peer: peer)) }
                }
                var collected: [(Int, A2AJSONRPCResponse<AnyCodable>)] = []
                for await (index, response) in group {
                    if let response {
                        collected.append((index, response))
                    }
                }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            return responses.isEmpty ? ChannelHTTPHandlerResponse(status: 200) : Self.rpcBatchResponse(responses)
        }
        guard let response = await self.processRPC(payload, peer: peer) else {
            return ChannelHTTPHandlerResponse(status: 200)
        }
        return Self.rpcResponse(response)
    }

    private func processRPC(_ input: AnyCodable, peer: String) async -> A2AJSONRPCResponse<AnyCodable>? {
        let object = input.dictionaryValue
        let id: A2AJSONRPCID = {
            if let value = object?["id"]?.stringValue { return .string(value) }
            if let number = object?["id"]?.doubleValue { return .number(number) }
            return .null
        }()
        let method = object?["method"]?.stringValue
        let idIsValid = object?["id"].map { $0.isNull || $0.stringValue != nil || $0.doubleValue != nil } ?? true
        let valid = object?["jsonrpc"]?.stringValue == "2.0" && !(method ?? "").isEmpty && idIsValid
        let notification = valid && object?["id"] == nil

        if self.isRateLimited(peer) {
            return notification ? nil : Self.rpcError(id: id, code: -32_000, message: "Peer is rate limited")
        }
        guard valid, let method else {
            return Self.rpcError(id: id, code: -32_600, message: "Invalid JSON-RPC request")
        }
        let result: Result<AnyCodable, A2AJSONRPCError>
        switch A2AProtocol.resolveMethod(method) {
        case nil:
            result = .failure(A2AJSONRPCError(code: -32_601, message: "Method not found: \(method)"))
        case .unsupported:
            result = .failure(A2AJSONRPCError(
                code: A2AProtocol.unsupportedOperationCode,
                message: "Unsupported operation; supported methods are SendMessage and GetTask"
            ))
        case .sendMessage:
            result = await self.handleSendMessage(object?["params"], peer: peer)
        case .getTask:
            result = await self.handleGetTask(object?["params"], peer: peer)
        }
        if notification {
            return nil
        }
        switch result {
        case .success(let value):
            return A2AJSONRPCResponse(id: id, result: value)
        case .failure(let error):
            return A2AJSONRPCResponse(id: id, error: error)
        }
    }

    private func handleSendMessage(_ params: AnyCodable?, peer: String) async -> Result<AnyCodable, A2AJSONRPCError> {
        let invalid = A2AJSONRPCError(code: -32_602, message: "Invalid SendMessage params: message and parts required")
        guard let params = params?.dictionaryValue, let message = params["message"]?.dictionaryValue,
              let role = message["role"]?.stringValue, ["ROLE_USER", "ROLE_AGENT", "user", "agent"].contains(role),
              let parts = message["parts"]?.arrayValue
        else {
            return .failure(invalid)
        }
        let messageID = message["messageId"]
        let rawContext = message["contextId"]
        let taskID = message["taskId"]
        if let messageID, (messageID.stringValue ?? "").isEmpty { return .failure(invalid) }
        if let taskID, (taskID.stringValue ?? "").isEmpty { return .failure(invalid) }
        if let rawContext, !A2AProtocol.isContextID(rawContext.stringValue ?? "") { return .failure(invalid) }
        let configuration = params["configuration"]?.dictionaryValue
        guard let text = A2AProtocol.extractText(from: parts) else {
            return .failure(A2AJSONRPCError(code: -32_602, message: "Message must contain at least one usable text part"))
        }
        let contextId = rawContext?.stringValue ?? "ctx-\(UUID().uuidString.lowercased())"
        let task = await self.taskStore.create(contextId: contextId, ownerPeer: peer)
        await self.taskStore.start(task.id)
        let resolvedMessageID = messageID?.stringValue ?? UUID().uuidString.lowercased()
        Task { [weak self] in
            await self?.dispatchInbound(taskID: task.id, contextId: contextId, messageID: resolvedMessageID, peer: peer, text: text)
        }
        let settled: A2ATask?
        if configuration?["returnImmediately"]?.boolValue == true {
            settled = await self.taskStore.get(task.id, ownerPeer: peer)
        } else {
            settled = await self.taskStore.wait(task.id, timeoutMs: self.config.replyTimeoutMs)
        }
        do {
            return .success(try AnyCodable(encoding: A2ASendMessageResult(task: settled ?? task)))
        } catch {
            return .failure(A2AJSONRPCError(code: -32_000, message: "A2A request could not be processed"))
        }
    }

    private func handleGetTask(_ params: AnyCodable?, peer: String) async -> Result<AnyCodable, A2AJSONRPCError> {
        guard let id = params?.dictionaryValue?["id"]?.stringValue, !id.isEmpty else {
            return .failure(A2AJSONRPCError(code: -32_602, message: "Invalid task params: id is required"))
        }
        guard let task = await self.taskStore.get(id, ownerPeer: peer) else {
            return .failure(A2AJSONRPCError(code: A2AProtocol.taskNotFoundCode, message: "Task not found"))
        }
        do {
            return .success(try AnyCodable(encoding: task))
        } catch {
            return .failure(A2AJSONRPCError(code: -32_000, message: "A2A request could not be processed"))
        }
    }

    private func dispatchInbound(taskID: String, contextId: String, messageID: String, peer: String, text: String) async {
        // Peer credentials admit tasks, never user commands.
        if text.drop(while: { $0.isWhitespace }).hasPrefix("/") {
            await self.taskStore.reject(
                taskID,
                reason: "A2A peers cannot execute slash commands. Send a task in plain text; only users can issue commands."
            )
            return
        }
        guard let inboundHandler else {
            await self.taskStore.fail(taskID, reason: "A2A channel has no inbound handler")
            return
        }
        let inbound = InboundMessage(
            channel: .a2a,
            accountID: self.accountID,
            peerID: "\(peer):\(contextId)",
            text: text,
            senderID: peer,
            senderName: peer,
            chatType: .direct,
            messageID: messageID,
            metadata: [
                "a2aTaskId": taskID,
                "a2aContextId": contextId,
                "a2aPeer": peer,
                "commandInterpretationSuppressed": "true",
            ]
        )
        await inboundHandler(inbound)
    }

    // MARK: Helpers

    private func resolvePeer(headers: [String: String]) -> String? {
        guard let authorization = ChannelHTTP.header("Authorization", in: headers)?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        let pieces = authorization.split(separator: " ", omittingEmptySubsequences: true)
        guard pieces.count == 2, pieces[0].lowercased() == "bearer" else { return nil }
        let token = String(pieces[1])
        var matched: String?
        for (name, peer) in self.config.validPeers.sorted(by: { $0.key < $1.key }) {
            guard let configured = peer.token else { continue }
            if ChannelWebhookSignature.constantTimeEquals(token, configured), matched == nil {
                matched = name
            }
        }
        return matched
    }

    private func isRateLimited(_ peer: String) -> Bool {
        let maximum = self.config.rateLimitPerMinute
        guard maximum > 0 else { return false }
        let now = self.now()
        var requests = (self.peerRequestTimes[peer] ?? []).filter { now.timeIntervalSince($0) < 60 }
        if requests.count >= maximum {
            self.peerRequestTimes[peer] = requests
            return true
        }
        requests.append(now)
        self.peerRequestTimes[peer] = requests
        return false
    }

    /// Splits `<peer>:<contextId>` (peer names never contain `:`).
    static func splitSessionPeer(_ value: String) -> (String, String)? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let peer = String(value[..<colon])
        let context = String(value[value.index(after: colon)...])
        guard A2AChannelConfig.isValidPeerName(peer), A2AProtocol.isContextID(context) else { return nil }
        return (peer, context)
    }

    private static func rpcError(id: A2AJSONRPCID, code: Int, message: String) -> A2AJSONRPCResponse<AnyCodable> {
        A2AJSONRPCResponse(id: id, error: A2AJSONRPCError(code: code, message: message))
    }

    private static let jsonHeaders = ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"]

    private static func json(status: Int, object: [String: String]) -> ChannelHTTPHandlerResponse {
        self.json(status: status, encodable: object)
    }

    private static func json(status: Int, encodable: some Encodable) -> ChannelHTTPHandlerResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = (try? encoder.encode(encodable)) ?? Data("{}".utf8)
        return ChannelHTTPHandlerResponse(status: status, headers: self.jsonHeaders, body: body)
    }

    private static func rpcResponse(_ response: A2AJSONRPCResponse<AnyCodable>) -> ChannelHTTPHandlerResponse {
        let encoded = self.json(status: 200, encodable: response)
        guard encoded.body.count > self.maxResponseBodyBytes else { return encoded }
        let bounded = self.json(status: 200, encodable: self.rpcError(id: response.id ?? .null, code: -32_000, message: "A2A response exceeds the 1 MiB limit"))
        guard bounded.body.count > self.maxResponseBodyBytes else { return bounded }
        return self.json(status: 200, encodable: self.rpcError(id: .null, code: -32_000, message: "A2A response exceeds the 1 MiB limit"))
    }

    private static func rpcBatchResponse(_ responses: [A2AJSONRPCResponse<AnyCodable>]) -> ChannelHTTPHandlerResponse {
        let encoded = self.json(status: 200, encodable: responses)
        guard encoded.body.count > self.maxResponseBodyBytes else { return encoded }
        let message = "A2A response exceeds the 1 MiB limit"
        let bounded = self.json(status: 200, encodable: responses.map { self.rpcError(id: $0.id ?? .null, code: -32_000, message: message) })
        guard bounded.body.count > self.maxResponseBodyBytes else { return bounded }
        return self.json(status: 200, encodable: responses.map { _ in self.rpcError(id: .null, code: -32_000, message: message) })
    }
}
