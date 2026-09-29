#if canImport(Network) && os(macOS)
import CryptoKit
import Foundation
import Network
import Security
import Testing
@testable import OpenClawKit

/// Self-signed P-256 identity for `127.0.0.1` (test-only, PKCS#12 passphrase `openclaw`).
private let loopbackTLSIdentityPKCS12 = Data(
    base64Encoded: [
        "MIIDWgIBAzCCAyAGCSqGSIb3DQEHAaCCAxEEggMNMIIDCTCCAf8GCSqGSIb3DQEHBqCCAfAwggHsAgEAMIIB5QYJKoZIhvcNAQcB",
        "MBwGCiqGSIb3DQEMAQYwDgQIyyiTuDf1yFUCAggAgIIBuAJHEHaqChqmfFpO0zA1aZA0jUoGNL0llR2TlgGktg+QnM+B8k/l34A2",
        "0lvjqDtfHZRf8orxoz/rcyPN0LYxsQZlxerIHYqSiCxGczOYGjMqiA47ieD+dAG400Ilc/9r6nkcpn2i4wOfuoPoq+gBlyd6gTa8",
        "L57D7SN0GaIvBr+piJNB8POyxk5gFrqa7cxGgO2y+Rc2F0ut9Sy/ZwrZUjMkHGMSMLmYS6bucqsNXAHmltBY9WIptlIMAEklYQ9/",
        "N5sYr4I+dbZ5s5K5CxyNcydPsR5NYaFWiyDW2h8FSJnc3gBC+07rB3ejBRNM31a7PThFjmyfrFzxPcTGA7NR05lcZNwuUf+kaAI7",
        "UWq9H5l+e0AzqNIWI9GzpN9+kD43mtGCi5gsismHxmeaMf+fqR+NTGgXah4z0nkyuF7oDa2rMmWc1YR3/KID5GGfAJ2zU7V9zp9P",
        "fVlprU8DEJl/KABt30DcCpB4CsIY9GS13sn7SU/zkdCdQHhaTlo926KipCxycVaHRj5c2eKcPYLGhA6Rc+AK1qpmjnryB0DzP1cS",
        "H4fvDWgi1ZjeKA/SVEi2PxyEvGNirOKAMIIBAgYJKoZIhvcNAQcBoIH0BIHxMIHuMIHrBgsqhkiG9w0BDAoBAqCBtDCBsTAcBgoq",
        "hkiG9w0BDAEDMA4ECHY5f+5wSNmuAgIIAASBkDQJWhdy/t+NpVcP7Cqgzk1O7CtznjKJQB6HVSiUtoXuWSAIXx5vIhj7Z/pNxs0Y",
        "2xYpobw/6QkuilqFST8IKFEObqRlQ9Sg38Q4hZdC70U7w9146WBP2eU1UUQyTIgmoLUHxuQTBclDVt6HZoLtsdhu0I9YC5mNxam0",
        "PJdsQTD/VwDvIc/GovDDxYl1YpJKcTElMCMGCSqGSIb3DQEJFTEWBBTNpqofHTl6FRako/27OPhbE25j5TAxMCEwCQYFKw4DAhoF",
        "AAQU/cgikBRNq3c3BTPOOBsWYYjKGuoECGWNoquFKm/BAgIIAA==",
    ].joined())!

