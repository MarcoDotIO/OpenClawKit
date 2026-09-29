import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore

@Suite("Sign in with ChatGPT authorization")
struct SignInWithChatGPTAuthorizationTests {
    private let host = SignInWithChatGPTHostIdentifier(rawValue: "urn:uuid:3f2c8a4e-7b1d-4c9e-9a51-2d6f0b8e4c17")!

    @Test("Host identifiers accept only the documented formats")
    func hostIdentifierFormats() throws {
        #expect(SignInWithChatGPTHostIdentifier(rawValue: "urn:uuid:3f2c8a4e-7b1d-4c9e-9a51-2d6f0b8e4c17") != nil)
        #expect(SignInWithChatGPTHostIdentifier(rawValue: "urn:ietf:params:oauth:jwk-thumbprint:sha-256:NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs") != nil)
        #expect(SignInWithChatGPTHostIdentifier(rawValue: "did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK") != nil)
        #expect(SignInWithChatGPTHostIdentifier(rawValue: "urn:uuid:not-a-uuid") == nil)
        #expect(SignInWithChatGPTHostIdentifier(rawValue: "person@example.com") == nil)
        #expect(SignInWithChatGPTHostIdentifier(rawValue: "did:key:") == nil)
        #expect(SignInWithChatGPTHostIdentifier(rawValue: "urn:uuid:3f2c8a4e 7b1d") == nil)

        let random = SignInWithChatGPTHostIdentifier.randomUUID()
        #expect(random.rawValue.hasPrefix("urn:uuid:"))
        #expect(random.rawValue == random.rawValue.lowercased())
        #expect(random != SignInWithChatGPTHostIdentifier.randomUUID())

        let data = try JSONEncoder().encode(random)
        #expect(try JSONDecoder().decode(SignInWithChatGPTHostIdentifier.self, from: data) == random)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SignInWithChatGPTHostIdentifier.self, from: Data(#""laptop.local""#.utf8))
        }
    }

    @Test("JWK thumbprints follow RFC 7638 and RFC 9278")
    func jwkThumbprint() throws {
        // RFC 7638 §3.1 example key and thumbprint.
        let modulus = "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-"
            + "5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08q"
            + "NLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw"
        let identifier = try #require(SignInWithChatGPTHostIdentifier.jwkThumbprint(members: ["kty": "RSA", "n": modulus, "e": "AQAB"]))
        #expect(identifier.rawValue == "urn:ietf:params:oauth:jwk-thumbprint:sha-256:NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs")

        let ed25519 = try #require(SignInWithChatGPTHostIdentifier.jwkThumbprint(ed25519PublicKey: Data(repeating: 7, count: 32)))
        #expect(ed25519.rawValue.hasPrefix(SignInWithChatGPTHostIdentifier.jwkThumbprintPrefix))
        #expect(SignInWithChatGPTHostIdentifier.jwkThumbprint(ed25519PublicKey: Data(repeating: 7, count: 31)) == nil)

        let point = Data(repeating: 1, count: 32) + Data(repeating: 2, count: 32)
        let raw = try #require(SignInWithChatGPTHostIdentifier.jwkThumbprint(p256PublicKey: point))
        let uncompressed = try #require(SignInWithChatGPTHostIdentifier.jwkThumbprint(p256PublicKey: Data([0x04]) + point))
        #expect(raw == uncompressed)
        #expect(SignInWithChatGPTHostIdentifier.jwkThumbprint(p256PublicKey: Data(repeating: 1, count: 33)) == nil)
    }

    @Test("PKCE uses S256 without padding and base64url round-trips")
    func pkce() {
        #expect(SignInWithChatGPTPKCE.challenge(for: "dBjftJeZ4CVP-mJ92K9dmtAkoUTL3VAUFWEPa9o-xgk") == "Ntr6zmdEd2QSHsYD5DZjLc27dCOy_MS9CCAx5jhmYWI")
        let generated = SignInWithChatGPTPKCE.generate()
        #expect(generated.verifier.count == 43)
        #expect(!generated.challenge.contains("="))
        #expect(generated.challenge == SignInWithChatGPTPKCE.challenge(for: generated.verifier))
        let bytes = Data((0..<255).map { UInt8($0) })
        #expect(SignInWithChatGPTBase64URL.decode(SignInWithChatGPTBase64URL.encode(bytes)) == bytes)
        #expect(SignInWithChatGPTBase64URL.decode("a+b/") == nil)
    }

    @Test("The auth-flow catalog lists Sign in with ChatGPT")
    func catalogDescriptor() throws {
        let descriptor = try #require(InteractiveAuthFlowCatalog.descriptor(for: "chatgpt-plan"))
        #expect(descriptor.displayName == "Sign in with ChatGPT")
        #expect(descriptor.kind == .browserOAuth)
        #expect(descriptor.clientID == "dynamic_agent_client")
        #expect(descriptor.callbackURL?.absoluteString == "http://127.0.0.1:1455/auth/callback")
        #expect(descriptor.scopes.contains("chatgpt.tokens.use.direct"))
        #expect(InteractiveAuthFlowCatalog.descriptor(for: "openai")?.displayName == "ChatGPT Login")
    }

    @Test("Redirect URIs must be the 127.0.0.1 loopback callback")
    func callbackURLValidation() {
        #expect(SignInWithChatGPTConfiguration.callbackURL().absoluteString == "http://127.0.0.1:1455/auth/callback")
        #expect(SignInWithChatGPTConfiguration.isValidCallbackURL(URL(string: "http://127.0.0.1:61000/auth/callback")!))
        #expect(!SignInWithChatGPTConfiguration.isValidCallbackURL(URL(string: "http://localhost:1455/auth/callback")!))
        #expect(!SignInWithChatGPTConfiguration.isValidCallbackURL(URL(string: "https://127.0.0.1:1455/auth/callback")!))
        #expect(!SignInWithChatGPTConfiguration.isValidCallbackURL(URL(string: "http://127.0.0.1/auth/callback")!))
        #expect(!SignInWithChatGPTConfiguration.isValidCallbackURL(URL(string: "http://127.0.0.1:1455/oauth/callback")!))
        #expect(!SignInWithChatGPTConfiguration.isValidCallbackURL(URL(string: "http://127.0.0.1:1455/auth/callback?x=1")!))
    }

    @Test("Registration requests use dynamic_agent_client, the host id and the plan scopes")
    func registrationRequest() throws {
        let pending = try SignInWithChatGPTAuthorizationRequest.make(
            redirectURI: SignInWithChatGPTConfiguration.callbackURL(port: 1455),
            hostIdentifier: self.host,
            scopes: SignInWithChatGPTClientConfiguration(agentName: "OpenClaw").scopes,
            agentName: "OpenClaw"
        )
        #expect(pending.isRegistration)
        #expect(pending.authorizationURL.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
        let query = SIWCTest.queryItems(pending.authorizationURL)
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == "dynamic_agent_client")
        #expect(query["agent_name_hint"] == "OpenClaw")
        #expect(query["ext_agent_host_id"] == self.host.rawValue)
        #expect(query["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
        #expect(query["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(query["resource"] == "https://api.openai.com/v1")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == SignInWithChatGPTPKCE.challenge(for: pending.codeVerifier))
        #expect(query["state"] == pending.state)
        #expect(query["nonce"] == pending.nonce)
        #expect(query["id_token_hint"] == nil)
        #expect(query["prompt"] == nil)
        #expect(query["force_reconsent"] == nil)
        // Spaces are percent-encoded, never `+`.
        #expect(pending.authorizationURL.absoluteString.contains("scope=openid%20profile"))
    }

    @Test("Re-authentication reuses the issued client id with hints and consent parameters")
    func reauthenticationRequest() throws {
        let reauth = SignInWithChatGPTAuthorizationRequest.Reauthentication(
            clientID: "oaiapp_test",
            subject: "user-abc",
            idTokenHint: "expired.id.token",
            loginHint: "person@example.com"
        )
        let pending = try SignInWithChatGPTAuthorizationRequest.make(
            redirectURI: SignInWithChatGPTConfiguration.callbackURL(port: 1455),
            hostIdentifier: self.host,
            scopes: SignInWithChatGPTConfiguration.identityScopes,
            agentName: "OpenClaw",
            reauthentication: reauth,
            consent: .forceReconsent
        )
        #expect(!pending.isRegistration)
        #expect(pending.accountSubject == "user-abc")
        let query = SIWCTest.queryItems(pending.authorizationURL)
        #expect(query["client_id"] == "oaiapp_test")
        #expect(query["agent_name_hint"] == nil)
        #expect(query["id_token_hint"] == "expired.id.token")
        #expect(query["login_hint"] == "person@example.com")
        #expect(query["force_reconsent"] == "true")
        #expect(query["scope"] == "openid profile email")

        let consent = try SignInWithChatGPTAuthorizationRequest.make(
            redirectURI: SignInWithChatGPTConfiguration.callbackURL(port: 1455),
            hostIdentifier: self.host,
            scopes: SignInWithChatGPTConfiguration.identityScopes,
            agentName: "OpenClaw",
            reauthentication: reauth,
            consent: .consent
        )
        #expect(SIWCTest.queryItems(consent.authorizationURL)["prompt"] == "consent")

        #expect(throws: SignInWithChatGPTError.self) {
            try SignInWithChatGPTAuthorizationRequest.make(
                redirectURI: URL(string: "http://localhost:1455/auth/callback")!,
                hostIdentifier: self.host,
                scopes: [],
                agentName: "OpenClaw"
            )
        }
    }

    @Test("Callbacks are validated against the pending authorization")
    func callbackValidation() throws {
        let registration = try self.pending(reauth: nil)
        let callback = try SignInWithChatGPTAuthorizationCallback.parse(SIWCTest.callbackURL(), pending: registration)
        #expect(callback.code == "code-1")
        #expect(callback.clientID == "oaiapp_test")
        #expect(callback.grantedScopes?.contains("chatgpt.tokens.use.direct") == true)

        #expect(throws: SignInWithChatGPTError.stateMismatch) {
            try SignInWithChatGPTAuthorizationCallback.parse(SIWCTest.callbackURL(state: "forged"), pending: registration)
        }
        #expect(throws: SignInWithChatGPTError.missingIssuedClientID) {
            try SignInWithChatGPTAuthorizationCallback.parse(SIWCTest.callbackURL(clientID: nil), pending: registration)
        }
        #expect(throws: SignInWithChatGPTError.missingIssuedClientID) {
            try SignInWithChatGPTAuthorizationCallback.parse(SIWCTest.callbackURL(clientID: "dynamic_agent_client"), pending: registration)
        }
        #expect(throws: SignInWithChatGPTError.missingAuthorizationCode) {
            try SignInWithChatGPTAuthorizationCallback.parse(SIWCTest.callbackURL(code: ""), pending: registration)
        }
        let denied = URL(string: "http://127.0.0.1:1455/auth/callback?error=access_denied&state=state-1")!
        #expect(throws: SignInWithChatGPTError.accessDenied) {
            try SignInWithChatGPTAuthorizationCallback.parse(denied, pending: registration)
        }
        let failed = URL(string: "http://127.0.0.1:1455/auth/callback?error=server_error&error_description=down&state=state-1")!
        #expect(throws: SignInWithChatGPTError.authorizationFailed(code: "server_error", description: "down")) {
            try SignInWithChatGPTAuthorizationCallback.parse(failed, pending: registration)
        }
        let wrongPath = URL(string: "http://127.0.0.1:1455/other?code=code-1&state=state-1&client_id=oaiapp_test")!
        #expect(throws: SignInWithChatGPTError.self) {
            try SignInWithChatGPTAuthorizationCallback.parse(wrongPath, pending: registration)
        }

        let reauth = try self.pending(reauth: .init(clientID: "oaiapp_test", subject: "user-abc"))
        #expect(try SignInWithChatGPTAuthorizationCallback.parse(SIWCTest.callbackURL(clientID: nil), pending: reauth).clientID == "oaiapp_test")
        #expect(throws: SignInWithChatGPTError.clientMismatch(expected: "oaiapp_test", received: "oaiapp_other")) {
            try SignInWithChatGPTAuthorizationCallback.parse(SIWCTest.callbackURL(clientID: "oaiapp_other"), pending: reauth)
        }
    }

    private func pending(reauth: SignInWithChatGPTAuthorizationRequest.Reauthentication?) throws -> SignInWithChatGPTPendingAuthorization {
        try SignInWithChatGPTAuthorizationRequest.make(
            endpoints: .production,
            redirectURI: SignInWithChatGPTConfiguration.callbackURL(port: 1455),
            hostIdentifier: self.host,
            scopes: SignInWithChatGPTClientConfiguration(agentName: "OpenClaw").scopes,
            agentName: "OpenClaw",
            reauthentication: reauth,
            consent: .automatic,
            now: Date(),
            secrets: SIWCTest.secrets
        )
    }
}

