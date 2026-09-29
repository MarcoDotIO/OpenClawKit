import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawChannels
import OpenClawCore
import OpenClawProtocol
import Testing

/// Cross-platform smoke tests for the 2026.3.0 native adapters (run on Linux CI with swift-crypto).
@Suite("Channel adapters (Linux smoke)")
struct ChannelAdaptersLinuxSmokeTests {
    actor StubHTTP: ChannelHTTPTransport {
        private(set) var bodies: [String] = []
        private let responses: [String: String]

        init(responses: [String: String]) {
            self.responses = responses
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            let path = request.url?.path ?? ""
            let match = self.responses.first { path.hasSuffix($0.key) }
            return HTTPResponseData(statusCode: match == nil ? 404 : 200, headers: [:], body: Data((match?.value ?? "{}").utf8))
        }
    }

    actor Inbox {
        private(set) var messages: [InboundMessage] = []

        func append(_ message: InboundMessage) {
            self.messages.append(message)
        }
    }

    private func poll(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await condition(), "timed out")
    }

    @Test
    func webhookSignatureVectorsMatchPlatformDocumentation() {
        let twilio = ChannelWebhookSignature.twilioSignature(
            authToken: "12345",
            url: "https://mycompany.com/myapp.php?foo=1&bar=2",
            form: ["CallSid": "CA1234567890ABCDE", "Caller": "+12349013030", "Digits": "1234", "From": "+12349013030", "To": "+18005551212"]
        )
        #expect(twilio == "0/KCTR6DLpKmkAf8muzZqo1nDgQ=")
        #expect(ChannelWebhookSignature.lineSignature(channelSecret: "line-secret", body: Data("{}".utf8)) == "hBcw8zWjhUK8A2tp/CjHF/+hHTMcYtYsx1Hz7OrIrBI=")
        #expect(ChannelWebhookSignature.slackSignature(signingSecret: "s", timestamp: "1", body: Data()).hasPrefix("v0="))
    }

    @Test
    func smsWebhookDeliversSignedMessage() async throws {
        let config = SMSChannelConfig(enabled: true, accountSid: "AC1", authToken: "tok", fromNumber: "+15550001111", publicWebhookUrl: "https://gw.example.com/webhooks/sms")
        let adapter = SMSChannelAdapter(config: config, environment: [:], transport: StubHTTP(responses: [:]))
        let inbox = Inbox()
        await adapter.setInboundHandler { await inbox.append($0) }
        try await adapter.start()
        let form = ["MessageSid": "SM1", "From": "+15550002222", "Body": "hi"]
        let signature = ChannelWebhookSignature.twilioSignature(authToken: "tok", url: "https://gw.example.com/webhooks/sms", form: form)
        let body = Data("MessageSid=SM1&From=%2B15550002222&Body=hi".utf8)
        let response = await adapter.handleWebhook(
            requestURL: URL(string: "https://gw.example.com/webhooks/sms")!,
            headers: ["X-Twilio-Signature": signature],
            body: body
        )
        #expect(response.status == 200)
        try await self.poll { await inbox.messages.count == 1 }
        #expect(await inbox.messages.first?.peerID == "+15550002222")
        await adapter.stop()
    }

    @Test
    func a2aRoundTripCompletesTaskWithReply() async throws {
        let config = A2AChannelConfig(enabled: true, replyTimeoutMs: 5_000, peers: ["peer": A2APeerConfig(token: "secret")])
        let adapter = A2AChannelAdapter(config: config)
        await adapter.setInboundHandler { message in
            try? await adapter.send(OutboundMessage(channel: .a2a, peerID: message.peerID, text: "done"))
        }
        try await adapter.start()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"role":"ROLE_USER","contextId":"c1","parts":[{"text":"task"}]}}}"#
        let response = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: ["Authorization": "Bearer secret"], body: Data(request.utf8))
        let decoded = try JSONDecoder().decode(A2AJSONRPCResponse<A2ASendMessageResult>.self, from: response.body)
        #expect(decoded.result?.task?.status.state == .completed)
        #expect(decoded.result?.task?.replyText == "done")
        await adapter.stop()

        let http = StubHTTP(responses: ["/a2a/v1": #"{"jsonrpc":"2.0","id":"x","result":{"task":{"id":"t9"}}}"#])
        let client = A2AClient(peers: ["remote": A2APeerConfig(token: "t", url: "https://remote.example.com/a2a/v1", outboundToken: "o")], transport: http)
        let task = try await client.send(text: "hello", to: "a2a:remote")
        #expect(task.id == "t9")
    }

    #if os(Linux) || os(macOS)
    @Test
    func imsgProcessPipeRunsNewlineJSONRPC() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imsg-linux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("imsg")
        let body = """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed 's/.*"id":\\([0-9]*\\).*/\\1/')
          printf '{"jsonrpc":"2.0","id":%s,"result":{"ok":true}}\\n' "$id"
        done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let client = IMsgRPCClient(pipe: IMsgProcessPipe(cliPath: script.path))
        try await client.start()
        let result = try await client.request("ping", timeoutMs: 10_000)
        #expect(result.dictionaryValue?["ok"]?.boolValue == true)
        await client.stop()
    }
    #endif
}
