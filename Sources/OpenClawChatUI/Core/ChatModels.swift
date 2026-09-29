import Foundation
import OpenClawProtocol

// NOTE: keep this file lightweight; decode must be resilient to varying transcript formats.
// Ported from upstream OpenClaw 2026.9.6 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatModels.swift`.
// UI-only types (`OpenClawPlatformImage`, `OpenClawPendingAttachment`) live in `ChatPendingAttachment.swift`.

/// Slash-command picker filter.
public enum OpenClawChatCommandFilter: String, CaseIterable, Sendable {
    /// Every command source.
    case all = "All"
    /// Native and plugin commands.
    case commands = "Commands"
    /// Skill commands only.
    case skills = "Skills"
}

/// One slash command offered by `commands.list`.
public struct OpenClawChatCommandChoice: Identifiable, Hashable, Sendable {
    /// Where a command comes from.
    public enum Source: String, Sendable {
        /// A gateway-native command.
        case command
        /// A skill command.
        case skill
        /// A plugin command.
        case plugin
        /// An unrecognized source.
        case unknown
    }

    /// Stable picker identity (`source:name:alias`).
    public let id: String
    /// Command name without the leading slash.
    public let name: String
    /// Text aliases such as `/new`.
    public let textAliases: [String]
    /// Human-readable description.
    public let description: String
    /// Command source.
    public let source: Source
    /// Whether the command accepts arguments.
    public let acceptsArgs: Bool

    /// Creates a command choice.
    public init(
        id: String,
        name: String,
        textAliases: [String],
        description: String,
        source: Source,
        acceptsArgs: Bool)
    {
        self.id = id
        self.name = name
        self.textAliases = textAliases
        self.description = description
        self.source = source
        self.acceptsArgs = acceptsArgs
    }

    /// Invocation inserted into the composer (first slash alias, else `/name`).
    public var preferredInvocation: String {
        self.textAliases.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") }
            ?? "/\(self.name)"
    }

    /// Trimmed invocation for display.
    public var displayInvocation: String {
        self.preferredInvocation.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Cost breakdown attached to assistant usage.
public struct OpenClawChatUsageCost: Codable, Hashable, Sendable {
    /// Input cost.
    public let input: Double?
    /// Output cost.
    public let output: Double?
    /// Cache-read cost.
    public let cacheRead: Double?
    /// Cache-write cost.
    public let cacheWrite: Double?
    /// Total cost.
    public let total: Double?
}

/// Token usage attached to assistant messages.
public struct OpenClawChatUsage: Codable, Hashable, Sendable {
    /// Input tokens.
    public let input: Int?
    /// Output tokens.
    public let output: Int?
    /// Cache-read tokens.
    public let cacheRead: Int?
    /// Cache-write tokens.
    public let cacheWrite: Int?
    /// Cost breakdown.
    public let cost: OpenClawChatUsageCost?
    /// Total tokens (`total` or `totalTokens`).
    public let total: Int?

    enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead
        case cacheWrite
        case cost
        case total
        case totalTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.input = try container.decodeIfPresent(Int.self, forKey: .input)
        self.output = try container.decodeIfPresent(Int.self, forKey: .output)
        self.cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheRead)
        self.cacheWrite = try container.decodeIfPresent(Int.self, forKey: .cacheWrite)
        self.cost = try container.decodeIfPresent(OpenClawChatUsageCost.self, forKey: .cost)
        self.total =
            try container.decodeIfPresent(Int.self, forKey: .total) ??
            container.decodeIfPresent(Int.self, forKey: .totalTokens)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.input, forKey: .input)
        try container.encodeIfPresent(self.output, forKey: .output)
        try container.encodeIfPresent(self.cacheRead, forKey: .cacheRead)
        try container.encodeIfPresent(self.cacheWrite, forKey: .cacheWrite)
        try container.encodeIfPresent(self.cost, forKey: .cost)
        try container.encodeIfPresent(self.total, forKey: .total)
    }
}

/// How gateway media should be played back.
public enum OpenClawChatPlaybackMode: String, Codable, Hashable, Sendable {
    /// Play the original bytes.
    case native
    /// The gateway transcodes before playback.
    case transcode
}

/// One content block of a transcript message (text, thinking, media, tool call, or tool result).
public struct OpenClawChatMessageContent: Codable, Hashable, Sendable {
    /// Block type (`text`, `thinking`, `image`, `toolCall`, `toolResult`, ...).
    public let type: String?
    /// Text payload.
    public let text: String?
    /// Opaque provider signature for the text block (carries response phase metadata).
    public let textSignature: String?
    /// Thinking text.
    public let thinking: String?
    /// Opaque provider signature for the thinking block.
    public let thinkingSignature: String?
    /// Media MIME type.
    public let mimeType: String?
    /// Attachment file name.
    public let fileName: String?
    /// Gateway-managed artifact identifier.
    public let artifactId: String?
    /// Media URL.
    public let url: String?
    /// URL opened when the user taps the media.
    public let openUrl: String?
    /// Accessibility text.
    public let alt: String?
    /// Media width in pixels.
    public let width: Int?
    /// Media height in pixels.
    public let height: Int?
    /// Media byte size.
    public let sizeBytes: Int?
    /// Media duration in seconds (decoded from `durationSeconds` or `durationMs`).
    public let durationSeconds: Double?
    /// Playback mode for audio/video.
    public let playback: OpenClawChatPlaybackMode?
    /// Raw content payload (base64 attachment bytes or nested blocks).
    public let content: AnyCodable?
    /// Inline canvas preview metadata.
    public let preview: OpenClawChatCanvasPreview?

    // Tool-call fields (when `type == "toolCall"` or similar)
    /// Run that produced this tool block.
    public let runId: String?
    /// Tool call identifier (`id`, `toolCallId`, `tool_call_id`, `toolUseId`, `tool_use_id`).
    public let id: String?
    /// Tool name.
    public let name: String?
    /// Tool call arguments.
    public let arguments: AnyCodable?
    /// Structured tool result details.
    public let details: AnyCodable?
    /// Whether the tool result reported an error.
    public let isError: Bool?

    /// Whether this block is a tool invocation.
    package var isToolCall: Bool {
        ["toolcall", "tool_call", "tooluse", "tool_use"].contains(self.type?.lowercased() ?? "") ||
            (self.name != nil && self.arguments != nil)
    }

    /// Whether this block is a tool result.
    package var isToolResult: Bool {
        ["toolresult", "tool_result"].contains(self.type?.lowercased() ?? "")
    }

    /// Gateway media and historical file attachments must stay visible in both chat and exports.
    package var isInlineAttachment: Bool {
        switch self.type?.lowercased() {
        case "file", "attachment", "image", "audio", "video":
            true
        default:
            false
        }
    }

