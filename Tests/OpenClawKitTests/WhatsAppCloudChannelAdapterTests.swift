import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit

@Suite("WhatsApp Cloud channel adapter")
struct WhatsAppCloudChannelAdapterTests {
    actor InboundCollector {
        private(set) var messages: [InboundMessage] = []

        func append(_ message: InboundMessage) {
            self.messages.append(message)
        }

        func snapshot() -> [InboundMessage] {
            self.messages
        }
    }

    actor DiagnosticCollector {
        private(set) var events: [RuntimeDiagnosticEvent] = []

        func append(_ event: RuntimeDiagnosticEvent) {
            self.events.append(event)
        }

        func names() -> [String] {
            self.events.map(\.name)
        }
    }

    actor MockWhatsAppTransport: WhatsAppCloudHTTPTransport {
        struct RequestRecord: Sendable {
            let method: String
            let path: String
            let authorization: String?
            let body: String
        }

        var statusCode: Int = 200
        private(set) var records: [RequestRecord] = []

        func setStatusCode(_ statusCode: Int) {
            self.statusCode = statusCode
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.records.append(
                RequestRecord(
                    method: request.httpMethod ?? "GET",
                    path: request.url?.path ?? "",
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    body: String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                )
            )
            return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: Data("{\"messages\":[]}".utf8))
        }

