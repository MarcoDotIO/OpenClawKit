import Foundation
import OpenClawCore
import OpenClawProtocol

extension NormalizedModelCatalogRow {
    /// Builds the gateway `ModelChoice` shape for a model picker, including context-window options and the
    /// catalog-driven thinking levels and default.
    /// - Parameters:
    ///   - thinkingProfile: Thinking profile for the row (see
    ///     ``OpenClawReferenceProviderCatalog/thinkingProfile(providerID:modelID:agentRuntime:)``).
    ///   - local: Whether the model runs locally.
    /// - Returns: A protocol `ModelChoice`.
    public func modelChoice(thinkingProfile: ModelThinkingProfile? = nil, local: Bool? = nil) -> ModelChoice {
        let contextWindows = self.model.contextWindows?.map { option -> [String: AnyCodable] in
            [
                "id": AnyCodable(option.id),
                "label": AnyCodable(option.label),
                "contextWindow": AnyCodable(option.contextWindow),
            ]
        }
        let thinkingLevels = thinkingProfile.map { profile in
            profile.levels.map { level -> [String: AnyCodable] in
                ["id": AnyCodable(level.rawValue), "label": AnyCodable(level.rawValue)]
            }
        }
        return ModelChoice(
            id: self.id,
            name: self.name,
            provider: self.provider,
            tags: self.model.tags,
            contextwindow: self.model.contextWindow,
            contexttokens: self.model.contextTokens,
            local: local,
            contextwindows: contextWindows,
            contextwindowdefault: self.model.contextWindowDefault,
            reasoning: self.reasoning,
            thinkinglevels: thinkingLevels,
            thinkingdefault: thinkingProfile?.defaultLevel?.rawValue,
            supportstools: self.model.compat?.supportsTools,
            input: self.input.map { AnyCodable($0.rawValue) }
        )
    }
}

extension OpenClawReferenceProviderCatalog {
    /// Picker-ready `ModelChoice` rows for one provider: selectable rows (disabled and suppressed hidden, deprecated
    /// last) with thinking levels resolved from the catalog.
    /// - Parameters:
    ///   - providerID: Provider id or alias.
    ///   - agentRuntime: Agent runtime id passed to the thinking profile resolver.
    ///   - baseURL: Configured base URL used for route-scoped suppressions.
    /// - Returns: Model choices in picker order.
    public static func modelChoices(
        providerID: String,
        agentRuntime: String? = nil,
        baseURL: String? = nil
    ) -> [ModelChoice] {
        let local = self.entry(for: providerID).map { $0.authMethods.contains("local") && $0.authEnvVars.isEmpty }
        return self.selectableModels(providerID: providerID, baseURL: baseURL).map { row in
            row.modelChoice(
                thinkingProfile: self.thinkingProfile(providerID: row.provider, modelID: row.id, agentRuntime: agentRuntime),
                local: local == true ? true : nil
            )
        }
    }
}
