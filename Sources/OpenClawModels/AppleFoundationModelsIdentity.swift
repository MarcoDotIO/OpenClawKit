import Foundation
import OpenClawCore
import OpenClawProtocol

// Provider identity, model targets and facts for Apple Foundation Models.
//
// Mirrors upstream `extensions/apple-fm` (defaults.ts, native.ts `AppleFmFacts`, setup.ts): the
// provider is `apple-fm`, the on-device model is `system` (ref `apple-fm/system`), the synthetic
// non-secret auth marker is `apple-fm-local`, and the setup/utility role needs at least 8,192
// context tokens. `apple-fm/private-cloud-compute` (alias `apple-fm/pcc`) is an SDK-only extension
// for Apple's Private Cloud Compute model on OS 27.
//
// Everything in this file is platform neutral (Linux included); runtime probing lives in the
// Apple-only FoundationModelsProvider files.

/// Apple Foundation Models backend targeted by a request.
public enum AppleFoundationModelTarget: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// On-device system language model (`apple-fm/system`).
    case system
    /// Private Cloud Compute language model (`apple-fm/private-cloud-compute`, alias `apple-fm/pcc`).
    ///
    /// SDK-only extension (upstream has no PCC route). Requires OS 27 and Apple's managed Private
    /// Cloud Compute entitlement; see <https://developer.apple.com/private-cloud-compute/>.
    case privateCloudCompute = "private-cloud-compute"

    /// Canonical model identifier (`system` or `private-cloud-compute`).
    public var modelID: String {
        self.rawValue
    }

    /// Canonical model reference (`apple-fm/system` or `apple-fm/private-cloud-compute`).
    public var modelRef: String {
        "\(FoundationModelsProvider.providerID)/\(self.rawValue)"
    }

    /// Resolves a model identifier, alias, or `provider/model` reference.
    ///
    /// Accepted spellings (case-insensitive): `system`, `default`, the legacy
    /// `apple-foundation-default`, `private-cloud-compute`, `pcc`, and any of those prefixed with
    /// `apple-fm/` or `foundation/`.
    /// - Parameter modelID: Raw model identifier or reference.
    public init?(modelID: String) {
        var normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in FoundationModelsProvider.providerIDAliases.map({ "\($0)/" }) where normalized.hasPrefix(prefix) {
            normalized = String(normalized.dropFirst(prefix.count))
            break
        }
        switch normalized {
        case FoundationModelsProvider.systemModelID, "default", FoundationModelsProvider.legacyModelID:
            self = .system
        case FoundationModelsProvider.privateCloudComputeModelID, FoundationModelsProvider.privateCloudComputeModelAlias:
            self = .privateCloudCompute
        default:
            return nil
        }
    }
}

/// Runtime facts about an Apple Foundation Models backend (upstream `AppleFmFacts` plus 27 capabilities).
///
/// Encodes the upstream keys `available`, `reason`, `modelName` and `contextWindow`, followed by
/// SDK extras (`target`, `variantID`, `supportsVision`, `supportsReasoning`, `supportsToolCalling`,
/// `supportsGuidedGeneration`). Decoding treats every extra as optional, so upstream helper output
/// decodes unchanged.
public struct AppleFoundationModelFacts: Codable, Sendable, Equatable {
    /// Backend these facts describe.
    public var target: AppleFoundationModelTarget
    /// Whether the backend can serve requests right now.
    public var available: Bool
    /// User-facing unavailability reason (`nil` when available).
    public var reason: String?
    /// Model display name, e.g. `AFM 3 Core Advanced` (the system model's variant display name on OS 27).
    public var modelName: String
    /// Context window in tokens (`0` when unavailable).
    public var contextWindow: Int
    /// On-device model variant: `core3`, `coreAdvanced3`, or `unknown` (`nil` before OS 27 or for PCC).
    public var variantID: String?
    /// The model accepts image input (OS 27 `LanguageModelCapabilities.vision`).
    public var supportsVision: Bool
    /// The model accepts a reasoning level (OS 27 `LanguageModelCapabilities.reasoning`).
    public var supportsReasoning: Bool
    /// The model can call tools.
    public var supportsToolCalling: Bool
    /// The model supports guided (schema-constrained) generation.
    public var supportsGuidedGeneration: Bool

