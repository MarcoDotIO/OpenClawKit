import Foundation

/// Session key routing behavior controls.
public struct RoutingConfig: Codable, Sendable, Equatable {
    public var defaultSessionKey: String
    public var includeChannelID: Bool
    public var includeAccountID: Bool
    public var includePeerID: Bool
    /// Session key format used by ``SessionKeyResolver/derive(context:config:)`` (SDK-only; default
    /// ``SessionKeyFormat/legacy``; ``SessionKeyFormat/canonical`` opts into upstream `agent:<id>:…` keys).
    public var sessionKeyFormat: SessionKeyFormat

    /// Creates routing settings.
    /// - Parameters:
    ///   - defaultSessionKey: Fallback session key.
    ///   - includeChannelID: Include channel ID in derived key.
    ///   - includeAccountID: Include account ID in derived key.
    ///   - includePeerID: Include peer ID in derived key.
    ///   - sessionKeyFormat: Derived session key format.
    public init(
        defaultSessionKey: String = "main",
        includeChannelID: Bool = true,
        includeAccountID: Bool = true,
        includePeerID: Bool = true,
        sessionKeyFormat: SessionKeyFormat = .legacy
    ) {
        self.defaultSessionKey = defaultSessionKey
        self.includeChannelID = includeChannelID
        self.includeAccountID = includeAccountID
        self.includePeerID = includePeerID
        self.sessionKeyFormat = sessionKeyFormat
    }

    private enum CodingKeys: String, CodingKey {
        case defaultSessionKey
        case includeChannelID
        case includeAccountID
        case includePeerID
        case sessionKeyFormat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultSessionKey = try container.decodeIfPresent(String.self, forKey: .defaultSessionKey) ?? "main"
        self.includeChannelID = try container.decodeIfPresent(Bool.self, forKey: .includeChannelID) ?? true
        self.includeAccountID = try container.decodeIfPresent(Bool.self, forKey: .includeAccountID) ?? true
        self.includePeerID = try container.decodeIfPresent(Bool.self, forKey: .includePeerID) ?? true
        self.sessionKeyFormat = container.decodeLenient(SessionKeyFormat.self, forKey: .sessionKeyFormat) ?? .legacy
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.defaultSessionKey, forKey: .defaultSessionKey)
        try container.encode(self.includeChannelID, forKey: .includeChannelID)
        try container.encode(self.includeAccountID, forKey: .includeAccountID)
        try container.encode(self.includePeerID, forKey: .includePeerID)
        if self.sessionKeyFormat != .legacy {
            try container.encode(self.sessionKeyFormat, forKey: .sessionKeyFormat)
        }
    }
}
