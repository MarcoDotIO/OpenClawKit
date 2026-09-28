import Foundation

/// Session key routing behavior controls.
public struct RoutingConfig: Codable, Sendable, Equatable {
    public var defaultSessionKey: String
    public var includeChannelID: Bool
    public var includeAccountID: Bool
    public var includePeerID: Bool

    /// Creates routing settings.
    /// - Parameters:
    ///   - defaultSessionKey: Fallback session key.
    ///   - includeChannelID: Include channel ID in derived key.
    ///   - includeAccountID: Include account ID in derived key.
    ///   - includePeerID: Include peer ID in derived key.
    public init(
        defaultSessionKey: String = "main",
        includeChannelID: Bool = true,
        includeAccountID: Bool = true,
        includePeerID: Bool = true
    ) {
        self.defaultSessionKey = defaultSessionKey
        self.includeChannelID = includeChannelID
        self.includeAccountID = includeAccountID
        self.includePeerID = includePeerID
    }

    private enum CodingKeys: String, CodingKey {
        case defaultSessionKey
        case includeChannelID
        case includeAccountID
        case includePeerID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultSessionKey = try container.decodeIfPresent(String.self, forKey: .defaultSessionKey) ?? "main"
        self.includeChannelID = try container.decodeIfPresent(Bool.self, forKey: .includeChannelID) ?? true
        self.includeAccountID = try container.decodeIfPresent(Bool.self, forKey: .includeAccountID) ?? true
        self.includePeerID = try container.decodeIfPresent(Bool.self, forKey: .includePeerID) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.defaultSessionKey, forKey: .defaultSessionKey)
        try container.encode(self.includeChannelID, forKey: .includeChannelID)
        try container.encode(self.includeAccountID, forKey: .includeAccountID)
        try container.encode(self.includePeerID, forKey: .includePeerID)
    }
}
