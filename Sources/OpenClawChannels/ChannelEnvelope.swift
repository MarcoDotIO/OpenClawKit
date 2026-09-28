import Foundation
import OpenClawCore
import OpenClawProtocol

/// Kind of inbound event (upstream `InboundEventKind`).
public enum InboundEventKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// A message addressed to the agent that expects a reply.
    case userRequest = "user_request"
    /// Ambient room traffic that the agent may observe without posting a reply.
    case roomEvent = "room_event"
}

/// Why a message counts as a mention without an explicit `@mention` (upstream `InboundImplicitMentionKind`).
public enum ChannelImplicitMentionKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// The message replies to a bot message.
    case replyToBot = "reply_to_bot"
    /// The message quotes a bot message.
    case quotedBot = "quoted_bot"
    /// The message is in a thread the bot participates in.
    case botThreadParticipant = "bot_thread_participant"
    /// The platform flagged the message as addressing the bot.
    case native
}

/// Normalized inbound message envelope delivered to the runtime.
///
/// - Important: 2026.3.0 aligned ``accountID`` with upstream `accountId`: it is the *channel
///   account key* (for example the configured bot account; `nil` means the default account), not
///   the human sender. The sender moved to ``senderID``. See
///   ``ChannelsCompatibilityConfig/legacySessionAccountKeys`` to keep pre-2026.3.0 session keys.
public struct InboundMessage: Sendable, Equatable {
    /// Source channel identifier.
    public var channel: ChannelID
    /// Channel account key (upstream `accountId`); `nil` means the default account.
    public var accountID: String?
    /// Conversation peer/channel identifier.
    public var peerID: String
    /// Message content.
    public var text: String
    /// Multimodal attachments.
    public var attachments: [MediaAttachment]
    /// Platform id of the human (or bot) sender.
    public var senderID: String?
    /// Display name of the sender.
    public var senderName: String?
    /// Conversation shape.
    public var chatType: ChannelChatType
    /// Platform message id.
    public var messageID: String?
    /// Platform thread/topic id.
    public var threadID: String?
    /// Platform id of the message this message replies to.
    public var replyToID: String?
    /// Whether the message explicitly mentions the bot; `nil` when the adapter cannot detect mentions.
    public var wasMentioned: Bool?
    /// Implicit mention signals detected by the adapter.
    public var implicitMentionKinds: Set<ChannelImplicitMentionKind>
    /// Whether the sender is a bot.
    public var isFromBot: Bool
    /// Platform id of the receiving bot account (used by the bot-loop guard).
    public var recipientID: String?
    /// Event kind.
    public var eventKind: InboundEventKind
    /// Time the adapter received the message.
    public var receivedAt: Date
    /// Adapter-specific metadata.
    public var metadata: [String: String]
    /// The value 2026.2 adapters stored in `accountID`, used only for legacy session keys.
    public var legacyRoutingAccountID: String?

    /// Creates an inbound message envelope.
    /// - Parameters:
    ///   - channel: Source channel identifier.
    ///   - accountID: Channel account key (`nil` = default account).
    ///   - peerID: Conversation peer/channel identifier.
    ///   - text: Message content.
    ///   - attachments: Optional multimodal attachments.
    ///   - senderID: Platform sender id.
    ///   - senderName: Sender display name.
    ///   - chatType: Conversation shape.
    ///   - messageID: Platform message id.
    ///   - threadID: Platform thread id.
    ///   - replyToID: Id of the replied-to message.
    ///   - wasMentioned: Whether the bot was mentioned (`nil` = unknown).
    ///   - implicitMentionKinds: Implicit mention signals.
    ///   - isFromBot: Whether the sender is a bot.
    ///   - recipientID: Receiving bot account id.
    ///   - eventKind: Event kind.
    ///   - receivedAt: Receive time.
    ///   - metadata: Adapter-specific metadata.
    ///   - legacyRoutingAccountID: Pre-2026.3.0 `accountID` value for legacy session keys.
    public init(
        channel: ChannelID,
        accountID: String? = nil,
        peerID: String,
        text: String,
        attachments: [MediaAttachment] = [],
        senderID: String? = nil,
        senderName: String? = nil,
        chatType: ChannelChatType = .direct,
        messageID: String? = nil,
        threadID: String? = nil,
        replyToID: String? = nil,
        wasMentioned: Bool? = nil,
        implicitMentionKinds: Set<ChannelImplicitMentionKind> = [],
        isFromBot: Bool = false,
        recipientID: String? = nil,
        eventKind: InboundEventKind = .userRequest,
        receivedAt: Date = Date(),
        metadata: [String: String] = [:],
        legacyRoutingAccountID: String? = nil
    ) {
        self.channel = channel
        self.accountID = accountID
        self.peerID = peerID
        self.text = text
        self.attachments = attachments
        self.senderID = senderID
        self.senderName = senderName
        self.chatType = chatType
        self.messageID = messageID
        self.threadID = threadID
        self.replyToID = replyToID
        self.wasMentioned = wasMentioned
        self.implicitMentionKinds = implicitMentionKinds
        self.isFromBot = isFromBot
        self.recipientID = recipientID
        self.eventKind = eventKind
        self.receivedAt = receivedAt
        self.metadata = metadata
        self.legacyRoutingAccountID = legacyRoutingAccountID
    }