@available(macOS 15.0, *)
private func loopbackTLSIdentity() throws -> (identity: SecIdentity, fingerprint: String) {
    var items: CFArray?
    let options: [String: Any] = [
        kSecImportExportPassphrase as String: "openclaw",
        kSecImportToMemoryOnly as String: true,
    ]
    try #require(SecPKCS12Import(loopbackTLSIdentityPKCS12 as CFData, options as CFDictionary, &items) == errSecSuccess)
    let item = try #require((items as? [[String: Any]])?.first)
    let identityValue = try #require(item[kSecImportItemIdentity as String])
    let identity = identityValue as! SecIdentity
    var certificate: SecCertificate?
    try #require(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
    let der = SecCertificateCopyData(try #require(certificate)) as Data
    return (identity, SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined())
}

private func gatewayExampleFingerprint() -> String {
    SHA256.hash(data: gatewayTLSTestCertificateDER).map { String(format: "%02x", $0) }.joined()
}

private func tlsStoreAccount(_ stableID: String) -> String {
    let component = Data(stableID.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "fingerprint.v3.\(component)"
}

/// Minimal loopback gateway speaking WebSocket through Network.framework's server-side protocol.
@available(macOS 26.0, *)
private final class NetworkConnectionLoopbackGateway: @unchecked Sendable {
    private let listener: NWListener
    private let scheme: String
    private let queue = DispatchQueue(label: "openclaw.network-connection-loopback")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var methods: [String] = []
    private var accepted = 0

    private init(listener: NWListener, scheme: String) {
        self.listener = listener
        self.scheme = scheme
    }

    static func start(tlsIdentity: SecIdentity? = nil) async throws -> NetworkConnectionLoopbackGateway {
        let parameters: NWParameters
        if let tlsIdentity {
            let tls = NWProtocolTLS.Options()
            let identity = try #require(sec_identity_create(tlsIdentity))
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters.tcp
        }
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let gateway = NetworkConnectionLoopbackGateway(listener: listener, scheme: tlsIdentity == nil ? "ws" : "wss")
        listener.newConnectionHandler = { [weak gateway] connection in
            gateway?.accept(connection)
        }
        listener.start(queue: gateway.queue)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if case .ready = listener.state, let port = listener.port, port.rawValue != 0 {
                return gateway
            }
            if case let .failed(error) = listener.state {
                throw error
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        listener.cancel()
        throw URLError(.timedOut)
    }

    var url: URL {
        URL(string: "\(self.scheme)://127.0.0.1:\(self.listener.port?.rawValue ?? 0)/gateway")!
    }

    /// Connections that completed the WebSocket upgrade.
    var acceptedConnections: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.accepted
    }

    var receivedMethods: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.methods
    }

    func stop() {
        self.listener.cancel()
        self.lock.lock()
        let connections = self.connections
        self.connections.removeAll()
        self.lock.unlock()
        for connection in connections {
            connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        self.lock.lock()
        self.connections.append(connection)
        self.lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, case .ready = state else { return }
            self.lock.lock()
            self.accepted += 1
            self.lock.unlock()
            self.send(GatewayCoreFrames.challenge(nonce: "network-nonce"), on: connection)
            self.receive(on: connection)
        }
        connection.start(queue: self.queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data,
               let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               frame["type"] as? String == "req",
               let id = frame["id"] as? String,
               let method = frame["method"] as? String
            {
                self.lock.lock()
                self.methods.append(method)
                self.lock.unlock()
                let payload: [String: Any] = method == "connect"
                    ? GatewayCoreFrames.hello()
                    : ["echo": method]
                self.send(["type": "res", "id": id, "ok": true, "payload": payload], on: connection)
            }
            self.receive(on: connection)
        }
    }

    private func send(_ frame: [String: Any], on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(
            content: GatewayCoreJSON.data(frame),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in })
    }
}