    /// Media kind inferred from the block type or MIME type.
    package var mediaKind: OpenClawChatMediaKind? {
        let normalizedType = self.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedType {
        case "image": return .image
        case "audio": return .audio
        case "video": return .video
        default: break
        }
        let normalizedMIME = self.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedMIME?.hasPrefix("image/") == true { return .image }
        if normalizedMIME?.hasPrefix("audio/") == true { return .audio }
        if normalizedMIME?.hasPrefix("video/") == true { return .video }
        return self.isInlineAttachment ? .file : nil
    }

    /// Creates a content block.
    public init(
        type: String?,
        text: String?,
        textSignature: String? = nil,
        thinking: String? = nil,
        thinkingSignature: String? = nil,
        mimeType: String?,
        fileName: String?,
        artifactId: String? = nil,
        url: String? = nil,
        openUrl: String? = nil,
        alt: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        sizeBytes: Int? = nil,
        durationSeconds: Double? = nil,
        playback: OpenClawChatPlaybackMode? = nil,
        content: AnyCodable?,
        preview: OpenClawChatCanvasPreview? = nil,
        id: String? = nil,
        name: String? = nil,
        arguments: AnyCodable? = nil,
        details: AnyCodable? = nil,
        isError: Bool? = nil,
        runId: String? = nil)
    {
        self.runId = runId
        self.type = type
        self.text = text
        self.textSignature = textSignature
        self.thinking = thinking
        self.thinkingSignature = thinkingSignature
        self.mimeType = mimeType
        self.fileName = fileName
        self.artifactId = artifactId
        self.url = url
        self.openUrl = openUrl
        self.alt = alt
        self.width = width
        self.height = height
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.playback = playback
        self.content = content
        self.preview = preview
        self.id = id
        self.name = name
        self.arguments = arguments
        self.details = details
        self.isError = isError
    }

    private struct AttachmentEnvelope: Decodable {
        let artifactId: String?
        let label: String?
        let mimeType: String?
        let sizeBytes: Int?
        let url: String?
    }

    enum CodingKeys: String, CodingKey {
        case attachment
        case type
        case text
        case textSignature
        case thinking
        case thinkingSignature
        case mimeType
        case fileName
        case artifactId
        case url
        case openUrl
        case alt
        case width
        case height
        case sizeBytes
        case durationSeconds
        case durationMs
        case playback
        case content
        case preview
        case id
        case name
        case arguments
        case runId
        case toolUseId
        case tool_use_id
        case toolCallId
        case tool_call_id
        case details
        case isError
        case is_error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.textSignature = try container.decodeIfPresent(String.self, forKey: .textSignature)
        self.thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        self.thinkingSignature = try container.decodeIfPresent(String.self, forKey: .thinkingSignature)
        let attachment = self.type == "attachment"
            ? try container.decodeIfPresent(AttachmentEnvelope.self, forKey: .attachment) : nil
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? attachment?.mimeType
        self.fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? attachment?.label
        let decodedURL = try container.decodeIfPresent(String.self, forKey: .url) ?? attachment?.url
        self.url = decodedURL
        self.openUrl = try container.decodeIfPresent(String.self, forKey: .openUrl)
        self.artifactId = try container.decodeIfPresent(String.self, forKey: .artifactId)
            ?? attachment?.artifactId
            ?? Self.managedArtifactId(
                from: decodedURL,
                type: self.type,
                mimeType: self.mimeType)
        self.alt = try container.decodeIfPresent(String.self, forKey: .alt)
        self.width = try container.decodeIfPresent(Int.self, forKey: .width)
        self.height = try container.decodeIfPresent(Int.self, forKey: .height)
        self.sizeBytes = try container.decodeIfPresent(Int.self, forKey: .sizeBytes) ?? attachment?.sizeBytes
        self.durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
            ?? container.decodeIfPresent(Double.self, forKey: .durationMs).map { $0 / 1000 }
        self.playback = try container.decodeIfPresent(OpenClawChatPlaybackMode.self, forKey: .playback)
        self.runId = try container.decodeIfPresent(String.self, forKey: .runId)
        self.id = try [CodingKeys.id, .tool_call_id, .toolCallId, .tool_use_id, .toolUseId]
            .compactMap { key in
                try container.decodeIfPresent(String.self, forKey: key)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first { !$0.isEmpty }
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.arguments = try container.decodeIfPresent(AnyCodable.self, forKey: .arguments)
        self.details = try container.decodeIfPresent(AnyCodable.self, forKey: .details)
        self.isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ??
            container.decodeIfPresent(Bool.self, forKey: .is_error)
        self.preview = try container.decodeIfPresent(OpenClawChatCanvasPreview.self, forKey: .preview)

        if let any = try container.decodeIfPresent(AnyCodable.self, forKey: .content) {
            self.content = any
        } else if let str = try container.decodeIfPresent(String.self, forKey: .content) {
            self.content = AnyCodable(str)
        } else {
            self.content = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.type, forKey: .type)
        try container.encodeIfPresent(self.text, forKey: .text)
        try container.encodeIfPresent(self.textSignature, forKey: .textSignature)
        try container.encodeIfPresent(self.thinking, forKey: .thinking)
        try container.encodeIfPresent(self.thinkingSignature, forKey: .thinkingSignature)
        try container.encodeIfPresent(self.mimeType, forKey: .mimeType)
        try container.encodeIfPresent(self.fileName, forKey: .fileName)
        try container.encodeIfPresent(self.artifactId, forKey: .artifactId)
        try container.encodeIfPresent(self.url, forKey: .url)
        try container.encodeIfPresent(self.openUrl, forKey: .openUrl)
        try container.encodeIfPresent(self.alt, forKey: .alt)
        try container.encodeIfPresent(self.width, forKey: .width)
        try container.encodeIfPresent(self.height, forKey: .height)
        try container.encodeIfPresent(self.sizeBytes, forKey: .sizeBytes)
        try container.encodeIfPresent(self.durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(self.playback, forKey: .playback)
        try container.encodeIfPresent(self.content, forKey: .content)
        try container.encodeIfPresent(self.preview, forKey: .preview)
        try container.encodeIfPresent(self.id, forKey: .id)
        try container.encodeIfPresent(self.name, forKey: .name)
        try container.encodeIfPresent(self.arguments, forKey: .arguments)
        try container.encodeIfPresent(self.runId, forKey: .runId)
        try container.encodeIfPresent(self.details, forKey: .details)
        try container.encodeIfPresent(self.isError, forKey: .isError)
    }

    private static func managedArtifactId(
        from rawURL: String?,
        type: String?,
        mimeType: String?) -> String?
    {
        guard let rawURL,
              let components = URLComponents(string: rawURL),
              components.scheme == nil,
              components.host == nil
        else { return nil }
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 7,
              segments[0...3] == ["api", "chat", "media", "outgoing"],
              segments[6] == "full",
              let attachmentId = UUID(uuidString: String(segments[5]))?.uuidString.lowercased()
        else { return nil }
        let normalizedType = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMIME = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isImage = normalizedType == "image" || normalizedMIME?.hasPrefix("image/") == true
        let prefix = if !isImage,
                        ["audio", "video", "file", "attachment"].contains(normalizedType ?? "") ||
                        normalizedMIME?.hasPrefix("audio/") == true ||
                        normalizedMIME?.hasPrefix("video/") == true
        {
            "artifact_managed_media_"
        } else {
            "artifact_managed_image_"
        }
        return prefix + attachmentId
    }
}

/// Canvas preview metadata attached to assistant content.
public struct OpenClawChatCanvasPreview: Codable, Hashable, Sendable {
    /// Preview kind (`canvas`).
    public let kind: String?
    /// Target surface (`assistant_message`).
    public let surface: String?
    /// Render mode (`url`).
    public let render: String?
    /// Preview title.
    public let title: String?
    /// Preferred height in points.
    public let preferredHeight: Double?
    /// Relative canvas document URL.
    public let url: String?
    /// Canvas view identifier.
    public let viewId: String?
    /// Sandbox policy (`scripts` or `strict`).
    public let sandbox: String?

