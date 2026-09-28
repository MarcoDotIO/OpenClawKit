import Foundation

/// Direct Watch node configuration derived from an iPhone-delivered setup code.
///
/// Only the setup's `wss://` endpoints are kept (the Watch polls the matching `https://` origin), and a
/// setup carrying a shared token or password is refused: the direct node authenticates with the one-time
/// bootstrap token and afterwards with its own device token only.
public struct OpenClawWatchNodeConfiguration: Codable, Sendable, Equatable {
    /// TLS-only connection link; its bootstrap token is removed after the first successful pairing.
    public private(set) var link: GatewayConnectDeepLink
    /// Credential owner id: `watch-direct:https://<host>:<port><contextPath>`.
    ///
    /// Reverse-proxied Gateways can share a host, so their path namespaces remain separate credential
    /// owners as well as separate HTTP and WebSocket routes.
    public let gatewayID: String
    /// Send time of the setup this configuration came from, in milliseconds.
    public let setupSentAtMs: Int64?

    /// Creates a configuration from a parsed setup link; nil unless the link is valid, carries a bootstrap
    /// token and no shared token or password, and has at least one TLS endpoint.
    public init?(setupLink: GatewayConnectDeepLink, sentAtMs: Int64) {
        guard setupLink.isValidEndpoint,
              setupLink.bootstrapToken != nil,
              setupLink.token == nil,
              setupLink.password == nil,
              let endpoint = setupLink.connectionEndpoints.first(where: \.tls)
        else { return nil }
        self.link = GatewayConnectDeepLink(
            host: endpoint.host,
            port: endpoint.port,
            tls: true,
            contextPath: endpoint.contextPath,
            bootstrapToken: setupLink.bootstrapToken,
            token: nil,
            password: nil,
            fallbackEndpoints: Array(setupLink.connectionEndpoints.filter(\.tls).dropFirst()))
        self.gatewayID = "watch-direct:https://\(endpoint.host.lowercased()):\(endpoint.port)" +
            (endpoint.contextPath ?? "")
        self.setupSentAtMs = sentAtMs
    }

    /// Creates a configuration from a setup message (see ``init(setupLink:sentAtMs:)``).
    public init?(setup: OpenClawWatchNodeSetupMessage) {
        guard let link = GatewayConnectDeepLink.fromSetupCode(setup.setupCode) else { return nil }
        self.init(setupLink: link, sentAtMs: setup.sentAtMs)
    }

    /// Whether the one-time bootstrap token is still pending.
    public var hasBootstrapCredential: Bool {
        self.link.bootstrapToken != nil
    }

    /// Primary endpoint text for display.
    public var endpointText: String {
        Self.httpsBaseURL(for: self.link)?.absoluteString ?? self.link.host
    }

    /// `https` base URLs in connection order (primary first, then fallbacks).
    public var httpsBaseURLs: [URL] {
        self.link.connectionEndpoints.compactMap { Self.httpsBaseURL(for: self.link.selectingEndpoint($0)) }
    }

    /// `wss://` URLs for a standalone Talk operator connection, in connection order.
    public var voiceWebSocketURLs: [URL] {
        self.link.connectionEndpoints.filter(\.tls).compactMap(\.websocketURL)
    }

    /// A copy without the bootstrap token, persisted once pairing has issued a device token.
    public func withoutBootstrapToken() -> OpenClawWatchNodeConfiguration {
        var result = self
        result.link = GatewayConnectDeepLink(
            host: self.link.host,
            port: self.link.port,
            tls: self.link.tls,
            contextPath: self.link.contextPath,
            bootstrapToken: nil,
            token: nil,
            password: nil,
            fallbackEndpoints: self.link.fallbackEndpoints)
        return result
    }

    /// Whether two configurations name the same installed setup (byte-exact Gateway id and send time).
    public func isSameInstallation(as other: OpenClawWatchNodeConfiguration?) -> Bool {
        guard let other else { return false }
        return self.gatewayID.utf8.elementsEqual(other.gatewayID.utf8) && self.setupSentAtMs == other.setupSentAtMs
    }

    /// `https://host:port<contextPath>` for a TLS link, or nil for a cleartext link or invalid port.
    public static func httpsBaseURL(for link: GatewayConnectDeepLink) -> URL? {
        guard link.tls, (1...65535).contains(link.port) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = link.host
        components.port = link.port
        components.percentEncodedPath = link.contextPath ?? ""
        return components.url
    }
}

/// Persistence for the direct Watch node configuration and the newest accepted setup time.
public protocol OpenClawWatchNodeConfigurationStoring: Sendable {
    /// Loads the installed configuration.
    func loadConfiguration() -> OpenClawWatchNodeConfiguration?
    /// Saves the configuration; returns false when it could not be stored securely.
    func saveConfiguration(_ configuration: OpenClawWatchNodeConfiguration) -> Bool
    /// Deletes the configuration.
    func deleteConfiguration()
    /// Send time of the newest accepted setup (replay fence), or 0.
    func lastAcceptedSetupSentAtMs() -> Int64
    /// Records the send time of an accepted setup.
    func saveLastAcceptedSetupSentAtMs(_ sentAtMs: Int64)
}

/// Keychain-backed configuration store (the bootstrap token is a secret) with the replay fence in
/// `UserDefaults`, matching the upstream Watch app.
public struct OpenClawWatchNodeKeychainConfigurationStore: OpenClawWatchNodeConfigurationStoring {
    /// Default Keychain service.
    public static let defaultService = "ai.openclaw.watch.direct-node"
    /// Default Keychain account.
    public static let defaultAccount = "gateway"
    /// Default `UserDefaults` key of the replay fence.
    public static let defaultLastSetupDefaultsKey = "watch.directNode.lastSetupSentAtMs"

    private let service: String
    private let account: String
    private let defaultsKey: String
    private let defaultsSuiteName: String?

    /// Creates a store; `defaultsSuiteName` nil uses `UserDefaults.standard`.
    public init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount,
        lastSetupDefaultsKey: String = Self.defaultLastSetupDefaultsKey,
        defaultsSuiteName: String? = nil)
    {
        self.service = service
        self.account = account
        self.defaultsKey = lastSetupDefaultsKey
        self.defaultsSuiteName = defaultsSuiteName
    }

    /// Loads the configuration from the Keychain.
    public func loadConfiguration() -> OpenClawWatchNodeConfiguration? {
        guard let raw = GenericPasswordKeychainStore.loadString(service: self.service, account: self.account)
        else { return nil }
        return try? JSONDecoder().decode(OpenClawWatchNodeConfiguration.self, from: Data(raw.utf8))
    }

    /// Saves the configuration to the Keychain.
    public func saveConfiguration(_ configuration: OpenClawWatchNodeConfiguration) -> Bool {
        guard let data = try? JSONEncoder().encode(configuration),
              let raw = String(bytes: data, encoding: .utf8)
        else { return false }
        return GenericPasswordKeychainStore.saveString(raw, service: self.service, account: self.account)
    }

    /// Deletes the Keychain item.
    public func deleteConfiguration() {
        _ = GenericPasswordKeychainStore.delete(service: self.service, account: self.account)
    }

    /// Reads the replay fence.
    public func lastAcceptedSetupSentAtMs() -> Int64 {
        (self.defaults.object(forKey: self.defaultsKey) as? NSNumber)?.int64Value ?? 0
    }

    /// Writes the replay fence.
    public func saveLastAcceptedSetupSentAtMs(_ sentAtMs: Int64) {
        self.defaults.set(NSNumber(value: sentAtMs), forKey: self.defaultsKey)
    }

    private var defaults: UserDefaults {
        self.defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
