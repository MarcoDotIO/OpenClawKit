import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

private func recoveryChannel(
    url: String,
    token: String? = nil,
    bootstrapToken: String? = nil,
    password: String? = nil,
    session: GatewayCoreFakeSession,
    options: GatewayConnectOptions = gatewayCoreOptions()) throws -> GatewayChannelActor
{
    GatewayChannelActor(
        url: try #require(URL(string: url)),
        token: token,
        bootstrapToken: bootstrapToken,
        password: password,
        session: WebSocketSessionBox(session: session),
        connectOptions: options)
}

private func withIsolatedRecoveryState(_ body: () async throws -> Void) async throws {
    let directory = try gatewayCoreTemporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await DeviceIdentityStore.withStateDirectory(directory) {
        try await body()
    }
}

private let pinMismatch = GatewayTLSValidationFailure(
    kind: .pinMismatch,
    host: "gateway.example.com",
    storeKey: "gateway.example.com:443",
    expectedFingerprint: String(repeating: "a", count: 64),
    observedFingerprint: String(repeating: "b", count: 64),
    systemTrustOk: true,
    port: 443)

@Suite("Gateway connect recovery", .serialized, .timeLimit(.minutes(1)))
struct GatewayConnectRecoveryTests {
    // MARK: TLS pin mismatch

    @Test
    func pinMismatchStopsAutoReconnectAndSurfacesARotationRequest() async throws {
        let session = GatewayCoreFakeSession(script: { index in
            index == 0 ? GatewayCoreSocketScript(challenge: nil) : GatewayCoreSocketScript()
        })
        let channel = try recoveryChannel(url: "wss://gateway.example.com", session: session)
        await channel._test_setConnectTimeoutSeconds(5)
        session.setTLSFailure(pinMismatch)
        let connect = Task { try await channel.connect() }
        try await gatewayCoreWaitUntil("socket opened") { session.makeCount == 1 }
        session.latestSocket?.emitReceiveFailure(URLError(.cancelled))
        await #expect(throws: GatewayTLSValidationError.self) { try await connect.value }

        #expect(await channel.reconnectPauseReason() == .tlsPinMismatch)
        #expect(await channel.lastTLSFailureClassification()
            == .pinMismatch(expected: pinMismatch.expectedFingerprint, presented: pinMismatch.observedFingerprint))
        let request = try #require(await channel.pendingTLSPinRotationRequest())
        #expect(request.storeKey == "gateway.example.com:443")
        #expect(request.currentFingerprint == pinMismatch.expectedFingerprint)
        #expect(request.presentedFingerprint == pinMismatch.observedFingerprint)
        #expect(request.isSystemTrusted)

        // Neither a network nudge nor time brings the socket back without the user.
        await channel.nudgeReconnect()
        try await Task.sleep(for: .milliseconds(700))
        #expect(session.makeCount == 1)

