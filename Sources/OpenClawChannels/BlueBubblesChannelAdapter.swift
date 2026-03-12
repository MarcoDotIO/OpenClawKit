import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Minimal HTTP transport contract used by the BlueBubbles adapter.
public protocol BlueBubblesHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured HTTP request.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: BlueBubblesHTTPTransport {}

private struct BlueBubblesSendRequest: Encodable {
    let chatGuid: String
    let tempGuid: String
    let message: String
}

private struct BlueBubblesInboundAttachmentPayload: Decodable {
    let mimeType: String?
    let base64Data: String?
    let fileName: String?
    let metadata: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case mimeType
        case base64Data
        case fileName
        case metadata
    }
}

private struct BlueBubblesWebhookEnvelope: Decodable {
    let guid: String?
    let chatGuid: String?
    let text: String?
    let from: String?
    let isFromMe: Bool?
    let attachments: [BlueBubblesInboundAttachmentPayload]?

    private enum CodingKeys: String, CodingKey {
        case guid
        case chatGuid
        case text
        case from
        case isFromMe
        case attachments
        case message
    }

    private struct NestedMessage: Decodable {
        let guid: String?
        let chatGuid: String?
        let text: String?
        let from: String?
        let isFromMe: Bool?
        let attachments: [BlueBubblesInboundAttachmentPayload]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.decodeIfPresent(NestedMessage.self, forKey: .message)
        self.guid = try container.decodeIfPresent(String.self, forKey: .guid) ?? nested?.guid
        self.chatGuid = try container.decodeIfPresent(String.self, forKey: .chatGuid) ?? nested?.chatGuid
        self.text = try container.decodeIfPresent(String.self, forKey: .text) ?? nested?.text
        self.from = try container.decodeIfPresent(String.self, forKey: .from) ?? nested?.from
        self.isFromMe = try container.decodeIfPresent(Bool.self, forKey: .isFromMe) ?? nested?.isFromMe
        self.attachments = try container.decodeIfPresent([BlueBubblesInboundAttachmentPayload].self, forKey: .attachments)
            ?? nested?.attachments
    }
}

