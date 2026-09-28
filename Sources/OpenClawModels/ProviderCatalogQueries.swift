import Foundation
import OpenClawCore

extension OpenClawReferenceProviderCatalog {
    /// Upstream OpenClaw commit the embedded catalog document was generated from (`nil` if it failed to decode).
    public static var generatedSourceCommit: String? {
        ProviderCatalogStore.shared.sourceCommit
    }

    /// Suppression rules from every upstream manifest (`modelCatalog.suppressions`).
    public static var suppressions: [ModelCatalogSuppression] {
        ProviderCatalogStore.shared.suppressions
    }

    /// Capability-provider ids registered upstream per capability (for example `.embedding` → `openai`, `gemini`, …).
    public static var capabilityProviderIDs: [ProviderCapability: [String]] {
        ProviderCatalogStore.shared.capabilityProviderIDs
    }

    /// Text provider entries that advertise a capability.
    public static func entries(withCapability capability: ProviderCapability) -> [ProviderCatalogEntry] {
        self.entries.filter { $0.capabilities.contains(capability) }
    }

    /// Metadata-only entries that advertise a capability.
    public static func metadataEntries(withCapability capability: ProviderCapability) -> [ProviderPluginMetadataEntry] {
        self.providerMetadataEntries.filter { $0.capabilities.contains(capability) }
    }

    /// Returns the manifest row for a provider/model pair (aliases and model-id normalization applied).
    public static func catalogModel(providerID: String, modelID: String) -> ModelCatalogModel? {
        guard let entry = self.entry(for: providerID) else { return nil }
        if let row = entry.catalog.model(id: modelID) {
            return row
        }
        return entry.catalog.model(id: self.normalizeModelID(modelID, providerID: entry.providerID))
    }

    /// Normalized rows for one provider (sorted by model id, provider api/baseUrl/headers applied).
    public static func normalizedRows(providerID: String) -> [NormalizedModelCatalogRow] {
        guard let entry = self.entry(for: providerID) else { return [] }
        return entry.catalog.normalizedRows(provider: entry.providerID)
    }

    /// Rows a model picker should offer: disabled and suppressed rows are hidden and deprecated rows sort last.
    /// - Parameters:
    ///   - providerID: Provider id or alias.
    ///   - baseURL: Configured base URL, used to evaluate route-scoped suppressions.
    ///   - api: Configured provider API, used to evaluate API-scoped suppressions.
    /// - Returns: Selectable rows in catalog order (default model first).
    public static func selectableModels(
        providerID: String,
        baseURL: String? = nil,
        api: ModelAPI? = nil
    ) -> [NormalizedModelCatalogRow] {
        guard let entry = self.entry(for: providerID) else { return [] }
        let rows = entry.config.models.compactMap { definition in
            entry.catalog.model(id: definition.id).map {
                NormalizedModelCatalogRow(provider: entry.providerID, model: $0, providerCatalog: entry.catalog)
            }
        }
        let visible = rows.filter { row in
            row.status != .disabled
                && self.suppression(providerID: entry.providerID, modelID: row.id, baseURL: baseURL, api: api) == nil
        }
        return visible.enumerated()
            .sorted { lhs, rhs in
                let lhsDeprecated = lhs.element.status == .deprecated
                let rhsDeprecated = rhs.element.status == .deprecated
                return lhsDeprecated == rhsDeprecated ? lhs.offset < rhs.offset : !lhsDeprecated
            }
            .map(\.element)
    }

    /// Returns the first suppression rule that hides a model on a route (ports upstream
    /// `buildManifestBuiltInModelSuppressionResolver`, without physical-endpoint retirement transfer).
    /// - Parameters:
    ///   - providerID: Provider id (aliases such as `azure-openai-responses` are matched as written first).
    ///   - modelID: Model id.
    ///   - baseURL: Route base URL, when known.
    ///   - api: Provider config API, when known.
    /// - Returns: The matching rule, or `nil` when the model is visible.
    public static func suppression(
        providerID: String,
        modelID: String,
        baseURL: String? = nil,
        api: ModelAPI? = nil
    ) -> ModelCatalogSuppression? {
        let written = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let canonical = self.normalize(providerID: written)
        let rules = ProviderCatalogStore.shared.suppressions
        if written != canonical, let match = rules.first(where: { $0.matches(provider: written, model: modelID, baseURL: baseURL, api: api) }) {
            return match
        }
        return rules.first { $0.matches(provider: canonical, model: modelID, baseURL: baseURL, api: api) }
    }

    /// User-facing error for a suppressed model selection, or `nil` when the model is visible.
    public static func suppressionErrorMessage(
        providerID: String,
        modelID: String,
        baseURL: String? = nil,
        api: ModelAPI? = nil
    ) -> String? {
        guard let rule = self.suppression(providerID: providerID, modelID: modelID, baseURL: baseURL, api: api) else {
            return nil
        }
        return rule.errorMessage(provider: providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), model: modelID)
    }

    /// Follows `replacedBy` links (catalog rows, then retirement suppressions) to the newest successor.
    /// - Parameters:
    ///   - providerID: Provider id or alias.
    ///   - modelID: Model id.
    ///   - baseURL: Route base URL used to evaluate retirement suppressions.
    /// - Returns: The final successor id, or `nil` when the model has no successor.
    public static func successor(providerID: String, modelID: String, baseURL: String? = nil) -> String? {
        let provider = self.normalize(providerID: providerID)
        var current = modelID
        var visited: Set<String> = [modelID.lowercased()]
        var result: String?
        while true {
            let next = self.catalogModel(providerID: provider, modelID: current)?.replacedBy
                ?? self.suppression(providerID: provider, modelID: current, baseURL: baseURL)?.retirement?.replacedBy
            guard let next, visited.insert(next.lowercased()).inserted else { break }
            result = next
            current = next
        }
        return result
    }

    /// Resolves a provider credential from environment variables (opt-in; for macOS and Linux CLI hosts).
    ///
    /// Checks the entry's ``ProviderCatalogEntry/authEnvVars`` in order (auth aliases share their target's
    /// variables), then metadata entries. Empty values are ignored.
    /// - Parameters:
    ///   - providerID: Provider id or alias.
    ///   - environment: Environment to read, for example `ProcessInfo.processInfo.environment`.
    /// - Returns: The first non-empty value, or `nil`.
    public static func resolveAPIKey(providerID: String, environment: [String: String]) -> String? {
        let variables: [String]
        if let entry = self.entry(for: providerID) {
            var names = entry.authEnvVars
            let authProvider = self.authProviderID(for: providerID)
            if authProvider != entry.providerID, let target = self.entry(for: authProvider) {
                names += target.authEnvVars
            }
            variables = names
        } else if let metadata = self.metadataEntry(for: providerID) {
            variables = metadata.authEnvVars
        } else {
            return nil
        }
        for name in variables {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