        await channel.resumeAfterTLSRepair()
        try await gatewayCoreWaitUntil("reconnected after repair") {
            await channel.currentConnectionGeneration() != nil
        }
        #expect(session.makeCount == 2)
        #expect(await channel.reconnectPauseReason() == nil)
        #expect(await channel.pendingTLSPinRotationRequest() == nil)
        await channel.shutdown()
    }

    @Test
    func successfulHandshakeClearsAPinMismatchPauseAndItsRotationRequest() async throws {
        let session = GatewayCoreFakeSession(script: { index in
            index == 0 ? GatewayCoreSocketScript(challenge: nil) : GatewayCoreSocketScript()
        })
        let channel = try recoveryChannel(url: "wss://gateway.example.com", session: session)
        await channel._test_setConnectTimeoutSeconds(5)
        session.setTLSFailure(pinMismatch)
        let failed = Task { try await channel.connect() }
        try await gatewayCoreWaitUntil("socket opened") { session.makeCount == 1 }
        session.latestSocket?.emitReceiveFailure(URLError(.cancelled))
        await #expect(throws: GatewayTLSValidationError.self) { try await failed.value }
        #expect(await channel.reconnectPauseReason() == .tlsPinMismatch)

        // An explicit connect (for example from a request) succeeds against the pinned certificate.
        try await channel.connect()
        #expect(await channel.reconnectPauseReason() == nil)
        #expect(await channel.pendingTLSPinRotationRequest() == nil)

        // Automatic reconnect works again after a later drop.
        session.latestSocket?.emitReceiveFailure(URLError(.networkConnectionLost))
        try await gatewayCoreWaitUntil("reconnected automatically") {
            session.makeCount == 3
        }
        try await gatewayCoreWaitUntil("readmitted") { await channel.currentConnectionGeneration() != nil }
        await channel.shutdown()
    }

    @Test(arguments: [
        (URLError.Code.serverCertificateUntrusted, GatewayTLSFailureClassification.untrustedChain),
        (.serverCertificateHasBadDate, .expired),
    ])
    func plainURLSessionCertificateRejectionsBecomeTypedTLSErrors(
        code: URLError.Code,
        classification: GatewayTLSFailureClassification) async throws
    {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(challenge: nil))
        let channel = try recoveryChannel(url: "wss://gateway.example.com", session: session)
        await channel._test_setConnectTimeoutSeconds(5)
        let connect = Task { try await channel.connect() }
        try await gatewayCoreWaitUntil("socket opened") { session.makeCount == 1 }
        session.latestSocket?.emitReceiveFailure(URLError(code))
        do {
            try await connect.value
            Issue.record("expected a TLS failure")
        } catch let error as GatewayTLSValidationError {
            #expect(error.failure.kind == .untrustedCertificate)
            #expect(error.failure.host == "gateway.example.com")
            #expect(GatewayTLSFailureClassification(error: error) == classification)
            #expect(GatewayConnectionProblemMapper.map(error: error)?.kind == .tlsCertificateUntrusted)
        }
        #expect(await channel.lastTLSFailureClassification() == classification)
        // Only a pin mismatch stops reconnects; a trust failure keeps the normal backoff.
        #expect(await channel.reconnectPauseReason() == nil)
        await channel.shutdown()
    }

    // MARK: Bootstrap handoff

    @Test(arguments: [
        ("wss://gateway.example.com", true),
        ("ws://127.0.0.1:18789", true),
        ("ws://[::1]:18789", true),
        ("ws://192.168.1.20:18789", true),
        ("ws://gateway.example.com", false),
        ("ws://0.0.0.0:18789", false),
    ])
    func bootstrapHandoffPersistenceFollowsTheTransportPolicy(url: String, persists: Bool) throws {
        #expect(GatewayChannelActor.allowsBootstrapHandoffPersistence(url: try #require(URL(string: url))) == persists)
    }

    @Test
    func reconnectAfterHandoffUsesThePersistedDeviceTokenInsteadOfTheConsumedSetupCode() async throws {
        try await withIsolatedRecoveryState {
            _ = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            let session = GatewayCoreFakeSession(script: { index in
                var script = GatewayCoreSocketScript()
                if index == 0 {
                    script.connectReply = { _ in
                        .ok(GatewayCoreFrames.hello(auth: [
                            "role": "operator",
                            "deviceToken": "handoff-device-token",
                            "scopes": ["operator.read"],
                        ]))
                    }
                }
                return script
            })
            let channel = try recoveryChannel(
                url: "ws://192.168.1.20:18789",
                bootstrapToken: "setup-code",
                session: session,
                options: gatewayCoreOptions(includeDeviceIdentity: true, deviceAuthGatewayID: "gateway-lan"))
            try await channel.connect()
            #expect(session.socket(at: 0)?.connectAuth()?["bootstrapToken"] as? String == "setup-code")

            session.latestSocket?.emitReceiveFailure()
            try await gatewayCoreWaitUntil("reconnected") {
                guard session.makeCount == 2 else { return false }
                return await channel.currentConnectionGeneration() != nil
            }
            let auth = try #require(session.socket(at: 1)?.connectAuth())
            #expect(auth["bootstrapToken"] == nil)
            #expect(auth["token"] as? String == "handoff-device-token")
            #expect(await channel.authSource() == .deviceToken)
            await channel.shutdown()
        }
    }

    @Test
    func explicitPasswordWinsOverTheSetupCodeOnEveryAttempt() async throws {
        let session = GatewayCoreFakeSession()
        let channel = try recoveryChannel(
            url: "ws://127.0.0.1:18789",
            bootstrapToken: "setup-code",
            password: "secret",
            session: session)
        try await channel.connect()
        session.latestSocket?.emitReceiveFailure()
        try await gatewayCoreWaitUntil("reconnected") {
            guard session.makeCount == 2 else { return false }
            return await channel.currentConnectionGeneration() != nil
        }
        for index in 0..<2 {
            #expect(session.socket(at: index)?.connectAuth() as? [String: String] == ["password": "secret"])
        }
        await channel.shutdown()
    }

    // MARK: Rate limiting

    @Test
    func rateLimitedReconnectPausesAndResumesAfterRetryAfter() async throws {
        let session = GatewayCoreFakeSession(script: { index in
            var script = GatewayCoreSocketScript()
            if index == 1 {
                script.connectReply = { _ in
                    .error(GatewayCoreFrames.error(
                        code: "INVALID_REQUEST",
                        message: "too many attempts",
                        details: ["code": "AUTH_RATE_LIMITED"],
                        retryAfterMs: 1000))
                }
            }
            return script
        })
        let channel = try recoveryChannel(url: "ws://127.0.0.1:18789", token: "shared", session: session)
        await channel._test_setConnectFailureBackoffWaitHandler {}
        try await channel.connect()
        session.latestSocket?.emitReceiveFailure()
        try await gatewayCoreWaitUntil("rate-limit pause") {
            await channel.reconnectPauseReason() == .authFailure
        }
        #expect(session.makeCount == 2)
        try await gatewayCoreWaitUntil("resumed after retryAfterMs") {
            guard session.makeCount == 3 else { return false }
            return await channel.currentConnectionGeneration() != nil
        }
        #expect(await channel.reconnectPauseReason() == nil)
        await channel.shutdown()
    }

    // MARK: Node pairing and connect helpers

    @Test
    func nodePairingStateTracksPendingApprovalAndHello() async throws {
        let session = GatewayCoreFakeSession(script: { index in
            var script = GatewayCoreSocketScript()
            if index == 0 {
                script.connectReply = { _ in
                    .error(GatewayCoreFrames.error(
                        code: "NOT_PAIRED",
                        message: "pairing required",
                        details: ["code": "PAIRING_REQUIRED", "requestId": "req-42"]))
                }
            }
            return script
        })
        let gateway = GatewayNodeSession()
        #expect(await gateway.pairingState() == .unknown)
        let url = try #require(URL(string: "ws://127.0.0.1:18789"))
        let options = gatewayCoreOptions(role: "node", scopes: [])
        func connect() async throws {
            try await gateway.connect(
                url: url,
                credentials: GatewayNodeSessionCredentials(),
                connectOptions: options,
                sessionBox: WebSocketSessionBox(session: session),
                onConnected: {},
                onDisconnected: { _ in },
                onInvoke: { BridgeInvokeResponse(id: $0.id, ok: true) })
        }
        await #expect(throws: GatewayConnectAuthError.self) { try await connect() }
        #expect(await gateway.pairingState() == .pending(requestId: "req-42"))
        #expect(await gateway.negotiatedProtocolVersion() == nil)

        try await connect()
        #expect(await gateway.pairingState() == .approved)
        #expect(await gateway.negotiatedProtocolVersion() == 4)
        await gateway.disconnect()
    }

    @Test
    func defaultNodeOptionsAdvertiseOnlyCanvasPresenterCommands() {
        let options = GatewayConnectOptions.defaultNode(
            caps: [.canvas, .camera, .canvas],
            commands: ["camera.snap", "canvas.eval", " canvas.snapshot ", "canvas.a2ui.push", "camera.snap", ""],
            permissions: ["camera": true],
            displayName: "Test Node")
        #expect(options.role == "node")
        #expect(options.clientMode == "node")
        #expect(options.scopes.isEmpty)
        #expect(options.caps == ["canvas", "camera"])
        #expect(options.commands == ["camera.snap", "canvas.present", "canvas.hide", "canvas.navigate"])
        #expect(options.permissions == ["camera": true])

        let snapshot = OpenClawPermissionsSnapshot(camera: .denied, microphone: .authorized)
        let reported = options.reportingPermissions(snapshot)
        #expect(reported.permissions["camera"] == false)
        #expect(reported.permissions["microphone"] == true)
    }

    @Test
    func gatewayConfigFeedsTheDefaultHandshakeTimeout() throws {
        var config = GatewayConfig()
        config.handshakeTimeoutMs = 12000
        let defaults = gatewayCoreOptions().applyingGatewayConfig(config, environment: [:])
        #expect(defaults.handshakeTimeoutMs == 12000)
        let environment = gatewayCoreOptions().applyingGatewayConfig(
            config,
            environment: ["OPENCLAW_HANDSHAKE_TIMEOUT_MS": "4500"])
        #expect(environment.handshakeTimeoutMs == 4500)
        var explicit = gatewayCoreOptions()
        explicit.handshakeTimeoutMs = 900
        #expect(explicit.applyingGatewayConfig(config, environment: [:]).handshakeTimeoutMs == 900)
    }
}
