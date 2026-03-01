import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit

@Suite("Slack channel adapter")
struct SlackChannelAdapterTests {
    actor InboundCollector {
        private(set) var messages: [InboundMessage] = []

        func append(_ message: InboundMessage) {
            self.messages.append(message)
        }

        func snapshot() -> [InboundMessage] {
            self.messages
        }
    }

    actor MockSlackTransport: SlackHTTPTransport {
        struct RequestRecord: Sendable {
            let method: String
            let path: String
            let query: String?
            let authorization: String?
            let body: String
        }

        private var responsesByPath: [String: [HTTPResponseData]] = [:]
        private var defaultResponse = HTTPResponseData(
            statusCode: 200,
            headers: [:],
            body: Data("{\"ok\":true}".utf8)
        )
        private(set) var records: [RequestRecord] = []

        func enqueue(path: String, response: HTTPResponseData) {
            var queue = self.responsesByPath[path] ?? []
            queue.append(response)
            self.responsesByPath[path] = queue
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.records.append(
                RequestRecord(
                    method: request.httpMethod ?? "GET",
                    path: request.url?.path ?? "",
                    query: request.url?.query,
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    body: String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                )
            )
            let path = request.url?.path ?? ""
            if var queue = self.responsesByPath[path], !queue.isEmpty {
                let response = queue.removeFirst()
                self.responsesByPath[path] = queue
                return response
            }
            return self.defaultResponse
        }

        func snapshot() -> [RequestRecord] {
            self.records
        }
    }

    @Test
    func sendPostsOutboundMessageUsingBotToken() async throws {
        let transport = MockSlackTransport()
        await transport.enqueue(
            path: "/api/auth.test",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("{\"ok\":true,\"user_id\":\"U_BOT\"}".utf8)
            )
        )
        await transport.enqueue(
            path: "/api/chat.postMessage",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("{\"ok\":true}".utf8)
            )
        )
        let adapter = SlackChannelAdapter(
            config: SlackChannelConfig(
                enabled: true,
                botToken: "xoxb-token",
                defaultChannelID: "C123"
            ),
            transport: transport,
            baseURL: URL(string: "https://slack.example/api")!
        )
        try await adapter.start()
        try await adapter.send(
            OutboundMessage(channel: .slack, accountID: "U123", peerID: "C999", text: "hello slack")
        )
        await adapter.stop()

        let requests = await transport.snapshot()
        let sendRequest = requests.first(where: { $0.path == "/api/chat.postMessage" })
        #expect(sendRequest?.method == "POST")
        #expect(sendRequest?.authorization == "Bearer xoxb-token")
        #expect(sendRequest?.body.contains("\"channel\":\"C999\"") == true)
        #expect(sendRequest?.body.contains("\"text\":\"hello slack\"") == true)
    }

    @Test
    func startFailsWhenBotTokenMissing() async throws {
        let adapter = SlackChannelAdapter(
            config: SlackChannelConfig(
                enabled: true,
                botToken: nil,
                defaultChannelID: "C123"
            ),
            transport: MockSlackTransport(),
            baseURL: URL(string: "https://slack.example/api")!
        )

        do {
            try await adapter.start()
            Issue.record("Expected missing token configuration error")
        } catch {
            #expect(String(describing: error).contains("bot token"))
        }
    }

    @Test
    func pollDeliversMentionAndUsesThreadTSAsPeerID() async throws {
        let transport = MockSlackTransport()
        await transport.enqueue(
            path: "/api/auth.test",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("{\"ok\":true,\"user_id\":\"U_BOT\"}".utf8)
            )
        )
        await transport.enqueue(
            path: "/api/conversations.history",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("{\"ok\":true,\"messages\":[]}".utf8)
            )
        )
        await transport.enqueue(
            path: "/api/conversations.history",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("""
                {
                  "ok": true,
                  "messages": [
                    {
                      "type": "message",
                      "user": "U123",
                      "text": "<@U_BOT> can you summarize this thread?",
                      "ts": "1001.000200",
                      "thread_ts": "1000.000100"
                    }
                  ]
                }
                """.utf8)
            )
        )

        let collector = InboundCollector()
        let adapter = SlackChannelAdapter(
            config: SlackChannelConfig(
                enabled: true,
                botToken: "xoxb-token",
                defaultChannelID: "C123",
                mentionOnly: true
            ),
            transport: transport,
            baseURL: URL(string: "https://slack.example/api")!,
            pollIntervalMs: 250
        )
        await adapter.setInboundHandler { inbound in
            await collector.append(inbound)
        }
        try await adapter.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        await adapter.stop()

        let inbound = await collector.snapshot()
        #expect(inbound.count == 1)
        #expect(inbound.first?.channel == .slack)
        #expect(inbound.first?.accountID == "U123")
        #expect(inbound.first?.peerID == "1000.000100")
        #expect(inbound.first?.text == "can you summarize this thread?")
    }

    @Test
    func pollSkipsNonMentionWhenMentionOnlyEnabled() async throws {
        let transport = MockSlackTransport()
        await transport.enqueue(
            path: "/api/auth.test",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("{\"ok\":true,\"user_id\":\"U_BOT\"}".utf8)
            )
        )
        await transport.enqueue(
            path: "/api/conversations.history",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("{\"ok\":true,\"messages\":[]}".utf8)
            )
        )
        await transport.enqueue(
            path: "/api/conversations.history",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("""
                {
                  "ok": true,
                  "messages": [
                    {
                      "type": "message",
                      "user": "U123",
                      "text": "hello without mention",
                      "ts": "1001.000200"
                    }
                  ]
                }
                """.utf8)
            )
        )

        let collector = InboundCollector()
        let adapter = SlackChannelAdapter(
            config: SlackChannelConfig(
                enabled: true,
                botToken: "xoxb-token",
                defaultChannelID: "C123",
                mentionOnly: true
            ),
            transport: transport,
            baseURL: URL(string: "https://slack.example/api")!,
            pollIntervalMs: 250
        )
        await adapter.setInboundHandler { inbound in
            await collector.append(inbound)
        }
        try await adapter.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        await adapter.stop()

        let inbound = await collector.snapshot()
        #expect(inbound.isEmpty)
    }

    @Test
    func pollProcessesNonMentionWhenMentionOnlyDisabled() async throws {
        let transport = MockSlackTransport()
        await transport.enqueue(
            path: "/api/auth.test",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("{\"ok\":true,\"user_id\":\"U_BOT\"}".utf8)
            )
        )
        await transport.enqueue(
            path: "/api/conversations.history",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("{\"ok\":true,\"messages\":[]}".utf8)
            )
        )
        await transport.enqueue(
            path: "/api/conversations.history",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("""
                {
                  "ok": true,
                  "messages": [
                    {
                      "type": "message",
                      "user": "U123",
                      "text": "hello without mention",
                      "ts": "1001.000200"
                    }
                  ]
                }
                """.utf8)
            )
        )

        let collector = InboundCollector()
        let adapter = SlackChannelAdapter(
            config: SlackChannelConfig(
                enabled: true,
                botToken: "xoxb-token",
                defaultChannelID: "C123",
                mentionOnly: false
            ),
            transport: transport,
            baseURL: URL(string: "https://slack.example/api")!,
            pollIntervalMs: 250
        )
        await adapter.setInboundHandler { inbound in
            await collector.append(inbound)
        }
        try await adapter.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        await adapter.stop()

        let inbound = await collector.snapshot()
        #expect(inbound.count == 1)
        #expect(inbound.first?.accountID == "U123")
        #expect(inbound.first?.peerID == "C123")
        #expect(inbound.first?.text == "hello without mention")
    }
}
