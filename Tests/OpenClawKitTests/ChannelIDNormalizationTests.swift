import Testing
@testable import OpenClawChannels

@Suite("Channel catalog sync and id normalization")
struct ChannelIDNormalizationTests {
    @Test
    func everyGeneratedRowMapsToAChannelID() {
        for row in OpenClawChannelMetadataCatalog.generatedRows {
            #expect(ChannelID(rawValue: row.id) != nil, "missing ChannelID case for \(row.id)")
        }
        #expect(OpenClawChannelMetadataCatalog.generatedRows.count == ChannelID.allCases.count)
        #expect(OpenClawChannelMetadataCatalog.upstreamVersion == "2026.9.6")
        #expect(OpenClawChannelMetadataCatalog.referenceCommit == "eb377ac59e")
    }

    @Test
    func everyChannelHasACapabilitiesRow() {
        for id in ChannelID.allCases {
            #expect(ChannelCatalogTraitsTable.rows[id.rawValue] != nil, "missing capabilities row for \(id.rawValue)")
        }
    }

    @Test(arguments: [
        ("lark", ChannelID.feishu),
        ("gchat", .googlechat),
        ("google-chat", .googlechat),
        ("imsg", .imessage),
        ("teams", .msteams),
        ("nc", .nextcloudTalk),
        ("nc-talk", .nextcloudTalk),
        ("zl", .zalo),
        ("zlu", .zalouser),
        ("wechat", .openclawWeixin),
        ("weixin", .openclawWeixin),
        ("微信", .openclawWeixin),
        ("元宝", .yuanbao),
        ("yb", .yuanbao),
        ("tencent-yuanbao", .yuanbao),
        ("qywx", .wecom),
        ("wework", .wecom),
        ("enterprise-wechat", .wecom),
        ("zaloclawbot", .openclawZaloClawbot),
        ("zalo-clawbot", .openclawZaloClawbot),
        ("twitch-chat", .twitch),
        ("internet-relay-chat", .irc),
        ("bb", .bluebubbles),
        ("  Telegram ", .telegram),
        ("SMS", .sms),
        ("openclaw-weixin", .openclawWeixin),
    ])
    func aliasesResolve(alias: String, expected: ChannelID) {
        #expect(ChannelID(normalizing: alias) == expected)
        #expect(OpenClawChannelMetadataCatalog.entry(forAlias: alias)?.id == expected)
    }

    @Test
    func unknownIDsDoNotResolve() {
        #expect(ChannelID(normalizing: "") == nil)
        #expect(ChannelID(normalizing: "facetime") == nil)
        #expect(ChannelID(normalizing: "whatsappCloud") == nil)
    }

    @Test
    func orderedEntriesFollowUpstreamOrderThenID() {
        let ordered = OpenClawChannelMetadataCatalog.orderedEntries
        #expect(ordered.first?.id == .feishu)
        for (lhs, rhs) in zip(ordered, ordered.dropFirst()) {
            let lo = lhs.order ?? Int.max
            let ro = rhs.order ?? Int.max
            #expect(lo < ro || (lo == ro && lhs.id.rawValue < rhs.id.rawValue))
        }
        #expect(OpenClawChannelMetadataCatalog.visibleEntries.contains { $0.id == .qaChannel } == false)
    }

    @Test
    func metadataMatchesUpstreamLabelsAndSymbols() {
        let telegram = ChannelID.telegram.metadata
        #expect(telegram.selectionLabel == "Telegram (Bot API)")
        #expect(telegram.detailLabel == "Telegram Bot")
        #expect(telegram.systemImage == "paperplane")
        #expect(telegram.distribution == .bundled)
        #expect(telegram.packageName == "@openclaw/telegram")

        #expect(ChannelID.zalouser.metadata.label == "Zalo Personal")
        #expect(ChannelID.webchat.metadata.docsPath == "/web/webchat")
        #expect(ChannelID.webchat.metadata.distribution == .core)
        #expect(ChannelID.googlechat.metadata.order == 55)
        #expect(ChannelID.googlechat.metadata.aliases.contains("gchat"))
        #expect(ChannelID.imessage.metadata.aliases == ["imsg"])
        #expect(ChannelID.qqbot.metadata.status == .external)
        #expect(ChannelID.qqbot.metadata.packageName == "@tencent-connect/openclaw-qqbot")
        #expect(ChannelID.qqbot.metadata.legacyPackageNames.contains("@openclaw/qqbot"))
        #expect(ChannelID.qaChannel.metadata.hidden)
        #expect(ChannelID.sms.metadata.selectionLabel == "SMS (Twilio)")
        #expect(ChannelID.clickclack.metadata.systemImage == "bubble.left.and.bubble.right")
        #expect(ChannelID.whatsapp.metadata.nativeTransportKind == "cloud-api")
    }

    @Test
    func blueBubblesIsRemovedWithIMessageReplacement() {
        #expect(ChannelID.bluebubbles.isRemovedUpstream)
        #expect(
            ChannelID.bluebubbles.metadata.status
                == .removed(replacement: .imessage, migrationDocsPath: "/channels/imessage-from-bluebubbles")
        )
        #expect(ChannelID.imessage.isRemovedUpstream == false)
    }

    @Test
    func pluginOnlyChannelsExplainMissingNativeTransport() {
        let pluginOnly: [ChannelID] = [.buzz, .raft, .reef, .clickclack, .openclawWeixin, .wecom, .yuanbao, .openclawZaloClawbot, .qqbot]
        for id in pluginOnly {
            #expect(id.metadata.nativeTransportAvailable == false)
            #expect(id.metadata.nativeUnavailableReason?.isEmpty == false)
        }
        #expect(ChannelID.buzz.metadata.nativeUnavailableReason?.contains("Schnorr") == true)
        #expect(ChannelID.telegram.metadata.nativeUnavailableReason == nil)
    }

    @Test
    func capabilitiesAndChunkDefaultsMatchUpstream() {
        #expect(ChannelID.googlechat.metadata.textChunking?.unit == .bytes)
        #expect(ChannelID.googlechat.metadata.defaultTextChunkLimit == 32_000)
        #expect(ChannelID.discord.metadata.textChunking?.maxLines == 17)
        #expect(ChannelID.telegram.metadata.textChunking?.effectiveLimit(richMessages: true) == 32_768)
        #expect(ChannelID.telegram.metadata.textChunking?.effectiveLimit(configured: 9_000) == 4_096)
        #expect(ChannelID.sms.metadata.textChunking?.effectiveLimit() == 1_500)
        #expect(ChannelID.imessage.metadata.capabilities.ttsVoice?.preferAudioFileFormat == "caf")
        #expect(ChannelID.imessage.metadata.capabilities.nativePolls)
        #expect(ChannelID.slack.metadata.formatProfile?.support(for: .underline) == .strip)
        #expect(ChannelID.slack.metadata.blockStreamingCoalesceDefaults == ChannelBlockStreamingCoalesceDefaults(minChars: 1_500, idleMs: 1_000))
        #expect(ChannelID.buzz.metadata.capabilities.chatTypes == [.group])
        let missing = ChannelID.sms.metadata.capabilities.requiredForDelivery(hasAttachments: true, replyToID: "1")
        #expect(missing == [.reply])
    }
}
