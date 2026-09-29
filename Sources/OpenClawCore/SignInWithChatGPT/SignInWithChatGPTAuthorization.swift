import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Stable, opaque identifier of the machine or app install that runs the agent (`ext_agent_host_id`).
///
/// OpenAI attributes plan usage to a host, so the identifier must stay the same across sign-ins,
/// accounts and token refreshes, and must be persisted before the first sign-in
/// (``SignInWithChatGPTAccountStore/hostIdentifier()`` does this). It must not identify the user:
/// never derive it from an email address, hostname or hardware serial.
///
/// Accepted formats: `urn:ietf:params:oauth:jwk-thumbprint:…` (RFC 9278, recommended when the host
/// already holds a stable key pair), `urn:uuid:…` (random UUIDv4) and `did:key:…`.
public struct SignInWithChatGPTHostIdentifier: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    /// RFC 9278 JWK thumbprint URN prefix for SHA-256 thumbprints.
    public static let jwkThumbprintPrefix = "urn:ietf:params:oauth:jwk-thumbprint:sha-256:"
    /// UUID URN prefix.
    public static let uuidPrefix = "urn:uuid:"
    /// DID key prefix.
    public static let didKeyPrefix = "did:key:"

    /// Identifier value sent as `ext_agent_host_id`.
    public let rawValue: String

    /// Validates an identifier.
    /// - Parameter rawValue: Identifier in one of the accepted formats.
    public init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...512).contains(value.count), value.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        if value.hasPrefix("urn:ietf:params:oauth:jwk-thumbprint:") {
            guard value.split(separator: ":").count >= 7, value.last != ":" else { return nil }
        } else if value.hasPrefix(Self.uuidPrefix) {
            guard UUID(uuidString: String(value.dropFirst(Self.uuidPrefix.count))) != nil else { return nil }
        } else if value.hasPrefix(Self.didKeyPrefix) {
            guard value.count > Self.didKeyPrefix.count else { return nil }
        } else {
            return nil
        }
        self.rawValue = value
    }

    /// Creates a random `urn:uuid:` identifier (UUIDv4, lowercase).
    /// - Returns: A new identifier; persist it and reuse it for every sign-in on this host.
    public static func randomUUID() -> Self {
        Self(rawValue: Self.uuidPrefix + UUID().uuidString.lowercased())!
    }

    /// Creates an RFC 9278 identifier from the SHA-256 JWK thumbprint (RFC 7638) of a stable Ed25519
    /// public key, such as a device identity key.
    /// - Parameter ed25519PublicKey: 32-byte raw public key.
    /// - Returns: The identifier, or `nil` for a key of the wrong length.
    public static func jwkThumbprint(ed25519PublicKey: Data) -> Self? {
        guard ed25519PublicKey.count == 32 else { return nil }
        return self.jwkThumbprint(members: ["crv": "Ed25519", "kty": "OKP", "x": SignInWithChatGPTBase64URL.encode(ed25519PublicKey)])
    }

    /// Creates an RFC 9278 identifier from the SHA-256 JWK thumbprint of a stable P-256 public key.
    /// - Parameter p256PublicKey: Raw `x‖y` (64 bytes) or uncompressed `0x04‖x‖y` (65 bytes) point.
    /// - Returns: The identifier, or `nil` for a key of the wrong length.
    public static func jwkThumbprint(p256PublicKey: Data) -> Self? {
        var point = [UInt8](p256PublicKey)
        if point.count == 65, point[0] == 0x04 {
            point.removeFirst()
        }
        guard point.count == 64 else { return nil }
        return self.jwkThumbprint(members: [
            "crv": "P-256",
            "kty": "EC",
            "x": SignInWithChatGPTBase64URL.encode(Data(point[0..<32])),
            "y": SignInWithChatGPTBase64URL.encode(Data(point[32..<64])),
        ])
    }

    /// Creates an RFC 9278 identifier from the required members of a public JWK.
    /// - Parameter members: Required JWK members only (for example `crv`, `kty`, `x`, `y`).
    /// - Returns: The identifier.
    public static func jwkThumbprint(members: [String: String]) -> Self? {
        guard !members.isEmpty else { return nil }
        // RFC 7638: required members, lexicographic order, no whitespace. Values are base64url or
        // short identifiers, so JSON string escaping only needs quotes and backslashes handled.
        let body = members.keys.sorted().map { key in
            "\(Self.jsonString(key)):\(Self.jsonString(members[key] ?? ""))"
        }.joined(separator: ",")
        let digest = SHA256.hash(data: Data("{\(body)}".utf8))
        return Self(rawValue: Self.jwkThumbprintPrefix + SignInWithChatGPTBase64URL.encode(Data(digest)))
    }

    /// The identifier value.
    public var description: String {
        self.rawValue
    }

    /// Decodes and validates an identifier string.
    /// - Parameter decoder: Decoder.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let identifier = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ext_agent_host_id"))
        }
        self = identifier
    }

    /// Encodes the identifier as a string.
    /// - Parameter encoder: Encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    private static func jsonString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Base64url helpers (RFC 4648 §5, no padding).
