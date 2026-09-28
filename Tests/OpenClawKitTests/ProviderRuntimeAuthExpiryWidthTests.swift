import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit

/// Copilot `expires_at` parsing runs in Int64 so it compiles and cannot trap on 32-bit `Int`
/// platforms (watchOS arm64_32); out-of-range values surface as errors instead of crashes.
@Suite("Provider runtime auth expiry width")
struct ProviderRuntimeAuthExpiryWidthTests {
    private static let copilotTokenURL = "https://api.github.com/copilot_internal/v2/token"

    private static func exchange(expiresAtJSON: String) async throws -> ProviderRuntimeAuthResolution {
        let transport = ProviderRuntimeAuthTests.MockRuntimeAuthTransport()
        await transport.enqueue(
            url: Self.copilotTokenURL,
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"token": "copilot-token", "expires_at": \#(expiresAtJSON)}"#.utf8)
            )
        )
        let resolver = RuntimeProviderAuthResolver(transport: transport, now: { 1_000_000 })
        return try await resolver.resolve(
            providerID: "github-copilot",
            credential: .token(TokenAuthProfileCredential(provider: "github-copilot", token: "ghu_123"))
        )
    }

    private static func expires(_ resolution: ProviderRuntimeAuthResolution) -> Int64? {
        guard case .token(let credential) = resolution.credential else { return nil }
        return credential.expires
    }

    @Test
    func millisecondExpiryPassesThrough() async throws {
        let resolution = try await Self.exchange(expiresAtJSON: "1900000000000")
        #expect(Self.expires(resolution) == 1_900_000_000_000)
    }

    @Test
    func secondExpiryFromStringAndDoubleIsScaledToMilliseconds() async throws {
        let fromString = try await Self.exchange(expiresAtJSON: #"" 1900000000 ""#)
        #expect(Self.expires(fromString) == 1_900_000_000_000)

        let fromDouble = try await Self.exchange(expiresAtJSON: "1900000000.4")
        #expect(Self.expires(fromDouble) == 1_900_000_000_000)
    }

    @Test
    func unrepresentableExpiryThrowsInsteadOfTrapping() async {
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await Self.exchange(expiresAtJSON: "1e30")
        }
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await Self.exchange(expiresAtJSON: "-9000000000000000000")
        }
    }
}
