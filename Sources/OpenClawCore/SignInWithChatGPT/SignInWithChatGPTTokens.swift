import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Token-endpoint response for the code exchange and the refresh grant.
public struct SignInWithChatGPTTokenResponse: Sendable, Equatable, Decodable {
    /// Access token (one hour).
    public let accessToken: String
    /// Rotating refresh token (30 days), present when `offline_access` was granted.
    public let refreshToken: String?
    /// ID token.
    public let idToken: String?
    /// Token type (`Bearer`).
    public let tokenType: String
    /// Access-token lifetime in seconds.
    public let expiresIn: Int?
    /// Space-separated granted scopes.
    public let scope: String?
    /// Earliest time a refresh should be attempted.
    public let earliestRefreshAt: Date?

    /// Creates a token response.
    /// - Parameters:
    ///   - accessToken: Access token.
    ///   - refreshToken: Refresh token.
    ///   - idToken: ID token.
    ///   - tokenType: Token type.
    ///   - expiresIn: Lifetime in seconds.
    ///   - scope: Granted scopes.
    ///   - earliestRefreshAt: Earliest refresh time.
    public init(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        tokenType: String = "Bearer",
        expiresIn: Int? = nil,
        scope: String? = nil,
        earliestRefreshAt: Date? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.scope = scope
        self.earliestRefreshAt = earliestRefreshAt
    }

    /// Granted scopes as a list.
    public var grantedScopes: [String]? {
        self.scope.map { $0.split(separator: " ").map(String.init) }
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
        case earliestRefreshAt = "earliest_refresh_at"
    }

    /// Decodes a token response; `earliest_refresh_at` may be Unix seconds or an ISO 8601 string.
    /// - Parameter decoder: Decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = try container.decode(String.self, forKey: .accessToken)
        self.refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        self.idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
        self.tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
        if let seconds = try? container.decodeIfPresent(Int.self, forKey: .expiresIn) {
            self.expiresIn = seconds
        } else if let seconds = try? container.decodeIfPresent(Double.self, forKey: .expiresIn) {
            self.expiresIn = Int(seconds)
        } else {
            self.expiresIn = (try? container.decodeIfPresent(String.self, forKey: .expiresIn)).flatMap { $0.flatMap(Int.init) }
        }
        self.scope = try container.decodeIfPresent(String.self, forKey: .scope)
        self.earliestRefreshAt = SignInWithChatGPTDates.flexibleDate(container, forKey: .earliestRefreshAt)
    }
}

/// Stored credential for one SIWC account (the documented credential record).
///
/// Encodes to the documented JSON field names (`client_id`, `access_token`, `refresh_token`,
/// `id_token`, `expires_in`, `saved_at` as ISO 8601, `ext_agent_host_id`, …) so a record can be moved
/// to a self-hosted VM. Never log it; persist it only in a ``CredentialStore`` (Keychain on Apple
/// platforms, a `0600` file elsewhere).
public struct SignInWithChatGPTCredential: Codable, Sendable, Equatable {
    /// Account email, when shared.
    public var email: String?
    /// Token issuer.
    public var issuer: String
    /// Account subject (`sub`).
    public var subject: String
    /// Issued client id of this account's registration.
    public var clientID: String
    /// Host identifier the credential was issued to.
    public var hostIdentifier: SignInWithChatGPTHostIdentifier
    /// Last ID token (kept for `id_token_hint`).
    public var idToken: String?
    /// Current access token.
    public var accessToken: String
    /// Current refresh token.
    public var refreshToken: String?
    /// Token type.
    public var tokenType: String
    /// Access-token lifetime in seconds from ``savedAt``.
    public var expiresIn: Int?
    /// Granted scopes.
    public var scopes: [String]
    /// When the tokens were saved.
    public var savedAt: Date
    /// Earliest time a refresh should be attempted.
    public var earliestRefreshAt: Date?

