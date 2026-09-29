import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

// MCP HTTP authorization (`auth: "oauth"`): protected resource metadata (RFC 9728), authorization
// server metadata (RFC 8414 / OpenID discovery), dynamic client registration (RFC 7591) or a client
// ID metadata document, PKCE S256 with a `resource` indicator, code exchange and refresh.
// Tokens persist per (server, identity) in a ``MCPOAuthStateStore`` (Keychain-backed
// ``CredentialStore`` on Apple platforms). Only the `shared` identity is supported in the embedded
// runtime.

/// OAuth tokens for one MCP server.
public struct MCPOAuthTokens: Codable, Sendable, Equatable {
    /// Access token.
    public var accessToken: String
    /// Token type (normally `Bearer`).
    public var tokenType: String
    /// Refresh token.
    public var refreshToken: String?
    /// Expiry in milliseconds since the epoch.
    public var expiresAtMs: Int64?
    /// Granted scope.
    public var scope: String?

    /// Creates tokens.
    /// - Parameters:
    ///   - accessToken: Access token.
    ///   - tokenType: Token type.
    ///   - refreshToken: Refresh token.
    ///   - expiresAtMs: Expiry.
    ///   - scope: Scope.
    public init(accessToken: String, tokenType: String = "Bearer", refreshToken: String? = nil, expiresAtMs: Int64? = nil, scope: String? = nil) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.expiresAtMs = expiresAtMs
        self.scope = scope
    }

    /// Whether the token expires within `skewMs` of `nowMs`.
    /// - Parameters:
    ///   - nowMs: Current time.
    ///   - skewMs: Safety margin.
    /// - Returns: `true` when expired.
    public func isExpired(nowMs: Int64, skewMs: Int64 = 30_000) -> Bool {
        guard let expiresAtMs else { return false }
        return nowMs + skewMs >= expiresAtMs
    }
}

/// Persisted OAuth state for one MCP server and identity.
public struct MCPOAuthState: Codable, Sendable, Equatable {
    /// Tokens.
    public var tokens: MCPOAuthTokens?
    /// Registered (or metadata-document) client id.
    public var clientID: String?
    /// Client secret from dynamic registration, if issued.
    public var clientSecret: String?
    /// Redirect URL registered for the client.
    public var redirectURL: String?
    /// Authorization server issuer.
    public var authorizationServer: String?
    /// Token endpoint.
    public var tokenEndpoint: String?
    /// Resource indicator (the MCP server URL).
    public var resource: String?
    /// Whether the server asked for (re)authorization.
    public var requiresAuthorization: Bool?

    /// Creates state.
    public init() {}
}

/// Status of an MCP server's OAuth sign-in (settings UIs).
public enum MCPOAuthStatus: Sendable, Equatable {
    /// Signed in with a usable (or refreshable) token.
    case signedIn(expiresAtMs: Int64?)
    /// The token expired and cannot be refreshed.
    case expired
    /// Sign-in is required.
    case required
}

/// Persistence for ``MCPOAuthState``.
public protocol MCPOAuthStateStore: Sendable {
    /// Loads state.
    /// - Parameters:
    ///   - server: Server name.
    ///   - identity: Identity (`shared`).
    /// - Returns: The state, if stored.
    func load(server: String, identity: String) async throws -> MCPOAuthState?
    /// Saves state.
    /// - Parameters:
    ///   - state: State.
    ///   - server: Server name.
    ///   - identity: Identity.
    func save(_ state: MCPOAuthState, server: String, identity: String) async throws
    /// Deletes state.
    /// - Parameters:
    ///   - server: Server name.
    ///   - identity: Identity.
    func delete(server: String, identity: String) async throws
}

/// ``MCPOAuthStateStore`` over a ``CredentialStore`` (Keychain on Apple platforms), keyed by
/// `mcp.oauth.<server>.<identity>` (or `mcp.oauth.profile.<authProfileId>` when an auth profile is set).
public struct CredentialMCPOAuthStateStore: MCPOAuthStateStore {
    private let credentialStore: any CredentialStore
    private let authProfileID: String?

