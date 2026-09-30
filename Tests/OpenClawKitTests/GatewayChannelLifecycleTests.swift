import CryptoKit
import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

private func makeChannel(
    url: String = "ws://127.0.0.1:18789",
    token: String? = nil,
    bootstrapToken: String? = nil,
    password: String? = nil,
    authBindingKey: SymmetricKey? = nil,
    session: GatewayCoreFakeSession,
    options: GatewayConnectOptions? = gatewayCoreOptions(),
    pushes: GatewayCoreRecorder<String>? = nil,
    disconnects: GatewayCoreRecorder<String>? = nil,
    extraHeadersProvider: (@Sendable () -> [String: String])? = nil) throws -> GatewayChannelActor
{
    GatewayChannelActor(
        url: try #require(URL(string: url)),
        token: token,
        bootstrapToken: bootstrapToken,
        password: password,
        authBindingKey: authBindingKey,
        session: WebSocketSessionBox(session: session),
        pushHandler: { push, generation in
            switch push {
            case .snapshot: pushes?.append("snapshot:\(generation)")
            case let .event(event): pushes?.append("event:\(event.event):\(generation)")
            case let .seqGap(expected, received): pushes?.append("gap:\(expected)-\(received)")
            }
        },
        connectOptions: options,
        disconnectHandler: { reason, generation in
            disconnects?.append("\(generation):\(reason)")
        },
        extraHeadersProvider: extraHeadersProvider)
}

@Suite("Gateway channel lifecycle")
struct GatewayChannelLifecycleTests {
    @Test
    func operatorConnectOffersProtocolFourWithPlatformDefaults() async throws {
        let session = GatewayCoreFakeSession()
        let channel = try makeChannel(session: session, options: nil)
        defer { Task { await channel.shutdown() } }

        // Platform defaults include the device identity. Scope it to a private state directory
        // (task-local) so a concurrently running env-pinning suite cannot swap or remove the store
        // under this connect ("attempt to write a readonly database").
        let stateDirectory = try gatewayCoreTemporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        try await DeviceIdentityStore.withStateDirectory(stateDirectory) {
            try await channel.connect()
        }

        let params = try #require(session.latestSocket?.connectParams())
        #expect(params["minProtocol"] as? Int == 4)
        #expect(params["maxProtocol"] as? Int == 4)
        #expect(params["role"] as? String == "operator")
        let client = try #require(params["client"] as? [String: Any])
        #expect(client["id"] as? String == GatewayConnectOptions.defaultClientID)
        #expect(client["mode"] as? String == "ui")
        #expect((params["scopes"] as? [String])?.contains("operator.questions") == true)
        #expect(await channel.negotiatedProtocolVersion() == 4)
        #expect(await channel.currentHandshakePhase() == .helloReceived)
        #expect(await channel.currentConnectionGeneration() != nil)
        await channel.shutdown()
    }

    @Test
    func defaultClientIDFollowsPlatformRegistry() {
        #if os(macOS)
        #expect(GatewayConnectOptions.defaultClientID == "openclaw-macos")
        #elseif os(watchOS)
        #expect(GatewayConnectOptions.defaultClientID == "openclaw-watchos")
        #else
        #expect(GatewayConnectOptions.defaultClientID == "openclaw-ios")
        #endif
        #expect(GatewayConnectOptions.defaultOperator().scopes == GatewayChannelActor.defaultOperatorConnectScopes)
    }

    @Test
    func nodeConnectOffersNMinusOneWindowAndLegacyOptInWidensOperators() async throws {
        let nodeSession = GatewayCoreFakeSession()
        let node = try makeChannel(session: nodeSession, options: gatewayCoreOptions(role: "node", scopes: []))
        try await node.connect()
        let nodeParams = try #require(nodeSession.latestSocket?.connectParams())
        #expect(nodeParams["minProtocol"] as? Int == 3)
        #expect(nodeParams["maxProtocol"] as? Int == 4)
        await node.shutdown()

        let legacySession = GatewayCoreFakeSession()
        let legacy = try makeChannel(
            session: legacySession,
            options: gatewayCoreOptions(minimumProtocolVersion: 3))
        try await legacy.connect()
        let legacyParams = try #require(legacySession.latestSocket?.connectParams())
        #expect(legacyParams["minProtocol"] as? Int == 3)
        #expect(legacyParams["maxProtocol"] as? Int == 4)
        await legacy.shutdown()
    }

