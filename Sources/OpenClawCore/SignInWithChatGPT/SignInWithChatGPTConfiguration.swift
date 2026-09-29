import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sign in with ChatGPT (SIWC) constants for the open-source "ChatGPT plan usage" flow.
///
/// SIWC lets a user sign in with their ChatGPT account and, when they grant the plan scopes, run
/// eligible inference against their ChatGPT plan instead of an API key. The first sign-in registers
/// the app with `client_id=dynamic_agent_client`; the callback returns the issued client id (for
/// example `oaiapp_…`) that every later request for that account uses.
///
/// This is a different OAuth client from ``OpenAIChatGPTOAuthConfiguration`` (the Codex login used by
/// the `openai-chatgpt-responses` route): SIWC tokens call `https://api.openai.com/v1/responses`.
public enum SignInWithChatGPTConfiguration {
    /// OAuth issuer (`iss` of ID tokens).
    public static let issuer = URL(string: "https://auth.openai.com")!
    /// OpenID discovery document.
    public static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    /// Browser authorization endpoint.
    public static let authorizationURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    /// Token endpoint (code exchange and refresh).
    public static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    /// Token revocation endpoint.
    public static let revocationURL = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    /// OpenID userinfo endpoint.
    public static let userInfoURL = URL(string: "https://auth.openai.com/api/accounts/oauth/userinfo")!
    /// JSON Web Key Set used to verify RS256 ID tokens.
    public static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!

    /// Client id sent on the first (registration) sign-in of an account.
    public static let dynamicClientID = "dynamic_agent_client"
    /// Resource indicator sent on authorization, code exchange and refresh.
    public static let resource = "https://api.openai.com/v1"
    /// Identity scopes (always requested).
    public static let identityScopes = ["openid", "profile", "email"]
    /// Additional scopes that enable ChatGPT plan usage.
    public static let planUsageScopes = ["offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]
    /// Scope that must be granted before a token may be used for inference.
    public static let planUsageScope = "chatgpt.tokens.use.direct"

    /// Loopback host used in the redirect URI. OpenAI requires the literal IPv4 loopback address;
    /// `localhost` is rejected.
    public static let callbackHost = "127.0.0.1"
    /// Redirect path.
    public static let callbackPath = "/auth/callback"
    /// Preferred loopback port. Only the port of the redirect URI may vary.
    public static let defaultCallbackPort: UInt16 = 1455

    /// Responses endpoint used with ChatGPT plan access tokens.
    public static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    /// Model list endpoint used with ChatGPT plan access tokens.
    public static let modelsURL = URL(string: "https://api.openai.com/v1/models")!

    /// ChatGPT settings page where users manage plan usage ("Manage usage").
    public static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!
    /// OpenAI Help Center ("Learn more").
    public static let learnMoreURL = URL(string: "https://help.openai.com/")!

    /// Loopback redirect URI for a port: `http://127.0.0.1:<port>/auth/callback`.
    /// - Parameter port: Loopback port.
    /// - Returns: Redirect URI.
    public static func callbackURL(port: UInt16 = defaultCallbackPort) -> URL {
        URL(string: "http://\(callbackHost):\(port)\(callbackPath)")!
    }

    /// Returns whether `url` is a valid SIWC loopback redirect URI (`http`, host `127.0.0.1`, an
    /// explicit port and the `/auth/callback` path, without query or fragment).
    /// - Parameter url: Candidate redirect URI.
    /// - Returns: `true` when OpenAI accepts the URI.
    public static func isValidCallbackURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "http"
            && components.host == callbackHost
            && components.port.map { (1...65_535).contains($0) } == true
            && components.path == callbackPath
            && components.query == nil
            && components.fragment == nil
            && components.user == nil
    }
}

