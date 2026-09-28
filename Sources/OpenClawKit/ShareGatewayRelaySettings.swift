import Foundation

/// Persisted gateway relay settings used by the share extension handoff flow.
public struct ShareGatewayRelayConfig: Codable, Sendable, Equatable {
    /// Gateway URL string used by the relay client.
    public let gatewayURLString: String
    /// Stable gateway identity (for example a ``GatewayEndpointID`` value) that scopes device auth.
    public let gatewayStableID: String?
    /// Optional gateway token used for bearer-style auth (stored in the Keychain).
    public let token: String?
    /// Optional gateway password used for password-based auth (stored in the Keychain).
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
        gatewayStableID: String? = nil,
        token: String?,
        password: String?,
        sessionKey: String,
        deliveryChannel: String? = nil,
        deliveryTo: String? = nil)
    {
        self.gatewayURLString = gatewayURLString
        self.gatewayStableID = gatewayStableID
        self.token = token
        self.password = password
        self.sessionKey = sessionKey
        self.deliveryChannel = deliveryChannel
        self.deliveryTo = deliveryTo
    }
}

/// Keychain operations used by ``ShareGatewayRelaySettings`` (injectable for tests).
struct ShareGatewayRelayCredentialStore: @unchecked Sendable {
    let load: (_ service: String, _ account: String, _ accessGroup: String?) -> String?
    let save: (_ value: String, _ service: String, _ account: String, _ accessGroup: String?) -> Bool
    let delete: (_ service: String, _ account: String, _ accessGroup: String?) -> Bool

    static let live = ShareGatewayRelayCredentialStore(
        load: { GenericPasswordKeychainStore.loadString(service: $0, account: $1, accessGroup: $2) },
        save: { GenericPasswordKeychainStore.saveString($0, service: $1, account: $2, accessGroup: $3) },
        delete: { GenericPasswordKeychainStore.delete(service: $0, account: $1, accessGroup: $2) })
}

/// Storage backends used by ``ShareGatewayRelaySettings`` (injectable for tests).
struct ShareGatewayRelayEnvironment: @unchecked Sendable {
    let defaults: () -> UserDefaults
    let legacyDefaults: () -> UserDefaults?
    let credentials: ShareGatewayRelayCredentialStore
    let isAppExtension: () -> Bool
    let credentialService: () -> String
    let credentialAccessGroup: () -> String?

    static let live = ShareGatewayRelayEnvironment(
        defaults: { OpenClawAppGroup.sharedDefaults },
        legacyDefaults: {
            // Pre-2026.3.0 releases always used this suite; read it once to migrate.
            guard OpenClawAppGroup.identifier != OpenClawAppGroup.legacyIdentifier else { return nil }
            return UserDefaults(suiteName: OpenClawAppGroup.legacyIdentifier)
        },
        credentials: .live,
        isAppExtension: { Bundle.main.object(forInfoDictionaryKey: "NSExtension") != nil },
        credentialService: { ShareGatewayRelaySettings.resolvedCredentialService },
        credentialAccessGroup: { ShareGatewayRelaySettings.resolvedCredentialAccessGroup })
}

/// Storage for the share-extension relay configuration and last event text.
///
/// Non-secret routing metadata lives in the App Group defaults suite (``OpenClawAppGroup``) under
/// `share.gatewayRelay.config.v1`. The token and password live in the Keychain (account
/// `credentials.v1`), scoped to the App Group as a Keychain access group so the host app and its
/// share extension share only this credential bundle. Earlier releases stored the secrets in plain
/// App Group defaults; ``loadConfig()`` migrates them into the Keychain (host app only) and scrubs
/// the old record.
public enum ShareGatewayRelaySettings {
    @TaskLocal static var environment = ShareGatewayRelayEnvironment.live

    private static let relayConfigKey = "share.gatewayRelay.config.v1"
    private static let relayCredentialAccount = "credentials.v1"
    private static let lastEventKey = "share.gatewayRelay.event.v1"
    private static let defaultCredentialServiceSuffix = "share-gateway-relay"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedCredentialService: String?
    nonisolated(unsafe) private static var storedAccessGroup: String?

