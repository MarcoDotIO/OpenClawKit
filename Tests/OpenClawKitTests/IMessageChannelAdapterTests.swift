import Testing
@testable import OpenClawKit

@Suite("iMessage channel adapter")
struct IMessageChannelAdapterTests {
    actor InboundCollector {
        private(set) var messages: [InboundMessage] = []

        func append(_ message: InboundMessage) {
            self.messages.append(message)
        }

        func snapshot() -> [InboundMessage] {
            self.messages
        }
    }

    actor MockTransport: IMessageTransport {
        private(set) var sentMessages: [IMessageTransportMessage] = []
        var shouldFail = false

        func send(_ message: IMessageTransportMessage) async throws {
            if self.shouldFail {
                throw OpenClawCoreError.unavailable("native send failed")
            }
            self.sentMessages.append(message)
        }

        func setShouldFail(_ value: Bool) {
            self.shouldFail = value
        }

        func snapshot() -> [IMessageTransportMessage] {
            self.sentMessages
        }
    }

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
    func nativeTransportIsPreferredWhenAvailable() async throws {
        let transport = MockTransport()
        let adapter = IMessageChannelAdapter(
            config: IMessageChannelConfig(
                enabled: true,
                defaultHandle: "user@icloud.com",
                allowUnsupportedPlatformSimulation: false
            ),
            transport: transport
        )

        try await adapter.start()
        try await adapter.send(
            OutboundMessage(channel: .imessage, accountID: "primary", peerID: "friend@icloud.com", text: "native hello")
        )
        await adapter.stop()

        let sent = await transport.snapshot()
        let simulated = await adapter.simulatedOutboundHistory()
        #expect(sent.count == 1)
        #expect(sent.first?.peerID == "friend@icloud.com")
        #expect(sent.first?.text == "native hello")
        #expect(sent.first?.accountID == "primary")
        #expect(simulated.isEmpty)
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

    @Test
    func reflectedInboundMessageIsDroppedOnceAfterConfirmedSend() async throws {
        let transport = MockTransport()
        let collector = InboundCollector()
        let adapter = IMessageChannelAdapter(
            config: IMessageChannelConfig(
                enabled: true,
                defaultHandle: "user@icloud.com",
                allowUnsupportedPlatformSimulation: false
            ),
            transport: transport
        )
        await adapter.setInboundHandler { message in
            await collector.append(message)
        }

        try await adapter.start()
        try await adapter.send(
            OutboundMessage(channel: .imessage, peerID: "friend@icloud.com", text: "mirror this")
        )
        try await adapter.handleInboundEvent(
            IMessageInboundEvent(peerID: "friend@icloud.com", text: "mirror this")
        )
        try await adapter.handleInboundEvent(
            IMessageInboundEvent(peerID: "friend@icloud.com", text: "mirror this")
        )
        await adapter.stop()

        let messages = await collector.snapshot()
        #expect(messages.count == 1)
        #expect(messages.first?.text == "mirror this")
    }

    @Test
    func reflectedInboundMessageIsNotDroppedWhenOutboundSendFails() async throws {
        let transport = MockTransport()
        await transport.setShouldFail(true)
        let collector = InboundCollector()
        let adapter = IMessageChannelAdapter(
            config: IMessageChannelConfig(
                enabled: true,
                defaultHandle: "user@icloud.com",
                allowUnsupportedPlatformSimulation: false
            ),
            transport: transport
        )
        await adapter.setInboundHandler { message in
            await collector.append(message)
        }

        try await adapter.start()
        do {
            try await adapter.send(
                OutboundMessage(channel: .imessage, peerID: "friend@icloud.com", text: "failed send")
            )
            Issue.record("Expected native transport send to fail")
        } catch {}
        try await adapter.handleInboundEvent(
            IMessageInboundEvent(peerID: "friend@icloud.com", text: "failed send")
        )
        await adapter.stop()

        let messages = await collector.snapshot()
        #expect(messages.count == 1)
        #expect(messages.first?.text == "failed send")
    }
}
