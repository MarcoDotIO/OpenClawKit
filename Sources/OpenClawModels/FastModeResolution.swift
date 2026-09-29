import Foundation
import OpenClawCore
import OpenClawProtocol

/// Fast-mode state resolution shared by the HTTP providers (upstream `src/agents/fast-mode.ts`,
/// `src/shared/fast-mode.ts`).
///
/// Order: request policy (session/agent, merged by the runtime) → model params `fastMode` /
/// `fast_mode` → provider-configured flag → off. `auto` is on while the elapsed time since
/// ``ModelGenerationPolicy/runStartedAt`` is at most `fastAutoOnSeconds` (model params
/// `fastAutoOnSeconds`, `fast_auto_on_seconds`, `fastSeconds` or `fast_seconds`; default 60).
enum FastModeResolution {
    /// Effective fast-mode setting, or `nil` when nothing configures it.
    static func mode(
        request: ModelGenerationRequest,
        configured: Bool?,
        model: ModelDefinitionConfig? = nil
    ) -> FastMode? {
        if let setting = request.policy.fastModeSetting {
            return setting
        }
        if let modelSetting = model?.fastModeSetting {
            return modelSetting
        }
        return configured.map(FastMode.init(enabled:))
    }

    /// Resolved on/off state, or `nil` when fast mode is not configured at all.
    static func resolve(
        request: ModelGenerationRequest,
        configured: Bool?,
        model: ModelDefinitionConfig? = nil,
        now: Date = Date()
    ) -> Bool? {
        guard let mode = self.mode(request: request, configured: configured, model: model) else {
            return nil
        }
        switch mode {
        case .off:
            return false
        case .on:
            return true
        case .auto:
            let startedAt = request.policy.runStartedAt ?? now
            let elapsed = max(0, now.timeIntervalSince(startedAt))
            return elapsed <= Double(self.autoOnSeconds(model: model))
        }
    }

    /// Seconds `auto` fast mode stays on for a model.
    static func autoOnSeconds(model: ModelDefinitionConfig?) -> Int {
        let keys = ["fastAutoOnSeconds", "fast_auto_on_seconds", "fastSeconds", "fast_seconds"]
        for key in keys {
            if let value = model?.params?[key]?.intValue, value > 0 {
                return value
            }
        }
        return FastMode.defaultAutoOnSeconds
    }
}

/// OpenAI fast mode: only `service_tier: "priority"` on verified native Responses routes
/// (upstream `src/llm/providers/openai-fast-mode.ts`). Reasoning effort comes from the thinking
/// level, not from fast mode.
enum OpenAIFastModeResolution {
    /// Whether the route may carry `service_tier` (upstream `allowsOpenAIServiceTier`).
    static func allowsServiceTier(providerID: String, api: ModelAPI?, baseURL: String) -> Bool {
        let provider = ProviderRuntimeIdentity.canonicalProviderID(providerID)
        guard provider == "openai" else { return false }
        let endpoint = ModelProviderEndpointClass.resolve(baseURL: baseURL)
        switch api {
        case .openAIResponses?:
            return endpoint == .openAIPublic || endpoint == .openAIChatGPT
        case .openAIChatGPTResponses?:
            return endpoint == .openAIChatGPT
        default:
            return false
        }
    }

    /// `service_tier` for a request: explicit policy tier, else `priority` when fast mode is on and
    /// the route allows service tiers.
    static func serviceTier(
        providerID: String,
        api: ModelAPI?,
        baseURL: String,
        request: ModelGenerationRequest,
        fastEnabled: Bool?
    ) -> String? {
        if let explicit = request.policy.serviceTier {
            return explicit == .standard ? ModelServiceTier.default.rawValue : explicit.rawValue
        }
        guard fastEnabled == true, self.allowsServiceTier(providerID: providerID, api: api, baseURL: baseURL) else {
            return nil
        }
        return ModelServiceTier.priority.rawValue
    }
}

/// Anthropic fast-mode plan (upstream `extensions/anthropic/fast-mode-policy.ts`).
enum AnthropicFastModePlan: Sendable, Equatable {
    /// Native `speed: "fast"` plus the `fast-mode-2026-02-01` beta (Opus 5 family, Opus 4.8).
    case native
    /// Legacy service tier: fast → `auto`, not fast → `standard_only`.
    case serviceTier
    /// Fast mode is not available for this route.
    case unavailable
}