    /// Relative widget path when this preview can render inline.
    public var inlineWidgetPath: String? {
        guard self.kind == "canvas",
              self.surface == "assistant_message",
              self.render == "url",
              self.sandbox == "scripts" || self.sandbox == "strict",
              let url = self.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              OpenClawChatWidgetURLResolver.supportsTarget(url)
        else { return nil }
        return url
    }

    /// Clamped inline height (160...1200, default 320).
    public var inlineWidgetHeight: Double {
        min(max(self.preferredHeight ?? 320, 160), 1200)
    }
}

/// Provenance of a user turn injected from another session, channel, or tool.
public struct OpenClawChatInputProvenance: Codable, Hashable, Sendable {
    /// Provenance kind (for example `inter_session`).
    public let kind: String
    /// Originating session identifier.
    public let originSessionId: String?
    /// Originating session key.
    public let sourceSessionKey: String?
    /// Originating channel.
    public let sourceChannel: String?
    /// Originating tool.
    public let sourceTool: String?

    /// Creates a provenance record.
    public init(
        kind: String,
        originSessionId: String? = nil,
        sourceSessionKey: String? = nil,
        sourceChannel: String? = nil,
        sourceTool: String? = nil)
    {
        self.kind = kind
        self.originSessionId = originSessionId
        self.sourceSessionKey = sourceSessionKey
        self.sourceChannel = sourceChannel
        self.sourceTool = sourceTool
    }
}

/// Transcript marker such as a compaction or reset boundary (`__openclaw.kind`).
public struct OpenClawChatHistoryMarker: Codable, Hashable, Sendable {
    /// Marker kind.
    public let kind: String
    /// Transcript entry identifier.
    public let id: String?
    /// Tokens before compaction.
    public let tokensBefore: Double?
    /// Tokens after compaction.
    public let tokensAfter: Double?

    /// Creates a history marker.
    public init(kind: String, id: String? = nil, tokensBefore: Double? = nil, tokensAfter: Double? = nil) {
        self.kind = kind
        self.id = id
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
    }
}

/// Stream-segment fallback metadata (`openclawStreamFallback`) for intermediate assistant rows.
public struct OpenClawChatStreamFallback: Codable, Hashable, Sendable {
    /// Fallback source.
    public let source: String?
    /// Stream item identifier.
    public let itemId: String?
    /// Run identifier.
    public let runId: String?

    private enum CodingKeys: String, CodingKey {
        case source
        case itemId
        case runId
    }

    /// Creates stream fallback metadata.
    public init(source: String? = nil, itemId: String? = nil, runId: String? = nil) {
        self.source = source
        self.itemId = itemId
        self.runId = runId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try? container.decode(String.self, forKey: .source)
        self.itemId = try? container.decode(String.self, forKey: .itemId)
        self.runId = try? container.decode(String.self, forKey: .runId)
    }
}

/// One transcript message.
public struct OpenClawChatMessage: Codable, Hashable, Identifiable, Sendable {
    private struct OpenClawMetadata: Codable {
        let kind: String?
        let id: String?
        let runId: String?
        let turnBoundary: Bool?
        let steerTargetRunId: String?
        let idempotencyKey: String?
        let truncated: Bool?
        let tokensBefore: Double?
        let tokensAfter: Double?
    }

    /// Client-local identity (stable across reconciliation where possible).
    public var id: UUID = .init()
    /// Durable transcript entry identifier (`__openclaw.id` or the session.message envelope).
    public var transcriptMessageID: String?
    /// Agent activity items linked to this message from `chat.history`.
    public var activity: [OpenClawAgentActivityItem]?
    /// Run recorded on the transcript row (`__openclaw.runId`).
    public let transcriptRunID: String?
    /// Whether the gateway truncated this row.
    public var isTruncated = false
    /// Message role.
    public let role: String
    /// Response phase (`commentary`, `final_answer`).
    public let phase: String?
    /// Whether this row starts a turn (`__openclaw.turnBoundary`).
    public let turnBoundary: Bool?
    /// Run a steering message targets (`__openclaw.steerTargetRunId`).
    public let steerTargetRunID: String?
    /// Stream-segment fallback metadata.
    public let streamFallback: OpenClawChatStreamFallback?
    /// Content blocks.
    public let content: [OpenClawChatMessageContent]
    /// Timestamp in milliseconds since 1970.
    public let timestamp: Double?
    /// Client idempotency key (`<runId>:user` for user turns).
    public let idempotencyKey: String?
    /// Tool call identifier for tool rows.
    public let toolCallId: String?
    /// Tool name for tool rows.
    public let toolName: String?
    /// Token usage.
    public let usage: OpenClawChatUsage?
    /// Provider stop reason.
    public let stopReason: String?
    /// Persisted provider failure text.
    public let errorMessage: String?
    /// Structured tool details.
    public let details: AnyCodable?
    /// Whether the tool row reported an error.
    public let isError: Bool?
    /// Provenance of an injected user turn.
    public let provenance: OpenClawChatInputProvenance?
    /// History marker (compaction/reset).
    public let historyMarker: OpenClawChatHistoryMarker?

    /// Stream item identifier for intermediate assistant segments.
    package var streamSegmentID: String? {
        guard self.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "assistant" else { return nil }
        let itemID = self.streamFallback?.itemId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return itemID?.isEmpty == false ? itemID : nil
    }

    enum CodingKeys: String, CodingKey {
        case role
        case phase
        case streamFallback = "openclawStreamFallback"
        case content
        case timestamp
        case idempotencyKey
        case openClaw = "__openclaw"
        case provenance
        case toolCallId
        case tool_call_id
        case toolName
        case tool_name
        case usage
        case stopReason
        case errorMessage
        case details
        case isError
        case is_error
        case mediaPath = "MediaPath"
        case mediaPaths = "MediaPaths"
        case mediaType = "MediaType"
        case mediaTypes = "MediaTypes"
    }

