import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#elseif canImport(_CryptoExtras)
import _CryptoExtras
#endif

/// Validated ID-token claims.
public struct SignInWithChatGPTIDTokenClaims: Sendable, Equatable {
    /// Issuer (`iss`).
    public let issuer: String
    /// Stable account identifier (`sub`).
    public let subject: String
    /// Audiences (`aud`).
    public let audience: [String]
    /// Expiry (`exp`).
    public let expiresAt: Date
    /// Issue time (`iat`).
    public let issuedAt: Date?
    /// Nonce (`nonce`).
    public let nonce: String?
    /// Email (`email`).
    public let email: String?
    /// Whether the email is verified (`email_verified`).
    public let emailVerified: Bool?
    /// Display name (`name`).
    public let name: String?

    /// Creates claims.
    /// - Parameters:
    ///   - issuer: Issuer.
    ///   - subject: Subject.
    ///   - audience: Audiences.
    ///   - expiresAt: Expiry.
    ///   - issuedAt: Issue time.
    ///   - nonce: Nonce.
    ///   - email: Email.
    ///   - emailVerified: Email verification flag.
    ///   - name: Display name.
    public init(
        issuer: String,
        subject: String,
        audience: [String],
        expiresAt: Date,
        issuedAt: Date? = nil,
        nonce: String? = nil,
        email: String? = nil,
        emailVerified: Bool? = nil,
        name: String? = nil
    ) {
        self.issuer = issuer
        self.subject = subject
        self.audience = audience
        self.expiresAt = expiresAt
        self.issuedAt = issuedAt
        self.nonce = nonce
        self.email = email
        self.emailVerified = emailVerified
        self.name = name
    }
}

/// An RSA public key from a JWKS document.
public struct SignInWithChatGPTRSAPublicKey: Sendable, Equatable {
    /// Key id (`kid`).
    public let keyID: String?
    /// Modulus (`n`) bytes.
    public let modulus: Data
    /// Public exponent (`e`) bytes.
    public let exponent: Data

    /// Creates a key.
    /// - Parameters:
    ///   - keyID: Key id.
    ///   - modulus: Modulus bytes.
    ///   - exponent: Exponent bytes.
    public init(keyID: String?, modulus: Data, exponent: Data) {
        self.keyID = keyID
        self.modulus = modulus
        self.exponent = exponent
    }

    /// Parses the RSA signing keys of a JWKS document (other key types and `use` values are skipped).
    /// - Parameter data: JWKS JSON.
    /// - Returns: RSA keys.
    public static func keys(fromJWKS data: Data) throws -> [Self] {
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let keys = object["keys"] as? [[String: Any]]
        else {
            throw SignInWithChatGPTError.invalidServerResponse("JWKS document is not valid")
        }
        return keys.compactMap { jwk in
            guard
                jwk["kty"] as? String == "RSA",
                (jwk["use"] as? String).map({ $0 == "sig" }) ?? true,
                (jwk["alg"] as? String).map({ $0 == "RS256" }) ?? true,
                let n = (jwk["n"] as? String).flatMap(SignInWithChatGPTBase64URL.decode),
                let e = (jwk["e"] as? String).flatMap(SignInWithChatGPTBase64URL.decode)
            else {
                return nil
            }
            return Self(keyID: jwk["kid"] as? String, modulus: n, exponent: e)
        }
    }

    /// Verifies an RSASSA-PKCS1-v1_5 SHA-256 (RS256) signature. Keys shorter than 2048 bits are rejected.
    ///
    /// Uses Security.framework on Apple platforms and swift-crypto's `_CryptoExtras` on Linux.
    /// - Parameters:
    ///   - signature: Signature bytes.
    ///   - message: Signed bytes.
    /// - Returns: `true` when the signature is valid.
    public func verifyRS256(signature: Data, message: Data) -> Bool {
        let modulus = Self.stripLeadingZeros(self.modulus)
        guard modulus.count * 8 >= 2048, !self.exponent.isEmpty else { return false }
        #if canImport(Security)
        let der = Self.pkcs1PublicKeyDER(modulus: modulus, exponent: Self.stripLeadingZeros(self.exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            return false
        }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, &error)
        #elseif canImport(_CryptoExtras)
        guard let key = try? _RSA.Signing.PublicKey(n: modulus, e: Self.stripLeadingZeros(self.exponent)) else {
            return false
        }
        return key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature), for: message, padding: .insecurePKCS1v1_5)
        #else
        return false
        #endif
    }

    static func stripLeadingZeros(_ data: Data) -> Data {
        Data(data.drop { $0 == 0 })
    }

    /// DER `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }` (PKCS #1).
    static func pkcs1PublicKeyDER(modulus: Data, exponent: Data) -> Data {
        func integer(_ bytes: Data) -> Data {
            var content = bytes.isEmpty ? Data([0]) : bytes
            if let first = content.first, first & 0x80 != 0 {
                content.insert(0, at: 0)
            }
            return Data([0x02]) + length(content.count) + content
        }
        func length(_ count: Int) -> Data {
            if count < 0x80 {
                return Data([UInt8(count)])
            }
            var value = count
            var bytes: [UInt8] = []
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30]) + length(body.count) + body
    }
}