/// HTTP-backed BlueBubbles adapter for recommended iMessage integration.
public actor BlueBubblesChannelAdapter: InboundChannelAdapter {
    /// Adapter channel identifier.
    public let id: ChannelID = .bluebubbles

    private let config: BlueBubblesChannelConfig
    private let transport: any BlueBubblesHTTPTransport
    private let explicitServerURL: URL?
    private var started = false
    private var inboundHandler: InboundMessageHandler?

    /// Creates a BlueBubbles adapter.
    /// - Parameters:
    ///   - config: BlueBubbles channel configuration.
    ///   - transport: HTTP transport implementation.
    ///   - serverURL: Optional BlueBubbles base URL override.
    public init(
        config: BlueBubblesChannelConfig,
        transport: any BlueBubblesHTTPTransport = HTTPClient(),
        serverURL: URL? = nil
    ) {
        self.config = config
        self.transport = transport
        self.explicitServerURL = serverURL
    }

    /// Registers or clears inbound callback.
    /// - Parameter handler: Optional callback for accepted inbound messages.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Starts adapter lifecycle.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("BlueBubbles channel is disabled")
        }
        if self.started {
            return
        }
        _ = try self.resolveServerURL()
        _ = try self.resolvePassword()
        self.started = true
    }

    /// Stops adapter lifecycle.
    public func stop() async {
        self.started = false
    }

    /// Sends an outbound BlueBubbles message via the REST API.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("BlueBubbles adapter is not started")
        }
        let password = try self.resolvePassword()
        let chatGUID = try self.resolveChatGUID(from: message)
        let text = try self.resolveText(message.text)
        let endpoint = try self.resolveEndpoint(path: "/api/v1/message/text", password: password)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            BlueBubblesSendRequest(
                chatGuid: chatGUID,
                tempGuid: UUID().uuidString,
                message: text
            )
        )
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("BlueBubbles send failed with status \(response.statusCode)")
        }
    }

    /// Handles an inbound BlueBubbles webhook payload.
    /// - Parameters:
    ///   - payload: Raw webhook JSON payload.
    ///   - password: Optional password or guid supplied by the host transport.
    public func handleWebhookEvent(_ payload: Data, password: String? = nil) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("BlueBubbles adapter is not started")
        }
        try self.assertWebhookPassword(password)

        let envelope = try JSONDecoder().decode(BlueBubblesWebhookEnvelope.self, from: payload)
        guard envelope.isFromMe != true else {
            return
        }
        let peerID = try self.resolveInboundPeerID(envelope)
        let text = envelope.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let attachments = Self.decodeAttachments(envelope.attachments)
        guard !text.isEmpty || !attachments.isEmpty else {
            return
        }

        let inbound = InboundMessage(
            channel: .bluebubbles,
            accountID: envelope.from?.trimmingCharacters(in: .whitespacesAndNewlines),
            peerID: peerID,
            text: text,
            attachments: attachments
        )
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    private func resolveServerURL() throws -> URL {
        let rawURL = self.explicitServerURL?.absoluteString ?? self.config.serverURL
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("BlueBubbles server URL is required")
        }
        let withScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed
            : "http://\(trimmed)"
        guard let url = URL(string: withScheme) else {
            throw OpenClawCoreError.invalidConfiguration("BlueBubbles server URL is invalid")
        }
        return url
    }

    private func resolvePassword() throws -> String {
        let password = self.config.password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !password.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("BlueBubbles password is required")
        }
        return password
    }

    private func resolveEndpoint(path: String, password: String) throws -> URL {
        let baseURL = try self.resolveServerURL()
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: normalizedPath, relativeTo: baseURL)?.absoluteURL else {
            throw OpenClawCoreError.invalidConfiguration("BlueBubbles endpoint is invalid")
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OpenClawCoreError.invalidConfiguration("BlueBubbles endpoint is invalid")
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "password" }
        queryItems.append(URLQueryItem(name: "password", value: password))
        components.queryItems = queryItems
        guard let resolved = components.url else {
            throw OpenClawCoreError.invalidConfiguration("BlueBubbles endpoint is invalid")
        }
        return resolved
    }

    private func resolveChatGUID(from message: OutboundMessage) throws -> String {
        let direct = message.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return direct
        }
        let configured = self.config.defaultChatGUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty {
            return configured
        }
        throw OpenClawCoreError.invalidConfiguration("BlueBubbles chat GUID is required")
    }

    private func resolveText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("BlueBubbles outbound text is required")
        }
        return trimmed
    }

    private func assertWebhookPassword(_ providedPassword: String?) throws {
        let configured = try self.resolvePassword()
        let provided = providedPassword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard provided == configured else {
            throw OpenClawCoreError.unavailable("BlueBubbles webhook authentication failed")
        }
    }

    private func resolveInboundPeerID(_ envelope: BlueBubblesWebhookEnvelope) throws -> String {
        let peerID = envelope.chatGuid?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? envelope.guid?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard !peerID.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("BlueBubbles inbound chat GUID is required")
        }
        return peerID
    }

    private static func decodeAttachments(
        _ payloads: [BlueBubblesInboundAttachmentPayload]?
    ) -> [MediaAttachment] {
        guard let payloads else {
            return []
        }
        return payloads.compactMap { attachment in
            guard let base64 = attachment.base64Data,
                  let data = Data(base64Encoded: base64),
                  !data.isEmpty
            else {
                return nil
            }
            return MediaAttachment(
                mimeType: attachment.mimeType ?? "application/octet-stream",
                data: data,
                fileName: attachment.fileName,
                metadata: attachment.metadata ?? [:]
            )
        }
    }
}
