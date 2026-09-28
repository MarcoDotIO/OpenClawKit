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
    ///
    /// The gateway's canonical `talk.resolved` block wins. A normalized payload
    /// (`provider`/`providers`) without `resolved` is rejected so clients never guess a provider
    /// the gateway did not resolve; legacy flat payloads map onto `defaultProvider`.
    public static func selectProviderConfig(
        _ talk: [String: AnyCodable]?,
        defaultProvider: String,
        allowLegacyFallback: Bool = true
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

    /// Returns the first non-empty (trimmed) string value among `keys`.
    /// - Parameters:
    ///   - config: Config object to read.
    ///   - keys: Keys in priority order.
    public static func firstNonEmptyString(
        _ config: [String: AnyCodable]?,
        keys: [String]) -> String?
    {
        guard let config else { return nil }
        for key in keys {
            let value = config[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if value?.isEmpty == false { return value }
        }
        return nil
    }

    static func singleRealtimeProviderID(_ providers: [String: AnyCodable]?) -> String? {
        guard let providers, providers.count == 1 else { return nil }
        let provider = providers.keys.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return provider?.isEmpty == false ? provider : nil
    }

    static func realtimeProviderConfig(
        providers: [String: AnyCodable]?,
        provider: String?) -> [String: AnyCodable]?
    {
        guard let providers else { return nil }
        if let provider {
            if let exact = providers[provider]?.dictionaryValue {
                return exact
            }
            return providers.first { key, _ in
                key.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(provider) == .orderedSame
            }?.value.dictionaryValue
        }
        if providers.count == 1 {
            return providers.values.first?.dictionaryValue
        }
        return nil
    }

    /// Reads a positive integer from `AnyCodable`, falling back when the value is missing or invalid.
    ///
    /// Integral doubles (for example `1500.0`) are accepted; fractional values, booleans, and
    /// strings fall back.
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

    /// Normalizes a speech locale identifier: trims whitespace and uses BCP-47 dashes (`ru_RU` → `ru-RU`).
    /// - Parameter value: Raw locale identifier.
    /// - Returns: The normalized identifier, or `nil` when empty.
    public static func normalizedSpeechLocaleID(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.replacingOccurrences(of: "_", with: "-")
    }

    static func resolvedSpeechLocaleID(
        _ talk: [String: AnyCodable]?,
        fallback: String? = nil) -> String?
    {
        self.normalizedSpeechLocaleID(talk?["speechLocale"]?.stringValue)
            ?? self.normalizedSpeechLocaleID(fallback)
    }

    /// Normalizes an explicitly configured speech locale, treating `automaticID` as "not set".
    /// - Parameters:
    ///   - value: Raw locale identifier.
    ///   - automaticID: Sentinel that selects automatic locale detection.
    public static func normalizedExplicitSpeechLocaleID(
        _ value: String?,
        automaticID: String = "auto") -> String?
    {
        let normalized = self.normalizedSpeechLocaleID(value)
        return normalized == automaticID ? nil : normalized
    }

    /// Picks the first preferred locale the recognizer supports, then `fallbackLocaleID`.
    /// - Parameters:
    ///   - preferredLocaleIDs: Candidates in priority order (configured, app, system).
    ///   - fallbackLocaleID: Final candidate.
    ///   - supportedLocaleIDs: Recognizer-supported identifiers; empty accepts any candidate.
    /// - Returns: The chosen normalized identifier, or `nil` when nothing is supported.
    public static func resolvedSpeechRecognitionLocaleID(
        preferredLocaleIDs: [String?],
        fallbackLocaleID: String = "en-US",
        supportedLocaleIDs: Set<String>) -> String?
    {
        let supported = Set(supportedLocaleIDs.compactMap(self.normalizedSpeechLocaleID))
        var seen = Set<String>()
        let candidates = (preferredLocaleIDs + [fallbackLocaleID])
            .compactMap(self.normalizedSpeechLocaleID)

        for candidate in candidates {
            guard seen.insert(candidate).inserted else { continue }
            if supported.isEmpty || supported.contains(candidate) {
                return candidate
            }
        }
        return nil
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
