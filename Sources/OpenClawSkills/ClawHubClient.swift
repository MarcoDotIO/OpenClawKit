import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

/// HTTP transport used by ``ClawHubClient`` (inject a stub in tests).
public protocol ClawHubHTTPTransport: Sendable {
    /// Performs a request.
    /// - Parameter request: URL request.
    /// - Returns: Response data.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: ClawHubHTTPTransport {}

/// One ClawHub skill search row (upstream `ClawHubSkillSearchResult`).
///
/// Registry text is untrusted: never place it into a model prompt before the skill is installed and
/// its SKILL.md parsed locally.
public struct ClawHubSkillSearchResult: Codable, Sendable, Equatable {
    /// Relevance score (0 for trending rows).
    public let score: Double
    /// Skill slug.
    public let slug: String
    /// Registry base URL.
    public let registry: String
    /// Publisher handle.
    public let ownerHandle: String?
    /// Source-qualified reference to install (`@owner/slug` or `skills-sh:…`).
    public let installRef: String
    /// Present (`true`) when ClawHub serves the result install-only.
    public let installOnly: Bool?
    /// `not-scanned-by-clawhub` for external skills.sh rows.
    public let trustState: String?
    /// Display name.
    public let displayName: String
    /// Summary.
    public let summary: String?
    /// Registry-hosted icon URL.
    public let icon: String?
    /// Latest version.
    public let version: String?
    /// Last update time in milliseconds since the epoch.
    public let updatedAt: Int64?

    /// Creates a search row.
    /// - Parameters:
    ///   - score: Score.
    ///   - slug: Slug.
    ///   - registry: Registry.
    ///   - ownerHandle: Owner handle.
    ///   - installRef: Install reference.
    ///   - installOnly: Install-only flag.
    ///   - trustState: Trust state.
    ///   - displayName: Display name.
    ///   - summary: Summary.
    ///   - icon: Icon URL.
    ///   - version: Version.
    ///   - updatedAt: Update time.
    public init(
        score: Double,
        slug: String,
        registry: String,
        ownerHandle: String? = nil,
        installRef: String,
        installOnly: Bool? = nil,
        trustState: String? = nil,
        displayName: String,
        summary: String? = nil,
        icon: String? = nil,
        version: String? = nil,
        updatedAt: Int64? = nil
    ) {
        self.score = score
        self.slug = slug
        self.registry = registry
        self.ownerHandle = ownerHandle
        self.installRef = installRef
        self.installOnly = installOnly
        self.trustState = trustState
        self.displayName = displayName
        self.summary = summary
        self.icon = icon
        self.version = version
        self.updatedAt = updatedAt
    }
}

/// How ClawHub will deliver an install (`GET /api/v1/skills/{slug}/install`).
public enum ClawHubInstallResolution: Sendable, Equatable {
    /// Registry-hosted archive.
    case archive(version: String, downloadURL: String)
    /// Commit-pinned GitHub tree.
    case github(repo: String, path: String, commit: String, contentHash: String, sourceURL: String)
    /// Install refused (`reason`, `message`, HTTP `status`).
    case failure(reason: String, message: String, status: Int)
}

/// Errors thrown by ``ClawHubClient``.
public enum ClawHubClientError: Error, LocalizedError, Sendable, Equatable {
    /// Non-success HTTP status.
    case http(status: Int, message: String)
    /// Response body could not be decoded.
    case invalidResponse(String)

    /// Human-readable description.
    public var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            return "ClawHub request failed (\(status)): \(message)"
        case .invalidResponse(let message):
            return "ClawHub returned an invalid response: \(message)"
        }
    }
}

/// Client for the ClawHub skill registry (upstream `src/infra/clawhub-skills.ts`).
public struct ClawHubClient: Sendable {
    /// Upstream `DEFAULT_CLAWHUB_URL`.
    public static let defaultBaseURL = URL(string: "https://clawhub.ai")!
    private static let skillsShTrustState = "not-scanned-by-clawhub"
    private static let skillsShReferencePrefix = "skills-sh:"
    private static let supportedInstallKinds: Set<String> = ["clawhub", "github", "skills-sh"]

    /// Registry base URL (no trailing slash).
    public let baseURL: URL
    private let token: String?
    private let transport: any ClawHubHTTPTransport
    private let timeout: TimeInterval

    /// Creates a client.
    /// - Parameters:
    ///   - baseURL: Registry base URL.
    ///   - token: Optional bearer token.
    ///   - transport: HTTP transport (defaults to `URLSession.shared`).
    ///   - timeout: Request timeout in seconds (upstream default 30).
    public init(baseURL: URL = ClawHubClient.defaultBaseURL, token: String? = nil, transport: (any ClawHubHTTPTransport)? = nil, timeout: TimeInterval = 30) {
        var normalized = baseURL.absoluteString
        while normalized.hasSuffix("/") { normalized.removeLast() }
        self.baseURL = URL(string: normalized) ?? baseURL
        self.token = token
        self.transport = transport ?? HTTPClient()
        self.timeout = timeout
    }

