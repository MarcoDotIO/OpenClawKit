import Foundation

/// Conversation shape of a channel message (upstream `ChatType` plus `thread`).
public enum ChannelChatType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// One-to-one direct message.
    case direct
    /// Multi-party group chat (for example a Telegram group or an iMessage group).
    case group
    /// Broadcast or workspace channel (for example a Discord guild channel or a Slack channel).
    case channel
    /// Thread or topic inside a group or channel.
    case thread

    /// Whether the conversation has more than two participants.
    public var isGroupLike: Bool {
        self != .direct
    }
}

/// How a channel delivers synthesized speech replies.
public struct ChannelTTSVoiceDelivery: Codable, Sendable, Equatable, Hashable {
    /// Synthesis target the channel expects.
    public enum SynthesisTarget: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        /// Deliver a regular audio file attachment.
        case audioFile = "audio-file"
        /// Deliver a native voice note.
        case voiceNote = "voice-note"
    }

    /// Synthesis target the channel expects.
    public var synthesisTarget: SynthesisTarget
    /// Whether the final text is sent as a caption next to the audio.
    public var captionedFinalText: Bool
    /// Whether the channel transcodes audio itself.
    public var transcodesAudio: Bool
    /// Audio container formats the channel accepts.
    public var audioFileFormats: [String]
    /// Preferred audio file format (upstream only sets `caf`, for iMessage).
    public var preferAudioFileFormat: String?

    /// Creates voice-delivery capabilities.
    /// - Parameters:
    ///   - synthesisTarget: Synthesis target the channel expects.
    ///   - captionedFinalText: Whether final text is sent as a caption.
    ///   - transcodesAudio: Whether the channel transcodes audio itself.
    ///   - audioFileFormats: Accepted audio container formats.
    ///   - preferAudioFileFormat: Preferred audio file format.
    public init(
        synthesisTarget: SynthesisTarget,
        captionedFinalText: Bool = false,
        transcodesAudio: Bool = false,
        audioFileFormats: [String] = [],
        preferAudioFileFormat: String? = nil
    ) {
        self.synthesisTarget = synthesisTarget
        self.captionedFinalText = captionedFinalText
        self.transcodesAudio = transcodesAudio
        self.audioFileFormats = audioFileFormats
        self.preferAudioFileFormat = preferAudioFileFormat
    }
}

