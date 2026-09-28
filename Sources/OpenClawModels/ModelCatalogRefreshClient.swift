import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Hosted pricing row in a remote catalog bundle (upstream `RemoteModelCatalogPricing`).
public struct RemoteModelCatalogPricing: Codable, Sendable, Equatable {
    /// Input rate per million tokens.
    public var input: Double
    /// Output rate per million tokens.
    public var output: Double
    /// Cache-read rate per million tokens.
    public var cacheRead: Double?
    /// Cache-write rate per million tokens.
    public var cacheWrite: Double?
    /// Optional prompt-size pricing tiers.
    public var tieredPricing: [ModelCatalogPricingTier]?

    /// Creates a pricing row.
    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil, tieredPricing: [ModelCatalogPricingTier]? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.tieredPricing = tieredPricing
    }
}

/// Hosted model-catalog bundle (upstream `RemoteModelCatalogBundle`), already validated and sanitized.
public struct RemoteModelCatalogBundle: Codable, Sendable, Equatable {
    /// Bundle schema version (always 1).
    public var schemaVersion: Int
    /// Generation time in milliseconds since the Unix epoch.
    public var generatedAt: Int64
    /// Minimum OpenClaw train the bundle applies to.
    public var minVersion: String?
    /// Upstream commit the bundle was built from.
    public var sourceCommit: String
    /// Provider catalogs keyed by provider id (transport fields stripped).
    public var providers: [String: ModelCatalogProvider]
    /// Hosted pricing keyed by `provider/model` ref.
    public var pricing: [String: RemoteModelCatalogPricing]?

    /// Creates a bundle.
    public init(
        schemaVersion: Int = 1,
        generatedAt: Int64,
        minVersion: String? = nil,
        sourceCommit: String,
        providers: [String: ModelCatalogProvider],
        pricing: [String: RemoteModelCatalogPricing]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.minVersion = minVersion
        self.sourceCommit = sourceCommit
        self.providers = providers
        self.pricing = pricing
    }

    /// Number of provider catalogs.
    public var providerCount: Int {
        self.providers.count
    }

    /// Number of model rows across providers.
    public var modelCount: Int {
        self.providers.values.reduce(0) { $0 + $1.models.count }
    }

    /// Maximum accepted clock skew for `generatedAt` in the future (upstream `REMOTE_CATALOG_MAX_FUTURE_SKEW_MS`).
    public static let maximumFutureSkew: TimeInterval = 24 * 60 * 60

    /// Parses, validates and sanitizes a bundle body (ports `validateAndSanitizeRemoteModelCatalogBundle`).
    ///
    /// Every `baseUrl` and `headers` key is stripped recursively before decoding, so remote data can never change
    /// endpoints or inject headers.
    /// - Parameters:
    ///   - data: JSON body.
    ///   - now: Current time used for the future-skew check.
    /// - Returns: The sanitized bundle.
    public static func parse(_ data: Data, now: Date = Date()) throws -> RemoteModelCatalogBundle {
        let raw = try JSONSerialization.jsonObject(with: data)
        let sanitized = Self.stripTransportOverrides(raw)
        guard JSONSerialization.isValidJSONObject(sanitized) else {
            throw OpenClawCoreError.invalidConfiguration("remote catalog must be a JSON object")
        }
        let bundle = try JSONDecoder().decode(RemoteModelCatalogBundle.self, from: JSONSerialization.data(withJSONObject: sanitized))
        try bundle.validate(now: now)
        return bundle
    }