public enum SignInWithChatGPTBase64URL {
    /// Encodes bytes without padding.
    /// - Parameter data: Bytes.
    /// - Returns: Base64url text.
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url text with or without padding.
    /// - Parameter text: Base64url text.
    /// - Returns: Bytes, or `nil` when the text is not base64url.
    public static func decode(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "=") }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "=", with: "")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    /// Random bytes encoded as base64url.
    /// - Parameter byteCount: Number of random bytes.
    /// - Returns: Base64url text.
    public static func random(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return self.encode(Data((0..<max(1, byteCount)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }
}

/// PKCE (RFC 7636) verifier and `S256` challenge.
public struct SignInWithChatGPTPKCE: Sendable, Equatable {
    /// Code verifier (43 characters of base64url from 32 random bytes).
    public let verifier: String
    /// `S256` code challenge: base64url(SHA-256(verifier)) without padding.
    public let challenge: String

    /// Creates a PKCE pair from a verifier.
    /// - Parameter verifier: Code verifier.
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// Generates a fresh verifier and challenge.
    /// - Returns: A PKCE pair.
    public static func generate() -> Self {
        Self(verifier: SignInWithChatGPTBase64URL.random(byteCount: 32))
    }

    /// Computes the `S256` challenge for a verifier.
    /// - Parameter verifier: Code verifier.
    /// - Returns: Challenge.
    public static func challenge(for verifier: String) -> String {
        SignInWithChatGPTBase64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// Re-consent request added to an authorization.
public enum SignInWithChatGPTConsentPrompt: String, Sendable, Equatable, Codable {
    /// No consent prompt parameter.
    case automatic
    /// `prompt=consent`: show the consent screen again (re-enable plan usage).
    case consent
    /// `force_reconsent=true`: OpenAI's dedicated re-consent parameter (once rolled out).
    case forceReconsent
}

/// A started authorization waiting for its browser callback.
///
/// Keep it in memory (or protected storage) until the callback arrives; it holds the PKCE verifier.
public struct SignInWithChatGPTPendingAuthorization: Sendable, Equatable, Codable {
    /// URL to open in the browser.
    public let authorizationURL: URL
    /// Loopback redirect URI.
    public let redirectURI: URL
    /// `state` sent with the request.
    public let state: String
    /// `nonce` expected in the ID token.
    public let nonce: String
    /// PKCE code verifier.
    public let codeVerifier: String
    /// Client id the authorization was started with (`dynamic_agent_client` for a registration).
    public let clientID: String
    /// Host identifier sent as `ext_agent_host_id`.
    public let hostIdentifier: SignInWithChatGPTHostIdentifier
    /// Requested scopes.
    public let requestedScopes: [String]
    /// Subject of the account being re-authenticated, when this is not a registration.
    public let accountSubject: String?
    /// When the authorization started.
    public let createdAt: Date

    /// Whether this authorization registers a new client (`dynamic_agent_client`).
    public var isRegistration: Bool {
        self.clientID == SignInWithChatGPTConfiguration.dynamicClientID
    }

    /// Creates a pending authorization. Prefer ``SignInWithChatGPTAuthorizationRequest``, which
    /// generates the `state`, `nonce` and PKCE values.
    /// - Parameters:
    ///   - authorizationURL: URL to open.
    ///   - redirectURI: Loopback redirect URI.
    ///   - state: `state` value.
    ///   - nonce: `nonce` value.
    ///   - codeVerifier: PKCE verifier.
    ///   - clientID: Client id used.
    ///   - hostIdentifier: Host identifier.
    ///   - requestedScopes: Requested scopes.
    ///   - accountSubject: Account being re-authenticated.
    ///   - createdAt: Start time.
    public init(
        authorizationURL: URL,
        redirectURI: URL,
        state: String,
        nonce: String,
        codeVerifier: String,
        clientID: String,
        hostIdentifier: SignInWithChatGPTHostIdentifier,
        requestedScopes: [String],
        accountSubject: String?,
        createdAt: Date
    ) {
        self.authorizationURL = authorizationURL
        self.redirectURI = redirectURI
        self.state = state
        self.nonce = nonce
        self.codeVerifier = codeVerifier
        self.clientID = clientID
        self.hostIdentifier = hostIdentifier
        self.requestedScopes = requestedScopes
        self.accountSubject = accountSubject
        self.createdAt = createdAt
    }
}

/// Builds SIWC authorization requests.
public enum SignInWithChatGPTAuthorizationRequest {
    /// Re-authentication of a known account with its issued client id.
    public struct Reauthentication: Sendable, Equatable {
        /// Issued client id saved for the account (for example `oaiapp_…`).
        public var clientID: String
        /// Account subject.
        public var subject: String
        /// Last ID token, sent as `id_token_hint` (it may be expired).
        public var idTokenHint: String?
        /// Account email, sent as `login_hint`.
        public var loginHint: String?

        /// Creates a re-authentication request.
        /// - Parameters:
        ///   - clientID: Issued client id.
        ///   - subject: Account subject.
        ///   - idTokenHint: Last ID token.
        ///   - loginHint: Account email.
        public init(clientID: String, subject: String, idTokenHint: String? = nil, loginHint: String? = nil) {
            self.clientID = clientID
            self.subject = subject
            self.idTokenHint = idTokenHint
            self.loginHint = loginHint
        }
    }

    /// Creates a pending authorization with fresh `state`, `nonce` and PKCE values.
    ///
    /// Without `reauthentication` the request registers a new client: `client_id=dynamic_agent_client`
    /// plus `agent_name_hint`. With it, the account's issued client id is used and `agent_name_hint`
    /// is omitted.
    /// - Parameters:
    ///   - endpoints: Authorization-server endpoints.
    ///   - redirectURI: Loopback redirect URI (see ``SignInWithChatGPTConfiguration/isValidCallbackURL(_:)``).
    ///   - hostIdentifier: Persisted host identifier.
    ///   - scopes: Scopes to request.
    ///   - agentName: App name for `agent_name_hint`.
    ///   - reauthentication: Known account to re-authenticate.
    ///   - consent: Re-consent parameter.
    ///   - now: Current time.
    /// - Returns: The pending authorization.
    /// - Throws: ``SignInWithChatGPTError/invalidCallback(_:)`` for an unusable redirect URI.
    public static func make(
        endpoints: SignInWithChatGPTEndpoints = .production,
        redirectURI: URL,
        hostIdentifier: SignInWithChatGPTHostIdentifier,
        scopes: [String],
        agentName: String,
        reauthentication: Reauthentication? = nil,
        consent: SignInWithChatGPTConsentPrompt = .automatic,
        now: Date = Date()
    ) throws -> SignInWithChatGPTPendingAuthorization {
        try self.make(
            endpoints: endpoints,
            redirectURI: redirectURI,
            hostIdentifier: hostIdentifier,
            scopes: scopes,
            agentName: agentName,
            reauthentication: reauthentication,
            consent: consent,
            now: now,
            secrets: nil
        )
    }

    /// Fixed `state`, `nonce` and verifier (tests only).
    struct Secrets: Sendable {
        var state: String
        var nonce: String
        var verifier: String
    }

    static func make(
        endpoints: SignInWithChatGPTEndpoints,
        redirectURI: URL,
        hostIdentifier: SignInWithChatGPTHostIdentifier,
        scopes: [String],
        agentName: String,
        reauthentication: Reauthentication?,
        consent: SignInWithChatGPTConsentPrompt,
        now: Date,
        secrets: Secrets?
    ) throws -> SignInWithChatGPTPendingAuthorization {
        guard SignInWithChatGPTConfiguration.isValidCallbackURL(redirectURI) else {
            throw SignInWithChatGPTError.invalidCallback("redirect URI must be http://127.0.0.1:<port>/auth/callback")
        }
        let state = secrets?.state ?? SignInWithChatGPTBase64URL.random(byteCount: 32)
        let nonce = secrets?.nonce ?? SignInWithChatGPTBase64URL.random(byteCount: 32)
        let pkce = secrets.map { SignInWithChatGPTPKCE(verifier: $0.verifier) } ?? SignInWithChatGPTPKCE.generate()
        let clientID = reauthentication?.clientID ?? SignInWithChatGPTConfiguration.dynamicClientID
        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: SignInWithChatGPTConfiguration.resource),
            URLQueryItem(name: "ext_agent_host_id", value: hostIdentifier.rawValue),
        ]
        if let reauthentication {
            if let hint = reauthentication.idTokenHint, !hint.isEmpty {
                items.append(URLQueryItem(name: "id_token_hint", value: hint))
            }
            if let login = reauthentication.loginHint, !login.isEmpty {
                items.append(URLQueryItem(name: "login_hint", value: login))
            }
        } else {
            let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                items.append(URLQueryItem(name: "agent_name_hint", value: name))
            }
        }
        switch consent {
        case .automatic:
            break
        case .consent:
            items.append(URLQueryItem(name: "prompt", value: "consent"))
        case .forceReconsent:
            items.append(URLQueryItem(name: "force_reconsent", value: "true"))
        }
        guard var components = URLComponents(url: endpoints.authorizationURL, resolvingAgainstBaseURL: false) else {
            throw SignInWithChatGPTError.invalidServerResponse("authorization endpoint is not a valid URL")
        }
        components.percentEncodedQuery = SignInWithChatGPTFormEncoding.encode(items)
        guard let url = components.url else {
            throw SignInWithChatGPTError.invalidServerResponse("authorization URL could not be built")
        }
        return SignInWithChatGPTPendingAuthorization(
            authorizationURL: url,
            redirectURI: redirectURI,
            state: state,
            nonce: nonce,
            codeVerifier: pkce.verifier,
            clientID: clientID,
            hostIdentifier: hostIdentifier,
            requestedScopes: scopes,
            accountSubject: reauthentication?.subject,
            createdAt: now
        )
    }
}

/// A validated authorization callback.
public struct SignInWithChatGPTAuthorizationCallback: Sendable, Equatable {
    /// Authorization code.
    public let code: String
    /// Client id to use for the code exchange: the issued id from a registration callback, or the
    /// pending client id for a re-authentication.
    public let clientID: String
    /// Scopes reported on the callback, when present.
    public let grantedScopes: [String]?

    /// Parses and validates a callback URL against its pending authorization.
    ///
    /// Checks the redirect path, `error` (`access_denied` → ``SignInWithChatGPTError/accessDenied``),
    /// `state`, `code` and `client_id` (a registration must return an issued client id; a
    /// re-authentication must not return a different one).
    /// - Parameters:
    ///   - url: Callback URL received on the loopback listener (or pasted by the user).
    ///   - pending: Pending authorization.
    /// - Returns: The validated callback.
    /// - Throws: ``SignInWithChatGPTError`` for any mismatch.
    public static func parse(_ url: URL, pending: SignInWithChatGPTPendingAuthorization) throws -> Self {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SignInWithChatGPTError.invalidCallback("callback is not a URL")
        }
        guard components.path == pending.redirectURI.path else {
            throw SignInWithChatGPTError.invalidCallback("callback path does not match the redirect URI")
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }
        guard let state = values["state"], Self.constantTimeEquals(state, pending.state) else {
            throw SignInWithChatGPTError.stateMismatch
        }
        if let error = values["error"], !error.isEmpty {
            if error == "access_denied" {
                throw SignInWithChatGPTError.accessDenied
            }
            throw SignInWithChatGPTError.authorizationFailed(code: error, description: values["error_description"].flatMap { $0.isEmpty ? nil : $0 })
        }
        guard let code = values["code"], !code.isEmpty else {
            throw SignInWithChatGPTError.missingAuthorizationCode
        }
        let returnedClientID = values["client_id"].flatMap { $0.isEmpty ? nil : $0 }
        let clientID: String
        if pending.isRegistration {
            guard let returnedClientID, returnedClientID != SignInWithChatGPTConfiguration.dynamicClientID else {
                throw SignInWithChatGPTError.missingIssuedClientID
            }
            clientID = returnedClientID
        } else {
            if let returnedClientID, returnedClientID != pending.clientID {
                throw SignInWithChatGPTError.clientMismatch(expected: pending.clientID, received: returnedClientID)
            }
            clientID = pending.clientID
        }
        let scopes = values["scope"].map { $0.split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init) }
        return Self(code: code, clientID: clientID, grantedScopes: scopes)
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// `application/x-www-form-urlencoded` encoding shared by SIWC requests.
enum SignInWithChatGPTFormEncoding {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ items: [URLQueryItem]) -> String {
        items.map { item in
            "\(self.escape(item.name))=\(self.escape(item.value ?? ""))"
        }.joined(separator: "&")
    }

    static func encode(_ pairs: KeyValuePairs<String, String>) -> String {
        self.encode(pairs.map { URLQueryItem(name: $0.key, value: $0.value) })
    }

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: self.unreserved) ?? value
    }
}