    /// Creates a transcript message.
    public init(
        id: UUID = .init(),
        role: String,
        content: [OpenClawChatMessageContent],
        timestamp: Double?,
        transcriptMessageID: String? = nil,
        transcriptRunID: String? = nil,
        isTruncated: Bool = false,
        idempotencyKey: String? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        usage: OpenClawChatUsage? = nil,
        stopReason: String? = nil,
        errorMessage: String? = nil,
        details: AnyCodable? = nil,
        isError: Bool? = nil,
        provenance: OpenClawChatInputProvenance? = nil,
        historyMarker: OpenClawChatHistoryMarker? = nil,
        phase: String? = nil,
        turnBoundary: Bool? = nil,
        steerTargetRunID: String? = nil,
        streamFallback: OpenClawChatStreamFallback? = nil,
        activity: [OpenClawAgentActivityItem]? = nil)
    {
        self.id = id
        self.transcriptMessageID = transcriptMessageID
        self.transcriptRunID = transcriptRunID
        self.isTruncated = isTruncated
        self.role = role
        self.phase = phase
        self.turnBoundary = turnBoundary
        self.steerTargetRunID = steerTargetRunID
        self.streamFallback = streamFallback
        self.activity = activity
        self.content = content
        self.timestamp = timestamp
        self.idempotencyKey = idempotencyKey
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.details = details
        self.isError = isError
        self.provenance = provenance
        self.historyMarker = historyMarker
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRole = try container.decode(String.self, forKey: .role)
        let decodedTimestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
        let decodedOpenClaw = try container.decodeIfPresent(OpenClawMetadata.self, forKey: .openClaw)
        let decodedIdempotencyKey = try decodedOpenClaw?.idempotencyKey ??
            container.decodeIfPresent(String.self, forKey: .idempotencyKey)
        let decodedToolCallId =
            try container.decodeIfPresent(String.self, forKey: .toolCallId) ??
            container.decodeIfPresent(String.self, forKey: .tool_call_id)
        let decodedToolName =
            try container.decodeIfPresent(String.self, forKey: .toolName) ??
            container.decodeIfPresent(String.self, forKey: .tool_name)
        let decodedUsage = try container.decodeIfPresent(OpenClawChatUsage.self, forKey: .usage)
        let decodedStopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
        let decodedErrorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        let decodedDetails = try container.decodeIfPresent(AnyCodable.self, forKey: .details)
        let decodedIsError = try container.decodeIfPresent(Bool.self, forKey: .isError) ??
            container.decodeIfPresent(Bool.self, forKey: .is_error)
        let decodedProvenance = try? container.decode(
            OpenClawChatInputProvenance.self,
            forKey: .provenance)

        self.role = decodedRole
        self.phase = try container.decodeIfPresent(String.self, forKey: .phase)
        self.turnBoundary = decodedOpenClaw?.turnBoundary
        self.steerTargetRunID = decodedOpenClaw?.steerTargetRunId
        self.streamFallback = try? container.decode(OpenClawChatStreamFallback.self, forKey: .streamFallback)
        self.transcriptMessageID = decodedOpenClaw?.id
        self.transcriptRunID = decodedOpenClaw?.runId
        self.timestamp = decodedTimestamp
        self.idempotencyKey = decodedIdempotencyKey
        self.toolCallId = decodedToolCallId
        self.toolName = decodedToolName
        self.usage = decodedUsage
        self.stopReason = decodedStopReason
        self.errorMessage = decodedErrorMessage
        self.details = decodedDetails
        self.isError = decodedIsError
        self.provenance = decodedProvenance
        self.historyMarker = decodedOpenClaw?.kind.map {
            OpenClawChatHistoryMarker(
                kind: $0,
                id: decodedOpenClaw?.id,
                tokensBefore: decodedOpenClaw?.tokensBefore,
                tokensAfter: decodedOpenClaw?.tokensAfter)
        }

        let decodedContent: [OpenClawChatMessageContent] = if let decoded = try? container.decode(
            [OpenClawChatMessageContent].self,
            forKey: .content)
        {
            decoded
        } else if let text = try? container.decode(String.self, forKey: .content) {
            // Some session log formats store `content` as a plain string.
            [
                OpenClawChatMessageContent(
                    type: "text",
                    text: text,
                    thinking: nil,
                    thinkingSignature: nil,
                    mimeType: nil,
                    fileName: nil,
                    content: nil,
                    id: nil,
                    name: nil,
                    arguments: nil),
            ]
        } else {
            []
        }

        let mediaPaths =
            (try? container.decode([String].self, forKey: .mediaPaths))
            ?? (try? container.decode(String.self, forKey: .mediaPath)).map { [$0] }
            ?? []
        let mediaTypes =
            (try? container.decode([String].self, forKey: .mediaTypes))
            ?? (try? container.decode(String.self, forKey: .mediaType)).map { [$0] }
            ?? []
        let alreadyContainsAudio = decodedContent.contains { content in
            content.mimeType?.lowercased().hasPrefix("audio/") == true
        }
        let audioAttachments: [OpenClawChatMessageContent] = alreadyContainsAudio ? [] : mediaPaths
            .enumerated()
            .compactMap { index, mediaPath in
                guard mediaTypes.indices.contains(index) else { return nil }
                let mimeType = mediaTypes[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard mimeType.lowercased().hasPrefix("audio/") else { return nil }
                return OpenClawChatMessageContent(
                    type: "file",
                    text: nil,
                    mimeType: mimeType,
                    fileName: (mediaPath as NSString).lastPathComponent,
                    content: nil)
            }
        self.content = decodedContent + audioAttachments
        self.isTruncated = decodedOpenClaw?.truncated == true || decodedContent.contains { content in
            content.text?.contains(Self.transcriptTruncationMarker) == true
        }
    }

    /// Visible text for a message, substituting persisted provider failures for empty assistant turns.
    package static func displayText(
        contentText: String,
        role: String,
        stopReason: String?,
        errorMessage: String?) -> String
    {
        let text = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let errorText = Self.errorDisplayText(
            role: role,
            stopReason: stopReason,
            errorMessage: errorMessage)
        else {
            return text
        }
        if text.isEmpty || text == Self.streamErrorFallbackText {
            return errorText
        }
        return text
    }

    /// Persisted provider failure text shown for assistant rows that stopped with an error.
    package static func errorDisplayText(role: String, stopReason: String?, errorMessage: String?) -> String? {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedStopReason = stopReason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedRole == "assistant",
              normalizedStopReason == "error",
              let text = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        return text
    }

    private static let streamErrorFallbackText = "[assistant turn failed before producing content]"
    private static let transcriptTruncationMarker = "\n...(truncated)..."

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.role, forKey: .role)
        try container.encodeIfPresent(self.phase, forKey: .phase)
        try container.encodeIfPresent(self.streamFallback, forKey: .streamFallback)
        try container.encodeIfPresent(self.timestamp, forKey: .timestamp)
        if self.transcriptMessageID != nil || self.transcriptRunID != nil || self.isTruncated || self
            .historyMarker != nil || self.turnBoundary != nil || self.steerTargetRunID != nil
        {
            try container.encode(
                OpenClawMetadata(
                    kind: self.historyMarker?.kind,
                    id: self.historyMarker?.id ?? self.transcriptMessageID,
                    runId: self.transcriptRunID,
                    turnBoundary: self.turnBoundary,
                    steerTargetRunId: self.steerTargetRunID,
                    idempotencyKey: nil,
                    truncated: self.isTruncated ? true : nil,
                    tokensBefore: self.historyMarker?.tokensBefore,
                    tokensAfter: self.historyMarker?.tokensAfter),
                forKey: .openClaw)
        }
        try container.encodeIfPresent(self.provenance, forKey: .provenance)
        try container.encodeIfPresent(self.idempotencyKey, forKey: .idempotencyKey)
        try container.encodeIfPresent(self.toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(self.toolName, forKey: .toolName)
        try container.encodeIfPresent(self.usage, forKey: .usage)
        try container.encodeIfPresent(self.stopReason, forKey: .stopReason)
        try container.encodeIfPresent(self.errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(self.details, forKey: .details)
        try container.encodeIfPresent(self.isError, forKey: .isError)
        try container.encode(self.content, forKey: .content)
    }
}

/// In-flight run snapshot returned by `chat.history`.
public struct OpenClawChatInFlightRun: Codable, Sendable {
    /// Run identifier.
    public let runId: String
    /// Buffered assistant text.
    public let text: String

