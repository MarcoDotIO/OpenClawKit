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

    /// Mutable epoch-millisecond clock for resolver tests.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64

        init(_ value: Int64) {
            self.value = value
        }

        func now() -> Int64 {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }

        func advance(by milliseconds: Int64) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.value += milliseconds
        }
    }

    /// A present-day clock (above `Int32.max`) must drive refresh decisions; a 32-bit `Int` clock
    /// clamped to `Int32.max` never refreshed on watchOS arm64_32.
    @Test
    func chatGPTOAuthRefreshesWithPresentDayClock() async throws {
        let transport = ProviderRuntimeAuthTests.MockRuntimeAuthTransport()
        await transport.enqueue(
            url: OpenAIChatGPTOAuthConfiguration.tokenURL.absoluteString,
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"access_token": "chatgpt-a2", "refresh_token": "chatgpt-r2", "expires_in": 3600}"#.utf8)
            )
        )
        let now: Int64 = 1_790_000_000_000
        #expect(now > Int64(Int32.max))
        let resolver = RuntimeProviderAuthResolver(transport: transport, now: { now })
        let resolution = try await resolver.resolve(
            providerID: "openai",
            credential: .oauth(
                OAuthAuthProfileCredential(
                    provider: "openai",
                    accessToken: "chatgpt-a1",
                    refreshToken: "chatgpt-r1",
                    expires: 1_789_999_000_000
                )
            )
        )
        #expect(resolution.persistCredential)
        guard case .oauth(let credential) = resolution.credential else {
            Issue.record("Expected refreshed OAuth credential")
            return
        }
        #expect(credential.accessToken == "chatgpt-a2")
        #expect(credential.expires == now + Int64(3_600_000))
        #expect(await transport.requests().count == 1)
    }

    /// A still-valid OAuth token is not refreshed under a present-day clock.
    @Test
    func chatGPTOAuthKeepsUnexpiredTokenWithPresentDayClock() async throws {
        let transport = ProviderRuntimeAuthTests.MockRuntimeAuthTransport()
        let resolver = RuntimeProviderAuthResolver(transport: transport, now: { 1_790_000_000_000 })
        let credential = AuthProfileCredential.oauth(
            OAuthAuthProfileCredential(
                provider: "openai",
                accessToken: "chatgpt-a1",
                refreshToken: "chatgpt-r1",
                expires: 1_790_000_000_000 + 3_600_000
            )
        )
        let resolution = try await resolver.resolve(providerID: "openai", credential: credential)
        #expect(!resolution.persistCredential)
        #expect(resolution.credential == credential)
        #expect(await transport.requests().isEmpty)
    }

    /// A cached Copilot token inside the 5-minute safety window is exchanged again, not reused.
    @Test
    func copilotCachedTokenIsReexchangedNearExpiry() async throws {
        let clock = TestClock(1_790_000_000_000)
        let transport = ProviderRuntimeAuthTests.MockRuntimeAuthTransport()
        for token in ["copilot-1", "copilot-2"] {
            await transport.enqueue(
                url: Self.copilotTokenURL,
                response: HTTPResponseData(
                    statusCode: 200,
                    headers: [:],
                    // Expires 30 minutes after the initial clock value (seconds form).
                    body: Data(#"{"token": "\#(token)", "expires_at": 1790001800}"#.utf8)
                )
            )
        }
        let resolver = RuntimeProviderAuthResolver(transport: transport, now: { clock.now() })
        let credential = AuthProfileCredential.token(TokenAuthProfileCredential(provider: "github-copilot", token: "ghu_123"))

        let first = try await resolver.resolve(providerID: "github-copilot", credential: credential)
        let cached = try await resolver.resolve(providerID: "github-copilot", credential: credential)
        #expect(await transport.requests().count == 1)
        guard case .token(let firstToken) = first.credential, case .token(let cachedToken) = cached.credential else {
            Issue.record("Expected token credentials")
            return
        }
        #expect(firstToken.token == "copilot-1")
        #expect(cachedToken.token == "copilot-1")

        clock.advance(by: 26 * 60 * 1000)
        let refreshed = try await resolver.resolve(providerID: "github-copilot", credential: credential)
        #expect(await transport.requests().count == 2)
        guard case .token(let refreshedToken) = refreshed.credential else {
            Issue.record("Expected token credential")
            return
        }
        #expect(refreshedToken.token == "copilot-2")
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
