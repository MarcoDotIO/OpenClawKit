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

    private enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
    }
}

private struct TelegramChat: Decodable {
    let id: Int64
    let type: String
}

private struct TelegramEntity: Decodable {
    let type: String
    let offset: Int
    let length: Int
}

private struct TelegramMessage: Decodable {
    let messageID: Int64
    let text: String?
    let chat: TelegramChat
    let from: TelegramUser?
    let entities: [TelegramEntity]?

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case text
        case chat
        case from
        case entities
    }
}

private struct TelegramUpdate: Decodable {
    let updateID: Int64
    let message: TelegramMessage?

    private enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
    }
}

private struct TelegramAPIResponse<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
}

private struct TelegramSendMessageRequest: Encodable {
    let chatID: Int64
    let text: String

    private enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case text
    }
}

private struct TelegramChatActionRequest: Encodable {
    let chatID: Int64
    let action: String

    private enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case action
    }
}

/// Live Telegram channel adapter backed by Telegram Bot API polling.
public actor TelegramChannelAdapter: InboundChannelAdapter {
    /// Adapter channel identifier.
    public let id: ChannelID = .telegram

    private let config: TelegramChannelConfig
    private let transport: any TelegramHTTPTransport
    private let explicitBaseURL: URL?
    private let offsetStore: any TelegramUpdateOffsetStore

    private var started = false
    private var pollTask: Task<Void, Never>?
    private var inboundHandler: InboundMessageHandler?
    private var botID: Int64?
    private var botUsername: String?
    private var nextOffset: Int64?
    private var recentUpdateIDs: [Int64] = []
    private var recentUpdateIDSet: Set<Int64> = []
    private let maxRecentUpdateCount = 512

    /// Creates a Telegram channel adapter.
    /// - Parameters:
    ///   - config: Telegram channel configuration.
    ///   - transport: HTTP transport implementation.
    ///   - baseURL: Optional Telegram API base URL override.
    ///   - offsetStore: Persistent storage for latest processed update offset.
    public init(
        config: TelegramChannelConfig,
        transport: any TelegramHTTPTransport = HTTPClient(),
        baseURL: URL? = nil,
        offsetStore: any TelegramUpdateOffsetStore = FileTelegramUpdateOffsetStore()
    ) {
        self.config = config
        self.transport = transport
        self.explicitBaseURL = baseURL
        self.offsetStore = offsetStore
    }

    /// Registers an inbound handler invoked for accepted user messages.
    /// - Parameter handler: Optional async inbound handler closure.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Starts adapter lifecycle and begins polling Telegram updates.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("Telegram channel is disabled")
        }
        if self.started {
            return
        }

        self.nextOffset = nil
        self.recentUpdateIDs.removeAll(keepingCapacity: true)
        self.recentUpdateIDSet.removeAll(keepingCapacity: true)
        if let persistedOffset = await self.offsetStore.readLastUpdateID() {
            self.nextOffset = max(0, persistedOffset + 1)
        }
        let token = try self.resolveToken()
        let me = try await self.fetchMe(token: token)
        self.botID = me.id
        self.botUsername = me.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.started = true

        self.pollTask = Task { [weak self] in
            await self?.pollLoop(token: token)
        }
    }

    /// Stops adapter lifecycle and cancels background polling.
    public func stop() async {
        self.started = false
        self.pollTask?.cancel()
        self.pollTask = nil
    }

    /// Sends an outbound message to Telegram.
    /// - Parameter message: Outbound message payload.
    public func send(_ message: OutboundMessage) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Telegram adapter is not started")
        }
        let token = try self.resolveToken()
        let chatID = try self.resolveTargetChatID(from: message)

        let endpoint = try self.resolveEndpoint(token: token, method: "sendMessage")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            TelegramSendMessageRequest(chatID: chatID, text: message.text)
        )
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Telegram send failed with status \(response.statusCode)")
        }
        let parsed = try JSONDecoder().decode(TelegramAPIResponse<TelegramMessage>.self, from: response.body)
        guard parsed.ok else {
            throw OpenClawCoreError.unavailable("Telegram send returned not ok")
        }
    }

    public func sendTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Telegram adapter is not started")
        }
        let token = try self.resolveToken()
        let chatID = try self.resolveTargetChatID(fromPeerID: peerID)
        guard try await self.sendTypingIndicator(token: token, chatID: chatID) else {
            throw OpenClawCoreError.unavailable("Telegram typing indicator failed")
        }
    }

    private func pollLoop(token: String) async {
        while !Task.isCancelled && self.started {
            do {
                try await self.pollOnce(token: token)
            } catch {
                // Keep loop alive; this adapter retries on next interval tick.
            }
            let sleepNs = UInt64(max(250, self.config.pollIntervalMs)) * 1_000_000
            try? await Task.sleep(nanoseconds: sleepNs)
        }
    }

    private func pollOnce(token: String) async throws {
        var components = URLComponents(
            url: try self.resolveEndpoint(token: token, method: "getUpdates"),
            resolvingAgainstBaseURL: false
        )
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "timeout", value: "0"), URLQueryItem(name: "limit", value: "50")]
        if let nextOffset {
            queryItems.append(URLQueryItem(name: "offset", value: String(nextOffset)))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw OpenClawCoreError.invalidConfiguration("Invalid Telegram updates URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Telegram poll failed with status \(response.statusCode)")
        }

        let updatesPayload = try JSONDecoder().decode(TelegramAPIResponse<[TelegramUpdate]>.self, from: response.body)
        guard updatesPayload.ok else {
            return
        }
        let updates = (updatesPayload.result ?? []).sorted { $0.updateID < $1.updateID }
        for update in updates {
            guard !self.shouldSkipUpdateID(update.updateID) else {
                continue
            }
            self.nextOffset = max(self.nextOffset ?? 0, update.updateID + 1)
            await self.offsetStore.writeLastUpdateID(update.updateID)
            guard let message = update.message else {
                continue
            }
            guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                continue
            }
            if message.from?.isBot == true || message.from?.id == self.botID {
                continue
            }
            if self.config.mentionOnly, message.chat.type != "private", !self.isMentioningBot(message) {
                continue
            }
            _ = try? await self.sendTypingIndicator(token: token, chatID: message.chat.id)
            let inbound = InboundMessage(
                channel: .telegram,
                accountID: message.from.map { String($0.id) },
                peerID: String(message.chat.id),
                text: self.normalizedInboundText(message)
            )
            if let inboundHandler {
                await inboundHandler(inbound)
            }
        }
    }

    private func shouldSkipUpdateID(_ updateID: Int64) -> Bool {
        if let nextOffset, updateID < nextOffset {
            return true
        }
        if self.recentUpdateIDSet.contains(updateID) {
            return true
        }
        self.recentUpdateIDSet.insert(updateID)
        self.recentUpdateIDs.append(updateID)
        if self.recentUpdateIDs.count > self.maxRecentUpdateCount {
            let evicted = self.recentUpdateIDs.removeFirst()
            self.recentUpdateIDSet.remove(evicted)
        }
        return false
    }

    private func isMentioningBot(_ message: TelegramMessage) -> Bool {
        guard let username = self.botUsername?.lowercased(), !username.isEmpty else {
            return false
        }
        let normalized = (message.text ?? "").lowercased()
        if normalized.contains("@\(username)") {
            return true
        }
        guard let entities = message.entities, !entities.isEmpty else {
            return false
        }
        let text = message.text ?? ""
        for entity in entities where entity.type == "mention" {
            guard entity.offset >= 0, entity.length > 0 else { continue }
            let start = text.index(text.startIndex, offsetBy: min(entity.offset, text.count))
            let end = text.index(start, offsetBy: min(entity.length, text.distance(from: start, to: text.endIndex)))
            let mention = text[start..<end].lowercased()
            if mention == "@\(username)" {
                return true
            }
        }
        return false
    }

    private func normalizedInboundText(_ message: TelegramMessage) -> String {
        var text = message.text ?? ""
        if self.config.mentionOnly, message.chat.type != "private",
           let username = self.botUsername?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty
        {
            text = text.replacingOccurrences(of: "@\(username)", with: " ")
            text = text.replacingOccurrences(of: "@\(username.lowercased())", with: " ")
            text = text.replacingOccurrences(of: "@\(username.uppercased())", with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendTypingIndicator(token: String, chatID: Int64) async throws -> Bool {
        let endpoint = try self.resolveEndpoint(token: token, method: "sendChatAction")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            TelegramChatActionRequest(chatID: chatID, action: "typing")
        )
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            return false
        }
        let parsed = try JSONDecoder().decode(TelegramAPIResponse<Bool>.self, from: response.body)
        return parsed.ok
    }

    private func fetchMe(token: String) async throws -> TelegramMe {
        let endpoint = try self.resolveEndpoint(token: token, method: "getMe")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
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

    private func resolveTargetChatID(from message: OutboundMessage) throws -> Int64 {
        try self.resolveTargetChatID(fromPeerID: message.peerID)
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
        guard let token = self.config.botToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Telegram bot token is required")
        }
        return token
    }

    private func resolveEndpoint(token: String, method: String) throws -> URL {
        let rawBase = self.explicitBaseURL?.absoluteString ?? self.config.baseURL
        let base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let baseURL = URL(string: base) else {
            throw OpenClawCoreError.invalidConfiguration("Telegram base URL is invalid")
        }
        return baseURL
            .appendingPathComponent("bot\(token)")
            .appendingPathComponent(method)
    }
}
