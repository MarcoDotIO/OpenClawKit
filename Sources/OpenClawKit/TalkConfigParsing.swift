import Foundation

/// Resolved talk-provider config selection extracted from a talk payload.
public struct TalkProviderConfigSelection: Sendable {
    /// Canonical provider identifier selected for talk mode.
    public let provider: String
    /// Provider-specific talk configuration payload.
    public let config: [String: AnyCodable]
    /// Indicates whether the payload came from the normalized resolved-provider shape.
    public let normalizedPayload: Bool

    /// Creates a talk-provider config selection.
    public init(provider: String, config: [String: AnyCodable], normalizedPayload: Bool) {
        self.provider = provider
        self.config = config
        self.normalizedPayload = normalizedPayload
    }
}

/// Helpers that normalize and read provider-specific talk configuration.
public enum TalkConfigParsing {
    /// Converts a Foundation dictionary into the SDK's `AnyCodable` representation.
    public static func bridgeFoundationDictionary(_ raw: [String: Any]?) -> [String: AnyCodable]? {
        raw?.reduce(into: [String: AnyCodable]()) { acc, entry in
            acc[entry.key] = AnyCodable.fromFoundation(entry.value) ?? AnyCodable(String(describing: entry.value))
        }
    }

    /// Selects the active talk provider config from a normalized or legacy talk payload.
    public static func selectProviderConfig(
        _ talk: [String: AnyCodable]?,
        defaultProvider: String,
        allowLegacyFallback: Bool = true,
    ) -> TalkProviderConfigSelection? {
        guard let talk else { return nil }
        if let resolvedSelection = self.resolvedProviderConfig(talk) {
            return resolvedSelection
        }
        let hasNormalizedPayload = talk["provider"] != nil || talk["providers"] != nil
        if hasNormalizedPayload {
            return nil
        }
        guard allowLegacyFallback else { return nil }
        return TalkProviderConfigSelection(
            provider: defaultProvider,
            config: talk,
            normalizedPayload: false)
    }

    /// Reads a positive integer from `AnyCodable`, falling back when the value is missing or invalid.
    public static func resolvedPositiveInt(_ value: AnyCodable?, fallback: Int) -> Int {
        if let timeout = value?.intValue, timeout > 0 {
            return timeout
        }
        if
            let timeout = value?.doubleValue,
            timeout > 0,
            timeout.rounded(.towardZero) == timeout,
            timeout <= Double(Int.max)
        {
            return Int(timeout)
        }
        return fallback
    }

    /// Resolves the silence timeout from a talk payload.
    public static func resolvedSilenceTimeoutMs(_ talk: [String: AnyCodable]?, fallback: Int) -> Int {
        self.resolvedPositiveInt(talk?["silenceTimeoutMs"], fallback: fallback)
    }

    private static func normalizedTalkProviderID(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolvedProviderConfig(
        _ talk: [String: AnyCodable]
    ) -> TalkProviderConfigSelection? {
        guard
            let resolved = talk["resolved"]?.dictionaryValue,
            let providerID = self.normalizedTalkProviderID(resolved["provider"]?.stringValue)
        else { return nil }
        return TalkProviderConfigSelection(
            provider: providerID,
            config: resolved["config"]?.dictionaryValue ?? [:],
            normalizedPayload: true)
    }
}
