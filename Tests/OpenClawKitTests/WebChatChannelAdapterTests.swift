import Foundation
import Testing
@testable import OpenClawKit

@Suite("WebChat channel adapter")
struct WebChatChannelAdapterTests {
    actor InboundCollector {
        private(set) var messages: [InboundMessage] = []

        func append(_ message: InboundMessage) {
            self.messages.append(message)
        }

        func snapshot() -> [InboundMessage] {
            self.messages
        }
    }

    @Test
    func webhookDeliversInboundPayloadWithAttachment() async throws {
        let collector = InboundCollector()
        let adapter = WebChatChannelAdapter(
            config: WebChatChannelConfig(enabled: true, sharedSecret: "secret-123", transcriptLimit: 50)
        )
        await adapter.setInboundHandler { inbound in
            await collector.append(inbound)
        }
        try await adapter.start()

        let payload = Data("""
        {
          "sessionID": "session-1",
          "userID": "web-user-1",
          "text": "hello from webchat",
          "attachments": [
            {
              "id": "att-1",
              "mimeType": "text/plain",
              "base64Data": "SGVsbG8gQXR0YWNobWVudA==",
              "fileName": "note.txt",
              "metadata": { "source": "ui-upload" }
            }
          ]
        }
        """.utf8)
        try await adapter.handleWebhookEvent(payload, sharedSecret: "secret-123")
        await adapter.stop()

        let inbound = await collector.snapshot()
        #expect(inbound.count == 1)
        #expect(inbound.first?.channel == .webchat)
        #expect(inbound.first?.accountID == "web-user-1")
        #expect(inbound.first?.peerID == "session-1")
        #expect(inbound.first?.attachments.count == 1)
        #expect(inbound.first?.attachments.first?.fileName == "note.txt")

        let transcript = await adapter.transcript(for: "session-1")
        #expect(transcript.count == 1)
        #expect(transcript.first?.direction == .inbound)
    }

    @Test
    func webhookRejectsInvalidSharedSecret() async throws {
        let adapter = WebChatChannelAdapter(
            config: WebChatChannelConfig(enabled: true, sharedSecret: "expected-secret")
        )
        try await adapter.start()

        let payload = Data("""
        {
          "sessionID": "session-1",
          "userID": "web-user-1",
          "text": "should fail"
        }
        """.utf8)
        do {
            try await adapter.handleWebhookEvent(payload, sharedSecret: "wrong-secret")
            Issue.record("Expected shared secret validation to fail")
        } catch {
            #expect(String(describing: error).contains("shared secret"))
        }
        await adapter.stop()
    }

    @Test
    func transcriptRetentionUsesConfiguredLimit() async throws {
        let adapter = WebChatChannelAdapter(
            config: WebChatChannelConfig(enabled: true, transcriptLimit: 2)
        )
        try await adapter.start()

        try await adapter.send(
            OutboundMessage(channel: .webchat, accountID: "assistant", peerID: "session-1", text: "one")
        )
        try await adapter.send(
            OutboundMessage(channel: .webchat, accountID: "assistant", peerID: "session-1", text: "two")
        )
        try await adapter.send(
            OutboundMessage(channel: .webchat, accountID: "assistant", peerID: "session-1", text: "three")
        )
        await adapter.stop()

        let transcript = await adapter.transcript(for: "session-1")
        #expect(transcript.count == 2)
        #expect(transcript.first?.text == "two")
        #expect(transcript.last?.text == "three")
    }
}
