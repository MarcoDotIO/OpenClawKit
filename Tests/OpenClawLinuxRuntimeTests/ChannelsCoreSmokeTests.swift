import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawChannels
import OpenClawCore
import OpenClawProtocol
import Testing

// Cross-platform smoke checks for the 2026.3.0 channel core. They run on every host, so Linux CI
// exercises upstream config decoding, the access policy, pairing persistence, chunking and retry
// classification without Apple frameworks.
@Suite("Channels core smoke")
struct ChannelsCoreSmokeTests {
    @Test
    func decodesUpstreamChannelsAndNormalizesIDs() throws {
        let json = """
        {"telegram": {"botToken": "${TELEGRAM_BOT_TOKEN}", "allowFrom": [42], "apiRoot": "https://t.example"},
         "sms": {"authToken": "plain"}, "defaults": {"groupPolicy": "open"}}
        """
        let config = try JSONDecoder().decode(ChannelsConfig.self, from: Data(json.utf8))
        #expect(config.telegram.enabled)
        #expect(config.telegram.baseURL == "https://t.example")
        #expect(config.telegram.policy.allowFrom == ["42"])
        #expect(config.rawSection(named: "sms") != nil)
        #expect(config.plaintextSecretPaths() == ["channels.sms.authToken"])
        #expect(ChannelID(normalizing: "lark") == .feishu)
        #expect(ChannelID(normalizing: "元宝") == .yuanbao)
        #expect(OpenClawChannelMetadataCatalog.upstreamVersion == "2026.9.6")
    }

    @Test
    func pairsUnknownSendersAndPersistsApprovals() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-linux-pairing", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChannelPairingStore(stateDirectory: directory)
        let message = InboundMessage(channel: .signal, peerID: "+15550001111", text: "hi", senderID: "+1 555 000 1111")
        let decision = await ChannelAccessPolicyEvaluator().evaluate(message, config: ChannelMessagingPolicyConfig(), store: store)
        guard case .pairingRequired(let code, true) = decision else {
            Issue.record("expected a new pairing request, got \(decision)")
            return
        }
        #expect(code.count == ChannelPairingStore.codeLength)
        _ = try await store.approve(channel: .signal, code: code)
        let reloaded = ChannelPairingStore(stateDirectory: directory)
        let approved = await ChannelAccessPolicyEvaluator().evaluate(message, config: ChannelMessagingPolicyConfig(), store: reloaded)
        #expect(approved == .allow)
    }

    @Test
    func chunksAndClassifiesSends() {
        let chunks = ChannelTextChunker.chunk(String(repeating: "é", count: 20_000), for: .googlechat)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.utf8.count <= 32_000 })
        #expect(ChannelSendError.classify(URLError(.timedOut)).isRetryable == false)
        #expect(ChannelSendError.classify(URLError(.cannotConnectToHost)).isRetryable)
        let body = Data(#"{"ok":false,"error_code":429,"parameters":{"retry_after":2}}"#.utf8)
        #expect(ChannelSendError.classify(statusCode: 429, body: body) == .rateLimited(retryAfterMs: 2_000))
    }
}
