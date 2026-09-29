import Foundation
@testable import OpenClawChannels
import OpenClawCore
import Testing

@Suite("Channel adapters report unconfigured status")
struct ChannelConfigurationStatusTests {
    @Test
    func adaptersWithoutCredentialsReportUnconfiguredReasons() {
        let adapters: [any ChannelConfigurationReporting] = [
            TelegramChannelAdapter(config: TelegramChannelConfig(enabled: true)),
            DiscordChannelAdapter(config: DiscordChannelConfig(enabled: true)),
            SlackChannelAdapter(config: SlackChannelConfig(enabled: true)),
            MicrosoftTeamsChannelAdapter(config: MicrosoftTeamsChannelConfig(enabled: true)),
            GoogleChatChannelAdapter(config: GoogleChatChannelConfig(enabled: true)),
            WhatsAppCloudChannelAdapter(config: WhatsAppCloudChannelConfig(enabled: true)),
            SMSChannelAdapter(config: SMSChannelConfig(enabled: true), environment: [:]),
            LineChannelAdapter(config: LineChannelConfig(enabled: true)),
            A2AChannelAdapter(config: A2AChannelConfig(enabled: true)),
        ]
        for adapter in adapters {
            #expect(adapter.configurationStatus.isConfigured == false, "\(adapter.id.rawValue) should be unconfigured")
            #expect(adapter.configurationStatus.reason?.isEmpty == false)
        }
    }

    @Test
    func registryRecordsUnconfiguredReasonInsteadOfThrowing() async throws {
        let registry = ChannelRegistry()
        await registry.register(LineChannelAdapter(config: LineChannelConfig(enabled: true)))
        try await registry.start(id: .line)
        let state = await registry.runtimeState(for: .line)
        #expect(state.running == false)
        #expect(state.unconfiguredReason == LineChannelConfig.unconfiguredReason)

        await registry.register(WhatsAppCloudChannelAdapter(config: WhatsAppCloudChannelConfig(enabled: true)))
        try await registry.start(id: .whatsapp)
        #expect(await registry.runtimeState(for: .whatsapp).unconfiguredReason == "WhatsApp Cloud requires accessToken and phoneNumberId.")
    }
}
