import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Native LINE Messaging API adapter (upstream `line` plugin, HTTPS + signed webhook).
///
/// - Inbound: route the webhook (default `/line/webhook`) to ``handleWebhook(headers:body:)``.
///   `X-Line-Signature` must equal base64(HMAC-SHA256(channelSecret, raw body)) (constant-time
///   compare). `message` events from `user`, `group` and `room` sources become inbound messages
///   (peer = user, group or room id); `join` emits a ``ChannelJoinEvent``. Media content is
///   downloaded from `api-data.line.me` within `mediaMaxMb`. Events are deduped by
///   `webhookEventId`.
/// - Outbound: chunks at 5,000 characters, batches of five messages; uses the reply API while
///   the conversation's reply token is fresh (50 s), otherwise the push API with
///   `X-Line-Retry-Key` (a 409 for a retried key is the earlier attempt's success). Receipts
///   carry `sentMessages[].id`.
/// - Typing: the loading animation (`/v2/bot/chat/loading/start`, 1:1 chats only).
public actor LineChannelAdapter: InboundChannelAdapter, ReceiptingChannelAdapter, JoinEventChannelAdapter,
    ChannelConfigurationReporting
{
    /// Messaging API base URL.
    public static let apiBaseURL = "https://api.line.me/v2/bot"
    /// Content API base URL.
    public static let dataBaseURL = "https://api-data.line.me/v2/bot"
    /// Reply tokens are used only while younger than this.
    public static let replyTokenTTL: TimeInterval = 50
    /// Messages per reply/push request.
    public static let maxMessagesPerRequest = 5

    /// Adapter channel identifier.
    public let id: ChannelID = .line

    private let config: LineChannelConfig
    private let accountID: String?
    private let transport: any ChannelHTTPTransport
    private let now: @Sendable () -> Date

    private var started = false
    private var accessToken: String?
    private var channelSecret: String?
    private var inboundHandler: InboundMessageHandler?
    private var joinHandler: ChannelJoinEventHandler?
    private var replyTokens: [String: (token: String, receivedAt: Date)] = [:]
    private var recentEventIDs = ChannelRecentIDs(capacity: 1_000)

    /// Creates a LINE adapter.
    /// - Parameters:
    ///   - config: `channels.line` settings (resolve SecretRefs first).
    ///   - accountID: Account to resolve.
    ///   - transport: HTTP transport.
    ///   - now: Clock (reply-token freshness).
    public init(
        config: LineChannelConfig,
        accountID: String? = nil,
        transport: any ChannelHTTPTransport = HTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config.resolvedAccount(accountID)
        self.accountID = accountID?.channelTrimmedNonEmpty
        self.transport = transport
        self.now = now
    }

    /// Registers or clears the inbound callback.
    /// - Parameter handler: Inbound handler.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Registers or clears the join-event callback.
    /// - Parameter handler: Callback.
    public func setJoinEventHandler(_ handler: ChannelJoinEventHandler?) async {
        self.joinHandler = handler
    }

    /// Webhook path the host must route to ``handleWebhook(headers:body:)``.
    nonisolated public var webhookPath: String {
        LineChannelConfig.normalizeWebhookPath(self.config.webhookPath)
    }

    /// Configured when a token and a secret (inline or files) are present.
    nonisolated public var configurationStatus: ChannelConfigurationStatus {
        self.config.isConfigured ? .configured : .unconfigured(reason: LineChannelConfig.unconfiguredReason)
    }

    /// Loading animation is supported for 1:1 chats.
    nonisolated public var supportsTypingIndicator: Bool {
        true
    }

    /// Resolves credentials (inline or `tokenFile`/`secretFile`) and starts accepting webhooks.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("LINE channel is disabled")
        }
        let token = try self.config.channelAccessToken?.channelTrimmedNonEmpty ?? Self.readSecretFile(self.config.tokenFile)
        let secret = try self.config.channelSecret?.channelTrimmedNonEmpty ?? Self.readSecretFile(self.config.secretFile)
        guard let token, let secret else {
            throw OpenClawCoreError.invalidConfiguration(LineChannelConfig.unconfiguredReason)
        }
        self.accessToken = token
        self.channelSecret = secret
        self.replyTokens.removeAll()
        self.started = true
    }

    /// Stops the adapter.
    public func stop() async {
        self.started = false
        self.replyTokens.removeAll()
    }

    /// Probes `GET /v2/bot/info`.
    /// - Parameter timeoutMs: Timeout.
    /// - Returns: Probe result with the bot display name.
    public func probe(timeoutMs: Int) async -> ChannelProbeResult {
        if case .unconfigured(let reason) = self.configurationStatus {
            return ChannelProbeResult(ok: false, detail: reason)
        }
        return await ChannelAsync.probe(timeoutMs: timeoutMs) { [self] in
            let token = try await self.token()
            let request = ChannelHTTP.jsonRequest(
                url: try Self.url(Self.apiBaseURL + "/info"),
                method: "GET",
                body: nil,
                headers: ["Authorization": "Bearer \(token)"]
            )
            let response = try await self.transport.data(for: request)
            try ChannelHTTP.check(response)
            return ChannelHTTP.jsonObject(response.body)?["displayName"] as? String
        }
    }

    // MARK: Inbound

    /// Handles one webhook delivery.
    /// - Parameters:
    ///   - headers: Request headers (`X-Line-Signature`).
    ///   - body: Raw body.
    /// - Returns: HTTP status and body.
    public func handleWebhook(headers: [String: String], body: Data) async -> (status: Int, body: String) {
        guard self.started, let secret = self.channelSecret else {
            return (503, "LINE channel is not started")
        }
        guard let signature = ChannelHTTP.header("X-Line-Signature", in: headers)?.channelTrimmedNonEmpty,
              ChannelWebhookSignature.constantTimeEquals(ChannelWebhookSignature.lineSignature(channelSecret: secret, body: body), signature)
        else {
            return (401, "Invalid signature")
        }
        guard let object = ChannelHTTP.jsonObject(body) else {
            return (400, "Invalid payload")
        }
        let events = object["events"] as? [[String: Any]] ?? []
        for event in events {
            if let eventID = event["webhookEventId"] as? String, !self.recentEventIDs.insert(eventID) {
                continue
            }
            await self.handleEvent(event)
        }
        return (200, "OK")
    }

    private func handleEvent(_ event: [String: Any]) async {
        let source = event["source"] as? [String: Any] ?? [:]
        let sourceType = source["type"] as? String ?? "user"
        let userID = source["userId"] as? String
        let conversationID: String?
        switch sourceType {
        case "group": conversationID = source["groupId"] as? String
        case "room": conversationID = source["roomId"] as? String
        default: conversationID = userID
        }
        guard let peerID = conversationID?.channelTrimmedNonEmpty else { return }
        if let replyToken = (event["replyToken"] as? String)?.channelTrimmedNonEmpty {
            self.replyTokens[peerID] = (replyToken, self.now())
        }
        switch event["type"] as? String {
        case "join":
            await self.joinHandler?(ChannelJoinEvent(channel: .line, accountID: self.accountID, peerID: peerID, chatType: .group))
        case "message":
            guard let message = event["message"] as? [String: Any] else { return }
            await self.handleMessage(message, peerID: peerID, sourceType: sourceType, userID: userID, event: event)
        default:
            return
        }
    }

    private func handleMessage(_ message: [String: Any], peerID: String, sourceType: String, userID: String?, event: [String: Any]) async {
        let type = message["type"] as? String ?? ""
        let messageID = message["id"] as? String
        var text = ""
        var attachments: [MediaAttachment] = []
        switch type {
        case "text":
            text = message["text"] as? String ?? ""
        case "image", "video", "audio", "file":
            if let messageID, let attachment = await self.downloadContent(messageID: messageID, type: type, fileName: message["fileName"] as? String) {
                attachments.append(attachment)
            } else {
                text = "[\(type) attachment could not be downloaded]"
            }
        case "sticker":
            text = "[sticker]"
        case "location":
            let title = message["title"] as? String
            let address = message["address"] as? String
            text = [title, address].compactMap { $0?.channelTrimmedNonEmpty }.joined(separator: "\n")
        default:
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let mentionees = (message["mention"] as? [String: Any])?["mentionees"] as? [[String: Any]] ?? []
        let mentioned = mentionees.contains { ($0["isSelf"] as? Bool) == true }
        let isGroup = sourceType == "group" || sourceType == "room"
        let quoted = (message["quotedMessageId"] as? String)?.channelTrimmedNonEmpty
        let inbound = InboundMessage(
            channel: .line,
            accountID: self.accountID,
            peerID: peerID,
            text: text,
            attachments: attachments,
            senderID: userID,
            chatType: isGroup ? .group : .direct,
            messageID: messageID,
            replyToID: quoted,
            wasMentioned: isGroup ? mentioned : nil,
            metadata: ["sourceType": sourceType]
        )
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    private func downloadContent(messageID: String, type: String, fileName: String?) async -> MediaAttachment? {
        guard let token = self.accessToken, let url = URL(string: "\(Self.dataBaseURL)/message/\(messageID)/content") else { return nil }
        let request = ChannelHTTP.jsonRequest(url: url, method: "GET", body: nil, headers: ["Authorization": "Bearer \(token)"], timeout: 30)
        guard let response = try? await self.transport.data(for: request), (200..<300).contains(response.statusCode) else { return nil }
        let maxBytes = Int((self.config.policy.mediaMaxMb ?? 10) * 1_024 * 1_024)
        guard response.body.count <= maxBytes else { return nil }
        let fallback: String
        switch type {
        case "image": fallback = "image/jpeg"
        case "video": fallback = "video/mp4"
        case "audio": fallback = "audio/m4a"
        default: fallback = "application/octet-stream"
        }
        let mimeType = ChannelHTTP.header("Content-Type", in: response.headers) ?? fallback
        return MediaAttachment(mimeType: mimeType, data: response.body, fileName: fileName, metadata: ["source": "line"])
    }

    // MARK: Outbound

    /// Shows the loading animation for 1:1 chats (user ids start with `U`).
    /// - Parameters:
    ///   - accountID: Unused.
    ///   - peerID: Conversation id.
    public func sendTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard self.started, peerID.hasPrefix("U") else { return }
        let token = try self.token()
        let body = try ChannelHTTP.jsonBody(["chatId": peerID, "loadingSeconds": 20])
        let url = try Self.url(Self.apiBaseURL + "/chat/loading/start")
        let request = ChannelHTTP.jsonRequest(url: url, body: body, headers: ["Authorization": "Bearer \(token)"])
        _ = try? await self.transport.data(for: request)
    }

    /// Sends text (5,000-character chunks, five per request).
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        _ = try await self.sendReturningReceipt(message)
    }

    /// Sends via the reply API while the reply token is fresh, otherwise via push.
    /// - Parameter message: Outbound payload.
    /// - Returns: Receipt with LINE message ids.
    public func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt {
        guard self.started else {
            throw OpenClawCoreError.unavailable("LINE adapter is not started")
        }
        let to = message.peerID.channelTrimmedNonEmpty ?? self.config.policy.defaultTo?.channelTrimmedNonEmpty ?? ""
        guard !to.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("LINE recipient is required")
        }
        let chunks = ChannelTextChunker.chunk(message.text, for: .line, policy: self.config.effectivePolicy)
        guard !chunks.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("LINE outbound text is required")
        }
        var ids: [String] = []
        var index = 0
        while index < chunks.count {
            let batch = Array(chunks[index..<min(index + Self.maxMessagesPerRequest, chunks.count)])
            let messages: [[String: Any]] = batch.map { ["type": "text", "text": $0] }
            ids += try await self.deliver(messages, to: to)
            index += batch.count
        }
        return ChannelSendReceipt(parts: ids.enumerated().map { ChannelSendReceipt.Part(platformMessageID: $0.element, index: $0.offset) })
    }

    private func deliver(_ messages: [[String: Any]], to: String) async throws -> [String] {
        if let reply = self.replyTokens.removeValue(forKey: to), self.now().timeIntervalSince(reply.receivedAt) < Self.replyTokenTTL {
            do {
                return try await self.post("reply", body: ["replyToken": reply.token, "messages": messages], retryKey: nil)
            } catch ChannelSendError.rejected(let status, _) where status == 400 {
                // Expired or reused reply token: nothing was delivered, fall back to push.
            }
        }
        return try await self.post("push", body: ["to": to, "messages": messages], retryKey: UUID().uuidString.lowercased())
    }

    private func post(_ operation: String, body: [String: Any], retryKey: String?) async throws -> [String] {
        let token = try self.token()
        var headers = ["Authorization": "Bearer \(token)"]
        if let retryKey {
            headers["X-Line-Retry-Key"] = retryKey
        }
        let url = try Self.url(Self.apiBaseURL + "/message/\(operation)")
        let request = ChannelHTTP.jsonRequest(url: url, body: try ChannelHTTP.jsonBody(body), headers: headers, timeout: 30)
        let response: HTTPResponseData
        do {
            response = try await self.transport.data(for: request)
        } catch {
            throw ChannelSendError.classify(error)
        }
        if !(retryKey != nil && response.statusCode == 409) {
            try ChannelHTTP.check(response)
        }
        let sent = ChannelHTTP.jsonObject(response.body)?["sentMessages"] as? [[String: Any]] ?? []
        return sent.compactMap { $0["id"] as? String }
    }

    private func token() throws -> String {
        guard let accessToken else {
            throw OpenClawCoreError.unavailable("LINE adapter is not started")
        }
        return accessToken
    }

    private static func url(_ raw: String) throws -> URL {
        guard let url = URL(string: raw) else {
            throw OpenClawCoreError.invalidConfiguration("Invalid LINE URL \(raw)")
        }
        return url
    }

    private static func readSecretFile(_ path: String?) throws -> String? {
        guard let path = path?.channelTrimmedNonEmpty else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw OpenClawCoreError.invalidConfiguration("LINE secret file is unreadable: \(path)")
        }
        return String(decoding: data, as: UTF8.self).channelTrimmedNonEmpty
    }
}
