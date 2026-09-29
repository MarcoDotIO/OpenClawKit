import Foundation

/// Hand-maintained per-channel traits merged with the generated upstream rows.
///
/// Upstream defines capabilities, format profiles and chunk limits in TypeScript plugin code, so
/// they cannot be generated from manifests. `Scripts/channel-catalog-gen.mjs` warns when a
/// generated channel id has no row here. Keys are upstream channel ids.
struct ChannelCatalogTraits: Sendable {
    var capabilities: ChannelCapabilities
    var formatProfile: ChannelFormatProfile?
    var chunking: ChannelTextChunkingDefaults?
    var coalesce: ChannelBlockStreamingCoalesceDefaults?
    var nativeTransportAvailable: Bool
    var nativeTransportKind: String?
    var nativeUnavailableReason: String?

    init(
        capabilities: ChannelCapabilities,
        formatProfile: ChannelFormatProfile? = nil,
        chunking: ChannelTextChunkingDefaults? = nil,
        coalesce: ChannelBlockStreamingCoalesceDefaults? = nil,
        nativeTransportAvailable: Bool = false,
        nativeTransportKind: String? = nil,
        nativeUnavailableReason: String? = nil
    ) {
        self.capabilities = capabilities
        self.formatProfile = formatProfile
        self.chunking = chunking
        self.coalesce = coalesce
        self.nativeTransportAvailable = nativeTransportAvailable
        self.nativeTransportKind = nativeTransportKind
        self.nativeUnavailableReason = nativeUnavailableReason
    }
}

enum ChannelCatalogTraitsTable {
    static let pluginOnlyReason = "Plugin-only channel; OpenClawKit ships no native Swift transport for it in this release"
    static let externalPluginReason = "External plugin maintained outside OpenClaw"

    static let standardCoalesce = ChannelBlockStreamingCoalesceDefaults(minChars: 1_500, idleMs: 1_000)

    static let iMessageCapabilities = ChannelCapabilities(
        chatTypes: [.direct, .group],
        reactions: true,
        edit: true,
        unsend: true,
        reply: true,
        effects: true,
        groupManagement: true,
        media: true,
        nativePolls: true,
        typing: true,
        ttsVoice: ChannelTTSVoiceDelivery(
            synthesisTarget: .audioFile,
            audioFileFormats: ["caf", "m4a", "mp3"],
            preferAudioFileFormat: "caf"
        )
    )

    static let iMessageFormat = ChannelFormatProfile(mechanism: .ranges, chunkLimit: 4_000, chunkUnit: .utf16)

    static let slackFormat = ChannelFormatProfile(
        mechanism: .markdown,
        chunkLimit: 4_000,
        chunkUnit: .chars,
        hardCap: 40_000,
        constructs: [
            .underline: .strip,
            .spoiler: .fallback,
            .heading: .fallback,
            .bulletList: .fallback,
            .orderedList: .fallback,
            .taskList: .fallback,
            .table: .fallback,
            .image: .fallback,
        ]
    )

