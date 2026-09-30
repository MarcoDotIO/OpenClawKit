import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

private func reportingChannel(
    url: String = "ws://127.0.0.1:18789",
    session: GatewayCoreFakeSession,
    reporter: RecordingStateReporter,
    options: GatewayConnectOptions = gatewayCoreOptions()) throws -> GatewayChannelActor
{
    GatewayChannelActor(
        url: try #require(URL(string: url)),
        token: "s3cr3t-credential",
        session: WebSocketSessionBox(session: session),
        connectOptions: options,
        stateReporter: reporter)
}

private func gatewayLabels(_ reporter: RecordingStateReporter) -> [String?] {
    reporter.transitions.filter { $0.domain == .gateway }.map(\.label)
}

@Suite("Gateway state reporting wiring", .serialized, .timeLimit(.minutes(1)))
struct GatewayStateReportingWiringTests {
    @Test
    func connectReportsTheHandshakeLifecycleWithStableContext() async throws {
        let reporter = RecordingStateReporter()
        let session = GatewayCoreFakeSession()
        let channel = try reportingChannel(session: session, reporter: reporter)
        try await channel.connect()

        #expect(gatewayLabels(reporter) == ["connecting", "authenticating", "connected"])
        let connected = try #require(reporter.transitions.last(where: { $0.label == "connected" }))
        #expect(connected.stable["authSource"] == .string(GatewayAuthSource.sharedToken.rawValue))
        #expect(connected.stable["role"] == .string("operator"))
        #expect(connected.stable["endpointKind"] == .string("loopback"))
        #expect(connected.stable["protocolVersion"] == .int(4))
        #expect(connected.stable["tlsPinned"] == .bool(false))
        // Never report the host or credentials.
        #expect(!connected.stable.values.contains(.string("127.0.0.1")))
        #expect(!connected.stable.values.contains(.string("s3cr3t-credential")))

        await channel.shutdown()
        #expect(gatewayLabels(reporter).last == .some(nil))
    }

    @Test
    func socketLossReportsReconnectingWithTheProblemKind() async throws {
        let reporter = RecordingStateReporter()
        let session = GatewayCoreFakeSession()
        let channel = try reportingChannel(session: session, reporter: reporter)
        try await channel.connect()
        session.latestSocket?.emitReceiveFailure(URLError(.networkConnectionLost))
        try await gatewayCoreWaitUntil("reconnecting reported") {
            gatewayLabels(reporter).contains("reconnecting")
        }
        let reconnecting = try #require(reporter.transitions.first(where: { $0.label == "reconnecting" }))
        #expect(reconnecting.volatile["problemKind"] == .string(GatewayConnectionProblem.Kind.reachabilityFailed.rawValue))
        #expect(reconnecting.volatile["backoffMs"] != nil)
        await channel.shutdown()
    }

    @Test
    func nonRecoverableAuthRejectionReportsAuthPaused() async throws {
        let reporter = RecordingStateReporter()
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            connectReply: { _ in
                .error(GatewayCoreFrames.error(
                    code: "INVALID_REQUEST",
                    message: "password mismatch",
                    details: ["code": "AUTH_PASSWORD_MISMATCH"]))
            }))
        let channel = try reportingChannel(session: session, reporter: reporter)
        await #expect(throws: GatewayConnectAuthError.self) { try await channel.connect() }
        let paused = try #require(reporter.transitions.last(where: { $0.domain == .gateway }))
        #expect(paused.label == "authPaused")
        #expect(paused.volatile["authDetailCode"] == .string("AUTH_PASSWORD_MISMATCH"))
        await channel.shutdown()
    }

    @Test
    func nodeInvokeReportsInvokingThenClears() async throws {
        let reporter = RecordingStateReporter()
        let session = GatewayCoreFakeSession()
        let gateway = GatewayNodeSession(stateReporter: reporter)
        try await gateway.connect(
            url: try #require(URL(string: "ws://127.0.0.1:18789")),
            credentials: GatewayNodeSessionCredentials(),
            connectOptions: gatewayCoreOptions(role: "node", scopes: []),
            sessionBox: WebSocketSessionBox(session: session),
            onConnected: {},
            onDisconnected: { _ in },
            onInvoke: { BridgeInvokeResponse(id: $0.id, ok: true) })
        let socket = try #require(session.latestSocket)
        socket.emit(GatewayCoreFrames.event("node.invoke.request", payload: [
            "id": "invoke-1",
            "nodeId": "node-1",
            "command": "device.info",
            "paramsJSON": "{}",
        ]))
        try await gatewayCoreWaitUntil("invoke state cleared") {
            reporter.transitions.filter { $0.domain == .nodeInvoke }.count >= 2
        }
        let invoke = reporter.transitions.filter { $0.domain == .nodeInvoke }
        #expect(invoke.map(\.label) == ["invoking", nil])
        #expect(invoke.first?.stable["command"] == .string("device.info"))
        #expect(invoke.first?.stable["invokeId"] == .string("invoke-1"))
        let outcome = reporter.reports.compactMap { report -> OpenClawStateMetadata? in
            if case let .volatile(.nodeInvoke, metadata) = report { return metadata }
            return nil
        }
        #expect(outcome == [["ok": .bool(true)]])
        // The node session's channel reports gateway lifecycle to the same reporter.
        #expect(gatewayLabels(reporter).contains("connected"))
        await gateway.disconnect()
    }

    @MainActor
    @Test
    func systemSpeechReportsSpeakingThenIdle() {
        let reporter = RecordingStateReporter()
        let synthesizer = TalkSystemSpeechSynthesizer._test_make()
        synthesizer.stateReporter = reporter
        synthesizer._test_simulateStart()
        synthesizer._test_simulateFinish()
        let talk = reporter.transitions.filter { $0.domain == .talk }
        #expect(talk.map(\.label) == ["speaking", nil])
        #expect(talk.first?.stable["provider"] == .string("system"))
    }
}