/// Anthropic fast-mode resolution.
enum AnthropicFastModeResolution {
    /// Beta header enabling native fast mode.
    static let fastModeBeta = "fast-mode-2026-02-01"

    /// Resolves the plan, or `nil` when the provider/runtime is not handled by this policy.
    static func plan(
        providerID: String,
        modelID: String,
        model: ModelDefinitionConfig?,
        api: ModelAPI?,
        baseURL: String,
        usesOAuth: Bool,
        runtimeID: String? = nil
    ) -> AnthropicFastModePlan? {
        guard ProviderRuntimeIdentity.canonicalProviderID(providerID) == "anthropic" else {
            return nil
        }
        if let runtimeID = runtimeID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !runtimeID.isEmpty, runtimeID != "auto", runtimeID != "openclaw"
        {
            return nil
        }
        let explicitTier = ProviderRuntimeParams.string(model?.params, keys: ["serviceTier", "service_tier"])?.lowercased()
        if explicitTier == "auto" || explicitTier == "standard_only" || usesOAuth {
            return .unavailable
        }
        let identity = ClaudeModelIdentity(modelID: modelID, params: model?.params)
        let native = identity.supportsFastMode
        if !native, !identity.supportsPriorityTier {
            return .unavailable
        }
        guard let api else { return nil }
        let endpoint = ModelProviderEndpointClass.resolve(baseURL: baseURL)
        let directEndpoint = endpoint == .default || endpoint == .anthropicPublic
        guard api == .anthropicMessages, directEndpoint else {
            return .unavailable
        }
        return native ? .native : .serviceTier
    }

    /// Maps an explicit policy tier to Anthropic's vocabulary.
    static func explicitServiceTier(_ tier: ModelServiceTier) -> String {
        switch tier {
        case .auto, .priority:
            return "auto"
        case .standard, .default, .flex:
            return "standard_only"
        }
    }
}

/// Fast-mode model swaps for providers that expose separate fast model ids.
enum FastModeModelSwap {
    private static let xaiFastModels: [String: String] = [
        "grok-3": "grok-3-fast",
        "grok-3-mini": "grok-3-mini-fast",
        "grok-4": "grok-4-fast",
        "grok-4-0709": "grok-4-fast",
    ]

    private static let minimaxFastModels: [String: String] = [
        "MiniMax-M2.7": "MiniMax-M2.7-highspeed",
    ]

    /// Fast variant of a model id (xAI on openai-completions/responses, MiniMax on anthropic-messages).
    static func fastModelID(providerID: String, modelID: String, api: ModelAPI?) -> String? {
        let provider = ProviderRuntimeIdentity.canonicalProviderID(providerID)
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == "xai", api == .openAICompletions || api == .openAIResponses {
            return self.xaiFastModels[trimmed]
        }
        if provider == "minimax" || provider == "minimax-portal", api == .anthropicMessages {
            return self.minimaxFastModels[trimmed]
        }
        return nil
    }
}

/// Public fast-mode capability queries for model pickers.
public enum ModelFastModeSupport {
    /// Authentication family used for fast-mode eligibility.
    public enum AuthMode: String, Sendable, Equatable {
        /// API-key auth.
        case apiKey
        /// OAuth/subscription auth.
        case oauth
    }

    /// Whether fast mode is available (`nil` = not determined by any provider policy).
    /// - Parameters:
    ///   - provider: Provider identifier.
    ///   - model: Model identifier.
    ///   - api: Effective transport API.
    ///   - baseURL: Effective base URL.
    ///   - authMode: Authentication family.
    public static func supportsFastMode(
        provider: String,
        model: String,
        api: ModelAPI?,
        baseURL: String?,
        authMode: AuthMode?
    ) -> Bool? {
        let canonical = ProviderRuntimeIdentity.canonicalProviderID(provider)
        if canonical == "openai" {
            let base = baseURL ?? OpenAIRouteResolution.platformBaseURL
            return OpenAIFastModeResolution.allowsServiceTier(providerID: canonical, api: api, baseURL: base)
        }
        if canonical == "anthropic" {
            guard let plan = AnthropicFastModeResolution.plan(
                providerID: canonical,
                modelID: model,
                model: nil,
                api: api,
                baseURL: baseURL ?? "",
                usesOAuth: authMode == .oauth
            ) else {
                return nil
            }
            return plan != .unavailable
        }
        if FastModeModelSwap.fastModelID(providerID: canonical, modelID: model, api: api) != nil {
            return true
        }
        return nil
    }
}