    static let rows: [String: ChannelCatalogTraits] = [
        "whatsapp": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .group, .channel],
                polls: true,
                reactions: true,
                media: true,
                ttsVoice: ChannelTTSVoiceDelivery(synthesisTarget: .voiceNote)
            ),
            formatProfile: ChannelFormatProfile(mechanism: .markdown, chunkLimit: 4_096),
            chunking: ChannelTextChunkingDefaults(defaultLimit: 4_000, platformLimit: 4_096),
            nativeTransportAvailable: true,
            nativeTransportKind: "cloud-api"
        ),
        "telegram": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .group, .channel, .thread],
                polls: true,
                reactions: true,
                threads: true,
                media: true,
                nativeCommands: true,
                blockStreaming: true,
                richMessages: true,
                roomIntroductions: true,
                typing: true,
                ttsVoice: ChannelTTSVoiceDelivery(synthesisTarget: .voiceNote, captionedFinalText: true)
            ),
            formatProfile: ChannelFormatProfile(mechanism: .html, chunkLimit: 4_000, hardCap: 4_096),
            chunking: ChannelTextChunkingDefaults(
                defaultLimit: 4_000,
                platformLimit: 4_096,
                richMessagesLimit: 32_768
            ),
            nativeTransportAvailable: true,
            nativeTransportKind: "bot-api"
        ),
        "slack": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .channel, .thread],
                reactions: true,
                threads: true,
                media: true,
                nativeCommands: true,
                groupDirectMessages: true,
                richMessages: true,
                presenceTriggers: true,
                roomIntroductions: true,
                typing: true
            ),
            formatProfile: Self.slackFormat,
            chunking: ChannelTextChunkingDefaults(defaultLimit: 8_000, platformLimit: 40_000),
            coalesce: Self.standardCoalesce,
            nativeTransportAvailable: true,
            nativeTransportKind: "web-api"
        ),
        "googlechat": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .group, .thread],
                threads: true,
                media: true,
                blockStreaming: true
            ),
            formatProfile: ChannelFormatProfile(mechanism: .markdown, chunkLimit: 32_000, chunkUnit: .bytes),
            chunking: ChannelTextChunkingDefaults(defaultLimit: 32_000, unit: .bytes, platformLimit: 32_000),
            coalesce: Self.standardCoalesce,
            nativeTransportAvailable: true,
            nativeTransportKind: "chat-api"
        ),
        "discord": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .channel, .thread],
                polls: true,
                reactions: true,
                threads: true,
                media: true,
                nativeCommands: true,
                presenceTriggers: true,
                roomIntroductions: true,
                typing: true,
                ttsVoice: ChannelTTSVoiceDelivery(synthesisTarget: .voiceNote)
            ),
            formatProfile: ChannelFormatProfile(mechanism: .markdown, chunkLimit: 2_000, hardCap: 2_000),
            chunking: ChannelTextChunkingDefaults(defaultLimit: 2_000, platformLimit: 2_000, maxLines: 17),
            nativeTransportAvailable: true,
            nativeTransportKind: "bot-api"
        ),
        "signal": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .group],
                reactions: true,
                media: true,
                typing: true
            ),
            formatProfile: ChannelFormatProfile(mechanism: .ranges, chunkLimit: 4_000),
            chunking: ChannelTextChunkingDefaults(defaultLimit: 4_000),
            coalesce: Self.standardCoalesce,
            nativeTransportAvailable: true,
            nativeTransportKind: "signal-cli-rest"
        ),
        "imessage": ChannelCatalogTraits(
            capabilities: Self.iMessageCapabilities,
            formatProfile: Self.iMessageFormat,
            chunking: ChannelTextChunkingDefaults(defaultLimit: 4_000, unit: .utf16),
            nativeTransportAvailable: true,
            nativeTransportKind: "imsg-rpc"
        ),
        "bluebubbles": ChannelCatalogTraits(
            capabilities: Self.iMessageCapabilities,
            formatProfile: Self.iMessageFormat,
            chunking: ChannelTextChunkingDefaults(defaultLimit: 4_000, unit: .utf16),
            nativeTransportAvailable: true,
            nativeTransportKind: "bluebubbles-rest"
        ),
        "msteams": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .channel, .group, .thread],
                polls: true,
                reactions: true,
                threads: true,
                media: true,
                typing: true
            ),
            formatProfile: ChannelFormatProfile(
                mechanism: .markdown,
                chunkLimit: 80_000,
                chunkUnit: .utf16,
                hardCap: 100_000
            ),
            chunking: ChannelTextChunkingDefaults(defaultLimit: 4_000, unit: .utf16, platformLimit: 100_000),
            nativeTransportAvailable: true,
            nativeTransportKind: "bot-framework"
        ),
        "webchat": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct], media: true),
            nativeTransportAvailable: true,
            nativeTransportKind: "http"
        ),
        "line": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .group],
                media: true,
                blockStreaming: true,
                roomIntroductions: true
            ),
            chunking: ChannelTextChunkingDefaults(defaultLimit: 5_000, platformLimit: 5_000),
            nativeTransportAvailable: true,
            nativeTransportKind: "messaging-api"
        ),
        "sms": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct], media: true),
            formatProfile: ChannelFormatProfile(mechanism: .plain, chunkLimit: 1_500, hardCap: 1_600),
            chunking: ChannelTextChunkingDefaults(defaultLimit: 1_500, platformLimit: 1_600),
            nativeTransportAvailable: true,
            nativeTransportKind: "twilio"
        ),
        // No outbound chunking: a reply completes one task whole (upstream `deliveryMode: direct`).
        // The 64 KiB `A2A_MESSAGE_MAX_BYTES` is an inbound text cap (`A2AProtocol.extractText`).
        "a2a": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct]),
            nativeTransportAvailable: true,
            nativeTransportKind: "a2a-jsonrpc"
        ),
        "buzz": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.group], threads: true),
            chunking: ChannelTextChunkingDefaults(defaultLimit: 16_000),
            nativeUnavailableReason: "Nostr secp256k1 Schnorr signing is not available in CryptoKit/swift-crypto"
        ),
        "clickclack": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .group],
                threads: true,
                media: true,
                blockStreaming: true
            ),
            nativeUnavailableReason: "Self-hosted bot-token workspace; plugin-only this release"
        ),
        "raft": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct]),
            nativeUnavailableReason: "Requires the Raft CLI wake bridge on the gateway host"
        ),
        "reef": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct], threads: true, blockStreaming: true),
            nativeUnavailableReason:
                "Requires the guarded pinned-model screening pipeline and trust store; protocol crypto is feasible via CryptoKit in a future release"
        ),
        "feishu": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .channel],
                reactions: true,
                edit: true,
                reply: true,
                threads: true,
                media: true,
                ttsVoice: ChannelTTSVoiceDelivery(synthesisTarget: .voiceNote)
            ),
            nativeUnavailableReason: Self.pluginOnlyReason
        ),
        "irc": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct, .group], media: true, blockStreaming: true),
            nativeUnavailableReason: Self.pluginOnlyReason
        ),
        "matrix": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .group, .thread],
                polls: true,
                reactions: true,
                threads: true,
                media: true,
                richMessages: true,
                roomIntroductions: true
            ),
            nativeUnavailableReason: Self.pluginOnlyReason
        ),
        "mattermost": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .channel, .group, .thread],
                reactions: true,
                threads: true,
                media: true,
                nativeCommands: true
            ),
            nativeUnavailableReason: Self.pluginOnlyReason
        ),
        "nextcloud-talk": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .group],
                reactions: true,
                media: true,
                blockStreaming: true
            ),
            nativeUnavailableReason: Self.pluginOnlyReason
        ),
        "nostr": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct]),
            nativeUnavailableReason: Self.pluginOnlyReason
        ),
        "synology-chat": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct], media: true),
            nativeUnavailableReason: Self.pluginOnlyReason
        ),
        "tlon": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .group, .thread],
                reply: true,
                threads: true,
                media: true
            ),
            nativeUnavailableReason: Self.pluginOnlyReason
        ),
        "twitch": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.group]),
            nativeUnavailableReason: Self.pluginOnlyReason
        ),
        "zalo": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct, .group], media: true, blockStreaming: true),
            nativeUnavailableReason: Self.pluginOnlyReason
        ),
        "zalouser": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(
                chatTypes: [.direct, .group],
                reactions: true,
                media: true,
                blockStreaming: true
            ),
            nativeUnavailableReason: Self.pluginOnlyReason
        ),
        "qa-channel": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct, .group]),
            nativeUnavailableReason: "Synthetic QA transport used by upstream automated scenarios"
        ),
        // External plugins define their own capabilities; only the conversation shape is recorded.
        "qqbot": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct, .group]),
            nativeUnavailableReason: Self.externalPluginReason
        ),
        "wecom": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct, .group]),
            nativeUnavailableReason: Self.externalPluginReason
        ),
        "openclaw-weixin": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct]),
            nativeUnavailableReason: Self.externalPluginReason
        ),
        "yuanbao": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct, .group]),
            nativeUnavailableReason: Self.externalPluginReason
        ),
        "openclaw-zaloclawbot": ChannelCatalogTraits(
            capabilities: ChannelCapabilities(chatTypes: [.direct]),
            nativeUnavailableReason: Self.externalPluginReason
        ),
    ]
}
