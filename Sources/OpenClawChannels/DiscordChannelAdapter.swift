import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Minimal HTTP transport contract used by the Discord adapter.
public protocol DiscordHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Normalized response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: DiscordHTTPTransport {}

private struct DiscordCurrentUser: Decodable {
    let id: String
    let username: String?
}

private struct DiscordAuthor: Decodable {
    let id: String
    let bot: Bool?
    let username: String?
    let globalName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case bot
        case username
        case globalName = "global_name"
    }
}

private struct DiscordMember: Decodable {
    let nick: String?
}

private struct DiscordMessageReference: Decodable {
    let messageID: String?

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }
}

private struct DiscordReferencedMessage: Decodable {
    let id: String?
    let author: DiscordAuthor?
}

private struct DiscordMessage: Decodable {
    let id: String
    let content: String
    let author: DiscordAuthor
    let mentions: [DiscordAuthor]?
    let mentionRoles: [String]?
    let channelID: String?
    let guildID: String?
    let member: DiscordMember?
    let messageReference: DiscordMessageReference?
    let referencedMessage: DiscordReferencedMessage?

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case author
        case mentions
        case mentionRoles = "mention_roles"
        case channelID = "channel_id"
        case guildID = "guild_id"
        case member
        case messageReference = "message_reference"
        case referencedMessage = "referenced_message"
    }
}

private struct DiscordChannelStub: Decodable {
    let id: String
    let type: Int?
    let parentID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case parentID = "parent_id"
    }
}

private struct DiscordGuildCreate: Decodable {
    let id: String
    let name: String?
    let joinedAt: String?
    let systemChannelID: String?
    let channels: [DiscordChannelStub]?
    let threads: [DiscordChannelStub]?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case joinedAt = "joined_at"
        case systemChannelID = "system_channel_id"
        case channels
        case threads
    }
}

private struct DiscordDispatch<Payload: Decodable>: Decodable {
    let d: Payload
}

private struct DiscordCreatedMessage: Decodable {
    let id: String
}