    /// Validates the bundle invariants (schema version, plausible `generatedAt`, non-empty unique model ids).
    public func validate(now: Date = Date()) throws {
        guard self.schemaVersion == 1 else {
            throw OpenClawCoreError.invalidConfiguration("unsupported remote catalog schemaVersion \(self.schemaVersion)")
        }
        let limit = Int64((now.timeIntervalSince1970 + Self.maximumFutureSkew) * 1_000)
        guard self.generatedAt > 0, self.generatedAt <= limit else {
            throw OpenClawCoreError.invalidConfiguration("remote catalog generatedAt is implausible")
        }
        guard !self.sourceCommit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("remote catalog sourceCommit is required")
        }
        for (providerID, provider) in self.providers {
            guard !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !provider.models.isEmpty else {
                throw OpenClawCoreError.invalidConfiguration("remote catalog provider \(providerID) has no models")
            }
            var seen: Set<String> = []
            for model in provider.models where !seen.insert(model.id).inserted {
                throw OpenClawCoreError.invalidConfiguration("remote catalog provider \(providerID) repeats model id \(model.id)")
            }
            if provider.baseURL != nil || provider.headers != nil || provider.models.contains(where: { $0.baseURL != nil || $0.headers != nil }) {
                throw OpenClawCoreError.invalidConfiguration("remote catalog provider \(providerID) carries transport overrides")
            }
        }
    }

    private static func stripTransportOverrides(_ value: Any) -> Any {
        if let array = value as? [Any] {
            return array.map(self.stripTransportOverrides)
        }
        guard let object = value as? [String: Any] else { return value }
        var stripped: [String: Any] = [:]
        for (key, entry) in object where key != "baseUrl" && key != "headers" {
            stripped[key] = self.stripTransportOverrides(entry)
        }
        return stripped
    }
}

/// Settings for the optional hosted catalog refresh (`models.catalogRefresh`). Disabled by default in the SDK.
public struct ModelCatalogRefreshConfiguration: Sendable, Equatable {
    /// Upstream default hosted catalog URL.
    public static let defaultURL = "https://catalog.openclaw.ai/models/v1/catalog.json"

    /// Whether refresh is enabled. Upstream enables it by default; the SDK requires hosts to opt in.
    public var isEnabled: Bool
    /// Catalog URL (https, or http on localhost, 127.0.0.1 or [::1]).
    public var url: URL
    /// Minimum interval between network checks (upstream 6 hours).
    public var ttl: TimeInterval
    /// Request timeout (upstream 15 seconds).
    public var timeout: TimeInterval
    /// Maximum accepted body size (upstream 4 MiB).
    public var maximumBodyBytes: Int
    /// OpenClaw train compared against a bundle's `minVersion`.
    public var clientVersion: String

    /// Creates a configuration.
    /// - Parameters:
    ///   - isEnabled: Whether refresh is enabled (default `false`).
    ///   - url: Optional catalog URL; defaults to ``defaultURL``.
    ///   - ttl: Minimum interval between network checks.
    ///   - timeout: Request timeout.
    ///   - maximumBodyBytes: Maximum accepted body size.
    ///   - clientVersion: Train compared against `minVersion`; defaults to the catalog reference version.
    /// - Throws: `OpenClawCoreError.invalidConfiguration` for non-https URLs other than loopback http.
    public init(
        isEnabled: Bool = false,
        url: String? = nil,
        ttl: TimeInterval = 6 * 60 * 60,
        timeout: TimeInterval = 15,
        maximumBodyBytes: Int = 4 * 1_024 * 1_024,
        clientVersion: String = OpenClawReferenceProviderCatalog.referenceVersion
    ) throws {
        let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? Self.defaultURL
        guard let parsed = URL(string: raw), Self.isAllowedURL(parsed) else {
            throw OpenClawCoreError.invalidConfiguration("models.catalogRefresh.url must be https (http only on localhost): \(raw)")
        }
        self.isEnabled = isEnabled
        self.url = parsed
        self.ttl = ttl
        self.timeout = timeout
        self.maximumBodyBytes = maximumBodyBytes
        self.clientVersion = clientVersion
    }

    /// Returns whether a catalog URL is allowed: https, or http on a loopback host.
    public static func isAllowedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" {
            return true
        }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

