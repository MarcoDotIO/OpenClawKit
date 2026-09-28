import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Minimal HTTP transport contract used by the Signal adapter.
public protocol SignalHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Normalized response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: SignalHTTPTransport {}

// MARK: - Payloads

private struct SignalReceiveResponse: Decodable {
    let messages: [SignalInboundEnvelope]

    private enum CodingKeys: String, CodingKey {
        case messages
    }

    init(from decoder: Decoder) throws {
        if let rawArray = try? [SignalInboundEnvelope](from: decoder) {
            self.messages = rawArray
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.messages = try container.decodeIfPresent([SignalInboundEnvelope].self, forKey: .messages) ?? []
    }
}

/// Receive frame (container REST/WebSocket and signal-cli SSE/JSON-RPC notifications).
private struct SignalInboundEnvelope: Decodable {
    let envelope: SignalInboundPayload?
    let params: SignalNotificationParams?
    let source: String?
    let sourceNumber: String?
    let timestamp: Int64?
    let message: String?
    let text: String?
    let dataMessage: SignalDataMessage?

    var payload: SignalInboundPayload? {
        self.envelope ?? self.params?.envelope
    }
}

private struct SignalNotificationParams: Decodable {
    let envelope: SignalInboundPayload?
}

private struct SignalInboundPayload: Decodable {
    let source: String?
    let sourceNumber: String?
    let sourceUuid: String?
    let sourceName: String?
    let timestamp: Int64?
    let dataMessage: SignalDataMessage?
    let syncMessage: AnyCodableStub?
}

private struct AnyCodableStub: Decodable {
    init(from _: Decoder) throws {}
}

private struct SignalDataMessage: Decodable {
    let message: String?
    let timestamp: Int64?
    let groupInfo: SignalGroupInfo?
    let quote: SignalQuote?
    let mentions: [SignalMention]?
    let reaction: AnyCodableStub?
}

private struct SignalGroupInfo: Decodable {
    let groupId: String?
    let groupName: String?
}

private struct SignalQuote: Decodable {
    let id: Int64?
    let authorNumber: String?
    let authorUuid: String?
}

private struct SignalMention: Decodable {
    let uuid: String?
    let number: String?
}

private struct SignalSendResponse: Decodable {
    let timestamp: Int64?
}

private struct SignalRPCResponse: Decodable {
    struct RPCError: Decodable {
        let code: Int?
        let message: String?
    }

    struct Result: Decodable {
        let timestamp: Int64?
    }