    /// Searches skills: a non-empty query calls `/api/v1/search`, an empty one `/api/v1/trending`.
    /// - Parameters:
    ///   - query: Search text.
    ///   - limit: Maximum results (trending caps at 100; default 20).
    /// - Returns: Source-qualified results (rows without an installable identity are dropped).
    public func search(query: String?, limit: Int? = nil) async throws -> [ClawHubSkillSearchResult] {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let registry = self.baseURL.absoluteString
        if !trimmed.isEmpty {
            var items = [URLQueryItem(name: "q", value: trimmed)]
            if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
            let object = try await self.getJSON(path: "/api/v1/search", query: items)
            return (object["results"]?.arrayValue ?? []).compactMap { self.mapSearchRow($0.dictionaryValue ?? [:], registry: registry) }
        }
        let capped = min(limit ?? 20, 100)
        let object = try await self.getJSON(
            path: "/api/v1/trending",
            query: [URLQueryItem(name: "kind", value: "skills"), URLQueryItem(name: "limit", value: String(capped))]
        )
        return (object["items"]?.arrayValue ?? []).compactMap { item -> ClawHubSkillSearchResult? in
            guard var row = item.dictionaryValue else { return nil }
            row["score"] = AnyCodable(0)
            row["ownerHandle"] = row["publisher"]?.dictionaryValue?["handle"]
            row["updatedAt"] = row["metrics"]?.dictionaryValue?["updatedAt"]
            return self.mapSearchRow(row, registry: registry)
        }
    }

    /// Fetches skill detail (`GET /api/v1/skills/{slug}`).
    /// - Parameters:
    ///   - slug: Skill slug.
    ///   - ownerHandle: Optional publisher handle.
    /// - Returns: Detail in the upstream `SkillsDetailResult` shape.
    public func detail(slug: String, ownerHandle: String? = nil) async throws -> SkillsDetailResult {
        let items = ownerHandle.map { [URLQueryItem(name: "ownerHandle", value: $0)] } ?? []
        var object = try await self.getJSON(path: "/api/v1/skills/\(Self.encodePathComponent(slug))", query: items)
        if var skill = object["skill"]?.dictionaryValue {
            skill["icon"] = self.resolveIconURL(skill["icon"]?.stringValue).map { AnyCodable($0) } ?? AnyCodable.nullValue
            object["skill"] = AnyCodable(skill)
        }
        return SkillsDetailResult(
            skill: object["skill"] ?? AnyCodable.nullValue,
            latestversion: object["latestVersion"],
            metadata: object["metadata"],
            owner: object["owner"]
        )
    }

    /// Resolves how an install would be delivered (`GET /api/v1/skills/{slug}/install`).
    /// - Parameters:
    ///   - slug: Skill slug.
    ///   - ownerHandle: Optional publisher handle.
    ///   - requestedReference: Optional exact reference.
    /// - Returns: The resolution.
    public func resolveInstall(slug: String, ownerHandle: String? = nil, requestedReference: String? = nil) async throws -> ClawHubInstallResolution {
        var items: [URLQueryItem] = []
        if let ownerHandle { items.append(URLQueryItem(name: "ownerHandle", value: ownerHandle)) }
        if let requestedReference { items.append(URLQueryItem(name: "reference", value: requestedReference)) }
        let response = try await self.get(path: "/api/v1/skills/\(Self.encodePathComponent(slug))/install", query: items)
        guard (200..<300).contains(response.statusCode) || [403, 409, 410, 423].contains(response.statusCode) else {
            throw ClawHubClientError.http(status: response.statusCode, message: String(decoding: response.body.prefix(512), as: UTF8.self))
        }
        let object = try Self.decodeObject(response.body)
        if object["ok"]?.boolValue == false {
            return .failure(
                reason: object["reason"]?.stringValue ?? "unknown",
                message: object["message"]?.stringValue ?? "",
                status: object["status"]?.intValue ?? response.statusCode
            )
        }
        switch object["installKind"]?.stringValue {
        case "archive":
            let archive = object["archive"]?.dictionaryValue ?? [:]
            guard let version = archive["version"]?.stringValue, let url = archive["downloadUrl"]?.stringValue else {
                throw ClawHubClientError.invalidResponse("archive resolution without version/downloadUrl")
            }
            return .archive(version: version, downloadURL: url)
        case "github":
            let github = object["github"]?.dictionaryValue ?? [:]
            guard let repo = github["repo"]?.stringValue,
                  let commit = github["commit"]?.stringValue,
                  let contentHash = github["contentHash"]?.stringValue
            else {
                throw ClawHubClientError.invalidResponse("github resolution without repo/commit/contentHash")
            }
            return .github(
                repo: repo,
                path: github["path"]?.stringValue ?? "",
                commit: commit,
                contentHash: contentHash,
                sourceURL: github["sourceUrl"]?.stringValue ?? ""
            )
        default:
            throw ClawHubClientError.invalidResponse("unknown installKind")
        }
    }

