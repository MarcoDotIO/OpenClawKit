import OpenClawCore

/// Helpers that keep built-in model catalogs aligned with upstream OpenClaw quirks.
public enum OpenClawModelCatalogParity {
    /// Spark model ID that is suppressed on direct OpenAI provider surfaces.
    public static let openAIDirectSparkModelID = "gpt-5.3-codex-spark"

    private static let suppressedSparkProviderIDs: Set<String> = [
        "openai",
        "azure-openai-responses",
    ]

    private static let codexSparkTemplateModelIDs = [
        "gpt-5.3-codex",
        "gpt-5.2-codex",
    ]

    private static let codexSparkContextWindow = 128_000
    private static let codexSparkMaxTokens = 128_000

    /// Returns whether a built-in model should be hidden for a provider.
    public static func shouldSuppressBuiltInModel(
        providerID: String,
        modelID: String
    ) -> Bool {
        let normalizedProviderID = Self.normalizedProviderID(providerID)
        let normalizedModelID = Self.normalizedModelID(modelID)
        return self.suppressedSparkProviderIDs.contains(normalizedProviderID)
            && normalizedModelID == self.openAIDirectSparkModelID
    }

    /// Returns the user-facing error message for a suppressed built-in model selection.
    public static func suppressedBuiltInModelError(
        providerID: String,
        modelID: String
    ) -> String? {
        guard self.shouldSuppressBuiltInModel(providerID: providerID, modelID: modelID) else {
            return nil
        }
        let normalizedProviderID = Self.normalizedProviderID(providerID)
        return """
        Unknown model: \(normalizedProviderID)/\(self.openAIDirectSparkModelID). \
        \(self.openAIDirectSparkModelID) is only supported via openai-codex OAuth. \
        Use openai-codex/\(self.openAIDirectSparkModelID).
        """
    }

    /// Normalizes the built-in model list for provider-specific parity quirks.
    public static func normalizeBuiltInModels(
        providerID: String,
        models: [ModelDefinitionConfig]
    ) -> [ModelDefinitionConfig] {
        let normalizedProviderID = Self.normalizedProviderID(providerID)
        var normalizedModels: [ModelDefinitionConfig] = []
        var seenModelIDs: Set<String> = []

        for model in models {
            if self.shouldSuppressBuiltInModel(providerID: normalizedProviderID, modelID: model.id) {
                continue
            }
            let normalizedModelID = Self.normalizedModelID(model.id)
            if seenModelIDs.insert(normalizedModelID).inserted {
                normalizedModels.append(model)
            }
        }

        guard normalizedProviderID == "openai-codex" else {
            return normalizedModels
        }
        guard seenModelIDs.contains(self.openAIDirectSparkModelID) == false else {
            return normalizedModels
        }
        guard let template = normalizedModels.first(where: {
            self.codexSparkTemplateModelIDs.contains(Self.normalizedModelID($0.id))
        }) else {
            return normalizedModels
        }

        var syntheticSpark = template
        syntheticSpark.id = self.openAIDirectSparkModelID
        syntheticSpark.name = self.openAIDirectSparkModelID
        syntheticSpark.api = .openAICodexResponses
        syntheticSpark.reasoning = true
        syntheticSpark.input = [.text]
        syntheticSpark.contextWindow = self.codexSparkContextWindow
        syntheticSpark.maxTokens = self.codexSparkMaxTokens
        normalizedModels.append(syntheticSpark)
        return normalizedModels
    }

    private static func normalizedProviderID(_ providerID: String) -> String {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedModelID(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
