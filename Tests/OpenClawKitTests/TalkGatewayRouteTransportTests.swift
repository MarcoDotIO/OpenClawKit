#if canImport(AVFAudio) && (os(iOS) || os(macOS) || os(visionOS))
import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

private func connectTalkSession(_ session: GatewayCoreFakeSession) async throws -> GatewayNodeSession {
    let gateway = GatewayNodeSession()
    try await gateway.connect(
        url: try #require(URL(string: "ws://127.0.0.1:18789")),
        credentials: GatewayNodeSessionCredentials(token: "talk-token"),
        connectOptions: gatewayCoreOptions(scopes: ["operator.read", "operator.talk"]),
        sessionBox: WebSocketSessionBox(session: session),
        onConnected: {},
        onDisconnected: { _ in },
        onInvoke: { BridgeInvokeResponse(id: $0.id, ok: true) })
    return gateway
}

@Suite("Talk gateway route transport", .serialized)
struct TalkGatewayRouteTransportTests {
    @Test
    func talkRequestsSendStructuredParamsWithoutAJSONRoundTrip() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            requestReply: { _, _ in .ok(["ok": true]) }))
        let gateway = try await connectTalkSession(session)
        let params: [String: AnyCodable] = [
            "sessionId": AnyCodable("relay-1"),
            "timestamp": AnyCodable(1_800_000_000_000.0),
            "nested": AnyCodable(["flag": AnyCodable(true), "count": AnyCodable(3)]),
        ]
        _ = try await gateway.talkRequest(method: "talk.session.appendAudio", params: params, timeoutMs: 2500)
        let sent = try #require(session.latestSocket?.sentFrames(method: "talk.session.appendAudio").first)
        let sentParams = try #require(sent["params"] as? [String: Any])
        #expect(sentParams["sessionId"] as? String == "relay-1")
        let nested = try #require(sentParams["nested"] as? [String: Any])
        #expect(nested["flag"] as? Bool == true)
        #expect(nested["count"] as? Int == 3)
        await gateway.disconnect()
    }

    @Test
    func routeBoundTransportStopsAtTheRouteLease() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            requestReply: { _, _ in .ok(["ok": true]) }))
        let gateway = try await connectTalkSession(session)
        let route = try #require(await gateway.currentRoute())
        let transport = RealtimeTalkRelayTransport.gatewayNodeSession(gateway, route: route)

        #expect(await transport.isCurrent())
        let data = try await transport.request("talk.session.close", ["sessionId": AnyCodable("relay-1")], 2000)
        #expect(!data.isEmpty)
        #expect(session.latestSocket?.sentFrames(method: "talk.session.close").count == 1)

        await gateway.disconnect()
        #expect(await transport.isCurrent() == false)
        await #expect(throws: CancellationError.self) {
            _ = try await transport.request("talk.session.close", ["sessionId": AnyCodable("relay-1")], 2000)
        }
    }

    @MainActor
    @Test
    func relaySessionReportsListeningAndIdle() async {
        let reporter = RecordingStateReporter()
        let session = RealtimeTalkRelaySession(
            transport: unusedRealtimeRelayTransport(),
            options: .init(sessionKey: "main", provider: "openai", model: nil, voice: nil),
            audioCapture: TestRealtimeTalkAudioCapture(),
            pcmPlayer: UnusedPCMStreamingAudioPlayer(),
            onStatus: { _ in },
            onSpeakingChanged: { _ in },
            stateReporter: reporter)
        session._test_setRelaySessionId("relay-1")
        await session._test_handleGatewayEvent(realtimeRelayReadyEvent())
        await session._test_handleGatewayEvent(
            realtimeRelayEvent(#"{"relaySessionId":"relay-1","type":"close","reason":"completed"}"#))
        let labels = reporter.transitions.filter { $0.domain == .talk }.map(\.label)
        #expect(labels == ["listening", nil])
    }
}
#endif