/// Caches the authorization server's JWKS and refreshes it when an unknown `kid` appears.
public actor SignInWithChatGPTJWKSCache {
    private let url: URL
    private let transport: SignInWithChatGPTHTTPTransport
    private let minimumRefreshInterval: TimeInterval
    private var keys: [SignInWithChatGPTRSAPublicKey] = []
    private var lastFetch: Date?

    /// Creates a cache.
    /// - Parameters:
    ///   - url: JWKS URL.
    ///   - transport: HTTP transport.
    ///   - minimumRefreshInterval: Minimum seconds between refreshes triggered by unknown key ids.
    public init(
        url: URL = SignInWithChatGPTConfiguration.jwksURL,
        transport: SignInWithChatGPTHTTPTransport = .urlSession(),
        minimumRefreshInterval: TimeInterval = 60
    ) {
        self.url = url
        self.transport = transport
        self.minimumRefreshInterval = minimumRefreshInterval
    }

    /// Returns the key for `keyID`, fetching the JWKS when it is not cached (at most once per
    /// `minimumRefreshInterval` for unknown ids).
    /// - Parameters:
    ///   - keyID: Key id from the JWT header (`nil` when absent).
    ///   - now: Current time.
    /// - Returns: The key, or `nil` when the JWKS has no matching key.
    public func key(for keyID: String?, now: Date = Date()) async throws -> SignInWithChatGPTRSAPublicKey? {
        if let key = self.match(keyID) {
            return key
        }
        if let lastFetch, now.timeIntervalSince(lastFetch) < self.minimumRefreshInterval, !self.keys.isEmpty {
            return nil
        }
        var request = URLRequest(url: self.url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await self.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw SignInWithChatGPTError.invalidServerResponse("JWKS returned status \(response.statusCode)")
        }
        self.keys = try SignInWithChatGPTRSAPublicKey.keys(fromJWKS: response.body)
        self.lastFetch = now
        return self.match(keyID)
    }

    private func match(_ keyID: String?) -> SignInWithChatGPTRSAPublicKey? {
        if let keyID {
            return self.keys.first { $0.keyID == keyID }
        }
        return self.keys.count == 1 ? self.keys.first : nil
    }
}

/// Validates SIWC ID tokens: RS256 signature (JWKS), `iss`, `aud`, `azp`, `exp`, `iat`, `nbf`,
/// `nonce` and a non-empty `sub`.
public struct SignInWithChatGPTIDTokenValidator: Sendable {
    /// Expected issuer.
    public let issuer: URL
    /// JWKS cache.
    public let jwks: SignInWithChatGPTJWKSCache
    /// Tolerated clock skew in seconds.
    public let clockSkew: TimeInterval

    /// Creates a validator.
    /// - Parameters:
    ///   - issuer: Expected issuer.
    ///   - jwks: JWKS cache.
    ///   - clockSkew: Tolerated clock skew in seconds.
    public init(issuer: URL = SignInWithChatGPTConfiguration.issuer, jwks: SignInWithChatGPTJWKSCache, clockSkew: TimeInterval = 60) {
        self.issuer = issuer
        self.jwks = jwks
        self.clockSkew = clockSkew
    }

