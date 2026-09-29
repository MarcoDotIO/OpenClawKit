import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawCore

/// Scripted SIWC authorization server: JWKS, token and revocation endpoints.
final class SIWCFakeServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ request: URLRequest, _ form: [String: String]) -> HTTPResponseData

    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var jwks: String
    private var tokenHandler: Handler
    private var revokeHandler: Handler
    private var refreshCount = 0

    init(jwks: String = SignInWithChatGPTFixtures.jwks) {
        self.jwks = jwks
        self.tokenHandler = { _, form in
            if form["grant_type"] == "authorization_code" {
                return SIWCFakeServer.json(SIWCFakeServer.tokenBody(access: "access-1", refresh: "refresh-1", idToken: SignInWithChatGPTFixtures.Token.valid))
            }
            return SIWCFakeServer.json(["error": "unsupported_grant_type"], status: 400)
        }
        self.revokeHandler = { _, _ in HTTPResponseData(statusCode: 200, headers: [:], body: Data()) }
    }

    var transport: SignInWithChatGPTHTTPTransport {
        SignInWithChatGPTHTTPTransport { request in self.handle(request) }
    }

    var recordedRequests: [URLRequest] {
        self.lock.withLock { self.requests }
    }

    func forms(path: String) -> [[String: String]] {
        self.recordedRequests.filter { $0.url?.path == path }.map(Self.form)
    }

    func setTokenHandler(_ handler: @escaping Handler) {
        self.lock.withLock { self.tokenHandler = handler }
    }

    func setRevokeHandler(_ handler: @escaping Handler) {
        self.lock.withLock { self.revokeHandler = handler }
    }

    func setJWKS(_ jwks: String) {
        self.lock.withLock { self.jwks = jwks }
    }

    /// Token handler that answers code exchanges with `access-1`/`refresh-1` and refreshes with
    /// `access-N`/`refresh-N` (N = 2, 3, …).
    func useRotatingRefresh(scope: String = SIWCFakeServer.planScope) {
        self.setTokenHandler { [weak self] _, form in
            guard let self else { return SIWCFakeServer.json([:], status: 500) }
            switch form["grant_type"] {
            case "authorization_code":
                let body = SIWCFakeServer.tokenBody(access: "access-1", refresh: "refresh-1", idToken: SignInWithChatGPTFixtures.Token.valid, scope: scope)
                return SIWCFakeServer.json(body)
            case "refresh_token":
                let count = self.lock.withLock { () -> Int in
                    self.refreshCount += 1
                    return self.refreshCount
                }
                return SIWCFakeServer.json(SIWCFakeServer.tokenBody(
                    access: "access-\(count + 1)",
                    refresh: "refresh-\(count + 1)",
                    idToken: SignInWithChatGPTFixtures.Token.refresh,
                    scope: scope
                ))
            default:
                return SIWCFakeServer.json(["error": "unsupported_grant_type"], status: 400)
            }
        }
    }

    private func handle(_ request: URLRequest) -> HTTPResponseData {
        let (tokenHandler, revokeHandler, jwks) = self.lock.withLock { () -> (Handler, Handler, String) in
            self.requests.append(request)
            return (self.tokenHandler, self.revokeHandler, self.jwks)
        }
        let form = Self.form(request)
        switch request.url?.path {
        case "/.well-known/jwks.json":
            return HTTPResponseData(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(jwks.utf8))
        case "/api/accounts/oauth/token":
            return tokenHandler(request, form)
        case "/api/accounts/oauth/revoke":
            return revokeHandler(request, form)
        default:
            return HTTPResponseData(statusCode: 404, headers: [:], body: Data())
        }
    }

    static let planScope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    static func tokenBody(access: String, refresh: String?, idToken: String?, scope: String = planScope, expiresIn: Int = 3600) -> [String: Any] {
        var body: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": expiresIn, "scope": scope]
        body["refresh_token"] = refresh
        body["id_token"] = idToken
        return body
    }

    static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponseData {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponseData(statusCode: status, headers: ["Content-Type": "application/json"], body: body)
    }

    static func form(_ request: URLRequest) -> [String: String] {
        guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            fields[name] = value
        }
        return fields
    }
}

/// Mutable test clock.
final class SIWCTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.current = start
    }

    var now: Date {
        self.lock.withLock { self.current }
    }

    func advance(_ seconds: TimeInterval) {
        self.lock.withLock { self.current = self.current.addingTimeInterval(seconds) }
    }

    var closure: @Sendable () -> Date {
        { self.now }
    }
}

enum SIWCTest {
    static let secrets = SignInWithChatGPTAuthorizationRequest.Secrets(
        state: "state-1",
        nonce: "nonce-1",
        verifier: "verifier-0123456789-0123456789-0123456789-abc"
    )

    static func queryItems(_ url: URL) -> [String: String] {
        var items: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            items[item.name] = item.value ?? ""
        }
        return items
    }

    static func callbackURL(port: UInt16 = 1455, code: String = "code-1", state: String = "state-1", clientID: String? = "oaiapp_test") -> URL {
        var components = URLComponents(url: SignInWithChatGPTConfiguration.callbackURL(port: port), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state)]
        if let clientID {
            items.append(URLQueryItem(name: "client_id", value: clientID))
        }
        items.append(URLQueryItem(name: "scope", value: SIWCFakeServer.planScope))
        components.queryItems = items
        return components.url!
    }

    static func makeSession(
        server: SIWCFakeServer,
        clock: SIWCTestClock,
        store: InMemoryTestCredentialStore = InMemoryTestCredentialStore(),
        requestsPlanUsage: Bool = true,
        callbackPort: UInt16 = 1455
    ) -> SignInWithChatGPTSession {
        SignInWithChatGPTSession(
            configuration: SignInWithChatGPTClientConfiguration(agentName: "TestAgent", requestsPlanUsage: requestsPlanUsage, callbackPort: callbackPort),
            credentialStore: store,
            transport: server.transport,
            now: clock.closure
        )
    }

    /// Signs in `user-abc` through begin/complete with the fixed secrets.
    @discardableResult
    static func signIn(_ session: SignInWithChatGPTSession) async throws -> SignInWithChatGPTSignInResult {
        let pending = try await session.beginAuthorization(
            redirectURI: SignInWithChatGPTConfiguration.callbackURL(port: 1455),
            reauthenticating: nil,
            consent: .automatic,
            secrets: self.secrets
        )
        return try await session.completeAuthorization(callbackURL: self.callbackURL(), pending: pending)
    }
}