    /// Creates the store.
    /// - Parameters:
    ///   - credentialStore: Credential store.
    ///   - authProfileID: Optional auth profile the tokens belong to.
    public init(credentialStore: any CredentialStore, authProfileID: String? = nil) {
        self.credentialStore = credentialStore
        self.authProfileID = authProfileID
    }

    /// Storage key.
    /// - Parameters:
    ///   - server: Server.
    ///   - identity: Identity.
    /// - Returns: Key.
    public func key(server: String, identity: String) -> String {
        if let authProfileID, !authProfileID.isEmpty { return "mcp.oauth.profile.\(authProfileID)" }
        return "mcp.oauth.\(server).\(identity)"
    }

    /// Loads state.
    public func load(server: String, identity: String) async throws -> MCPOAuthState? {
        guard let raw = try await self.credentialStore.loadSecret(for: self.key(server: server, identity: identity)) else { return nil }
        return try JSONDecoder().decode(MCPOAuthState.self, from: Data(raw.utf8))
    }

    /// Saves state.
    public func save(_ state: MCPOAuthState, server: String, identity: String) async throws {
        let data = try JSONEncoder().encode(state)
        try await self.credentialStore.saveSecret(String(decoding: data, as: UTF8.self), for: self.key(server: server, identity: identity))
    }

    /// Deletes state.
    public func delete(server: String, identity: String) async throws {
        try await self.credentialStore.deleteSecret(for: self.key(server: server, identity: identity))
    }
}

/// Presents the authorization URL and returns the redirect callback URL (with `code` and `state`).
public protocol MCPOAuthPresenter: Sendable {
    /// Runs the interactive authorization.
    /// - Parameters:
    ///   - authorizationURL: URL to open.
    ///   - redirectURL: Registered redirect URL.
    /// - Returns: The callback URL the browser was redirected to.
    func authorize(authorizationURL: URL, redirectURL: URL) async throws -> URL
}

/// Presenter for platforms without a web authentication session (tvOS, watchOS, Linux): opens the URL
/// through a callback and waits for the pasted callback URL or code.
public struct ManualMCPOAuthPresenter: MCPOAuthPresenter {
    private let open: @Sendable (URL) async -> Void
    private let readCallback: @Sendable () async throws -> String

    /// Creates the presenter.
    /// - Parameters:
    ///   - open: Opens or displays the authorization URL.
    ///   - readCallback: Returns the pasted callback URL, or just the `code`.
    public init(open: @escaping @Sendable (URL) async -> Void, readCallback: @escaping @Sendable () async throws -> String) {
        self.open = open
        self.readCallback = readCallback
    }

    /// Opens the URL and waits for the pasted callback.
    public func authorize(authorizationURL: URL, redirectURL: URL) async throws -> URL {
        await self.open(authorizationURL)
        let pasted = try await self.readCallback().trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: pasted), url.scheme != nil, url.query != nil {
            return url
        }
        let state = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        var components = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "code", value: pasted), URLQueryItem(name: "state", value: state)]
        guard let url = components?.url else { throw MCPOAuthError.invalidCallback("could not build callback URL") }
        return url
    }
}

/// Errors raised by ``MCPOAuthClient``.
public enum MCPOAuthError: Error, LocalizedError, Sendable, Equatable {
    /// Discovery failed.
    case discoveryFailed(String)
    /// The callback was malformed or did not match.
    case invalidCallback(String)
    /// The token endpoint rejected the request.
    case tokenRequestFailed(String)
    /// Unsupported configuration (for example `per-requester`).
    case unsupported(String)

    /// Human-readable description.
    public var errorDescription: String? {
        switch self {
        case .discoveryFailed(let message): return "MCP OAuth discovery failed: \(message)"
        case .invalidCallback(let message): return "MCP OAuth callback invalid: \(message)"
        case .tokenRequestFailed(let message): return "MCP OAuth token request failed: \(message)"
        case .unsupported(let message): return "MCP OAuth unsupported: \(message)"
        }
    }
}

