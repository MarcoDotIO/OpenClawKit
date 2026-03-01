import Testing
@testable import OpenClawKit

@Suite("iMessage channel adapter")
struct IMessageChannelAdapterTests {
    @Test
    func startFailsWhenSimulationFallbackDisabled() async throws {
        let adapter = IMessageChannelAdapter(
            config: IMessageChannelConfig(
                enabled: true,
                defaultHandle: "user@icloud.com",
                allowUnsupportedPlatformSimulation: false
            )
        )

        do {
            try await adapter.start()
            Issue.record("Expected iMessage start to fail when simulation is disabled")
        } catch {
            let description = String(describing: error)
            #expect(description.contains("simulation"))
        }
    }

    @Test
    func simulatedModeCapturesOutboundMessage() async throws {
        let adapter = IMessageChannelAdapter(
            config: IMessageChannelConfig(
                enabled: true,
                defaultHandle: "user@icloud.com",
                allowUnsupportedPlatformSimulation: true
            )
        )
        try await adapter.start()
        try await adapter.send(
            OutboundMessage(channel: .imessage, accountID: nil, peerID: "friend@icloud.com", text: "hello imessage")
        )
        await adapter.stop()

        let sent = await adapter.simulatedOutboundHistory()
        #expect(sent.count == 1)
        #expect(sent.first?.channel == .imessage)
        #expect(sent.first?.peerID == "friend@icloud.com")
        #expect(sent.first?.text == "hello imessage")
    }

    @Test
    func simulatedModeFallsBackToDefaultHandleWhenPeerMissing() async throws {
        let adapter = IMessageChannelAdapter(
            config: IMessageChannelConfig(
                enabled: true,
                defaultHandle: "fallback@icloud.com",
                allowUnsupportedPlatformSimulation: true
            )
        )
        try await adapter.start()
        try await adapter.send(
            OutboundMessage(channel: .imessage, accountID: nil, peerID: "", text: "fallback route")
        )
        await adapter.stop()

        let sent = await adapter.simulatedOutboundHistory()
        #expect(sent.count == 1)
        #expect(sent.first?.peerID == "fallback@icloud.com")
        #expect(sent.first?.text == "fallback route")
    }

    @Test
    func sendFailsWhenNoPeerAndNoDefaultHandle() async throws {
        let adapter = IMessageChannelAdapter(
            config: IMessageChannelConfig(
                enabled: true,
                defaultHandle: nil,
                allowUnsupportedPlatformSimulation: true
            )
        )
        try await adapter.start()
        do {
            try await adapter.send(
                OutboundMessage(channel: .imessage, accountID: nil, peerID: "", text: "no recipient")
            )
            Issue.record("Expected send to fail without recipient")
        } catch {
            #expect(String(describing: error).contains("recipient"))
        }
        await adapter.stop()
    }
}
