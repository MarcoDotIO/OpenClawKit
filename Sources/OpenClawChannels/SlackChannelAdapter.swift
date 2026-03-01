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

private struct SlackAuthTestResponse: Decodable {
    let ok: Bool
    let error: String?
    let userID: String?
    let botID: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case error
        case userID = "user_id"
        case botID = "bot_id"
    }
}

private struct SlackGenericResponse: Decodable {
    let ok: Bool
    let error: String?
}

private struct SlackConversationsHistoryResponse: Decodable {
    let ok: Bool
    let error: String?
    let messages: [SlackMessage]?
}

private struct SlackMessage: Decodable {
    let type: String?
    let subtype: String?
    let user: String?
    let botID: String?
    let text: String?
    let ts: String?
    let threadTS: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case subtype
        case user
        case botID = "bot_id"
        case text
        case ts
        case threadTS = "thread_ts"
    }
}

private struct SlackPostMessageRequest: Encodable {
    let channel: String
    let text: String
}

private struct SlackTypingRequest: Encodable {
    let channel: String
}

/// Slack channel adapter backed by Slack Web API.
public actor SlackChannelAdapter: InboundChannelAdapter {
    /// Adapter channel identifier.
    public let id: ChannelID = .slack

    private let config: SlackChannelConfig
    private let transport: any SlackHTTPTransport
    private let explicitBaseURL: URL?
    private let pollIntervalMs: Int

    private var started = false
    private var pollTask: Task<Void, Never>?
    private var inboundHandler: InboundMessageHandler?
    private var botUserID: String?
    private var hasInitializedCursor = false
    private var lastSeenTimestamp: Double?

    /// Creates a Slack channel adapter.
    /// - Parameters:
    ///   - config: Slack channel configuration.
    ///   - transport: HTTP transport implementation.
    ///   - baseURL: Optional Slack API base URL override.
    ///   - pollIntervalMs: Polling interval used for inbound checks.
    public init(
        config: SlackChannelConfig,
        transport: any SlackHTTPTransport = HTTPClient(),
        baseURL: URL? = nil,
        pollIntervalMs: Int = 2_000
    ) {
        self.config = config
        self.transport = transport
        self.explicitBaseURL = baseURL
        self.pollIntervalMs = max(250, pollIntervalMs)
    }

    /// Registers or clears inbound callback.
    /// - Parameter handler: Optional inbound callback.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Starts adapter lifecycle and polling loop.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("Slack channel is disabled")
        }
        if self.started {
            return
        }
        let token = try self.resolveBotToken()
        let channelID = try self.resolveDefaultChannelID()
        self.botUserID = try await self.fetchBotUserID(token: token)
        self.lastSeenTimestamp = nil
        self.hasInitializedCursor = false
        self.started = true
        self.pollTask = Task { [weak self] in
            await self?.pollLoop(channelID: channelID, token: token)
        }
    }

    /// Stops adapter lifecycle.
    public func stop() async {
        self.started = false
        self.pollTask?.cancel()
        self.pollTask = nil
    }

    /// Sends outbound message through Slack chat.postMessage.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Slack adapter is not started")
        }
        let token = try self.resolveBotToken()
        let targetChannel = try self.resolveTargetChannel(from: message)
        let payload = SlackPostMessageRequest(
            channel: targetChannel,
            text: try self.resolveOutboundText(from: message)
        )
        var request = URLRequest(url: try self.resolveEndpoint(path: "chat.postMessage"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Slack send failed with status \(response.statusCode)")
        }
        let parsed = try JSONDecoder().decode(SlackGenericResponse.self, from: response.body)
        guard parsed.ok else {
            throw OpenClawCoreError.unavailable("Slack send failed: \(parsed.error ?? "unknown")")
        }
    }

    public func sendTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Slack adapter is not started")
        }
        let token = try self.resolveBotToken()
        let channel = try self.resolveTargetChannel(fromPeerID: peerID)
        let payload = SlackTypingRequest(channel: channel)
        var request = URLRequest(url: try self.resolveEndpoint(path: "chat.typing"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Slack typing indicator failed with status \(response.statusCode)")
        }
        let parsed = try JSONDecoder().decode(SlackGenericResponse.self, from: response.body)
        guard parsed.ok else {
            throw OpenClawCoreError.unavailable("Slack typing indicator failed: \(parsed.error ?? "unknown")")
        }
    }

    private func pollLoop(channelID: String, token: String) async {
        while !Task.isCancelled && self.started {
            do {
                try await self.pollOnce(channelID: channelID, token: token)
            } catch {
                // Keep loop alive; this adapter retries on next interval tick.
            }
            try? await Task.sleep(nanoseconds: UInt64(self.pollIntervalMs) * 1_000_000)
        }
    }

    private func pollOnce(channelID: String, token: String) async throws {
        var components = URLComponents(
            url: try self.resolveEndpoint(path: "conversations.history"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "channel", value: channelID),
            URLQueryItem(name: "limit", value: "50"),
        ]
        guard let url = components?.url else {
            throw OpenClawCoreError.invalidConfiguration("Invalid Slack conversations.history URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Slack poll failed with status \(response.statusCode)")
        }
        let parsed = try JSONDecoder().decode(SlackConversationsHistoryResponse.self, from: response.body)
        guard parsed.ok else {
            throw OpenClawCoreError.unavailable("Slack poll failed: \(parsed.error ?? "unknown")")
        }

        let sorted = (parsed.messages ?? []).sorted {
            Self.parseTimestamp($0.ts) < Self.parseTimestamp($1.ts)
        }
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
            guard self.shouldProcess(message) else {
                continue
            }
            let text = self.normalizedInboundText(message.text ?? "")
            guard !text.isEmpty else {
                continue
            }
            let peerID = (message.threadTS?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? (message.threadTS ?? channelID)
                : channelID
            let inbound = InboundMessage(
                channel: .slack,
                accountID: message.user,
                peerID: peerID,
                text: text
            )
            if let inboundHandler {
                await inboundHandler(inbound)
            }
        }
    }

    private func shouldProcess(_ message: SlackMessage) -> Bool {
        if message.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "message" {
            return false
        }
        if message.subtype?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "bot_message" {
            return false
        }
        if message.botID != nil {
            return false
        }
        if let botUserID, message.user == botUserID {
            return false
        }
        let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            return false
        }
        if self.config.mentionOnly {
            return self.isMentioningBot(text: text)
        }
        return true
    }

    private func isMentioningBot(text: String) -> Bool {
        guard let botUserID = self.botUserID?.trimmingCharacters(in: .whitespacesAndNewlines), !botUserID.isEmpty else {
            return false
        }
        return text.contains("<@\(botUserID)>")
    }

    private func normalizedInboundText(_ text: String) -> String {
        var value = text
        if self.config.mentionOnly,
           let botUserID = self.botUserID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !botUserID.isEmpty
        {
            value = value.replacingOccurrences(of: "<@\(botUserID)>", with: " ")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchBotUserID(token: String) async throws -> String {
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
        guard let userID = parsed.userID?.trimmingCharacters(in: .whitespacesAndNewlines), !userID.isEmpty else {
            throw OpenClawCoreError.unavailable("Slack auth.test did not return a user ID")
        }
        return userID
    }

    private func resolveBotToken() throws -> String {
        guard let token = self.config.botToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Slack bot token is required")
        }
        return token
    }

    private func resolveDefaultChannelID() throws -> String {
        guard let channelID = self.config.defaultChannelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !channelID.isEmpty
        else {
            throw OpenClawCoreError.invalidConfiguration("Slack default channel ID is required")
        }
        return channelID
    }

    private func resolveTargetChannel(from message: OutboundMessage) throws -> String {
        try self.resolveTargetChannel(fromPeerID: message.peerID)
    }

    private func resolveTargetChannel(fromPeerID peerID: String) throws -> String {
        let trimmed = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return try self.resolveDefaultChannelID()
    }

    private func resolveOutboundText(from message: OutboundMessage) throws -> String {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Slack outbound text is required")
        }
        return text
    }

    private func resolveEndpoint(path: String) throws -> URL {
        let baseRaw = self.explicitBaseURL?.absoluteString ?? self.config.baseURL
        let trimmedBase = baseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty, let baseURL = URL(string: trimmedBase) else {
            throw OpenClawCoreError.invalidConfiguration("Slack base URL is invalid")
        }
        return baseURL.appendingPathComponent(path)
    }

    private static func parseTimestamp(_ raw: String?) -> Double {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return 0
        }
        return Double(raw) ?? 0
    }
}