    @Test
    func requestRoundTripsAndZeroTimeoutDisablesTheClientDeadline() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            requestReply: { method, params in
                method == "echo" ? .ok(["echo": params["value"] ?? NSNull()]) : .none
            }))
        let channel = try makeChannel(session: session)
        try await channel.connect()

        let data = try await channel.request(method: "echo", params: ["value": AnyCodable(42)], timeoutMs: 0)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["echo"] as? Int == 42)
        #expect(await channel._test_pendingRequestCount() == 0)
        #expect(GatewayChannelActor.resolveRequestTimeoutMs(0, defaultMs: 15000) == nil)
        #expect(GatewayChannelActor.resolveRequestTimeoutMs(nil, defaultMs: 15000) == 15000)
        await channel.shutdown()
    }

    @Test
    func requestTimeoutFailsOnlyThatRequest() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            requestReply: { method, _ in method == "hang" ? .none : .ok(["ok": true]) }))
        let channel = try makeChannel(session: session)
        try await channel.connect()
        let generation = await channel.currentConnectionGeneration()

        do {
            _ = try await channel.request(method: "hang", params: nil, timeoutMs: 50)
            Issue.record("expected a timeout")
        } catch {
            #expect((error as NSError).domain == "Gateway")
            #expect((error as NSError).code == 5)
        }
        #expect(await channel.currentConnectionGeneration() == generation)
        _ = try await channel.request(method: "ping", params: nil)
        await channel.shutdown()
    }

    @Test
    func cancelledRequestDoesNotTearDownTheSocket() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            requestReply: { method, _ in method == "hang" ? .none : .ok([:]) }))
        let channel = try makeChannel(session: session)
        try await channel.connect()
        let generation = await channel.currentConnectionGeneration()

        let pending = Task {
            try await channel.request(method: "hang", params: nil, timeoutMs: 0)
        }
        try await gatewayCoreWaitUntil("hang request sent") {
            session.latestSocket?.sentFrames(method: "hang").isEmpty == false
        }
        pending.cancel()
        let result = await pending.result
        #expect(throws: CancellationError.self) { try result.get() }
        try await gatewayCoreWaitUntil("pending request released") {
            await channel._test_pendingRequestCount() == 0
        }
        #expect(await channel.currentConnectionGeneration() == generation)
        #expect(session.makeCount == 1)
        _ = try await channel.request(method: "ok", params: nil)
        await channel.shutdown()
    }

    @Test
    func boundRequestNeverReconnectsAStaleGeneration() async throws {
        let session = GatewayCoreFakeSession()
        let channel = try makeChannel(session: session)
        try await channel.connect()
        let generation = try #require(await channel.currentConnectionGeneration())

        _ = try await channel.request(method: "ok", params: nil, ifCurrentConnectionGeneration: generation)
        await #expect(throws: CancellationError.self) {
            _ = try await channel.request(method: "ok", params: nil, ifCurrentConnectionGeneration: generation &+ 1)
        }
        await #expect(throws: CancellationError.self) {
            try await channel.send(method: "ok", params: nil, ifCurrentConnectionGeneration: generation &+ 1)
        }
        await channel.shutdown()
    }

    @Test
    func startupUnavailableConnectIsRetriedOnAFreshSocket() async throws {
        let session = GatewayCoreFakeSession(script: { index in
            var script = GatewayCoreSocketScript()
            if index == 0 {
                script.connectReply = { _ in .error(GatewayCoreFrames.startupUnavailable(retryAfterMs: 100)) }
            }
            return script
        })
        let disconnects = GatewayCoreRecorder<String>()
        let channel = try makeChannel(session: session, disconnects: disconnects)

        try await channel.connect()

        #expect(session.makeCount == 2)
        #expect(disconnects.values.isEmpty)
        #expect(await channel._test_hasConnectFailureBackoffDeadline() == false)
        await channel.shutdown()
    }

    @Test
    func startupUnavailableRequestIsRetriedWithinTheBudget() async throws {
        let attempts = GatewayCoreRecorder<String>()
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            requestReply: { method, _ in
                attempts.append(method)
                return attempts.values.count == 1
                    ? .error(GatewayCoreFrames.startupUnavailable(retryAfterMs: 100))
                    : .ok(["ready": true])
            }))
        let channel = try makeChannel(session: session)
        try await channel.connect()

        let data = try await channel.request(method: "sessions.create", params: nil, timeoutMs: 5000)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["ready"] as? Bool == true)
        #expect(attempts.values == ["sessions.create", "sessions.create"])

        // A budget smaller than the retry hint surfaces the startup error instead of waiting.
        let tight = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            requestReply: { _, _ in .error(GatewayCoreFrames.startupUnavailable(retryAfterMs: 2000)) }))
        let tightChannel = try makeChannel(session: tight)
        try await tightChannel.connect()
        do {
            _ = try await tightChannel.request(method: "agent.wait", params: nil, timeoutMs: 500)
            Issue.record("expected the startup error")
        } catch let error as GatewayResponseError {
            #expect(error.isStartupUnavailable)
            #expect(error.startupRetryAfterMs == 2000)
        }
        await channel.shutdown()
        await tightChannel.shutdown()
    }

    @Test
    func protocolMismatchResetsBackoffWhileTransportFailuresBackOff() async throws {
        let mismatch = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            connectReply: { _ in
                .error(GatewayCoreFrames.error(
                    code: "INVALID_REQUEST",
                    message: "protocol mismatch",
                    details: [
                        "code": "PROTOCOL_MISMATCH",
                        "clientMinProtocol": 4,
                        "clientMaxProtocol": 4,
                        "expectedProtocol": 5,
                    ]))
            }))
        let mismatchChannel = try makeChannel(session: mismatch)
        do {
            try await mismatchChannel.connect()
            Issue.record("expected a protocol mismatch")
        } catch let error as GatewayConnectAuthError {
            #expect(error.detail == .protocolMismatch)
            #expect(error.protocolUpdateOwner == .client)
            #expect(error.expectedProtocol == 5)
        }
        #expect(await mismatchChannel._test_hasConnectFailureBackoffDeadline() == false)
        await mismatchChannel.shutdown()

        let transport = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(challenge: nil))
        let transportChannel = try makeChannel(session: transport)
        await transportChannel._test_setConnectTimeoutSeconds(0.1)
        await #expect(throws: (any Error).self) { try await transportChannel.connect() }
        #expect(await transportChannel._test_hasConnectFailureBackoffDeadline() == true)
        #expect(await transportChannel._test_connectFailureBackoffDelayMs() == 1000)
        await transportChannel.shutdown()
    }

    @Test
    func concurrentConnectCallersShareOneAttempt() async throws {
        let session = GatewayCoreFakeSession()
        let channel = try makeChannel(session: session)
        async let first: Void = channel.connect()
        async let second: Void = channel.connect()
        async let third: Void = channel.connect()
        _ = try await (first, second, third)
        #expect(session.makeCount == 1)
        #expect(await channel._test_connectWaiterCount() == 0)
        await channel.shutdown()
    }

    @Test
    func shutdownRefusesLaterConnects() async throws {
        let session = GatewayCoreFakeSession()
        let channel = try makeChannel(session: session)
        try await channel.connect()
        await channel.shutdown()
        do {
            try await channel.connect()
            Issue.record("expected shutdown error")
        } catch {
            #expect((error as NSError).domain == "Gateway")
            #expect((error as NSError).code == 6)
        }
    }

    @Test
    func receiveFailureRetiresTheGenerationAndReconnects() async throws {
        let session = GatewayCoreFakeSession()
        let disconnects = GatewayCoreRecorder<String>()
        let pushes = GatewayCoreRecorder<String>()
        let channel = try makeChannel(session: session, pushes: pushes, disconnects: disconnects)
        try await channel.connect()
        let firstGeneration = try #require(await channel.currentConnectionGeneration())

        session.latestSocket?.emitReceiveFailure()
        try await gatewayCoreWaitUntil("reconnect after receive failure") {
            await channel.currentConnectionGeneration().map { $0 != firstGeneration } ?? false
        }
        #expect(disconnects.values.first?.hasPrefix("\(firstGeneration):receive failed") == true)
        #expect(session.makeCount == 2)
        try await gatewayCoreWaitUntil("snapshot for the replacement socket") {
            pushes.values.filter { $0.hasPrefix("snapshot:") }.count == 2
        }
        await channel.shutdown()
    }

    @Test
    func staleForegroundSocketIsRetiredWithTheTickCloseCode() async throws {
        let session = GatewayCoreFakeSession()
        let disconnects = GatewayCoreRecorder<String>()
        let channel = try makeChannel(session: session, disconnects: disconnects)
        try await channel.connect()

        #expect(await channel.reconnectIfStale() == false)
        let later = ContinuousClock.now.advanced(by: .seconds(120))
        #expect(await channel.reconnectIfStale(now: later) == true)
        #expect(session.socket(at: 0)?.closeCode?.rawValue == 4000)
        #expect(disconnects.values.first?.contains("stale") == true)
        try await gatewayCoreWaitUntil("stale reconnect") { session.makeCount == 2 }
        await channel.shutdown()
    }

    @Test
    func sequenceGapIsReportedBeforeTheEvent() async throws {
        let session = GatewayCoreFakeSession()
        let pushes = GatewayCoreRecorder<String>()
        let channel = try makeChannel(session: session, pushes: pushes)
        try await channel.connect()
        let socket = try #require(session.latestSocket)

        socket.emit(GatewayCoreFrames.event("agent", payload: [:], seq: 1))
        socket.emit(GatewayCoreFrames.event("agent", payload: [:], seq: 4))
        try await gatewayCoreWaitUntil("second event") {
            pushes.values.filter { $0.hasPrefix("event:agent") }.count == 2
        }
        let values = pushes.values.filter { !$0.hasPrefix("snapshot") }
        #expect(values.count == 3)
        #expect(values[1] == "gap:2-4")
        await channel.shutdown()
    }

    @Test
    func profileBindingRequiresTheAdvertisedCapability() async throws {
        let unsupported = GatewayCoreFakeSession()
        let plain = try makeChannel(session: unsupported)
        try await plain.connect()
        await #expect(throws: GatewayRequestError.profileBindingUnsupported(method: "chat.send")) {
            _ = try await plain.request(method: "chat.send", params: nil, expectedProfileID: "profile-1")
        }
        #expect(unsupported.latestSocket?.sentFrames(method: "chat.send").isEmpty == true)
        await plain.shutdown()

        let supported = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            connectReply: { _ in .ok(GatewayCoreFrames.hello(capabilities: ["profile-binding-v1"])) },
            requestReply: { _, _ in
                .error(GatewayCoreFrames.error(
                    code: "INVALID_REQUEST",
                    message: "Selected account changed or is unavailable.",
                    details: ["reason": "EXPECTED_PROFILE_MISMATCH", "execution": "not_started"]))
            }))
        let bound = try makeChannel(session: supported)
        try await bound.connect()
        await #expect(throws: GatewayRequestError.invalidExpectedProfileID) {
            _ = try await bound.request(method: "chat.send", params: nil, expectedProfileID: "")
        }
        do {
            _ = try await bound.request(method: "chat.send", params: nil, expectedProfileID: "profile-1")
            Issue.record("expected a profile mismatch")
        } catch let error as GatewayResponseError {
            #expect(error.expectedProfileMismatch == .notStarted)
        }
        let frame = try #require(supported.latestSocket?.sentFrames(method: "chat.send").last)
        #expect(frame["expectedProfileId"] as? String == "profile-1")
        await bound.shutdown()
    }

    @Test
    func advertisedMaxPayloadRejectsOversizedFramesLocally() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            connectReply: { _ in
                .ok(GatewayCoreFrames.hello(policy: ["maxPayload": 2048, "tickIntervalMs": 15000]))
            }))
        let channel = try makeChannel(session: session)
        try await channel.connect()
        #expect(await channel.currentHelloPolicy() == GatewayHelloPolicy(tickIntervalMs: 15000, maxPayloadBytes: 2048))

        let large = String(repeating: "x", count: 4096)
        do {
            _ = try await channel.request(method: "chat.send", params: ["text": AnyCodable(large)])
            Issue.record("expected payloadTooLarge")
        } catch let GatewayRequestError.payloadTooLarge(method, bytes, maximumBytes) {
            #expect(method == "chat.send")
            #expect(bytes > 4096)
            #expect(maximumBytes == 2048)
        }
        #expect(session.latestSocket?.sentFrames(method: "chat.send").isEmpty == true)
        await channel.shutdown()
    }

    @Test
    func customHeadersRideOnlySecureUpgradesAndAreReadPerConnect() async throws {
        let reads = GatewayCoreRecorder<Int>()
        let provider: @Sendable () -> [String: String] = {
            reads.append(1)
            return [
                "CF-Access-Client-Id": "client-\(reads.values.count)",
                "CF-Access-Client-Secret": "secret",
                "Host": "evil.example",
            ]
        }
        let secure = GatewayCoreFakeSession()
        let channel = try makeChannel(url: "wss://gateway.example.com", session: secure, extraHeadersProvider: provider)
        try await channel.connect()
        let request = try #require(secure.latestRequest)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client-1")
        #expect(request.value(forHTTPHeaderField: "Host") == nil)
        #expect(await channel.currentWorkerEdgeCredentials() == ["clientId": "client-1", "clientSecret": "secret"])

        secure.latestSocket?.emitReceiveFailure()
        try await gatewayCoreWaitUntil("secure reconnect") { secure.makeCount == 2 }
        #expect(secure.latestRequest?.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client-2")
        await channel.shutdown()

        let readsBefore = reads.values.count
        let cleartext = GatewayCoreFakeSession()
        let plain = try makeChannel(url: "ws://gateway.example.com", session: cleartext, extraHeadersProvider: provider)
        try await plain.connect()
        #expect(reads.values.count == readsBefore)
        #expect(cleartext.latestRequest?.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        await plain.shutdown()
    }

    @Test
    func unknownHelloFieldsNeverFailTheConnect() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            connectReply: { _ in
                .ok(GatewayCoreFrames.hello(
                    auth: ["scopes": ["operator.read"], "futureAuthKey": ["nested": true]],
                    snapshotOverride: [
                        "presence": [["ts": "not-a-number"], ["ts": 7, "futureKey": 1]],
                        "health": [:],
                        "stateVersion": ["presence": 3, "health": 2],
                        "uptimeMs": 12,
                        "updateAvailable": ["unexpected": "shape"],
                        "suspension": ["phase": ["kind": "future-phase"]],
                    ]))
            }))
        let channel = try makeChannel(session: session)
        try await channel.connect()
        let hello = try #require(await channel.currentHello())
        #expect(hello.snapshot.presence.map(\.ts) == [7])
        #expect(hello.snapshot.stateversion.presence == 3)
        #expect(hello.snapshot.updateavailable == nil)
        #expect(hello.advertisedOperatorScopes() == ["operator.read"])
        await channel.shutdown()
    }

    @Test
    func tlsFailuresSurfaceAsTypedValidationErrors() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(challenge: nil))
        let channel = try makeChannel(url: "wss://gateway.example.com", session: session)
        await channel._test_setConnectTimeoutSeconds(5)
        session.setTLSFailure(GatewayTLSValidationFailure(
            kind: .pinMismatch,
            host: "gateway.example.com",
            storeKey: "gateway.example.com:443",
            expectedFingerprint: "old",
            observedFingerprint: "new",
            systemTrustOk: true))
        let connect = Task { try await channel.connect() }
        try await gatewayCoreWaitUntil("socket opened") { session.makeCount == 1 }
        session.latestSocket?.emitReceiveFailure(URLError(.serverCertificateUntrusted))
        do {
            try await connect.value
            Issue.record("expected a TLS failure")
        } catch let error as GatewayTLSValidationError {
            #expect(error.failure.kind == .pinMismatch)
            #expect(GatewayConnectionProblemMapper.map(error: error)?.canTrustRotatedCertificate == true)
        }
        await channel.shutdown()
    }

    /// The socket never pongs, so only the ping deadline can end the wait (with `URLError`); an unbounded
    /// ping trips the time limit. No wall-clock bound: a saturated test pool can stall the run for seconds.
    @Test(.timeLimit(.minutes(1)))
    func keepalivePingIsBoundedWhenNoPongArrives() async throws {
        let socket = GatewayCoreFakeSocket(script: GatewayCoreSocketScript(pingBehavior: .never))
        let box = WebSocketTaskBox(task: socket)
        await #expect(throws: URLError.self) {
            try await box.sendPing(timeout: .milliseconds(50))
        }

        let duplicate = WebSocketTaskBox(task: GatewayCoreFakeSocket(script: GatewayCoreSocketScript(
            pingBehavior: .duplicateSuccess)))
        try await duplicate.sendPing(timeout: .seconds(5))
    }

    @Test
    func helloPolicyReadsAttachmentCeilingsWithUpstreamDefaults() {
        let advertised = GatewayHelloPolicy(policy: [
            "tickIntervalMs": AnyCodable(20000),
            "maxPayload": AnyCodable(1_048_576),
            "maxBufferedBytes": AnyCodable(-1),
            "attachments": AnyCodable(["maxBytes": AnyCodable(8_388_608), "maxImageBytes": AnyCodable(4_194_304)]),
        ])
        #expect(advertised.tickIntervalMs == 20000)
        #expect(advertised.maxPayloadBytes == 1_048_576)
        #expect(advertised.maxBufferedBytes == nil)
        #expect(advertised.effectiveAttachmentMaxBytes == 8_388_608)
        #expect(advertised.effectiveAttachmentMaxImageBytes == 4_194_304)

        let legacy = GatewayHelloPolicy(policy: [:])
        #expect(legacy.tickIntervalMs == 30000)
        #expect(legacy.maxPayloadBytes == 25 * 1024 * 1024)
        #expect(legacy.effectiveAttachmentMaxBytes == 20 * 1024 * 1024)
        #expect(legacy.effectiveAttachmentMaxImageBytes == 6 * 1024 * 1024)
    }

    @Test
    func profileEventBindingDropsForeignAndUnstampedEvents() {
        let binding = GatewayProfileEventBinding(connectionGeneration: 3, profileID: "Profile-1")
        let own = EventFrame(type: "event", event: "chat", recipientprofileid: "Profile-1")
        #expect(binding.admit(own, connectionGeneration: 3) == .deliver)
        #expect(binding.admit(own, connectionGeneration: 4) == .drop(.staleConnectionGeneration))
        #expect(binding.admit(
            EventFrame(type: "event", event: "chat", recipientprofileid: "profile-1"),
            connectionGeneration: 3) == .drop(.recipientProfileMismatch))
        #expect(binding.admit(EventFrame(type: "event", event: "chat"), connectionGeneration: 3)
            == .drop(.missingRecipientProfile))
    }

    /// The gateway never answers `connect`. Only the 100 ms option can time the handshake out within the
    /// time limit: the fallback budget is an hour, so a channel that ignored the option would trip it. No
    /// wall-clock bound: a saturated test pool can stall the run for seconds.
    @Test(.timeLimit(.minutes(1)))
    func handshakeTimeoutOptionBoundsTheWholeHandshake() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            connectReply: { _ in .none }))
        var options = gatewayCoreOptions()
        options.handshakeTimeoutMs = 100
        let channel = try makeChannel(session: session, options: options)
        await channel._test_setConnectTimeoutSeconds(3600)
        do {
            try await channel.connect()
            Issue.record("expected a handshake timeout")
        } catch {
            #expect((error as NSError).domain == NSURLErrorDomain)
            #expect((error as NSError).code == URLError.timedOut.rawValue)
        }
        #expect(await channel.currentHandshakePhase() == .connectSent)
        #expect(session.latestSocket?.state != .running)
        await channel.shutdown()
    }

    @Test
    func requestLifetimeFinishesExactlyOnce() {
        let lifetime = WebSocketRequestLifetime()
        let finished = GatewayCoreRecorder<Int>()
        let onFinish: @Sendable () -> Void = { finished.append(1) }
        let admitted = lifetime.performIfActive({}, onFinish: onFinish)
        #expect(admitted)
        lifetime.finish()
        lifetime.finish()
        #expect(finished.values == [1])
        let lateAdmission = lifetime.performIfActive({ Issue.record("finished lifetimes must not admit work") }, onFinish: {})
        #expect(!lateAdmission)
    }
}
