import Foundation
import Security
import Testing
@testable import OpenClawKit

private struct FakeClientIdentity: GatewayClientIdentityProviding {
    let fails: Bool

    func urlCredential() async throws -> URLCredential {
        if self.fails { throw URLError(.clientCertificateRequired) }
        return URLCredential(user: "mtls-client", password: "unused", persistence: .forSession)
    }
}

private final class NoopChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private func clientCertificateChallenge() -> URLAuthenticationChallenge {
    URLAuthenticationChallenge(
        protectionSpace: URLProtectionSpace(
            host: "gateway.example.com",
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate),
        proposedCredential: nil,
        previousFailureCount: 0,
        failureResponse: nil,
        error: nil,
        sender: NoopChallengeSender())
}

private func answer(
    _ session: GatewayTLSPinningSession,
    _ challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, String?)
{
    await withCheckedContinuation { continuation in
        session.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            continuation.resume(returning: (disposition, credential?.user))
        }
    }
}

@Suite("Gateway client identity TLS")
struct GatewayClientIdentityTLSTests {
    private let params = GatewayTLSParams(
        required: true,
        expectedFingerprint: nil,
        allowTOFU: false,
        storeKey: nil)

    @Test
    func clientCertificateChallengesUseTheConfiguredIdentity() async {
        let session = GatewayTLSPinningSession(params: self.params, clientIdentity: FakeClientIdentity(fails: false))
        let (disposition, user) = await answer(session, clientCertificateChallenge())
        #expect(disposition == .useCredential)
        #expect(user == "mtls-client")
    }

    @Test
    func unavailableIdentityCancelsAndMissingIdentityUsesDefaultHandling() async {
        let failing = GatewayTLSPinningSession(params: self.params, clientIdentity: FakeClientIdentity(fails: true))
        #expect(await answer(failing, clientCertificateChallenge()).0 == .cancelAuthenticationChallenge)

        let plain = GatewayTLSPinningSession(params: self.params)
        #expect(await answer(plain, clientCertificateChallenge()).0 == .performDefaultHandling)
    }

    @Test
    func identitiesWithoutAnchorsReportNone() async throws {
        #expect(try await FakeClientIdentity(fails: false).anchorCertificates().isEmpty)
    }
}
