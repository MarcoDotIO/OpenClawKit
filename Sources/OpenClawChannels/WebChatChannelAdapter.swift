import Foundation
import OpenClawCore
import OpenClawProtocol

/// Transcript direction marker for WebChat conversation entries.
public enum WebChatTranscriptDirection: String, Sendable, Equatable, Codable {
    case inbound
    case outbound
}

/// One retained WebChat transcript entry.
public struct WebChatTranscriptEntry: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let direction: WebChatTranscriptDirection
    public let sessionID: String
    public let accountID: String?
    public let text: String
    public let attachments: [MediaAttachment]
    public let occurredAt: Date

    /// Creates a transcript entry.
    public init(
        id: String = UUID().uuidString,
        direction: WebChatTranscriptDirection,
        sessionID: String,
        accountID: String?,
        text: String,
        attachments: [MediaAttachment] = [],
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.direction = direction
        self.sessionID = sessionID
        self.accountID = accountID
        self.text = text
        self.attachments = attachments
        self.occurredAt = occurredAt
    }
}

private struct WebChatInboundEvent: Decodable {
    let sessionID: String
    let userID: String?
    let text: String
    let sharedSecret: String?
    let attachments: [WebChatInboundAttachment]?

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case userID
        case text
        case sharedSecret
        case attachments
    }
}

private struct WebChatInboundAttachment: Decodable {
    let id: String?
    let mimeType: String
    let base64Data: String
    let fileName: String?
    let metadata: [String: String]?
}

/// Production WebChat adapter with explicit webhook contract and transcript storage.
public actor WebChatChannelAdapter: InboundChannelAdapter {
    /// Adapter channel identifier.
    public let id: ChannelID = .webchat

    private let config: WebChatChannelConfig
    private var started = false
    private var inboundHandler: InboundMessageHandler?
    private var transcriptBySession: [String: [WebChatTranscriptEntry]] = [:]
    private var outboundBuffer: [OutboundMessage] = []

    /// Creates a WebChat adapter.
    /// - Parameter config: WebChat channel configuration.
    public init(config: WebChatChannelConfig) {
        self.config = config
    }

    /// Registers or clears inbound callback.
    /// - Parameter handler: Optional callback for inbound user events.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Starts adapter lifecycle.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("WebChat channel is disabled")
        }
        self.started = true
    }

    /// Stops adapter lifecycle.
    public func stop() async {
        self.started = false
    }

    /// Sends outbound message through WebChat adapter and stores transcript entry.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("WebChat adapter is not started")
        }
        let sessionID = try self.resolveSessionID(from: message.peerID)
        let text = try self.resolveText(message.text)
        let normalized = OutboundMessage(
            channel: .webchat,
            accountID: message.accountID,
            peerID: sessionID,
            text: text,
            attachments: message.attachments
        )
        self.outboundBuffer.append(normalized)
        self.appendTranscript(
            WebChatTranscriptEntry(
                direction: .outbound,
                sessionID: sessionID,
                accountID: message.accountID,
                text: text,
                attachments: message.attachments
            )
        )
    }

    /// Handles inbound webhook payload from a WebChat frontend.
    /// - Parameters:
    ///   - payload: Raw inbound JSON payload.
    ///   - sharedSecret: Optional shared secret provided by host transport/header.
    public func handleWebhookEvent(_ payload: Data, sharedSecret: String? = nil) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("WebChat adapter is not started")
        }
        let event = try JSONDecoder().decode(WebChatInboundEvent.self, from: payload)
        let sessionID = try self.resolveSessionID(from: event.sessionID)
        let text = try self.resolveText(event.text)
        try self.assertSharedSecret(headerSecret: sharedSecret, bodySecret: event.sharedSecret)
        let attachments = event.attachments?.compactMap(Self.decodeAttachment(_:)) ?? []

        let inbound = InboundMessage(
            channel: .webchat,
            accountID: event.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
            peerID: sessionID,
            text: text,
            attachments: attachments
        )
        self.appendTranscript(
            WebChatTranscriptEntry(
                direction: .inbound,
                sessionID: sessionID,
                accountID: inbound.accountID,
                text: text,
                attachments: attachments
            )
        )
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    /// Returns transcript entries retained for one session.
    /// - Parameter sessionID: Session identifier.
    /// - Returns: Transcript entries in insertion order.
    public func transcript(for sessionID: String) -> [WebChatTranscriptEntry] {
        self.transcriptBySession[sessionID] ?? []
    }

    /// Returns outbound buffer snapshot for transport integrations/tests.
    public func outboundBufferSnapshot() -> [OutboundMessage] {
        self.outboundBuffer
    }

    private func appendTranscript(_ entry: WebChatTranscriptEntry) {
        var entries = self.transcriptBySession[entry.sessionID] ?? []
        entries.append(entry)
        let limit = max(1, self.config.transcriptLimit)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        self.transcriptBySession[entry.sessionID] = entries
    }

    private func resolveSessionID(from rawSessionID: String) throws -> String {
        let trimmed = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("WebChat session ID is required")
        }
        return trimmed
    }

    private func resolveText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("WebChat message text is required")
        }
        return trimmed
    }

    private func assertSharedSecret(headerSecret: String?, bodySecret: String?) throws {
        let configured = self.config.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !configured.isEmpty else {
            return
        }
        let provided = (headerSecret ?? bodySecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard provided == configured else {
            throw OpenClawCoreError.unavailable("WebChat shared secret validation failed")
        }
    }

    private static func decodeAttachment(_ attachment: WebChatInboundAttachment) -> MediaAttachment? {
        guard let bytes = Data(base64Encoded: attachment.base64Data) else {
            return nil
        }
        let attachmentID = attachment.id.flatMap(UUID.init(uuidString:)) ?? UUID()
        return MediaAttachment(
            id: attachmentID,
            mimeType: attachment.mimeType,
            data: bytes,
            fileName: attachment.fileName,
            metadata: attachment.metadata ?? [:]
        )
    }
}
