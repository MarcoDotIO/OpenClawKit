#if canImport(Network) && os(macOS)
import Foundation
import Network
import Testing
@testable import OpenClawKit

/// Minimal loopback gateway speaking WebSocket through Network.framework's server-side protocol.
@available(macOS 26.0, *)
private final class NetworkConnectionLoopbackGateway: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "openclaw.network-connection-loopback")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var methods: [String] = []
    private var upgradeHeaderSeen = false

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> NetworkConnectionLoopbackGateway {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let gateway = NetworkConnectionLoopbackGateway(listener: listener)
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
        URL(string: "ws://127.0.0.1:\(self.listener.port?.rawValue ?? 0)/gateway")!
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

@Suite("Network.framework gateway transport", .serialized)
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

    @Test
    func tlsPolicyEnforcesPinsAndTrustBeforeFirstUse() {
        guard #available(macOS 26.0, *) else { return }
        let pin = String(repeating: "ab", count: 32)
        let pinned = GatewayTLSParams(required: true, expectedFingerprint: "SHA256:" + pin.uppercased(), allowTOFU: false, storeKey: nil)
        guard case .accepted(_, true) = NetworkConnectionTLSValidator.decide(
            observed: pin, systemTrustOk: false, host: "gw", port: 443, params: pinned)
        else {
            Issue.record("a matching pin must be accepted and enforced")
            return
        }
        guard case let .rejected(mismatch) = NetworkConnectionTLSValidator.decide(
            observed: String(repeating: "cd", count: 32), systemTrustOk: true, host: "gw", port: 443, params: pinned)
        else {
            Issue.record("a different certificate must be rejected")
            return
        }
        #expect(mismatch.kind == .pinMismatch)
        #expect(mismatch.systemTrustOk)

        let firstUse = GatewayTLSParams(required: true, expectedFingerprint: nil, allowTOFU: true, storeKey: nil)
        guard case .accepted(pin, true) = NetworkConnectionTLSValidator.decide(
            observed: pin, systemTrustOk: true, host: "gw", port: nil, params: firstUse)
        else {
            Issue.record("first use after system trust must pin the certificate")
            return
        }
        guard case let .rejected(untrusted) = NetworkConnectionTLSValidator.decide(
            observed: pin, systemTrustOk: false, host: "gw", port: nil, params: firstUse)
        else {
            Issue.record("first use without system trust must fail closed")
            return
        }
        #expect(untrusted.kind == .untrustedCertificate)
        guard case .rejected = NetworkConnectionTLSValidator.decide(
            observed: pin, systemTrustOk: false, host: "gw", port: nil, params: nil)
        else {
            Issue.record("system trust must decide without pinning parameters")
            return
        }
        #expect(NetworkConnectionTLSValidator.normalize(" sha256:AB:CD ") == "abcd")
    }
}
#endif