    /// Creates an in-flight run snapshot.
    public init(runId: String, text: String) {
        self.runId = runId
        self.text = text
    }
}

/// Session state attached to `chat.history`.
public struct OpenClawChatSessionInfo: Codable, Sendable {
    /// Canonical session key.
    public let key: String?
    /// Owning agent.
    public let agentId: String?
    /// Whether any run is active in the session.
    public let hasActiveRun: Bool?
    /// Active run identifiers.
    public let activeRunIds: [String]?

    /// Creates session info.
    public init(hasActiveRun: Bool?, activeRunIds: [String]? = nil, key: String? = nil, agentId: String? = nil) {
        self.key = key
        self.agentId = agentId
        self.hasActiveRun = hasActiveRun
        self.activeRunIds = activeRunIds
    }
}

/// Agent activity item (tool call, preamble, ...) reported by `item` agent events and history.
public struct OpenClawAgentActivityItem: Codable, Hashable, Sendable {
    /// Item identifier.
    public let itemId: String
    /// Linked tool call identifier.
    public let toolCallId: String?
    /// Item kind.
    public let kind: String
    /// Item phase (`start`, `update`, `end`).
    public let phase: String
    /// Display title.
    public let title: String
    /// Tool name.
    public let name: String?
    /// Status (`running`, `completed`, `failed`, `blocked`).
    public let status: String?
    /// Whether channels should hide this item from progress.
    public let hideFromChannelProgress: Bool?
    /// Whether progress output is suppressed for this item.
    public let suppressChannelProgress: Bool?

    /// Creates an activity item.
    public init(
        itemId: String,
        toolCallId: String? = nil,
        kind: String,
        phase: String,
        title: String,
        name: String? = nil,
        status: String? = nil,
        hideFromChannelProgress: Bool? = nil,
        suppressChannelProgress: Bool? = nil)
    {
        self.itemId = itemId
        self.toolCallId = toolCallId
        self.kind = kind
        self.phase = phase
        self.title = title
        self.name = name
        self.status = status
        self.hideFromChannelProgress = hideFromChannelProgress
        self.suppressChannelProgress = suppressChannelProgress
    }

    /// Whether the item should render as visible progress.
    package var isVisible: Bool {
        self.hideFromChannelProgress != true && self.suppressChannelProgress != true
    }
}

/// Activity items grouped by transcript message in `chat.history`.
public struct OpenClawChatHistoryActivity: Codable, Sendable {
    /// Transcript message identifier.
    public let messageId: String
    /// Activity items.
    public let items: [OpenClawAgentActivityItem]

    /// Creates a history activity group.
    public init(messageId: String, items: [OpenClawAgentActivityItem]) {
        self.messageId = messageId
        self.items = items
    }
}

/// `chat.history` response.
public struct OpenClawChatHistoryPayload: Codable, Sendable {
    /// Which run consumed a queued input (`inputRunIds` history requests).
    public struct InputConsumption: Codable, Sendable {
        /// Input run identifier.
        public let runId: String
        /// Consuming event identifier.
        public let consumedByEventId: String

        /// Creates an input consumption record.
        public init(runId: String, consumedByEventId: String) {
            self.runId = runId
            self.consumedByEventId = consumedByEventId
        }
    }

    /// Session key.
    public let sessionKey: String
    /// Session identifier.
    public let sessionId: String?
    /// Raw transcript rows.
    public let messages: [AnyCodable]?
    /// Session thinking level.
    public let thinkingLevel: String?
    /// Session run state.
    public let sessionInfo: OpenClawChatSessionInfo?
    /// In-flight run snapshot.
    public let inFlightRun: OpenClawChatInFlightRun?
    /// Input consumption records.
    public let inputConsumptions: [InputConsumption]?
    /// Activity items keyed by message.
    public let activity: [OpenClawChatHistoryActivity]?

    /// Creates a history payload.
    public init(
        sessionKey: String,
        sessionId: String?,
        messages: [AnyCodable]?,
        thinkingLevel: String?,
        sessionInfo: OpenClawChatSessionInfo? = nil,
        inFlightRun: OpenClawChatInFlightRun? = nil,
        inputConsumptions: [InputConsumption]? = nil,
        activity: [OpenClawChatHistoryActivity]? = nil)
    {
        self.sessionKey = sessionKey
        self.sessionId = sessionId
        self.messages = messages
        self.thinkingLevel = thinkingLevel
        self.sessionInfo = sessionInfo
        self.inFlightRun = inFlightRun
        self.inputConsumptions = inputConsumptions
        self.activity = activity
    }
}

/// One preview line in `sessions.preview`.
public struct OpenClawSessionPreviewItem: Codable, Hashable, Sendable {
    /// Message role.
    public let role: String
    /// Preview text.
    public let text: String
}

/// Preview lines for one session.
public struct OpenClawSessionPreviewEntry: Codable, Sendable {
    /// Session key.
    public let key: String
    /// Preview status.
    public let status: String
    /// Preview lines.
    public let items: [OpenClawSessionPreviewItem]
}

/// `sessions.preview` response.
public struct OpenClawSessionsPreviewPayload: Codable, Sendable {
    /// Server timestamp in epoch milliseconds (`0` when the gateway omitted or malformed it).
    ///
    /// Stored as `Int64` because millisecond epochs exceed `Int32`, the width of `Int` on watchOS arm64_32.
    public let tsMilliseconds: Int64
    /// Session previews.
    public let previews: [OpenClawSessionPreviewEntry]

