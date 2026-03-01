import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit

@Suite("Signal channel adapter")
struct SignalChannelAdapterTests {
    actor InboundCollector {
        private(set) var messages: [InboundMessage] = []

        func append(_ message: InboundMessage) {
            self.messages.append(message)
        }

        func snapshot() -> [InboundMessage] {
            self.messages
        }
    }

    actor MockSignalTransport: SignalHTTPTransport {
        struct RequestRecord: Sendable {
            let method: String
            let path: String
            let query: String?
            let authorization: String?
            let body: String
        }

        private var responsesByPath: [String: [HTTPResponseData]] = [:]
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
                let next = queue.removeFirst()
                self.responsesByPath[path] = queue
                return next
            }
            return HTTPResponseData(statusCode: 200, headers: [:], body: Data("{\"messages\":[]}".utf8))
        }

        func snapshot() -> [RequestRecord] {
            self.records
        }
    }

    @Test
    func sendPostsOutboundSignalRequest() async throws {
        let transport = MockSignalTransport()
        await transport.enqueue(
            path: "/v2/send",
            response: HTTPResponseData(statusCode: 200, headers: [:], body: Data("{\"timestamp\":1}".utf8))
        )
        let adapter = SignalChannelAdapter(
            config: SignalChannelConfig(
                enabled: true,
                serviceURL: "https://signal.example",
                accountID: "+15550000001",
                authToken: "signal-auth-token"
            ),
            transport: transport,
            serviceURL: URL(string: "https://signal.example")!
        )
        try await adapter.start()
        try await adapter.send(
            OutboundMessage(channel: .signal, accountID: nil, peerID: "+15550000002", text: "hello signal")
        )
        await adapter.stop()

        let requests = await transport.snapshot()
        let sendRequest = requests.first(where: { $0.path == "/v2/send" })
        #expect(sendRequest?.method == "POST")
        #expect(sendRequest?.authorization == "Bearer signal-auth-token")
        #expect(sendRequest?.body.contains("\"number\":\"+15550000001\"") == true)
        #expect(sendRequest?.body.contains("\"recipients\":[\"+15550000002\"]") == true)
        #expect(sendRequest?.body.contains("\"message\":\"hello signal\"") == true)
    }

    @Test
    func sendUsesDefaultRecipientWhenPeerIDMissing() async throws {
        let transport = MockSignalTransport()
        await transport.enqueue(
            path: "/v2/send",
            response: HTTPResponseData(statusCode: 200, headers: [:], body: Data("{\"timestamp\":1}".utf8))
        )
        let adapter = SignalChannelAdapter(
            config: SignalChannelConfig(
                enabled: true,
                serviceURL: "https://signal.example",
                accountID: "+15550000001",
                defaultRecipient: "+15550000009"
            ),
            transport: transport,
            serviceURL: URL(string: "https://signal.example")!
        )
        try await adapter.start()
        try await adapter.send(
            OutboundMessage(channel: .signal, accountID: nil, peerID: "", text: "fallback recipient")
        )
        await adapter.stop()

        let requests = await transport.snapshot()
        let sendRequest = requests.first(where: { $0.path == "/v2/send" })
        #expect(sendRequest?.body.contains("\"recipients\":[\"+15550000009\"]") == true)
    }

    @Test
    func startFailsWhenAccountIDMissing() async throws {
        let adapter = SignalChannelAdapter(
            config: SignalChannelConfig(
                enabled: true,
                serviceURL: "https://signal.example",
                accountID: nil
            ),
            transport: MockSignalTransport(),
            serviceURL: URL(string: "https://signal.example")!
        )

        do {
            try await adapter.start()
            Issue.record("Expected missing account ID configuration error")
        } catch {
            #expect(String(describing: error).contains("account ID"))
        }
    }

    @Test
    func pollingDeliversInboundMessagesAndSkipsDuplicates() async throws {
        let transport = MockSignalTransport()
        await transport.enqueue(
            path: "/v1/receive/+15550000001",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("""
                {
                  "messages": [
                    {
                      "envelope": {
                        "sourceNumber": "+15550000002",
                        "timestamp": 2001,
                        "dataMessage": {
                          "message": "first signal message"
                        }
                      }
                    }
                  ]
                }
                """.utf8)
            )
        )
        await transport.enqueue(
            path: "/v1/receive/+15550000001",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("""
                {
                  "messages": [
                    {
                      "envelope": {
                        "sourceNumber": "+15550000002",
                        "timestamp": 2001,
                        "dataMessage": {
                          "message": "first signal message"
                        }
                      }
                    },
                    {
                      "envelope": {
                        "sourceNumber": "+15550000003",
                        "timestamp": 2002,
                        "dataMessage": {
                          "message": "second signal message"
                        }
                      }
                    }
                  ]
                }
                """.utf8)
            )
        )

        let collector = InboundCollector()
        let adapter = SignalChannelAdapter(
            config: SignalChannelConfig(
                enabled: true,
                serviceURL: "https://signal.example",
                accountID: "+15550000001",
                pollIntervalMs: 250
            ),
            transport: transport,
            serviceURL: URL(string: "https://signal.example")!
        )
        await adapter.setInboundHandler { inbound in
            await collector.append(inbound)
        }
        try await adapter.start()
        try await Task.sleep(nanoseconds: 750_000_000)
        await adapter.stop()

        let inbound = await collector.snapshot()
        #expect(inbound.map(\.peerID) == ["+15550000002", "+15550000003"])
        #expect(inbound.map(\.text) == ["first signal message", "second signal message"])
    }
}
