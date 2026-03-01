import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit

@Suite("Google Chat channel adapter")
struct GoogleChatChannelAdapterTests {
    actor InboundCollector {
        private(set) var messages: [InboundMessage] = []

        func append(_ message: InboundMessage) {
            self.messages.append(message)
        }

        func snapshot() -> [InboundMessage] {
            self.messages
        }
    }

    actor MockGoogleChatTransport: GoogleChatHTTPTransport {
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
            return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: Data("{\"name\":\"ok\"}".utf8))
        }

        func snapshot() -> [RequestRecord] {
            self.records
        }
    }

    @Test
    func sendPostsToConfiguredDefaultSpace() async throws {
        let transport = MockGoogleChatTransport()
        let adapter = GoogleChatChannelAdapter(
            config: GoogleChatChannelConfig(
                enabled: true,
                bearerToken: "googlechat-token",
                defaultSpaceID: "spaces/AAA"
            ),
            transport: transport,
            baseURL: URL(string: "https://chat.example/v1")!
        )
        try await adapter.start()
        try await adapter.send(
            OutboundMessage(channel: .googlechat, accountID: "users/123", peerID: "", text: "hello google chat")
        )
        await adapter.stop()

        let requests = await transport.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.method == "POST")
        #expect(requests.first?.path == "/v1/spaces/AAA/messages")
        #expect(requests.first?.authorization == "Bearer googlechat-token")
        #expect(requests.first?.body.contains("\"text\":\"hello google chat\"") == true)
    }

    @Test
    func sendUsesThreadPeerIDWhenProvided() async throws {
        let transport = MockGoogleChatTransport()
        let adapter = GoogleChatChannelAdapter(
            config: GoogleChatChannelConfig(
                enabled: true,
                bearerToken: "googlechat-token",
                defaultSpaceID: "spaces/AAA"
            ),
            transport: transport,
            baseURL: URL(string: "https://chat.example/v1")!
        )
        try await adapter.start()
        try await adapter.send(
            OutboundMessage(
                channel: .googlechat,
                accountID: "users/123",
                peerID: "spaces/AAA/threads/BBB",
                text: "thread message"
            )
        )
        await adapter.stop()

        let requests = await transport.snapshot()
        #expect(requests.first?.path == "/v1/spaces/AAA/messages")
        let bodyData = Data((requests.first?.body ?? "").utf8)
        let bodyObject = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let threadName = (bodyObject?["thread"] as? [String: Any])?["name"] as? String
        #expect(threadName == "spaces/AAA/threads/BBB")
    }

    @Test
    func startFailsWhenBearerTokenMissing() async throws {
        let adapter = GoogleChatChannelAdapter(
            config: GoogleChatChannelConfig(
                enabled: true,
                bearerToken: nil,
                defaultSpaceID: "spaces/AAA"
            ),
            transport: MockGoogleChatTransport(),
            baseURL: URL(string: "https://chat.example/v1")!
        )

        do {
            try await adapter.start()
            Issue.record("Expected missing bearer token error")
        } catch {
            #expect(String(describing: error).contains("bearer token"))
        }
    }

    @Test
    func webhookDeliversHumanMessageAndSkipsInvalidTokenAndBotMessages() async throws {
        let collector = InboundCollector()
        let adapter = GoogleChatChannelAdapter(
            config: GoogleChatChannelConfig(
                enabled: true,
                bearerToken: "googlechat-token",
                verificationToken: "verify-token",
                defaultSpaceID: "spaces/AAA"
            ),
            transport: MockGoogleChatTransport(),
            baseURL: URL(string: "https://chat.example/v1")!
        )
        await adapter.setInboundHandler { inbound in
            await collector.append(inbound)
        }
        try await adapter.start()

        let invalidTokenPayload = Data("""
        {
          "type": "MESSAGE",
          "token": "wrong-token",
          "space": { "name": "spaces/AAA" },
          "message": {
            "text": "ignore me",
            "sender": { "name": "users/123", "type": "HUMAN" }
          }
        }
        """.utf8)
        try await adapter.handleWebhookEvent(invalidTokenPayload)

        let botPayload = Data("""
        {
          "type": "MESSAGE",
          "token": "verify-token",
          "space": { "name": "spaces/AAA" },
          "message": {
            "text": "ignore bot",
            "sender": { "name": "users/bot", "type": "BOT" }
          }
        }
        """.utf8)
        try await adapter.handleWebhookEvent(botPayload)

        let humanPayload = Data("""
        {
          "type": "MESSAGE",
          "token": "verify-token",
          "space": { "name": "spaces/AAA" },
          "message": {
            "text": "human message",
            "sender": { "name": "users/123", "type": "HUMAN" },
            "thread": { "name": "spaces/AAA/threads/THREAD-1" }
          }
        }
        """.utf8)
        try await adapter.handleWebhookEvent(humanPayload)
        await adapter.stop()

        let inbound = await collector.snapshot()
        #expect(inbound.count == 1)
        #expect(inbound.first?.channel == .googlechat)
        #expect(inbound.first?.accountID == "users/123")
        #expect(inbound.first?.peerID == "spaces/AAA/threads/THREAD-1")
        #expect(inbound.first?.text == "human message")
    }
}
