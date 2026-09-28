import CryptoKit
import Foundation
import Security
import Testing
@testable import OpenClawKit

private func fixtureFingerprint() -> String {
    SHA256.hash(data: gatewayTLSTestCertificateDER).map { String(format: "%02x", $0) }.joined()
}

@Suite(.gatewayTLSStoreIsolated)
struct GatewayTLSPinRotationTests {
    @Test func `staged next pin is promoted when the renewed certificate appears`() throws {
        let trust = try gatewayTLSTestTrust(systemTrusted: false)
        let storeKey = "profile:staged-rotation"
        let previous = String(repeating: "a", count: 64)
        GatewayTLSStore.saveFingerprint(previous, stableID: storeKey)
        #expect(GatewayTLSStore.stageNextFingerprint("SHA256:\(fixtureFingerprint().uppercased())", stableID: storeKey))
        #expect(GatewayTLSStore.stagedNextFingerprint(stableID: storeKey) == fixtureFingerprint())

        let params = GatewayTLSParams(required: true, expectedFingerprint: nil, allowTOFU: true, storeKey: storeKey)
        #expect(GatewayTLSServerTrust.evaluate(trust: trust, host: "gateway.example", port: 443, params: params) == .accept)
        #expect(GatewayTLSStore.loadFingerprint(stableID: storeKey) == fixtureFingerprint())
        #expect(GatewayTLSStore.stagedNextFingerprint(stableID: storeKey) == nil)
    }

    @Test func `staged pin never overrides an explicitly configured pin`() throws {
        let trust = try gatewayTLSTestTrust(systemTrusted: false)
        let storeKey = "profile:explicit-pin"
        #expect(GatewayTLSStore.stageNextFingerprint(fixtureFingerprint(), stableID: storeKey))
        let params = GatewayTLSParams(
            required: true,
            expectedFingerprint: String(repeating: "b", count: 64),
            allowTOFU: false,
            storeKey: storeKey)
        #expect(GatewayTLSServerTrust.evaluate(trust: trust, host: "gateway.example", port: 443, params: params) == .reject)
    }

    @Test func `system trust only mode ignores pins and requires a trusted chain`() throws {
        let storeKey = "profile:system-only"
        GatewayTLSStore.saveFingerprint(String(repeating: "c", count: 64), stableID: storeKey)
        let params = GatewayTLSParams(
            required: true,
            expectedFingerprint: nil,
            allowTOFU: true,
            storeKey: storeKey,
            requiresSystemTrust: true)

        let trusted = try gatewayTLSTestTrust(systemTrusted: true)
        #expect(GatewayTLSServerTrust.evaluate(trust: trusted, host: "gateway.example", port: 443, params: params) == .accept)
        // No first-use pin is recorded in system-trust-only mode.
        #expect(GatewayTLSStore.loadFingerprint(stableID: storeKey) == String(repeating: "c", count: 64))

        let untrusted = try gatewayTLSTestTrust(systemTrusted: false)
        let pinned = GatewayTLSParams(
            required: true,
            expectedFingerprint: fixtureFingerprint(),
            allowTOFU: false,
            storeKey: nil,
            requiresSystemTrust: true)
        #expect(GatewayTLSServerTrust.evaluate(trust: untrusted, host: "gateway.example", port: 443, params: pinned) == .reject)
    }