    /// Creates a credential.
    /// - Parameters:
    ///   - email: Account email.
    ///   - issuer: Token issuer.
    ///   - subject: Account subject.
    ///   - clientID: Issued client id.
    ///   - hostIdentifier: Host identifier.
    ///   - idToken: ID token.
    ///   - accessToken: Access token.
    ///   - refreshToken: Refresh token.
    ///   - tokenType: Token type.
    ///   - expiresIn: Lifetime in seconds.
    ///   - scopes: Granted scopes.
    ///   - savedAt: Save time.
    ///   - earliestRefreshAt: Earliest refresh time.
    public init(
        email: String?,
        issuer: String,
        subject: String,
        clientID: String,
        hostIdentifier: SignInWithChatGPTHostIdentifier,
        idToken: String?,
        accessToken: String,
        refreshToken: String?,
        tokenType: String = "Bearer",
        expiresIn: Int?,
        scopes: [String],
        savedAt: Date,
        earliestRefreshAt: Date? = nil
    ) {
        self.email = email
        self.issuer = issuer
        self.subject = subject
        self.clientID = clientID
        self.hostIdentifier = hostIdentifier
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.scopes = scopes
        self.savedAt = savedAt
        self.earliestRefreshAt = earliestRefreshAt
    }

    /// When the access token expires, when its lifetime is known.
    public var expiresAt: Date? {
        self.expiresIn.map { self.savedAt.addingTimeInterval(TimeInterval($0)) }
    }

    /// Whether the grant allows ChatGPT plan inference.
    public var allowsPlanUsage: Bool {
        self.scopes.contains(SignInWithChatGPTConfiguration.planUsageScope)
    }

    /// Whether the access token should be refreshed at `now`.
    /// - Parameters:
    ///   - now: Current time.
    ///   - leeway: Seconds before expiry at which to refresh.
    /// - Returns: `true` when a refresh token exists and the access token is (nearly) expired.
    public func needsRefresh(now: Date, leeway: TimeInterval) -> Bool {
        guard self.refreshToken != nil, let expiresAt = self.expiresAt else { return false }
        if now >= expiresAt {
            return true
        }
        if let earliest = self.earliestRefreshAt, now < earliest {
            return false
        }
        return now >= expiresAt.addingTimeInterval(-leeway)
    }

    /// Applies a refresh response: every token is replaced together (refresh tokens rotate).
    /// - Parameters:
    ///   - response: Refresh response.
    ///   - now: Save time.
    /// - Returns: The updated credential.
    public func applying(_ response: SignInWithChatGPTTokenResponse, now: Date) -> Self {
        var updated = self
        updated.accessToken = response.accessToken
        updated.refreshToken = response.refreshToken ?? self.refreshToken
        updated.idToken = response.idToken ?? self.idToken
        updated.tokenType = response.tokenType
        updated.expiresIn = response.expiresIn
        updated.scopes = response.grantedScopes ?? self.scopes
        updated.savedAt = now
        updated.earliestRefreshAt = response.earliestRefreshAt
        return updated
    }

    enum CodingKeys: String, CodingKey {
        case email
        case issuer
        case subject
        case clientID = "client_id"
        case hostIdentifier = "ext_agent_host_id"
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scopes
        case savedAt = "saved_at"
        case earliestRefreshAt = "earliest_refresh_at"
    }