    let result: Result?
    let error: RPCError?
}

private struct SignalInboundContext: Sendable {
    let author: String
    let timestamp: Int64
    let groupID: String?
}

/// Signal adapter (upstream 2026.9.6 transports).
///
/// - ``SignalTransportKind/container`` (default, bbernhard/signal-cli-rest-api): receives through
///   the WebSocket `ws(s)://<base>/v1/receive/<account>` (json-rpc mode) and falls back to
///   `GET /v1/receive` polling (normal mode) when the upgrade fails; sends `/v2/send` with
///   `base64_attachments` (8 MiB budget, or `mediaMaxMb`) and quote fields; typing
///   `PUT`/`DELETE /v1/typing-indicator/<account>`; reactions `/v1/reactions/<account>`; read
///   receipts `/v1/receipts/<account>`; probe `GET /v1/about`.
/// - ``SignalTransportKind/externalNative`` (`signal-cli daemon --http`): JSON-RPC 2.0
///   `POST /api/v1/rpc` (`send`, `sendTyping`, `sendReaction`, `sendReceipt`), SSE inbound
///   `GET /api/v1/events`, probe `GET /api/v1/check`.
/// - ``SignalTransportKind/managedNative`` is not supported: run signal-cli yourself and use
///   `external-native`.
///
/// Group conversations use the peer id `group:<groupId>`. Self-authored messages (the account
/// number or `accountUuid`) are dropped for loop protection. Text is chunked at 4,000 characters
/// and sends return timestamp receipts.
public actor SignalChannelAdapter: InboundChannelAdapter, ReceiptingChannelAdapter, ReactingChannelAdapter, ChannelMessageActions,
    ChannelConfigurationReporting, ChannelTransportHealthReporting
{
    /// Adapter channel identifier.
    public let id: ChannelID = .signal

    /// Upstream Signal chunk limit.
    public static let textChunkLimit = 4_000
    /// Default outbound attachment budget (8 MiB raw bytes per send).
    public static let defaultAttachmentBudgetBytes = 8 * 1_024 * 1_024
    /// Receive frame cap (1 MiB).
    public static let maxFrameBytes = 1_024 * 1_024

    private let config: SignalChannelConfig
    private let transport: any SignalHTTPTransport
    private let explicitServiceURL: URL?
    private let webSocketConnector: any ChannelWebSocketConnecting
    private let lineStreamer: any ChannelLineStreaming

    private var started = false
    private var receiveTask: Task<Void, Never>?
    private var socket: (any ChannelWebSocketConnection)?
    private var inboundHandler: InboundMessageHandler?
    private var recentInbound = ChannelRecentIDs(capacity: 1_024)
    private var lastInbound: [String: SignalInboundContext] = [:]
    private var health = ChannelTransportHealth()
    private var usesPolling = false

    /// Creates a Signal channel adapter.
    /// - Parameters:
    ///   - config: Signal channel configuration (resolve SecretRefs first).
    ///   - transport: HTTP transport implementation.
    ///   - serviceURL: Optional service URL override.
    ///   - webSocketConnector: WebSocket connector for container receive.
    ///   - lineStreamer: Line streamer for the external-native SSE event stream.
    public init(
        config: SignalChannelConfig,
        transport: any SignalHTTPTransport = HTTPClient(),
        serviceURL: URL? = nil,
        webSocketConnector: any ChannelWebSocketConnecting = URLSessionChannelWebSocketConnector(),
        lineStreamer: any ChannelLineStreaming = URLSessionChannelLineStreamer()
    ) {
        self.config = config
        self.transport = transport
        self.explicitServiceURL = serviceURL
        self.webSocketConnector = webSocketConnector
        self.lineStreamer = lineStreamer
    }

    /// Registers or clears inbound callback.
    /// - Parameter handler: Optional callback for accepted inbound messages.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Resolved transport kind.
    nonisolated public var transportKind: SignalTransportKind {
        self.config.resolvedTransportKind
    }

    /// Configuration status: an account number and a service URL.
    nonisolated public var configurationStatus: ChannelConfigurationStatus {
        if self.transportKind == .managedNative {
            return .unconfigured(reason: Self.managedNativeReason)
        }
        guard self.config.accountID?.channelTrimmedNonEmpty != nil else {
            return .unconfigured(reason: "Signal requires account (E.164).")
        }
        return .configured
    }

    static let managedNativeReason =
        "Signal managed-native transport is not supported by OpenClawKit; run `signal-cli daemon --http` yourself and set transport.kind to external-native."

    /// Current receive health.
    public func transportHealth() async -> ChannelTransportHealth {
        self.health
    }

    /// Whether the container receive fell back to `GET /v1/receive` polling.
    /// - Returns: `true` after the WebSocket upgrade failed.
    public func isUsingPollingFallback() -> Bool {
        self.usesPolling
    }

    // MARK: Lifecycle

    /// Starts adapter lifecycle and the inbound receive loop.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("Signal channel is disabled")
        }
        if self.started {
            return
        }
        if self.transportKind == .managedNative {
            throw OpenClawCoreError.unavailable(Self.managedNativeReason)
        }
        _ = try self.resolveServiceURL()
        let account = try self.resolveAccountID(fromOutboundAccountID: nil)
        self.recentInbound.removeAll()
        self.usesPolling = false
        self.started = true
        self.health = ChannelTransportHealth(state: .healthy)
        switch self.transportKind {
        case .externalNative:
            self.receiveTask = Task { [weak self] in
                await self?.sseLoop(account: account)
            }
        case .container, .managedNative:
            self.receiveTask = Task { [weak self] in
                await self?.containerReceiveLoop(account: account)
            }
        }
    }

    /// Stops adapter lifecycle.
    public func stop() async {
        self.started = false
        self.receiveTask?.cancel()
        self.receiveTask = nil
        await self.socket?.close()
        self.socket = nil
        self.health = ChannelTransportHealth(state: .stopped)
    }

    /// Probes the service (`GET /v1/about` for container, `GET /api/v1/check` for external-native).
    /// - Parameter timeoutMs: Probe timeout.
    /// - Returns: Probe result.
    public func probe(timeoutMs: Int) async -> ChannelProbeResult {
        if case .unconfigured(let reason) = self.configurationStatus {
            return ChannelProbeResult(ok: false, detail: reason)
        }
        return await ChannelAsync.probe(timeoutMs: timeoutMs) { [self] in
            try await self.performProbe()
        }
    }

    private func performProbe() async throws -> String {
        let path = self.transportKind == .externalNative ? "api/v1/check" : "v1/about"
        var request = URLRequest(url: try self.endpoint(path))
        request.httpMethod = "GET"
        self.authorize(&request)
        let response = try await self.transport.data(for: request)
        try ChannelHTTP.check(response)
        return "HTTP \(response.statusCode)"
    }

    // MARK: Outbound

    /// Sends an outbound Signal message.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        _ = try await self.sendReturningReceipt(message)
    }

    /// Sends text (chunked at 4,000 characters) and attachments; returns timestamp receipts.
    /// - Parameter message: Outbound payload.
    /// - Returns: Receipt with the Signal timestamps.
    public func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Signal adapter is not started")
        }
        let account = try self.resolveAccountID(fromOutboundAccountID: message.accountID)
        let recipient = try self.resolveRecipient(from: message)
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !message.attachments.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Signal outbound text is required")
        }
        let chunks = text.isEmpty ? [""] : ChannelTextChunker.chunk(text, limit: Self.textChunkLimit)
        let quote = message.replyToID.flatMap { replyTo in self.lastInbound[message.peerID].flatMap { $0.timestamp == Int64(replyTo) ? $0 : nil } }
        var parts: [ChannelSendReceipt.Part] = []
        for (index, chunk) in chunks.enumerated() {
            let attachments = index == 0 ? message.attachments : []
            let timestamp = try await self.sendOne(
                account: account,
                recipient: recipient,
                text: chunk,
                attachments: attachments,
                quote: index == 0 ? quote : nil
            )
            parts.append(
                ChannelSendReceipt.Part(
                    platformMessageID: timestamp.map(String.init) ?? "",
                    kind: attachments.isEmpty ? .text : .media,
                    index: index,
                    replyToID: index == 0 ? message.replyToID : nil
                )
            )
        }
        return ChannelSendReceipt(parts: parts, replyToID: message.replyToID)
    }

    private func sendOne(
        account: String,
        recipient: String,
        text: String,
        attachments: [MediaAttachment],
        quote: SignalInboundContext?
    ) async throws -> Int64? {
        switch self.transportKind {
        case .externalNative:
            var params: [String: Any] = ["account": account, "message": text]
            Self.applyNativeTarget(recipient, to: &params)
            if let quote {
                params["quoteTimestamp"] = quote.timestamp
                params["quoteAuthor"] = quote.author
            }
            let result = try await self.rpc("send", params: params)
            return result?.timestamp
        case .container, .managedNative:
            var payload: [String: Any] = ["message": text, "number": account, "recipients": [Self.containerRecipient(recipient)]]
            if !attachments.isEmpty {
                payload["base64_attachments"] = try self.base64Attachments(attachments)
            }
            if let quote {
                payload["quote_timestamp"] = quote.timestamp
                payload["quote_author"] = quote.author
                payload["quote_message"] = ""
            }
            let response = try await self.rest("POST", path: "v2/send", payload: payload)
            return (try? JSONDecoder().decode(SignalSendResponse.self, from: response.body))?.timestamp
        }
    }

    /// Encodes attachments as container data URIs within the raw-byte budget.
    private func base64Attachments(_ attachments: [MediaAttachment]) throws -> [String] {
        let budget = self.config.policy.mediaMaxMb.map { Int($0 * 1_024 * 1_024) } ?? Self.defaultAttachmentBudgetBytes
        var remaining = budget
        var results: [String] = []
        for attachment in attachments {
            guard attachment.data.count <= remaining else {
                throw ChannelSendError.rejected(status: 413, detail: "Signal attachments exceed the \(budget)-byte budget")
            }
            remaining -= attachment.data.count
            let name = (attachment.fileName ?? "attachment").map { ",;#".contains($0) ? "_" : $0 }
            results.append("data:\(attachment.mimeType);filename=\(String(name));base64,\(attachment.data.base64EncodedString())")
        }
        return results
    }

    /// Container recipient: `group:<id>` becomes `group.<base64(id)>`; `uuid:` prefixes are stripped.
    /// - Parameter peerID: Peer id.
    /// - Returns: Container recipient.
    static func containerRecipient(_ peerID: String) -> String {
        if peerID.hasPrefix("group.") {
            return peerID
        }
        if peerID.hasPrefix("group:") {
            return "group." + Data(peerID.dropFirst(6).utf8).base64EncodedString()
        }
        return peerID.hasPrefix("uuid:") ? String(peerID.dropFirst(5)) : peerID
    }

    private static func applyNativeTarget(_ peerID: String, to params: inout [String: Any]) {
        if peerID.hasPrefix("group:") {
            params["groupId"] = String(peerID.dropFirst(6))
        } else {
            params["recipient"] = [peerID]
        }
    }

    /// Signal supports typing indicators.
    nonisolated public var supportsTypingIndicator: Bool {
        true
    }

    /// Starts typing (`PUT /v1/typing-indicator/<account>` or JSON-RPC `sendTyping`).
    /// - Parameters:
    ///   - accountID: Channel account key.
    ///   - peerID: Recipient or `group:<id>`.
    public func sendTypingIndicator(accountID: String?, peerID: String) async throws {
        try await self.typing(accountID: accountID, peerID: peerID, stop: false)
    }

    /// Stops typing (`DELETE /v1/typing-indicator/<account>` or `sendTyping {stop: true}`).
    /// - Parameters:
    ///   - accountID: Channel account key.
    ///   - peerID: Recipient or `group:<id>`.
    public func stopTypingIndicator(accountID: String?, peerID: String) async throws {
        try await self.typing(accountID: accountID, peerID: peerID, stop: true)
    }

    private func typing(accountID: String?, peerID: String, stop: Bool) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Signal adapter is not started")
        }
        let account = try self.resolveAccountID(fromOutboundAccountID: accountID)
        let recipient = try peerID.channelTrimmedNonEmpty ?? self.defaultRecipient()
        switch self.transportKind {
        case .externalNative:
            var params: [String: Any] = ["account": account, "stop": stop]
            Self.applyNativeTarget(recipient, to: &params)
            _ = try await self.rpc("sendTyping", params: params)
        case .container, .managedNative:
            _ = try await self.rest(
                stop ? "DELETE" : "PUT",
                path: "v1/typing-indicator/\(Self.pathComponent(account))",
                payload: ["recipient": Self.containerRecipient(recipient)]
            )
        }
    }

    // MARK: Reactions

    /// Actions implemented natively (reactions).
    nonisolated public var supportedMessageActions: Set<ChannelMessageActionName> {
        [.react]
    }

    /// Adds a reaction to the message identified by its timestamp.
    /// - Parameters:
    ///   - peerID: Recipient or `group:<id>`.
    ///   - messageID: Target message timestamp.
    ///   - emoji: Emoji.
    public func addReaction(peerID: String, messageID: String, emoji: String) async throws {
        try await self.react(peerID: peerID, messageID: messageID, emoji: emoji, remove: false)
    }

    /// Removes a reaction.
    /// - Parameters:
    ///   - peerID: Recipient or `group:<id>`.
    ///   - messageID: Target message timestamp.
    ///   - emoji: Emoji.
    public func removeReaction(peerID: String, messageID: String, emoji: String) async throws {
        try await self.react(peerID: peerID, messageID: messageID, emoji: emoji, remove: true)
    }

    /// Sends or removes a reaction (`/v1/reactions/<account>` or JSON-RPC `sendReaction`).
    /// - Parameters:
    ///   - peerID: Recipient or `group:<id>`.
    ///   - messageID: Target message timestamp.
    ///   - emoji: Emoji.
    ///   - remove: Whether to remove.
    public func react(peerID: String, messageID: String, emoji: String, remove: Bool) async throws {
        let account = try self.resolveAccountID(fromOutboundAccountID: nil)
        guard let targetTimestamp = Int64(messageID) else {
            throw ChannelMessageActionError.invalidParams("Signal reactions target a message timestamp")
        }
        let context = self.lastInbound[peerID]
        let targetAuthor = context?.timestamp == targetTimestamp ? context?.author : nil
        let author = targetAuthor ?? (peerID.hasPrefix("group:") ? nil : peerID)
        guard let author else {
            throw ChannelMessageActionError.invalidParams("Signal group reactions need the target author")
        }
        switch self.transportKind {
        case .externalNative:
            var params: [String: Any] = [
                "account": account, "emoji": emoji, "targetAuthor": author, "targetTimestamp": targetTimestamp, "remove": remove,
            ]
            Self.applyNativeTarget(peerID, to: &params)
            _ = try await self.rpc("sendReaction", params: params)
        case .container, .managedNative:
            var payload: [String: Any] = [
                "recipient": Self.containerRecipient(peerID.hasPrefix("group:") ? author : peerID),
                "reaction": emoji,
                "target_author": author,
                "timestamp": targetTimestamp,
            ]
            if peerID.hasPrefix("group:") {
                payload["group_id"] = Self.containerRecipient(peerID)
            }
            _ = try await self.rest(remove ? "DELETE" : "POST", path: "v1/reactions/\(Self.pathComponent(account))", payload: payload)
        }
    }

    // MARK: Receive loops

    private func containerReceiveLoop(account: String) async {
        var attempt = 0
        while self.started, !Task.isCancelled {
            if self.usesPolling {
                await self.pollLoop(account: account)
                return
            }
            var receivedFrame = false
            do {
                var request = URLRequest(url: try self.webSocketURL(account: account))
                self.authorize(&request)
                let socket = try await self.webSocketConnector.connect(request, maximumMessageSize: Self.maxFrameBytes)
                self.socket = socket
                while self.started, !Task.isCancelled {
                    let raw = try await socket.receive()
                    receivedFrame = true
                    attempt = 0
                    self.health = ChannelTransportHealth(state: .healthy)
                    await self.handleFrame(Data(raw.utf8), account: account)
                }
            } catch {
                await self.socket?.close()
                self.socket = nil
                guard self.started, !Task.isCancelled else { return }
                if !receivedFrame, attempt == 0 {
                    // The upgrade failed: the container runs in normal mode; use REST polling.
                    self.usesPolling = true
                    continue
                }
                self.health = ChannelTransportHealth(state: .degraded, lastError: "Signal receive socket failed: \(error.localizedDescription)")
                await ChannelAsync.sleep(milliseconds: ChannelAsync.backoffMs(attempt: attempt, initialMs: 1_000))
                attempt += 1
            }
        }
    }

    private func pollLoop(account: String) async {
        while !Task.isCancelled && self.started {
            do {
                try await self.pollOnce(account: account)
                if self.health.state != .healthy {
                    self.health = ChannelTransportHealth(state: .healthy)
                }
            } catch {
                self.health = ChannelTransportHealth(state: .degraded, lastError: "Signal poll failed: \(error.localizedDescription)")
            }
            await ChannelAsync.sleep(milliseconds: max(250, self.config.pollIntervalMs))
        }
    }

    private func pollOnce(account: String) async throws {
        var components = URLComponents(url: try self.endpoint("v1/receive/\(Self.pathComponent(account))"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "timeout", value: "0")]
        guard let url = components?.url else {
            throw OpenClawCoreError.invalidConfiguration("Signal receive URL is invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        self.authorize(&request)
        let response = try await self.transport.data(for: request)
        try ChannelHTTP.check(response)
        let parsed = try JSONDecoder().decode(SignalReceiveResponse.self, from: response.body)
        for envelope in parsed.messages {
            await self.handleEnvelope(envelope, account: account)
        }
    }

    private func sseLoop(account: String) async {
        var attempt = 0
        while self.started, !Task.isCancelled {
            do {
                var components = URLComponents(url: try self.endpoint("api/v1/events"), resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "account", value: account)]
                guard let url = components?.url else { throw OpenClawCoreError.invalidConfiguration("Signal events URL is invalid") }
                var request = URLRequest(url: url)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 24 * 60 * 60
                self.authorize(&request)
                var parser = ChannelSSEParser()
                for try await line in try await self.lineStreamer.lines(for: request) {
                    guard self.started else { return }
                    attempt = 0
                    self.health = ChannelTransportHealth(state: .healthy)
                    if let data = parser.feed(line) {
                        await self.handleFrame(Data(data.utf8), account: account)
                    }
                }
            } catch {
                self.health = ChannelTransportHealth(state: .degraded, lastError: "Signal event stream failed: \(error.localizedDescription)")
            }
            guard self.started, !Task.isCancelled else { return }
            await ChannelAsync.sleep(milliseconds: ChannelAsync.backoffMs(attempt: attempt, initialMs: 1_000))
            attempt += 1
        }
    }

    private func handleFrame(_ data: Data, account: String) async {
        guard data.count <= Self.maxFrameBytes, let envelope = try? JSONDecoder().decode(SignalInboundEnvelope.self, from: data) else {
            return
        }
        await self.handleEnvelope(envelope, account: account)
    }

    private func handleEnvelope(_ frame: SignalInboundEnvelope, account: String) async {
        let payload = frame.payload
        if payload?.syncMessage != nil, payload?.dataMessage == nil {
            return
        }
        let dataMessage = frame.dataMessage ?? payload?.dataMessage
        if dataMessage?.reaction != nil {
            return
        }
        let sourceUUID = payload?.sourceUuid
        guard let source = (frame.sourceNumber ?? frame.source ?? payload?.sourceNumber ?? payload?.source ?? sourceUUID)?.channelTrimmedNonEmpty
        else { return }
        if source == account || (sourceUUID != nil && sourceUUID == self.config.accountUUID) {
            return
        }
        guard let text = (frame.message ?? frame.text ?? dataMessage?.message)?.channelTrimmedNonEmpty else { return }
        let timestamp = frame.timestamp ?? payload?.timestamp ?? dataMessage?.timestamp ?? 0
        guard self.recentInbound.insert("\(source)|\(timestamp)|\(text)") else { return }
        let groupID = dataMessage?.groupInfo?.groupId?.channelTrimmedNonEmpty
        let peerID = groupID.map { "group:\($0)" } ?? source
        let mentioned: Bool? = groupID == nil
            ? nil
            : self.config.accountUUID.map { uuid in dataMessage?.mentions?.contains { $0.uuid == uuid || $0.number == account } ?? false }
        let quotedBot = dataMessage?.quote.map { $0.authorNumber == account || ($0.authorUuid != nil && $0.authorUuid == self.config.accountUUID) }
            ?? false
        self.lastInbound[peerID] = SignalInboundContext(author: source, timestamp: timestamp, groupID: groupID)
        var metadata: [String: String] = [:]
        if let groupName = dataMessage?.groupInfo?.groupName {
            metadata["groupName"] = groupName
        }
        let inbound = InboundMessage(
            channel: .signal,
            peerID: peerID,
            text: text,
            senderID: source,
            senderName: payload?.sourceName,
            chatType: groupID == nil ? .direct : .group,
            messageID: String(timestamp),
            replyToID: dataMessage?.quote?.id.map(String.init),
            wasMentioned: mentioned,
            implicitMentionKinds: quotedBot ? [.quotedBot] : [],
            recipientID: account,
            metadata: metadata,
            legacyRoutingAccountID: source
        )
        if let inboundHandler {
            await inboundHandler(inbound)
        }
        if self.config.sendReadReceipts, timestamp > 0 {
            await self.sendReadReceipt(account: account, recipient: source, timestamp: timestamp)
        }
    }

    private func sendReadReceipt(account: String, recipient: String, timestamp: Int64) async {
        switch self.transportKind {
        case .externalNative:
            _ = try? await self.rpc(
                "sendReceipt",
                params: ["account": account, "recipient": [recipient], "targetTimestamp": timestamp, "type": "read"]
            )
        case .container, .managedNative:
            _ = try? await self.rest(
                "POST",
                path: "v1/receipts/\(Self.pathComponent(account))",
                payload: ["recipient": Self.containerRecipient(recipient), "timestamp": timestamp, "receipt_type": "read"]
            )
        }
    }

    // MARK: HTTP helpers

    private func rest(_ method: String, path: String, payload: [String: Any]) async throws -> HTTPResponseData {
        var request = ChannelHTTP.jsonRequest(url: try self.endpoint(path), method: method, body: try ChannelHTTP.jsonBody(payload), timeout: 30)
        self.authorize(&request)
        let response = try await self.transport.data(for: request)
        try ChannelHTTP.check(response)
        return response
    }

    private func rpc(_ method: String, params: [String: Any]) async throws -> SignalRPCResponse.Result? {
        let body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params, "id": UUID().uuidString]
        let response = try await self.rest("POST", path: "api/v1/rpc", payload: body)
        if response.statusCode == 201 || response.body.isEmpty {
            return nil
        }
        let parsed = try JSONDecoder().decode(SignalRPCResponse.self, from: response.body)
        if let error = parsed.error {
            throw ChannelSendError.rejected(status: error.code ?? 0, detail: "Signal RPC \(method): \(error.message ?? "error")")
        }
        return parsed.result
    }

    private func authorize(_ request: inout URLRequest) {
        if let token = self.config.authToken?.channelTrimmedNonEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func webSocketURL(account: String) throws -> URL {
        guard var components = URLComponents(url: try self.endpoint("v1/receive/\(Self.pathComponent(account))"), resolvingAgainstBaseURL: false)
        else {
            throw OpenClawCoreError.invalidConfiguration("Signal receive URL is invalid")
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else {
            throw OpenClawCoreError.invalidConfiguration("Signal receive URL is invalid")
        }
        return url
    }

    private func endpoint(_ path: String) throws -> URL {
        var base = try self.resolveServiceURL().absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard let url = URL(string: base + "/" + path) else {
            throw OpenClawCoreError.invalidConfiguration("Signal service URL is invalid")
        }
        return url
    }

    private func resolveAccountID(fromOutboundAccountID outboundAccountID: String?) throws -> String {
        // Outbound account keys that look like E.164 numbers select that Signal number.
        if let outbound = outboundAccountID?.channelTrimmedNonEmpty, outbound.hasPrefix("+") {
            return outbound
        }
        if let configured = self.config.accountID?.channelTrimmedNonEmpty {
            return configured
        }
        throw OpenClawCoreError.invalidConfiguration("Signal account ID is required")
    }

    private func defaultRecipient() throws -> String {
        guard let fallback = self.config.defaultRecipient?.channelTrimmedNonEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Signal recipient is required")
        }
        return fallback
    }

    private func resolveRecipient(from message: OutboundMessage) throws -> String {
        try message.peerID.channelTrimmedNonEmpty ?? self.defaultRecipient()
    }

    private func resolveServiceURL() throws -> URL {
        let rawURL = self.explicitServiceURL?.absoluteString ?? self.config.serviceURL
        guard let trimmed = rawURL.channelTrimmedNonEmpty, let url = URL(string: trimmed) else {
            throw OpenClawCoreError.invalidConfiguration("Signal service URL is invalid")
        }
        return url
    }
}