    /// Server timestamp as `Int`, clamped on 32-bit platforms. Prefer ``tsMilliseconds``.
    public var ts: Int {
        Int(clamping: self.tsMilliseconds)
    }

    /// Creates a preview payload.
    public init(ts: Int, previews: [OpenClawSessionPreviewEntry]) {
        self.init(tsMilliseconds: Int64(ts), previews: previews)
    }

    /// Creates a preview payload from a 64-bit millisecond timestamp.
    public init(tsMilliseconds: Int64, previews: [OpenClawSessionPreviewEntry]) {
        self.tsMilliseconds = tsMilliseconds
        self.previews = previews
    }

    private enum CodingKeys: String, CodingKey {
        case ts
        case previews
    }

    /// Decodes a preview payload; `ts` is read leniently as a 64-bit millisecond value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tsMilliseconds = ChatMillisecondTimestamp.decode(from: container, forKey: .ts) ?? 0
        self.previews = try container.decode([OpenClawSessionPreviewEntry].self, forKey: .previews)
    }

    /// Encodes the payload with `ts` as a 64-bit integer.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.tsMilliseconds, forKey: .ts)
        try container.encode(self.previews, forKey: .previews)
    }
}

/// Lenient millisecond-epoch decoding that is safe on 32-bit `Int` platforms (watchOS arm64_32).
enum ChatMillisecondTimestamp {
    /// Reads `key` as `Int64`, falling back to a whole `Double`; `nil` when absent or malformed.
    static func decode<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key) -> Int64?
    {
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        guard let value = try? container.decodeIfPresent(Double.self, forKey: key) else { return nil }
        return Int64(exactly: value.rounded())
    }
}

/// `chat.send` acknowledgement.
public struct OpenClawChatSendResponse: Codable, Sendable {
    /// Run identifier (may differ from the idempotency key when the gateway reuses a run).
    public let runId: String
    /// Status (`started`, `queued`, `ok`, `error`, `timeout`, ...).
    public let status: String

    /// Creates a send response.
    public init(runId: String, status: String) {
        self.runId = runId
        self.status = status
    }
}

/// `sessions.create` response.
public struct OpenClawChatCreateSessionResponse: Codable, Sendable {
    /// Whether creation succeeded.
    public let ok: Bool?
    /// Created session key.
    public let key: String
    /// Created session identifier.
    public let sessionId: String?

    /// Creates a create-session response.
    public init(ok: Bool? = true, key: String, sessionId: String? = nil) {
        self.ok = ok
        self.key = key
        self.sessionId = sessionId
    }
}

/// Composer attachment restored by rewind/fork (base64 bytes).
public struct OpenClawChatEditorAttachment: Codable, Sendable {
    /// MIME type.
    public let mimeType: String
    /// Base64 data.
    public let data: String

    /// Creates an editor attachment.
    public init(mimeType: String, data: String) {
        self.mimeType = mimeType
        self.data = data
    }
}

/// `sessions.rewind` response.
public struct OpenClawChatRewindResponse: Codable, Sendable {
    /// Text restored into the composer.
    public let editorText: String?
    /// Attachments restored into the composer.
    public let editorAttachments: [OpenClawChatEditorAttachment]?

    /// Creates a rewind response.
    public init(editorText: String? = nil, editorAttachments: [OpenClawChatEditorAttachment]? = nil) {
        self.editorText = editorText
        self.editorAttachments = editorAttachments
    }
}

/// `sessions.fork` (fork at message) response.
public struct OpenClawChatForkAtMessageResponse: Codable, Sendable {
    /// Created session key.
    public let sessionKey: String
    /// Text restored into the composer.
    public let editorText: String?
    /// Attachments restored into the composer.
    public let editorAttachments: [OpenClawChatEditorAttachment]?

    /// Creates a fork-at-message response.
    public init(
        sessionKey: String,
        editorText: String? = nil,
        editorAttachments: [OpenClawChatEditorAttachment]? = nil)
    {
        self.sessionKey = sessionKey
        self.editorText = editorText
        self.editorAttachments = editorAttachments
    }
}

/// One transcript branch reported by `sessions.branches.list`.
public struct OpenClawChatSessionBranch: Codable, Sendable, Equatable, Identifiable {
    /// Leaf transcript entry of the branch.
    public let leafEntryId: String
    /// Headline text.
    public let headline: String
    /// Messages on the branch.
    public let messageCount: Int
    /// Last update (ISO-8601 string).
    public let updatedAt: String?
    /// Whether this branch is the active one.
    public let active: Bool

    /// The leaf entry identifier.
    public var id: String {
        self.leafEntryId
    }

    /// Creates a branch.
    public init(
        leafEntryId: String,
        headline: String,
        messageCount: Int,
        updatedAt: String?,
        active: Bool)
    {
        self.leafEntryId = leafEntryId
        self.headline = headline
        self.messageCount = messageCount
        self.updatedAt = updatedAt
        self.active = active
    }
}

/// `sessions.branches.list` response.
public struct OpenClawChatSessionBranchesResponse: Codable, Sendable {
    /// Branches.
    public let branches: [OpenClawChatSessionBranch]

    /// Creates a branches response.
    public init(branches: [OpenClawChatSessionBranch]) {
        self.branches = branches
    }
}

/// State discriminator of a protocol-v4 `chat` event.
///
/// Gateway protocol v4 publishes chat events as a union keyed on `state`. Newer gateways add
/// states over time (2026.9.6 added `status`), so unknown values are preserved in ``unknown(_:)``
/// instead of failing the frame.
public enum OpenClawChatEventState: Sendable, Equatable {
    /// Streaming assistant text (`deltaText`, optionally `replace`).
    case delta
    /// Terminal success.
    case final
    /// Terminal abort.
    case aborted
    /// Terminal failure.
    case error
    /// Run startup/retry status (non-terminal).
    case status
    /// A state this SDK does not know yet.
    case unknown(String)
    /// The frame had no `state`.
    case missing

    /// Parses a wire `state` value.
    public init(rawValue: String?) {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "": self = .missing
        case "delta": self = .delta
        case "final": self = .final
        case "aborted": self = .aborted
        case "error": self = .error
        case "status": self = .status
        case let value?: self = .unknown(value)
        }
    }

    /// Whether this state ends the run.
    public var isTerminal: Bool {
        switch self {
        case .final, .aborted, .error: true
        case .delta, .status, .unknown, .missing: false
        }
    }
}

