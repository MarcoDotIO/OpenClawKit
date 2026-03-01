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
    }
}

private struct GoogleChatWebhookEvent: Decodable {
    let type: String?
    let token: String?
    let space: SpaceReference?
    let message: GoogleChatMessagePayload?

    struct SpaceReference: Decodable {
        let name: String?
    }
}

/// Google Chat adapter backed by Google Chat API + inbound event webhook.
public actor GoogleChatChannelAdapter: InboundChannelAdapter {
    /// Adapter channel identifier.
    public let id: ChannelID = .googlechat

    private let config: GoogleChatChannelConfig
    private let transport: any GoogleChatHTTPTransport
    private let explicitBaseURL: URL?

    private var started = false
    private var inboundHandler: InboundMessageHandler?

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

    /// Starts adapter lifecycle.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("Google Chat channel is disabled")
        }
        _ = try self.resolveBearerToken()
        self.started = true
    }

    /// Stops adapter lifecycle.
    public func stop() async {
        self.started = false
    }

    /// Sends outbound message to Google Chat spaces.messages endpoint.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Google Chat adapter is not started")
        }
        let token = try self.resolveBearerToken()
        let target = try self.resolveTarget(from: message)
        let endpoint = try self.resolveMessagesEndpoint(spaceID: target.spaceID)
        let requestBody = GoogleChatSendRequest(
            text: try self.resolveOutboundText(from: message),
            thread: target.threadName.map { GoogleChatSendRequest.ThreadReference(name: $0) }
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Google Chat send failed with status \(response.statusCode)")
        }
    }

    /// Handles inbound webhook event payload from Google Chat.
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
            guard inboundToken == configuredToken else {
                return
            }
        }
        guard let message = event.message else {
            return
        }
        if message.sender?.type?.uppercased() == "BOT" {
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
        let inbound = InboundMessage(
            channel: .googlechat,
            accountID: message.sender?.name,
            peerID: peerID,
            text: text
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
        let peerID = message.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
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