    /// Compares envelopes by content; ``receivedAt`` is ignored so envelopes built at different
    /// times (for example in tests or dedupe checks) compare equal when their content matches.
    /// - Parameters:
    ///   - lhs: Left envelope.
    ///   - rhs: Right envelope.
    /// - Returns: `true` when every field except `receivedAt` matches.
    public static func == (lhs: InboundMessage, rhs: InboundMessage) -> Bool {
        lhs.channel == rhs.channel
            && lhs.accountID == rhs.accountID
            && lhs.peerID == rhs.peerID
            && lhs.text == rhs.text
            && lhs.attachments == rhs.attachments
            && lhs.senderID == rhs.senderID
            && lhs.senderName == rhs.senderName
            && lhs.chatType == rhs.chatType
            && lhs.messageID == rhs.messageID
            && lhs.threadID == rhs.threadID
            && lhs.replyToID == rhs.replyToID
            && lhs.wasMentioned == rhs.wasMentioned
            && lhs.implicitMentionKinds == rhs.implicitMentionKinds
            && lhs.isFromBot == rhs.isFromBot
            && lhs.recipientID == rhs.recipientID
            && lhs.eventKind == rhs.eventKind
            && lhs.metadata == rhs.metadata
            && lhs.legacyRoutingAccountID == rhs.legacyRoutingAccountID
    }

    /// Whether the message is a one-to-one direct message.
    public var isDirect: Bool {
        self.chatType == .direct
    }

    /// Account key with the upstream default (`"default"` when ``accountID`` is `nil`).
    public var resolvedAccountID: String {
        let trimmed = self.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "default" : trimmed
    }

    /// Builds a reply envelope addressed to this message's conversation.
    /// - Parameters:
    ///   - text: Reply text.
    ///   - replyNatively: Whether to set ``OutboundMessage/replyToID`` to this message's id.
    /// - Returns: Outbound envelope.
    public func reply(text: String, replyNatively: Bool = false) -> OutboundMessage {
        OutboundMessage(
            channel: self.channel,
            accountID: self.accountID,
            peerID: self.peerID,
            text: text,
            replyToID: replyNatively ? self.messageID : nil,
            threadID: self.threadID,
            chatType: self.chatType
        )
    }
}

/// Normalized outbound message envelope sent through adapters.
public struct OutboundMessage: Sendable, Equatable {
    /// Destination channel identifier.
    public var channel: ChannelID
    /// Channel account key (`nil` = default account).
    public var accountID: String?
    /// Conversation peer/channel identifier.
    public var peerID: String
    /// Message content.
    public var text: String
    /// Multimodal attachments.
    public var attachments: [MediaAttachment]
    /// Platform message id to reply to natively.
    public var replyToID: String?
    /// Platform thread/topic id to post into.
    public var threadID: String?
    /// Deliver without a notification where the platform supports it.
    public var silent: Bool
    /// Conversation shape, when known.
    public var chatType: ChannelChatType?

    /// Creates an outbound message envelope.
    /// - Parameters:
    ///   - channel: Destination channel identifier.
    ///   - accountID: Channel account key (`nil` = default account).
    ///   - peerID: Conversation peer/channel identifier.
    ///   - text: Message content.
    ///   - attachments: Optional multimodal attachments.
    ///   - replyToID: Message id to reply to natively.
    ///   - threadID: Thread id to post into.
    ///   - silent: Deliver without a notification.
    ///   - chatType: Conversation shape.
    public init(
        channel: ChannelID,
        accountID: String? = nil,
        peerID: String,
        text: String,
        attachments: [MediaAttachment] = [],
        replyToID: String? = nil,
        threadID: String? = nil,
        silent: Bool = false,
        chatType: ChannelChatType? = nil
    ) {
        self.channel = channel
        self.accountID = accountID
        self.peerID = peerID
        self.text = text
        self.attachments = attachments
        self.replyToID = replyToID
        self.threadID = threadID
        self.silent = silent
        self.chatType = chatType
    }
}

/// Session-key routing for channel messages, including the 2026.3.0 compatibility switch.
public enum ChannelSessionRouting {
    /// Account dimension used for session routing.
    ///
    /// Sessions route by the channel account key. The default account (`accountID == nil`)
    /// contributes no account segment, so hosts that never set `accountID` keep their pre-2026.3.0
    /// session keys. Built-in adapters used to put the *sender* into `accountID`; with
    /// ``ChannelsCompatibilityConfig/legacySessionAccountKeys`` that pre-2026.3.0 value
    /// (``InboundMessage/legacyRoutingAccountID``) is used instead, so their session keys and
    /// conversation memory do not fork after upgrading.
    /// - Parameters:
    ///   - message: Inbound message.
    ///   - compatibility: Compatibility switches.
    /// - Returns: Account routing dimension (`nil` for the default account).
    public static func routingAccountID(
        for message: InboundMessage,
        compatibility: ChannelsCompatibilityConfig
    ) -> String? {
        if compatibility.legacySessionAccountKeys {
            return message.legacyRoutingAccountID ?? message.accountID
        }
        let trimmed = message.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Routing context for a message.
    /// - Parameters:
    ///   - message: Inbound message.
    ///   - config: Runtime configuration.
    /// - Returns: Session routing context.
    public static func routingContext(for message: InboundMessage, config: OpenClawConfig) -> SessionRoutingContext {
        SessionRoutingContext(
            channel: message.channel.rawValue,
            accountID: self.routingAccountID(for: message, compatibility: config.channels.compatibility),
            peerID: message.peerID
        )
    }

    /// Session key for a message.
    /// - Parameters:
    ///   - message: Inbound message.
    ///   - config: Runtime configuration.
    /// - Returns: Resolved session key.
    public static func sessionKey(for message: InboundMessage, config: OpenClawConfig) -> String {
        SessionKeyResolver.resolve(explicit: nil, context: self.routingContext(for: message, config: config), config: config)
    }
}
