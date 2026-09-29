import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Minimal HTTP transport contract used by the Google Chat adapter.
public protocol GoogleChatHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response payload.
    /// - Parameter request: Configured URL request.
    /// - Returns: Normalized response data.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: GoogleChatHTTPTransport {}

private struct GoogleChatSendRequest: Encodable {
    let text: String
    let thread: ThreadReference?

    struct ThreadReference: Encodable {
        let name: String
    }
}

private struct GoogleChatMessagePayload: Decodable {
    let name: String?
    let text: String?
    let sender: Sender?
    let thread: ThreadReference?
    let space: SpaceReference?

    struct Sender: Decodable {
        let name: String?
        let type: String?
    }

    struct ThreadReference: Decodable {
        let name: String?
    }

    struct SpaceReference: Decodable {
        let name: String?
        let type: String?
        let spaceType: String?
    }
}

private struct GoogleChatWebhookEvent: Decodable {
    let type: String?
    let token: String?
    let space: SpaceReference?
    let message: GoogleChatMessagePayload?

    struct SpaceReference: Decodable {
        let name: String?
        let type: String?
        let spaceType: String?
        let displayName: String?
    }
}

/// Google Chat adapter backed by Google Chat API + inbound event webhook.
///
/// 2026.3.0 (upstream 2026.9.6): outbound text chunks at 32,000 UTF-8 bytes; `typingIndicator`
/// `message` (default) posts a `_<bot> is typing..._` placeholder that the first reply chunk
/// replaces via `PATCH ...?updateMask=text` (`reaction` needs user OAuth and falls back to
/// `message`, like upstream); bot senders are dropped unless `allowBots` admits them, in which
/// case they arrive with `isFromBot` so the bot-loop guard applies; `ADDED_TO_SPACE` emits a
/// ``ChannelJoinEvent``; sends return message-name receipts. Reactions and message actions were
/// removed upstream and are not advertised.
public actor GoogleChatChannelAdapter: InboundChannelAdapter, ReceiptingChannelAdapter, JoinEventChannelAdapter,
    ChannelConfigurationReporting
{
    /// Adapter channel identifier.
    public let id: ChannelID = .googlechat

    private let config: GoogleChatChannelConfig
    private let transport: any GoogleChatHTTPTransport
    private let explicitBaseURL: URL?

    private var started = false
    private var inboundHandler: InboundMessageHandler?
    private var joinHandler: ChannelJoinEventHandler?
    private var typingPlaceholders: [String: String] = [:]

    /// Creates a Google Chat adapter.
    /// - Parameters:
    ///   - config: Google Chat channel configuration.
    ///   - transport: HTTP transport implementation.
    ///   - baseURL: Optional Google Chat API base URL override.
    public init(
        config: GoogleChatChannelConfig,
        transport: any GoogleChatHTTPTransport = HTTPClient(),
        baseURL: URL? = nil
    ) {
        self.config = config
        self.transport = transport
        self.explicitBaseURL = baseURL
    }

    /// Registers or clears inbound callback.
    /// - Parameter handler: Optional callback for accepted inbound events.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Registers or clears the join-event callback (`ADDED_TO_SPACE`).
    /// - Parameter handler: Callback.
    public func setJoinEventHandler(_ handler: ChannelJoinEventHandler?) async {
        self.joinHandler = handler
    }

    /// Configured when a bearer token is present (service-account auth is resolved by the host).
    nonisolated public var configurationStatus: ChannelConfigurationStatus {
        let token = self.config.bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty ? .unconfigured(reason: "Google Chat requires a bearer token (mint one from the service account).") : .configured
    }

    /// Effective typing mode (`reaction` falls back to `message`; default `message`).
    nonisolated var typingMode: GoogleChatTypingIndicator {
        switch self.config.typingIndicator ?? .message {
        case .none: .none
        case .message, .reaction: .message
        }
    }

    /// Whether the placeholder typing message is enabled.
    nonisolated public var supportsTypingIndicator: Bool {
        self.typingMode != .none
    }

    /// Starts adapter lifecycle.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("Google Chat channel is disabled")
        }
        _ = try self.resolveBearerToken()
        self.typingPlaceholders.removeAll()
        self.started = true
    }

    /// Stops adapter lifecycle.
    public func stop() async {
        self.started = false
    }

    /// Posts the `_<bot> is typing..._` placeholder once per conversation.
    /// - Parameters:
    ///   - accountID: Unused.
    ///   - peerID: Space or thread.
    public func sendTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard self.started, self.typingMode == .message, self.typingPlaceholders[peerID] == nil else { return }
        let target = try self.resolveTarget(peerID: peerID)
        let botName = self.config.policy.name?.channelTrimmedNonEmpty ?? "OpenClaw"
        let name = try await self.postMessage(text: "_\(botName) is typing..._", target: target)
        if let name {
            self.typingPlaceholders[peerID] = name
        }
    }

    /// Deletes an unused typing placeholder.
    /// - Parameters:
    ///   - accountID: Unused.
    ///   - peerID: Space or thread.
    public func stopTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard let name = self.typingPlaceholders.removeValue(forKey: peerID) else { return }
        var request = URLRequest(url: try self.messageURL(name: name))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(try self.resolveBearerToken())", forHTTPHeaderField: "Authorization")
        _ = try? await self.transport.data(for: request)
    }

    /// Sends outbound message to Google Chat spaces.messages endpoint.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        _ = try await self.sendReturningReceipt(message)
    }

    /// Sends 32 KB byte chunks (the first replaces a pending typing placeholder) and returns message names.
    /// - Parameter message: Outbound payload.
    /// - Returns: Receipt.
    public func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Google Chat adapter is not started")
        }
        let target = try self.resolveTarget(from: message)
        let text = try self.resolveOutboundText(from: message)
        let chunks = ChannelTextChunker.chunk(text, for: .googlechat, policy: self.config.policy)
        let parts = try await ChannelMultipartDelivery(threadID: target.threadName).run(count: chunks.count) { index in
            let chunk = chunks[index]
            var name: String?
            if index == 0, let placeholder = self.typingPlaceholders.removeValue(forKey: message.peerID.trimmingCharacters(in: .whitespaces)) {
                name = try await self.updateMessage(name: placeholder, text: chunk)
            } else {
                name = try await self.postMessage(text: chunk, target: target)
            }
            return [ChannelSendReceipt.Part(platformMessageID: name ?? "", index: index, threadID: target.threadName)]
        }
        return ChannelSendReceipt(parts: parts.filter { !$0.platformMessageID.isEmpty }, threadID: target.threadName)
    }

    private func postMessage(text: String, target: (spaceID: String, threadName: String?)) async throws -> String? {
        let token = try self.resolveBearerToken()
        let endpoint = try self.resolveMessagesEndpoint(spaceID: target.spaceID)
        let requestBody = GoogleChatSendRequest(
            text: text,
            thread: target.threadName.map { GoogleChatSendRequest.ThreadReference(name: $0) }
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)
        let response = try await self.transport.data(for: request)
        try ChannelHTTP.check(response)
        return ChannelHTTP.jsonObject(response.body)?["name"] as? String
    }

    private func updateMessage(name: String, text: String) async throws -> String? {
        var components = URLComponents(url: try self.messageURL(name: name), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "updateMask", value: "text")]
        guard let url = components?.url else {
            throw OpenClawCoreError.invalidConfiguration("Invalid Google Chat message name \(name)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try self.resolveBearerToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        let response = try await self.transport.data(for: request)
        try ChannelHTTP.check(response)
        return (ChannelHTTP.jsonObject(response.body)?["name"] as? String) ?? name
    }

    private func messageURL(name: String) throws -> URL {
        let baseRaw = (self.explicitBaseURL?.absoluteString ?? self.config.baseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.hasPrefix("spaces/"), !name.contains(".."), let baseURL = URL(string: baseRaw) else {
            throw OpenClawCoreError.invalidConfiguration("Invalid Google Chat message name \(name)")
        }
        return baseURL.appendingPathComponent(name)
    }

    /// Handles inbound webhook event payload from Google Chat.
    ///
    /// - Note: The adapter checks only the legacy `verificationToken` (constant-time) when one is
    ///   configured. It does not verify Google's `Authorization: Bearer` JWT (`audienceType` and
    ///   `audience` are not enforced here): hosts must verify that token (issuer
    ///   `chat@system.gserviceaccount.com`, audience = the configured project number or app URL)
    ///   before calling this method, because the payload's sender is the access-policy boundary.
    /// - Parameter payload: Raw webhook JSON payload.
    public func handleWebhookEvent(_ payload: Data) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Google Chat adapter is not started")
        }
        let event = try JSONDecoder().decode(GoogleChatWebhookEvent.self, from: payload)
        if let configuredToken = self.config.verificationToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredToken.isEmpty
        {
            let inboundToken = event.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard ChannelWebhookSignature.constantTimeEquals(inboundToken, configuredToken) else {
                return
            }
        }
        if event.type?.uppercased() == "ADDED_TO_SPACE" {
            let spaceName = event.space?.name ?? event.message?.space?.name
            let spaceType = (event.space?.spaceType ?? event.space?.type)?.uppercased()
            if let spaceName, spaceType != "DM", spaceType != "DIRECT_MESSAGE", let joinHandler {
                await joinHandler(ChannelJoinEvent(channel: .googlechat, peerID: spaceName, roomName: event.space?.displayName, chatType: .group))
            }
        }
        guard let message = event.message else {
            return
        }
        let isBot = message.sender?.type?.uppercased() == "BOT"
        if isBot, !(self.config.policy.allowBots?.admitsBots ?? false) {
            return
        }
        guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return
        }

        let spaceID = message.space?.name
            ?? event.space?.name
            ?? self.config.defaultSpaceID
            ?? "unknown-space"
        let peerID = message.thread?.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (message.thread?.name ?? spaceID)
            : spaceID
        let spaceType = (message.space?.spaceType ?? message.space?.type ?? event.space?.spaceType ?? event.space?.type)?.uppercased()
        let chatType: ChannelChatType
        switch spaceType {
        case "DM", "DIRECT_MESSAGE", nil: chatType = .direct
        default: chatType = message.thread?.name == nil ? .group : .thread
        }
        let inbound = InboundMessage(
            channel: .googlechat,
            peerID: peerID,
            text: text,
            senderID: message.sender?.name,
            chatType: chatType,
            messageID: message.name,
            threadID: message.thread?.name,
            isFromBot: isBot,
            legacyRoutingAccountID: message.sender?.name
        )
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    private func resolveBearerToken() throws -> String {
        guard let token = self.config.bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Google Chat bearer token is required")
        }
        return token
    }

    private func resolveOutboundText(from message: OutboundMessage) throws -> String {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Google Chat outbound text is required")
        }
        return trimmed
    }

    private func resolveMessagesEndpoint(spaceID: String) throws -> URL {
        let baseRaw = self.explicitBaseURL?.absoluteString ?? self.config.baseURL
        let base = baseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let baseURL = URL(string: base) else {
            throw OpenClawCoreError.invalidConfiguration("Google Chat base URL is invalid")
        }
        return baseURL
            .appendingPathComponent(spaceID)
            .appendingPathComponent("messages")
    }

    private func resolveTarget(from message: OutboundMessage) throws -> (spaceID: String, threadName: String?) {
        try self.resolveTarget(peerID: message.peerID)
    }

    private func resolveTarget(peerID raw: String) throws -> (spaceID: String, threadName: String?) {
        let peerID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if peerID.hasPrefix("spaces/"), let range = peerID.range(of: "/threads/") {
            let spaceID = String(peerID[..<range.lowerBound])
            return (spaceID, peerID)
        }
        if peerID.hasPrefix("spaces/") {
            return (peerID, nil)
        }

        if let defaultSpaceID = self.config.defaultSpaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !defaultSpaceID.isEmpty
        {
            return (defaultSpaceID, nil)
        }
        throw OpenClawCoreError.invalidConfiguration("Google Chat default space ID is required")
    }
}
