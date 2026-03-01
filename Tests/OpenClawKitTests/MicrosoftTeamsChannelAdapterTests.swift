import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit

@Suite("Microsoft Teams channel adapter")
struct MicrosoftTeamsChannelAdapterTests {
    actor InboundCollector {
        private(set) var messages: [InboundMessage] = []

        func append(_ message: InboundMessage) {
            self.messages.append(message)
        }

        func snapshot() -> [InboundMessage] {
            self.messages
        }
    }

    actor MockTeamsTransport: MicrosoftTeamsHTTPTransport {
        struct RequestRecord: Sendable {
            let method: String
            let path: String
            let authorization: String?
            let body: String
        }

        var statusCode = 200
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
            return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: Data("{\"id\":\"ok\"}".utf8))
        }

        func snapshot() -> [RequestRecord] {
            self.records
        }
    }

    @Test
    func sendPostsOutboundTeamsActivity() async throws {
        let transport = MockTeamsTransport()
        let adapter = MicrosoftTeamsChannelAdapter(
            config: MicrosoftTeamsChannelConfig(
                enabled: true,
                botAppID: "bot-app-id",
                botAppPassword: "bot-password",
                defaultConversationID: "conversation-id"
            ),
            transport: transport,
            serviceURL: URL(string: "https://teams.example")!
        )
        try await adapter.start()
        try await adapter.send(
            OutboundMessage(channel: .msteams, accountID: nil, peerID: "", text: "hello teams")
        )
        await adapter.stop()

        let requests = await transport.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.method == "POST")
        #expect(requests.first?.path == "/v3/conversations/conversation-id/activities")
        #expect(requests.first?.authorization == "Bearer bot-password")
        #expect(requests.first?.body.contains("\"text\":\"hello teams\"") == true)
        #expect(requests.first?.body.contains("\"id\":\"bot-app-id\"") == true)
    }

    @Test
    func startFailsWhenBotPasswordMissing() async throws {
        let adapter = MicrosoftTeamsChannelAdapter(
            config: MicrosoftTeamsChannelConfig(
                enabled: true,
                botAppID: "bot-app-id",
                botAppPassword: nil,
                defaultConversationID: "conversation-id"
            ),
            transport: MockTeamsTransport(),
            serviceURL: URL(string: "https://teams.example")!
        )

        do {
            try await adapter.start()
            Issue.record("Expected missing bot password error")
        } catch {
            #expect(String(describing: error).contains("password"))
        }
    }

    @Test
    func webhookDeliversHumanMessageWhenMentionDetected() async throws {
        let collector = InboundCollector()
        let adapter = MicrosoftTeamsChannelAdapter(
            config: MicrosoftTeamsChannelConfig(
                enabled: true,
                botAppID: "bot-app-id",
                botAppPassword: "bot-password",
                defaultConversationID: "conversation-id",
                mentionOnly: true
            ),
            transport: MockTeamsTransport(),
            serviceURL: URL(string: "https://teams.example")!
        )
        await adapter.setInboundHandler { inbound in
            await collector.append(inbound)
        }
        try await adapter.start()

        let mentionPayload = Data("""
        {
          "type": "message",
          "text": "<at>OpenClaw</at> summarize this",
          "from": { "id": "user-id" },
          "conversation": { "id": "conversation-id" },
          "entities": [
            {
              "type": "mention",
              "mentioned": { "id": "bot-app-id" },
              "text": "<at>OpenClaw</at>"
            }
          ]
        }
        """.utf8)
        try await adapter.handleWebhookEvent(mentionPayload)
        await adapter.stop()

        let inbound = await collector.snapshot()
        #expect(inbound.count == 1)
        #expect(inbound.first?.channel == .msteams)
        #expect(inbound.first?.accountID == "user-id")
        #expect(inbound.first?.peerID == "conversation-id")
        #expect(inbound.first?.text == "OpenClaw  summarize this")
    }

    @Test
    func webhookSkipsNonMentionWhenMentionOnlyEnabled() async throws {
        let collector = InboundCollector()
        let adapter = MicrosoftTeamsChannelAdapter(
            config: MicrosoftTeamsChannelConfig(
                enabled: true,
                botAppID: "bot-app-id",
                botAppPassword: "bot-password",
                defaultConversationID: "conversation-id",
                mentionOnly: true
            ),
            transport: MockTeamsTransport(),
            serviceURL: URL(string: "https://teams.example")!
        )
        await adapter.setInboundHandler { inbound in
            await collector.append(inbound)
        }
        try await adapter.start()

        let payload = Data("""
        {
          "type": "message",
          "text": "hello without mention",
          "from": { "id": "user-id" },
          "conversation": { "id": "conversation-id" }
        }
        """.utf8)
        try await adapter.handleWebhookEvent(payload)
        await adapter.stop()

        let inbound = await collector.snapshot()
        #expect(inbound.isEmpty)
    }
}