@Suite("Sign in with ChatGPT ID tokens")
struct SignInWithChatGPTIDTokenTests {
    private func validator(jwks: String = SignInWithChatGPTFixtures.jwks) -> (SignInWithChatGPTIDTokenValidator, SIWCFakeServer) {
        let server = SIWCFakeServer(jwks: jwks)
        let cache = SignInWithChatGPTJWKSCache(transport: server.transport)
        return (SignInWithChatGPTIDTokenValidator(jwks: cache, clockSkew: 60), server)
    }

    @Test("A valid RS256 ID token yields its claims")
    func validToken() async throws {
        let (validator, _) = self.validator()
        let claims = try await validator.validate(SignInWithChatGPTFixtures.Token.valid, clientID: "oaiapp_test", nonce: "nonce-1")
        #expect(claims.subject == "user-abc")
        #expect(claims.email == "person@example.com")
        #expect(claims.emailVerified == true)
        #expect(claims.name == "Test Person")
        #expect(claims.issuer == "https://auth.openai.com")
        #expect(claims.audience == ["oaiapp_test"])
        #expect(claims.nonce == "nonce-1")

        let array = try await validator.validate(SignInWithChatGPTFixtures.Token.audienceArray, clientID: "oaiapp_test", nonce: "nonce-1")
        #expect(array.audience == ["oaiapp_test", "other"])
        let refresh = try await validator.validate(SignInWithChatGPTFixtures.Token.refresh, clientID: "oaiapp_test", nonce: nil)
        #expect(refresh.nonce == nil)
    }