@Suite("Network.framework gateway transport", .serialized, .gatewayTLSStoreIsolated)
struct GatewayNetworkConnectionTransportTests {
    @Test
    func handshakeAndRequestsRunOverNetworkConnection() async throws {
        guard #available(macOS 26.0, *) else { return }
        let gateway = try await NetworkConnectionLoopbackGateway.start()
        defer { gateway.stop() }
        let pathEvents = GatewayCoreRecorder<NetworkConnectionPathEvent>()
        let session = NetworkConnectionWebSocketSession(onPathEvent: { pathEvents.append($0) })
        let channel = GatewayChannelActor(
            url: gateway.url,
            token: "shared",
            session: WebSocketSessionBox(session: session),
            connectOptions: gatewayCoreOptions())
        try await channel.connect()
        #expect(await channel.negotiatedProtocolVersion() == 4)
        #expect(await channel.currentConnectionGeneration() != nil)

        let data = try await channel.request(method: "status", params: nil, timeoutMs: 5000)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["echo"] as? String == "status")
        #expect(gateway.receivedMethods == ["connect", "status"])
        await channel.shutdown()
    }

    // MARK: TLS policy (shared with GatewayTLSPinningSession)

    @Test
    func explicitPinsAreEnforcedAndSurviveAsDeviceTokenTrust() throws {
        guard #available(macOS 26.0, *) else { return }
        let url = try #require(URL(string: "wss://gateway.example/gateway"))
        let untrusted = try gatewayTLSTestTrust(systemTrusted: false)
        let pinned = NetworkConnectionWebSocketSession(tls: GatewayTLSParams(
            required: true,
            expectedFingerprint: "SHA256:" + gatewayExampleFingerprint().uppercased(),
            allowTOFU: false,
            storeKey: nil))
        #expect(pinned.serverTrustFailure(untrusted, for: url) == nil)
        #expect(pinned.allowsDeviceTokenRetryAuth)
        #expect(pinned.effectiveTLSFingerprintSHA256 == gatewayExampleFingerprint())

        let other = NetworkConnectionWebSocketSession(tls: GatewayTLSParams(
            required: true,
            expectedFingerprint: String(repeating: "cd", count: 32),
            allowTOFU: false,
            storeKey: "gw"))
        let mismatch = try #require(other.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: true), for: url))
        #expect(mismatch.kind == .pinMismatch)
        #expect(mismatch.systemTrustOk)
        #expect(mismatch.observedFingerprint == gatewayExampleFingerprint())
    }

    @Test
    func emptyExplicitPinFailsClosed() throws {
        guard #available(macOS 26.0, *) else { return }
        let url = try #require(URL(string: "wss://gateway.example/gateway"))
        for empty in ["", "sha256:"] {
            let session = NetworkConnectionWebSocketSession(tls: GatewayTLSParams(
                required: true, expectedFingerprint: empty, allowTOFU: true, storeKey: "empty-pin"))
            let failure = session.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: true), for: url)
            #expect(failure?.kind == .pinMismatch)
        }
        #expect(GatewayTLSStore.loadFingerprint(stableID: "empty-pin") == nil, "an empty pin must never trigger first use")
    }

    @Test
    func requiresSystemTrustIgnoresPinsAndRequiredFalse() throws {
        guard #available(macOS 26.0, *) else { return }
        let url = try #require(URL(string: "wss://gateway.example/gateway"))
        let pinnedSystemOnly = NetworkConnectionWebSocketSession(tls: GatewayTLSParams(
            required: true,
            expectedFingerprint: gatewayExampleFingerprint(),
            allowTOFU: true,
            storeKey: "system-only",
            requiresSystemTrust: true))
        let pinnedFailure = pinnedSystemOnly.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: false), for: url)
        #expect(pinnedFailure?.kind == .untrustedCertificate)

        let optionalSystemOnly = NetworkConnectionWebSocketSession(tls: GatewayTLSParams(
            required: false, expectedFingerprint: nil, allowTOFU: false, storeKey: nil, requiresSystemTrust: true))
        let optionalFailure = optionalSystemOnly.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: false), for: url)
        #expect(optionalFailure?.kind == .untrustedCertificate)

        #expect(pinnedSystemOnly.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: true), for: url) == nil)
        #expect(!pinnedSystemOnly.allowsDeviceTokenRetryAuth, "system-trust-only mode never pins")
        #expect(GatewayTLSStore.loadFingerprint(stableID: "system-only") == nil)
    }

    @Test
    func systemTrustWithoutParamsIsBoundToTheRequestedHost() throws {
        guard #available(macOS 26.0, *) else { return }
        let session = NetworkConnectionWebSocketSession()
        let matching = try #require(URL(string: "wss://gateway.example/gateway"))
        let otherHost = try #require(URL(string: "wss://other.example/gateway"))
        #expect(session.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: true), for: matching) == nil)
        #expect(session.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: true), for: otherHost)?.kind
            == .untrustedCertificate)
        #expect(session.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: false), for: matching)?.kind
            == .untrustedCertificate)
        #expect(!session.allowsDeviceTokenRetryAuth)
    }

    @Test
    func trustedFirstUseIsClaimedAndNeedsAStoreKey() throws {
        guard #available(macOS 26.0, *) else { return }
        let url = try #require(URL(string: "wss://gateway.example/gateway"))
        let noStore = NetworkConnectionWebSocketSession(tls: GatewayTLSParams(
            required: true, expectedFingerprint: nil, allowTOFU: true, storeKey: nil))
        let unsaved = noStore.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: true), for: url)
        #expect(unsaved?.kind == .pinStorageUnavailable, "a pin that cannot be persisted is never reported as enforced")
        #expect(!noStore.allowsDeviceTokenRetryAuth)

        let storeKey = "network-first-use"
        let firstUse = NetworkConnectionWebSocketSession(tls: GatewayTLSParams(
            required: true, expectedFingerprint: nil, allowTOFU: true, storeKey: storeKey))
        #expect(firstUse.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: true), for: url) == nil)
        #expect(GatewayTLSStore.loadFingerprint(stableID: storeKey) == gatewayExampleFingerprint())
        #expect(firstUse.allowsDeviceTokenRetryAuth)
        // The enforced pin survives reconnects even when system trust later fails.
        #expect(firstUse.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: false), for: url) == nil)
    }

    @Test
    func unreadableStoredPinFailsClosedWithoutOverwritingIt() throws {
        guard #available(macOS 26.0, *) else { return }
        let url = try #require(URL(string: "wss://gateway.example/gateway"))
        let storeKey = "network-unreadable-pin"
        // A v3 record without its comparison attribute reads as unavailable, not missing.
        try #require(GatewayTLSStoreFixture.current).seed(
            account: tlsStoreAccount(storeKey),
            data: Data(String(repeating: "e", count: 64).utf8))
        let session = NetworkConnectionWebSocketSession(tls: GatewayTLSParams(
            required: true, expectedFingerprint: nil, allowTOFU: true, storeKey: storeKey))
        let failure = session.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: true), for: url)
        #expect(failure?.kind == .pinStorageUnavailable)
        #expect(GatewayTLSStore.loadFingerprint(stableID: storeKey) == nil, "the unreadable pin must not be replaced")
        #expect(!session.allowsDeviceTokenRetryAuth)
    }

    @Test
    func lockedKeychainNeverIssuesAPinWrite() throws {
        guard #available(macOS 26.0, *) else { return }
        let url = try #require(URL(string: "wss://gateway.example/gateway"))
        let writes = GatewayCoreRecorder<String>()
        let locked = GatewayTLSKeychainOperations(
            copyMatching: { _, _ in errSecInteractionNotAllowed },
            add: { _ in
                writes.append("add")
                return errSecSuccess
            },
            update: { _, _ in
                writes.append("update")
                return errSecSuccess
            },
            delete: { _ in errSecSuccess })
        let trust = try gatewayTLSTestTrust(systemTrusted: true)
        let failure = GatewayTLSStore.$keychainOperations.withValue(locked) {
            NetworkConnectionWebSocketSession(tls: GatewayTLSParams(
                required: true, expectedFingerprint: nil, allowTOFU: true, storeKey: "network-locked"))
                .serverTrustFailure(trust, for: url)
        }
        #expect(failure?.kind == .pinStorageUnavailable)
        #expect(writes.values.isEmpty)
    }

    @Test
    func aNewTaskDropsTheRejectionOfAnEarlierAttempt() throws {
        guard #available(macOS 26.0, *) else { return }
        let url = try #require(URL(string: "wss://gateway.example/gateway"))
        let session = NetworkConnectionWebSocketSession(tls: GatewayTLSParams(
            required: true, expectedFingerprint: String(repeating: "0", count: 64), allowTOFU: false, storeKey: "gw"))
        #expect(session.serverTrustFailure(try gatewayTLSTestTrust(systemTrusted: true), for: url) != nil)
        _ = session.makeWebSocketTask(url: url)
        #expect(session.consumeLastTLSFailure() == nil, "a later timeout must not pick up the stale mismatch")
    }

    // MARK: TLS end to end

    @Test
    func pinnedTLSHandshakeRunsOverNetworkConnection() async throws {
        guard #available(macOS 26.0, *) else { return }
        let (identity, fingerprint) = try loopbackTLSIdentity()
        let gateway = try await NetworkConnectionLoopbackGateway.start(tlsIdentity: identity)
        defer { gateway.stop() }
        let session = NetworkConnectionWebSocketSession(tls: GatewayTLSParams(
            required: true, expectedFingerprint: fingerprint, allowTOFU: false, storeKey: nil))
        let channel = GatewayChannelActor(
            url: gateway.url,
            token: "shared",
            session: WebSocketSessionBox(session: session),
            connectOptions: gatewayCoreOptions())
        try await channel.connect()
        #expect(session.effectiveTLSFingerprintSHA256 == fingerprint)
        #expect(session.allowsDeviceTokenRetryAuth)
        #expect(gateway.receivedMethods == ["connect"])
        await channel.shutdown()
    }

    @Test
    func pinMismatchOverNetworkConnectionPausesReconnectsWithARotationRequest() async throws {
        guard #available(macOS 26.0, *) else { return }
        let (identity, fingerprint) = try loopbackTLSIdentity()
        let gateway = try await NetworkConnectionLoopbackGateway.start(tlsIdentity: identity)
        defer { gateway.stop() }
        let stalePin = String(repeating: "a", count: 64)
        let session = NetworkConnectionWebSocketSession(tls: GatewayTLSParams(
            required: true, expectedFingerprint: stalePin, allowTOFU: false, storeKey: "loopback-rotation"))
        let channel = GatewayChannelActor(
            url: gateway.url,
            token: "shared",
            session: WebSocketSessionBox(session: session),
            connectOptions: gatewayCoreOptions())
        await channel._test_setConnectTimeoutSeconds(5)
        do {
            try await channel.connect()
            Issue.record("a certificate that does not match the pin must be rejected")
        } catch let error as GatewayTLSValidationError {
            #expect(error.failure.kind == .pinMismatch)
            #expect(error.failure.expectedFingerprint == stalePin)
            #expect(error.failure.observedFingerprint == fingerprint)
            #expect(GatewayConnectionProblemMapper.map(error: error)?.kind != nil)
        }
        #expect(await channel.reconnectPauseReason() == .tlsPinMismatch)
        let request = try #require(await channel.pendingTLSPinRotationRequest())
        #expect(request.currentFingerprint == stalePin)
        #expect(request.presentedFingerprint == fingerprint)
        #expect(!request.isSystemTrusted)

        // Reconnects stay paused instead of retrying the changed certificate with backoff.
        await channel.nudgeReconnect()
        try await Task.sleep(for: .milliseconds(800))
        #expect(gateway.acceptedConnections == 0)
        #expect(gateway.receivedMethods.isEmpty)
        await channel.shutdown()
    }

    @Test
    func closeCodesMapIncludingApplicationCodes() {
        guard #available(macOS 26.0, *) else { return }
        #expect(NetworkConnectionWebSocketTask.networkCloseCode(.goingAway) == .protocolCode(.goingAway))
        #expect(NetworkConnectionWebSocketTask.networkCloseCode(.normalClosure) == .protocolCode(.normalClosure))
        let tick = URLSessionWebSocketTask.CloseCode(rawValue: 4000) ?? .goingAway
        #expect(NetworkConnectionWebSocketTask.networkCloseCode(tick) == .applicationCode(4000))
    }
}
#endif