    @Test func `pin mismatch produces a reviewable rotation request`() throws {
        let trust = try gatewayTLSTestTrust(systemTrusted: true)
        let storeKey = "profile:rotation-request"
        let previous = String(repeating: "d", count: 64)
        let params = GatewayTLSParams(required: true, expectedFingerprint: nil, allowTOFU: true, storeKey: storeKey)
        GatewayTLSStore.saveFingerprint(previous, stableID: storeKey)

        let evaluation = GatewayTLSServerTrust.evaluate(
            trust: trust,
            host: "gateway.example",
            port: 443,
            params: params,
            expectedFingerprint: previous)
        guard case let .reject(failure, _) = evaluation else {
            Issue.record("Expected a pin mismatch")
            return
        }
        #expect(failure.kind == .pinMismatch)
        #expect(failure.systemTrustOk)
        #expect(GatewayTLSFailureClassification(failure: failure) == .pinMismatch(
            expected: previous,
            presented: fixtureFingerprint()))

        let request = try #require(GatewayTLSPinRotationRequest(failure: failure))
        #expect(request.currentFingerprint == previous)
        #expect(request.presentedFingerprint == fixtureFingerprint())
        #expect(request.isSystemTrusted)
        // The stored pin is never replaced until the app accepts the request.
        #expect(GatewayTLSStore.loadFingerprint(stableID: storeKey) == previous)
        #expect(GatewayTLSStore.acceptRotation(request))
        #expect(GatewayTLSStore.loadFingerprint(stableID: storeKey) == fixtureFingerprint())
        // A stale request (pin already rotated) fails the compare-and-swap.
        #expect(!GatewayTLSStore.acceptRotation(request))
    }

    @Test func `untrusted first use reports the trust failure reason`() throws {
        let trust = try gatewayTLSTestTrust(systemTrusted: true)
        let params = GatewayTLSParams(
            required: true,
            expectedFingerprint: nil,
            allowTOFU: true,
            storeKey: "profile:hostname")
        let evaluation = GatewayTLSServerTrust.evaluate(
            trust: trust,
            host: "other.example",
            port: 443,
            params: params,
            expectedFingerprint: nil)
        guard case let .reject(failure, _) = evaluation else {
            Issue.record("Expected an untrusted certificate")
            return
        }
        #expect(failure.kind == .untrustedCertificate)
        #expect(!failure.systemTrustOk)
        #expect(failure.trustFailureReason == .hostnameMismatch)
        #expect(GatewayTLSFailureClassification(failure: failure) == .hostnameMismatch)
        #expect(GatewayTLSPinRotationRequest(failure: failure) == nil)
    }

    @Test func `URL errors map to stable classifications`() {
        #expect(GatewayTLSFailureClassification(error: URLError(.serverCertificateUntrusted)) == .untrustedChain)
        #expect(GatewayTLSFailureClassification(error: URLError(.serverCertificateHasBadDate)) == .expired)
        #expect(GatewayTLSFailureClassification(error: URLError(.secureConnectionFailed)) == .handshakeFailed)
        #expect(GatewayTLSFailureClassification(error: URLError(.timedOut)) == nil)
        #expect(GatewayTLSFailureClassification.handshakeFailed.requiresUserAction == false)
        #expect(GatewayTLSFailureClassification.pinMismatch(expected: nil, presented: nil).requiresUserAction)
    }

    @Test func `validation error describes both fingerprints on mismatch`() {
        let failure = GatewayTLSValidationFailure(
            kind: .pinMismatch,
            host: "gateway.example",
            storeKey: "k",
            expectedFingerprint: "old",
            observedFingerprint: "new",
            systemTrustOk: true)
        let error = GatewayTLSValidationError(failure: failure, context: "gateway connect")
        #expect(error.errorDescription == "gateway connect: TLS certificate pin mismatch for gateway.example (expected old, observed new)")
        #expect(GatewayTLSFailureClassification(error: error) == .pinMismatch(expected: "old", presented: "new"))
    }

    @Test func `clearing a fingerprint also clears its staged successor`() {
        let storeKey = "profile:clear-staged"
        GatewayTLSStore.saveFingerprint("11", stableID: storeKey)
        #expect(GatewayTLSStore.stageNextFingerprint("22", stableID: storeKey))
        #expect(GatewayTLSStore.clearFingerprint(stableID: storeKey))
        #expect(GatewayTLSStore.loadFingerprint(stableID: storeKey) == nil)
        #expect(GatewayTLSStore.stagedNextFingerprint(stableID: storeKey) == nil)
    }
}