    @Test("Invalid ID tokens are rejected", arguments: [
        ("tampered", SignInWithChatGPTFixtures.Token.tampered, "oaiapp_test", "nonce-1"),
        ("expired", SignInWithChatGPTFixtures.Token.expired, "oaiapp_test", "nonce-1"),
        ("wrong issuer", SignInWithChatGPTFixtures.Token.wrongIssuer, "oaiapp_test", "nonce-1"),
        ("wrong audience", SignInWithChatGPTFixtures.Token.valid, "oaiapp_other", "nonce-1"),
        ("wrong azp", SignInWithChatGPTFixtures.Token.wrongAuthorizedParty, "oaiapp_test", "nonce-1"),
        ("wrong nonce", SignInWithChatGPTFixtures.Token.valid, "oaiapp_test", "nonce-2"),
        ("missing nonce", SignInWithChatGPTFixtures.Token.refresh, "oaiapp_test", "nonce-1"),
        ("alg none", SignInWithChatGPTFixtures.Token.algNone, "oaiapp_test", "nonce-1"),
        ("HS256", SignInWithChatGPTFixtures.Token.hs256, "oaiapp_test", "nonce-1"),
        ("not yet valid", SignInWithChatGPTFixtures.Token.notYetValid, "oaiapp_test", "nonce-1"),
        ("issued in the future", SignInWithChatGPTFixtures.Token.issuedInFuture, "oaiapp_test", "nonce-1"),
        ("1024-bit key", SignInWithChatGPTFixtures.Token.weakKey, "oaiapp_test", "nonce-1"),
        ("no kid with several keys", SignInWithChatGPTFixtures.Token.noKeyID, "oaiapp_test", "nonce-1"),
        ("malformed", "not-a-jwt", "oaiapp_test", "nonce-1"),
    ])
    func rejectsInvalidTokens(name: String, token: String, clientID: String, nonce: String) async throws {
        let (validator, _) = self.validator()
        await #expect(throws: SignInWithChatGPTError.self, "\(name)") {
            try await validator.validate(token, clientID: clientID, nonce: nonce)
        }
    }

    @Test("Unknown key ids refresh the JWKS once, and a single key needs no kid")
    func keyRotation() async throws {
        let (validator, server) = self.validator()
        await #expect(throws: SignInWithChatGPTError.self) {
            try await validator.validate(SignInWithChatGPTFixtures.Token.rotatedKey, clientID: "oaiapp_test", nonce: "nonce-1")
        }
        #expect(server.recordedRequests.count == 1)

        let rotated = SIWCFakeServer(jwks: SignInWithChatGPTFixtures.jwksRotated)
        let cache = SignInWithChatGPTJWKSCache(transport: rotated.transport, minimumRefreshInterval: 0)
        let fresh = SignInWithChatGPTIDTokenValidator(jwks: cache)
        _ = try await fresh.validate(SignInWithChatGPTFixtures.Token.valid, clientID: "oaiapp_test", nonce: "nonce-1")
        _ = try await fresh.validate(SignInWithChatGPTFixtures.Token.rotatedKey, clientID: "oaiapp_test", nonce: "nonce-1")
        #expect(rotated.recordedRequests.count == 1)

        let single = SIWCFakeServer(jwks: SignInWithChatGPTFixtures.jwksSingleKey)
        let singleValidator = SignInWithChatGPTIDTokenValidator(jwks: SignInWithChatGPTJWKSCache(transport: single.transport))
        _ = try await singleValidator.validate(SignInWithChatGPTFixtures.Token.noKeyID, clientID: "oaiapp_test", nonce: "nonce-1")
    }

    @Test("JWKS parsing keeps RSA signing keys and PKCS #1 DER is well formed")
    func jwksParsing() throws {
        let keys = try SignInWithChatGPTRSAPublicKey.keys(fromJWKS: Data(SignInWithChatGPTFixtures.jwks.utf8))
        #expect(keys.map(\.keyID) == ["test-key-1", "weak-key"])
        #expect(throws: SignInWithChatGPTError.self) {
            try SignInWithChatGPTRSAPublicKey.keys(fromJWKS: Data("[]".utf8))
        }
        let der = SignInWithChatGPTRSAPublicKey.pkcs1PublicKeyDER(modulus: Data([0x80, 0x01]), exponent: Data([0x01, 0x00, 0x01]))
        #expect([UInt8](der) == [0x30, 0x0A, 0x02, 0x03, 0x00, 0x80, 0x01, 0x02, 0x03, 0x01, 0x00, 0x01])
        let long = SignInWithChatGPTRSAPublicKey.pkcs1PublicKeyDER(modulus: Data(repeating: 0x7F, count: 256), exponent: Data([3]))
        #expect([UInt8](long.prefix(8)) == [0x30, 0x82, 0x01, 0x07, 0x02, 0x82, 0x01, 0x00])
    }

    @Test("Unverified claims decode for display")
    func unverifiedClaims() {
        #expect(SignInWithChatGPTIDTokenValidator.unverifiedClaims(SignInWithChatGPTFixtures.Token.valid)?.email == "person@example.com")
        #expect(SignInWithChatGPTIDTokenValidator.unverifiedClaims("x.y.z") == nil)
    }
}
