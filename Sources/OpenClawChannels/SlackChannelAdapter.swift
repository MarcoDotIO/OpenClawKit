import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Minimal HTTP transport contract used by the Slack adapter.
public protocol SlackHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Normalized response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: SlackHTTPTransport {}

// MARK: - Payloads

private struct SlackAuthTestResponse: Decodable {
    let ok: Bool
    let error: String?
    let userID: String?
    let botID: String?
    let user: String?
    let team: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case error
        case userID = "user_id"
        case botID = "bot_id"
        case user
        case team
    }
}

private struct SlackGenericResponse: Decodable {
    let ok: Bool
    let error: String?
    let ts: String?
    let url: String?
    let warning: String?
}

private struct SlackConversationsHistoryResponse: Decodable {
    let ok: Bool
    let error: String?
    let messages: [SlackEvent]?
}

/// Slack message-like event (Events API `message`, `app_mention`, `member_joined_channel`).
struct SlackEvent: Decodable, Sendable {
    let type: String?
    let subtype: String?
    let user: String?
    let botID: String?
    let text: String?
    let ts: String?
    let threadTS: String?
    let channel: String?
    let channelType: String?
    let eventTS: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case subtype
        case user
        case botID = "bot_id"
        case text
        case ts
        case threadTS = "thread_ts"
        case channel
        case channelType = "channel_type"
        case eventTS = "event_ts"
    }
}

private struct SlackEventCallback: Decodable {
    let type: String?
    let challenge: String?
    let eventID: String?
    let event: SlackEvent?

    private enum CodingKeys: String, CodingKey {
        case type
        case challenge
        case eventID = "event_id"
        case event
    }
}

private struct SlackSocketEnvelope: Decodable {
    let type: String?
    let envelopeID: String?
    let reason: String?
    let payload: SlackEventCallback?

    private enum CodingKeys: String, CodingKey {
        case type
        case envelopeID = "envelope_id"
        case reason
        case payload
    }
}

private struct SlackRelayFrame: Decodable {
    struct Route: Decodable {
        let kind: String?
        let key: String?
    }

    struct Identity: Decodable {
        let username: String?
        let iconURL: String?
        let iconEmoji: String?

        private enum CodingKeys: String, CodingKey {
            case username
            case iconURL = "icon_url"
            case iconEmoji = "icon_emoji"
        }
    }

    struct Payload: Decodable {
        let event: SlackEvent?
    }

    let type: String?
    let deliveryID: String?
    let route: Route?
    let payload: Payload?
    let slackIdentity: Identity?

    private enum CodingKeys: String, CodingKey {
        case type
        case deliveryID = "delivery_id"
        case route
        case payload
        case slackIdentity = "slack_identity"
    }
}

/// Post identity announced by a relay `hello` frame.
public struct SlackPostIdentity: Sendable, Equatable {
    /// Display name override.
    public var username: String?
    /// Avatar URL override.
    public var iconURL: String?
    /// Emoji avatar override.
    public var iconEmoji: String?

    /// Creates a post identity.
    /// - Parameters:
    ///   - username: Display name.
    ///   - iconURL: Avatar URL.
    ///   - iconEmoji: Emoji avatar.
    public init(username: String? = nil, iconURL: String? = nil, iconEmoji: String? = nil) {
        self.username = username
        self.iconURL = iconURL
        self.iconEmoji = iconEmoji
    }
}

private struct SlackInboundContext: Sendable {
    let ts: String
    let threadTS: String?
    let chatType: ChannelChatType
}

