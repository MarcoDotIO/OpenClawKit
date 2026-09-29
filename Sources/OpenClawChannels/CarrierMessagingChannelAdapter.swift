#if canImport(TelephonyMessagingKit) && os(iOS)
import Foundation
import OpenClawCore
import OpenClawProtocol
import TelephonyMessagingKit
import UniformTypeIdentifiers

/// On-device carrier SMS/MMS/RCS channel backed by TelephonyMessagingKit (iOS 26+).
///
/// Select it with `channels.sms.transport: "carrier"` and create it explicitly; it is never
/// enabled automatically. Requirements (controlled by Apple, the carrier and the user):
/// - the app must be the user's default carrier messaging app
///   (`TelephonyMessagingSession.shared.isConfiguredForCarrierMessaging`), which needs Apple's
///   carrier messaging entitlement and is limited to supported regions and carriers;
/// - a viable cellular service (SIM/eSIM) for SMS.
///
/// Inbound SMS, MMS (iOS 26.1+) and RCS messages become ``InboundMessage`` values (RCS groups
/// map to ``ChannelChatType/group``) and pass through the channel access policy (pairing by
/// default) like any other channel. Outbound text is rendered as plain text and chunked at
/// `textChunkLimit`; RCS is preferred when the recipient's remote capabilities report chat
/// support. On iOS 27 RCS threaded replies (`replyToID`) and emoji reactions are used when the
/// recipient supports extended messaging. The RCS composing indicator reports typing.
@available(iOS 26.0, *)
public actor CarrierMessagingChannelAdapter: InboundChannelAdapter, ReceiptingChannelAdapter, ChannelMessageActions {
    /// Adapter channel identifier.
    public let id: ChannelID = .sms

    private let config: SMSChannelConfig
    private let preferRCS: Bool
    private var cellularServiceID: CellularServiceID?
    private var inboundHandler: InboundMessageHandler?
    private var tasks: [Task<Void, Never>] = []
    private var nextSMSMessageID = UInt32.random(in: 1...UInt32.max / 2)
    private var rcsGroupHandles: [String: RCSHandle] = [:]
    private var started = false

    /// Creates a carrier messaging adapter.
    /// - Parameters:
    ///   - config: `channels.sms` settings (`transport` should be `carrier`).
    ///   - preferRCS: Prefer RCS when the recipient supports it (default `true`).
    public init(config: SMSChannelConfig, preferRCS: Bool = true) {
        self.config = config
        self.preferRCS = preferRCS
    }

    /// Whether this app is the user's carrier messaging app.
    nonisolated public static var isConfiguredForCarrierMessaging: Bool {
        TelephonyMessagingSession.shared.isConfiguredForCarrierMessaging
    }

    /// RCS typing is reported through the composing indicator.
    nonisolated public var supportsTypingIndicator: Bool {
        self.preferRCS
    }

    /// Reactions are available on iOS 27 for RCS recipients with extended messaging.
    nonisolated public var supportedMessageActions: Set<ChannelMessageActionName> {
        if #available(iOS 27.0, *) {
            return [.react]
        }
        return []
    }

    /// Registers or clears the inbound callback.
    /// - Parameter handler: Inbound handler.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Selects a viable cellular service and starts listening for SMS, MMS and RCS messages.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("SMS channel is disabled")
        }
        guard !self.started else { return }
        let session = TelephonyMessagingSession.shared
        guard session.isConfiguredForCarrierMessaging else {
            throw OpenClawCoreError.unavailable("This app is not configured as the carrier messaging app")
        }
        let services = try session.cellularServices
        guard let service = services.first(where: { session.smsService.isViable(for: $0.id) }) else {
            throw OpenClawCoreError.unavailable("No cellular service is currently viable for SMS")
        }
        self.cellularServiceID = service.id
        self.started = true
        self.startListening(session: session)
    }

    /// Stops listening.
    public func stop() async {
        self.started = false
        for task in self.tasks {
            task.cancel()
        }
        self.tasks.removeAll()
    }

    // MARK: Inbound

    private func startListening(session: TelephonyMessagingSession) {
        let sms = session.smsService
        let mms = session.mmsService
        let rcs = session.rcsService
        self.tasks.append(Task { [weak self] in
            guard let notifications = try? sms.incomingMessageNotifications else { return }
            for await notification in notifications {
                await self?.handleSMS(notification.message)
            }
        })
        if #available(iOS 26.1, *) {
            self.tasks.append(Task { [weak self] in
                guard let notifications = try? mms.incomingMessageNotifications else { return }
                for await notification in notifications {
                    await self?.handleMMS(notification.message)
                }
            })
        }
        self.tasks.append(Task { [weak self] in
            guard let notifications = try? rcs.incomingMessageNotifications else { return }
            for await notification in notifications {
                await self?.handleRCS(notification.message, groupContext: notification.groupContext)
            }
        })
        self.tasks.append(Task { [weak self] in
            for await state in session.cellularServiceStateUpdates {
                await self?.refreshCellularService(preferred: state.id)
            }
        })
    }

    private func refreshCellularService(preferred: CellularServiceID) {
        let sms = TelephonyMessagingSession.shared.smsService
        if let current = self.cellularServiceID, sms.isViable(for: current) {
            return
        }
        if sms.isViable(for: preferred) {
            self.cellularServiceID = preferred
        }
    }

    private func handleSMS(_ message: SMSMessage) async {
        let sender = TwilioSMS.normalizePhoneNumber(message.handle.phoneNumber)
        await self.dispatch(
            peerID: sender,
            senderID: sender,
            text: message.content.body,
            messageID: "sms:\(message.messageID.rawValue)",
            chatType: .direct,
            metadata: ["carrierService": "sms"]
        )
    }

    @available(iOS 26.1, *)
    private func handleMMS(_ message: MMSMessage) async {
        let content = message.content
        guard let sender = content.from.map({ TwilioSMS.normalizePhoneNumber($0.phoneNumber) }) else { return }
        var texts: [String] = []
        var attachments: [MediaAttachment] = []
        for part in content.parts {
            if let type = part.contentType, type.conforms(to: .plainText) || type.conforms(to: .text) {
                texts.append(String(decoding: part.data, as: UTF8.self))
            } else if part.contentType?.identifier != "application/smil" {
                attachments.append(MediaAttachment(
                    mimeType: part.contentType?.preferredMIMEType ?? "application/octet-stream",
                    data: part.data,
                    fileName: part.filename.isEmpty ? nil : part.filename,
                    metadata: ["source": "carrier-mms"]
                ))
            }
        }
        let isGroup = content.recipients.count > 1
        await self.dispatch(
            peerID: sender,
            senderID: sender,
            text: ([content.subject].compactMap { $0 } + texts).joined(separator: "\n"),
            attachments: attachments,
            messageID: "mms:\(message.messageID.rawValue)",
            chatType: isGroup ? .group : .direct,
            metadata: ["carrierService": "mms"]
        )
    }

    private func handleRCS(_ message: RCSMessage, groupContext: RCSGroupContext?) async {
        var text: String?
        var replyToID: String?
        switch message.content {
        case .text(let body):
            text = body.body
        default:
            if #available(iOS 27.0, *), case .reply(let reply) = message.content, case .text(let body) = reply.content {
                text = body.body
                replyToID = reply.targetMessageID.rawValue
            }
        }
        guard let text else { return }
        let sender = Self.phoneNumber(from: message.handle)
        var peerID = sender
        var chatType = ChannelChatType.direct
        if let groupContext {
            peerID = "rcs-group:\(groupContext.handle.conversationID)"
            chatType = .group
            self.rcsGroupHandles[peerID] = .group(groupContext.handle)
        }
        await self.dispatch(
            peerID: peerID,
            senderID: sender,
            text: text,
            messageID: message.id.rawValue,
            replyToID: replyToID,
            chatType: chatType,
            metadata: ["carrierService": "rcs"]
        )
    }

    private func dispatch(
        peerID: String,
        senderID: String,
        text: String,
        attachments: [MediaAttachment] = [],
        messageID: String,
        replyToID: String? = nil,
        chatType: ChannelChatType,
        metadata: [String: String]
    ) async {
        guard self.started, !peerID.isEmpty else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let inbound = InboundMessage(
            channel: .sms,
            peerID: peerID,
            text: text,
            attachments: attachments,
            senderID: senderID,
            chatType: chatType,
            messageID: messageID,
            replyToID: replyToID,
            metadata: metadata,
            legacyRoutingAccountID: senderID
        )
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    // MARK: Outbound

    /// Sends text over RCS (when supported) or SMS.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        _ = try await self.sendReturningReceipt(message)
    }

    /// Sends plain-text chunks and returns their message ids.
    /// - Parameter message: Outbound payload.
    /// - Returns: Receipt.
    public func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt {
        guard self.started, let serviceID = self.cellularServiceID else {
            throw OpenClawCoreError.unavailable("Carrier messaging adapter is not started")
        }
        let chunks = ChannelTextChunker.chunk(TwilioSMS.renderPlainText(message.text), limit: self.config.textChunkLimit)
        guard !chunks.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("SMS outbound text is required")
        }
        let rcsHandle = await self.rcsHandleIfSupported(peerID: message.peerID, serviceID: serviceID)
        let parts = try await ChannelMultipartDelivery().run(count: chunks.count) { index in
            let chunk = chunks[index]
            if let rcsHandle {
                let messageID = RCSMessageID(rawValue: UUID().uuidString)
                try await self.sendRCS(chunk, to: rcsHandle, serviceID: serviceID, messageID: messageID, replyToID: index == 0 ? message.replyToID : nil)
                return [ChannelSendReceipt.Part(platformMessageID: messageID.rawValue, index: index)]
            } else {
                let phone = TwilioSMS.normalizePhoneNumber(message.peerID)
                guard TwilioSMS.looksLikePhoneNumber(phone) else {
                    throw ChannelSendError.rejected(status: 0, detail: "SMS recipient must be an E.164 phone number")
                }
                self.nextSMSMessageID &+= 1
                let smsID = SMSMessageID(rawValue: self.nextSMSMessageID)
                let sms = SMSMessage(cellularServiceID: serviceID, handle: SMSHandle(phoneNumber: phone), messageID: smsID, content: SMSContent(body: chunk))
                try await TelephonyMessagingSession.shared.smsService.sendMessage(sms)
                return [ChannelSendReceipt.Part(platformMessageID: "sms:\(smsID.rawValue)", index: index)]
            }
        }
        return ChannelSendReceipt(parts: parts)
    }

    private func sendRCS(_ text: String, to handle: RCSHandle, serviceID: CellularServiceID, messageID: RCSMessageID, replyToID: String?) async throws {
        let rcs = TelephonyMessagingSession.shared.rcsService
        if #available(iOS 27.0, *), let replyToID, let capabilities = await self.capabilities(for: handle, serviceID: serviceID),
           capabilities.supportsExtendedMessagingReply
        {
            let reply = RCSMessage.Reply(targetMessageID: RCSMessageID(rawValue: replyToID), content: .text(RCSMessage.Text(body: text)))
            try await rcs.sendMessage(reply, to: handle, using: serviceID, messageID: messageID)
            return
        }
        try await rcs.sendMessage(RCSMessage.Text(body: text), to: handle, using: serviceID, messageID: messageID)
    }

    /// Sends the RCS composing indicator (active).
    /// - Parameters:
    ///   - accountID: Unused.
    ///   - peerID: Recipient.
    public func sendTypingIndicator(accountID _: String?, peerID: String) async throws {
        try await self.sendComposing(.active, peerID: peerID)
    }

    /// Sends the RCS composing indicator (idle).
    /// - Parameters:
    ///   - accountID: Unused.
    ///   - peerID: Recipient.
    public func stopTypingIndicator(accountID _: String?, peerID: String) async throws {
        try await self.sendComposing(.idle, peerID: peerID)
    }

    private func sendComposing(_ state: RCSMessage.ComposingIndicator.State, peerID: String) async throws {
        guard self.started, let serviceID = self.cellularServiceID,
              let handle = await self.rcsHandleIfSupported(peerID: peerID, serviceID: serviceID)
        else { return }
        let indicator = RCSMessage.ComposingIndicator(state: state)
        try? await TelephonyMessagingSession.shared.rcsService.sendMessage(
            indicator,
            to: handle,
            using: serviceID,
            messageID: RCSMessageID(rawValue: UUID().uuidString)
        )
    }

    /// Adds or removes an RCS emoji reaction (iOS 27, recipients with extended messaging).
    /// - Parameters:
    ///   - peerID: Conversation.
    ///   - messageID: Target RCS message id.
    ///   - emoji: Emoji.
    ///   - remove: Remove instead of add.
    public func react(peerID: String, messageID: String, emoji: String, remove: Bool) async throws {
        guard #available(iOS 27.0, *) else {
            throw ChannelMessageActionError.unsupported(action: "react", channel: .sms)
        }
        guard self.started, let serviceID = self.cellularServiceID,
              let handle = await self.rcsHandleIfSupported(peerID: peerID, serviceID: serviceID),
              let capabilities = await self.capabilities(for: handle, serviceID: serviceID),
              capabilities.supportsExtendedMessagingReaction
        else {
            throw ChannelMessageActionError.unsupported(action: "react", channel: .sms)
        }
        let reaction = RCSMessage.Reaction(
            targetMessageID: RCSMessageID(rawValue: messageID),
            operation: remove ? .removeEmoji(emoji) : .addEmoji(emoji)
        )
        try await TelephonyMessagingSession.shared.rcsService.sendMessage(
            reaction,
            to: handle,
            using: serviceID,
            messageID: RCSMessageID(rawValue: UUID().uuidString)
        )
    }

    // MARK: Helpers

    private func rcsHandleIfSupported(peerID: String, serviceID: CellularServiceID) async -> RCSHandle? {
        guard self.preferRCS else { return nil }
        if let group = self.rcsGroupHandles[peerID] {
            return group
        }
        let rcs = TelephonyMessagingSession.shared.rcsService
        guard rcs.isViable(for: serviceID), let handle = RCSHandle.phoneNumber(TwilioSMS.normalizePhoneNumber(peerID)) else {
            return nil
        }
        guard let capabilities = await self.capabilities(for: handle, serviceID: serviceID), capabilities.supportsChat,
              capabilities.availability != .unavailable
        else {
            return nil
        }
        return handle
    }

    private func capabilities(for handle: RCSHandle, serviceID: CellularServiceID) async -> RCSService.RemoteCapabilities? {
        let request = RCSService.RemoteCapabilitiesRequest(cellularServiceID: serviceID, handle: handle, cachePolicy: .cacheOrRemote)
        return try? await TelephonyMessagingSession.shared.rcsService.remoteCapabilities(for: request)
    }

    private static func phoneNumber(from handle: RCSHandle) -> String {
        guard case .uri(let uri) = handle else { return handle.description }
        var raw = uri.rawValue
        for prefix in ["tel:", "sip:"] where raw.lowercased().hasPrefix(prefix) {
            raw = String(raw.dropFirst(prefix.count))
        }
        if let at = raw.firstIndex(of: "@") {
            raw = String(raw[..<at])
        }
        if let semicolon = raw.firstIndex(of: ";") {
            raw = String(raw[..<semicolon])
        }
        let phone = TwilioSMS.normalizePhoneNumber(raw)
        return TwilioSMS.looksLikePhoneNumber(phone) ? phone : uri.rawValue
    }
}
#endif