    // MARK: - Mapping

    func mapSearchRow(_ row: [String: AnyCodable], registry: String) -> ClawHubSkillSearchResult? {
        guard let slug = row["slug"]?.stringValue, !slug.isEmpty,
              let displayName = row["displayName"]?.stringValue, !displayName.isEmpty
        else {
            return nil
        }
        let install = row["install"]?.dictionaryValue
        let installKind = install?["kind"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = install?["reference"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let installKind, !installKind.isEmpty, !Self.supportedInstallKinds.contains(installKind) {
            return nil
        }
        let ownerHandle = row["ownerHandle"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let score = row["score"]?.doubleValue ?? 0
        let updatedAt = row["updatedAt"]?.int64Value
        let icon = self.resolveIconURL(row["icon"]?.stringValue)
        switch row["source"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "skills-sh":
            guard let reference, reference.hasPrefix(Self.skillsShReferencePrefix) else { return nil }
            return ClawHubSkillSearchResult(
                score: score, slug: slug, registry: registry, ownerHandle: ownerHandle, installRef: reference,
                installOnly: true, trustState: Self.skillsShTrustState, displayName: displayName,
                summary: row["summary"]?.stringValue, icon: icon, version: row["version"]?.stringValue, updatedAt: updatedAt
            )
        case "clawhub":
            guard let ownerHandle, !ownerHandle.isEmpty else { return nil }
            return ClawHubSkillSearchResult(
                score: score, slug: slug, registry: registry, ownerHandle: ownerHandle, installRef: "@\(ownerHandle)/\(slug)",
                displayName: displayName, summary: row["summary"]?.stringValue, icon: icon,
                version: row["version"]?.stringValue, updatedAt: updatedAt
            )
        default:
            return nil
        }
    }

    /// Accepts only registry-hosted `/api/v1/skill-icons/<sha256>` URLs (upstream `resolveClawHubImageUrl`).
    func resolveIconURL(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let base = URL(string: self.baseURL.absoluteString + "/"),
              let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.range(of: "^/api/v1/skill-icons/[a-fA-F0-9]{64}$", options: .regularExpression) != nil
        else {
            return nil
        }
        return url.absoluteString
    }

    // MARK: - HTTP

    private func get(path: String, query: [URLQueryItem]) async throws -> HTTPResponseData {
        guard var components = URLComponents(url: self.baseURL, resolvingAgainstBaseURL: false) else {
            throw ClawHubClientError.invalidResponse("invalid base URL")
        }
        components.percentEncodedPath = (components.percentEncodedPath) + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw ClawHubClientError.invalidResponse("invalid request URL")
        }
        var request = URLRequest(url: url, timeoutInterval: self.timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await self.transport.data(for: request)
    }

    private func getJSON(path: String, query: [URLQueryItem]) async throws -> [String: AnyCodable] {
        let response = try await self.get(path: path, query: query)
        guard (200..<300).contains(response.statusCode) else {
            throw ClawHubClientError.http(status: response.statusCode, message: String(decoding: response.body.prefix(512), as: UTF8.self))
        }
        return try Self.decodeObject(response.body)
    }

    private static func decodeObject(_ data: Data) throws -> [String: AnyCodable] {
        guard let object = try? JSONDecoder().decode(AnyCodable.self, from: data).dictionaryValue else {
            throw ClawHubClientError.invalidResponse("expected a JSON object")
        }
        return object
    }

    private static func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Registers `skills.search {query?, limit?}` and `skills.detail {slug}` backed by ClawHub.
/// - Parameters:
///   - registrar: Gateway server or registrar.
///   - client: ClawHub client.
public func registerClawHubGatewayMethods(on registrar: some GatewayMethodRegistrar, client: ClawHubClient) async {
    await registrar.register(method: "skills.search") { request in
        let params = try request.decodeParams(SkillsSearchParams.self)
        if let limit = params.limit, !(1...100).contains(limit) {
            throw GatewayMethodError.invalidRequest("limit must be between 1 and 100")
        }
        let rows = try await client.search(query: params.query, limit: params.limit)
        return AnyCodable(["results": try AnyCodable(encoding: rows)])
    }
    await registrar.register(method: "skills.detail") { request in
        let params = try request.decodeParams(SkillsDetailParams.self)
        var slug = params.slug.trimmingCharacters(in: .whitespacesAndNewlines)
        var owner: String?
        if slug.hasPrefix("@"), let slash = slug.firstIndex(of: "/") {
            owner = String(slug[slug.index(after: slug.startIndex)..<slash])
            slug = String(slug[slug.index(after: slash)...])
        }
        guard !slug.isEmpty else {
            throw GatewayMethodError.invalidRequest("slug must be non-empty")
        }
        return try GatewayPayloadCodec.encode(try await client.detail(slug: slug, ownerHandle: owner))
    }
}
