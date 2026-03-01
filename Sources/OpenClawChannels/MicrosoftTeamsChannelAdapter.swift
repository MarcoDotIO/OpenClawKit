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

private struct TeamsOutboundActivity: Encodable {
    let type = "message"
    let text: String
    let from: TeamsOutboundIdentity?
    let conversation: TeamsOutboundConversation?

    struct TeamsOutboundIdentity: Encodable {
        let id: String
    }

    struct TeamsOutboundConversation: Encodable {
        let id: String
    }
}

private struct TeamsInboundActivity: Decodable {
    let type: String?
    let text: String?
    let from: TeamsInboundIdentity?
    let recipient: TeamsInboundIdentity?
    let conversation: TeamsInboundConversation?
    let entities: [TeamsMentionEntity]?

    struct TeamsInboundIdentity: Decodable {
        let id: String?
        let name: String?
    }

    struct TeamsInboundConversation: Decodable {
        let id: String?
    }

    struct TeamsMentionEntity: Decodable {
        let type: String?
        let text: String?
        let mentioned: TeamsInboundIdentity?
    }
}

/// Microsoft Teams adapter backed by Bot Framework activity APIs.
public actor MicrosoftTeamsChannelAdapter: InboundChannelAdapter {
    /// Adapter channel identifier.
    public let id: ChannelID = .msteams

    private let config: MicrosoftTeamsChannelConfig
    private let transport: any MicrosoftTeamsHTTPTransport
    private let explicitServiceURL: URL?

    private var started = false
    private var inboundHandler: InboundMessageHandler?

    /// Creates a Microsoft Teams adapter.
    /// - Parameters:
    ///   - config: Microsoft Teams channel configuration.
    ///   - transport: HTTP transport implementation.
    ///   - serviceURL: Optional Bot Framework service URL override.
    public init(
        config: MicrosoftTeamsChannelConfig,
        transport: any MicrosoftTeamsHTTPTransport = HTTPClient(),
        serviceURL: URL? = nil
    ) {
        self.config = config
        self.transport = transport
        self.explicitServiceURL = serviceURL
    }

    /// Registers or clears inbound callback.
    /// - Parameter handler: Optional callback for accepted inbound activities.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Starts adapter lifecycle.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("Microsoft Teams channel is disabled")
        }
        _ = try self.resolveServiceURL()
        _ = try self.resolveBotAuthToken()
        self.started = true
    }

    /// Stops adapter lifecycle.
    public func stop() async {
        self.started = false
    }

    /// Sends outbound message activity to Microsoft Teams.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Microsoft Teams adapter is not started")
        }
        let conversationID = try self.resolveConversationID(from: message)
        let endpoint = try self.resolveServiceURL()
            .appendingPathComponent("v3")
            .appendingPathComponent("conversations")
            .appendingPathComponent(conversationID)
            .appendingPathComponent("activities")
        let payload = TeamsOutboundActivity(
            text: try self.resolveOutboundText(from: message),
            from: self.config.botAppID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? TeamsOutboundActivity.TeamsOutboundIdentity(id: self.config.botAppID ?? "")
                : nil,
            conversation: TeamsOutboundActivity.TeamsOutboundConversation(id: conversationID)
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try self.resolveBotAuthToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Microsoft Teams send failed with status \(response.statusCode)")
        }
    }

    /// Handles inbound Teams webhook activity payload.
    /// - Parameter payload: Raw activity JSON payload.
    public func handleWebhookEvent(_ payload: Data) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Microsoft Teams adapter is not started")
        }
        let activity = try JSONDecoder().decode(TeamsInboundActivity.self, from: payload)
        guard activity.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "message" else {
            return
        }

        let senderID = activity.from?.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if senderID.isEmpty {
            return
        }
        if self.isSelfAuthored(senderID: senderID) {
            return
        }

        var text = activity.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            return
        }
        if self.config.mentionOnly, !self.isMentioningBot(activity: activity, text: text) {
            return
        }
        text = self.normalizedInboundText(text)
        guard !text.isEmpty else {
            return
        }
        let conversationID = activity.conversation?.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? self.config.defaultConversationID
            ?? "unknown-conversation"
        let inbound = InboundMessage(
            channel: .msteams,
            accountID: senderID,
            peerID: conversationID,
            text: text
        )
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    private func isSelfAuthored(senderID: String) -> Bool {
        let botID = self.config.botAppID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !botID.isEmpty && senderID == botID
    }

    private func isMentioningBot(activity: TeamsInboundActivity, text: String) -> Bool {
        let botID = self.config.botAppID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !botID.isEmpty {
            if activity.entities?.contains(where: {
                $0.type?.lowercased() == "mention" && $0.mentioned?.id?.trimmingCharacters(in: .whitespacesAndNewlines) == botID
            }) == true {
                return true
            }
            if text.contains(botID) {
                return true
            }
        }
        return text.lowercased().contains("<at>")
    }

    private func normalizedInboundText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<at>", with: " ")
            .replacingOccurrences(of: "</at>", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveServiceURL() throws -> URL {
        let raw = self.explicitServiceURL?.absoluteString ?? self.config.serviceURL
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            throw OpenClawCoreError.invalidConfiguration("Microsoft Teams service URL is invalid")
        }
        return url
    }

    private func resolveBotAuthToken() throws -> String {
        let token = self.config.botAppPassword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Microsoft Teams bot app password is required")
        }
        return token
    }

    private func resolveConversationID(from message: OutboundMessage) throws -> String {
        let directConversationID = message.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directConversationID.isEmpty {
            return directConversationID
        }
        let configured = self.config.defaultConversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty {
            return configured
        }
        throw OpenClawCoreError.invalidConfiguration("Microsoft Teams conversation ID is required")
    }

    private func resolveOutboundText(from message: OutboundMessage) throws -> String {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Microsoft Teams outbound text is required")
        }
        return text
    }
}
