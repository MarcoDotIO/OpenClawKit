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
}

private struct DiscordAuthor: Decodable {
    let id: String
    let bot: Bool?
}

private struct DiscordMessage: Decodable {
    let id: String
    let content: String
    let author: DiscordAuthor
    let mentions: [DiscordAuthor]?
}

/// Live Discord channel adapter backed by Discord REST polling APIs.
public actor DiscordChannelAdapter: ReactingChannelAdapter {
    public typealias PresenceFactory = @Sendable (_ token: String) -> any DiscordPresenceClient

    /// Adapter channel identifier.
    public let id: ChannelID = .discord

    private let config: DiscordChannelConfig
    private let transport: any DiscordHTTPTransport
    private let baseURL: URL
    private let presenceFactory: PresenceFactory?

    private var started = false
    private var pollTask: Task<Void, Never>?
    private var botUserID: String?
    private var lastSeenMessageID: UInt64?
    private var hasInitializedCursor = false
    private var presenceClient: (any DiscordPresenceClient)?
    private var inboundHandler: (@Sendable (InboundMessage) async -> Void)?

    /// Creates a Discord channel adapter.
    /// - Parameters:
    ///   - config: Discord channel configuration.
    ///   - transport: HTTP transport implementation.
    ///   - baseURL: Discord API base URL.
    ///   - presenceFactory: Optional presence client factory.
    public init(
        config: DiscordChannelConfig,
        transport: any DiscordHTTPTransport = HTTPClient(),
        baseURL: URL = URL(string: "https://discord.com/api/v10")!,
        presenceFactory: PresenceFactory? = { token in
            DiscordGatewayPresenceClient(token: token)
        }
    ) {
        self.config = config
        self.transport = transport
        self.baseURL = baseURL
        self.presenceFactory = presenceFactory
    }

    /// Sets an inbound handler invoked for polled user messages.
    /// - Parameter handler: Optional async inbound handler closure.
    public func setInboundHandler(_ handler: (@Sendable (InboundMessage) async -> Void)?) {
        self.inboundHandler = handler
    }

    /// Starts adapter lifecycle and begins polling configured Discord channel.
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
        let channelID = try self.resolveDefaultChannelID()
        self.botUserID = try await self.fetchCurrentUserID(token: token)
        if self.config.presenceEnabled, let presenceFactory = self.presenceFactory {
            let presence = presenceFactory(token)
            try await presence.start()
            self.presenceClient = presence
        }
        self.started = true

        self.pollTask = Task { [weak self] in
            await self?.pollLoop(channelID: channelID, token: token)
        }
    }

    /// Stops adapter lifecycle and cancels background polling.
    public func stop() async {
        self.started = false
        self.pollTask?.cancel()
        self.pollTask = nil
        if let presenceClient = self.presenceClient {
            await presenceClient.stop()
        }
        self.presenceClient = nil
    }

    /// Sends an outbound message to a Discord channel.
    /// - Parameter message: Outbound message payload.
    public func send(_ message: OutboundMessage) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Discord adapter is not started")
        }
        let token = try self.resolveToken()
        let channelID = try resolveTargetChannelID(from: message) ?? self.resolveDefaultChannelID()
        let payload = ["content": message.text]
        let body = try JSONEncoder().encode(payload)
        var request = URLRequest(url: self.baseURL.appending(path: "channels/\(channelID)/messages"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        if response.statusCode == 401 {
            throw OpenClawCoreError.unavailable("Discord authentication failed")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Discord send failed with status \(response.statusCode)")
        }
    }

    /// Discord supports channel typing indicators.
    nonisolated public var supportsTypingIndicator: Bool {
        true
    }

    public func sendTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Discord adapter is not started")
        }
        let token = try self.resolveToken()
        let trimmedPeerID = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelID = trimmedPeerID.isEmpty ? try self.resolveDefaultChannelID() : trimmedPeerID
        _ = try await self.sendTypingIndicator(channelID: channelID, token: token)
    }

    private func resolveTargetChannelID(from message: OutboundMessage) -> String? {
        let candidate = message.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private func pollLoop(channelID: String, token: String) async {
        while !Task.isCancelled && self.started {
            do {
                try await self.pollOnce(channelID: channelID, token: token)
            } catch {
                // Keep loop alive; callers can inspect upstream runtime state.
            }
            let sleepNs = UInt64(max(250, self.config.pollIntervalMs)) * 1_000_000
            try? await Task.sleep(nanoseconds: sleepNs)
        }
    }

    private func pollOnce(channelID: String, token: String) async throws {
        var components = URLComponents(
            url: self.baseURL.appending(path: "channels/\(channelID)/messages"),
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
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Discord poll failed with status \(response.statusCode)")
        }

        let messages = try JSONDecoder().decode([DiscordMessage].self, from: response.body)
            .sorted { (UInt64($0.id) ?? 0) < (UInt64($1.id) ?? 0) }
        if !self.hasInitializedCursor {
            self.hasInitializedCursor = true
            if let newest = messages.last {
                let latest = UInt64(newest.id) ?? 0
                self.lastSeenMessageID = max(self.lastSeenMessageID ?? 0, latest)
            }
            return
        }

        for message in messages {
            let messageID = UInt64(message.id) ?? 0
            if let lastSeen = self.lastSeenMessageID, messageID <= lastSeen {
                continue
            }
            self.lastSeenMessageID = max(self.lastSeenMessageID ?? 0, messageID)
            if message.author.bot == true || message.author.id == self.botUserID {
                continue
            }
            if self.config.mentionOnly, !self.isMentioningBot(message) {
                continue
            }
            let text = self.normalizedInboundText(from: message)
            guard !text.isEmpty else {
                continue
            }
            // The acknowledgement reaction is sent by AutoReplyEngine (ackReactionScope) through
            // ReactingChannelAdapter instead of unconditionally here.
            _ = try? await self.sendTypingIndicator(channelID: channelID, token: token)
            let inbound = InboundMessage(
                channel: .discord,
                peerID: channelID,
                text: text,
                senderID: message.author.id,
                chatType: .channel,
                messageID: message.id,
                wasMentioned: self.botUserID == nil ? nil : self.isMentioningBot(message),
                isFromBot: message.author.bot == true,
                recipientID: self.botUserID,
                legacyRoutingAccountID: message.author.id
            )
            if let inboundHandler {
                await inboundHandler(inbound)
            }
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

    private func normalizedInboundText(from message: DiscordMessage) -> String {
        var text = message.content
        if self.config.mentionOnly, let botUserID = self.botUserID {
            text = text.replacingOccurrences(of: "<@\(botUserID)>", with: " ")
            text = text.replacingOccurrences(of: "<@!\(botUserID)>", with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds a reaction as the bot (`PUT /channels/{c}/messages/{m}/reactions/{emoji}/@me`).
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message id.
    ///   - emoji: Unicode emoji.
    public func addReaction(peerID: String, messageID: String, emoji: String) async throws {
        let token = try self.resolveReactionToken()
        try await self.sendReactionRequest(channelID: peerID, messageID: messageID, emoji: emoji, method: "PUT", token: token)
    }

    /// Removes the bot's reaction (`DELETE .../reactions/{emoji}/@me`).
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message id.
    ///   - emoji: Unicode emoji.
    public func removeReaction(peerID: String, messageID: String, emoji: String) async throws {
        let token = try self.resolveReactionToken()
        try await self.sendReactionRequest(channelID: peerID, messageID: messageID, emoji: emoji, method: "DELETE", token: token)
    }

    private func resolveReactionToken() throws -> String {
        guard let token = self.config.botToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Discord bot token is required")
        }
        return token
    }

    private func sendReactionRequest(channelID: String, messageID: String, emoji: String, method: String, token: String) async throws {
        let endpoint = self.baseURL.appending(path: "channels/\(channelID)/messages/\(messageID)/reactions/\(emoji)/@me")
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        if response.statusCode == 401 {
            throw OpenClawCoreError.unavailable("Discord authentication failed")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Discord reaction failed with status \(response.statusCode)")
        }
    }

    private func sendTypingIndicator(channelID: String, token: String) async throws -> Bool {
        let endpoint = self.baseURL.appending(path: "channels/\(channelID)/typing")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        if response.statusCode == 401 {
            throw OpenClawCoreError.unavailable("Discord authentication failed")
        }
        return (200..<300).contains(response.statusCode)
    }

    private func fetchCurrentUserID(token: String) async throws -> String {
        var request = URLRequest(url: self.baseURL.appending(path: "users/@me"))
        request.httpMethod = "GET"
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        if response.statusCode == 401 {
            throw OpenClawCoreError.unavailable("Discord authentication failed")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Discord identity check failed with status \(response.statusCode)")
        }
        let me = try JSONDecoder().decode(DiscordCurrentUser.self, from: response.body)
        return me.id
    }

    private func resolveToken() throws -> String {
        guard let token = self.config.botToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            throw OpenClawCoreError.invalidConfiguration("Discord bot token is required")
        }
        return token
    }

    private func resolveDefaultChannelID() throws -> String {
        guard let channelID = self.config.defaultChannelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !channelID.isEmpty
        else {
            throw OpenClawCoreError.invalidConfiguration("Discord default channel ID is required")
        }
        return channelID
    }
}