    /// Decodes a credential record.
    /// - Parameter decoder: Decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.issuer = try container.decodeIfPresent(String.self, forKey: .issuer) ?? SignInWithChatGPTConfiguration.issuer.absoluteString
        self.subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        self.clientID = try container.decode(String.self, forKey: .clientID)
        self.hostIdentifier = try container.decode(SignInWithChatGPTHostIdentifier.self, forKey: .hostIdentifier)
        self.idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
        self.accessToken = try container.decode(String.self, forKey: .accessToken)
        self.refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        self.tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
        self.expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
        if let scopes = try? container.decodeIfPresent([String].self, forKey: .scopes) {
            self.scopes = scopes
        } else {
            self.scopes = (try container.decodeIfPresent(String.self, forKey: .scopes))?.split(separator: " ").map(String.init) ?? []
        }
        self.savedAt = SignInWithChatGPTDates.flexibleDate(container, forKey: .savedAt) ?? Date(timeIntervalSince1970: 0)
        self.earliestRefreshAt = SignInWithChatGPTDates.flexibleDate(container, forKey: .earliestRefreshAt)
    }

    /// Encodes a credential record (`saved_at` as ISO 8601).
    /// - Parameter encoder: Encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.email, forKey: .email)
        try container.encode(self.issuer, forKey: .issuer)
        try container.encode(self.subject, forKey: .subject)
        try container.encode(self.clientID, forKey: .clientID)
        try container.encode(self.hostIdentifier, forKey: .hostIdentifier)
        try container.encodeIfPresent(self.idToken, forKey: .idToken)
        try container.encode(self.accessToken, forKey: .accessToken)
        try container.encodeIfPresent(self.refreshToken, forKey: .refreshToken)
        try container.encode(self.tokenType, forKey: .tokenType)
        try container.encodeIfPresent(self.expiresIn, forKey: .expiresIn)
        try container.encode(self.scopes, forKey: .scopes)
        try container.encode(SignInWithChatGPTDates.iso8601(self.savedAt), forKey: .savedAt)
        try container.encodeIfPresent(self.earliestRefreshAt.map(SignInWithChatGPTDates.iso8601), forKey: .earliestRefreshAt)
    }

    /// Encodes the record as JSON (sorted keys), for example to move it to a self-hosted VM.
    /// - Returns: JSON bytes containing live tokens; protect them like a password.
    public func recordJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decodes a credential record.
    /// - Parameter data: Record JSON.
    /// - Returns: The credential.
    public static func decodeRecord(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

/// Date helpers for SIWC payloads.
enum SignInWithChatGPTDates {
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func flexibleDate<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) -> Date? {
        if let seconds = try? container.decodeIfPresent(Double.self, forKey: key) {
            // Millisecond timestamps are far beyond any plausible seconds value.
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000 : seconds)
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            if let seconds = Double(text) {
                return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000 : seconds)
            }
            return self.parseISO8601(text)
        }
        return nil
    }
}

/// Token-endpoint client: code exchange, refresh and revocation (public client, no secret).
public struct SignInWithChatGPTTokenClient: Sendable {
    /// Endpoints.
    public let endpoints: SignInWithChatGPTEndpoints
    /// HTTP transport.
    public let transport: SignInWithChatGPTHTTPTransport
    /// Delays between revocation retries (seconds).
    let revocationRetryDelays: [TimeInterval]

    /// Creates a token client.
    /// - Parameters:
    ///   - endpoints: Endpoints.
    ///   - transport: HTTP transport.
    public init(endpoints: SignInWithChatGPTEndpoints = .production, transport: SignInWithChatGPTHTTPTransport = .urlSession()) {
        self.init(endpoints: endpoints, transport: transport, revocationRetryDelays: [0.5, 1, 2])
    }

    init(endpoints: SignInWithChatGPTEndpoints, transport: SignInWithChatGPTHTTPTransport, revocationRetryDelays: [TimeInterval]) {
        self.endpoints = endpoints
        self.transport = transport
        self.revocationRetryDelays = revocationRetryDelays
    }

    /// Exchanges an authorization code (`grant_type=authorization_code`).
    /// - Parameters:
    ///   - callback: Validated callback (its client id is the issued id).
    ///   - pending: Pending authorization (verifier and redirect URI).
    /// - Returns: Token response.
    /// - Throws: ``SignInWithChatGPTError/authorizationCodeRejected(_:)`` for `invalid_grant`.
    public func exchange(
        _ callback: SignInWithChatGPTAuthorizationCallback,
        pending: SignInWithChatGPTPendingAuthorization
    ) async throws -> SignInWithChatGPTTokenResponse {
        let form: KeyValuePairs<String, String> = [
            "grant_type": "authorization_code",
            "client_id": callback.clientID,
            "code": callback.code,
            "code_verifier": pending.codeVerifier,
            "redirect_uri": pending.redirectURI.absoluteString,
            "resource": SignInWithChatGPTConfiguration.resource,
        ]
        do {
            return try await self.tokenRequest(form)
        } catch let OAuthFailure.rejected(status, code, description) {
            switch code {
            case "invalid_grant"?:
                throw SignInWithChatGPTError.authorizationCodeRejected(description)
            case "invalid_client"?:
                throw SignInWithChatGPTError.invalidClient(description)
            default:
                throw SignInWithChatGPTError.tokenRequestFailed(statusCode: status, code: code, description: description)
            }
        }
    }