/// Supplies `Authorization` headers to HTTP transports and handles 401 challenges.
public protocol MCPAuthorizationProvider: Sendable {
    /// Header value (`Bearer …`) for the next request, if signed in.
    func authorizationHeader() async throws -> String?
    /// Handles a 401; returns `true` when the request should be retried.
    /// - Parameter wwwAuthenticate: `WWW-Authenticate` header value.
    func handleUnauthorized(wwwAuthenticate: String?) async throws -> Bool
    /// Handles a 401 for a request that carried `rejectedAuthorization`; returns `true` when the request
    /// should be retried. Providers can skip a refresh when the rejected credential was already replaced
    /// by a concurrent caller. The built-in transports call this variant.
    /// - Parameters:
    ///   - wwwAuthenticate: `WWW-Authenticate` header value.
    ///   - rejectedAuthorization: `Authorization` header value of the rejected request.
    func handleUnauthorized(wwwAuthenticate: String?, rejectedAuthorization: String?) async throws -> Bool
}

public extension MCPAuthorizationProvider {
    /// Default: ignores the rejected credential and calls ``handleUnauthorized(wwwAuthenticate:)``.
    func handleUnauthorized(wwwAuthenticate: String?, rejectedAuthorization _: String?) async throws -> Bool {
        try await self.handleUnauthorized(wwwAuthenticate: wwwAuthenticate)
    }
}

