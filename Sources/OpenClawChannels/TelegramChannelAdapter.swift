import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Minimal HTTP transport contract used by the Telegram adapter.
public protocol TelegramHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Normalized response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: TelegramHTTPTransport {}

// MARK: - Bot API payloads

private struct TelegramMe: Decodable {
    let id: Int64
    let isBot: Bool
    let username: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case username
    }
}

private struct TelegramUser: Decodable {
    let id: Int64
    let isBot: Bool?
    let firstName: String?
    let lastName: String?
    let username: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case firstName = "first_name"
        case lastName = "last_name"
        case username
    }

    var displayName: String? {
        let full = [self.firstName, self.lastName].compactMap(\.self).joined(separator: " ")
        return full.channelTrimmedNonEmpty ?? self.username
    }
}

private struct TelegramChat: Decodable {
    let id: Int64
    let type: String
    let title: String?
    let isForum: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case isForum = "is_forum"
    }
}

private struct TelegramEntity: Decodable {
    let type: String
    let offset: Int
    let length: Int
}

private struct TelegramReplyTarget: Decodable {
    let messageID: Int64
    let from: TelegramUser?

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from
    }
}

private struct TelegramMessage: Decodable {
    let messageID: Int64
    let text: String?
    let caption: String?
    let chat: TelegramChat
    let from: TelegramUser?
    let senderChat: TelegramChat?
    let entities: [TelegramEntity]?
    let messageThreadID: Int64?
    let isTopicMessage: Bool?
    let replyToMessage: TelegramReplyTarget?

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case text
        case caption
        case chat
        case from
        case senderChat = "sender_chat"
        case entities
        case messageThreadID = "message_thread_id"
        case isTopicMessage = "is_topic_message"
        case replyToMessage = "reply_to_message"
    }
}

private struct TelegramChatMember: Decodable {
    let status: String
    let user: TelegramUser
}

private struct TelegramChatMemberUpdated: Decodable {
    let chat: TelegramChat
    let date: Int64?
    let oldChatMember: TelegramChatMember
    let newChatMember: TelegramChatMember

    private enum CodingKeys: String, CodingKey {
        case chat
        case date
        case oldChatMember = "old_chat_member"
        case newChatMember = "new_chat_member"
    }
}

private struct TelegramUpdate: Decodable {
    let updateID: Int64
    let message: TelegramMessage?
    let channelPost: TelegramMessage?
    let myChatMember: TelegramChatMemberUpdated?

    private enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
        case channelPost = "channel_post"
        case myChatMember = "my_chat_member"
    }
}

private struct TelegramAPIResponse<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
    let errorCode: Int?
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case result
        case errorCode = "error_code"
        case description
    }
}

private struct TelegramSentMessage: Decodable {
    let messageID: Int64
    let messageThreadID: Int64?

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case messageThreadID = "message_thread_id"
    }
}

/// Classified `getUpdates` failure.
private enum TelegramPollFailure: Error {
    case conflict(String)
    case rateLimited(retryAfterMs: Int?, detail: String)
    case terminal(String)
    case transient(String)
}

/// Internal polling timings (upstream constants; overridable only in tests).
struct TelegramPollingTiming: Sendable {
    /// `getUpdates` long-poll timeout in seconds.
    var longPollTimeoutSeconds = 25
    /// URL request timeout for `getUpdates` (must exceed the long-poll timeout).
    var requestTimeoutSeconds: TimeInterval = 45
    /// Restart polling when no poll completes within this window (upstream 120 s).
    var stallThresholdMs = 120_000
    /// Watchdog check interval (upstream 30 s).
    var watchdogIntervalMs = 30_000
    /// A poll shorter than this with no updates means the server ignored long polling.
    var minimumLongPollMs = 500
}

