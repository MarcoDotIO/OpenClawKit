import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import OpenClawCore
import OpenClawProtocol
@testable import OpenClawMCP

/// Presenter that approves the authorization request and records the URL it was given.
final class ApprovingOAuthPresenter: MCPOAuthPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var authorizationURLs: [URL] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.urls
    }

    private func record(_ url: URL) {
        self.lock.lock()
        self.urls.append(url)
        self.lock.unlock()
    }

    func authorize(authorizationURL: URL, redirectURL: URL) async throws -> URL {
        self.record(authorizationURL)
        let state = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        var components = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "code", value: "auth-code"), URLQueryItem(name: "state", value: state)]
        return components.url!
    }
}

/// Mutable clock for token expiry tests.
final class OAuthTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.current
    }

    func advance(_ seconds: TimeInterval) {
        self.lock.lock()
        self.current = self.current.addingTimeInterval(seconds)
        self.lock.unlock()
    }
}

/// Stub provider for transport retry tests.
actor StubAuthorizationProvider: MCPAuthorizationProvider {
    private var token = "stale"
    private(set) var challenges: [String?] = []

    func authorizationHeader() async throws -> String? {
        "Bearer \(self.token)"
    }

    func handleUnauthorized(wwwAuthenticate: String?) async throws -> Bool {
        self.challenges.append(wwwAuthenticate)
        self.token = "fresh"
        return true
    }
}