/// `chat` event payload (protocol v4 union, decoded leniently).
///
/// Every union member shares `runId`/`sessionKey`/`seq`/`state`; `delta` frames carry `deltaText`
/// (append) and `replace` (replace the buffer), terminal frames carry `stopReason`/`errorMessage`.
/// Fields a state does not define stay `nil`.
public struct OpenClawChatEventPayload: Codable, Sendable {
    /// Run identifier.
    public let runId: String?
    /// Session key (canonical or alias).
    public let sessionKey: String?
    /// Owning agent.
    public let agentId: String?
    /// Raw `state` discriminator.
    public let state: String?
    /// Full assistant message snapshot (delta and final frames).
    public let message: AnyCodable?
    /// Failure text (aborted/error frames).
    public let errorMessage: String?
    /// Event sequence number.
    public let seq: Int?
    /// Parent session key that spawned this run.
    public let spawnedBy: String?
    /// Text appended by a delta frame (v4).
    public let deltaText: String?
    /// Whether ``deltaText`` replaces the buffered text instead of appending (v4).
    public let replace: Bool?
    /// Provider stop reason (final/aborted/error frames).
    public let stopReason: String?
    /// Whether the run yielded control (final frames).
    public let yielded: Bool?
    /// Error classification (error frames).
    public let errorKind: AnyCodable?
    /// Usage snapshot.
    public let usage: AnyCodable?
    /// Startup phase (status frames).
    public let phase: String?

    /// Parsed state discriminator.
    public var kind: OpenClawChatEventState {
        OpenClawChatEventState(rawValue: self.state)
    }

    /// Creates a chat event payload.
    public init(
        runId: String?,
        sessionKey: String?,
        agentId: String? = nil,
        state: String?,
        message: AnyCodable?,
        errorMessage: String?,
        seq: Int? = nil,
        spawnedBy: String? = nil,
        deltaText: String? = nil,
        replace: Bool? = nil,
        stopReason: String? = nil,
        yielded: Bool? = nil,
        errorKind: AnyCodable? = nil,
        usage: AnyCodable? = nil,
        phase: String? = nil)
    {
        self.runId = runId
        self.sessionKey = sessionKey
        self.agentId = agentId
        self.state = state
        self.message = message
        self.errorMessage = errorMessage
        self.seq = seq
        self.spawnedBy = spawnedBy
        self.deltaText = deltaText
        self.replace = replace
        self.stopReason = stopReason
        self.yielded = yielded
        self.errorKind = errorKind
        self.usage = usage
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey {
        case runId
        case sessionKey
        case agentId
        case state
        case message
        case errorMessage
        case seq
        case spawnedBy
        case deltaText
        case replace
        case stopReason
        case yielded
        case errorKind
        case usage
        case phase
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Identity fields keep strict typing; state-specific fields decode leniently so a new
        // or reshaped union member never drops the whole frame.
        self.runId = try container.decodeIfPresent(String.self, forKey: .runId)
        self.sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
        self.agentId = try? container.decodeIfPresent(String.self, forKey: .agentId)
        self.state = try? container.decodeIfPresent(String.self, forKey: .state)
        self.message = try? container.decodeIfPresent(AnyCodable.self, forKey: .message)
        self.errorMessage = try? container.decodeIfPresent(String.self, forKey: .errorMessage)
        self.seq = try? container.decodeIfPresent(Int.self, forKey: .seq)
        self.spawnedBy = try? container.decodeIfPresent(String.self, forKey: .spawnedBy)
        self.deltaText = try? container.decodeIfPresent(String.self, forKey: .deltaText)
        self.replace = try? container.decodeIfPresent(Bool.self, forKey: .replace)
        self.stopReason = try? container.decodeIfPresent(String.self, forKey: .stopReason)
        self.yielded = try? container.decodeIfPresent(Bool.self, forKey: .yielded)
        self.errorKind = try? container.decodeIfPresent(AnyCodable.self, forKey: .errorKind)
        self.usage = try? container.decodeIfPresent(AnyCodable.self, forKey: .usage)
        self.phase = try? container.decodeIfPresent(String.self, forKey: .phase)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.runId, forKey: .runId)
        try container.encodeIfPresent(self.sessionKey, forKey: .sessionKey)
        try container.encodeIfPresent(self.agentId, forKey: .agentId)
        try container.encodeIfPresent(self.state, forKey: .state)
        try container.encodeIfPresent(self.message, forKey: .message)
        try container.encodeIfPresent(self.errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(self.seq, forKey: .seq)
        try container.encodeIfPresent(self.spawnedBy, forKey: .spawnedBy)
        try container.encodeIfPresent(self.deltaText, forKey: .deltaText)
        try container.encodeIfPresent(self.replace, forKey: .replace)
        try container.encodeIfPresent(self.stopReason, forKey: .stopReason)
        try container.encodeIfPresent(self.yielded, forKey: .yielded)
        try container.encodeIfPresent(self.errorKind, forKey: .errorKind)
        try container.encodeIfPresent(self.usage, forKey: .usage)
        try container.encodeIfPresent(self.phase, forKey: .phase)
    }
}

/// `session.message` event payload: one durable transcript row plus session run state.
public struct OpenClawSessionMessageEventPayload: Codable, Sendable {
    /// Session key (falls back to nested `session.sessionKey`).
    public let sessionKey: String?
    /// Owning agent (falls back to nested `session.agentId`).
    public let agentId: String?
    /// Transcript row.
    public let message: OpenClawChatMessage?
    /// Durable message identifier.
    public let messageId: String?
    /// Message sequence number.
    public let messageSeq: Int?
    /// Whether the session has an active run.
    public let hasActiveRun: Bool?
    /// Active run identifiers.
    public let activeRunIds: [String]?
    /// Whether `activeRunIds` was present (explicit null clears).
    package let activeRunIdsPresent: Bool

    /// Creates a session message payload.
    public init(
        sessionKey: String?,
        agentId: String? = nil,
        message: OpenClawChatMessage?,
        messageId: String?,
        messageSeq: Int?,
        hasActiveRun: Bool? = nil,
        activeRunIds: [String]? = nil,
        activeRunIdsPresent: Bool? = nil)
    {
        self.sessionKey = sessionKey
        self.agentId = agentId
        self.message = message
        self.messageId = messageId
        self.messageSeq = messageSeq
        self.hasActiveRun = hasActiveRun
        self.activeRunIds = activeRunIds
        self.activeRunIdsPresent = activeRunIdsPresent ?? (activeRunIds != nil)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .session)

        func decode<T: Decodable>(_ type: T.Type, forKey key: CodingKeys) throws -> T? {
            if container.contains(key) {
                return try container.decodeIfPresent(type, forKey: key)
            }
            return try nested?.decodeIfPresent(type, forKey: key)
        }