        func snapshot() -> [RequestRecord] {
            self.records
        }
    }

    @Test
    func sendPostsOutboundCloudAPIMessage() async throws {
        let transport = MockWhatsAppTransport()
        let adapter = WhatsAppCloudChannelAdapter(
            config: WhatsAppCloudChannelConfig(
                enabled: true,
                accessToken: "wa-token",
                phoneNumberID: "123456",
                webhookVerifyToken: "verify"
            ),
            transport: transport,
            baseURL: URL(string: "https://graph.example")!
        )
        try await adapter.start()
        try await adapter.send(
            OutboundMessage(channel: .whatsapp, accountID: "123456", peerID: "15551234567", text: "hello from openclaw")
        )
        await adapter.stop()

        let requests = await transport.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.method == "POST")
        #expect(requests.first?.path.contains("/v20.0/123456/messages") == true)
        #expect(requests.first?.authorization == "Bearer wa-token")
        #expect(requests.first?.body.contains("\"messaging_product\":\"whatsapp\"") == true)
        #expect(requests.first?.body.contains("\"to\":\"15551234567\"") == true)
    }

    @Test
    func startFailsWhenAccessTokenMissing() async throws {
        let adapter = WhatsAppCloudChannelAdapter(
            config: WhatsAppCloudChannelConfig(
                enabled: true,
                accessToken: nil,
                phoneNumberID: "123456"
            ),
            transport: MockWhatsAppTransport(),
            baseURL: URL(string: "https://graph.example")!
        )

        do {
            try await adapter.start()
            Issue.record("Expected invalid configuration error")
        } catch {
            #expect(String(describing: error).contains("access token"))
        }
    }

    @Test
    func webhookVerificationEchoesChallengeWhenTokenMatches() async throws {
        let adapter = WhatsAppCloudChannelAdapter(
            config: WhatsAppCloudChannelConfig(
                enabled: true,
                accessToken: "wa-token",
                phoneNumberID: "123456",
                webhookVerifyToken: "verify"
            ),
            transport: MockWhatsAppTransport(),
            baseURL: URL(string: "https://graph.example")!
        )
        #expect(await adapter.handleWebhookVerification(mode: "subscribe", token: "verify", challenge: "1234") == "1234")
        #expect(await adapter.handleWebhookVerification(mode: "subscribe", token: "bad", challenge: "1234") == nil)
    }

    @Test
    func webhookEventDeliversInboundTextMessages() async throws {
        let collector = InboundCollector()
        let adapter = WhatsAppCloudChannelAdapter(
            config: WhatsAppCloudChannelConfig(
                enabled: true,
                accessToken: "wa-token",
                phoneNumberID: "123456",
                webhookVerifyToken: "verify"
            ),
            transport: MockWhatsAppTransport(),
            baseURL: URL(string: "https://graph.example")!
        )
        await adapter.setInboundHandler { message in
            await collector.append(message)
        }
        try await adapter.start()

        let webhook = Data("""
        {
          "entry": [
            {
              "changes": [
                {
                  "value": {
                    "metadata": { "phone_number_id": "123456" },
                    "contacts": [{ "wa_id": "15550001111" }],
                    "messages": [
                      {
                        "from": "15550001111",
                        "type": "text",
                        "text": { "body": "weather in milan?" }
                      }
                    ]
                  }
                }
              ]
            }
          ]
        }
        """.utf8)
        try await adapter.handleWebhookEvent(webhook)
        await adapter.stop()

        let messages = await collector.snapshot()
        #expect(messages.count == 1)
        #expect(messages.first?.channel == .whatsapp)
        #expect(messages.first?.accountID == "123456")
        #expect(messages.first?.peerID == "15550001111")
        #expect(messages.first?.text == "weather in milan?")
    }

    @Test
    func webhookEventSkipsDuplicatesSupportsButtonPayloadsAndEmitsDiagnostics() async throws {
        let inboundCollector = InboundCollector()
        let diagnostics = DiagnosticCollector()
        let adapter = WhatsAppCloudChannelAdapter(
            config: WhatsAppCloudChannelConfig(
                enabled: true,
                accessToken: "wa-token",
                phoneNumberID: "123456",
                webhookVerifyToken: "verify"
            ),
            transport: MockWhatsAppTransport(),
            baseURL: URL(string: "https://graph.example")!,
            diagnosticsSink: { event in
                await diagnostics.append(event)
            }
        )
        await adapter.setInboundHandler { message in
            await inboundCollector.append(message)
        }
        try await adapter.start()

        let webhook = Data("""
        {
          "entry": [{
            "changes": [{
              "value": {
                "metadata": { "phone_number_id": "123456" },
                "contacts": [{ "wa_id": "15550001111" }],
                "statuses": [{ "id": "wamid-status-1", "status": "delivered", "recipient_id": "15550001111" }],
                "messages": [
                  {
                    "id": "wamid-1",
                    "from": "15550001111",
                    "type": "text",
                    "text": { "body": "first payload" }
                  },
                  {
                    "id": "wamid-1",
                    "from": "15550001111",
                    "type": "text",
                    "text": { "body": "duplicate payload" }
                  },
                  {
                    "id": "wamid-2",
                    "from": "15550001111",
                    "type": "image"
                  },
                  {
                    "id": "wamid-3",
                    "from": "15550001111",
                    "type": "button",
                    "button": { "text": "Button tap value" }
                  }
                ]
              }
            }]
          }]
        }
        """.utf8)
        try await adapter.handleWebhookEvent(webhook)
        await adapter.stop()

        let inbound = await inboundCollector.snapshot()
        #expect(inbound.count == 2)
        #expect(inbound.map(\.text) == ["first payload", "Button tap value"])

        let names = await diagnostics.names()
        #expect(names.contains("channel.whatsapp.webhook.status"))
        #expect(names.contains("channel.whatsapp.webhook.ignored-duplicate"))
        #expect(names.contains("channel.whatsapp.webhook.ignored-empty"))
        #expect(names.contains("channel.whatsapp.webhook.delivered"))
    }

    @Test
    func webhookEventSkipsMetadataPhoneNumberMismatch() async throws {
        let inboundCollector = InboundCollector()
        let diagnostics = DiagnosticCollector()
        let adapter = WhatsAppCloudChannelAdapter(
            config: WhatsAppCloudChannelConfig(
                enabled: true,
                accessToken: "wa-token",
                phoneNumberID: "123456",
                webhookVerifyToken: "verify"
            ),
            transport: MockWhatsAppTransport(),
            baseURL: URL(string: "https://graph.example")!,
            diagnosticsSink: { event in
                await diagnostics.append(event)
            }
        )
        await adapter.setInboundHandler { message in
            await inboundCollector.append(message)
        }
        try await adapter.start()

        let webhook = Data("""
        {
          "entry": [{
            "changes": [{
              "value": {
                "metadata": { "phone_number_id": "999999" },
                "messages": [{
                  "id": "wamid-44",
                  "from": "15550002222",
                  "type": "text",
                  "text": { "body": "should not route" }
                }]
              }
            }]
          }]
        }
        """.utf8)
        try await adapter.handleWebhookEvent(webhook)
        await adapter.stop()

        let inbound = await inboundCollector.snapshot()
        #expect(inbound.isEmpty)
        let names = await diagnostics.names()
        #expect(names.contains("channel.whatsapp.webhook.ignored-account-mismatch"))
    }

    @Test
    func sendFailureEmitsDiagnostics() async throws {
        let transport = MockWhatsAppTransport()
        await transport.setStatusCode(500)
        let diagnostics = DiagnosticCollector()
        let adapter = WhatsAppCloudChannelAdapter(
            config: WhatsAppCloudChannelConfig(
                enabled: true,
                accessToken: "wa-token",
                phoneNumberID: "123456",
                webhookVerifyToken: "verify"
            ),
            transport: transport,
            baseURL: URL(string: "https://graph.example")!,
            diagnosticsSink: { event in
                await diagnostics.append(event)
            }
        )
        try await adapter.start()
        do {
            try await adapter.send(
                OutboundMessage(channel: .whatsapp, accountID: "123456", peerID: "15551234567", text: "hello from openclaw")
            )
            Issue.record("Expected send failure")
        } catch {
            #expect(String(describing: error).contains("status 500"))
        }
        await adapter.stop()

        let names = await diagnostics.names()
        #expect(names.contains("channel.whatsapp.send.started"))
        #expect(names.contains("channel.whatsapp.send.failed"))
    }
}
