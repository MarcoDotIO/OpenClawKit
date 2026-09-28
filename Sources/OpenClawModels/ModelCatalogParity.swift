import Foundation
import OpenClawCore

/// Helpers that keep built-in model catalogs aligned with upstream OpenClaw quirks.
///
/// Suppression is data-driven from upstream `modelCatalog.suppressions` (see
/// ``OpenClawReferenceProviderCatalog/suppression(providerID:modelID:baseURL:api:)``). Legacy `openai-codex` provider
/// ids are treated as the `openai` ChatGPT/Codex OAuth route (`chatgpt.com`).
public enum OpenClawModelCatalogParity {
    /// Spark model ID that is only available on the ChatGPT/Codex OAuth route.
    public static let openAIDirectSparkModelID = "gpt-5.3-codex-spark"

    /// Template rows used to synthesize the Spark row on the ChatGPT route (upstream `openai-chatgpt-provider.ts`).
    public static let codexSparkTemplateModelIDs = [
        "gpt-5.3-codex",
        "gpt-5.4",
    ]

    private static let codexSparkContextWindow = 128_000
    private static let codexSparkMaxTokens = 128_000
    private static let chatGPTHost = "chatgpt.com"

    /// Returns whether a built-in model should be hidden for a provider route.
    /// - Parameters:
    ///   - providerID: Provider id or alias (`openai-codex` selects the ChatGPT route).
    ///   - modelID: Model id.
    ///   - baseURL: Configured base URL, when known.
    ///   - api: Configured provider API, when known.
    public static func shouldSuppressBuiltInModel(
        providerID: String,
        modelID: String,
        baseURL: String? = nil,
        api: ModelAPI? = nil
    ) -> Bool {
        self.suppressionRule(providerID: providerID, modelID: modelID, baseURL: baseURL, api: api) != nil
    }

    /// Returns the user-facing error message for a suppressed built-in model selection.
    /// - Parameters:
    ///   - providerID: Provider id or alias.
    ///   - modelID: Model id.
    ///   - baseURL: Configured base URL, when known.
    ///   - api: Configured provider API, when known.
    /// - Returns: `Unknown model: <provider>/<model>. <reason>`, or `nil` when the model is visible.
    public static func suppressedBuiltInModelError(
        providerID: String,
        modelID: String,
        baseURL: String? = nil,
        api: ModelAPI? = nil
    ) -> String? {
        guard let rule = self.suppressionRule(providerID: providerID, modelID: modelID, baseURL: baseURL, api: api) else {
            return nil
        }
        let provider = self.normalizedID(providerID)
        return rule.errorMessage(provider: provider, model: self.normalizedID(modelID))
    }

    /// Normalizes the built-in model list for provider-specific parity quirks.
    ///
    /// Suppressed rows are removed, legacy ids are normalized (for example `gpt-5.4-codex` → `gpt-5.4`), duplicates
    /// are dropped, and on the ChatGPT route a `gpt-5.3-codex-spark` row is synthesized from a template row.
    /// - Parameters:
    ///   - providerID: Provider id or alias.
    ///   - models: Candidate rows.
    ///   - baseURL: Configured base URL, when known.
    ///   - api: Configured provider API, when known.
    /// - Returns: Normalized rows.
    public static func normalizeBuiltInModels(
        providerID: String,
        models: [ModelDefinitionConfig],
        baseURL: String? = nil,
        api: ModelAPI? = nil
    ) -> [ModelDefinitionConfig] {
        let route = self.route(providerID: providerID, baseURL: baseURL, api: api)
        var normalizedModels: [ModelDefinitionConfig] = []
        var seenModelIDs: Set<String> = []

        for model in models {
            var row = model
            let normalizedID = OpenClawReferenceProviderCatalog.normalizeModelID(model.id, providerID: route.providerID)
            if normalizedID != model.id {
                row.id = normalizedID
                if row.name == model.id {
                    row.name = normalizedID
                }
            }
            if self.shouldSuppressBuiltInModel(providerID: providerID, modelID: row.id, baseURL: baseURL, api: api) {
                continue
            }
            if seenModelIDs.insert(self.normalizedID(row.id)).inserted {
                normalizedModels.append(row)
            }
        }

        guard route.isChatGPTRoute else {
            return normalizedModels
        }
        guard seenModelIDs.contains(self.openAIDirectSparkModelID) == false else {
            return normalizedModels
        }
        guard let template = normalizedModels.first(where: {
            self.codexSparkTemplateModelIDs.contains(self.normalizedID($0.id))
        }) else {
            return normalizedModels
        }

        var syntheticSpark = template
        syntheticSpark.id = self.openAIDirectSparkModelID
        syntheticSpark.name = self.openAIDirectSparkModelID
        syntheticSpark.api = .openAIChatGPTResponses
        syntheticSpark.reasoning = true
        syntheticSpark.input = [.text]
        syntheticSpark.contextWindow = self.codexSparkContextWindow
        syntheticSpark.maxTokens = self.codexSparkMaxTokens
        normalizedModels.append(syntheticSpark)
        return normalizedModels
    }

    private struct Route {
        let providerID: String
        let baseURL: String?
        let api: ModelAPI?
        let isChatGPTRoute: Bool
    }

    private static func route(providerID: String, baseURL: String?, api: ModelAPI?) -> Route {
        let alias = OpenClawReferenceProviderCatalog.alias(for: providerID)
        let canonical = OpenClawReferenceProviderCatalog.normalize(providerID: providerID)
        let effectiveAPI = api ?? alias?.api
        var effectiveBaseURL = self.nonEmpty(baseURL) ?? alias?.baseURL
        if effectiveBaseURL == nil, canonical == "openai", effectiveAPI == .openAIChatGPTResponses {
            effectiveBaseURL = OpenClawReferenceProviderCatalog.openAIChatGPTBaseURL
        }
        let host = effectiveBaseURL.flatMap { URL(string: $0)?.host?.lowercased() }
        let isChatGPT = canonical == "openai" && (effectiveAPI == .openAIChatGPTResponses || host == self.chatGPTHost)
        return Route(providerID: canonical, baseURL: effectiveBaseURL, api: effectiveAPI, isChatGPTRoute: isChatGPT)
    }

    private static func suppressionRule(
        providerID: String,
        modelID: String,
        baseURL: String?,
        api: ModelAPI?
    ) -> ModelCatalogSuppression? {
        let route = self.route(providerID: providerID, baseURL: baseURL, api: api)
        return OpenClawReferenceProviderCatalog.suppression(
            providerID: providerID,
            modelID: modelID,
            baseURL: route.baseURL,
            api: route.api
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
