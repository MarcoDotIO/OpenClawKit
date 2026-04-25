import Testing
@testable import OpenClawChannels

@Suite("Channel metadata parity")
struct ChannelMetadataParityTests {
    @Test
    func pluginOnlyChannelsAreVisibleButNotNativeTransports() {
        let metadata = Dictionary(
            uniqueKeysWithValues: OpenClawChannelMetadataCatalog.entries.map { entry in
                (entry.id, entry)
            }
        )

        let pluginOnly: [ChannelID] = [
            .feishu,
            .irc,
            .matrix,
            .mattermost,
            .nextcloudTalk,
            .nostr,
            .qqbot,
            .synologyChat,
            .tlon,
            .twitch,
            .zalo,
            .zalouser,
            .qaChannel,
        ]
        for channelID in pluginOnly {
            #expect(metadata[channelID]?.nativeTransportAvailable == false)
        }

        #expect(metadata[.telegram]?.nativeTransportAvailable == true)
        #expect(metadata[.webchat]?.nativeTransportAvailable == true)
    }
}
