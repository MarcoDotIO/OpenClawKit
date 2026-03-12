import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit

@Suite("BlueBubbles channel adapter")
struct BlueBubblesChannelAdapterTests {
    actor InboundCollector {
        private(set) var messages: [InboundMessage] = []

        func append(_ message: InboundMessage) {
            self.messages.append(message)
        }

        func snapshot() -> [InboundMessage] {
            self.messages
        }
    }

    actor MockTransport: BlueBubblesHTTPTransport {
        struct RequestRecord: Sendable {
            let method: String
            let path: String
            let url: String
            let body: String
        }

        private(set) var records: [RequestRecord] = []
        var nextStatusCode: Int = 200

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.records.append(
                RequestRecord(
                    method: request.httpMethod ?? "GET",
                    path: request.url?.path ?? "",
                    url: request.url?.absoluteString ?? "",
                    body: String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                )
            )
            return HTTPResponseData(statusCode: self.nextStatusCode, headers: [:], body: Data("{\"ok\":true}".utf8))
        }

        func snapshot() -> [RequestRecord] {
            self.records
        }
    }

    @Test
    func blueBubblesConfigUsesTSStyleKeys() throws {
        let config = OpenClawConfig(
            channels: ChannelsConfig(
                bluebubbles: BlueBubblesChannelConfig(
                    enabled: true,
                    serverURL: "http://bb.example:1234",
                    password: "bluebubbles-password",
                    webhookPath: "/bluebubbles-webhook",
                    defaultChatGUID: "iMessage;-;+15551234567"
                )
            )
        )

        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let channels = json?["channels"] as? [String: Any]
        let bluebubbles = channels?["bluebubbles"] as? [String: Any]

        #expect(bluebubbles?["serverUrl"] as? String == "http://bb.example:1234")
        #expect(bluebubbles?["webhookPath"] as? String == "/bluebubbles-webhook")
        #expect(bluebubbles?["defaultChatGuid"] as? String == "iMessage;-;+15551234567")
    }

    @Test
    func sendPostsToBlueBubblesMessageEndpoint() async throws {
        let transport = MockTransport()
        let adapter = BlueBubblesChannelAdapter(
            config: BlueBubblesChannelConfig(
                enabled: true,
                serverURL: "http://bluebubbles.local:1234",
                password: "secret",
                defaultChatGUID: "iMessage;-;+15551234567"
            ),
            transport: transport
        )

        try await adapter.start()
        try await adapter.send(
            OutboundMessage(channel: .bluebubbles, peerID: "", text: "hello bluebubbles")
        )
        await adapter.stop()

        let records = await transport.snapshot()
        #expect(records.count == 1)
        #expect(records.first?.method == "POST")
        #expect(records.first?.path == "/api/v1/message/text")
        #expect(records.first?.url.contains("password=secret") == true)
        #expect(records.first?.body.contains("\"chatGuid\":\"iMessage;-;+15551234567\"") == true)
        #expect(records.first?.body.contains("\"message\":\"hello bluebubbles\"") == true)
    }

    @Test
    func webhookDeliversInboundMessageAndAttachments() async throws {
        let transport = MockTransport()
        let collector = InboundCollector()
        let adapter = BlueBubblesChannelAdapter(
            config: BlueBubblesChannelConfig(
                enabled: true,
                serverURL: "http://bluebubbles.local:1234",
                password: "secret"
            ),
            transport: transport
        )
        await adapter.setInboundHandler { message in
            await collector.append(message)
        }

        try await adapter.start()
        let payload = Data("""
        {
          "chatGuid": "iMessage;-;+15551234567",
          "from": "+15557654321",
          "text": "hello from bluebubbles",
          "isFromMe": false,
          "attachments": [
            {
              "mimeType": "image/png",
              "base64Data": "aGVsbG8=",
              "fileName": "hello.png"
            }
          ]
        }
        """.utf8)
        try await adapter.handleWebhookEvent(payload, password: "secret")
        await adapter.stop()

        let messages = await collector.snapshot()
        #expect(messages.count == 1)
        #expect(messages.first?.channel == .bluebubbles)
        #expect(messages.first?.accountID == "+15557654321")
        #expect(messages.first?.peerID == "iMessage;-;+15551234567")
        #expect(messages.first?.text == "hello from bluebubbles")
        #expect(messages.first?.attachments.count == 1)
        #expect(messages.first?.attachments.first?.fileName == "hello.png")
    }

    @Test
    func webhookRejectsIncorrectPassword() async throws {
        let adapter = BlueBubblesChannelAdapter(
            config: BlueBubblesChannelConfig(
                enabled: true,
                serverURL: "http://bluebubbles.local:1234",
                password: "secret"
            ),
            transport: MockTransport()
        )

        try await adapter.start()
        do {
            try await adapter.handleWebhookEvent(
                Data("{\"chatGuid\":\"chat\",\"text\":\"hello\",\"isFromMe\":false}".utf8),
                password: "wrong"
            )
            Issue.record("Expected BlueBubbles webhook auth failure")
        } catch {
            #expect(String(describing: error).contains("authentication"))
        }
        await adapter.stop()
    }
}
