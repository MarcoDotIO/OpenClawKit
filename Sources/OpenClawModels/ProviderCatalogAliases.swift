import Foundation
import OpenClawCore

/// Manifest-owned model-id normalization policy for one provider (upstream `ManifestModelIdNormalizationProvider`).
public struct ModelIDNormalizationRule: Codable, Sendable, Equatable {
    /// Prefix rule applied to bare ids after alias expansion.
    public struct PrefixRule: Codable, Sendable, Equatable {
        /// Model id prefix (case-insensitive) that triggers the rule.
        public var modelPrefix: String
        /// Namespace prepended to the model id.
        public var prefix: String

        /// Creates a prefix rule.
        public init(modelPrefix: String, prefix: String) {
            self.modelPrefix = modelPrefix
            self.prefix = prefix
        }
    }

    /// Model id aliases keyed by lowercased alias.
    public var aliases: [String: String]?
    /// Case-insensitive prefixes stripped before alias lookup (first match wins).
    public var stripPrefixes: [String]?
    /// Namespace prepended to bare ids (ids without `/`).
    public var prefixWhenBare: String?
    /// Conditional namespaces prepended to bare ids after alias expansion.
    public var prefixWhenBareAfterAliasStartsWith: [PrefixRule]?

    /// Creates a normalization rule.
    public init(
        aliases: [String: String]? = nil,
        stripPrefixes: [String]? = nil,
        prefixWhenBare: String? = nil,
        prefixWhenBareAfterAliasStartsWith: [PrefixRule]? = nil
    ) {
        self.aliases = aliases
        self.stripPrefixes = stripPrefixes
        self.prefixWhenBare = prefixWhenBare
        self.prefixWhenBareAfterAliasStartsWith = prefixWhenBareAfterAliasStartsWith
    }

    /// Applies the rule to a model id (ports upstream `normalizeProviderModelIdWithPolicies`).
    /// - Parameter modelID: Raw model id.
    /// - Returns: Normalized model id.
    public func apply(to modelID: String) -> String {
        var model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return model }
        for prefix in self.stripPrefixes ?? [] {
            let normalizedPrefix = prefix.lowercased()
            if !normalizedPrefix.isEmpty, model.lowercased().hasPrefix(normalizedPrefix) {
                model = String(model.dropFirst(normalizedPrefix.count))
                break
            }
        }
        model = self.aliases?[model.lowercased()] ?? model
        guard !model.contains("/") else { return model }
        for rule in self.prefixWhenBareAfterAliasStartsWith ?? [] where model.lowercased().hasPrefix(rule.modelPrefix.lowercased()) {
            return Self.join(prefix: rule.prefix, model: model)
        }
        if let prefixWhenBare {
            return Self.join(prefix: prefixWhenBare, model: model)
        }
        return model
    }

    private static func join(prefix: String, model: String) -> String {
        var trimmedPrefix = prefix
        while trimmedPrefix.hasSuffix("/") {
            trimmedPrefix.removeLast()
        }
        var trimmedModel = Substring(model)
        while trimmedModel.hasPrefix("/") {
            trimmedModel = trimmedModel.dropFirst()
        }
        return "\(trimmedPrefix)/\(trimmedModel)"
    }
}

/// Bare model-id prefix that implies a provider (upstream `modelSupport.modelPrefixes`).
public struct BareModelPrefixRule: Sendable, Equatable {
    /// Model id prefix (for example `claude-`).
    public var prefix: String
    /// Provider inferred for bare ids with the prefix.
    public var providerID: String

    /// Creates a prefix rule.
    public init(prefix: String, providerID: String) {
        self.prefix = prefix
        self.providerID = providerID
    }
}

