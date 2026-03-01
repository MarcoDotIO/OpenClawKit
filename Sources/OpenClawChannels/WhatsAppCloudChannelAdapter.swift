import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Minimal HTTP transport contract used by the WhatsApp Cloud adapter.
public protocol WhatsAppCloudHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response payload.
    /// - Parameter request: Configured URL request.
    /// - Returns: Normalized response data.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: WhatsAppCloudHTTPTransport {}

private struct WhatsAppSendTextRequest: Encodable {
    let messagingProduct = "whatsapp"
    let to: String
    let type = "text"
    let text: TextBody

    struct TextBody: Encodable {
        let body: String
    }

    private enum CodingKeys: String, CodingKey {
        case messagingProduct = "messaging_product"
        case to
        case type
        case text
    }
}

private struct WhatsAppWebhookPayload: Decodable {
    let entry: [Entry]

    struct Entry: Decodable {
        let changes: [Change]
    }

    struct Change: Decodable {
        let value: ValuePayload
    }

    struct ValuePayload: Decodable {
        let metadata: Metadata?
        let contacts: [Contact]?
        let messages: [Message]?
        let statuses: [Status]?
    }

    struct Metadata: Decodable {
        let phoneNumberID: String?

        private enum CodingKeys: String, CodingKey {
            case phoneNumberID = "phone_number_id"
        }
    }

    struct Contact: Decodable {
        let waID: String?

        private enum CodingKeys: String, CodingKey {
            case waID = "wa_id"
        }
    }

    struct Message: Decodable {
        let id: String?
        let from: String?
        let text: MessageText?
        let button: MessageButton?
        let interactive: InteractiveMessage?
        let context: MessageContext?
        let type: String?
    }

    struct MessageText: Decodable {
        let body: String?
    }

    struct MessageButton: Decodable {
        let text: String?
    }

    struct InteractiveMessage: Decodable {
        let type: String?
        let buttonReply: InteractiveButtonReply?
        let listReply: InteractiveListReply?

        private enum CodingKeys: String, CodingKey {
            case type
            case buttonReply = "button_reply"
            case listReply = "list_reply"
        }
    }

    struct InteractiveButtonReply: Decodable {
        let title: String?
        let id: String?
    }

    struct InteractiveListReply: Decodable {
        let title: String?
        let id: String?
    }

    struct MessageContext: Decodable {
        let id: String?
        let from: String?
    }

    struct Status: Decodable {
        let id: String?
        let status: String?
        let recipientID: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case status
            case recipientID = "recipient_id"
        }
    }
}