/// Typed channel capability flags (upstream `ChannelCapabilities`).
public struct ChannelCapabilities: Codable, Sendable, Equatable, Hashable {
    /// Features a caller may need before delivering an outbound message.
    public enum DeliveryFeature: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        /// Media attachments.
        case media
        /// Native replies to a specific message.
        case reply
        /// Threaded delivery.
        case threads
        /// Native polls.
        case polls
        /// Emoji reactions.
        case reactions
        /// Editing sent messages.
        case edit
        /// Deleting (unsending) sent messages.
        case unsend
    }

    /// Conversation shapes the channel supports.
    public var chatTypes: Set<ChannelChatType>
    /// Native polls.
    public var polls: Bool
    /// Emoji reactions.
    public var reactions: Bool
    /// Editing sent messages.
    public var edit: Bool
    /// Deleting (unsending) sent messages.
    public var unsend: Bool
    /// Native replies to a specific message.
    public var reply: Bool
    /// Send effects (for example iMessage bubble effects).
    public var effects: Bool
    /// Group membership management.
    public var groupManagement: Bool
    /// Threaded conversations.
    public var threads: Bool
    /// Media attachments.
    public var media: Bool
    /// Native slash commands.
    public var nativeCommands: Bool
    /// Block streaming (progressive message delivery).
    public var blockStreaming: Bool
    /// Native polls through the platform's own poll object (upstream `nativePolls`, iMessage).
    public var nativePolls: Bool
    /// Group direct messages with a small recipient set (Slack MPIM, 1-8 recipients).
    public var groupDirectMessages: Bool
    /// Rich message formats (Telegram rich messages, Slack Block Kit, Matrix tables).
    public var richMessages: Bool
    /// Presence-driven triggers (Discord, Slack).
    public var presenceTriggers: Bool
    /// Room join introductions (upstream `joinIntro`).
    public var roomIntroductions: Bool
    /// Typing indicators.
    public var typing: Bool
    /// Voice (TTS) delivery, when supported.
    public var ttsVoice: ChannelTTSVoiceDelivery?

    /// Creates channel capabilities; every flag defaults to `false`.
    /// - Parameters:
    ///   - chatTypes: Supported conversation shapes.
    ///   - polls: Native polls.
    ///   - reactions: Emoji reactions.
    ///   - edit: Editing sent messages.
    ///   - unsend: Deleting sent messages.
    ///   - reply: Native replies.
    ///   - effects: Send effects.
    ///   - groupManagement: Group membership management.
    ///   - threads: Threaded conversations.
    ///   - media: Media attachments.
    ///   - nativeCommands: Native slash commands.
    ///   - blockStreaming: Block streaming.
    ///   - nativePolls: Platform-native poll objects.
    ///   - groupDirectMessages: Group direct messages.
    ///   - richMessages: Rich message formats.
    ///   - presenceTriggers: Presence-driven triggers.
    ///   - roomIntroductions: Room join introductions.
    ///   - typing: Typing indicators.
    ///   - ttsVoice: Voice delivery capabilities.
    public init(
        chatTypes: Set<ChannelChatType> = [],
        polls: Bool = false,
        reactions: Bool = false,
        edit: Bool = false,
        unsend: Bool = false,
        reply: Bool = false,
        effects: Bool = false,
        groupManagement: Bool = false,
        threads: Bool = false,
        media: Bool = false,
        nativeCommands: Bool = false,
        blockStreaming: Bool = false,
        nativePolls: Bool = false,
        groupDirectMessages: Bool = false,
        richMessages: Bool = false,
        presenceTriggers: Bool = false,
        roomIntroductions: Bool = false,
        typing: Bool = false,
        ttsVoice: ChannelTTSVoiceDelivery? = nil
    ) {
        self.chatTypes = chatTypes
        self.polls = polls
        self.reactions = reactions
        self.edit = edit
        self.unsend = unsend
        self.reply = reply
        self.effects = effects
        self.groupManagement = groupManagement
        self.threads = threads
        self.media = media
        self.nativeCommands = nativeCommands
        self.blockStreaming = blockStreaming
        self.nativePolls = nativePolls
        self.groupDirectMessages = groupDirectMessages
        self.richMessages = richMessages
        self.presenceTriggers = presenceTriggers
        self.roomIntroductions = roomIntroductions
        self.typing = typing
        self.ttsVoice = ttsVoice
    }

    /// Whether the channel supports one delivery feature.
    /// - Parameter feature: Feature to check.
    /// - Returns: `true` when the capability flag is set.
    public func supports(_ feature: DeliveryFeature) -> Bool {
        switch feature {
        case .media: self.media
        case .reply: self.reply
        case .threads: self.threads
        case .polls: self.polls
        case .reactions: self.reactions
        case .edit: self.edit
        case .unsend: self.unsend
        }
    }

    /// Returns the delivery features an outbound message needs that this channel lacks.
    ///
    /// Callers check this before sending attachments or native reply/thread targets; unsupported
    /// features should be dropped (or rendered as text) instead of failing the send.
    /// - Parameters:
    ///   - hasAttachments: Whether the message carries media.
    ///   - replyToID: Native reply target, when set.
    ///   - threadID: Native thread target, when set.
    /// - Returns: Missing features in ``DeliveryFeature`` declaration order.
    public func requiredForDelivery(
        hasAttachments: Bool = false,
        replyToID: String? = nil,
        threadID: String? = nil
    ) -> [DeliveryFeature] {
        var missing: [DeliveryFeature] = []
        if hasAttachments, !self.media {
            missing.append(.media)
        }
        if replyToID != nil, !self.reply, !self.threads {
            missing.append(.reply)
        }
        if threadID != nil, !self.threads {
            missing.append(.threads)
        }
        return missing
    }
}

/// Unit used to measure a channel's text chunk limit.
public enum ChannelTextChunkUnit: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Extended grapheme clusters (Swift `Character`s).
    case chars
    /// UTF-16 code units (JavaScript string length; iMessage and Teams limits).
    case utf16
    /// UTF-8 bytes (Google Chat).
    case bytes
}

/// Markdown construct tracked by a channel's format profile.
public enum ChannelFormatConstruct: String, Codable, CodingKeyRepresentable, Sendable, Equatable, Hashable, CaseIterable {
    /// Bold text.
    case bold
    /// Italic text.
    case italic
    /// Underlined text.
    case underline
    /// Strikethrough text.
    case strikethrough
    /// Spoiler text.
    case spoiler
    /// Inline code.
    case codeInline
    /// Fenced code block.
    case codeBlock
    /// Code block language hints.
    case codeLanguage
    /// Labelled links.
    case linkLabel
    /// Headings.
    case heading
    /// Bulleted lists.
    case bulletList
    /// Ordered lists.
    case orderedList
    /// Task lists.
    case taskList
    /// Tables.
    case table
    /// Block quotes.
    case blockquote
    /// Inline images.
    case image
    /// User mentions.
    case mention
}

/// How a channel renders one markdown construct.
public enum ChannelFormatConstructSupport: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Rendered natively.
    case native
    /// Rendered through a textual fallback.
    case fallback
    /// Stripped from the output.
    case strip
}

