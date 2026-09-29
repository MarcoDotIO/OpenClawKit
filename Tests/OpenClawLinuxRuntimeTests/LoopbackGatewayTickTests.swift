import Foundation
import Testing
import OpenClawGateway
import OpenClawProtocol

/// Server-backed loopback ticks keep `GatewayClient` connections alive (2026.3.0 FX1 review fix).
@Suite("Loopback gateway ticks")
struct LoopbackGatewayTickTests {
    typealias Harness = GatewayServerTestHarness

    @Test
    func serverBackedLoopbackSocketsEmitUpstreamTicks() async throws {
        let (server, _) = Harness.bareServer("robust-tick-frames")
        let socket = LoopbackGatewaySocket(server: server, connection: GatewayConnectionContext(connectionID: "ticks", scopes: []), tickIntervalMs: 10)
        try await socket.connect(url: URL(string: "ws://127.0.0.1:18789")!)
        let raw = try await socket.receive()
        let frame = try JSONDecoder().decode(EventFrame.self, from: Data(raw.utf8))
        #expect(frame.event == "tick")
        #expect(frame.payload?.dictionaryValue?["ts"]?.int64Value != nil)
        await socket.close()
    }

    @Test
    func loopbackClientKeepsItsConnectionAndSubscriptionsPastTheTickDeadline() async throws {
        let (server, _) = Harness.bareServer("robust-ticks")
        let context = GatewayConnectionContext(connectionID: "tick-client", scopes: ["operator.admin"])
        let factory = SocketCounter()
        // Without server ticks the client watchdog (deadline 2 × 250 ms) would drop the idle
        // connection and wipe its subscriptions well before the 1.5 s sleep ends.
        let client = GatewayClient(
            socketFactory: {
                factory.increment()
                return LoopbackGatewaySocket(server: server, connection: context, tickIntervalMs: 10)
            },
            tickIntervalMs: 250
        )
        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        let subscribed = try await client.send(method: "sessions.messages.subscribe", params: ["key": AnyCodable("agent:main:main")])
        #expect(subscribed.ok)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(await server.sessionMessageSubscriptions(connectionID: "tick-client") == ["agent:main:main"])
        #expect(factory.count == 1)
        let connected = await client.isConnected()
        #expect(connected)
        await client.disconnect()
    }

    final class SocketCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }

        func increment() {
            self.lock.lock()
            self.value += 1
            self.lock.unlock()
        }
    }
}