/// WhatsApp Cloud API channel adapter using Graph API transport.
public actor WhatsAppCloudChannelAdapter: InboundChannelAdapter {
    /// Adapter channel identifier.
    public let id: ChannelID = .whatsapp

    private let config: WhatsAppCloudChannelConfig
    private let transport: any WhatsAppCloudHTTPTransport
    private let explicitBaseURL: URL?
    private let diagnosticsSink: RuntimeDiagnosticSink?

    private var started = false
    private var inboundHandler: InboundMessageHandler?
    private var recentInboundMessageIDs: [String] = []
    private var recentInboundMessageIDSet: Set<String> = []
    private let maxRecentInboundMessageCount = 1_024

    /// Creates a WhatsApp Cloud adapter.
    /// - Parameters:
    ///   - config: WhatsApp Cloud channel configuration.
    ///   - transport: HTTP transport implementation.
    ///   - baseURL: Optional Graph API base URL override.
    ///   - diagnosticsSink: Optional diagnostics sink for parity telemetry.
    public init(
        config: WhatsAppCloudChannelConfig,
        transport: any WhatsAppCloudHTTPTransport = HTTPClient(),
        baseURL: URL? = nil,
        diagnosticsSink: RuntimeDiagnosticSink? = nil
    ) {
        self.config = config
        self.transport = transport
        self.explicitBaseURL = baseURL
        self.diagnosticsSink = diagnosticsSink
    }

    /// Registers or clears inbound webhook callback.
    /// - Parameter handler: Optional inbound callback.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Starts adapter lifecycle.
    public func start() async throws {
        guard self.config.enabled else {
            await self.emitDiagnostic(
                name: "channel.whatsapp.start.skipped-disabled",
                metadata: ["channel": self.id.rawValue]
            )
            throw OpenClawCoreError.unavailable("WhatsApp Cloud channel is disabled")
        }
        _ = try self.resolveAccessToken()
        _ = try self.resolvePhoneNumberID()
        self.recentInboundMessageIDs.removeAll(keepingCapacity: true)
        self.recentInboundMessageIDSet.removeAll(keepingCapacity: true)
        self.started = true
        await self.emitDiagnostic(
            name: "channel.whatsapp.started",
            metadata: [
                "channel": self.id.rawValue,
                "apiVersion": self.config.apiVersion,
                "webhookPath": self.config.webhookPath,
            ]
        )
    }

    /// Stops adapter lifecycle.
    public func stop() async {
        self.started = false
        await self.emitDiagnostic(
            name: "channel.whatsapp.stopped",
            metadata: ["channel": self.id.rawValue]
        )
    }

    /// Sends outbound text message through WhatsApp Cloud API.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        guard self.started else {
            await self.emitDiagnostic(
                name: "channel.whatsapp.send.rejected-not-started",
                metadata: ["channel": self.id.rawValue]
            )
            throw OpenClawCoreError.unavailable("WhatsApp Cloud adapter is not started")
        }
        let to = try self.resolveRecipient(from: message)
        let text = try self.resolveOutboundText(from: message)
        let requestBody = WhatsAppSendTextRequest(to: to, text: .init(body: text))
        let endpoint = try self.resolveMessagesEndpoint()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try self.resolveAccessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        await self.emitDiagnostic(
            name: "channel.whatsapp.send.started",
            metadata: [
                "channel": self.id.rawValue,
                "peerID": to,
                "attachmentCount": String(message.attachments.count),
            ]
        )
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            await self.emitDiagnostic(
                name: "channel.whatsapp.send.failed",
                metadata: [
                    "channel": self.id.rawValue,
                    "peerID": to,
                    "statusCode": String(response.statusCode),
                ]
            )
            throw OpenClawCoreError.unavailable("WhatsApp Cloud send failed with status \(response.statusCode)")
        }
        await self.emitDiagnostic(
            name: "channel.whatsapp.send.succeeded",
            metadata: [
                "channel": self.id.rawValue,
                "peerID": to,
                "statusCode": String(response.statusCode),
            ]
        )
    }

    /// Handles webhook verification challenge request.
    /// - Parameters:
    ///   - mode: verify mode query value.
    ///   - token: verify token query value.
    ///   - challenge: challenge query value.
    /// - Returns: Echoed challenge when verification succeeds.
    public func handleWebhookVerification(mode: String?, token: String?, challenge: String?) async -> String? {
        guard mode == "subscribe",
              let token,
              let challenge,
              let configured = self.config.webhookVerifyToken,
              !configured.isEmpty,
              configured == token
        else {
            await self.emitDiagnostic(
                name: "channel.whatsapp.webhook.verify.failed",
                metadata: ["channel": self.id.rawValue]
            )
            return nil
        }
        await self.emitDiagnostic(
            name: "channel.whatsapp.webhook.verify.succeeded",
            metadata: ["channel": self.id.rawValue]
        )
        return challenge
    }

    /// Handles incoming WhatsApp webhook event payload.
    /// - Parameter payload: Raw webhook JSON payload.
    public func handleWebhookEvent(_ payload: Data) async throws {
        guard self.started else {
            await self.emitDiagnostic(
                name: "channel.whatsapp.webhook.rejected-not-started",
                metadata: ["channel": self.id.rawValue]
            )
            throw OpenClawCoreError.unavailable("WhatsApp Cloud adapter is not started")
        }

        await self.emitDiagnostic(
            name: "channel.whatsapp.webhook.received",
            metadata: [
                "channel": self.id.rawValue,
                "payloadBytes": String(payload.count),
            ]
        )
        let event = try JSONDecoder().decode(WhatsAppWebhookPayload.self, from: payload)
        for entry in event.entry {
            for change in entry.changes {
                let value = change.value
                for status in value.statuses ?? [] {
                    await self.emitDiagnostic(
                        name: "channel.whatsapp.webhook.status",
                        metadata: [
                            "channel": self.id.rawValue,
                            "status": status.status ?? "unknown",
                            "recipientID": status.recipientID ?? "",
                            "messageID": status.id ?? "",
                        ]
                    )
                }
                let fallbackPeer = value.contacts?.first?.waID
                let accountID = value.metadata?.phoneNumberID ?? self.config.phoneNumberID
                if !self.isMatchingConfiguredPhoneNumber(accountID: accountID) {
                    await self.emitDiagnostic(
                        name: "channel.whatsapp.webhook.ignored-account-mismatch",
                        metadata: [
                            "channel": self.id.rawValue,
                            "accountID": accountID ?? "",
                        ]
                    )
                    continue
                }
                for message in value.messages ?? [] {
                    guard !self.shouldSkipInboundMessageID(message.id) else {
                        await self.emitDiagnostic(
                            name: "channel.whatsapp.webhook.ignored-duplicate",
                            metadata: [
                                "channel": self.id.rawValue,
                                "messageID": message.id ?? "",
                            ]
                        )
                        continue
                    }
                    let messageType = message.type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "text"
                    guard let text = self.normalizedInboundText(from: message), !text.isEmpty else {
                        await self.emitDiagnostic(
                            name: "channel.whatsapp.webhook.ignored-empty",
                            metadata: [
                                "channel": self.id.rawValue,
                                "messageType": messageType,
                                "messageID": message.id ?? "",
                            ]
                        )
                        continue
                    }
                    guard let peerID = message.from ?? fallbackPeer else { continue }

                    let inbound = InboundMessage(
                        channel: .whatsapp,
                        accountID: accountID,
                        peerID: peerID,
                        text: text
                    )
                    await self.emitDiagnostic(
                        name: "channel.whatsapp.webhook.delivered",
                        metadata: [
                            "channel": self.id.rawValue,
                            "peerID": peerID,
                            "messageType": messageType,
                            "messageID": message.id ?? "",
                            "contextMessageID": message.context?.id ?? "",
                        ]
                    )
                    if let inboundHandler {
                        await inboundHandler(inbound)
                    }
                }
            }
        }
    }

    private func resolveOutboundText(from message: OutboundMessage) throws -> String {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("WhatsApp outbound text is required")
        }
        return trimmed
    }

    private func normalizedInboundText(from message: WhatsAppWebhookPayload.Message) -> String? {
        let textBody = message.text?.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let textBody, !textBody.isEmpty {
            return textBody
        }
        let buttonText = message.button?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let buttonText, !buttonText.isEmpty {
            return buttonText
        }
        let interactiveButton = message.interactive?.buttonReply?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let interactiveButton, !interactiveButton.isEmpty {
            return interactiveButton
        }
        let interactiveList = message.interactive?.listReply?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let interactiveList, !interactiveList.isEmpty {
            return interactiveList
        }
        return nil
    }

    private func isMatchingConfiguredPhoneNumber(accountID: String?) -> Bool {
        let configured = self.config.phoneNumberID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !configured.isEmpty else {
            return true
        }
        let incoming = accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if incoming.isEmpty {
            return true
        }
        return incoming == configured
    }

    private func shouldSkipInboundMessageID(_ messageID: String?) -> Bool {
        guard let messageID = messageID?.trimmingCharacters(in: .whitespacesAndNewlines), !messageID.isEmpty else {
            return false
        }
        if self.recentInboundMessageIDSet.contains(messageID) {
            return true
        }
        self.recentInboundMessageIDSet.insert(messageID)
        self.recentInboundMessageIDs.append(messageID)
        if self.recentInboundMessageIDs.count > self.maxRecentInboundMessageCount {
            let evicted = self.recentInboundMessageIDs.removeFirst()
            self.recentInboundMessageIDSet.remove(evicted)
        }
        return false
    }

    private func resolveAccessToken() throws -> String {
        guard let token = self.config.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("WhatsApp Cloud access token is required")
        }
        return token
    }

    private func resolvePhoneNumberID() throws -> String {
        guard let id = self.config.phoneNumberID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("WhatsApp Cloud phone number ID is required")
        }
        return id
    }

    private func resolveRecipient(from message: OutboundMessage) throws -> String {
        let candidate = message.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty {
            return candidate
        }
        let fallback = message.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !fallback.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("WhatsApp recipient is required")
        }
        return fallback
    }

    private func resolveMessagesEndpoint() throws -> URL {
        let baseRaw = self.explicitBaseURL?.absoluteString ?? self.config.baseURL
        let base = baseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let baseURL = URL(string: base) else {
            throw OpenClawCoreError.invalidConfiguration("WhatsApp Cloud base URL is invalid")
        }
        return baseURL
            .appendingPathComponent(self.config.apiVersion)
            .appendingPathComponent(try self.resolvePhoneNumberID())
            .appendingPathComponent("messages")
    }

    private func emitDiagnostic(name: String, metadata: [String: String] = [:]) async {
        guard let diagnosticsSink else {
            return
        }
        await diagnosticsSink(
            RuntimeDiagnosticEvent(
                subsystem: "channel",
                name: name,
                metadata: metadata
            )
        )
    }
}
