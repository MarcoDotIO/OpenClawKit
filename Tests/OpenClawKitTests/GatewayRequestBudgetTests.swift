import Foundation
import Testing
@testable import OpenClawKit

private func budgetChannel(session: GatewayCoreFakeSession) throws -> GatewayChannelActor {
    GatewayChannelActor(
        url: try #require(URL(string: "ws://127.0.0.1:18789")),
        token: nil,
        session: WebSocketSessionBox(session: session),
        connectOptions: gatewayCoreOptions())
}

@Suite("Gateway request budget", .serialized, .timeLimit(.minutes(1)))
struct GatewayRequestBudgetTests {
    @Test
    func slowConnectDoesNotConsumeTheRequestBudget() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            challenge: nil,
            requestReply: { method, _ in .ok(["echo": method]) }))
        let channel = try budgetChannel(session: session)
        await channel._test_setConnectTimeoutSeconds(5)
        let request = Task {
            try await channel.request(method: "chat.send", params: nil, timeoutMs: 300)
        }
        try await gatewayCoreWaitUntil("socket opened") { session.makeCount == 1 }
        // The handshake takes longer than the whole request budget.
        try await Task.sleep(for: .milliseconds(500))
        session.latestSocket?.emit(GatewayCoreFrames.challenge())

        let data = try await request.value
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["echo"] as? String == "chat.send")
        #expect(session.latestSocket?.sentFrames(method: "chat.send").count == 1)
        await channel.shutdown()
    }

    @Test
    func unboundedTimeoutsAndTickIntervalsNeverTrap() async throws {
        #expect(GatewayChannelActor.sleepNanoseconds(milliseconds: 1.5) == 1_500_000)
        #expect(GatewayChannelActor.sleepNanoseconds(milliseconds: 1e13 * 2) == UInt64.max)
        #expect(GatewayChannelActor.sleepNanoseconds(milliseconds: .infinity) == UInt64.max)
        #expect(GatewayChannelActor.sleepNanoseconds(milliseconds: .nan) == 0)
        #expect(GatewayChannelActor.sleepNanoseconds(milliseconds: -5) == 0)
        #expect(GatewayChannelActor.resolveRequestTimeoutMs(nil, defaultMs: 15000) == 15000)
        #expect(GatewayChannelActor.resolveRequestTimeoutMs(250, defaultMs: 15000) == 250)
        for unbounded in [0, -1, Double.infinity, -Double.infinity, Double.nan] {
            #expect(GatewayChannelActor.resolveRequestTimeoutMs(unbounded, defaultMs: 15000) == nil)
        }

        let huge = GatewayHelloPolicy(policy: ["tickIntervalMs": AnyCodable(10_000_000_000_000)])
        #expect(huge.tickIntervalMs == GatewayHelloPolicy.advertisedTickIntervalRangeMs.upperBound)
        let tiny = GatewayHelloPolicy(policy: ["tickIntervalMs": AnyCodable(0.5)])
        #expect(tiny.tickIntervalMs == GatewayHelloPolicy.advertisedTickIntervalRangeMs.lowerBound)

        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            connectReply: { _ in .ok(GatewayCoreFrames.hello(policy: ["tickIntervalMs": 1e13])) },
            requestReply: { method, _ in .ok(["echo": method]) }))
        let channel = try budgetChannel(session: session)
        try await channel.connect()
        #expect(await channel.currentHelloPolicy().tickIntervalMs == 600_000)
        // The tick watchdog and an unbounded caller deadline used to trap converting to UInt64.
        _ = try await channel.request(method: "status", params: nil, timeoutMs: .infinity)
        _ = try await channel.request(method: "status", params: nil, timeoutMs: .nan)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await channel.currentConnectionGeneration() != nil)
        await channel.shutdown()
    }
}