    /// Validates an ID token.
    /// - Parameters:
    ///   - idToken: Compact JWT.
    ///   - clientID: Issued client id (expected audience).
    ///   - nonce: Expected nonce; `nil` skips the nonce check (refresh responses).
    ///   - now: Current time.
    /// - Returns: Validated claims.
    /// - Throws: ``SignInWithChatGPTError/invalidIDToken(_:)``.
    public func validate(_ idToken: String, clientID: String, nonce: String?, now: Date = Date()) async throws -> SignInWithChatGPTIDTokenClaims {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = SignInWithChatGPTBase64URL.decode(String(parts[0])),
              let payloadData = SignInWithChatGPTBase64URL.decode(String(parts[1])),
              let signature = SignInWithChatGPTBase64URL.decode(String(parts[2])),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        else {
            throw SignInWithChatGPTError.invalidIDToken("malformed token")
        }
        guard header["alg"] as? String == "RS256" else {
            throw SignInWithChatGPTError.invalidIDToken("unsupported algorithm")
        }
        guard let key = try await self.jwks.key(for: header["kid"] as? String, now: now) else {
            throw SignInWithChatGPTError.invalidIDToken("unknown signing key")
        }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard key.verifyRS256(signature: signature, message: signingInput) else {
            throw SignInWithChatGPTError.invalidIDToken("signature is invalid")
        }
        let claims = try Self.claims(from: payload)
        guard Self.normalizedIssuer(claims.issuer) == Self.normalizedIssuer(self.issuer.absoluteString) else {
            throw SignInWithChatGPTError.invalidIDToken("issuer does not match")
        }
        guard claims.audience.contains(clientID) else {
            throw SignInWithChatGPTError.invalidIDToken("audience does not match the client id")
        }
        if let authorizedParty = payload["azp"] as? String, authorizedParty != clientID {
            throw SignInWithChatGPTError.invalidIDToken("authorized party does not match the client id")
        }
        guard now < claims.expiresAt.addingTimeInterval(self.clockSkew) else {
            throw SignInWithChatGPTError.invalidIDToken("token is expired")
        }
        if let issuedAt = claims.issuedAt, issuedAt > now.addingTimeInterval(self.clockSkew) {
            throw SignInWithChatGPTError.invalidIDToken("token was issued in the future")
        }
        if let notBefore = Self.seconds(payload["nbf"]), Date(timeIntervalSince1970: notBefore) > now.addingTimeInterval(self.clockSkew) {
            throw SignInWithChatGPTError.invalidIDToken("token is not valid yet")
        }
        if let nonce {
            guard let tokenNonce = claims.nonce, SignInWithChatGPTAuthorizationCallback.constantTimeEquals(tokenNonce, nonce) else {
                throw SignInWithChatGPTError.invalidIDToken("nonce does not match")
            }
        }
        return claims
    }

    /// Decodes the claims of a JWT without verifying it (for display only, never for trust decisions).
    /// - Parameter idToken: Compact JWT.
    /// - Returns: Claims, or `nil` when the token cannot be decoded.
    public static func unverifiedClaims(_ idToken: String) -> SignInWithChatGPTIDTokenClaims? {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let data = SignInWithChatGPTBase64URL.decode(String(parts[1])),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        return try? self.claims(from: payload)
    }

    static func claims(from payload: [String: Any]) throws -> SignInWithChatGPTIDTokenClaims {
        guard let issuer = payload["iss"] as? String else {
            throw SignInWithChatGPTError.invalidIDToken("missing issuer")
        }
        guard let subject = payload["sub"] as? String, !subject.isEmpty else {
            throw SignInWithChatGPTError.invalidIDToken("missing subject")
        }
        let audience: [String]
        if let single = payload["aud"] as? String {
            audience = [single]
        } else if let list = payload["aud"] as? [String] {
            audience = list
        } else {
            throw SignInWithChatGPTError.invalidIDToken("missing audience")
        }
        guard let expiry = self.seconds(payload["exp"]) else {
            throw SignInWithChatGPTError.invalidIDToken("missing expiry")
        }
        return SignInWithChatGPTIDTokenClaims(
            issuer: issuer,
            subject: subject,
            audience: audience,
            expiresAt: Date(timeIntervalSince1970: expiry),
            issuedAt: self.seconds(payload["iat"]).map { Date(timeIntervalSince1970: $0) },
            nonce: payload["nonce"] as? String,
            email: payload["email"] as? String,
            emailVerified: self.bool(payload["email_verified"]),
            name: payload["name"] as? String
        )
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        switch value {
        case let number as Int:
            return TimeInterval(number)
        case let number as Double:
            return number
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            return TimeInterval(text)
        default:
            return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }

    private static func normalizedIssuer(_ value: String) -> String {
        value.hasSuffix("/") ? String(value.dropLast()) : value
    }
}