@Suite("MCP HTTP OAuth")
struct MCPOAuthTests {
    static func formFields(_ request: URLRequest) -> [String: String] {
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        var components = URLComponents()
        components.percentEncodedQuery = body
        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] { fields[item.name] = item.value ?? "" }
        return fields
    }

    static func authServer(tokenCounter: ManagedCounter) -> FakeMCPHTTP {
        FakeMCPHTTP { request, json in
            let url = request.url!.absoluteString
            switch url {
            case "https://mcp.example.com/.well-known/oauth-protected-resource/mcp":
                return FakeMCPHTTP.json(["resource": AnyCodable("https://mcp.example.com/mcp"),
                                         "authorization_servers": AnyCodable([AnyCodable("https://auth.example.com")])])
            case "https://auth.example.com/.well-known/oauth-authorization-server":
                return FakeMCPHTTP.json([
                    "issuer": AnyCodable("https://auth.example.com"),
                    "authorization_endpoint": AnyCodable("https://auth.example.com/authorize"),
                    "token_endpoint": AnyCodable("https://auth.example.com/token"),
                    "registration_endpoint": AnyCodable("https://auth.example.com/register"),
                ])
            case "https://auth.example.com/register":
                #expect(json?["client_name"]?.stringValue == "OpenClaw MCP")
                #expect(json?["token_endpoint_auth_method"]?.stringValue == "none")
                return FakeMCPHTTP.json(["client_id": AnyCodable("client-1")], status: 201)
            case "https://auth.example.com/token":
                let count = tokenCounter.increment()
                return FakeMCPHTTP.json([
                    "access_token": AnyCodable("access-\(count)"),
                    "token_type": AnyCodable("Bearer"),
                    "refresh_token": AnyCodable("refresh-\(count)"),
                    "expires_in": AnyCodable(3_600),
                ])
            default:
                return FakeMCPHTTP.json(["error": AnyCodable("not_found")], status: 404)
            }
        }
    }

    @Test
    func pkceChallengeIsBase64URLSHA256() {
        // Reference: `printf '%s' <verifier> | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '='`.
        #expect(MCPOAuthClient.pkceChallenge(for: "dBjftJeZ4CVP-mJ0RqsxyIfvT6pmmQmpA41lEFgAWnY") == "eyhcy3qWtYMInacE5GuPGs8AAVs9DfkbSQL0nP2nVY4")
    }

    @Test
    func discoveryHelpers() {
        let header = #"Bearer error="invalid_token", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp""#
        #expect(MCPOAuthClient.resourceMetadataURL(from: header)?.absoluteString == "https://mcp.example.com/.well-known/oauth-protected-resource/mcp")
        #expect(MCPOAuthClient.resourceMetadataURL(from: "Bearer") == nil)
        let wellKnown = MCPOAuthClient.wellKnown(URL(string: "https://auth.example.com/tenant?x=1")!, suffix: "oauth-authorization-server")
        #expect(wellKnown?.absoluteString == "https://auth.example.com/.well-known/oauth-authorization-server/tenant")
        #expect(MCPOAuthClient.formEncode(["b": "x y", "a": "1&2"]) == "a=1%262&b=x%20y")
        #expect(MCPOAuthClient.formEncode(["n": "é+"]) == "n=%C3%A9%2B")
    }

    @Test
    func perRequesterIdentityIsRejected() {
        #expect(throws: MCPOAuthError.self) {
            _ = try MCPOAuthClient(
                serverName: "docs",
                serverURL: URL(string: "https://mcp.example.com/mcp")!,
                config: MCPOAuthConfig(identity: "per-requester"),
                store: InMemoryOAuthStore()
            )
        }
    }

    @Test
    func signInRegistersClientExchangesCodeAndRefreshes() async throws {
        let counter = ManagedCounter()
        let http = Self.authServer(tokenCounter: counter)
        let presenter = ApprovingOAuthPresenter()
        let clock = OAuthTestClock()
        let store = InMemoryOAuthStore()
        let client = try MCPOAuthClient(
            serverName: "docs",
            serverURL: URL(string: "https://mcp.example.com/mcp")!,
            config: MCPOAuthConfig(scope: "read"),
            store: store,
            presenter: presenter,
            http: http,
            now: { clock.now }
        )
        #expect(await client.status() == .required)
        #expect(try await client.authorizationHeader() == nil)

        let retry = try await client.handleUnauthorized(wwwAuthenticate: "Bearer")
        #expect(retry)
        #expect(try await client.authorizationHeader() == "Bearer access-1")
        #expect(await client.status() == .signedIn(expiresAtMs: 1_800_000_000_000 + 3_600_000))

        let authorizationURL = try #require(presenter.authorizationURLs.first)
        let query = Dictionary(
            (URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        ) { first, _ in first }
        #expect(authorizationURL.absoluteString.hasPrefix("https://auth.example.com/authorize?"))
        #expect(query["client_id"] == "client-1")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["resource"] == "https://mcp.example.com/mcp")
        #expect(query["redirect_uri"] == MCPOAuthClient.defaultRedirectURL)
        #expect(query["scope"] == "read")

        let tokenRequest = try #require(http.requests.first { $0.url?.absoluteString == "https://auth.example.com/token" })
        let fields = Self.formFields(tokenRequest)
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "auth-code")
        #expect(fields["resource"] == "https://mcp.example.com/mcp")
        #expect(MCPOAuthClient.pkceChallenge(for: fields["code_verifier"] ?? "") == query["code_challenge"])

        let persisted = try #require(try await store.load(server: "docs", identity: "shared"))
        #expect(persisted.clientID == "client-1")
        #expect(persisted.tokens?.refreshToken == "refresh-1")

        clock.advance(3_600)
        #expect(try await client.authorizationHeader() == "Bearer access-2")
        let refresh = try #require(http.requests.last { $0.url?.absoluteString == "https://auth.example.com/token" })
        #expect(Self.formFields(refresh)["grant_type"] == "refresh_token")
        #expect(Self.formFields(refresh)["refresh_token"] == "refresh-1")

        try await client.signOut()
        #expect(await client.status() == .required)
        #expect(try await store.load(server: "docs", identity: "shared") == nil)
    }

    @Test
    func unauthorizedWithoutPresenterMarksRequired() async throws {
        let store = InMemoryOAuthStore()
        var state = MCPOAuthState()
        state.tokens = MCPOAuthTokens(accessToken: "old")
        try await store.save(state, server: "docs", identity: "shared")
        let client = try MCPOAuthClient(serverName: "docs", serverURL: URL(string: "https://mcp.example.com/mcp")!, store: store)
        #expect(await client.status() == .signedIn(expiresAtMs: nil))
        #expect(try await client.handleUnauthorized(wwwAuthenticate: nil) == false)
        #expect(await client.status() == .required)
    }

    @Test
    func manualPresenterBuildsCallbackFromPastedCode() async throws {
        let presenter = ManualMCPOAuthPresenter(open: { _ in }, readCallback: { " pasted-code \n" })
        let callback = try await presenter.authorize(
            authorizationURL: URL(string: "https://auth.example.com/authorize?state=abc&client_id=c")!,
            redirectURL: URL(string: MCPOAuthClient.defaultRedirectURL)!
        )
        #expect(callback.absoluteString == "http://127.0.0.1:8989/oauth/callback?code=pasted-code&state=abc")
        let full = ManualMCPOAuthPresenter(open: { _ in }, readCallback: { "http://127.0.0.1:8989/oauth/callback?code=x&state=y" })
        let direct = try await full.authorize(authorizationURL: URL(string: "https://a.example/authorize")!, redirectURL: URL(string: "http://127.0.0.1:8989/oauth/callback")!)
        #expect(direct.query == "code=x&state=y")
    }

    @Test
    func credentialStoreBackedStateRoundTrips() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("mcp-oauth")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        let store = CredentialMCPOAuthStateStore(credentialStore: credentials)
        #expect(store.key(server: "docs", identity: "shared") == "mcp.oauth.docs.shared")
        let profileStore = CredentialMCPOAuthStateStore(credentialStore: credentials, authProfileID: "work")
        #expect(profileStore.key(server: "docs", identity: "shared") == "mcp.oauth.profile.work")
        var state = MCPOAuthState()
        state.clientID = "client"
        state.tokens = MCPOAuthTokens(accessToken: "a", refreshToken: "r", expiresAtMs: 42)
        try await store.save(state, server: "docs", identity: "shared")
        #expect(try await store.load(server: "docs", identity: "shared") == state)
        try await store.delete(server: "docs", identity: "shared")
        #expect(try await store.load(server: "docs", identity: "shared") == nil)
    }

    @Test
    func streamableTransportRetriesOnceAfterUnauthorized() async throws {
        let provider = StubAuthorizationProvider()
        let http = FakeMCPHTTP { request, json in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" else {
                return FakeMCPHTTP.Reply(
                    status: 401,
                    headers: ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#],
                    chunks: []
                )
            }
            return FakeMCPHTTP.json(FakeMCPHTTP.result(json?["id"], ["ok": AnyCodable(true)]))
        }
        let transport = MCPStreamableHTTPTransport(
            url: URL(string: "https://mcp.example.com/mcp")!,
            http: http,
            openServerStream: false,
            authorization: provider
        )
        try await transport.send(.request(id: .int(1), method: "ping", params: nil))
        var iterator = transport.events.makeAsyncIterator()
        let event = await iterator.next()
        guard case .message(.response(let id, _))? = event else {
            Issue.record("expected a response, got \(String(describing: event))")
            return
        }
        #expect(id == .int(1))
        #expect(http.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer stale", "Bearer fresh"])
        #expect(await provider.challenges.count == 1)
        await transport.close()
    }
}

/// In-memory ``MCPOAuthStateStore``.
actor InMemoryOAuthStore: MCPOAuthStateStore {
    private var states: [String: MCPOAuthState] = [:]

    func load(server: String, identity: String) async throws -> MCPOAuthState? {
        self.states["\(server)/\(identity)"]
    }

    func save(_ state: MCPOAuthState, server: String, identity: String) async throws {
        self.states["\(server)/\(identity)"] = state
    }

    func delete(server: String, identity: String) async throws {
        self.states.removeValue(forKey: "\(server)/\(identity)")
    }
}

/// Thread-safe counter.
final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.value += 1
        return self.value
    }
}