/// Persisted state of the last catalog refresh.
public struct ModelCatalogRefreshRecord: Codable, Sendable, Equatable {
    /// Sanitized bundle.
    public var bundle: RemoteModelCatalogBundle
    /// URL the bundle was fetched from.
    public var sourceURL: String
    /// Entity tag returned by the server.
    public var etag: String?
    /// `Last-Modified` value returned by the server.
    public var lastModified: String?
    /// Last check time in milliseconds since the Unix epoch.
    public var checkedAt: Int64

    /// Creates a record.
    public init(bundle: RemoteModelCatalogBundle, sourceURL: String, etag: String? = nil, lastModified: String? = nil, checkedAt: Int64) {
        self.bundle = bundle
        self.sourceURL = sourceURL
        self.etag = etag
        self.lastModified = lastModified
        self.checkedAt = checkedAt
    }
}

/// Pluggable persistence for ``ModelCatalogRefreshClient``.
public struct ModelCatalogRefreshPersistence: Sendable {
    /// Loads the stored record.
    public var load: @Sendable () async -> ModelCatalogRefreshRecord?
    /// Stores a record.
    public var save: @Sendable (ModelCatalogRefreshRecord) async -> Void

    /// Creates persistence from closures.
    public init(
        load: @escaping @Sendable () async -> ModelCatalogRefreshRecord?,
        save: @escaping @Sendable (ModelCatalogRefreshRecord) async -> Void
    ) {
        self.load = load
        self.save = save
    }

    /// In-memory persistence (the default); state is lost when the process exits.
    public static func inMemory() -> ModelCatalogRefreshPersistence {
        let box = RecordBox()
        return ModelCatalogRefreshPersistence(load: { await box.value }, save: { await box.set($0) })
    }

    /// JSON file persistence, for example in the app's Application Support directory.
    /// - Parameter fileURL: File that stores the record.
    public static func file(at fileURL: URL) -> ModelCatalogRefreshPersistence {
        ModelCatalogRefreshPersistence(
            load: {
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return try? JSONDecoder().decode(ModelCatalogRefreshRecord.self, from: data)
            },
            save: { record in
                guard let data = try? JSONEncoder().encode(record) else { return }
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        )
    }

    private actor RecordBox {
        var value: ModelCatalogRefreshRecord?

        func set(_ record: ModelCatalogRefreshRecord) {
            self.value = record
        }
    }
}

/// Outcome of one refresh attempt (upstream `RemoteModelCatalogRefreshResult`).
public enum ModelCatalogRefreshStatus: Sendable, Equatable {
    /// A new bundle was downloaded and stored.
    case updated
    /// The server reported no change (HTTP 304 or identical body).
    case unchanged
    /// The stored bundle is younger than the TTL; no request was made.
    case fresh(nextCheckIn: TimeInterval)
    /// Refresh is disabled.
    case disabled
    /// The refresh failed; the stored bundle (if any) is kept.
    case failed(String)
}

/// Result of one refresh attempt.
public struct ModelCatalogRefreshResult: Sendable, Equatable {
    /// Outcome.
    public var status: ModelCatalogRefreshStatus
    /// Provider count of the stored bundle.
    public var providers: Int
    /// Model count of the stored bundle.
    public var models: Int
    /// `generatedAt` of the stored bundle.
    public var generatedAt: Int64?