    /// Creates facts.
    /// - Parameters:
    ///   - target: Backend described by these facts.
    ///   - available: Whether the backend can serve requests.
    ///   - reason: Unavailability reason.
    ///   - modelName: Model display name.
    ///   - contextWindow: Context window in tokens.
    ///   - variantID: On-device variant identifier.
    ///   - supportsVision: Image input support.
    ///   - supportsReasoning: Reasoning-level support.
    ///   - supportsToolCalling: Tool-calling support.
    ///   - supportsGuidedGeneration: Guided-generation support.
    public init(
        target: AppleFoundationModelTarget = .system,
        available: Bool,
        reason: String? = nil,
        modelName: String,
        contextWindow: Int,
        variantID: String? = nil,
        supportsVision: Bool = false,
        supportsReasoning: Bool = false,
        supportsToolCalling: Bool = true,
        supportsGuidedGeneration: Bool = true
    ) {
        self.target = target
        self.available = available
        self.reason = reason
        self.modelName = modelName
        self.contextWindow = Swift.max(0, contextWindow)
        self.variantID = variantID
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
        self.supportsToolCalling = supportsToolCalling
        self.supportsGuidedGeneration = supportsGuidedGeneration
    }

    /// Facts for an unavailable backend (upstream helper `info` output when unavailable).
    /// - Parameters:
    ///   - target: Backend described by these facts.
    ///   - reason: User-facing reason.
    /// - Returns: Unavailable facts with an empty context window.
    public static func unavailable(
        target: AppleFoundationModelTarget = .system,
        reason: String
    ) -> AppleFoundationModelFacts {
        AppleFoundationModelFacts(
            target: target,
            available: false,
            reason: reason,
            modelName: target == .system
                ? FoundationModelsProvider.displayName
                : FoundationModelsProvider.privateCloudComputeDisplayName,
            contextWindow: 0,
            supportsToolCalling: false,
            supportsGuidedGeneration: false
        )
    }

    /// Whether the backend qualifies for the setup/utility role (upstream `requireUsableModel`):
    /// available with at least ``FoundationModelsProvider/minimumUtilityContextWindow`` tokens.
    public var isEligibleUtilityModel: Bool {
        self.available && self.contextWindow >= FoundationModelsProvider.minimumUtilityContextWindow
    }

    /// Upstream setup error for backends that do not qualify for the utility role, else `nil`.
    public var utilityEligibilityError: String? {
        guard self.available else {
            return self.reason ?? "Apple Foundation Models is unavailable. Enable Apple Intelligence in System Settings "
                + "and wait for its model download, then retry setup."
        }
        guard self.contextWindow >= FoundationModelsProvider.minimumUtilityContextWindow else {
            return "\(self.modelName) provides \(self.contextWindow) context tokens. "
                + "OpenClaw's Apple setup option requires at least \(FoundationModelsProvider.minimumUtilityContextWindow). "
                + "Choose another local or cloud model on this device."
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case available
        case reason
        case modelName
        case contextWindow
        case target
        case variantID
        case supportsVision
        case supportsReasoning
        case supportsToolCalling
        case supportsGuidedGeneration
    }

    /// Decodes facts; SDK extras are optional so upstream helper JSON decodes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let available = try container.decode(Bool.self, forKey: .available)
        self.init(
            target: try container.decodeIfPresent(AppleFoundationModelTarget.self, forKey: .target) ?? .system,
            available: available,
            reason: try container.decodeIfPresent(String.self, forKey: .reason),
            modelName: try container.decodeIfPresent(String.self, forKey: .modelName) ?? FoundationModelsProvider.displayName,
            contextWindow: try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 0,
            variantID: try container.decodeIfPresent(String.self, forKey: .variantID),
            supportsVision: try container.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false,
            supportsReasoning: try container.decodeIfPresent(Bool.self, forKey: .supportsReasoning) ?? false,
            supportsToolCalling: try container.decodeIfPresent(Bool.self, forKey: .supportsToolCalling) ?? available,
            supportsGuidedGeneration: try container.decodeIfPresent(Bool.self, forKey: .supportsGuidedGeneration) ?? available
        )
    }

    /// Encodes facts with the upstream keys first; `reason` is omitted when `nil` (upstream shape).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.available, forKey: .available)
        try container.encodeIfPresent(self.reason, forKey: .reason)
        try container.encode(self.modelName, forKey: .modelName)
        try container.encode(self.contextWindow, forKey: .contextWindow)
        try container.encode(self.target, forKey: .target)
        try container.encodeIfPresent(self.variantID, forKey: .variantID)
        try container.encode(self.supportsVision, forKey: .supportsVision)
        try container.encode(self.supportsReasoning, forKey: .supportsReasoning)
        try container.encode(self.supportsToolCalling, forKey: .supportsToolCalling)
        try container.encode(self.supportsGuidedGeneration, forKey: .supportsGuidedGeneration)
    }
}

