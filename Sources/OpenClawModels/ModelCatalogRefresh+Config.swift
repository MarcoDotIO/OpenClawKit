import Foundation
import OpenClawCore
import OpenClawProtocol

public extension ModelCatalogRefreshConfiguration {
    /// Builds refresh settings from the config's `models.catalogRefresh` value (`enabled`, `url`).
    ///
    /// The SDK keeps refresh opt-in: an unset `enabled` stays disabled.
    /// - Parameter config: Config value.
    /// - Throws: `OpenClawCoreError.invalidConfiguration` for URLs that are neither https nor loopback http.
    init(config: ModelCatalogRefreshConfig) throws {
        try self.init(isEnabled: config.enabled ?? false, url: config.url)
    }

    /// Builds refresh settings from a config document's `models.catalogRefresh`.
    /// - Parameter document: Config document.
    /// - Returns: The settings, or `nil` when the document does not configure catalog refresh.
    /// - Throws: `DecodingError` for a malformed section, or `OpenClawCoreError.invalidConfiguration`
    ///   for a disallowed URL.
    static func resolve(from document: OpenClawConfigDocument) throws -> ModelCatalogRefreshConfiguration? {
        guard let raw = document.models?.catalogRefresh else { return nil }
        let data = try JSONEncoder().encode(raw)
        guard let config = try JSONDecoder().decode(ModelCatalogRefreshConfig?.self, from: data) else { return nil }
        return try ModelCatalogRefreshConfiguration(config: config)
    }
}