    /// Creates a result.
    public init(status: ModelCatalogRefreshStatus, providers: Int = 0, models: Int = 0, generatedAt: Int64? = nil) {
        self.status = status
        self.providers = providers
        self.models = models
        self.generatedAt = generatedAt
    }
}

/// Optional hosted model-catalog refresh client (ports `src/model-catalog/remote-refresh.ts` and `remote-overlay.ts`).
///
/// The SDK default is off: construct it with an enabled ``ModelCatalogRefreshConfiguration`` to opt in.
public actor ModelCatalogRefreshClient {
    private let configuration: ModelCatalogRefreshConfiguration
    private let persistence: ModelCatalogRefreshPersistence
    private let transport: any ProviderCatalogHTTPTransport
    private let now: @Sendable () -> Date

    /// Creates a refresh client.
    /// - Parameters:
    ///   - configuration: Refresh settings.
    ///   - persistence: Record storage (in memory by default).
    ///   - transport: HTTP transport.
    ///   - now: Clock.
    public init(
        configuration: ModelCatalogRefreshConfiguration,
        persistence: ModelCatalogRefreshPersistence = .inMemory(),
        transport: any ProviderCatalogHTTPTransport = HTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.persistence = persistence
        self.transport = transport
        self.now = now
    }

    /// Checks the hosted catalog, honoring the TTL and conditional request headers.
    /// - Parameter force: Ignore the TTL.
    /// - Returns: The refresh outcome.
    public func refresh(force: Bool = false) async -> ModelCatalogRefreshResult {
        guard self.configuration.isEnabled else {
            return ModelCatalogRefreshResult(status: .disabled)
        }
        let now = self.now()
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let sourceURL = self.configuration.url.absoluteString
        let stored = await self.persistence.load()
        let active = stored?.sourceURL == sourceURL ? stored : nil
        if !force, let active {
            let age = TimeInterval(nowMs - active.checkedAt) / 1_000
            if age < self.configuration.ttl {
                return Self.result(.fresh(nextCheckIn: max(0, self.configuration.ttl - age)), active.bundle)
            }
        }
        var request = URLRequest(url: self.configuration.url, timeoutInterval: self.configuration.timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = active?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = active?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        do {
            let response = try await self.transport.data(for: request)
            if response.statusCode == 304 {
                guard var record = active else {
                    throw OpenClawCoreError.unavailable("remote catalog returned 304 without a stored bundle")
                }
                record.checkedAt = nowMs
                record.etag = Self.header(response, "etag") ?? record.etag
                record.lastModified = Self.header(response, "last-modified") ?? record.lastModified
                await self.persistence.save(record)
                return Self.result(.unchanged, record.bundle)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw OpenClawCoreError.unavailable("remote catalog request failed: HTTP \(response.statusCode)")
            }
            guard response.body.count <= self.configuration.maximumBodyBytes else {
                throw OpenClawCoreError.unavailable("remote catalog exceeds \(self.configuration.maximumBodyBytes) bytes")
            }
            let bundle = try RemoteModelCatalogBundle.parse(response.body, now: now)
            if let minVersion = bundle.minVersion {
                guard let comparison = Self.compareVersions(self.configuration.clientVersion, minVersion) else {
                    throw OpenClawCoreError.invalidConfiguration("invalid remote catalog minVersion: \(minVersion)")
                }
                guard comparison >= 0 else {
                    throw OpenClawCoreError.unavailable(
                        "remote catalog requires OpenClaw \(minVersion) or newer (current \(self.configuration.clientVersion))"
                    )
                }
            }
            if let active, active.bundle.generatedAt > bundle.generatedAt {
                return Self.result(.unchanged, active.bundle)
            }
            let unchanged = active?.bundle == bundle
            await self.persistence.save(
                ModelCatalogRefreshRecord(
                    bundle: bundle,
                    sourceURL: sourceURL,
                    etag: Self.header(response, "etag"),
                    lastModified: Self.header(response, "last-modified"),
                    checkedAt: nowMs
                )
            )
            return Self.result(unchanged ? .unchanged : .updated, bundle)
        } catch {
            return ModelCatalogRefreshResult(status: .failed(String(describing: error)))
        }
    }

    /// Returns the stored bundle when it may overlay the bundled catalog: refresh enabled, same source URL,
    /// newer than the bundled `generatedAt`, and `minVersion` satisfied (upstream `isCompatible`).
    /// - Parameter bundledGeneratedAt: `generatedAt` of the bundled catalog.
    public func activeOverlay(
        bundledGeneratedAt: Int64 = OpenClawReferenceProviderCatalog.referenceGeneratedAt
    ) async -> RemoteModelCatalogBundle? {
        guard self.configuration.isEnabled,
              let stored = await self.persistence.load(),
              stored.sourceURL == self.configuration.url.absoluteString,
              stored.bundle.generatedAt > bundledGeneratedAt
        else {
            return nil
        }
        if let minVersion = stored.bundle.minVersion {
            guard let comparison = Self.compareVersions(self.configuration.clientVersion, minVersion), comparison >= 0 else {
                return nil
            }
        }
        return stored.bundle
    }

    /// Returns catalog entries with the active overlay applied (rows replaced per provider; transport kept).
    public func overlaidEntries() async -> [ProviderCatalogEntry] {
        guard let overlay = await self.activeOverlay() else {
            return OpenClawReferenceProviderCatalog.entries
        }
        return OpenClawReferenceProviderCatalog.entries.map { entry in
            overlay.providers[entry.providerID].map { entry.applyingRemoteCatalog($0) } ?? entry
        }
    }

    /// Compares OpenClaw versions (`YYYY.M.D` with optional `-prerelease`); `nil` when either is invalid.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> Int? {
        guard let left = self.parseVersion(lhs), let right = self.parseVersion(rhs) else { return nil }
        for (a, b) in zip(left.parts, right.parts) where a != b {
            return a < b ? -1 : 1
        }
        switch (left.prerelease, right.prerelease) {
        case (nil, nil):
            return 0
        case (nil, _):
            return 1
        case (_, nil):
            return -1
        case let (a?, b?):
            return a == b ? 0 : (a < b ? -1 : 1)
        }
    }

    private static func parseVersion(_ raw: String) -> (parts: [Int], prerelease: String?)? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") {
            value.removeFirst()
        }
        let split = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = split[0].split(separator: ".", omittingEmptySubsequences: false)
        let numbers = components.compactMap { Int($0) }.filter { $0 >= 0 }
        guard components.count == 3, numbers.count == 3 else { return nil }
        let prerelease = split.count > 1 ? String(split[1]) : nil
        return (numbers, prerelease?.isEmpty == true ? nil : prerelease)
    }

    private static func header(_ response: HTTPResponseData, _ name: String) -> String? {
        response.headers.first { $0.key.lowercased() == name }?.value
    }

    private static func result(_ status: ModelCatalogRefreshStatus, _ bundle: RemoteModelCatalogBundle) -> ModelCatalogRefreshResult {
        ModelCatalogRefreshResult(
            status: status,
            providers: bundle.providerCount,
            models: bundle.modelCount,
            generatedAt: bundle.generatedAt
        )
    }
}

extension ProviderCatalogEntry {
    /// Returns a copy whose model rows come from a hosted catalog overlay; base URL, API, headers and auth stay local.
    /// - Parameter remote: Sanitized remote provider catalog.
    public func applyingRemoteCatalog(_ remote: ModelCatalogProvider) -> ProviderCatalogEntry {
        guard !remote.models.isEmpty else { return self }
        var copy = self
        var catalog = self.catalog
        catalog.models = remote.models
        catalog.defaultModel = remote.defaultModel.flatMap { id in remote.models.contains { $0.id == id } ? id : nil }
            ?? self.catalog.defaultModel.flatMap { id in remote.models.contains { $0.id == id } ? id : nil }
            ?? remote.models.first?.id
        catalog.defaultUtilityModel = remote.defaultUtilityModel ?? self.catalog.defaultUtilityModel
        copy.catalog = catalog
        var models = catalog.models
        if let defaultID = catalog.defaultModel, let index = models.firstIndex(where: { $0.id == defaultID }), index > 0 {
            models.insert(models.remove(at: index), at: 0)
        }
        copy.config.models = models.map { $0.definitionConfig() }
        return copy
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        self.isEmpty ? nil : self
    }
}