/// Live Discord channel adapter (upstream 2026.9.6 semantics).
///
/// - Inbound (default ``DiscordTransportMode/gateway``): gateway `MESSAGE_CREATE` ingestion with
///   upstream intents (Message Content unless `intents.messageContent == false`; Presences and
///   Members only when enabled). DMs (no `guild_id`) are ``ChannelChatType/direct``, thread
///   channels (types 10/11/12) are ``ChannelChatType/thread``, guild channels are
///   ``ChannelChatType/channel``. `dm.enabled`, `guilds.<id>.requireMention`,
///   `guilds.<id>.channels.<id>.{enabled, requireMention, users}` and `ignoreOtherMentions` are
///   applied. `GUILD_CREATE` for a guild joined within five minutes emits a ``ChannelJoinEvent``.
/// - ``DiscordTransportMode/restPolling`` keeps the pre-2026.3.0 REST polling of `defaultChannelID`.
/// - Outbound: chunks at 2,000 characters and `maxLinesPerMessage` (17) lines, sets
///   `flags: 4` (SUPPRESS_EMBEDS) unless `suppressEmbeds` is `false`, replies with
///   `message_reference` on the first chunk and rewrites `@handle` via `mentionAliases`.
///   Returns message-id receipts; 429 responses carry `retry_after`.
public actor DiscordChannelAdapter: InboundChannelAdapter, ReceiptingChannelAdapter, ReactingChannelAdapter, ChannelMessageActions,
    ChannelConfigurationReporting, ChannelTransportHealthReporting, JoinEventChannelAdapter
{
    /// Presence client factory used by the legacy REST polling transport.
    public typealias PresenceFactory = @Sendable (_ token: String) -> any DiscordPresenceClient

    /// Adapter channel identifier.
    public let id: ChannelID = .discord

    /// Discord message content limit.
    public static let textChunkLimit = 2_000
    /// Thread channel types (announcement thread, public thread, private thread).
    public static let threadChannelTypes: Set<Int> = [10, 11, 12]
    /// Group DM channel type.
    public static let groupDMChannelType = 3

    private let config: DiscordChannelConfig
    private let transport: any DiscordHTTPTransport
    private let baseURL: URL
    private let presenceFactory: PresenceFactory?
    private let gatewayConnector: any ChannelWebSocketConnecting
    private let gatewayURL: URL

    private var started = false
    private var pollTask: Task<Void, Never>?
    private var botUserID: String?
    private var lastSeenMessageID: UInt64?
    private var hasInitializedCursor = false
    private var presenceClient: (any DiscordPresenceClient)?
    private var gateway: DiscordGatewayClient?
    private var inboundHandler: InboundMessageHandler?
    private var joinHandler: ChannelJoinEventHandler?
    private var channelTypes: [String: Int] = [:]
    private var channelGuilds: [String: String] = [:]
    private var recentMessageIDs = ChannelRecentIDs(capacity: 512)
    private var health = ChannelTransportHealth()
    /// Last queued inbound delivery per channel (per-conversation sequencing, upstream
    /// `extensions/discord/src/monitor/listeners.ts`).
    private var inboundTails: [String: (id: Int, task: Task<Void, Never>)] = [:]
    private var nextInboundID = 0

    /// Creates a Discord channel adapter.
    /// - Parameters:
    ///   - config: Discord channel configuration (resolve SecretRefs first).
    ///   - transport: HTTP transport implementation.
    ///   - baseURL: Discord API base URL.
    ///   - presenceFactory: Presence client factory for the REST polling transport.
    ///   - gatewayConnector: WebSocket connector for the gateway transport.
    ///   - gatewayURL: Gateway URL.
    public init(
        config: DiscordChannelConfig,
        transport: any DiscordHTTPTransport = HTTPClient(),
        baseURL: URL = URL(string: "https://discord.com/api/v10")!,
        presenceFactory: PresenceFactory? = { token in
            DiscordGatewayPresenceClient(token: token)
        },
        gatewayConnector: any ChannelWebSocketConnecting = URLSessionChannelWebSocketConnector(),
        gatewayURL: URL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!
    ) {
        self.config = config
        self.transport = transport
        self.baseURL = baseURL
        self.presenceFactory = presenceFactory
        self.gatewayConnector = gatewayConnector
        self.gatewayURL = gatewayURL
    }

    /// Sets an inbound handler invoked for accepted user messages.
    /// - Parameter handler: Optional async inbound handler closure.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Registers a handler for bot-joined-guild events.
    /// - Parameter handler: Optional join handler.
    public func setJoinEventHandler(_ handler: ChannelJoinEventHandler?) async {
        self.joinHandler = handler
    }

    /// Whether a bot token is configured (`token` or `botToken`).
    nonisolated public var configurationStatus: ChannelConfigurationStatus {
        self.config.botToken?.channelTrimmedNonEmpty == nil
            ? .unconfigured(reason: "Discord requires a bot token (channels.discord.token).")
            : .configured
    }

    /// Current inbound transport health.
    public func transportHealth() async -> ChannelTransportHealth {
        if let gateway, let error = await gateway.lastError() {
            return ChannelTransportHealth(state: .degraded, lastError: error)
        }
        return self.health
    }

    /// Starts the adapter: verifies the token (`GET /users/@me`), then connects the gateway or
    /// starts legacy REST polling.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("Discord channel is disabled")
        }
        if self.started {
            return
        }
        self.lastSeenMessageID = nil
        self.hasInitializedCursor = false
        let token = try self.resolveToken()
        self.botUserID = try await self.fetchCurrentUser(token: token).id
        switch self.config.transport {
        case .restPolling:
            let channelID = try self.resolveDefaultChannelID()
            if self.config.presenceEnabled, let presenceFactory = self.presenceFactory {
                let presence = presenceFactory(token)
                try await presence.start()
                self.presenceClient = presence
            }
            self.started = true
            self.pollTask = Task { [weak self] in
                await self?.pollLoop(channelID: channelID, token: token)
            }
        case .gateway:
            let gateway = DiscordGatewayClient(
                token: token,
                intents: DiscordGatewayIntent.resolve(self.config.intents),
                presence: self.config.presenceEnabled ? DiscordPresence.from(self.config) : DiscordPresence(status: .invisible),
                gatewayURL: self.gatewayURL,
                connector: self.gatewayConnector
            )
            self.gateway = gateway
            self.started = true
            do {
                try await gateway.start { [weak self] event, frame in
                    await self?.handleGatewayDispatch(event: event, frame: frame)
                }
            } catch {
                self.started = false
                self.gateway = nil
                throw error
            }
        }
        self.health = ChannelTransportHealth(state: .healthy)
    }

    /// Stops the adapter (gateway, polling and presence) and drops queued inbound deliveries.
    public func stop() async {
        self.started = false
        self.pollTask?.cancel()
        self.pollTask = nil
        for tail in self.inboundTails.values {
            tail.task.cancel()
        }
        self.inboundTails.removeAll()
        if let presenceClient = self.presenceClient {
            await presenceClient.stop()
        }
        self.presenceClient = nil
        if let gateway {
            await gateway.stop()
        }
        self.gateway = nil
        self.health = ChannelTransportHealth(state: .stopped)
    }

    /// Probes the token with `GET /users/@me`.
    /// - Parameter timeoutMs: Probe timeout.
    /// - Returns: Probe result with the bot username.
    public func probe(timeoutMs: Int) async -> ChannelProbeResult {
        if case .unconfigured(let reason) = self.configurationStatus {
            return ChannelProbeResult(ok: false, detail: reason)
        }
        return await ChannelAsync.probe(timeoutMs: timeoutMs) { [self] in
            let token = try await self.resolveToken()
            let me = try await self.fetchCurrentUser(token: token)
            return me.username.map { "@\($0)" } ?? "bot \(me.id)"
        }
    }

    // MARK: Outbound

    /// Sends an outbound message to a Discord channel.
    /// - Parameter message: Outbound message payload.
    public func send(_ message: OutboundMessage) async throws {
        _ = try await self.sendReturningReceipt(message)
    }

    /// Sends an outbound message and returns the Discord message-id receipt.
    ///
    /// A failure after the first chunk was delivered throws
    /// ``ChannelSendError/partiallyDelivered(receipt:failure:)`` (rate limits are retried per chunk).
    /// - Parameter message: Outbound payload.
    /// - Returns: Receipt with one part per chunk.
    public func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Discord adapter is not started")
        }
        let token = try self.resolveToken()
        let channelID = try message.peerID.channelTrimmedNonEmpty ?? self.resolveDefaultChannelID()
        let text = Self.applyMentionAliases(message.text, aliases: self.config.mentionAliases)
        let chunks = ChannelTextChunker.chunk(text, limit: Self.textChunkLimit, maxLines: self.config.maxLinesPerMessage)
        guard !chunks.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Discord outbound text is required")
        }
        let delivery = ChannelMultipartDelivery(threadID: message.threadID, replyToID: message.replyToID)
        let parts = try await delivery.run(count: chunks.count) { index in
            var payload: [String: Any] = ["content": chunks[index]]
            if self.config.suppressEmbeds {
                payload["flags"] = 4
            }
            if index == 0, let replyTo = message.replyToID?.channelTrimmedNonEmpty {
                payload["message_reference"] = ["message_id": replyTo, "fail_if_not_exists": false]
            }
            let created: DiscordCreatedMessage = try await self.request(
                "POST",
                path: "channels/\(channelID)/messages",
                token: token,
                payload: payload
            )
            return [
                ChannelSendReceipt.Part(
                    platformMessageID: created.id,
                    kind: .text,
                    index: index,
                    threadID: message.threadID,
                    replyToID: index == 0 ? message.replyToID : nil
                ),
            ]
        }
        return ChannelSendReceipt(parts: parts, threadID: message.threadID, replyToID: message.replyToID)
    }

    /// Rewrites `@handle` to `<@id>` for configured aliases (case-insensitive, word-bounded).
    /// - Parameters:
    ///   - text: Outbound text.
    ///   - aliases: Handle (without `@`) → user id.
    /// - Returns: Rewritten text.
    public static func applyMentionAliases(_ text: String, aliases: [String: String]) -> String {
        guard !aliases.isEmpty else { return text }
        var result = text
        for (handle, userID) in aliases.sorted(by: { $0.key.count > $1.key.count }) {
            let cleaned = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
            guard !cleaned.isEmpty, !userID.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: cleaned)
            guard let regex = try? NSRegularExpression(pattern: "(?<![\\w<])@\(escaped)(?![\\w])", options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<@\(userID)>")
        }
        return result
    }

    /// Discord supports channel typing indicators.
    nonisolated public var supportsTypingIndicator: Bool {
        true
    }

    /// Triggers the typing indicator (`POST /channels/{id}/typing`).
    /// - Parameters:
    ///   - accountID: Channel account key (unused).
    ///   - peerID: Channel id.
    public func sendTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Discord adapter is not started")
        }
        let token = try self.resolveToken()
        let channelID = try peerID.channelTrimmedNonEmpty ?? self.resolveDefaultChannelID()
        try await self.requestNoContent("POST", path: "channels/\(channelID)/typing", token: token)
    }

    // MARK: Reactions and message actions

    /// Actions implemented natively.
    nonisolated public var supportedMessageActions: Set<ChannelMessageActionName> {
        [.react, .edit, .unsend, .delete, .poll]
    }

    /// Adds a reaction as the bot (`PUT /channels/{c}/messages/{m}/reactions/{emoji}/@me`).
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message id.
    ///   - emoji: Unicode emoji.
    public func addReaction(peerID: String, messageID: String, emoji: String) async throws {
        let token = try self.resolveToken()
        try await self.requestNoContent("PUT", path: Self.reactionPath(peerID, messageID, emoji), token: token)
    }

    /// Removes the bot's reaction (`DELETE .../reactions/{emoji}/@me`).
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message id.
    ///   - emoji: Unicode emoji.
    public func removeReaction(peerID: String, messageID: String, emoji: String) async throws {
        let token = try self.resolveToken()
        try await self.requestNoContent("DELETE", path: Self.reactionPath(peerID, messageID, emoji), token: token)
    }

    /// Adds or removes the bot's reaction.
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message id.
    ///   - emoji: Unicode emoji.
    ///   - remove: Whether to remove the reaction.
    public func react(peerID: String, messageID: String, emoji: String, remove: Bool) async throws {
        if remove {
            try await self.removeReaction(peerID: peerID, messageID: messageID, emoji: emoji)
        } else {
            try await self.addReaction(peerID: peerID, messageID: messageID, emoji: emoji)
        }
    }

    /// Edits a bot message (`PATCH /channels/{c}/messages/{m}`).
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message id.
    ///   - text: Replacement content.
    public func edit(peerID: String, messageID: String, text: String) async throws {
        let token = try self.resolveToken()
        let content = Self.applyMentionAliases(text, aliases: self.config.mentionAliases)
        let _: DiscordCreatedMessage = try await self.request(
            "PATCH",
            path: "channels/\(peerID)/messages/\(messageID)",
            token: token,
            payload: ["content": content]
        )
    }

    /// Deletes a message (`DELETE /channels/{c}/messages/{m}`).
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message id.
    public func unsend(peerID: String, messageID: String) async throws {
        let token = try self.resolveToken()
        try await self.requestNoContent("DELETE", path: "channels/\(peerID)/messages/\(messageID)", token: token)
    }

    /// Sends a native Discord poll (24 h duration).
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - question: Question.
    ///   - options: Answers.
    ///   - allowMultiple: Whether multiple answers are allowed.
    /// - Returns: Poll message receipt.
    public func sendPoll(peerID: String, question: String, options: [String], allowMultiple: Bool) async throws -> ChannelSendReceipt? {
        let token = try self.resolveToken()
        let payload: [String: Any] = [
            "poll": [
                "question": ["text": question],
                "answers": options.map { ["poll_media": ["text": $0]] },
                "allow_multiselect": allowMultiple,
                "duration": 24,
            ],
        ]
        let created: DiscordCreatedMessage = try await self.request("POST", path: "channels/\(peerID)/messages", token: token, payload: payload)
        return ChannelSendReceipt(platformMessageID: created.id, kind: .poll)
    }

    // MARK: Gateway ingestion

    private func handleGatewayDispatch(event: String, frame: Data) async {
        switch event {
        case "MESSAGE_CREATE":
            guard let dispatch = try? JSONDecoder().decode(DiscordDispatch<DiscordMessage>.self, from: frame) else { return }
            await self.handleMessage(dispatch.d, polledChannelID: nil)
        case "GUILD_CREATE":
            guard let dispatch = try? JSONDecoder().decode(DiscordDispatch<DiscordGuildCreate>.self, from: frame) else { return }
            await self.handleGuildCreate(dispatch.d)
        case "CHANNEL_CREATE", "CHANNEL_UPDATE", "THREAD_CREATE", "THREAD_UPDATE":
            guard let dispatch = try? JSONDecoder().decode(DiscordDispatch<DiscordChannelStub>.self, from: frame) else { return }
            if let type = dispatch.d.type {
                self.channelTypes[dispatch.d.id] = type
            }
        case "READY":
            if let gateway, let id = await gateway.botUserID() {
                self.botUserID = id
            }
        default:
            break
        }
    }

    private func handleGuildCreate(_ guild: DiscordGuildCreate) async {
        for channel in (guild.channels ?? []) + (guild.threads ?? []) {
            if let type = channel.type {
                self.channelTypes[channel.id] = type
            }
            self.channelGuilds[channel.id] = guild.id
        }
        guard let joinedAt = guild.joinedAt.flatMap(Self.parseDate),
              Date().timeIntervalSince(joinedAt) <= 300,
              let channelID = guild.systemChannelID,
              let joinHandler
        else {
            return
        }
        await joinHandler(
            ChannelJoinEvent(channel: .discord, peerID: channelID, roomName: guild.name, chatType: .channel, joinedAt: joinedAt)
        )
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// Applies DM/guild/channel gates and delivers one message.
    private func handleMessage(_ message: DiscordMessage, polledChannelID: String?) async {
        guard let channelID = message.channelID ?? polledChannelID else { return }
        guard self.recentMessageIDs.insert(message.id) else { return }
        if message.author.id == self.botUserID {
            return
        }
        let text = self.normalizedInboundText(from: message.content)
        guard !text.isEmpty else { return }
        let guildID = message.guildID ?? self.channelGuilds[channelID]
        let channelType = self.channelTypes[channelID]
        let chatType: ChannelChatType
        if polledChannelID != nil, guildID == nil {
            // Legacy REST polling reads guild channels.
            chatType = .channel
        } else if guildID == nil {
            guard self.config.dm.enabled ?? true else { return }
            if channelType == Self.groupDMChannelType, !(self.config.dm.groupEnabled ?? false) { return }
            chatType = .direct
        } else if let channelType, Self.threadChannelTypes.contains(channelType) {
            chatType = .thread
        } else {
            chatType = .channel
        }
        let mentioned = self.isMentioningBot(message)
        let repliesToBot = message.referencedMessage?.author?.id != nil && message.referencedMessage?.author?.id == self.botUserID
        if chatType != .direct {
            let guildOverride = guildID.flatMap { self.config.guilds[$0] }
            let channelOverride = guildOverride?.channels?[channelID]
            if channelOverride?.enabled == false {
                return
            }
            let requireMention = channelOverride?.requireMention ?? guildOverride?.requireMention ?? self.config.mentionOnly
            if requireMention, !mentioned, !repliesToBot {
                return
            }
            let ignoreOthers = channelOverride?.ignoreOtherMentions ?? guildOverride?.ignoreOtherMentions ?? false
            if ignoreOthers, !mentioned, !(message.mentions ?? []).isEmpty || !(message.mentionRoles ?? []).isEmpty {
                return
            }
            if let users = channelOverride?.users ?? guildOverride?.users, !users.isEmpty,
               !users.contains(message.author.id), !users.contains(where: { $0.caseInsensitiveCompare(message.author.username ?? "") == .orderedSame })
            {
                return
            }
        }
        var metadata: [String: String] = [:]
        if let guildID {
            metadata["guildId"] = guildID
        }
        let inbound = InboundMessage(
            channel: .discord,
            peerID: channelID,
            text: text,
            senderID: message.author.id,
            senderName: message.member?.nick ?? message.author.globalName ?? message.author.username,
            chatType: chatType,
            messageID: message.id,
            threadID: chatType == .thread ? channelID : nil,
            replyToID: message.messageReference?.messageID,
            wasMentioned: chatType == .direct ? nil : (self.botUserID == nil ? nil : mentioned),
            implicitMentionKinds: repliesToBot ? [.replyToBot] : [],
            isFromBot: message.author.bot == true,
            recipientID: self.botUserID,
            metadata: metadata,
            legacyRoutingAccountID: message.author.id
        )
        if let inboundHandler {
            self.enqueueInbound(inbound, channelID: channelID, handler: inboundHandler)
        }
    }

    /// Runs the inbound handler off the gateway receive path, serially per channel: a slow agent
    /// turn delays only later messages of its own channel, never heartbeats or other channels.
    private func enqueueInbound(_ inbound: InboundMessage, channelID: String, handler: @escaping InboundMessageHandler) {
        let previous = self.inboundTails[channelID]?.task
        self.nextInboundID &+= 1
        let id = self.nextInboundID
        let task = Task { [weak self] in
            await previous?.value
            if !Task.isCancelled {
                await handler(inbound)
            }
            await self?.finishInbound(channelID: channelID, id: id)
        }
        self.inboundTails[channelID] = (id, task)
    }

    private func finishInbound(channelID: String, id: Int) {
        if self.inboundTails[channelID]?.id == id {
            self.inboundTails[channelID] = nil
        }
    }

    // MARK: Legacy REST polling

    private func pollLoop(channelID: String, token: String) async {
        while !Task.isCancelled && self.started {
            do {
                try await self.pollOnce(channelID: channelID, token: token)
                if self.health.state != .healthy {
                    self.health = ChannelTransportHealth(state: .healthy)
                }
            } catch {
                self.health = ChannelTransportHealth(state: .degraded, lastError: "Discord poll failed: \(error.localizedDescription)")
            }
            await ChannelAsync.sleep(milliseconds: max(250, self.config.pollIntervalMs))
        }
    }

    private func pollOnce(channelID: String, token: String) async throws {
        var components = URLComponents(
            url: self.endpoint("channels/\(channelID)/messages"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: "20")]
        guard let url = components?.url else {
            throw OpenClawCoreError.invalidConfiguration("Invalid Discord messages URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        if response.statusCode == 401 {
            throw OpenClawCoreError.unavailable("Discord authentication failed")
        }
        try ChannelHTTP.check(response)
        let messages = try JSONDecoder().decode([DiscordMessage].self, from: response.body)
            .sorted { (UInt64($0.id) ?? 0) < (UInt64($1.id) ?? 0) }
        if !self.hasInitializedCursor {
            self.hasInitializedCursor = true
            if let newest = messages.last {
                self.lastSeenMessageID = max(self.lastSeenMessageID ?? 0, UInt64(newest.id) ?? 0)
            }
            return
        }
        for message in messages {
            let messageID = UInt64(message.id) ?? 0
            if let lastSeen = self.lastSeenMessageID, messageID <= lastSeen {
                continue
            }
            self.lastSeenMessageID = max(self.lastSeenMessageID ?? 0, messageID)
            if message.author.bot == true {
                continue
            }
            await self.handleMessage(message, polledChannelID: channelID)
        }
    }

    private func isMentioningBot(_ message: DiscordMessage) -> Bool {
        guard let botUserID = self.botUserID else {
            return false
        }
        if message.mentions?.contains(where: { $0.id == botUserID }) == true {
            return true
        }
        return message.content.contains("<@\(botUserID)>") || message.content.contains("<@!\(botUserID)>")
    }

    private func normalizedInboundText(from content: String) -> String {
        var text = content
        if let botUserID = self.botUserID {
            text = text.replacingOccurrences(of: "<@\(botUserID)>", with: " ")
            text = text.replacingOccurrences(of: "<@!\(botUserID)>", with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: REST helpers

    private static func reactionPath(_ channelID: String, _ messageID: String, _ emoji: String) -> String {
        let encoded = emoji.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? emoji
        return "channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)/@me"
    }

    private func endpoint(_ path: String) -> URL {
        var base = self.baseURL.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return URL(string: base + "/" + path) ?? self.baseURL.appendingPathComponent(path)
    }

    private func request<T: Decodable>(_ method: String, path: String, token: String, payload: [String: Any]) async throws -> T {
        let request = ChannelHTTP.jsonRequest(
            url: self.endpoint(path),
            method: method,
            body: try ChannelHTTP.jsonBody(payload),
            headers: ["Authorization": "Bot \(token)"]
        )
        let response = try await self.transport.data(for: request)
        try Self.check(response)
        return try JSONDecoder().decode(T.self, from: response.body)
    }

    private func requestNoContent(_ method: String, path: String, token: String) async throws {
        var request = URLRequest(url: self.endpoint(path))
        request.httpMethod = method
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        try Self.check(response)
    }

    private static func check(_ response: HTTPResponseData) throws {
        if response.statusCode == 401 {
            throw ChannelSendError.rejected(status: 401, detail: "Discord authentication failed")
        }
        try ChannelHTTP.check(response)
    }

    private func fetchCurrentUser(token: String) async throws -> DiscordCurrentUser {
        var request = URLRequest(url: self.endpoint("users/@me"))
        request.httpMethod = "GET"
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        if response.statusCode == 401 {
            throw OpenClawCoreError.unavailable("Discord authentication failed")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Discord identity check failed with status \(response.statusCode)")
        }
        return try JSONDecoder().decode(DiscordCurrentUser.self, from: response.body)
    }

    private func resolveToken() throws -> String {
        guard let token = self.config.botToken?.channelTrimmedNonEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Discord bot token is required")
        }
        return token
    }

    private func resolveDefaultChannelID() throws -> String {
        guard let channelID = self.config.defaultChannelID?.channelTrimmedNonEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Discord default channel ID is required")
        }
        return channelID
    }
}