/// Live Telegram channel adapter backed by Bot API long polling (upstream 2026.9.6 semantics).
///
/// Start sequence: `getMe`, then `deleteWebhook {drop_pending_updates: false}` to clear a stale
/// webhook, then `getUpdates?timeout=25` long polling.
/// - HTTP 409 (a duplicate poller or stale webhook) keeps polling: the transport health degrades
///   with upstream's conflict hint, the webhook is cleared again and polling backs off.
/// - HTTP 429 honors `parameters.retry_after` (capped at 60 s).
/// - 401/403/404 block the transport (revoked token); other failures retry with backoff.
/// - A stall watchdog restarts polling when no poll completes within 120 s.
///
/// Inbound messages carry chat type, forum topic (`message_thread_id` → `threadID`), sender name
/// and mentions (replies to the bot count as implicit mentions). Outbound text is chunked at
/// 4,000 characters with `reply_parameters` on the first chunk, `message_thread_id`,
/// `link_preview_options` and `disable_notification`. `my_chat_member` joins are emitted as
/// ``ChannelJoinEvent`` values.
public actor TelegramChannelAdapter: InboundChannelAdapter, ReceiptingChannelAdapter, ReactingChannelAdapter,
    ChannelMessageActions, ChannelConfigurationReporting, ChannelTransportHealthReporting, JoinEventChannelAdapter
{
    /// Adapter channel identifier.
    public let id: ChannelID = .telegram

    /// Upstream 409 hint surfaced in health and status.
    public static let conflictHint =
        "Another OpenClaw gateway, script, or Telegram poller may be using this bot token; stop the duplicate poller or switch this account to webhook mode."
    /// Upstream `TELEGRAM_TEXT_CHUNK_LIMIT`.
    public static let textChunkLimit = 4_000
    /// Update types requested from `getUpdates`.
    public static let allowedUpdates = ["message", "channel_post", "my_chat_member"]

    private let config: TelegramChannelConfig
    private let transport: any TelegramHTTPTransport
    private let explicitBaseURL: URL?
    private let offsetStore: any TelegramUpdateOffsetStore
    private let diagnosticsSink: RuntimeDiagnosticSink?
    private let timing: TelegramPollingTiming

    private var started = false
    private var pollTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var pollGeneration = 0
    private var pollInFlightSince: Date?
    private var inboundHandler: InboundMessageHandler?
    private var joinHandler: ChannelJoinEventHandler?
    private var botID: Int64?
    private var botUsername: String?
    private var nextOffset: Int64?
    private var recentUpdateIDs = ChannelRecentIDs(capacity: 512)
    private var threadByPeer: [String: Int64] = [:]
    private var health = ChannelTransportHealth()
    private var webhookCleared = false

    /// Creates a Telegram channel adapter.
    /// - Parameters:
    ///   - config: Telegram channel configuration (resolve SecretRefs with ``ChannelsConfig/resolvingSecrets(using:)``).
    ///   - transport: HTTP transport implementation.
    ///   - baseURL: Optional Telegram API root override (wins over `apiRoot`).
    ///   - offsetStore: Persistent storage for latest processed update offset.
    ///   - diagnosticsSink: Optional diagnostics sink.
    public init(
        config: TelegramChannelConfig,
        transport: any TelegramHTTPTransport = HTTPClient(),
        baseURL: URL? = nil,
        offsetStore: any TelegramUpdateOffsetStore = FileTelegramUpdateOffsetStore(),
        diagnosticsSink: RuntimeDiagnosticSink? = nil
    ) {
        self.init(
            config: config,
            transport: transport,
            baseURL: baseURL,
            offsetStore: offsetStore,
            diagnosticsSink: diagnosticsSink,
            timing: TelegramPollingTiming()
        )
    }

    init(
        config: TelegramChannelConfig,
        transport: any TelegramHTTPTransport,
        baseURL: URL?,
        offsetStore: any TelegramUpdateOffsetStore,
        diagnosticsSink: RuntimeDiagnosticSink?,
        timing: TelegramPollingTiming
    ) {
        self.config = config
        self.transport = transport
        self.explicitBaseURL = baseURL
        self.offsetStore = offsetStore
        self.diagnosticsSink = diagnosticsSink
        self.timing = timing
    }

    /// Registers an inbound handler invoked for accepted user messages.
    /// - Parameter handler: Optional async inbound handler closure.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Registers a handler for bot-joined-group events (`my_chat_member`).
    /// - Parameter handler: Optional join handler.
    public func setJoinEventHandler(_ handler: ChannelJoinEventHandler?) async {
        self.joinHandler = handler
    }

    /// Whether a bot token (or `tokenFile`) is configured.
    nonisolated public var configurationStatus: ChannelConfigurationStatus {
        let token = self.config.botToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !token.isEmpty || self.config.tokenFile?.channelTrimmedNonEmpty != nil {
            return .configured
        }
        return .unconfigured(reason: "Telegram requires botToken or tokenFile.")
    }

    /// Current `getUpdates` transport health.
    public func transportHealth() async -> ChannelTransportHealth {
        self.health
    }

    /// Starts adapter lifecycle: `getMe`, `deleteWebhook`, then long polling.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("Telegram channel is disabled")
        }
        if self.started {
            return
        }
        self.nextOffset = nil
        self.recentUpdateIDs.removeAll()
        if let persistedOffset = await self.offsetStore.readLastUpdateID() {
            self.nextOffset = max(0, persistedOffset + 1)
        }
        let token = try self.resolveToken()
        let me = try await self.fetchMe(token: token)
        self.botID = me.id
        self.botUsername = me.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.started = true
        self.health = ChannelTransportHealth(state: .healthy)
        await self.clearWebhook(token: token)
        self.startPolling(token: token)
        self.startWatchdog(token: token)
    }

    /// Stops adapter lifecycle and cancels background polling.
    public func stop() async {
        self.started = false
        self.pollGeneration += 1
        self.pollTask?.cancel()
        self.pollTask = nil
        self.watchdogTask?.cancel()
        self.watchdogTask = nil
        self.pollInFlightSince = nil
        self.health = ChannelTransportHealth(state: .stopped)
    }

    /// Probes credentials with `getMe`.
    /// - Parameter timeoutMs: Probe timeout.
    /// - Returns: Probe result with the bot username.
    public func probe(timeoutMs: Int) async -> ChannelProbeResult {
        if case .unconfigured(let reason) = self.configurationStatus {
            return ChannelProbeResult(ok: false, detail: reason)
        }
        return await ChannelAsync.probe(timeoutMs: timeoutMs) { [self] in
            let token = try await self.resolveToken()
            let me = try await self.fetchMe(token: token)
            return me.username.map { "@\($0)" } ?? "bot \(me.id)"
        }
    }

    // MARK: Outbound

    /// Sends an outbound message to Telegram.
    /// - Parameter message: Outbound message payload.
    public func send(_ message: OutboundMessage) async throws {
        _ = try await self.sendReturningReceipt(message)
    }

    /// Sends an outbound message and returns the Telegram `message_id` receipt.
    ///
    /// Text is chunked at 4,000 characters; only the first chunk carries `reply_parameters`.
    /// - Parameter message: Outbound payload.
    /// - Returns: Receipt with one part per chunk.
    public func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Telegram adapter is not started")
        }
        let token = try self.resolveToken()
        let chatID = try self.resolveTargetChatID(fromPeerID: message.peerID)
        let threadID = message.threadID.flatMap { Int64($0) }
        let chunks = ChannelTextChunker.chunk(message.text, limit: Self.textChunkLimit)
        guard !chunks.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Telegram outbound text is required")
        }
        var parts: [ChannelSendReceipt.Part] = []
        for (index, chunk) in chunks.enumerated() {
            var payload: [String: Any] = ["chat_id": chatID, "text": chunk]
            if let threadID {
                payload["message_thread_id"] = threadID
            }
            if index == 0, let replyTo = message.replyToID.flatMap({ Int64($0) }) {
                payload["reply_parameters"] = ["message_id": replyTo, "allow_sending_without_reply": true]
            }
            if self.config.additionalProperties["linkPreview"]?.boolValue == false {
                payload["link_preview_options"] = ["is_disabled": true]
            }
            if message.silent {
                payload["disable_notification"] = true
            }
            let sent: TelegramSentMessage = try await self.callSend(token: token, method: "sendMessage", payload: payload)
            parts.append(
                ChannelSendReceipt.Part(
                    platformMessageID: String(sent.messageID),
                    kind: .text,
                    index: index,
                    threadID: sent.messageThreadID.map(String.init) ?? message.threadID,
                    replyToID: index == 0 ? message.replyToID : nil
                )
            )
        }
        return ChannelSendReceipt(parts: parts, threadID: message.threadID, replyToID: message.replyToID)
    }

    /// Telegram supports `sendChatAction` typing indicators.
    nonisolated public var supportsTypingIndicator: Bool {
        true
    }

    /// Sends `sendChatAction typing` (renewed by the engine every 4,000 ms), in the peer's last topic.
    /// - Parameters:
    ///   - accountID: Channel account key (unused).
    ///   - peerID: Chat id.
    public func sendTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Telegram adapter is not started")
        }
        let token = try self.resolveToken()
        let chatID = try self.resolveTargetChatID(fromPeerID: peerID)
        var payload: [String: Any] = ["chat_id": chatID, "action": "typing"]
        if let thread = self.threadByPeer[peerID] {
            payload["message_thread_id"] = thread
        }
        let _: Bool = try await self.callSend(token: token, method: "sendChatAction", payload: payload)
    }

    // MARK: Reactions and message actions

    /// Actions implemented natively (Bot API `setMessageReaction`, `editMessageText`, `deleteMessage`, `sendPoll`).
    nonisolated public var supportedMessageActions: Set<ChannelMessageActionName> {
        [.react, .edit, .unsend, .delete, .poll]
    }

    /// Adds a reaction (`setMessageReaction`).
    /// - Parameters:
    ///   - peerID: Chat id.
    ///   - messageID: Message id.
    ///   - emoji: Emoji from Telegram's reaction set.
    public func addReaction(peerID: String, messageID: String, emoji: String) async throws {
        try await self.react(peerID: peerID, messageID: messageID, emoji: emoji, remove: false)
    }

    /// Removes the bot's reactions (`setMessageReaction` with an empty list).
    /// - Parameters:
    ///   - peerID: Chat id.
    ///   - messageID: Message id.
    ///   - emoji: Emoji (Telegram clears all bot reactions).
    public func removeReaction(peerID: String, messageID: String, emoji: String) async throws {
        try await self.react(peerID: peerID, messageID: messageID, emoji: emoji, remove: true)
    }

    /// Sets or clears the bot's reaction on a message.
    /// - Parameters:
    ///   - peerID: Chat id.
    ///   - messageID: Message id.
    ///   - emoji: Emoji.
    ///   - remove: Whether to clear the reaction.
    public func react(peerID: String, messageID: String, emoji: String, remove: Bool) async throws {
        let token = try self.resolveToken()
        let payload: [String: Any] = [
            "chat_id": try self.resolveTargetChatID(fromPeerID: peerID),
            "message_id": try Self.messageID(messageID),
            "reaction": remove ? [] : [["type": "emoji", "emoji": emoji]],
        ]
        let _: Bool = try await self.callSend(token: token, method: "setMessageReaction", payload: payload)
    }

    /// Edits a sent message (`editMessageText`).
    /// - Parameters:
    ///   - peerID: Chat id.
    ///   - messageID: Message id.
    ///   - text: Replacement text.
    public func edit(peerID: String, messageID: String, text: String) async throws {
        let token = try self.resolveToken()
        let payload: [String: Any] = [
            "chat_id": try self.resolveTargetChatID(fromPeerID: peerID),
            "message_id": try Self.messageID(messageID),
            "text": text,
        ]
        let _: TelegramSentMessage = try await self.callSend(token: token, method: "editMessageText", payload: payload)
    }

    /// Deletes a message (`deleteMessage`).
    /// - Parameters:
    ///   - peerID: Chat id.
    ///   - messageID: Message id.
    public func unsend(peerID: String, messageID: String) async throws {
        let token = try self.resolveToken()
        let payload: [String: Any] = [
            "chat_id": try self.resolveTargetChatID(fromPeerID: peerID),
            "message_id": try Self.messageID(messageID),
        ]
        let _: Bool = try await self.callSend(token: token, method: "deleteMessage", payload: payload)
    }

    /// Sends a native poll (`sendPoll`).
    /// - Parameters:
    ///   - peerID: Chat id.
    ///   - question: Question.
    ///   - options: Two to ten options.
    ///   - allowMultiple: Whether multiple answers are allowed.
    /// - Returns: Poll message receipt.
    public func sendPoll(peerID: String, question: String, options: [String], allowMultiple: Bool) async throws -> ChannelSendReceipt? {
        let token = try self.resolveToken()
        var payload: [String: Any] = [
            "chat_id": try self.resolveTargetChatID(fromPeerID: peerID),
            "question": question,
            "options": options.map { ["text": $0] },
            "allows_multiple_answers": allowMultiple,
        ]
        if let thread = self.threadByPeer[peerID] {
            payload["message_thread_id"] = thread
        }
        let sent: TelegramSentMessage = try await self.callSend(token: token, method: "sendPoll", payload: payload)
        return ChannelSendReceipt(platformMessageID: String(sent.messageID), kind: .poll)
    }

    // MARK: Polling

    private func startPolling(token: String) {
        self.pollGeneration += 1
        let generation = self.pollGeneration
        self.pollTask?.cancel()
        self.pollTask = Task { [weak self] in
            await self?.pollLoop(token: token, generation: generation)
        }
    }

    private func startWatchdog(token: String) {
        self.watchdogTask?.cancel()
        let interval = self.timing.watchdogIntervalMs
        self.watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                await ChannelAsync.sleep(milliseconds: interval)
                guard let self, !Task.isCancelled else { return }
                await self.checkForStall(token: token)
            }
        }
    }

    private func checkForStall(token: String) async {
        guard self.started, let since = self.pollInFlightSince else { return }
        guard Date().timeIntervalSince(since) * 1_000 >= Double(self.timing.stallThresholdMs) else { return }
        let message = "Telegram polling stalled for \(self.timing.stallThresholdMs / 1_000) s; restarting getUpdates."
        self.health = ChannelTransportHealth(state: .degraded, lastError: message)
        self.pollInFlightSince = nil
        await self.emitDiagnostic("telegram.polling.stall_restart", ["thresholdMs": String(self.timing.stallThresholdMs)])
        self.startPolling(token: token)
    }

    private func pollLoop(token: String, generation: Int) async {
        var failures = 0
        while !Task.isCancelled, self.started, generation == self.pollGeneration {
            let startedAt = Date()
            self.pollInFlightSince = startedAt
            do {
                let processed = try await self.pollOnce(token: token)
                guard generation == self.pollGeneration else { return }
                self.pollInFlightSince = nil
                failures = 0
                if self.health.state != .healthy {
                    self.health = ChannelTransportHealth(state: .healthy)
                }
                if processed == 0, Date().timeIntervalSince(startedAt) * 1_000 < Double(self.timing.minimumLongPollMs) {
                    // The server answered immediately (no long polling); avoid a tight loop.
                    await ChannelAsync.sleep(milliseconds: max(250, self.config.pollIntervalMs))
                }
            } catch let failure as TelegramPollFailure {
                guard generation == self.pollGeneration else { return }
                self.pollInFlightSince = nil
                failures += 1
                switch failure {
                case .conflict(let detail):
                    let message = "Telegram getUpdates conflict: \(detail). \(Self.conflictHint)"
                    self.health = ChannelTransportHealth(state: .degraded, lastError: message)
                    await self.emitDiagnostic("telegram.polling.conflict", [:])
                    self.webhookCleared = false
                    await self.clearWebhook(token: token)
                    await ChannelAsync.sleep(milliseconds: self.backoffMs(failures: failures))
                case .rateLimited(let retryAfterMs, let detail):
                    self.health = ChannelTransportHealth(state: .degraded, lastError: "Telegram getUpdates rate limited: \(detail)")
                    let delay = min(ChannelSendError.retryAfterCapMs, retryAfterMs ?? self.backoffMs(failures: failures))
                    await ChannelAsync.sleep(milliseconds: max(delay, 1))
                case .terminal(let detail):
                    self.health = ChannelTransportHealth(state: .blocked, lastError: detail)
                    await self.emitDiagnostic("telegram.polling.blocked", [:])
                    self.started = false
                    return
                case .transient(let detail):
                    self.health = ChannelTransportHealth(state: .degraded, lastError: detail)
                    await ChannelAsync.sleep(milliseconds: self.backoffMs(failures: failures))
                }
            } catch {
                guard generation == self.pollGeneration else { return }
                self.pollInFlightSince = nil
                failures += 1
                if error is CancellationError || Task.isCancelled { return }
                self.health = ChannelTransportHealth(
                    state: .degraded,
                    lastError: "Telegram getUpdates failed: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
                )
                await ChannelAsync.sleep(milliseconds: self.backoffMs(failures: failures))
            }
        }
    }

    private func backoffMs(failures: Int) -> Int {
        let base = max(250, self.config.pollIntervalMs)
        let exponent = min(max(0, failures - 1), 6)
        return min(30_000, base * (1 << exponent))
    }

    /// Runs one `getUpdates` call and dispatches its updates; returns the number of new updates.
    private func pollOnce(token: String) async throws -> Int {
        var components = URLComponents(
            url: try self.resolveEndpoint(token: token, method: "getUpdates"),
            resolvingAgainstBaseURL: false
        )
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "timeout", value: String(self.timing.longPollTimeoutSeconds)),
            URLQueryItem(name: "limit", value: "100"),
        ]
        if let nextOffset {
            queryItems.append(URLQueryItem(name: "offset", value: String(nextOffset)))
        }
        let allowed = "[" + Self.allowedUpdates.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        queryItems.append(URLQueryItem(name: "allowed_updates", value: allowed))
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw OpenClawCoreError.invalidConfiguration("Invalid Telegram updates URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = max(self.timing.requestTimeoutSeconds, TimeInterval(self.timing.longPollTimeoutSeconds + 10))
        let response: HTTPResponseData
        do {
            response = try await self.transport.data(for: request)
        } catch {
            throw TelegramPollFailure.transient(
                "Telegram getUpdates failed: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
            )
        }
        let parsed = try? JSONDecoder().decode(TelegramAPIResponse<[TelegramUpdate]>.self, from: response.body)
        let failed = !(200..<300).contains(response.statusCode) || parsed?.ok == false
        if failed {
            let errorCode = parsed?.errorCode ?? response.statusCode
            let detail = parsed?.description ?? "HTTP \(response.statusCode)"
            switch errorCode {
            case 409:
                throw TelegramPollFailure.conflict(detail)
            case 429:
                throw TelegramPollFailure.rateLimited(
                    retryAfterMs: ChannelSendError.telegramRetryAfterMs(body: response.body),
                    detail: detail
                )
            case 401, 403, 404:
                throw TelegramPollFailure.terminal("Telegram getUpdates failed (\(errorCode)): \(detail)")
            default:
                throw TelegramPollFailure.transient("Telegram getUpdates failed (\(errorCode)): \(detail)")
            }
        }
        guard let parsed, parsed.ok else {
            throw TelegramPollFailure.transient("Telegram getUpdates returned an invalid response")
        }
        let updates = (parsed.result ?? []).sorted { $0.updateID < $1.updateID }
        var processed = 0
        for update in updates {
            guard !self.shouldSkipUpdateID(update.updateID) else {
                continue
            }
            processed += 1
            self.nextOffset = max(self.nextOffset ?? 0, update.updateID + 1)
            await self.offsetStore.writeLastUpdateID(update.updateID)
            if let member = update.myChatMember {
                await self.handleMembership(member)
            }
            if let message = update.message ?? update.channelPost {
                await self.dispatch(message)
            }
        }
        return processed
    }

    private func dispatch(_ message: TelegramMessage) async {
        let rawText = (message.text ?? message.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return }
        if let from = message.from, from.isBot == true || from.id == self.botID {
            return
        }
        let isPrivate = message.chat.type == "private"
        let mentioned = self.isMentioningBot(message)
        let repliesToBot = message.replyToMessage?.from?.id != nil && message.replyToMessage?.from?.id == self.botID
        if self.config.mentionOnly, !isPrivate, message.chat.type != "channel", !mentioned, !repliesToBot {
            return
        }
        let peerID = String(message.chat.id)
        // Only forum topics are addressable threads; reply chains in plain groups also carry
        // message_thread_id, which the Bot API rejects on send outside forums.
        let topicThread = (message.isTopicMessage == true || message.chat.isForum == true) ? message.messageThreadID : nil
        let threadID = topicThread.map(String.init)
        if let thread = topicThread {
            self.threadByPeer[peerID] = thread
        } else {
            self.threadByPeer.removeValue(forKey: peerID)
        }
        let senderID = message.from.map { String($0.id) } ?? message.senderChat.map { String($0.id) }
        var metadata: [String: String] = [:]
        if let title = message.chat.title {
            metadata["chatTitle"] = title
        }
        let inbound = InboundMessage(
            channel: .telegram,
            accountID: nil,
            peerID: peerID,
            text: self.normalizedInboundText(rawText, isPrivate: isPrivate),
            senderID: senderID,
            senderName: message.from?.displayName ?? message.senderChat?.title,
            chatType: Self.chatType(for: message.chat.type),
            messageID: String(message.messageID),
            threadID: threadID,
            replyToID: message.replyToMessage.map { String($0.messageID) },
            wasMentioned: isPrivate ? nil : mentioned,
            implicitMentionKinds: repliesToBot ? [.replyToBot] : [],
            isFromBot: message.from?.isBot == true,
            recipientID: self.botID.map(String.init),
            metadata: metadata,
            legacyRoutingAccountID: senderID
        )
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    private func handleMembership(_ update: TelegramChatMemberUpdated) async {
        guard let botID, update.newChatMember.user.id == botID else { return }
        let wasOut = ["left", "kicked"].contains(update.oldChatMember.status)
        let isIn = ["member", "administrator", "creator", "restricted"].contains(update.newChatMember.status)
        guard wasOut, isIn, update.chat.type != "private" else { return }
        let event = ChannelJoinEvent(
            channel: .telegram,
            peerID: String(update.chat.id),
            roomName: update.chat.title,
            chatType: Self.chatType(for: update.chat.type),
            joinedAt: update.date.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        )
        if let joinHandler {
            await joinHandler(event)
        }
    }

    private func shouldSkipUpdateID(_ updateID: Int64) -> Bool {
        if let nextOffset, updateID < nextOffset {
            return true
        }
        return !self.recentUpdateIDs.insert(String(updateID))
    }

    /// Maps Telegram `chat.type` onto the envelope chat type.
    private static func chatType(for rawType: String) -> ChannelChatType {
        switch rawType.lowercased() {
        case "private": .direct
        case "channel": .channel
        default: .group
        }
    }

    private func isMentioningBot(_ message: TelegramMessage) -> Bool {
        guard let username = self.botUsername?.lowercased(), !username.isEmpty else {
            return false
        }
        let text = message.text ?? message.caption ?? ""
        if text.lowercased().contains("@\(username)") {
            return true
        }
        guard let entities = message.entities, !entities.isEmpty else {
            return false
        }
        let utf16 = Array(text.utf16)
        for entity in entities where entity.type == "mention" {
            guard entity.offset >= 0, entity.length > 0, entity.offset + entity.length <= utf16.count else { continue }
            let mention = String(decoding: utf16[entity.offset..<(entity.offset + entity.length)], as: UTF16.self)
            if mention.lowercased() == "@\(username)" {
                return true
            }
        }
        return false
    }

    private func normalizedInboundText(_ raw: String, isPrivate: Bool) -> String {
        var text = raw
        if self.config.mentionOnly, !isPrivate, let username = self.botUsername?.channelTrimmedNonEmpty {
            text = text.replacingOccurrences(of: "@\(username)", with: " ", options: .caseInsensitive)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Bot API calls

    private func clearWebhook(token: String) async {
        guard !self.webhookCleared else { return }
        do {
            let _: Bool = try await self.callSend(token: token, method: "deleteWebhook", payload: ["drop_pending_updates": false])
            self.webhookCleared = true
        } catch {
            // Upstream continues to polling so getUpdates can confirm the webhook state.
            await self.emitDiagnostic("telegram.webhook.clear_failed", ["error": String(describing: error)])
        }
    }

    private func callSend<T: Decodable>(token: String, method: String, payload: [String: Any]) async throws -> T {
        let endpoint = try self.resolveEndpoint(token: token, method: method)
        let request = ChannelHTTP.jsonRequest(url: endpoint, body: try ChannelHTTP.jsonBody(payload), timeout: 60)
        let response = try await self.transport.data(for: request)
        try ChannelHTTP.check(response)
        let parsed = try JSONDecoder().decode(TelegramAPIResponse<T>.self, from: response.body)
        guard parsed.ok, let result = parsed.result else {
            let code = parsed.errorCode ?? 400
            if code == 429 {
                throw ChannelSendError.rateLimited(retryAfterMs: ChannelSendError.telegramRetryAfterMs(body: response.body))
            }
            throw ChannelSendError.rejected(status: code, detail: "Telegram \(method) failed: \(parsed.description ?? "not ok")")
        }
        return result
    }

    private func fetchMe(token: String) async throws -> TelegramMe {
        let endpoint = try self.resolveEndpoint(token: token, method: "getMe")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Telegram identity check failed with status \(response.statusCode)")
        }
        let parsed = try JSONDecoder().decode(TelegramAPIResponse<TelegramMe>.self, from: response.body)
        guard parsed.ok, let me = parsed.result else {
            throw OpenClawCoreError.unavailable("Telegram identity response was not ok")
        }
        return me
    }

    private static func messageID(_ raw: String) throws -> Int64 {
        guard let value = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ChannelMessageActionError.invalidParams("Telegram message ids are integers")
        }
        return value
    }

    private func resolveTargetChatID(fromPeerID peerID: String) throws -> Int64 {
        if let parsed = Int64(peerID.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        if let configured = self.config.defaultChatID?.trimmingCharacters(in: .whitespacesAndNewlines),
           let parsed = Int64(configured)
        {
            return parsed
        }
        throw OpenClawCoreError.invalidConfiguration("Telegram default chat ID is required")
    }

    private func resolveToken() throws -> String {
        if let token = self.config.botToken?.channelTrimmedNonEmpty {
            return token
        }
        if let path = self.config.tokenFile?.channelTrimmedNonEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            if let token = (try? String(contentsOfFile: expanded, encoding: .utf8))?.channelTrimmedNonEmpty {
                return token
            }
            throw OpenClawCoreError.invalidConfiguration("Telegram tokenFile \(path) is missing or empty")
        }
        throw OpenClawCoreError.invalidConfiguration("Telegram bot token is required")
    }

    /// Normalizes `apiRoot` like upstream: trims trailing slashes and drops a trailing `/bot<TOKEN>` segment.
    /// - Parameter raw: Configured API root.
    /// - Returns: Normalized root URL string.
    static func normalizeAPIRoot(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "https://api.telegram.org" }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        var segments = components.path.split(separator: "/").map(String.init)
        if let last = segments.last, last.range(of: "^bot\\d+:[^/]+$", options: .regularExpression) != nil {
            segments.removeLast()
            components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
            components.query = nil
            components.fragment = nil
            return components.string ?? trimmed
        }
        return trimmed
    }

    private func resolveEndpoint(token: String, method: String) throws -> URL {
        let rawBase = self.explicitBaseURL?.absoluteString ?? self.config.baseURL
        let base = Self.normalizeAPIRoot(rawBase)
        guard !base.isEmpty, let baseURL = URL(string: base) else {
            throw OpenClawCoreError.invalidConfiguration("Telegram base URL is invalid")
        }
        return baseURL
            .appendingPathComponent("bot\(token)")
            .appendingPathComponent(method)
    }

    private func emitDiagnostic(_ name: String, _ metadata: [String: String]) async {
        guard let diagnosticsSink else { return }
        await diagnosticsSink(RuntimeDiagnosticEvent(subsystem: "channel", name: name, metadata: metadata))
    }
}