/// Slack channel adapter (upstream 2026.9.6 semantics).
///
/// Ingestion follows `mode`:
/// - ``SlackConnectionMode/socket`` (default): `apps.connections.open` with the app token, then a
///   Socket Mode WebSocket; every envelope is acked immediately. Reconnects back off
///   2 s → 30 s (factor 1.8, jitter 0.25); auth errors (`invalid_auth`, `token_revoked`, ...) block.
///   Without an app token the adapter falls back to legacy ``SlackConnectionMode/poll``.
/// - ``SlackConnectionMode/http``: the host routes Events API requests (default `/slack/events`)
///   to ``handleEventsWebhook(headers:body:)``, which verifies `X-Slack-Signature` (v0 HMAC-SHA256,
///   300 s skew) and answers `url_verification`.
/// - ``SlackConnectionMode/relay``: WebSocket to `relay.url` (`https`→`wss`; `ws` only for
///   localhost), `gateway_id` query and bearer auth; `slack_event` frames are acked after the
///   inbound handler accepts them.
/// - ``SlackConnectionMode/poll``: legacy `conversations.history` polling of `defaultChannelID`.
///
/// Semantics: `im` → direct, `mpim` → group (requires `dm.groupEnabled`), channels → channel
/// (thread replies → thread with `threadID`). `requireMention` defaults to true for channels
/// (`channels.<id>.requireMention` overrides); `ignoreOtherMentions` drops messages addressed to
/// others. Outbound `chat.postMessage` chunks at 8,000 characters, threads per `replyToMode` /
/// `replyToModeByChatType` (default `off`), and sends `unfurl_links: false` unless enabled.
/// Typing uses `agents.sessions.setStatus` (`processing` → `active`) and the optional
/// `typingReaction`; the invalid `chat.typing` call was removed.
public actor SlackChannelAdapter: InboundChannelAdapter, ReceiptingChannelAdapter, ReactingChannelAdapter, ChannelMessageActions,
    ChannelConfigurationReporting, ChannelTransportHealthReporting, JoinEventChannelAdapter
{
    /// Adapter channel identifier.
    public let id: ChannelID = .slack

    /// Upstream Slack text limit per message.
    public static let textChunkLimit = 8_000
    /// Relay frame size cap (1 MiB).
    public static let relayMaxFrameBytes = 1_024 * 1_024
    /// Signature timestamp skew window in seconds.
    public static let signatureSkewSeconds: TimeInterval = 300
    /// Slack auth errors that stop reconnecting (upstream `SLACK_AUTH_ERROR_RE`).
    public static let terminalAuthErrors: Set<String> = [
        "account_inactive", "invalid_auth", "token_revoked", "token_expired", "not_authed", "org_login_required",
        "team_access_not_granted", "user_removed_from_team", "team_disabled", "missing_scope", "cannot_find_service",
        "invalid_token",
    ]

    private let config: SlackChannelConfig
    private let transport: any SlackHTTPTransport
    private let explicitBaseURL: URL?
    private let pollIntervalMs: Int
    private let webSocketConnector: any ChannelWebSocketConnecting
    private let now: @Sendable () -> Date

    private var started = false
    private var ingestTask: Task<Void, Never>?
    private var socket: (any ChannelWebSocketConnection)?
    private var inboundHandler: InboundMessageHandler?
    private var joinHandler: ChannelJoinEventHandler?
    private var botUserID: String?
    private var botID: String?
    private var hasInitializedCursor = false
    private var lastSeenTimestamp: Double?
    private var recentEvents = ChannelRecentIDs(capacity: 1_024)
    private var lastInbound: [String: SlackInboundContext] = [:]
    private var activeStatus: [String: (channel: String, threadTS: String)] = [:]
    private var activeReaction: [String: (channel: String, ts: String, name: String)] = [:]
    private var botThreads: Set<String> = []
    private var relayIdentity: SlackPostIdentity?
    private var health = ChannelTransportHealth()
    private var warnedMissingStopSubscription = false

    /// Creates a Slack channel adapter.
    /// - Parameters:
    ///   - config: Slack channel configuration (resolve SecretRefs first).
    ///   - transport: HTTP transport implementation.
    ///   - baseURL: Optional Slack API base URL override.
    ///   - pollIntervalMs: Polling interval for the legacy `poll` mode.
    ///   - webSocketConnector: WebSocket connector for Socket Mode and relay.
    public init(
        config: SlackChannelConfig,
        transport: any SlackHTTPTransport = HTTPClient(),
        baseURL: URL? = nil,
        pollIntervalMs: Int = 2_000,
        webSocketConnector: any ChannelWebSocketConnecting = URLSessionChannelWebSocketConnector()
    ) {
        self.init(
            config: config,
            transport: transport,
            baseURL: baseURL,
            pollIntervalMs: pollIntervalMs,
            webSocketConnector: webSocketConnector,
            now: { Date() }
        )
    }

    init(
        config: SlackChannelConfig,
        transport: any SlackHTTPTransport,
        baseURL: URL?,
        pollIntervalMs: Int,
        webSocketConnector: any ChannelWebSocketConnecting,
        now: @escaping @Sendable () -> Date
    ) {
        self.config = config
        self.transport = transport
        self.explicitBaseURL = baseURL
        self.pollIntervalMs = max(250, pollIntervalMs)
        self.webSocketConnector = webSocketConnector
        self.now = now
    }

    /// Registers or clears inbound callback.
    /// - Parameter handler: Optional inbound callback.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Registers a handler for `member_joined_channel` events about the bot.
    /// - Parameter handler: Optional join handler.
    public func setJoinEventHandler(_ handler: ChannelJoinEventHandler?) async {
        self.joinHandler = handler
    }

    /// Ingestion mode actually used (`socket` without an app token falls back to `poll`).
    nonisolated public var effectiveMode: SlackConnectionMode {
        if self.config.mode == .socket, self.config.appToken?.channelTrimmedNonEmpty == nil {
            return .poll
        }
        return self.config.mode
    }

    /// Events API path for ``SlackConnectionMode/http`` (default `/slack/events`).
    nonisolated public var webhookPath: String {
        self.config.webhookPath
    }

    /// Configuration status: a bot token, plus the mode's credentials.
    nonisolated public var configurationStatus: ChannelConfigurationStatus {
        guard self.config.botToken?.channelTrimmedNonEmpty != nil else {
            return .unconfigured(reason: "Slack requires botToken.")
        }
        switch self.effectiveMode {
        case .http where self.config.signingSecret?.channelTrimmedNonEmpty == nil:
            return .unconfigured(reason: "Slack HTTP mode requires signingSecret.")
        case .relay
            where self.config.relay?.url?.channelTrimmedNonEmpty == nil || self.config.relay?.authToken?.channelTrimmedNonEmpty == nil
            || self.config.relay?.gatewayID?.channelTrimmedNonEmpty == nil:
            return .unconfigured(reason: "Slack relay mode requires relay.url, relay.authToken and relay.gatewayId.")
        default:
            return .configured
        }
    }

    /// Current ingestion health.
    public func transportHealth() async -> ChannelTransportHealth {
        self.health
    }

    // MARK: Lifecycle

    /// Starts the adapter (`auth.test`, then the configured ingestion mode).
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("Slack channel is disabled")
        }
        if self.started {
            return
        }
        let token = try self.resolveBotToken()
        let auth = try await self.authTest(token: token)
        guard let userID = auth.userID?.channelTrimmedNonEmpty else {
            throw OpenClawCoreError.unavailable("Slack auth.test did not return a user ID")
        }
        self.botUserID = userID
        self.botID = auth.botID
        self.lastSeenTimestamp = nil
        self.hasInitializedCursor = false
        switch self.effectiveMode {
        case .poll:
            let channelID = try self.resolveDefaultChannelID()
            self.started = true
            self.ingestTask = Task { [weak self] in
                await self?.pollLoop(channelID: channelID, token: token)
            }
        case .socket:
            guard let appToken = self.config.appToken?.channelTrimmedNonEmpty else {
                throw OpenClawCoreError.invalidConfiguration("Slack Socket Mode requires appToken")
            }
            // Validate the app token synchronously so bad credentials fail start().
            let url = try await self.openSocketURL(appToken: appToken)
            self.started = true
            self.ingestTask = Task { [weak self] in
                await self?.socketLoop(appToken: appToken, firstURL: url)
            }
        case .http:
            guard self.config.signingSecret?.channelTrimmedNonEmpty != nil else {
                throw OpenClawCoreError.invalidConfiguration("Slack HTTP mode requires signingSecret")
            }
            self.started = true
        case .relay:
            let request = try Self.relayRequest(config: self.config.relay ?? SlackRelayConfig())
            self.started = true
            self.ingestTask = Task { [weak self] in
                await self?.relayLoop(request: request)
            }
        }
        self.health = ChannelTransportHealth(state: .healthy)
    }

    /// Stops adapter lifecycle.
    public func stop() async {
        self.started = false
        self.ingestTask?.cancel()
        self.ingestTask = nil
        await self.socket?.close()
        self.socket = nil
        self.health = ChannelTransportHealth(state: .stopped)
    }

    /// Probes the bot token with `auth.test`.
    /// - Parameter timeoutMs: Probe timeout.
    /// - Returns: Probe result with the bot user.
    public func probe(timeoutMs: Int) async -> ChannelProbeResult {
        if case .unconfigured(let reason) = self.configurationStatus {
            return ChannelProbeResult(ok: false, detail: reason)
        }
        return await ChannelAsync.probe(timeoutMs: timeoutMs) { [self] in
            let token = try await self.resolveBotToken()
            let auth = try await self.authTest(token: token)
            return [auth.user, auth.team].compactMap(\.self).joined(separator: " @ ").channelTrimmedNonEmpty ?? auth.userID
        }
    }

    // MARK: Outbound

    /// Sends outbound message through `chat.postMessage`.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        _ = try await self.sendReturningReceipt(message)
    }

    /// Sends outbound text (chunked at 8,000 characters) and returns the `ts` receipt.
    /// - Parameter message: Outbound payload.
    /// - Returns: Receipt with one part per chunk.
    public func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Slack adapter is not started")
        }
        let token = try self.resolveBotToken()
        let channel = try self.resolveTargetChannel(fromPeerID: message.peerID)
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Slack outbound text is required")
        }
        let threadTS = self.threadTS(for: message, channel: channel)
        var parts: [ChannelSendReceipt.Part] = []
        for (index, chunk) in ChannelTextChunker.chunk(text, limit: Self.textChunkLimit).enumerated() {
            var payload: [String: Any] = ["channel": channel, "text": chunk, "unfurl_links": self.config.unfurlLinks]
            if let unfurlMedia = self.config.unfurlMedia {
                payload["unfurl_media"] = unfurlMedia
            }
            if let threadTS {
                payload["thread_ts"] = threadTS
            }
            if let identity = self.relayIdentity {
                if let username = identity.username { payload["username"] = username }
                if let iconURL = identity.iconURL { payload["icon_url"] = iconURL }
                if let iconEmoji = identity.iconEmoji { payload["icon_emoji"] = iconEmoji }
            }
            let response = try await self.call("chat.postMessage", token: token, payload: payload)
            parts.append(ChannelSendReceipt.Part(platformMessageID: response.ts ?? "", kind: .text, index: index, threadID: threadTS))
        }
        if let threadTS {
            self.botThreads.insert("\(channel):\(threadTS)")
        }
        return ChannelSendReceipt(parts: parts, threadID: threadTS, replyToID: message.replyToID)
    }

    /// Resolves `thread_ts`: stay in the inbound thread, otherwise thread under `replyToID` when
    /// the effective reply mode (`channels.<id>.replyToMode` → `replyToModeByChatType` →
    /// `replyToMode`, default `off`) is not `off`.
    private func threadTS(for message: OutboundMessage, channel: String) -> String? {
        if let thread = message.threadID?.channelTrimmedNonEmpty {
            return thread
        }
        guard let replyTo = message.replyToID?.channelTrimmedNonEmpty else { return nil }
        let chatType = message.chatType ?? self.lastInbound[message.peerID]?.chatType ?? Self.chatType(forChannelID: channel, channelType: nil)
        let byType = self.config.replyToModeByChatType
        let typed: ChannelReplyToMode? = switch chatType {
        case .direct: byType.direct
        case .group: byType.group
        case .channel, .thread: byType.channel
        }
        let mode = self.config.channels[channel]?.replyToMode ?? typed ?? self.config.policy.replyToMode ?? .off
        return mode == .off ? nil : replyTo
    }

    /// Slack typing uses the assistant status API and the optional typing reaction.
    nonisolated public var supportsTypingIndicator: Bool {
        true
    }

    /// Marks the conversation as processing (`agents.sessions.setStatus`) and adds `typingReaction`.
    ///
    /// Uses the last inbound message of the peer for the thread and reaction target. Failures
    /// are ignored (the status API requires the assistant scope); keepalive ticks do not repeat
    /// calls that already succeeded.
    /// - Parameters:
    ///   - accountID: Channel account key (unused).
    ///   - peerID: Channel id.
    public func sendTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Slack adapter is not started")
        }
        let token = try self.resolveBotToken()
        guard let context = self.lastInbound[peerID] else { return }
        let channel = try self.resolveTargetChannel(fromPeerID: peerID)
        if self.activeStatus[peerID] == nil, let threadTS = context.threadTS ?? (context.chatType == .direct ? nil : context.ts) {
            if await self.setStatus(token: token, channel: channel, threadTS: threadTS, status: "processing") {
                self.activeStatus[peerID] = (channel, threadTS)
            }
        }
        if self.activeReaction[peerID] == nil, let name = self.config.typingReaction.map(Self.reactionName), !name.isEmpty {
            if (try? await self.call("reactions.add", token: token, payload: ["channel": channel, "timestamp": context.ts, "name": name])) != nil {
                self.activeReaction[peerID] = (channel, context.ts, name)
            }
        }
    }

    /// Resets the status to `active` and removes the typing reaction.
    /// - Parameters:
    ///   - accountID: Channel account key (unused).
    ///   - peerID: Channel id.
    public func stopTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard let token = try? self.resolveBotToken() else { return }
        if let status = self.activeStatus.removeValue(forKey: peerID) {
            _ = await self.setStatus(token: token, channel: status.channel, threadTS: status.threadTS, status: "active")
        }
        if let reaction = self.activeReaction.removeValue(forKey: peerID) {
            _ = try? await self.call(
                "reactions.remove",
                token: token,
                payload: ["channel": reaction.channel, "timestamp": reaction.ts, "name": reaction.name]
            )
        }
    }

    private func setStatus(token: String, channel: String, threadTS: String, status: String) async -> Bool {
        let payload: [String: Any] = ["channel_id": channel, "thread_ts": threadTS, "status": status]
        guard let request = try? self.jsonRequest("agents.sessions.setStatus", token: token, payload: payload),
              let response = try? await self.transport.data(for: request),
              let parsed = try? JSONDecoder().decode(SlackGenericResponse.self, from: response.body)
        else {
            return false
        }
        if parsed.warning == "missing_agent_session_stopped_event_subscription", !self.warnedMissingStopSubscription {
            self.warnedMissingStopSubscription = true
            self.health.lastError =
                "Slack's Stop button is unavailable until the app subscribes to agent_session_stopped."
        }
        return parsed.ok
    }

    // MARK: Reactions and message actions

    /// Actions implemented natively (`reactions.add/remove`, `chat.update`, `chat.delete`).
    nonisolated public var supportedMessageActions: Set<ChannelMessageActionName> {
        [.react, .edit, .unsend, .delete]
    }

    /// Adds a reaction (`reactions.add`; Unicode emoji are mapped to Slack names).
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message `ts`.
    ///   - emoji: Emoji or `:name:`.
    public func addReaction(peerID: String, messageID: String, emoji: String) async throws {
        try await self.react(peerID: peerID, messageID: messageID, emoji: emoji, remove: false)
    }

    /// Removes a reaction (`reactions.remove`).
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message `ts`.
    ///   - emoji: Emoji or `:name:`.
    public func removeReaction(peerID: String, messageID: String, emoji: String) async throws {
        try await self.react(peerID: peerID, messageID: messageID, emoji: emoji, remove: true)
    }

    /// Adds or removes a reaction.
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message `ts`.
    ///   - emoji: Emoji or `:name:`.
    ///   - remove: Whether to remove.
    public func react(peerID: String, messageID: String, emoji: String, remove: Bool) async throws {
        let token = try self.resolveBotToken()
        _ = try await self.call(
            remove ? "reactions.remove" : "reactions.add",
            token: token,
            payload: ["channel": try self.resolveTargetChannel(fromPeerID: peerID), "timestamp": messageID, "name": Self.reactionName(emoji)]
        )
    }

    /// Edits a message (`chat.update`).
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message `ts`.
    ///   - text: Replacement text.
    public func edit(peerID: String, messageID: String, text: String) async throws {
        let token = try self.resolveBotToken()
        _ = try await self.call(
            "chat.update",
            token: token,
            payload: ["channel": try self.resolveTargetChannel(fromPeerID: peerID), "ts": messageID, "text": text]
        )
    }

    /// Deletes a message (`chat.delete`).
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message `ts`.
    public func unsend(peerID: String, messageID: String) async throws {
        let token = try self.resolveBotToken()
        _ = try await self.call("chat.delete", token: token, payload: ["channel": try self.resolveTargetChannel(fromPeerID: peerID), "ts": messageID])
    }

    /// Maps a Unicode emoji or `:name:` to a Slack reaction name.
    /// - Parameter emoji: Emoji input.
    /// - Returns: Slack emoji name.
    public static func reactionName(_ emoji: String) -> String {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(":"), trimmed.hasSuffix(":"), trimmed.count > 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        let table: [String: String] = [
            "👀": "eyes", "👍": "+1", "👎": "-1", "✅": "white_check_mark", "❤️": "heart", "🎉": "tada", "🙏": "pray",
            "😂": "joy", "🔥": "fire", "⏳": "hourglass_flowing_sand", "🤔": "thinking_face", "👋": "wave", "❌": "x",
            "⚠️": "warning", "🚀": "rocket", "💯": "100",
        ]
        return table[trimmed] ?? trimmed
    }

    // MARK: HTTP Events API

    /// Handles one Slack Events API request (``SlackConnectionMode/http``).
    ///
    /// Verifies `X-Slack-Signature` against the signing secret with a 300 s timestamp window,
    /// answers `url_verification`, and dispatches `event_callback` events asynchronously.
    /// - Parameters:
    ///   - headers: Request headers.
    ///   - body: Raw request body (signature input; do not re-serialize).
    /// - Returns: HTTP status and body to return to Slack.
    public func handleEventsWebhook(headers: [String: String], body: Data) async -> (status: Int, body: String) {
        guard let secret = self.config.signingSecret?.channelTrimmedNonEmpty else {
            return (500, "signing secret not configured")
        }
        guard let timestamp = ChannelHTTP.header("X-Slack-Request-Timestamp", in: headers),
              let signature = ChannelHTTP.header("X-Slack-Signature", in: headers),
              let seconds = TimeInterval(timestamp.trimmingCharacters(in: .whitespaces))
        else {
            return (401, "missing signature")
        }
        guard abs(self.now().timeIntervalSince1970 - seconds) <= Self.signatureSkewSeconds else {
            return (401, "stale request")
        }
        let expected = ChannelWebhookSignature.slackSignature(signingSecret: secret, timestamp: timestamp, body: body)
        guard ChannelWebhookSignature.constantTimeEquals(expected, signature) else {
            return (401, "invalid signature")
        }
        guard let callback = try? JSONDecoder().decode(SlackEventCallback.self, from: body) else {
            return (400, "invalid payload")
        }
        if callback.type == "url_verification" {
            return (200, callback.challenge ?? "")
        }
        guard self.started, callback.type == "event_callback", let event = callback.event else {
            return (200, "")
        }
        if let eventID = callback.eventID, !self.recentEvents.insert("event:\(eventID)") {
            return (200, "")
        }
        Task { [weak self] in
            await self?.handleEvent(event)
        }
        return (200, "")
    }

    // MARK: Socket Mode

    private func openSocketURL(appToken: String) async throws -> URL {
        let request = try self.jsonRequest("apps.connections.open", token: appToken, payload: [:])
        let response = try await self.transport.data(for: request)
        try ChannelHTTP.check(response)
        let parsed = try JSONDecoder().decode(SlackGenericResponse.self, from: response.body)
        guard parsed.ok, let raw = parsed.url, let url = URL(string: raw) else {
            let error = parsed.error ?? "missing url"
            if Self.terminalAuthErrors.contains(error) {
                throw OpenClawCoreError.invalidConfiguration("Slack Socket Mode auth failed: \(error)")
            }
            throw OpenClawCoreError.unavailable("Slack apps.connections.open failed: \(error)")
        }
        return url
    }

    private func socketLoop(appToken: String, firstURL: URL) async {
        var attempt = 0
        var nextURL: URL? = firstURL
        while self.started, !Task.isCancelled {
            do {
                let url: URL
                if let nextURL {
                    url = nextURL
                } else {
                    url = try await self.openSocketURL(appToken: appToken)
                }
                nextURL = nil
                let socket = try await self.webSocketConnector.connect(URLRequest(url: url), maximumMessageSize: nil)
                self.socket = socket
                attempt = 0
                self.health = ChannelTransportHealth(state: .healthy)
                try await self.consumeSocket(socket)
            } catch let error as OpenClawCoreError {
                if case .invalidConfiguration(let detail) = error {
                    self.health = ChannelTransportHealth(state: .blocked, lastError: detail)
                    self.started = false
                    return
                }
                self.health = ChannelTransportHealth(state: .degraded, lastError: error.localizedDescription)
            } catch {
                self.health = ChannelTransportHealth(state: .degraded, lastError: "Slack Socket Mode disconnected: \(error.localizedDescription)")
            }
            await self.socket?.close()
            self.socket = nil
            guard self.started, !Task.isCancelled else { return }
            await ChannelAsync.sleep(milliseconds: ChannelAsync.backoffMs(attempt: attempt))
            attempt += 1
        }
    }

    private func consumeSocket(_ socket: any ChannelWebSocketConnection) async throws {
        while self.started, !Task.isCancelled {
            let raw = try await socket.receive()
            guard let envelope = try? JSONDecoder().decode(SlackSocketEnvelope.self, from: Data(raw.utf8)) else { continue }
            if envelope.type == "disconnect" {
                return
            }
            if let envelopeID = envelope.envelopeID {
                // Ack before processing: Slack retries unacknowledged envelopes after 3 s.
                let ack = String(decoding: try JSONSerialization.data(withJSONObject: ["envelope_id": envelopeID]), as: UTF8.self)
                try await socket.send(text: ack)
            }
            guard envelope.type == "events_api", let event = envelope.payload?.event else { continue }
            if let eventID = envelope.payload?.eventID, !self.recentEvents.insert("event:\(eventID)") {
                continue
            }
            await self.handleEvent(event)
        }
    }

    // MARK: Relay

    /// Builds the relay WebSocket request (upstream `buildRelayWebSocketUrl`).
    /// - Parameter config: Relay settings.
    /// - Returns: Upgrade request with the bearer header and `gateway_id` query.
    /// - Throws: `OpenClawCoreError.invalidConfiguration` for invalid relay URLs.
    public static func relayRequest(config: SlackRelayConfig) throws -> URLRequest {
        guard let raw = config.url?.channelTrimmedNonEmpty, var components = URLComponents(string: raw) else {
            throw OpenClawCoreError.invalidConfiguration("Slack relay mode requires relay.url")
        }
        guard let token = config.authToken?.channelTrimmedNonEmpty, let gatewayID = config.gatewayID?.channelTrimmedNonEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Slack relay mode requires relay.authToken and relay.gatewayId")
        }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default:
            throw OpenClawCoreError.invalidConfiguration("Slack relay URL must use http(s) or ws(s): \(raw)")
        }
        let host = (components.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let isLocal = host == "localhost" || host == "::1" || (host.hasPrefix("127.") && host.split(separator: ".").count == 4)
        if components.scheme == "ws", !isLocal {
            throw OpenClawCoreError.invalidConfiguration(
                "Slack relay URL uses plaintext ws:// for non-local host \"\(components.host ?? "")\". Use wss:// for remote relay URLs."
            )
        }
        if components.path.isEmpty || components.path == "/" {
            throw OpenClawCoreError.invalidConfiguration("Slack relay URL must include its websocket path: \(raw)")
        }
        var items = (components.queryItems ?? []).filter { $0.name != "gateway_id" }
        items.append(URLQueryItem(name: "gateway_id", value: gatewayID))
        components.queryItems = items
        guard let url = components.url else {
            throw OpenClawCoreError.invalidConfiguration("Slack relay URL is invalid: \(raw)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    private func relayLoop(request: URLRequest) async {
        var attempt = 0
        while self.started, !Task.isCancelled {
            do {
                let socket = try await self.webSocketConnector.connect(request, maximumMessageSize: Self.relayMaxFrameBytes)
                self.socket = socket
                attempt = 0
                self.health = ChannelTransportHealth(state: .healthy)
                while self.started, !Task.isCancelled {
                    let raw = try await socket.receive()
                    guard raw.utf8.count <= Self.relayMaxFrameBytes,
                          let frame = try? JSONDecoder().decode(SlackRelayFrame.self, from: Data(raw.utf8))
                    else { continue }
                    await self.handleRelayFrame(frame, socket: socket)
                }
            } catch {
                self.health = ChannelTransportHealth(state: .degraded, lastError: "Slack relay disconnected: \(error.localizedDescription)")
            }
            await self.socket?.close()
            self.socket = nil
            guard self.started, !Task.isCancelled else { return }
            await ChannelAsync.sleep(milliseconds: ChannelAsync.backoffMs(attempt: attempt))
            attempt += 1
        }
    }

    private func handleRelayFrame(_ frame: SlackRelayFrame, socket: any ChannelWebSocketConnection) async {
        switch frame.type {
        case "hello":
            if let identity = frame.slackIdentity {
                let post = SlackPostIdentity(username: identity.username, iconURL: identity.iconURL, iconEmoji: identity.iconEmoji)
                self.relayIdentity = (post.username ?? post.iconURL ?? post.iconEmoji) == nil ? nil : post
            }
        case "slack_event":
            let kinds: Set<String> = ["user_group", "thread_affinity", "channel_default"]
            guard let deliveryID = frame.deliveryID?.channelTrimmedNonEmpty,
                  let kind = frame.route?.kind, kinds.contains(kind), frame.route?.key?.channelTrimmedNonEmpty != nil,
                  let event = frame.payload?.event
            else { return }
            if self.recentEvents.insert("delivery:\(deliveryID)") {
                await self.handleEvent(event)
            }
            // Ack after the inbound handler accepted the event; redeliveries are deduped above.
            if let ack = try? JSONSerialization.data(withJSONObject: ["type": "ack", "delivery_id": deliveryID]) {
                try? await socket.send(text: String(decoding: ack, as: UTF8.self))
            }
        default:
            break
        }
    }

    /// Post identity announced by the relay `hello` frame.
    /// - Returns: Identity, when announced.
    public func postIdentity() -> SlackPostIdentity? {
        self.relayIdentity
    }

    // MARK: Event handling

    func handleEvent(_ event: SlackEvent) async {
        switch event.type {
        case "member_joined_channel":
            guard let user = event.user, user == self.botUserID, let channel = event.channel else { return }
            let joined = ChannelJoinEvent(channel: .slack, peerID: channel, chatType: .channel)
            if let joinHandler {
                await joinHandler(joined)
            }
        case "message", "app_mention":
            await self.handleMessageEvent(event)
        default:
            return
        }
    }

    private func handleMessageEvent(_ event: SlackEvent) async {
        let allowedSubtypes: Set<String> = ["thread_broadcast", "file_share"]
        if let subtype = event.subtype?.lowercased(), !allowedSubtypes.contains(subtype) {
            return
        }
        guard let channel = event.channel?.channelTrimmedNonEmpty, let ts = event.ts?.channelTrimmedNonEmpty else { return }
        // message and app_mention both fire for mentions in channels.
        guard self.recentEvents.insert("msg:\(channel):\(ts)") else { return }
        await self.deliver(event, channel: channel, ts: ts)
    }

    private func deliver(_ event: SlackEvent, channel: String, ts: String) async {
        if let botUserID, event.user == botUserID {
            return
        }
        if let botID, event.botID == botID {
            return
        }
        let rawText = event.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawText.isEmpty else { return }
        let chatType = Self.chatType(forChannelID: channel, channelType: event.channelType)
        let override = self.config.channels[channel]
        if override?.enabled == false {
            return
        }
        if chatType == .direct, self.config.dm.enabled == false {
            return
        }
        if chatType == .group, !(self.config.dm.groupEnabled ?? false), event.channelType == "mpim" {
            return
        }
        let mentioned = self.isMentioningBot(text: rawText)
        let threadTS = event.threadTS?.channelTrimmedNonEmpty
        let threadParticipant = threadTS.map { self.botThreads.contains("\(channel):\($0)") } ?? false
        if chatType != .direct {
            let requireMention = override?.requireMention ?? self.config.mentionOnly
            if requireMention, !mentioned, !threadParticipant {
                return
            }
            let ignoreOthers = override?.ignoreOtherMentions ?? self.config.ignoreOtherMentions
            if ignoreOthers, !mentioned, Self.mentionsSomeoneElse(rawText, botUserID: self.botUserID) {
                return
            }
            if let users = override?.users, !users.isEmpty, !users.contains(event.user ?? "") {
                return
            }
        }
        let envelopeType: ChannelChatType = (chatType != .direct && threadTS != nil && threadTS != ts) ? .thread : chatType
        self.lastInbound[channel] = SlackInboundContext(ts: ts, threadTS: threadTS, chatType: chatType)
        let inbound = InboundMessage(
            channel: .slack,
            peerID: channel,
            text: self.normalizedInboundText(rawText),
            senderID: event.user,
            chatType: envelopeType,
            messageID: ts,
            threadID: threadTS,
            wasMentioned: chatType == .direct ? nil : mentioned,
            implicitMentionKinds: threadParticipant ? [.botThreadParticipant] : [],
            isFromBot: event.botID != nil,
            recipientID: self.botUserID,
            metadata: event.channelType.map { ["channelType": $0] } ?? [:],
            legacyRoutingAccountID: event.user
        )
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    /// Maps Slack `channel_type` (or the id prefix when absent) to the envelope chat type:
    /// `im` → direct, `mpim` → group, `channel`/`group` → channel.
    static func chatType(forChannelID channelID: String, channelType: String?) -> ChannelChatType {
        switch channelType?.lowercased() {
        case "im": return .direct
        case "mpim": return .group
        case "channel", "group": return .channel
        default:
            return channelID.hasPrefix("D") ? .direct : .channel
        }
    }

    static func mentionsSomeoneElse(_ text: String, botUserID: String?) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "<(@[UW][A-Z0-9]+|!subteam\\^[A-Z0-9]+)[^>]*>") else { return false }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let tokenRange = Range(match.range(at: 1), in: text) else { continue }
            let token = String(text[tokenRange])
            if let botUserID, token == "@\(botUserID)" { continue }
            return true
        }
        return false
    }

    private func isMentioningBot(text: String) -> Bool {
        guard let botUserID = self.botUserID?.channelTrimmedNonEmpty else {
            return false
        }
        return text.contains("<@\(botUserID)>") || text.contains("<@\(botUserID)|")
    }

    private func normalizedInboundText(_ text: String) -> String {
        var value = text
        if let botUserID = self.botUserID?.channelTrimmedNonEmpty {
            value = value.replacingOccurrences(of: "<@\(botUserID)>", with: " ")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Legacy polling

    private func pollLoop(channelID: String, token: String) async {
        while !Task.isCancelled && self.started {
            do {
                try await self.pollOnce(channelID: channelID, token: token)
            } catch {
                self.health = ChannelTransportHealth(state: .degraded, lastError: "Slack poll failed: \(error.localizedDescription)")
            }
            await ChannelAsync.sleep(milliseconds: self.pollIntervalMs)
        }
    }

    private func pollOnce(channelID: String, token: String) async throws {
        var components = URLComponents(url: try self.resolveEndpoint(path: "conversations.history"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "channel", value: channelID), URLQueryItem(name: "limit", value: "50")]
        guard let url = components?.url else {
            throw OpenClawCoreError.invalidConfiguration("Invalid Slack conversations.history URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        try ChannelHTTP.check(response)
        let parsed = try JSONDecoder().decode(SlackConversationsHistoryResponse.self, from: response.body)
        guard parsed.ok else {
            throw OpenClawCoreError.unavailable("Slack poll failed: \(parsed.error ?? "unknown")")
        }
        let sorted = (parsed.messages ?? []).sorted { Self.parseTimestamp($0.ts) < Self.parseTimestamp($1.ts) }
        if !self.hasInitializedCursor {
            self.hasInitializedCursor = true
            if let latest = sorted.last?.ts {
                self.lastSeenTimestamp = Self.parseTimestamp(latest)
            }
            return
        }
        for message in sorted {
            let timestamp = Self.parseTimestamp(message.ts)
            if let lastSeenTimestamp, timestamp <= lastSeenTimestamp {
                continue
            }
            self.lastSeenTimestamp = max(self.lastSeenTimestamp ?? 0, timestamp)
            guard message.type?.lowercased() == "message", message.subtype?.lowercased() != "bot_message", message.botID == nil,
                  let ts = message.ts
            else { continue }
            guard self.recentEvents.insert("msg:\(channelID):\(ts)") else { continue }
            await self.deliver(message, channel: channelID, ts: ts)
        }
    }

    private static func parseTimestamp(_ raw: String?) -> Double {
        Double(raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    // MARK: Web API helpers

    private func jsonRequest(_ method: String, token: String, payload: [String: Any]) throws -> URLRequest {
        var request = ChannelHTTP.jsonRequest(
            url: try self.resolveEndpoint(path: method),
            body: try ChannelHTTP.jsonBody(payload),
            headers: ["Authorization": "Bearer \(token)"]
        )
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func call(_ method: String, token: String, payload: [String: Any]) async throws -> SlackGenericResponse {
        let response = try await self.transport.data(for: try self.jsonRequest(method, token: token, payload: payload))
        try ChannelHTTP.check(response)
        let parsed = try JSONDecoder().decode(SlackGenericResponse.self, from: response.body)
        guard parsed.ok else {
            let error = parsed.error ?? "unknown"
            if error == "ratelimited" {
                throw ChannelSendError.rateLimited(
                    retryAfterMs: ChannelHTTP.header("Retry-After", in: response.headers).flatMap { ChannelSendError.parseRetryAfterHeader($0) }
                )
            }
            throw ChannelSendError.rejected(status: response.statusCode, detail: "Slack \(method) failed: \(error)")
        }
        return parsed
    }

    private func authTest(token: String) async throws -> SlackAuthTestResponse {
        var request = URLRequest(url: try self.resolveEndpoint(path: "auth.test"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Slack auth.test failed with status \(response.statusCode)")
        }
        let parsed = try JSONDecoder().decode(SlackAuthTestResponse.self, from: response.body)
        guard parsed.ok else {
            throw OpenClawCoreError.unavailable("Slack auth.test failed: \(parsed.error ?? "unknown")")
        }
        return parsed
    }

    private func resolveBotToken() throws -> String {
        guard let token = self.config.botToken?.channelTrimmedNonEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Slack bot token is required")
        }
        return token
    }

    private func resolveDefaultChannelID() throws -> String {
        guard let channelID = self.config.defaultChannelID?.channelTrimmedNonEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Slack default channel ID is required")
        }
        return channelID
    }

    private func resolveTargetChannel(fromPeerID peerID: String) throws -> String {
        try peerID.channelTrimmedNonEmpty ?? self.resolveDefaultChannelID()
    }

    private func resolveEndpoint(path: String) throws -> URL {
        let baseRaw = self.explicitBaseURL?.absoluteString ?? self.config.baseURL
        guard let trimmedBase = baseRaw.channelTrimmedNonEmpty, let baseURL = URL(string: trimmedBase) else {
            throw OpenClawCoreError.invalidConfiguration("Slack base URL is invalid")
        }
        return baseURL.appendingPathComponent(path)
    }
}