/// Result of resolving a `provider/model` reference against the catalog.
public struct ProviderModelRefResolution: Sendable, Equatable {
    /// Canonical provider id (empty when a bare model id matched no provider prefix).
    public var providerID: String
    /// Normalized provider-local model id.
    public var modelID: String
    /// Provider id as written in the input when it was an alias (for example `openai-codex`).
    public var aliasProviderID: String?
    /// API selected by the alias (for example `openai-chatgpt-responses` for legacy Codex refs).
    public var api: ModelAPI?
    /// Base URL selected by the alias.
    public var baseURL: String?
    /// Auth mode implied by the alias.
    public var auth: ModelProviderAuthMode?
    /// Runtime hint preserved from a legacy ref (for example `codex`).
    public var runtimeHint: String?
    /// Whether the input used a legacy provider alias.
    public var isLegacy: Bool

    /// Creates a resolution.
    public init(
        providerID: String,
        modelID: String,
        aliasProviderID: String? = nil,
        api: ModelAPI? = nil,
        baseURL: String? = nil,
        auth: ModelProviderAuthMode? = nil,
        runtimeHint: String? = nil,
        isLegacy: Bool = false
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.aliasProviderID = aliasProviderID
        self.api = api
        self.baseURL = baseURL
        self.auth = auth
        self.runtimeHint = runtimeHint
        self.isLegacy = isLegacy
    }

    /// Canonical `provider/model` reference (the bare model id when the provider is unknown).
    public var ref: String {
        self.providerID.isEmpty ? self.modelID : "\(self.providerID)/\(self.modelID)"
    }
}

extension OpenClawReferenceProviderCatalog {
    /// ChatGPT/Codex OAuth route base URL used by legacy `openai-codex/*` and `codex/*` refs.
    public static let openAIChatGPTBaseURL = "https://chatgpt.com/backend-api/codex"

    /// Provider aliases keyed by alias id (manifest `modelCatalog.aliases`, auth aliases and SDK legacy ids).
    public static var providerAliases: [String: ModelCatalogAlias] {
        ProviderCatalogStore.shared.aliases
    }

    /// Auth-only aliases: providers with their own catalog entry that share another provider's credentials
    /// (for example `byteplus-plan` → `byteplus`).
    public static var authAliases: [String: String] {
        ProviderCatalogStore.shared.authAliases
    }

    /// Model-id normalization rules keyed by canonical provider id.
    public static var modelIDNormalizationRules: [String: ModelIDNormalizationRule] {
        ProviderCatalogStore.shared.modelIDNormalization
    }

    /// Bare model-id prefixes that imply a provider (`claude-` → `anthropic`, `gpt-`/`o1`/`o3`/`o4` → `openai`).
    public static var bareModelPrefixes: [BareModelPrefixRule] {
        ProviderCatalogStore.shared.modelPrefixes
    }

    /// Returns the alias entry for a provider id, or `nil` when the id is canonical or unknown.
    public static func alias(for providerID: String) -> ModelCatalogAlias? {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ProviderCatalogStore.shared.entriesByID[normalized] == nil else { return nil }
        return ProviderCatalogStore.shared.aliases[normalized]
    }

    /// Returns the provider id whose credentials a provider uses (auth aliases, then provider aliases).
    public static func authProviderID(for providerID: String) -> String {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let target = ProviderCatalogStore.shared.authAliases[normalized] {
            return target
        }
        return normalize(providerID: normalized)
    }

    /// Normalizes a provider-local model id (manifest rules, then built-in rules; ports upstream
    /// `normalizeStaticProviderModelIdWithPolicies`).
    /// - Parameters:
    ///   - modelID: Raw model id.
    ///   - providerID: Provider id or alias.
    /// - Returns: Normalized model id.
    public static func normalizeModelID(_ modelID: String, providerID: String) -> String {
        let provider = normalize(providerID: providerID)
        var model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == "anthropic" {
            // Mirrors upstream `stripSelfProviderModelPrefix` for the Anthropic built-in rule.
            let selfPrefix = "anthropic/"
            if model.lowercased().hasPrefix(selfPrefix) {
                model = String(model.dropFirst(selfPrefix.count))
            }
        }
        if let rule = ProviderCatalogStore.shared.modelIDNormalization[provider] {
            model = rule.apply(to: model)
        }
        if ["google", "google-gemini-cli", "google-vertex"].contains(provider), model.hasPrefix("google/") {
            let inner = String(model.dropFirst("google/".count))
            if let rule = ProviderCatalogStore.shared.modelIDNormalization[provider] {
                model = "google/\(rule.apply(to: inner))"
            }
        }
        return model
    }