/// OAuth client for one MCP server.
///
/// Token refreshes and interactive sign-ins are single-flight: concurrent callers (parallel tool calls,
/// the server stream, several 401s) share one `refresh_token` request or one browser flow, and a 401
/// for a credential another caller already replaced is retried without refreshing again. This matters
/// because dynamic registration creates a public client, whose refresh tokens OAuth 2.1 servers rotate
/// (and often revoke on reuse).
public actor MCPOAuthClient: MCPAuthorizationProvider {
    /// Upstream default redirect URL.
    public static let defaultRedirectURL = "http://127.0.0.1:8989/oauth/callback"
    /// Identity used by the embedded runtime.
    public static let sharedIdentity = "shared"
    /// Longest `expires_in` honoured (10 years); larger values are clamped.
    public static let maxExpiresInSeconds: Double = 315_360_000

    private let serverName: String
    private let serverURL: URL
    private let config: MCPOAuthConfig
    private let store: any MCPOAuthStateStore
    private let presenter: (any MCPOAuthPresenter)?
    private let http: any MCPHTTPStreaming
    private let now: @Sendable () -> Date
    private var state: MCPOAuthState?
    private var refreshTask: Task<MCPOAuthTokens, Error>?
    private var signInTask: Task<Void, Error>?

    /// Creates the client.
    /// - Parameters:
    ///   - serverName: Server name.
    ///   - serverURL: MCP server URL (the resource indicator).
    ///   - config: OAuth settings.
    ///   - store: State store.
    ///   - presenter: Interactive presenter (`nil` disables interactive sign-in).
    ///   - http: HTTP client.
    ///   - now: Clock.
    /// - Throws: ``MCPOAuthError/unsupported(_:)`` for `per-requester` identities.
    public init(
        serverName: String,
        serverURL: URL,
        config: MCPOAuthConfig = MCPOAuthConfig(),
        store: any MCPOAuthStateStore,
        presenter: (any MCPOAuthPresenter)? = nil,
        http: any MCPHTTPStreaming = URLSessionMCPHTTPStreaming(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        if config.identity == "per-requester" {
            throw MCPOAuthError.unsupported("oauth.identity \"per-requester\" is not supported by the embedded runtime")
        }
        self.serverName = serverName
        self.serverURL = serverURL
        self.config = config
        self.store = store
        self.presenter = presenter
        self.http = http
        self.now = now
    }

    /// Current sign-in status.
    public func status() async -> MCPOAuthStatus {
        let state = await self.loadedState()
        guard let tokens = state.tokens else { return .required }
        if tokens.isExpired(nowMs: self.nowMs(), skewMs: 0), tokens.refreshToken == nil { return .expired }
        return state.requiresAuthorization == true ? .required : .signedIn(expiresAtMs: tokens.expiresAtMs)
    }

    /// Removes stored tokens and client registration.
    public func signOut() async throws {
        self.state = MCPOAuthState()
        try await self.store.delete(server: self.serverName, identity: Self.sharedIdentity)
    }

    /// `Bearer` header for the next request, refreshing an expired token when possible.
    public func authorizationHeader() async throws -> String? {
        let state = await self.loadedState()
        guard var tokens = state.tokens else { return nil }
        if tokens.isExpired(nowMs: self.nowMs()) {
            guard tokens.refreshToken != nil else { return nil }
            tokens = try await self.refreshTokens(rejectedAccessToken: tokens.accessToken)
        }
        return Self.header(for: tokens)
    }

    /// Handles a 401: refreshes when possible, otherwise runs the interactive sign-in.
    public func handleUnauthorized(wwwAuthenticate: String?) async throws -> Bool {
        let current = await self.loadedState().tokens.map(Self.header(for:))
        return try await self.handleUnauthorized(wwwAuthenticate: wwwAuthenticate, rejectedAuthorization: current)
    }

    /// Handles a 401 for a request that carried `rejectedAuthorization`: when another caller already
    /// replaced that credential the request is simply retried; otherwise the token is refreshed (shared
    /// with concurrent callers) or, failing that, the interactive sign-in runs (one browser flow for all
    /// concurrent callers).
    public func handleUnauthorized(wwwAuthenticate: String?, rejectedAuthorization: String?) async throws -> Bool {
        let entry = await self.loadedState()
        if let tokens = entry.tokens, Self.header(for: tokens) != rejectedAuthorization, !tokens.isExpired(nowMs: self.nowMs()) {
            // The rejected request carried an older credential (or none); retry with the current one.
            return true
        }
        let rejectedAccessToken = entry.tokens?.accessToken
        if entry.tokens?.refreshToken != nil, (try? await self.refreshTokens(rejectedAccessToken: rejectedAccessToken)) != nil {
            return true
        }
        guard self.presenter != nil else {
            // Re-read after the await and only flag the credential that was actually rejected, so fresh
            // tokens saved by a concurrent caller are never overwritten with a stale copy.
            var latest = await self.loadedState()
            guard latest.tokens?.accessToken == rejectedAccessToken else { return latest.tokens != nil }
            latest.requiresAuthorization = true
            try await self.persist(latest)
            return false
        }
        try await self.signIn(wwwAuthenticate: wwwAuthenticate)
        return true
    }

    /// Runs discovery, client registration, PKCE authorization and code exchange. Concurrent calls
    /// share one interactive flow.
    /// - Parameter wwwAuthenticate: Optional `WWW-Authenticate` header carrying `resource_metadata`.
    public func signIn(wwwAuthenticate: String? = nil) async throws {
        guard self.presenter != nil else { throw MCPOAuthError.unsupported("no OAuth presenter is configured") }
        if let signInTask {
            try await signInTask.value
            return
        }
        let task = Task { () throws -> Void in
            defer { self.signInTask = nil }
            try await self.performSignIn(wwwAuthenticate: wwwAuthenticate)
        }
        self.signInTask = task
        try await task.value
    }

    private func performSignIn(wwwAuthenticate: String?) async throws {
        guard let presenter else { throw MCPOAuthError.unsupported("no OAuth presenter is configured") }
        var state = await self.loadedState()
        let metadata = try await self.discover(wwwAuthenticate: wwwAuthenticate)
        let redirect = self.config.redirectUrl ?? state.redirectURL ?? Self.defaultRedirectURL
        guard let redirectURL = URL(string: redirect) else { throw MCPOAuthError.unsupported("invalid redirect URL \(redirect)") }
        if state.clientID == nil || state.redirectURL != redirect || state.authorizationServer != metadata.issuer {
            try await self.registerClient(metadata: metadata, redirect: redirect, state: &state)
        }
        guard let clientID = state.clientID,
              let authorizationEndpoint = metadata.authorizationEndpoint,
              var components = URLComponents(string: authorizationEndpoint)
        else {
            throw MCPOAuthError.discoveryFailed("authorization endpoint or client id missing")
        }
        let verifier = Self.randomToken(bytes: 48)
        let challenge = Self.pkceChallenge(for: verifier)
        let stateToken = Self.randomToken(bytes: 16)
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: stateToken),
            URLQueryItem(name: "resource", value: self.serverURL.absoluteString),
        ]
        if let scope = self.config.scope ?? metadata.scopesSupported?.joined(separator: " "), !scope.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scope))
        }
        components.queryItems = items
        guard let authorizationURL = components.url else { throw MCPOAuthError.discoveryFailed("invalid authorization URL") }
        let callback = try await presenter.authorize(authorizationURL: authorizationURL, redirectURL: redirectURL)
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = query.first(where: { $0.name == "error" })?.value {
            throw MCPOAuthError.invalidCallback(error)
        }
        guard query.first(where: { $0.name == "state" })?.value == stateToken else {
            throw MCPOAuthError.invalidCallback("state mismatch")
        }
        guard let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MCPOAuthError.invalidCallback("missing code")
        }
        var form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "client_id": clientID,
            "code_verifier": verifier,
            "resource": self.serverURL.absoluteString,
        ]
        if let secret = state.clientSecret { form["client_secret"] = secret }
        state.tokenEndpoint = metadata.tokenEndpoint
        state.tokens = try await self.tokenRequest(endpoint: metadata.tokenEndpoint, form: form)
        state.requiresAuthorization = false
        try await self.persist(state)
    }

    // MARK: - Discovery

    struct AuthorizationServerMetadata: Sendable, Equatable {
        let issuer: String
        let authorizationEndpoint: String?
        let tokenEndpoint: String
        let registrationEndpoint: String?
        let scopesSupported: [String]?
    }

    func discover(wwwAuthenticate: String?) async throws -> AuthorizationServerMetadata {
        var authorizationServer: String?
        let resourceMetadataURL = wwwAuthenticate.flatMap(Self.resourceMetadataURL(from:))
            ?? Self.wellKnown(self.serverURL, suffix: "oauth-protected-resource")
        if let resourceMetadataURL, let resource = try? await self.getJSON(resourceMetadataURL) {
            authorizationServer = resource["authorization_servers"]?.arrayValue?.first?.stringValue
        }
        guard let issuer = authorizationServer ?? Self.origin(of: self.serverURL), let issuerURL = URL(string: issuer) else {
            throw MCPOAuthError.discoveryFailed("no authorization server")
        }
        for suffix in ["oauth-authorization-server", "openid-configuration"] {
            guard let url = Self.wellKnown(issuerURL, suffix: suffix), let object = try? await self.getJSON(url),
                  let tokenEndpoint = object["token_endpoint"]?.stringValue
            else {
                continue
            }
            return AuthorizationServerMetadata(
                issuer: object["issuer"]?.stringValue ?? issuer,
                authorizationEndpoint: object["authorization_endpoint"]?.stringValue,
                tokenEndpoint: tokenEndpoint,
                registrationEndpoint: object["registration_endpoint"]?.stringValue,
                scopesSupported: object["scopes_supported"]?.arrayValue?.compactMap(\.stringValue)
            )
        }
        throw MCPOAuthError.discoveryFailed("authorization server metadata not found for \(issuer)")
    }

    /// `resource_metadata="…"` from a `WWW-Authenticate` challenge.
    static func resourceMetadataURL(from header: String) -> URL? {
        guard let range = header.range(of: "resource_metadata=\"") else { return nil }
        let rest = header[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return URL(string: String(rest[..<end]))
    }

    /// Path-aware well-known URL (`https://host/.well-known/<suffix>/<path>`).
    static func wellKnown(_ base: URL, suffix: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path == "/" ? "" : components.path
        components.path = "/.well-known/\(suffix)\(path)"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: - Registration and tokens

    private func registerClient(metadata: AuthorizationServerMetadata, redirect: String, state: inout MCPOAuthState) async throws {
        state.authorizationServer = metadata.issuer
        state.redirectURL = redirect
        state.resource = self.serverURL.absoluteString
        if let metadataURL = self.config.clientMetadataUrl {
            // Client ID metadata document: the URL is the client id.
            state.clientID = metadataURL
            state.clientSecret = nil
            return
        }
        guard let registration = metadata.registrationEndpoint, let url = URL(string: registration) else {
            throw MCPOAuthError.discoveryFailed("authorization server has no registration endpoint; set oauth.clientMetadataUrl")
        }
        var body: [String: AnyCodable] = [
            "client_name": AnyCodable("OpenClaw MCP"),
            "redirect_uris": AnyCodable([AnyCodable(redirect)]),
            "grant_types": AnyCodable(["authorization_code", "refresh_token"].map { AnyCodable($0) }),
            "response_types": AnyCodable([AnyCodable("code")]),
            "token_endpoint_auth_method": AnyCodable("none"),
        ]
        if let scope = self.config.scope { body["scope"] = AnyCodable(scope) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(AnyCodable(body))
        let (status, object) = try await self.send(request)
        guard (200..<300).contains(status), let clientID = object["client_id"]?.stringValue else {
            throw MCPOAuthError.discoveryFailed("client registration failed (HTTP \(status))")
        }
        state.clientID = clientID
        state.clientSecret = object["client_secret"]?.stringValue
    }

    /// Single-flight refresh: joins an in-flight refresh, or returns the stored tokens when another caller
    /// already replaced `rejectedAccessToken` with a token that is still valid.
    private func refreshTokens(rejectedAccessToken: String?) async throws -> MCPOAuthTokens {
        if let refreshTask { return try await refreshTask.value }
        if let tokens = await self.loadedState().tokens, tokens.accessToken != rejectedAccessToken, !tokens.isExpired(nowMs: self.nowMs()) {
            return tokens
        }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { () throws -> MCPOAuthTokens in
            defer { self.refreshTask = nil }
            return try await self.refresh()
        }
        self.refreshTask = task
        return try await task.value
    }

    private func refresh() async throws -> MCPOAuthTokens {
        let state = await self.loadedState()
        guard let refreshToken = state.tokens?.refreshToken, let clientID = state.clientID else {
            throw MCPOAuthError.tokenRequestFailed("no refresh token")
        }
        let endpoint: String
        if let stored = state.tokenEndpoint {
            endpoint = stored
        } else {
            endpoint = try await self.discover(wwwAuthenticate: nil).tokenEndpoint
        }
        var form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "resource": self.serverURL.absoluteString,
        ]
        if let secret = state.clientSecret { form["client_secret"] = secret }
        var tokens = try await self.tokenRequest(endpoint: endpoint, form: form)
        if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
        // Apply the result to the state as it is now, not to the snapshot taken before the awaits.
        var latest = await self.loadedState()
        latest.tokens = tokens
        latest.tokenEndpoint = endpoint
        latest.requiresAuthorization = false
        try await self.persist(latest)
        return tokens
    }

    private func tokenRequest(endpoint: String, form: [String: String]) async throws -> MCPOAuthTokens {
        guard let url = URL(string: endpoint) else { throw MCPOAuthError.tokenRequestFailed("invalid token endpoint") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(form).utf8)
        let (status, object) = try await self.send(request)
        guard (200..<300).contains(status), let access = object["access_token"]?.stringValue else {
            throw MCPOAuthError.tokenRequestFailed(object["error_description"]?.stringValue ?? object["error"]?.stringValue ?? "HTTP \(status)")
        }
        return MCPOAuthTokens(
            accessToken: access,
            tokenType: object["token_type"]?.stringValue ?? "Bearer",
            refreshToken: object["refresh_token"]?.stringValue,
            expiresAtMs: Self.expiresAtMs(expiresIn: object["expires_in"]?.doubleValue, nowMs: self.nowMs()),
            scope: object["scope"]?.stringValue
        )
    }

    /// Absolute expiry for a server-supplied `expires_in` (seconds). Non-finite and non-positive values
    /// mean "no known expiry" (a 401 then triggers the refresh); values above ``maxExpiresInSeconds``
    /// are clamped, so the arithmetic can never trap.
    static func expiresAtMs(expiresIn: Double?, nowMs: Int64) -> Int64? {
        guard let expiresIn, expiresIn.isFinite, expiresIn > 0 else { return nil }
        let milliseconds = Int64((min(expiresIn, Self.maxExpiresInSeconds) * 1_000).rounded())
        let (sum, overflow) = nowMs.addingReportingOverflow(milliseconds)
        return overflow ? nil : sum
    }

    static func header(for tokens: MCPOAuthTokens) -> String {
        "\(tokens.tokenType.isEmpty ? "Bearer" : tokens.tokenType) \(tokens.accessToken)"
    }

    private func getJSON(_ url: URL) async throws -> [String: AnyCodable] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (status, object) = try await self.send(request)
        guard (200..<300).contains(status) else { throw MCPOAuthError.discoveryFailed("HTTP \(status) for \(url.absoluteString)") }
        return object
    }

    private func send(_ request: URLRequest) async throws -> (Int, [String: AnyCodable]) {
        let (response, body) = try await self.http.stream(request)
        let data = try await MCPHTTPSupport.collect(body, limit: 1_024 * 1_024)
        let object = (try? JSONDecoder().decode(AnyCodable.self, from: data))?.dictionaryValue ?? [:]
        return (response.statusCode, object)
    }

    private func loadedState() async -> MCPOAuthState {
        if let state { return state }
        let loaded = (try? await self.store.load(server: self.serverName, identity: Self.sharedIdentity)) ?? nil
        let resolved = loaded ?? MCPOAuthState()
        self.state = resolved
        return resolved
    }

    private func persist(_ state: MCPOAuthState) async throws {
        self.state = state
        try await self.store.save(state, server: self.serverName, identity: Self.sharedIdentity)
    }

    private func nowMs() -> Int64 {
        Int64((self.now().timeIntervalSince1970 * 1_000).rounded())
    }

    static func formEncode(_ form: [String: String]) -> String {
        // RFC 3986 unreserved characters only (ASCII), so non-ASCII letters are percent-encoded too.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return form.keys.sorted().map { key in
            let value = form[key] ?? ""
            return "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    static func randomToken(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
        return self.base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// PKCE S256 challenge for a verifier.
    /// - Parameter verifier: Code verifier.
    /// - Returns: `base64url(sha256(verifier))`.
    public static func pkceChallenge(for verifier: String) -> String {
        self.base64URL(Data(OpenClawCrypto.sha256Hex(Data(verifier.utf8)).oauthHexBytes))
    }

    /// `scheme://host[:port]` of a URL.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }
}

private extension String {
    /// Bytes of a hex string.
    var oauthHexBytes: [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(self.count / 2)
        var index = self.startIndex
        while index < self.endIndex {
            let next = self.index(index, offsetBy: 2, limitedBy: self.endIndex) ?? self.endIndex
            if let byte = UInt8(self[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return bytes
    }
}

#if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
/// ``MCPOAuthPresenter`` backed by `ASWebAuthenticationSession` (iOS, macOS, visionOS).
///
/// Use a custom-scheme `oauth.redirectUrl` (for example `myapp://mcp/oauth`) so the session can
/// capture the callback; loopback `http://127.0.0.1` redirects need ``ManualMCPOAuthPresenter``.
public struct WebAuthenticationMCPOAuthPresenter: MCPOAuthPresenter {
    private let makePresenter: @MainActor @Sendable () -> AppleWebAuthenticationSessionPresenter

    /// Creates the presenter.
    /// - Parameter makePresenter: Builds the web authentication presenter (supply a presentation anchor).
    public init(makePresenter: @escaping @MainActor @Sendable () -> AppleWebAuthenticationSessionPresenter = { AppleWebAuthenticationSessionPresenter() }) {
        self.makePresenter = makePresenter
    }

    /// Runs the browser session and returns the callback URL.
    public func authorize(authorizationURL: URL, redirectURL: URL) async throws -> URL {
        let scheme = redirectURL.scheme?.lowercased()
        let callbackScheme = scheme == "http" || scheme == "https" ? nil : scheme
        let presenter = await self.makePresenter()
        return try await presenter.authenticate(authorizationURL: authorizationURL, callbackScheme: callbackScheme)
    }
}
#endif
