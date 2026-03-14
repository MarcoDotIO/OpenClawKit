import Foundation
import OpenClawCore

enum FastModeResolution {
    static func resolve(
        request: ModelGenerationRequest,
        configured: Bool?
    ) -> Bool? {
        request.policy.fastMode ?? configured
    }
}

enum OpenAIFastModeResolution {
    static func reasoningEffort(
        request: ModelGenerationRequest,
        configuredFastMode: Bool?
    ) -> ModelReasoningEffort? {
        request.policy.reasoningEffort
            ?? (FastModeResolution.resolve(request: request, configured: configuredFastMode) == true ? .low : nil)
    }

    static func serviceTier(
        providerID: String,
        baseURL: URL,
        request: ModelGenerationRequest,
        configuredFastMode: Bool?
    ) -> String? {
        if let explicit = request.policy.serviceTier {
            return explicit.rawValue
        }
        guard FastModeResolution.resolve(request: request, configured: configuredFastMode) == true else {
            return nil
        }
        guard Self.normalizedProviderID(providerID) == "openai", Self.isOpenAIPublicAPIBaseURL(baseURL) else {
            return nil
        }
        return ModelServiceTier.priority.rawValue
    }

    static func textVerbosity(
        request: ModelGenerationRequest,
        configuredFastMode: Bool?
    ) -> String? {
        FastModeResolution.resolve(request: request, configured: configuredFastMode) == true ? "low" : nil
    }

    private static func normalizedProviderID(_ providerID: String) -> String {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isOpenAIPublicAPIBaseURL(_ baseURL: URL) -> Bool {
        baseURL.host?.lowercased() == "api.openai.com"
    }
}

enum AnthropicFastModeResolution {
    static func serviceTier(
        providerID: String,
        baseURL: URL,
        request: ModelGenerationRequest,
        configuredFastMode: Bool?,
        allowsFastModeDefaults: Bool
    ) -> String? {
        if let explicit = request.policy.serviceTier {
            return Self.mapExplicitServiceTier(explicit)
        }
        guard let fastMode = FastModeResolution.resolve(request: request, configured: configuredFastMode) else {
            return nil
        }
        guard Self.normalizedProviderID(providerID) == "anthropic",
              allowsFastModeDefaults,
              Self.isAnthropicPublicAPIBaseURL(baseURL)
        else {
            return nil
        }
        return fastMode ? "auto" : "standard_only"
    }

    private static func mapExplicitServiceTier(_ value: ModelServiceTier) -> String {
        switch value {
        case .auto, .priority:
            return "auto"
        case .standard:
            return "standard_only"
        }
    }

    private static func normalizedProviderID(_ providerID: String) -> String {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isAnthropicPublicAPIBaseURL(_ baseURL: URL) -> Bool {
        baseURL.host?.lowercased() == "api.anthropic.com"
    }
}
