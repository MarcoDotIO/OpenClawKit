import Foundation
import Testing
import OpenClawKit

@Suite("Approval trust signals")
struct ApprovalTrustSignalsTests {
    actor FakeSignals: OpenClawApprovalTrustSignals {
        let risk: OpenClawCoachingRisk
        private(set) var outcomes: [(OpenClawSensitiveOperation, Bool)] = []

        init(risk: OpenClawCoachingRisk) {
            self.risk = risk
        }

        func coachingRisk(for operation: OpenClawSensitiveOperation) async -> OpenClawCoachingRisk {
            self.risk
        }

        func recordOutcome(_ operation: OpenClawSensitiveOperation, frictionApplied: Bool) async {
            self.outcomes.append((operation, frictionApplied))
        }

        func recorded() -> [(OpenClawSensitiveOperation, Bool)] {
            self.outcomes
        }
    }

    @Test
    func highRiskRequiresReauthenticationBeforeApprovals() async {
        let signals = FakeSignals(risk: .high)
        let gate = OpenClawApprovalGate(signals: signals)
        let pairing = await gate.evaluate(.approveDevicePairing(requestId: "req-1"))
        #expect(pairing.risk == .high)
        #expect(pairing.friction == .reauthenticate)
        #expect(pairing.requiresFriction)

        let allowAlways = await gate.evaluate(.resolveExecApproval(id: "ap-1", decision: "allow-always"))
        #expect(allowAlways.friction == .reauthenticate)

        let deny = await gate.evaluate(.resolveExecApproval(id: "ap-2", decision: "deny"))
        #expect(deny.friction == .none)

        await gate.recordOutcome(pairing)
        await gate.recordOutcome(deny)
        let outcomes = await signals.recorded()
        #expect(outcomes.map(\.1) == [true, false])
        #expect(outcomes.first?.0 == .approveDevicePairing(requestId: "req-1"))
    }

    @Test
    func mediumRiskWarnsOnlyForPersistentAccess() async {
        let gate = OpenClawApprovalGate(signals: FakeSignals(risk: .medium))
        #expect(await gate.evaluate(.resolveExecApproval(id: "1", decision: "allow-once")).friction == .none)
        #expect(await gate.evaluate(.resolveExecApproval(id: "2", decision: "allow-always")).friction == .warn)
        #expect(await gate.evaluate(.rotateDeviceToken(deviceId: "d")).friction == .warn)
    }

    @Test
    func unavailableSignalsNeverAddFriction() async {
        let gate = OpenClawApprovalGate(signals: NoopApprovalTrustSignals())
        let evaluation = await gate.evaluate(.approveDevicePairing(requestId: "r"))
        #expect(evaluation.risk == .unavailable)
        #expect(!evaluation.requiresFriction)
        #if !os(iOS)
        #expect(OpenClawApprovalTrustSignalsFactory.makeDefault() is NoopApprovalTrustSignals)
        #endif
    }

    @Test
    func operationsExposeRequestIdentifiersAndPolicyIsConfigurable() {
        #expect(OpenClawSensitiveOperation.approveDevicePairing(requestId: "a").requestID == "a")
        #expect(OpenClawSensitiveOperation.resolveExecApproval(id: "b", decision: "deny").requestID == "b")
        #expect(OpenClawSensitiveOperation.rotateDeviceToken(deviceId: "c").requestID == "c")
        let lenient = OpenClawApprovalFrictionPolicy(highRiskFriction: .warn, mediumRiskFriction: .none)
        #expect(lenient.friction(for: .high, operation: .approveDevicePairing(requestId: "x")) == .warn)
        #expect(lenient.friction(for: .medium, operation: .approveDevicePairing(requestId: "x")) == .none)
        #expect(OpenClawApprovalFriction.none < .warn)
        #expect(OpenClawApprovalFriction.warn < .reauthenticate)
    }
}
