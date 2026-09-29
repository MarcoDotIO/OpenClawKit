import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Minimal HTTP transport contract used by the Microsoft Teams adapter.
public protocol MicrosoftTeamsHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Normalized response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: MicrosoftTeamsHTTPTransport {}

// MARK: - Service URL allowlist

/// Bot Framework `serviceUrl` validation (upstream `bot-framework-service-url.ts`).
///
/// Only HTTPS URLs whose host equals or ends with `.` + an allowlisted suffix may receive Bot
/// Framework tokens: `smba.trafficmanager.net`, `smba.infra.gcc.teams.microsoft.com`,
/// `smba.infra.gov.teams.microsoft.us`, `smba.infra.dod.teams.microsoft.us`, `botframework.azure.cn`.
public enum BotFrameworkServiceURL {
    /// Allowlisted host suffixes.
    public static let allowedHostSuffixes = [
        "smba.trafficmanager.net",
        "smba.infra.gcc.teams.microsoft.com",
        "smba.infra.gov.teams.microsoft.us",
        "smba.infra.dod.teams.microsoft.us",
        "botframework.azure.cn",
    ]

    /// Whether a service URL may receive Bot Framework tokens.
    /// - Parameter serviceURL: Candidate URL.
    /// - Returns: `true` for allowlisted HTTPS hosts.
    public static func isAllowed(_ serviceURL: String) -> Bool {
        guard let components = URLComponents(string: serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              var host = components.host?.lowercased(), !host.isEmpty
        else {
            return false
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        return self.allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Normalizes an allowlisted service URL (trailing slashes stripped).
    /// - Parameter serviceURL: Candidate URL.
    /// - Returns: Normalized URL string.
    /// - Throws: `OpenClawCoreError.invalidConfiguration("Blocked Microsoft Teams serviceUrl host: <host>")`.
    public static func normalize(_ serviceURL: String) throws -> String {
        guard self.isAllowed(serviceURL) else {
            let host = URLComponents(string: serviceURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "invalid-url"
            throw OpenClawCoreError.invalidConfiguration("Blocked Microsoft Teams serviceUrl host: \(host.isEmpty ? "invalid-url" : host)")
        }
        var trimmed = serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}

// MARK: - Token provider

/// Acquires Bot Connector access tokens with the client-credentials flow.
///
/// `POST https://login.microsoftonline.com/<tenantId ?? botframework.com>/oauth2/v2.0/token` with
/// `scope=https://api.botframework.com/.default`; tokens are cached until `expires_in - 300 s` and
/// concurrent refreshes are coalesced. Government and China clouds use their national authorities
/// (`login.microsoftonline.us` / `api.botframework.us`, `login.partner.microsoftonline.cn` /
/// `api.botframework.azure.cn`).
public actor BotFrameworkTokenProvider {
    private struct TokenResponse: Decodable {
        let accessToken: String?
        let expiresIn: Double?
        let error: String?
        let errorDescription: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case error
            case errorDescription = "error_description"
        }
    }

    private let appID: String
    private let appPassword: String
    private let tenantID: String?
    private let cloud: MicrosoftTeamsCloud
    private let transport: any MicrosoftTeamsHTTPTransport
    private let now: @Sendable () -> Date
    private var cached: (token: String, expiresAt: Date)?
    private var inFlight: Task<(String, Date), Error>?

    /// Creates a token provider.
    /// - Parameters:
    ///   - appID: Bot app id.
    ///   - appPassword: Bot app secret.
    ///   - tenantID: Entra tenant (single-tenant bots); `nil` uses `botframework.com`.
    ///   - cloud: Microsoft cloud.
    ///   - transport: HTTP transport.
    ///   - now: Clock.
    public init(
        appID: String,
        appPassword: String,
        tenantID: String? = nil,
        cloud: MicrosoftTeamsCloud = .public,
        transport: any MicrosoftTeamsHTTPTransport = HTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appID = appID
        self.appPassword = appPassword
        self.tenantID = tenantID?.channelTrimmedNonEmpty
        self.cloud = cloud
        self.transport = transport
        self.now = now
    }

    /// Token endpoint for the configured cloud and tenant.
    nonisolated public var tokenEndpoint: URL {
        let host: String = switch self.cloud {
        case .public: "https://login.microsoftonline.com"
        case .usGov, .usGovDoD: "https://login.microsoftonline.us"
        case .china: "https://login.partner.microsoftonline.cn"
        }
        return URL(string: "\(host)/\(self.tenantID ?? "botframework.com")/oauth2/v2.0/token")!
    }

    /// OAuth scope for the configured cloud.
    nonisolated public var scope: String {
        switch self.cloud {
        case .public: "https://api.botframework.com/.default"
        case .usGov, .usGovDoD: "https://api.botframework.us/.default"
        case .china: "https://api.botframework.azure.cn/.default"
        }
    }

    /// Returns a cached token or acquires a new one.
    /// - Returns: Bearer access token.
    public func token() async throws -> String {
        if let cached, cached.expiresAt > self.now() {
            return cached.token
        }
        if let inFlight {
            return try await inFlight.value.0
        }
        let request = self.tokenRequest()
        let transport = self.transport
        let now = self.now
        let task = Task { () throws -> (String, Date) in
            let response = try await transport.data(for: request)
            let parsed = try? JSONDecoder().decode(TokenResponse.self, from: response.body)
            guard (200..<300).contains(response.statusCode), let token = parsed?.accessToken, !token.isEmpty else {
                let detail = parsed?.errorDescription ?? parsed?.error ?? "HTTP \(response.statusCode)"
                throw OpenClawCoreError.unavailable("Bot Framework token request failed: \(detail)")
            }
            let lifetime = max(60, (parsed?.expiresIn ?? 3_600) - 300)
            return (token, now().addingTimeInterval(lifetime))
        }
        self.inFlight = task
        defer { self.inFlight = nil }
        let (token, expiresAt) = try await task.value
        self.cached = (token, expiresAt)
        return token
    }

    /// Drops the cached token (for example after a 401).
    public func invalidate() {
        self.cached = nil
    }

    private func tokenRequest() -> URLRequest {
        var request = URLRequest(url: self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChannelHTTP.formEncoded([
            ("grant_type", "client_credentials"),
            ("client_id", self.appID),
            ("client_secret", self.appPassword),
            ("scope", self.scope),
        ])
        request.timeoutInterval = 30
        return request
    }
}

// MARK: - Activities

private struct TeamsInboundActivity: Decodable {
    let type: String?
    let id: String?
    let text: String?
    let serviceURL: String?
    let replyToID: String?
    let from: TeamsInboundIdentity?
    let recipient: TeamsInboundIdentity?
    let conversation: TeamsInboundConversation?
    let entities: [TeamsMentionEntity]?
    let membersAdded: [TeamsInboundIdentity]?

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case text
        case serviceURL = "serviceUrl"
        case replyToID = "replyToId"
        case from
        case recipient
        case conversation
        case entities
        case membersAdded
    }

    struct TeamsInboundIdentity: Decodable {
        let id: String?
        let name: String?
    }

    struct TeamsInboundConversation: Decodable {
        let id: String?
        let name: String?
        let conversationType: String?
    }

    struct TeamsMentionEntity: Decodable {
        let type: String?
        let text: String?
        let mentioned: TeamsInboundIdentity?
    }
}

private struct TeamsResourceResponse: Decodable {
    let id: String?
}

/// Microsoft Teams adapter backed by Bot Framework activity APIs (upstream 2026.9.6 semantics).
///
/// Outbound requests carry a real Bot Connector token from ``BotFrameworkTokenProvider`` (the
/// app secret is never sent as a bearer). Every `serviceUrl` (the per-conversation value from
/// inbound activities, else `serviceUrl` config) is validated against
/// ``BotFrameworkServiceURL`` before a token is attached. Text chunks at 4,000 characters;
/// replies post to `activities/{replyToId}`; `typingIndicator` sends `typing` activities; bot
/// installs (`conversationUpdate` adding the bot) emit ``ChannelJoinEvent``.
///
/// - Note: Inbound Bot Framework JWT validation (OpenID metadata) is not performed; hosts must
///   authenticate the webhook endpoint before calling ``handleWebhookEvent(_:)``.
public actor MicrosoftTeamsChannelAdapter: InboundChannelAdapter, ReceiptingChannelAdapter, ChannelConfigurationReporting,
    JoinEventChannelAdapter
{
    /// Adapter channel identifier.
    public let id: ChannelID = .msteams

    /// Upstream Teams outbound chunk limit.
    public static let textChunkLimit = 4_000

    private let config: MicrosoftTeamsChannelConfig
    private let transport: any MicrosoftTeamsHTTPTransport
    private let explicitServiceURL: URL?
    private let injectedTokenProvider: BotFrameworkTokenProvider?

    private var started = false
    private var inboundHandler: InboundMessageHandler?
    private var joinHandler: ChannelJoinEventHandler?
    private var tokenProvider: BotFrameworkTokenProvider?
    private var serviceURLByConversation: [String: String] = [:]

    /// Creates a Microsoft Teams adapter.
    /// - Parameters:
    ///   - config: Microsoft Teams channel configuration (resolve SecretRefs first).
    ///   - transport: HTTP transport implementation (also used for token requests).
    ///   - serviceURL: Optional default service URL override (must be allowlisted).
    ///   - tokenProvider: Optional token provider (defaults to one built from the config).
    public init(
        config: MicrosoftTeamsChannelConfig,
        transport: any MicrosoftTeamsHTTPTransport = HTTPClient(),
        serviceURL: URL? = nil,
        tokenProvider: BotFrameworkTokenProvider? = nil
    ) {
        self.config = config
        self.transport = transport
        self.explicitServiceURL = serviceURL
        self.injectedTokenProvider = tokenProvider
    }

    /// Registers or clears inbound callback.
    /// - Parameter handler: Optional callback for accepted inbound activities.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Registers a handler for bot installs in conversations.
    /// - Parameter handler: Optional join handler.
    public func setJoinEventHandler(_ handler: ChannelJoinEventHandler?) async {
        self.joinHandler = handler
    }

    /// Configuration status: `appId` and `appPassword`, and an allowlisted service URL.
    nonisolated public var configurationStatus: ChannelConfigurationStatus {
        guard self.config.botAppID?.channelTrimmedNonEmpty != nil, self.config.botAppPassword?.channelTrimmedNonEmpty != nil else {
            return .unconfigured(reason: "Microsoft Teams requires appId and appPassword.")
        }
        return .configured
    }

    /// Starts adapter lifecycle after validating credentials and the default service URL.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("Microsoft Teams channel is disabled")
        }
        _ = try self.defaultServiceURL()
        let provider = try self.resolveTokenProvider()
        self.tokenProvider = provider
        self.started = true
    }

    /// Stops adapter lifecycle.
    public func stop() async {
        self.started = false
    }

    /// Probes credentials by acquiring a Bot Connector token.
    /// - Parameter timeoutMs: Probe timeout.
    /// - Returns: Probe result.
    public func probe(timeoutMs: Int) async -> ChannelProbeResult {
        if case .unconfigured(let reason) = self.configurationStatus {
            return ChannelProbeResult(ok: false, detail: reason)
        }
        return await ChannelAsync.probe(timeoutMs: timeoutMs) { [self] in
            let provider = try await self.resolveTokenProvider()
            _ = try await provider.token()
            return "token acquired"
        }
    }

    // MARK: Outbound

    /// Sends outbound message activity to Microsoft Teams.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        _ = try await self.sendReturningReceipt(message)
    }

    /// Sends a message activity (chunked at 4,000 characters) and returns the activity-id receipt.
    /// - Parameter message: Outbound payload.
    /// - Returns: Receipt with the activity ids.
    public func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Microsoft Teams adapter is not started")
        }
        let conversationID = try self.resolveConversationID(from: message)
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Microsoft Teams outbound text is required")
        }
        let chunks = ChannelTextChunker.chunk(text, limit: Self.textChunkLimit, unit: .utf16)
        let parts = try await ChannelMultipartDelivery(replyToID: message.replyToID).run(count: chunks.count) { index in
            var activity: [String: Any] = ["type": "message", "text": chunks[index], "conversation": ["id": conversationID]]
            if let appID = self.config.botAppID?.channelTrimmedNonEmpty {
                activity["from"] = ["id": appID]
            }
            let replyTo = index == 0 ? message.replyToID?.channelTrimmedNonEmpty : nil
            if let replyTo {
                activity["replyToId"] = replyTo
            }
            let response = try await self.postActivity(activity, conversationID: conversationID, replyToID: replyTo)
            let id = (try? JSONDecoder().decode(TeamsResourceResponse.self, from: response.body))?.id ?? ""
            return [ChannelSendReceipt.Part(platformMessageID: id, kind: .text, index: index, replyToID: replyTo)]
        }
        return ChannelSendReceipt(parts: parts, replyToID: message.replyToID)
    }

    /// Teams typing activities follow `typingIndicator` (default `true`).
    nonisolated public var supportsTypingIndicator: Bool {
        self.config.typingIndicator
    }

    /// Sends a `typing` activity.
    /// - Parameters:
    ///   - accountID: Channel account key (unused).
    ///   - peerID: Conversation id.
    public func sendTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard self.started, self.config.typingIndicator else { return }
        let conversationID = try peerID.channelTrimmedNonEmpty ?? self.defaultConversationID()
        var activity: [String: Any] = ["type": "typing"]
        if let appID = self.config.botAppID?.channelTrimmedNonEmpty {
            activity["from"] = ["id": appID]
        }
        _ = try await self.postActivity(activity, conversationID: conversationID, replyToID: nil)
    }

    private func postActivity(_ activity: [String: Any], conversationID: String, replyToID: String?) async throws -> HTTPResponseData {
        // Validate the host before a token is ever attached.
        let serviceURL = try self.serviceURL(forConversation: conversationID)
        var path = "\(serviceURL)/v3/conversations/\(Self.escape(conversationID))/activities"
        if let replyToID {
            path += "/\(Self.escape(replyToID))"
        }
        guard let url = URL(string: path) else {
            throw OpenClawCoreError.invalidConfiguration("Microsoft Teams activity URL is invalid")
        }
        let provider = try self.resolveTokenProvider()
        var request = ChannelHTTP.jsonRequest(url: url, body: try ChannelHTTP.jsonBody(activity), timeout: 30)
        request.setValue("Bearer \(try await provider.token())", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        if response.statusCode == 401 {
            await provider.invalidate()
        }
        try ChannelHTTP.check(response)
        return response
    }

    // MARK: Inbound

    /// Handles inbound Teams webhook activity payload.
    ///
    /// Caches the activity's allowlisted `serviceUrl` for its conversation, emits join events for
    /// bot installs, and delivers human `message` activities (mention-gated in group chats and
    /// channels when `requireMention` is on).
    /// - Parameter payload: Raw activity JSON payload.
    public func handleWebhookEvent(_ payload: Data) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Microsoft Teams adapter is not started")
        }
        let activity = try JSONDecoder().decode(TeamsInboundActivity.self, from: payload)
        let conversationID = activity.conversation?.id?.channelTrimmedNonEmpty
        if let conversationID, let serviceURL = activity.serviceURL, let normalized = try? BotFrameworkServiceURL.normalize(serviceURL) {
            self.serviceURLByConversation[conversationID] = normalized
        }
        let type = activity.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type == "conversationupdate" {
            await self.handleConversationUpdate(activity)
            return
        }
        guard type == "message" else {
            return
        }
        let senderID = activity.from?.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if senderID.isEmpty || self.isSelfAuthored(senderID: senderID, recipientID: activity.recipient?.id) {
            return
        }
        var text = activity.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            return
        }
        let chatType: ChannelChatType
        switch activity.conversation?.conversationType?.lowercased() {
        case "personal": chatType = .direct
        case "channel": chatType = .channel
        // groupChat, and activities without a conversation type, are gated like group chats.
        default: chatType = .group
        }
        let mentioned = self.isMentioningBot(activity: activity, text: text)
        if self.config.mentionOnly, chatType != .direct, !mentioned {
            return
        }
        text = self.normalizedInboundText(text)
        guard !text.isEmpty else {
            return
        }
        let peerID = conversationID ?? self.config.defaultConversationID ?? "unknown-conversation"
        var metadata: [String: String] = [:]
        if let serviceURL = self.serviceURLByConversation[peerID] {
            metadata["serviceUrl"] = serviceURL
        }
        let inbound = InboundMessage(
            channel: .msteams,
            peerID: peerID,
            text: text,
            senderID: senderID,
            senderName: activity.from?.name,
            chatType: chatType,
            messageID: activity.id,
            replyToID: activity.replyToID,
            wasMentioned: chatType == .direct ? nil : mentioned,
            recipientID: activity.recipient?.id,
            metadata: metadata,
            legacyRoutingAccountID: senderID
        )
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    private func handleConversationUpdate(_ activity: TeamsInboundActivity) async {
        guard let conversationID = activity.conversation?.id, let joinHandler else { return }
        let botIDs = Set([activity.recipient?.id, self.config.botAppID].compactMap(\.self))
        guard activity.membersAdded?.contains(where: { $0.id.map(botIDs.contains) ?? false }) == true else { return }
        let chatType: ChannelChatType = activity.conversation?.conversationType?.lowercased() == "channel" ? .channel : .group
        await joinHandler(ChannelJoinEvent(channel: .msteams, peerID: conversationID, roomName: activity.conversation?.name, chatType: chatType))
    }

    private func isSelfAuthored(senderID: String, recipientID: String?) -> Bool {
        let botID = self.config.botAppID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !botID.isEmpty, senderID == botID || senderID == "28:\(botID)" {
            return true
        }
        return recipientID != nil && senderID == recipientID
    }

    private func isMentioningBot(activity: TeamsInboundActivity, text: String) -> Bool {
        let botIDs = Set([self.config.botAppID, activity.recipient?.id].compactMap { $0?.channelTrimmedNonEmpty })
        if activity.entities?.contains(where: {
            $0.type?.lowercased() == "mention" && ($0.mentioned?.id.map { id in botIDs.contains(id) || botIDs.contains { "28:\($0)" == id } } ?? false)
        }) == true {
            return true
        }
        if botIDs.contains(where: { text.contains($0) }) {
            return true
        }
        return text.lowercased().contains("<at>")
    }

    private func normalizedInboundText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<at>", with: " ")
            .replacingOccurrences(of: "</at>", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    private func resolveTokenProvider() throws -> BotFrameworkTokenProvider {
        if let provider = self.tokenProvider ?? self.injectedTokenProvider {
            return provider
        }
        guard let appID = self.config.botAppID?.channelTrimmedNonEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Microsoft Teams bot app id is required")
        }
        guard let password = self.config.botAppPassword?.channelTrimmedNonEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Microsoft Teams bot app password is required")
        }
        let provider = BotFrameworkTokenProvider(
            appID: appID,
            appPassword: password,
            tenantID: self.config.tenantID,
            cloud: self.config.cloud,
            transport: self.transport
        )
        self.tokenProvider = provider
        return provider
    }

    private func defaultServiceURL() throws -> String {
        let raw = self.explicitServiceURL?.absoluteString ?? self.config.serviceURL
        return try BotFrameworkServiceURL.normalize(raw)
    }

    private func serviceURL(forConversation conversationID: String) throws -> String {
        if let cached = self.serviceURLByConversation[conversationID] {
            return cached
        }
        return try self.defaultServiceURL()
    }

    private func defaultConversationID() throws -> String {
        guard let configured = self.config.defaultConversationID?.channelTrimmedNonEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Microsoft Teams conversation ID is required")
        }
        return configured
    }

    private func resolveConversationID(from message: OutboundMessage) throws -> String {
        try message.peerID.channelTrimmedNonEmpty ?? self.defaultConversationID()
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