/// Authorization-server endpoints used by ``SignInWithChatGPTSession``.
///
/// ``production`` holds the documented OpenAI endpoints; ``discover(transport:discoveryURL:)`` reads
/// them from the OpenID discovery document instead. Tests point these at local fixtures.
public struct SignInWithChatGPTEndpoints: Sendable, Equatable, Codable {
    /// Expected `iss` claim.
    public var issuer: URL
    /// Authorization endpoint.
    public var authorizationURL: URL
    /// Token endpoint.
    public var tokenURL: URL
    /// Revocation endpoint.
    public var revocationURL: URL
    /// JWKS endpoint.
    public var jwksURL: URL
    /// Userinfo endpoint.
    public var userInfoURL: URL?

    /// Creates an endpoint set.
    /// - Parameters:
    ///   - issuer: Expected `iss` claim.
    ///   - authorizationURL: Authorization endpoint.
    ///   - tokenURL: Token endpoint.
    ///   - revocationURL: Revocation endpoint.
    ///   - jwksURL: JWKS endpoint.
    ///   - userInfoURL: Userinfo endpoint.
    public init(issuer: URL, authorizationURL: URL, tokenURL: URL, revocationURL: URL, jwksURL: URL, userInfoURL: URL? = nil) {
        self.issuer = issuer
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.revocationURL = revocationURL
        self.jwksURL = jwksURL
        self.userInfoURL = userInfoURL
    }

    /// Documented OpenAI endpoints.
    public static let production = Self(
        issuer: SignInWithChatGPTConfiguration.issuer,
        authorizationURL: SignInWithChatGPTConfiguration.authorizationURL,
        tokenURL: SignInWithChatGPTConfiguration.tokenURL,
        revocationURL: SignInWithChatGPTConfiguration.revocationURL,
        jwksURL: SignInWithChatGPTConfiguration.jwksURL,
        userInfoURL: SignInWithChatGPTConfiguration.userInfoURL
    )

    /// Reads endpoints from an OpenID discovery document.
    ///
    /// The document must advertise the `S256` PKCE method and the `code` response type, and its
    /// issuer must match the discovery URL's origin.
    /// - Parameters:
    ///   - transport: HTTP transport.
    ///   - discoveryURL: Discovery document URL.
    /// - Returns: Discovered endpoints.
    /// - Throws: ``SignInWithChatGPTError/invalidServerResponse(_:)`` for a malformed document.
    public static func discover(
        transport: SignInWithChatGPTHTTPTransport = .urlSession(),
        discoveryURL: URL = SignInWithChatGPTConfiguration.discoveryURL
    ) async throws -> Self {
        var request = URLRequest(url: discoveryURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw SignInWithChatGPTError.invalidServerResponse("discovery returned status \(response.statusCode)")
        }
        guard let document = try? JSONDecoder().decode(DiscoveryDocument.self, from: response.body) else {
            throw SignInWithChatGPTError.invalidServerResponse("discovery document is not valid JSON")
        }
        guard
            let issuer = URL(string: document.issuer),
            let authorization = URL(string: document.authorizationEndpoint),
            let token = URL(string: document.tokenEndpoint),
            let jwks = URL(string: document.jwksURI)
        else {
            throw SignInWithChatGPTError.invalidServerResponse("discovery document is missing endpoints")
        }
        guard issuer.host == discoveryURL.host, issuer.scheme == discoveryURL.scheme else {
            throw SignInWithChatGPTError.invalidServerResponse("discovery issuer does not match the discovery URL")
        }
        if let methods = document.codeChallengeMethodsSupported, !methods.contains("S256") {
            throw SignInWithChatGPTError.invalidServerResponse("authorization server does not support S256 PKCE")
        }
        let revocation = document.revocationEndpoint.flatMap(URL.init(string:)) ?? SignInWithChatGPTConfiguration.revocationURL
        return Self(
            issuer: issuer,
            authorizationURL: authorization,
            tokenURL: token,
            revocationURL: revocation,
            jwksURL: jwks,
            userInfoURL: document.userInfoEndpoint.flatMap(URL.init(string:))
        )
    }

    private struct DiscoveryDocument: Decodable {
        let issuer: String
        let authorizationEndpoint: String
        let tokenEndpoint: String
        let jwksURI: String
        let revocationEndpoint: String?
        let userInfoEndpoint: String?
        let codeChallengeMethodsSupported: [String]?

        enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case jwksURI = "jwks_uri"
            case revocationEndpoint = "revocation_endpoint"
            case userInfoEndpoint = "userinfo_endpoint"
            case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        }
    }
}

/// App-level settings for ``SignInWithChatGPTSession``.
public struct SignInWithChatGPTClientConfiguration: Sendable, Equatable {
    /// App name sent as `agent_name_hint` on the first registration of an account (the app's actual
    /// name, for example `"OpenClaw"`). It is shown to the user on the consent screen.
    public var agentName: String
    /// Requests the ChatGPT plan scopes (`offline_access resource.invoke chatgpt.tokens.use.direct`).
    /// When `false` only identity scopes are requested and no refresh token is issued.
    public var requestsPlanUsage: Bool
    /// Preferred loopback callback port.
    public var callbackPort: UInt16
    /// Falls back to an ephemeral loopback port when ``callbackPort`` is busy.
    public var allowsCallbackPortFallback: Bool
    /// Clock skew tolerated when validating ID-token times.
    public var clockSkew: TimeInterval
    /// Access tokens are refreshed this long before they expire.
    public var refreshLeeway: TimeInterval
    /// How long ``SignInWithChatGPTSession/signIn(using:reauthenticating:consent:timeout:)`` waits for
    /// the browser callback.
    public var signInTimeout: TimeInterval
    /// Authorization-server endpoints.
    public var endpoints: SignInWithChatGPTEndpoints

    /// Creates a client configuration.
    /// - Parameters:
    ///   - agentName: App name sent as `agent_name_hint`.
    ///   - requestsPlanUsage: Request the ChatGPT plan scopes.
    ///   - callbackPort: Preferred loopback callback port.
    ///   - allowsCallbackPortFallback: Use an ephemeral port when `callbackPort` is busy.
    ///   - clockSkew: Tolerated ID-token clock skew in seconds.
    ///   - refreshLeeway: Seconds before expiry at which access tokens refresh.
    ///   - signInTimeout: Seconds to wait for the browser callback.
    ///   - endpoints: Authorization-server endpoints.
    public init(
        agentName: String,
        requestsPlanUsage: Bool = true,
        callbackPort: UInt16 = SignInWithChatGPTConfiguration.defaultCallbackPort,
        allowsCallbackPortFallback: Bool = true,
        clockSkew: TimeInterval = 60,
        refreshLeeway: TimeInterval = 300,
        signInTimeout: TimeInterval = 600,
        endpoints: SignInWithChatGPTEndpoints = .production
    ) {
        self.agentName = agentName
        self.requestsPlanUsage = requestsPlanUsage
        self.callbackPort = callbackPort
        self.allowsCallbackPortFallback = allowsCallbackPortFallback
        self.clockSkew = clockSkew
        self.refreshLeeway = refreshLeeway
        self.signInTimeout = signInTimeout
        self.endpoints = endpoints
    }

    /// Scopes requested on authorization.
    public var scopes: [String] {
        SignInWithChatGPTConfiguration.identityScopes + (self.requestsPlanUsage ? SignInWithChatGPTConfiguration.planUsageScopes : [])
    }
}

/// HTTP transport used by the SIWC token, revocation and JWKS requests.
public struct SignInWithChatGPTHTTPTransport: Sendable {
    /// Sends a request and returns the response (any status code).
    public let send: @Sendable (URLRequest) async throws -> HTTPResponseData

    /// Creates a transport from a send closure.
    /// - Parameter send: Sends a request and returns the response.
    public init(send: @escaping @Sendable (URLRequest) async throws -> HTTPResponseData) {
        self.send = send
    }

    /// Transport backed by a `URLSession`.
    /// - Parameter session: URL session (defaults to `.shared`).
    /// - Returns: A transport.
    public static func urlSession(_ session: URLSession = .shared) -> Self {
        let client = HTTPClient(session: session)
        return Self { request in try await client.data(for: request) }
    }
}