    /// Keychain service for the relay credentials. Defaults to `<App Group>.share-gateway-relay`
    /// (or `ai.openclaw.share-gateway-relay` without an App Group); host and extension must agree.
    public static var credentialServiceOverride: String? {
        get { self.lock.withLock { self.storedCredentialService } }
        set { self.lock.withLock { self.storedCredentialService = newValue } }
    }

    /// Keychain access group for the relay credentials. Defaults to ``OpenClawAppGroup/identifier``.
    public static var keychainAccessGroupOverride: String? {
        get { self.lock.withLock { self.storedAccessGroup } }
        set { self.lock.withLock { self.storedAccessGroup = newValue } }
    }

    static var resolvedCredentialService: String {
        if let override = self.credentialServiceOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return override
        }
        let base = OpenClawAppGroup.identifier ?? "ai.openclaw"
        return "\(base).\(self.defaultCredentialServiceSuffix)"
    }

    static var resolvedCredentialAccessGroup: String? {
        self.keychainAccessGroupOverride ?? OpenClawAppGroup.identifier
    }

    private static var defaults: UserDefaults {
        self.environment.defaults()
    }

    /// Loads the relay configuration, merging Keychain credentials that belong to the stored route.
    ///
    /// Legacy records with inline secrets are migrated into the Keychain when running in the host app;
    /// in an extension, or when the Keychain write fails, the legacy record is scrubbed and `nil` is
    /// returned so the user reconnects from the host app.
    public static func loadConfig() -> ShareGatewayRelayConfig? {
        self.migrateLegacySuiteIfNeeded()
        guard let data = self.defaults.data(forKey: self.relayConfigKey) else { return nil }
        guard let config = try? JSONDecoder().decode(ShareGatewayRelayConfig.self, from: data) else { return nil }
        if config.token != nil || config.password != nil {
            return self.resolveLegacyConfig(
                config,
                isAppExtension: self.environment.isAppExtension(),
                migrate: { config in
                    self.commitConfig(
                        config,
                        saveCredentials: self.saveCredentials,
                        saveMetadata: self.saveMetadata)
                },
                discard: {
                    self.defaults.removeObject(forKey: self.relayConfigKey)
                    self.saveLastEvent("Share unavailable after upgrade: open the app to reconnect securely.")
                })
        }
        // Keep relay identity in the Keychain bundle with its secrets. A partial
        // route update must never bind one gateway's credentials to another.
        let credentials = self.loadCredentials().flatMap { stored in
            self.credentials(stored, match: config) ? stored : nil
        }
        return ShareGatewayRelayConfig(
            gatewayURLString: config.gatewayURLString,
            gatewayStableID: config.gatewayStableID,
            token: credentials?.token,
            password: credentials?.password,
            sessionKey: config.sessionKey,
            deliveryChannel: config.deliveryChannel,
            deliveryTo: config.deliveryTo)
    }

    /// An endpoint is not a gateway identity. If the extension launches before the host can prove a
    /// stable ID, discard unscoped device auth and use explicit auth only.
    ///
    /// - Parameter discardUnscopedDeviceAuth: Drops device-auth tokens that are not scoped to a gateway
    ///   (for the share-extension device profile). Called only when the config has no stable ID.
    public static func loadConfigDiscardingUnscopedDeviceAuth(
        discardUnscopedDeviceAuth: () -> Void) -> ShareGatewayRelayConfig?
    {
        guard let config = self.loadConfig() else { return nil }
        if config.gatewayStableID?.isEmpty == false {
            return config
        }
        discardUnscopedDeviceAuth()
        return config
    }

    /// Persists the relay configuration: secrets to the Keychain first, then metadata.
    ///
    /// - Returns: `false` when the Keychain write failed; the stored config is then removed and a
    ///   "reconnect" event is recorded, because metadata without its credentials is unusable.
    @discardableResult
    public static func saveConfig(_ config: ShareGatewayRelayConfig) -> Bool {
        let saved = self.commitConfig(
            config,
            saveCredentials: self.saveCredentials,
            saveMetadata: self.saveMetadata)
        guard saved else {
            self.defaults.removeObject(forKey: self.relayConfigKey)
            self.saveLastEvent("Share unavailable: reconnect the app to save gateway access securely.")
            return false
        }
        return true
    }

    /// Removes any stored relay configuration and its Keychain credentials.
    public static func clearConfig() {
        self.defaults.removeObject(forKey: self.relayConfigKey)
        _ = self.deleteCredentials()
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

    private static func saveMetadata(_ config: ShareGatewayRelayConfig) {
        let metadata = ShareGatewayRelayConfig(
            gatewayURLString: config.gatewayURLString,
            gatewayStableID: config.gatewayStableID,
            token: nil,
            password: nil,
            sessionKey: config.sessionKey,
            deliveryChannel: config.deliveryChannel,
            deliveryTo: config.deliveryTo)
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        self.defaults.set(data, forKey: self.relayConfigKey)
    }

    static func commitConfig(
        _ config: ShareGatewayRelayConfig,
        saveCredentials: (ShareGatewayRelayConfig) -> Bool,
        saveMetadata: (ShareGatewayRelayConfig) -> Void) -> Bool
    {
        guard saveCredentials(config) else { return false }
        saveMetadata(config)
        return true
    }

    static func resolveLegacyConfig(
        _ config: ShareGatewayRelayConfig,
        isAppExtension: Bool,
        migrate: (ShareGatewayRelayConfig) -> Bool,
        discard: () -> Void) -> ShareGatewayRelayConfig?
    {
        // Only the host may create shared credentials. An extension-first upgrade
        // or failed Keychain write must scrub and reject the legacy auth record.
        guard !isAppExtension, migrate(config) else {
            discard()
            return nil
        }
        return config
    }

    /// Moves a pre-2026.3.0 record from the legacy suite into the configured App Group suite once.
    private static func migrateLegacySuiteIfNeeded() {
        guard self.defaults.data(forKey: self.relayConfigKey) == nil,
              let legacy = self.environment.legacyDefaults(),
              let data = legacy.data(forKey: self.relayConfigKey)
        else { return }
        self.defaults.set(data, forKey: self.relayConfigKey)
        if let event = legacy.string(forKey: self.lastEventKey), self.defaults.string(forKey: self.lastEventKey) == nil {
            self.defaults.set(event, forKey: self.lastEventKey)
        }
        legacy.removeObject(forKey: self.relayConfigKey)
        legacy.removeObject(forKey: self.lastEventKey)
    }

    private static func loadCredentials() -> ShareGatewayRelayConfig? {
        guard let json = self.environment.credentials.load(
            self.environment.credentialService(),
            self.relayCredentialAccount,
            self.environment.credentialAccessGroup()),
            let data = json.data(using: .utf8),
            let credentials = try? JSONDecoder().decode(ShareGatewayRelayConfig.self, from: data)
        else { return nil }
        return credentials
    }

    private static func saveCredentials(_ config: ShareGatewayRelayConfig) -> Bool {
        guard config.token != nil || config.password != nil else {
            return self.deleteCredentials()
        }
        guard let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8),
              self.environment.credentials.save(
                  json,
                  self.environment.credentialService(),
                  self.relayCredentialAccount,
                  self.environment.credentialAccessGroup())
        else {
            return false
        }
        return true
    }

    private static func deleteCredentials() -> Bool {
        self.environment.credentials.delete(
            self.environment.credentialService(),
            self.relayCredentialAccount,
            self.environment.credentialAccessGroup())
    }

    private static func credentials(
        _ credentials: ShareGatewayRelayConfig,
        match metadata: ShareGatewayRelayConfig) -> Bool
    {
        if let stableID = metadata.gatewayStableID, !stableID.isEmpty {
            return credentials.gatewayStableID == stableID
        }
        return credentials.gatewayStableID?.isEmpty != false &&
            credentials.gatewayURLString == metadata.gatewayURLString
    }
}
