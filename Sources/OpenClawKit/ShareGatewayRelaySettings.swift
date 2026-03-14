import Foundation

/// Persisted gateway relay settings used by the share extension handoff flow.
public struct ShareGatewayRelayConfig: Codable, Sendable, Equatable {
    /// Gateway URL string used by the relay client.
    public let gatewayURLString: String
    /// Optional gateway token used for bearer-style auth.
    public let token: String?
    /// Optional gateway password used for password-based auth.
    public let password: String?
    /// Session key targeted by the relay flow.
    public let sessionKey: String
    /// Optional delivery channel identifier for the shared event.
    public let deliveryChannel: String?
    /// Optional destination identifier within the delivery channel.
    public let deliveryTo: String?

    /// Creates a relay configuration for share-extension delivery.
    public init(
        gatewayURLString: String,
        token: String?,
        password: String?,
        sessionKey: String,
        deliveryChannel: String? = nil,
        deliveryTo: String? = nil)
    {
        self.gatewayURLString = gatewayURLString
        self.token = token
        self.password = password
        self.sessionKey = sessionKey
        self.deliveryChannel = deliveryChannel
        self.deliveryTo = deliveryTo
    }
}

/// Shared defaults-backed storage for the share-extension relay configuration and last event text.
public enum ShareGatewayRelaySettings {
    private static let suiteName = "group.ai.openclaw.shared"
    private static let relayConfigKey = "share.gatewayRelay.config.v1"
    private static let lastEventKey = "share.gatewayRelay.event.v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: self.suiteName) ?? .standard
    }

    /// Loads the currently persisted relay configuration.
    public static func loadConfig() -> ShareGatewayRelayConfig? {
        guard let data = self.defaults.data(forKey: self.relayConfigKey) else { return nil }
        return try? JSONDecoder().decode(ShareGatewayRelayConfig.self, from: data)
    }

    /// Persists the relay configuration used by the share extension.
    public static func saveConfig(_ config: ShareGatewayRelayConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        self.defaults.set(data, forKey: self.relayConfigKey)
    }

    /// Removes any stored relay configuration.
    public static func clearConfig() {
        self.defaults.removeObject(forKey: self.relayConfigKey)
    }

    /// Persists a human-readable last relay event line with a timestamp.
    public static func saveLastEvent(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let payload = "[\(timestamp)] \(message)"
        self.defaults.set(payload, forKey: self.lastEventKey)
    }

    /// Loads the most recently stored relay event message.
    public static func loadLastEvent() -> String? {
        let value = self.defaults.string(forKey: self.lastEventKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