        self.sessionKey = try decode(String.self, forKey: .sessionKey)
        self.agentId = try decode(String.self, forKey: .agentId)
        self.message = try container.decodeIfPresent(OpenClawChatMessage.self, forKey: .message)
        self.messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        self.messageSeq = try container.decodeIfPresent(Int.self, forKey: .messageSeq)
        self.hasActiveRun = try decode(Bool.self, forKey: .hasActiveRun)
        self.activeRunIds = try decode([String].self, forKey: .activeRunIds)
        self.activeRunIdsPresent = container.contains(.activeRunIds) || nested?.contains(.activeRunIds) == true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.sessionKey, forKey: .sessionKey)
        try container.encodeIfPresent(self.agentId, forKey: .agentId)
        try container.encodeIfPresent(self.message, forKey: .message)
        try container.encodeIfPresent(self.messageId, forKey: .messageId)
        try container.encodeIfPresent(self.messageSeq, forKey: .messageSeq)
        try container.encodeIfPresent(self.hasActiveRun, forKey: .hasActiveRun)
        if self.activeRunIdsPresent {
            if let activeRunIds {
                try container.encode(activeRunIds, forKey: .activeRunIds)
            } else {
                try container.encodeNil(forKey: .activeRunIds)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case session
        case sessionKey
        case agentId
        case message
        case messageId
        case messageSeq
        case hasActiveRun
        case activeRunIds
    }
}

/// `agent` (and `session.tool`) event payload.
public struct OpenClawAgentEventPayload: Codable, Sendable, Identifiable {
    /// `runId-seq` identity.
    public var id: String {
        "\(self.runId)-\(self.seq ?? -1)"
    }

    /// Run identifier.
    public let runId: String
    /// Event sequence number.
    public let seq: Int?
    /// Stream (`assistant`, `tool`, `lifecycle`, `item`, `usage`, `plan`, ...).
    public let stream: String
    /// Event timestamp in epoch milliseconds (wire key `ts`).
    ///
    /// Stored as `Int64` because millisecond epochs exceed `Int32`, the width of `Int` on watchOS arm64_32.
    public let tsMilliseconds: Int64?
    /// Stream-specific data.
    public let data: [String: AnyCodable]
    /// Session key when the gateway attaches a session snapshot (`session.tool`).
    public let sessionKey: String?
    /// Owning agent when the gateway attaches a session snapshot.
    public let agentId: String?

    /// Event timestamp in milliseconds as `Int`; `nil` on 32-bit platforms where it does not fit.
    /// Prefer ``tsMilliseconds``.
    public var ts: Int? {
        self.tsMilliseconds.flatMap { Int(exactly: $0) }
    }

    /// Creates an agent event payload.
    public init(
        runId: String,
        seq: Int?,
        stream: String,
        ts: Int?,
        data: [String: AnyCodable],
        sessionKey: String? = nil,
        agentId: String? = nil)
    {
        self.init(
            runId: runId,
            seq: seq,
            stream: stream,
            tsMilliseconds: ts.map { Int64($0) },
            data: data,
            sessionKey: sessionKey,
            agentId: agentId)
    }

    /// Creates an agent event payload from a 64-bit millisecond timestamp.
    public init(
        runId: String,
        seq: Int?,
        stream: String,
        tsMilliseconds: Int64?,
        data: [String: AnyCodable],
        sessionKey: String? = nil,
        agentId: String? = nil)
    {
        self.runId = runId
        self.seq = seq
        self.stream = stream
        self.tsMilliseconds = tsMilliseconds
        self.data = data
        self.sessionKey = sessionKey
        self.agentId = agentId
    }

    private enum CodingKeys: String, CodingKey {
        case runId
        case seq
        case stream
        case ts
        case data
        case sessionKey
        case agentId
    }

    /// Decodes an event: `runId` and `stream` are required, every other field is lenient so one
    /// malformed or out-of-range value (such as a millisecond `ts` on 32-bit `Int`) never drops the event.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runId = try container.decode(String.self, forKey: .runId)
        self.stream = try container.decode(String.self, forKey: .stream)
        self.seq = try? container.decodeIfPresent(Int.self, forKey: .seq)
        self.tsMilliseconds = ChatMillisecondTimestamp.decode(from: container, forKey: .ts)
        self.data = (try? container.decodeIfPresent(Dictionary<String, AnyCodable>.self, forKey: .data)) ?? [:]
        self.sessionKey = try? container.decodeIfPresent(String.self, forKey: .sessionKey)
        self.agentId = try? container.decodeIfPresent(String.self, forKey: .agentId)
    }

    /// Encodes the event with `ts` as a 64-bit integer.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.runId, forKey: .runId)
        try container.encodeIfPresent(self.seq, forKey: .seq)
        try container.encode(self.stream, forKey: .stream)
        try container.encodeIfPresent(self.tsMilliseconds, forKey: .ts)
        try container.encode(self.data, forKey: .data)
        try container.encodeIfPresent(self.sessionKey, forKey: .sessionKey)
        try container.encodeIfPresent(self.agentId, forKey: .agentId)
    }
}

/// Live tool call tracked for the active turn.
public struct OpenClawChatPendingToolCall: Identifiable, Hashable, Sendable {
    /// Tool call identifier.
    public var id: String {
        self.toolCallId
    }

    /// Tool call identifier.
    public let toolCallId: String
    /// Tool name.
    public let name: String
    /// Tool arguments.
    public let args: AnyCodable?
    /// Start timestamp in milliseconds.
    public let startedAt: Double?
    /// Whether the call failed.
    public let isError: Bool?
    /// Live diff statistics from `input_delta` events.
    package let diffStat: ChatToolDiffStat?
    /// Activity item linked to this call.
    package var activity: OpenClawAgentActivityItem?
    /// Whether the call finished (kept visible while its activity item is shown).
    package var isComplete: Bool = false

    /// Creates a pending tool call.
    package init(
        toolCallId: String,
        name: String,
        args: AnyCodable?,
        startedAt: Double?,
        isError: Bool?,
        diffStat: ChatToolDiffStat? = nil,
        activity: OpenClawAgentActivityItem? = nil,
        isComplete: Bool = false)
    {
        self.toolCallId = toolCallId
        self.name = name
        self.args = args
        self.startedAt = startedAt
        self.isError = isError
        self.diffStat = diffStat
        self.activity = activity
        self.isComplete = isComplete
    }
}

/// `health` payload.
public struct OpenClawGatewayHealthOK: Codable, Sendable {
    /// Whether the gateway reports healthy.
    public let ok: Bool?
}

/// Attachment bytes sent with `chat.send`.
public struct OpenClawChatAttachmentPayload: Codable, Sendable, Hashable {
    /// Attachment type (`image`, `file`, ...).
    public let type: String
    /// MIME type.
    public let mimeType: String
    /// File name.
    public let fileName: String
    /// Base64 content.
    public let content: String

    /// Creates an attachment payload.
    public init(type: String, mimeType: String, fileName: String, content: String) {
        self.type = type
        self.mimeType = mimeType
        self.fileName = fileName
        self.content = content
    }
}
