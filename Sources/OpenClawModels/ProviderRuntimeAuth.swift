import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// HTTP transport contract used by runtime auth refresh and token-exchange helpers.
public protocol RuntimeAuthHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured request.
    /// - Returns: Response metadata and body payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: RuntimeAuthHTTPTransport {}

/// Result of resolving a stored auth profile into runtime request credentials.
public struct ProviderRuntimeAuthResolution: Sendable, Equatable {
    /// Effective credential used for this request.
    public var credential: AuthProfileCredential
    /// Indicates whether the effective credential should be written back to the auth profile store.
    public var persistCredential: Bool
    /// Additional request metadata derived during auth resolution.
    public var metadata: [String: String]

    /// Creates a runtime auth resolution.
    /// - Parameters:
    ///   - credential: Effective credential used for the request.
    ///   - persistCredential: Whether the credential should be written back to storage.
    ///   - metadata: Additional request metadata.
    public init(
        credential: AuthProfileCredential,
        persistCredential: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.credential = credential
        self.persistCredential = persistCredential
        self.metadata = metadata
    }
}

/// Provider-aware runtime auth resolver used by `ModelRouter`.
public protocol ProviderRuntimeAuthResolving: Sendable {
    /// Resolves runtime credentials for one provider request.
    /// - Parameters:
    ///   - providerID: Target provider identifier.
    ///   - credential: Stored auth profile credential.
    /// - Returns: Effective runtime credential and any derived metadata overrides.
    func resolve(
        providerID: String,
        credential: AuthProfileCredential
    ) async throws -> ProviderRuntimeAuthResolution
}