    /// Refreshes tokens (`grant_type=refresh_token`, no `scope`).
    /// - Parameters:
    ///   - refreshToken: Current refresh token.
    ///   - clientID: Issued client id of the account.
    ///   - subject: Account subject (for error reporting).
    /// - Returns: Token response with a rotated refresh token.
    /// - Throws: ``SignInWithChatGPTError/reauthenticationRequired(subject:reason:)`` when the refresh
    ///   token is no longer usable; ``SignInWithChatGPTError/invalidClient(_:)`` for `invalid_client`.
    public func refresh(refreshToken: String, clientID: String, subject: String) async throws -> SignInWithChatGPTTokenResponse {
        let form: KeyValuePairs<String, String> = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
            "resource": SignInWithChatGPTConfiguration.resource,
        ]
        do {
            return try await self.tokenRequest(form)
        } catch let OAuthFailure.rejected(status, code, description) {
            if let code, Self.reauthenticationCodes.contains(code) {
                throw SignInWithChatGPTError.reauthenticationRequired(subject: subject, reason: code)
            }
            if code == "invalid_client" {
                throw SignInWithChatGPTError.invalidClient(description)
            }
            if status == 401 {
                throw SignInWithChatGPTError.reauthenticationRequired(subject: subject, reason: code ?? "unauthorized")
            }
            throw SignInWithChatGPTError.tokenRequestFailed(statusCode: status, code: code, description: description)
        }
    }

    /// Revokes a refresh token. Retries network failures and `5xx` responses with backoff.
    /// - Parameters:
    ///   - refreshToken: Refresh token to revoke.
    ///   - clientID: Issued client id of the account.
    /// - Throws: ``SignInWithChatGPTError/revocationFailed(_:)`` after the retries are exhausted or for
    ///   a `4xx` response.
    public func revoke(refreshToken: String, clientID: String) async throws {
        let body = SignInWithChatGPTFormEncoding.encode([
            "token": refreshToken,
            "token_type_hint": "refresh_token",
            "client_id": clientID,
        ] as KeyValuePairs<String, String>)
        var request = URLRequest(url: self.endpoints.revocationURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.utf8)
        var lastFailure = "no attempt"
        for attempt in 0...self.revocationRetryDelays.count {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(self.revocationRetryDelays[attempt - 1] * 1_000_000_000))
            }
            do {
                let response = try await self.transport.send(request)
                if (200..<300).contains(response.statusCode) {
                    return
                }
                let failure = Self.oauthError(response.body)
                lastFailure = "status \(response.statusCode)" + (failure.code.map { " (\($0))" } ?? "")
                if response.statusCode < 500 {
                    throw SignInWithChatGPTError.revocationFailed(lastFailure)
                }
            } catch let error as SignInWithChatGPTError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = "network error"
            }
        }
        throw SignInWithChatGPTError.revocationFailed(lastFailure)
    }

    /// Refresh-grant error codes that mean the refresh token can no longer be used.
    public static let reauthenticationCodes: Set<String> = [
        "invalid_grant",
        "invalid_refresh_token",
        "token_expired",
        "refresh_token_expired",
        "refresh_token_invalidated",
        "refresh_token_reused",
    ]

    enum OAuthFailure: Error {
        case rejected(status: Int, code: String?, description: String?)
    }

    private func tokenRequest(_ form: KeyValuePairs<String, String>) async throws -> SignInWithChatGPTTokenResponse {
        var request = URLRequest(url: self.endpoints.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(SignInWithChatGPTFormEncoding.encode(form).utf8)
        let response = try await self.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let failure = Self.oauthError(response.body)
            throw OAuthFailure.rejected(status: response.statusCode, code: failure.code, description: failure.description)
        }
        do {
            return try JSONDecoder().decode(SignInWithChatGPTTokenResponse.self, from: response.body)
        } catch {
            throw SignInWithChatGPTError.invalidServerResponse("token response is not valid JSON")
        }
    }

    /// Reads `{"error": "…", "error_description": "…"}` or `{"error": {"code": …, "message": …}}`.
    static func oauthError(_ body: Data) -> (code: String?, description: String?) {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return (nil, nil)
        }
        if let nested = object["error"] as? [String: Any] {
            let code = (nested["code"] as? String) ?? (nested["type"] as? String)
            return (code, Self.shortened(nested["message"] as? String))
        }
        let code = (object["error"] as? String) ?? (object["code"] as? String)
        let description = (object["error_description"] as? String) ?? (object["message"] as? String) ?? (object["detail"] as? String)
        return (code, Self.shortened(description))
    }

    private static func shortened(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }
}