    /// Returns the provider implied by a bare model id prefix (`modelSupport.modelPrefixes`), if any.
    public static func inferProviderID(forBareModelID modelID: String) -> String? {
        let lowered = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ProviderCatalogStore.shared.modelPrefixes.first { lowered.hasPrefix($0.prefix.lowercased()) }?.providerID
    }

    /// Resolves a `provider/model` reference: provider aliases are canonicalized (legacy `openai-codex/<m>` and
    /// `codex/<m>` resolve to `openai/<m>` on the ChatGPT route with runtime hint `codex`), the model id is
    /// normalized, and bare ids infer their provider from model prefixes.
    /// - Parameter ref: Raw reference.
    /// - Returns: Canonical resolution.
    public static func resolveModelRef(_ ref: String) -> ProviderModelRefResolution {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/"), slash != trimmed.startIndex, trimmed.index(after: slash) != trimmed.endIndex else {
            let provider = self.inferProviderID(forBareModelID: trimmed) ?? ""
            let model = provider.isEmpty ? trimmed : self.normalizeModelID(trimmed, providerID: provider)
            return ProviderModelRefResolution(providerID: provider, modelID: model)
        }
        let rawProvider = trimmed[..<slash].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawModel = trimmed[trimmed.index(after: slash)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = self.alias(for: rawProvider)
        let provider = alias?.provider ?? self.normalize(providerID: rawProvider)
        return ProviderModelRefResolution(
            providerID: provider,
            modelID: self.normalizeModelID(rawModel, providerID: provider),
            aliasProviderID: alias == nil ? nil : rawProvider,
            api: alias?.api,
            baseURL: alias?.baseURL,
            auth: alias?.auth,
            runtimeHint: alias?.runtimeHint,
            isLegacy: alias?.legacy ?? false
        )
    }

    /// Normalizes a `provider/model` reference into its canonical provider and model ids.
    /// - Parameter ref: Raw reference (bare ids infer the provider from model prefixes; unknown bare ids return an
    ///   empty provider).
    /// - Returns: Canonical provider id and normalized model id.
    public static func normalizeModelRef(_ ref: String) -> (provider: String, model: String) {
        let resolution = self.resolveModelRef(ref)
        return (resolution.providerID, resolution.modelID)
    }

    /// Canonicalizes a model reference and reports the runtime hint carried by legacy provider ids.
    /// - Parameter ref: Raw reference such as `openai-codex/gpt-5.4`.
    /// - Returns: The canonical reference (`openai/gpt-5.4`) and the runtime hint (`codex`), when any.
    public static func canonicalizeModelRef(_ ref: String) -> (ref: String, runtimeHint: String?) {
        let resolution = self.resolveModelRef(ref)
        return (resolution.ref, resolution.runtimeHint)
    }

    /// Applies an alias route to a provider config: a legacy `openai-codex` config becomes the ChatGPT OAuth route
    /// of `openai` (api, base URL, auth), and `azure-openai-responses` selects its API.
    /// - Parameters:
    ///   - providerID: Configured provider id (possibly an alias).
    ///   - config: Configured provider config.
    /// - Returns: Canonical provider id and the adjusted config.
    public static func canonicalizeProviderConfig(
        providerID: String,
        config: ModelProviderConfig
    ) -> (providerID: String, config: ModelProviderConfig) {
        guard let alias = self.alias(for: providerID) else {
            return (self.normalize(providerID: providerID), config)
        }
        var adjusted = config
        if let api = alias.api {
            adjusted.api = api
        }
        if let baseURL = alias.baseURL {
            let current = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultBaseURL = self.entry(for: alias.provider)?.config.baseURL
            if current.isEmpty || current == defaultBaseURL || current == "https://api.openai.com/v1" {
                adjusted.baseURL = baseURL
            }
        }
        if let auth = alias.auth {
            adjusted.auth = auth
        }
        return (alias.provider, adjusted)
    }
}
