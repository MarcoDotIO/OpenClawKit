import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawChannels
import OpenClawCore
import Testing

/// Credential redaction for channel health, `channels.status`, diagnostics and delivery failures.
@Suite("Channel error redaction")
struct ChannelErrorRedactionTests {
    actor OffsetStore: TelegramUpdateOffsetStore {
        func readLastUpdateID() async -> Int64? { nil }
        func writeLastUpdateID(_: Int64) async {}
    }

    static let telegramToken = "123456789:AAHsecretTOKENvalue_abcdefghijkl"

    static func registry(maxAttempts: Int) -> ChannelRegistry {
        ChannelRegistry(
            sendRetryPolicy: ChannelSendRetryPolicy(maxAttempts: maxAttempts, initialBackoffMs: 1, maxBackoffMs: 2, backoffMultiplier: 1),
            sendThrottlePolicy: ChannelSendThrottlePolicy()
        )
    }

    static func tokenURLError() -> URLError {
        let url = "https://api.telegram.org/bot\(Self.telegramToken)/getUpdates?timeout=30"
        return URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLStringErrorKey: url, NSURLErrorFailingURLErrorKey: URL(string: url)!])
    }

    @Test
    func errorTextNeverPrintsCredentialURLs() {
        let described = ChannelErrorText.describe(Self.tokenURLError())
        #expect(!described.contains(Self.telegramToken))
        #expect(!described.contains("AAHsecret"))
        #expect(described.contains("URLError"))

        let raw = "GET https://bb.example/api/v1/message/text?password=hunter2&guid=abc failed; bot\(Self.telegramToken)/sendMessage"
        let redacted = ChannelErrorText.redact(raw)
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains(Self.telegramToken))
        #expect(redacted.contains("password=<redacted>"))
        #expect(ChannelErrorText.redact("Authorization: Bearer abcdefghijklmnop") == "Authorization: Bearer <redacted>")
        #expect(ChannelErrorText.redact("https://user:secret@host.example/x") == "https://<redacted>@host.example/x")
        #expect(ChannelErrorText.redact("plain failure") == "plain failure")
    }

    @Test
    func telegramPollAndSendFailuresDoNotLeakTheBotToken() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/getMe", json: #"{"ok":true,"result":{"id":999,"is_bot":true,"username":"OpenClawBot"}}"#)
        await http.on("/deleteWebhook", json: #"{"ok":true,"result":true}"#)
        await http.fail("/getUpdates", error: Self.tokenURLError())
        await http.fail("/sendMessage", error: Self.tokenURLError())
        let adapter = TelegramChannelAdapter(
            config: TelegramChannelConfig(enabled: true, botToken: Self.telegramToken, pollIntervalMs: 250),
            transport: http,
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: OffsetStore(),
            diagnosticsSink: nil
        )
        try await adapter.start()
        try await waitUntil("poll failure recorded") { await adapter.transportHealth().lastError != nil }
        let health = await adapter.transportHealth()
        #expect(health.lastError?.contains(Self.telegramToken) == false)

        let registry = Self.registry(maxAttempts: 1)
        await registry.register(adapter)
        do {
            try await registry.send(OutboundMessage(channel: .telegram, peerID: "1", text: "hi"))
            Issue.record("expected failure")
        } catch let failure as ChannelDeliveryFailure {
            #expect(!failure.detail.contains(Self.telegramToken))
        }
        let snapshot = await registry.healthSnapshot(for: .telegram)
        #expect(snapshot.lastError != nil)
        #expect(snapshot.lastError?.contains(Self.telegramToken) == false)

        let handlers = ChannelGatewayHandlers(context: ChannelGatewayContext(
            registry: registry,
            pairingStore: ChannelPairingStore(),
            config: ChannelsConfig(telegram: TelegramChannelConfig(enabled: true, botToken: Self.telegramToken))
        ))
        let report = await handlers.statusReport()
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!encoded.contains(Self.telegramToken))
        #expect(!encoded.contains("AAHsecret"))
        await adapter.stop()
    }
}