/// Snapshot of the Private Cloud Compute usage quota (OS 27 quota usage).
public struct FoundationModelsQuotaSnapshot: Codable, Sendable, Equatable {
    /// The per-user request budget is exhausted until ``resetDate``.
    public var limitReached: Bool
    /// The budget is close to exhausted.
    public var approachingLimit: Bool
    /// When the quota resets, when the system reports it.
    public var resetDate: Date?
    /// The system can present a limit-increase offer
    /// (see ``FoundationModelsProvider/presentPrivateCloudQuotaIncreaseSuggestion()``).
    public var canRequestIncrease: Bool

    /// Creates a quota snapshot.
    /// - Parameters:
    ///   - limitReached: Whether the limit is reached.
    ///   - approachingLimit: Whether the limit is close.
    ///   - resetDate: Quota reset date.
    ///   - canRequestIncrease: Whether a limit-increase offer is available.
    public init(limitReached: Bool, approachingLimit: Bool = false, resetDate: Date? = nil, canRequestIncrease: Bool = false) {
        self.limitReached = limitReached
        self.approachingLimit = approachingLimit
        self.resetDate = resetDate
        self.canRequestIncrease = canRequestIncrease
    }
}

// MARK: - Identity constants and config builders

public extension FoundationModelsProvider {
    /// Canonical provider identifier (upstream `APPLE_FM_PROVIDER_ID`).
    static let providerID = "apple-fm"
    /// Pre-2026.3.0 provider identifier, still accepted as an alias of ``providerID``.
    static let legacyProviderID = "foundation"
    /// Every accepted provider identifier: ``providerID``, ``legacyProviderID`` and `apple-foundation`.
    static let providerIDAliases: [String] = [providerID, legacyProviderID, "apple-foundation"]
    /// On-device model identifier (upstream `APPLE_FM_MODEL_ID`).
    static let systemModelID = "system"
    /// Default model identifier (alias of ``systemModelID``).
    static let defaultModelID = systemModelID
    /// Pre-2026.3.0 model identifier, accepted as an alias of ``systemModelID``.
    static let legacyModelID = "apple-foundation-default"
    /// Private Cloud Compute model identifier (SDK-only).
    static let privateCloudComputeModelID = "private-cloud-compute"
    /// Short alias of ``privateCloudComputeModelID``.
    static let privateCloudComputeModelAlias = "pcc"
    /// On-device model reference `apple-fm/system` (upstream `APPLE_FM_MODEL_REF`).
    static let systemModelRef = "\(providerID)/\(systemModelID)"
    /// Private Cloud Compute model reference `apple-fm/private-cloud-compute`.
    static let privateCloudComputeModelRef = "\(providerID)/\(privateCloudComputeModelID)"
    /// Synthetic non-secret auth marker (upstream `APPLE_FM_LOCAL_AUTH_MARKER`); never a credential.
    static let localAuthMarker = "apple-fm-local"
    /// Minimum context window for the setup/utility role (upstream `APPLE_FM_MIN_CONTEXT_WINDOW`).
    static let minimumUtilityContextWindow = 8_192
    /// Default maximum response tokens (upstream model `maxTokens`).
    static let defaultMaxTokens = 1_024
    /// Placeholder request timeout written to provider config (upstream `timeoutSeconds`).
    static let defaultTimeoutSeconds = 120
    /// Placeholder base URL written to provider config; native inference never sends HTTP.
    static let placeholderBaseURL = "http://127.0.0.1"
    /// Provider display name.
    static let displayName = "Apple Foundation Models"
    /// Private Cloud Compute model display name.
    static let privateCloudComputeDisplayName = "Apple Foundation Models (Private Cloud Compute)"
    /// Onboarding choice label (upstream `choiceLabel`).
    static let choiceLabel = "Apple Foundation Models (on-device)"

    /// Whether a provider identifier (or alias) routes to this provider, independent of the
    /// configured `api` (the config api is a placeholder; inference is native).
    /// - Parameter providerID: Provider identifier or alias.
    /// - Returns: `true` for `apple-fm`, `foundation` and `apple-foundation`.
    static func handles(providerID: String) -> Bool {
        self.providerIDAliases.contains(providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Whether a configured API key is the synthetic non-secret marker rather than a secret.
    /// - Parameter apiKey: Configured key.
    /// - Returns: `true` for ``localAuthMarker``.
    static func isNonSecretAuthMarker(_ apiKey: String?) -> Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) == self.localAuthMarker
    }

    /// Whether facts qualify for the setup/utility role (available and at least 8,192 context tokens).
    /// - Parameter facts: Backend facts.
    /// - Returns: Utility-role eligibility.
    static func eligibleForUtilityRole(facts: AppleFoundationModelFacts) -> Bool {
        facts.isEligibleUtilityModel
    }

    /// Throws the upstream setup error when facts do not qualify for the utility role.
    /// - Parameter facts: Backend facts.
    /// - Throws: ``OpenClawCoreError/unavailable(_:)`` with the upstream message.
    static func requireUsableUtilityModel(facts: AppleFoundationModelFacts) throws {
        if let message = facts.utilityEligibilityError {
            throw OpenClawCoreError.unavailable(message)
        }
    }