/// Rich-text format profile for a channel (upstream `FormatCapabilityProfile`).
public struct ChannelFormatProfile: Codable, Sendable, Equatable, Hashable {
    /// Formatting mechanism the channel uses.
    public enum Mechanism: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        /// Markdown dialect.
        case markdown
        /// HTML subset.
        case html
        /// Styled ranges over plain text (Signal, iMessage).
        case ranges
        /// Structured blocks (Telegram rich messages, Slack Block Kit).
        case blocks
        /// Plain text only.
        case plain
    }

    /// Formatting mechanism.
    public var mechanism: Mechanism
    /// Chunk limit for formatted text.
    public var chunkLimit: Int
    /// Unit the chunk limit is measured in.
    public var chunkUnit: ChannelTextChunkUnit
    /// Absolute platform cap, when larger than the chunk limit.
    public var hardCap: Int?
    /// Per-construct support; constructs that are absent render natively.
    public var constructs: [ChannelFormatConstruct: ChannelFormatConstructSupport]

    /// Creates a format profile.
    /// - Parameters:
    ///   - mechanism: Formatting mechanism.
    ///   - chunkLimit: Chunk limit for formatted text.
    ///   - chunkUnit: Unit for the chunk limit.
    ///   - hardCap: Absolute platform cap.
    ///   - constructs: Per-construct support overrides.
    public init(
        mechanism: Mechanism,
        chunkLimit: Int,
        chunkUnit: ChannelTextChunkUnit = .chars,
        hardCap: Int? = nil,
        constructs: [ChannelFormatConstruct: ChannelFormatConstructSupport] = [:]
    ) {
        self.mechanism = mechanism
        self.chunkLimit = max(1, chunkLimit)
        self.chunkUnit = chunkUnit
        self.hardCap = hardCap
        self.constructs = constructs
    }

    /// Returns how one construct renders (default ``ChannelFormatConstructSupport/native``).
    /// - Parameter construct: Markdown construct.
    /// - Returns: Construct support level.
    public func support(for construct: ChannelFormatConstruct) -> ChannelFormatConstructSupport {
        self.constructs[construct] ?? .native
    }
}

/// Default block-streaming coalescing thresholds for a channel.
public struct ChannelBlockStreamingCoalesceDefaults: Codable, Sendable, Equatable, Hashable {
    /// Minimum characters buffered before a block is flushed.
    public var minChars: Int
    /// Idle time in milliseconds after which a partial block is flushed.
    public var idleMs: Int

    /// Creates coalescing defaults.
    /// - Parameters:
    ///   - minChars: Minimum characters per flushed block.
    ///   - idleMs: Idle flush timeout in milliseconds.
    public init(minChars: Int, idleMs: Int) {
        self.minChars = max(0, minChars)
        self.idleMs = max(0, idleMs)
    }
}

/// Outbound text chunking defaults for a channel.
public struct ChannelTextChunkingDefaults: Codable, Sendable, Equatable, Hashable {
    /// Default chunk limit when config does not set `textChunkLimit`.
    public var defaultLimit: Int
    /// Unit the limits are measured in.
    public var unit: ChannelTextChunkUnit
    /// Platform hard limit; configured limits are clamped to it.
    public var platformLimit: Int?
    /// Soft cap on lines per message (Discord: 17).
    public var maxLines: Int?
    /// Chunk limit used when rich messages are enabled (Telegram: 32768).
    public var richMessagesLimit: Int?

    /// Creates chunking defaults.
    /// - Parameters:
    ///   - defaultLimit: Default chunk limit.
    ///   - unit: Measurement unit.
    ///   - platformLimit: Platform hard limit.
    ///   - maxLines: Soft line cap per message.
    ///   - richMessagesLimit: Chunk limit with rich messages enabled.
    public init(
        defaultLimit: Int,
        unit: ChannelTextChunkUnit = .chars,
        platformLimit: Int? = nil,
        maxLines: Int? = nil,
        richMessagesLimit: Int? = nil
    ) {
        self.defaultLimit = max(1, defaultLimit)
        self.unit = unit
        self.platformLimit = platformLimit
        self.maxLines = maxLines
        self.richMessagesLimit = richMessagesLimit
    }

    /// Resolves the effective chunk limit for a configured value.
    ///
    /// Mirrors upstream `min(config textChunkLimit ?? default, platform limit)`.
    /// - Parameters:
    ///   - configured: Configured `textChunkLimit`, when set.
    ///   - richMessages: Whether rich messages are enabled.
    /// - Returns: Effective limit, at least 1.
    public func effectiveLimit(configured: Int? = nil, richMessages: Bool = false) -> Int {
        let base = richMessages ? (self.richMessagesLimit ?? self.defaultLimit) : self.defaultLimit
        var limit = configured.flatMap { $0 > 0 ? $0 : nil } ?? base
        let cap = richMessages ? (self.richMessagesLimit ?? self.platformLimit) : self.platformLimit
        if let cap {
            limit = min(limit, cap)
        }
        return max(1, limit)
    }
}