/// Default runtime auth resolver aligned with the TS provider auth flows.
public actor RuntimeProviderAuthResolver: ProviderRuntimeAuthResolving {
    public static let shared = RuntimeProviderAuthResolver()

    private static let qwenOAuthTokenEndpoint = URL(string: "https://chat.qwen.ai/api/v1/oauth2/token")!
    private static let qwenOAuthClientID = "f0304373b74a44d2b584a3fb70ca9e56"
    private static let githubCopilotTokenEndpoint = URL(string: "https://api.github.com/copilot_internal/v2/token")!
    private static let githubCopilotDefaultBaseURL = "https://api.individual.githubcopilot.com"
    private static let preemptiveRefreshWindowMs = 60_000
    private static let copilotCacheSafetyWindowMs = 5 * 60 * 1000

    private struct CachedCopilotToken: Sendable {
        var token: String
        var expiresAt: Int
        var baseURL: String
    }

    private let transport: any RuntimeAuthHTTPTransport
    private let now: @Sendable () -> Int
    private var copilotCacheByGitHubToken: [String: CachedCopilotToken] = [:]

    /// Creates a runtime auth resolver.
    /// - Parameters:
    ///   - transport: HTTP transport used for refresh and exchange requests.
    ///   - now: Clock returning milliseconds since epoch.
    public init(
        transport: any RuntimeAuthHTTPTransport = HTTPClient(),
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.transport = transport
        self.now = now
    }

    public func resolve(
        providerID: String,
        credential: AuthProfileCredential
    ) async throws -> ProviderRuntimeAuthResolution {
        switch OpenClawReferenceProviderCatalog.normalize(providerID: providerID) {
        case GitHubCopilotModelProvider.providerID:
            return try await self.resolveGitHubCopilot(credential)
        case QwenPortalModelProvider.providerID:
            return try await self.resolveQwenPortal(credential)
        default:
            return ProviderRuntimeAuthResolution(credential: credential)
        }
    }

    private func resolveGitHubCopilot(
        _ credential: AuthProfileCredential
    ) async throws -> ProviderRuntimeAuthResolution {
        guard case .token(let value) = credential,
              let githubToken = Self.normalized(value.token)
        else {
            return ProviderRuntimeAuthResolution(credential: credential)
        }

        let now = self.now()
        if let cached = self.copilotCacheByGitHubToken[githubToken],
           cached.expiresAt - now > Self.copilotCacheSafetyWindowMs
        {
            return ProviderRuntimeAuthResolution(
                credential: .token(
                    TokenAuthProfileCredential(
                        provider: value.provider,
                        token: cached.token,
                        expires: cached.expiresAt,
                        email: value.email
                    )
                ),
                metadata: ["provider.baseURL": cached.baseURL]
            )
        }

        var request = URLRequest(url: Self.githubCopilotTokenEndpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(githubToken)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("github-copilot token exchange failed with status \(response.statusCode)")
        }

        let payload = try JSONDecoder().decode(GitHubCopilotTokenResponse.self, from: response.body)
        guard let exchangedToken = Self.normalized(payload.token) else {
            throw OpenClawCoreError.unavailable("github-copilot token exchange response missing token")
        }
        let expiresAt = try Self.parseCopilotExpiry(payload.expiresAt)
        let baseURL = Self.deriveCopilotBaseURL(from: exchangedToken) ?? Self.githubCopilotDefaultBaseURL
        self.copilotCacheByGitHubToken[githubToken] = CachedCopilotToken(
            token: exchangedToken,
            expiresAt: expiresAt,
            baseURL: baseURL
        )
        return ProviderRuntimeAuthResolution(
            credential: .token(
                TokenAuthProfileCredential(
                    provider: value.provider,
                    token: exchangedToken,
                    expires: expiresAt,
                    email: value.email
                )
            ),
            metadata: ["provider.baseURL": baseURL]
        )
    }

    private func resolveQwenPortal(
        _ credential: AuthProfileCredential
    ) async throws -> ProviderRuntimeAuthResolution {
        guard case .oauth(let value) = credential else {
            return ProviderRuntimeAuthResolution(credential: credential)
        }

        let accessToken = Self.normalized(value.accessToken)
        let refreshToken = Self.normalized(value.refreshToken)
        let now = self.now()
        let needsRefresh: Bool
        if let expires = value.expires {
            needsRefresh = expires <= now + Self.preemptiveRefreshWindowMs
        } else {
            needsRefresh = accessToken == nil
        }

        guard needsRefresh, let refreshToken else {
            return ProviderRuntimeAuthResolution(credential: credential)
        }

        var request = URLRequest(url: Self.qwenOAuthTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncodedBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.normalized(value.clientID) ?? Self.qwenOAuthClientID,
        ])
        let response = try await self.transport.data(for: request)
        if response.statusCode == 400 {
            throw OpenClawCoreError.unavailable("Qwen OAuth refresh token expired or invalid; re-authenticate.")
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw OpenClawCoreError.unavailable(
                "Qwen OAuth refresh failed with status \(response.statusCode)\(body.isEmpty ? "" : ": \(body)")"
            )
        }

        let payload = try JSONDecoder().decode(QwenRefreshTokenResponse.self, from: response.body)
        guard let nextAccessToken = Self.normalized(payload.accessToken) else {
            throw OpenClawCoreError.unavailable("Qwen OAuth refresh response missing access token")
        }
        guard let expiresIn = payload.expiresIn, expiresIn > 0 else {
            throw OpenClawCoreError.unavailable("Qwen OAuth refresh response missing or invalid expires_in")
        }
        let updatedCredential = OAuthAuthProfileCredential(
            provider: value.provider,
            accessToken: nextAccessToken,
            refreshToken: Self.normalized(payload.refreshToken) ?? refreshToken,
            expires: now + expiresIn * 1000,
            clientID: Self.normalized(value.clientID) ?? Self.qwenOAuthClientID,
            email: value.email,
            metadata: value.metadata
        )
        return ProviderRuntimeAuthResolution(
            credential: .oauth(updatedCredential),
            persistCredential: true
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func formEncodedBody(_ fields: [String: String]) -> Data {
        let body = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(Self.urlEncode(key))=\(Self.urlEncode(value))"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private static func urlEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func parseCopilotExpiry(_ raw: JSONScalar?) throws -> Int {
        guard let raw else {
            throw OpenClawCoreError.unavailable("github-copilot token exchange response missing expires_at")
        }
        switch raw {
        case .int(let value):
            return value > 10_000_000_000 ? value : value * 1000
        case .double(let value):
            guard value.isFinite else {
                throw OpenClawCoreError.unavailable("github-copilot token exchange response has invalid expires_at")
            }
            let integer = Int(value.rounded())
            return integer > 10_000_000_000 ? integer : integer * 1000
        case .string(let value):
            guard let integer = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw OpenClawCoreError.unavailable("github-copilot token exchange response has invalid expires_at")
            }
            return integer > 10_000_000_000 ? integer : integer * 1000
        }
    }

    private static func deriveCopilotBaseURL(from token: String) -> String? {
        let pattern = "(?:^|;)\\s*proxy-ep=([^;\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: token.utf16.count)
        guard let match = regex.firstMatch(in: token, options: [], range: range),
              let hostRange = Range(match.range(at: 1), in: token)
        else {
            return nil
        }
        let proxyEndpoint = token[hostRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: #"^proxy\."#, with: "api.", options: .regularExpression)
        guard !proxyEndpoint.isEmpty else {
            return nil
        }
        return "https://\(proxyEndpoint)"
    }
}

private struct QwenRefreshTokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct GitHubCopilotTokenResponse: Decodable {
    let token: String?
    let expiresAt: JSONScalar?

    private enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

private enum JSONScalar: Decodable {
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
}