    /// Provider config matching upstream `buildAppleFmProviderConfig` for gateway-compatible config.
    ///
    /// Upstream shape: `api` `openai-completions` (placeholder), `authHeader` false, base URL
    /// `http://127.0.0.1`, one `system` model with `reasoning` false, `input` text, zero cost, the
    /// probed context window, `maxTokens` 1024, and compat `supportsTools`/`supportsDeveloperRole`
    /// false/`supportsUsageInStreaming`. Fields the Swift config types do not model yet
    /// (`timeoutSeconds`, `compat.supportsJsonSchemaResponseFormat`) are available through
    /// ``upstreamProviderConfigJSON(facts:)``.
    /// - Parameter facts: Probed system-model facts.
    /// - Returns: Provider config.
    static func buildProviderConfig(facts: AppleFoundationModelFacts) -> ModelProviderConfig {
        ModelProviderConfig(
            enabled: true,
            baseURL: self.placeholderBaseURL,
            auth: nil,
            api: .openAICompletions,
            authHeader: false,
            models: [
                ModelDefinitionConfig(
                    id: self.systemModelID,
                    name: facts.modelName,
                    reasoning: false,
                    input: [.text],
                    cost: ModelCostConfig(),
                    contextWindow: facts.contextWindow,
                    maxTokens: self.defaultMaxTokens,
                    compat: self.upstreamCompat
                ),
            ]
        )
    }

    /// Upstream-shaped provider config JSON (exactly `buildAppleFmProviderConfig(facts)`), for hosts
    /// that write `models.providers["apple-fm"]` into an upstream `openclaw.json`.
    /// - Parameter facts: Probed system-model facts.
    /// - Returns: JSON object.
    static func upstreamProviderConfigJSON(facts: AppleFoundationModelFacts) -> [String: AnyCodable] {
        let cost: [String: AnyCodable] = [
            "input": AnyCodable(0),
            "output": AnyCodable(0),
            "cacheRead": AnyCodable(0),
            "cacheWrite": AnyCodable(0),
        ]
        let compat: [String: AnyCodable] = [
            "supportsTools": AnyCodable(true),
            "supportsJsonSchemaResponseFormat": AnyCodable(true),
            "supportsDeveloperRole": AnyCodable(false),
            "supportsUsageInStreaming": AnyCodable(true),
        ]
        let model: [String: AnyCodable] = [
            "id": AnyCodable(self.systemModelID),
            "name": AnyCodable(facts.modelName),
            "reasoning": AnyCodable(false),
            "input": AnyCodable([AnyCodable("text")]),
            "cost": AnyCodable(cost),
            "contextWindow": AnyCodable(facts.contextWindow),
            "maxTokens": AnyCodable(self.defaultMaxTokens),
            "compat": AnyCodable(compat),
        ]
        return [
            "baseUrl": AnyCodable(self.placeholderBaseURL),
            "api": AnyCodable(ModelAPI.openAICompletions.rawValue),
            "authHeader": AnyCodable(false),
            "timeoutSeconds": AnyCodable(self.defaultTimeoutSeconds),
            "models": AnyCodable([AnyCodable(model)]),
        ]
    }

    /// SDK catalog model definition derived from probed facts.
    ///
    /// Unlike ``buildProviderConfig(facts:)`` (upstream parity: text only, no reasoning), this uses
    /// the OS 27 capabilities: `input` gains `image` when the model supports vision and `reasoning`
    /// follows the model's reasoning capability (a Swift-only extension; the upstream helper does not
    /// pass images). Private Cloud Compute definitions use ``privateCloudComputeModelID``.
    /// - Parameter facts: Probed facts for either target.
    /// - Returns: Model definition.
    static func modelDefinition(facts: AppleFoundationModelFacts) -> ModelDefinitionConfig {
        ModelDefinitionConfig(
            id: facts.target.modelID,
            name: facts.modelName,
            reasoning: facts.supportsReasoning,
            input: facts.supportsVision ? [.text, .image] : [.text],
            cost: ModelCostConfig(),
            contextWindow: facts.contextWindow,
            maxTokens: self.defaultMaxTokens,
            compat: ModelCompatConfig(
                supportsDeveloperRole: false,
                supportsUsageInStreaming: true,
                supportsTools: facts.supportsToolCalling
            )
        )
    }

    /// Upstream compat flags representable by ``ModelCompatConfig`` today.
    private static var upstreamCompat: ModelCompatConfig {
        ModelCompatConfig(supportsDeveloperRole: false, supportsUsageInStreaming: true, supportsTools: true)
    }
}
