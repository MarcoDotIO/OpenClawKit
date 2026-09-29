import Foundation
import Testing
@testable import OpenClawKit

private let oldPin = String(repeating: "a", count: 64)
private let newPin = String(repeating: "b", count: 64)

private func mismatch(storeKey: String) -> GatewayTLSValidationFailure {
    GatewayTLSValidationFailure(
        kind: .pinMismatch,
        host: "gateway.example.com",
        storeKey: storeKey,
        expectedFingerprint: oldPin,
        observedFingerprint: newPin,
        systemTrustOk: true,
        port: 443)
}

@Suite("Gateway TLS pin rotation recovery", .serialized, .gatewayTLSStoreIsolated)
struct GatewayTLSPinRotationRecoveryTests {
    @Test
    func pinningSessionAcceptsAReviewedRotationInPlace() throws {
        let storeKey = "rotation-\(UUID().uuidString)"
        GatewayTLSStore.saveFingerprint(oldPin, stableID: storeKey)
        let session = GatewayTLSPinningSession(params: GatewayTLSParams(
            required: true, expectedFingerprint: nil, allowTOFU: true, storeKey: storeKey))
        let request = try #require(GatewayTLSPinRotationRequest(failure: mismatch(storeKey: storeKey)))

        #expect(session.acceptPinRotation(request))
        #expect(GatewayTLSStore.loadFingerprint(stableID: storeKey) == newPin)
        #expect(session.allowsDeviceTokenRetryAuth, "the rotated pin is enforced in memory")
        // Compare-and-swap: the reviewed pin is no longer current.
        #expect(!session.acceptPinRotation(request))

        let explicit = GatewayTLSPinningSession(params: GatewayTLSParams(
            required: true, expectedFingerprint: oldPin, allowTOFU: false, storeKey: storeKey))
        #expect(!explicit.acceptPinRotation(request))
        let otherKey = GatewayTLSPinningSession(params: GatewayTLSParams(
            required: true, expectedFingerprint: nil, allowTOFU: true, storeKey: "other"))
        #expect(!otherKey.acceptPinRotation(request))
    }

    @Test
    func channelAcceptsThePendingRotationAndReconnects() async throws {
        let storeKey = "channel-rotation-\(UUID().uuidString)"
        GatewayTLSStore.saveFingerprint(oldPin, stableID: storeKey)
        let session = GatewayCoreFakeSession(script: { index in
            index == 0 ? GatewayCoreSocketScript(challenge: nil) : GatewayCoreSocketScript()
        })
        let channel = GatewayChannelActor(
            url: try #require(URL(string: "wss://gateway.example.com")),
            token: nil,
            session: WebSocketSessionBox(session: session),
            connectOptions: gatewayCoreOptions())
        await channel._test_setConnectTimeoutSeconds(5)
        session.setTLSFailure(mismatch(storeKey: storeKey))
        let connect = Task { try await channel.connect() }
        try await gatewayCoreWaitUntil("socket opened") { session.makeCount == 1 }
        session.latestSocket?.emitReceiveFailure(URLError(.cancelled))
        await #expect(throws: GatewayTLSValidationError.self) { try await connect.value }

        let request = try #require(await channel.pendingTLSPinRotationRequest())
        let unrelated = try #require(GatewayTLSPinRotationRequest(failure: mismatch(storeKey: "unrelated")))
        #expect(await channel.acceptTLSPinRotation(unrelated) == false)
        #expect(await channel.acceptTLSPinRotation(request))
        #expect(GatewayTLSStore.loadFingerprint(stableID: storeKey) == newPin)
        try await gatewayCoreWaitUntil("reconnected") {
            await channel.currentConnectionGeneration() != nil
        }
        #expect(await channel.reconnectPauseReason() == nil)
        await channel.shutdown()
    }
}
