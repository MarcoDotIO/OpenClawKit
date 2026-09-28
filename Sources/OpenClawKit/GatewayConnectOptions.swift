import Foundation
import OpenClawProtocol

/// Client capability strings a native app can advertise in connect `caps`.
///
/// These mirror the upstream Swift constants. The full generated vocabulary lives in
/// ``GatewayClientCapability`` (OpenClawProtocol); advertise only what the app implements.
public enum OpenClawGatewayClientCapability {
    /// The client renders agent-kind metadata.
    public static let agentKind = "agent-kind"
    /// The client renders inline widgets.
    public static let inlineWidgets = "inline-widgets"
    /// The client honors model-selection policies.
    public static let modelSelectionPolicy = "model-selection-policy"
    /// The client refreshes usage on demand.
    public static let usageRefreshing = "usage-refreshing"
}

/// Which device-proof payload the connect signer produces.
public enum GatewayDeviceProofPayloadVersion: String, Sendable {
    /// Upstream default: the v2 payload, which every managed gateway (including ones deployed
    /// before v3 metadata support) verifies. Gateways try v3 first and then v2.
    case v2Compatible = "v2"
    /// The v3 payload that also signs platform and device family metadata.
    case v3
}

/// Connect-frame options for one gateway channel.
public struct GatewayConnectOptions: Sendable {
    /// Connect role (`operator` or `node`).
    public var role: String
    /// Requested scopes.
    public var scopes: [String]
    /// When `true`, a stored device token's scopes never replace ``scopes``.
    public var scopesAreExplicit: Bool
    /// Advertised client capabilities.
    public var caps: [String]
    /// Node commands this client implements.
    public var commands: [String]
    /// Optional computer-use capability descriptor sent verbatim as `computerUse`.
    public var computerUse: AnyCodable?
    /// Optional `PATH` environment advertised by node hosts.
    public var pathEnv: String?
    /// Node permission flags.
    public var permissions: [String: Bool]
    /// Client id from the gateway's closed registry (see ``GatewayClientID``).
    public var clientId: String
    /// Client mode (see ``GatewayClientMode``).
    public var clientMode: String
    /// Display name shown by the gateway; defaults to the device name.
    public var clientDisplayName: String?
    /// Identity profile whose device key and tokens this connection uses.
    public var deviceIdentityProfile: GatewayDeviceIdentityProfile
    /// When false, the connection omits the signed device identity payload and cannot use
    /// device-scoped auth (role/scope upgrades will require pairing). Keep this true for
    /// role/scoped sessions such as operator UI clients.
    public var includeDeviceIdentity: Bool
    /// Set false for an endpoint handoff whose explicit credentials (including none) must be
    /// tried without loading a previously stored device token.
    public var allowStoredDeviceAuth: Bool
    /// Stable Gateway owner for device tokens. Nil preserves legacy unscoped storage only when
    /// ``allowStoredDeviceAuth`` is true; false plus nil disables both lookup and persistence.
    public var deviceAuthGatewayID: String?
    /// Device-proof payload version signed during connect.
    public var deviceProofPayload: GatewayDeviceProofPayloadVersion
    /// Lowest gateway protocol version offered in `connect.minProtocol`.
    ///
    /// `nil` (the default) follows upstream: operators require `GATEWAY_MIN_PROTOCOL_VERSION` (4) and
    /// node-role/node-mode clients accept `GATEWAY_MIN_NODE_PROTOCOL_VERSION` (3). Set this to `3` to
    /// opt in to legacy pre-v4 gateways (for example OpenClaw 2026.4.x); v4-only features such as
    /// chat `deltaText` events are then unavailable on those gateways.
    public var minimumProtocolVersion: Int?
    /// Pre-auth handshake budget in milliseconds (socket open through hello-ok), mirroring
    /// `gateway.handshakeTimeoutMs`. `nil` keeps the 30 s client default.
    public var handshakeTimeoutMs: Int?

    /// Creates connect options. Every parameter added after 2026.2 is defaulted for source compatibility.
    public init(
        role: String,
        scopes: [String],
        scopesAreExplicit: Bool = false,
        caps: [String],
        commands: [String],
        computerUse: AnyCodable? = nil,
        pathEnv: String? = nil,
        permissions: [String: Bool],
        clientId: String,
        clientMode: String,
        clientDisplayName: String?,
        deviceIdentityProfile: GatewayDeviceIdentityProfile = .primary,
        includeDeviceIdentity: Bool = true,
        allowStoredDeviceAuth: Bool = true,
        deviceAuthGatewayID: String? = nil,
        deviceProofPayload: GatewayDeviceProofPayloadVersion = .v2Compatible,
        minimumProtocolVersion: Int? = nil,
        handshakeTimeoutMs: Int? = nil)
    {
        self.role = role
        self.scopes = scopes
        self.scopesAreExplicit = scopesAreExplicit
        self.caps = caps
        self.commands = commands
        self.computerUse = computerUse
        self.pathEnv = pathEnv
        self.permissions = permissions
        self.clientId = clientId
        self.clientMode = clientMode
        self.clientDisplayName = clientDisplayName
        self.deviceIdentityProfile = deviceIdentityProfile
        self.includeDeviceIdentity = includeDeviceIdentity
        self.allowStoredDeviceAuth = allowStoredDeviceAuth
        self.deviceAuthGatewayID = deviceAuthGatewayID
        self.deviceProofPayload = deviceProofPayload
        self.minimumProtocolVersion = minimumProtocolVersion
        self.handshakeTimeoutMs = handshakeTimeoutMs
    }

    /// Registry client id for the current platform.
    ///
    /// macOS uses `openclaw-macos`, iOS/iPadOS `openclaw-ios`, and watchOS `openclaw-watchos`.
    /// The upstream registry has no tvOS or visionOS ids, so those platforms (and Mac Catalyst)
    /// connect as `openclaw-ios`; the gateway normalizes client ids against its closed registry.
    public static var defaultClientID: String {
        #if os(macOS)
        GatewayClientID.macosApp.rawValue
        #elseif os(watchOS)
        GatewayClientID.watchosApp.rawValue
        #else
        GatewayClientID.iosApp.rawValue
        #endif
    }

    /// Default operator UI options: ``GatewayChannelActor/defaultOperatorConnectScopes``,
    /// the platform ``defaultClientID`` and mode `ui`.
    /// - Parameter displayName: Client display name; defaults to the device name.
    /// - Returns: Operator connect options.
    public static func defaultOperator(displayName: String? = nil) -> GatewayConnectOptions {
        GatewayConnectOptions(
            role: "operator",
            scopes: GatewayChannelActor.defaultOperatorConnectScopes,
            caps: [],
            commands: [],
            permissions: [:],
            clientId: Self.defaultClientID,
            clientMode: GatewayClientMode.ui.rawValue,
            clientDisplayName: displayName ?? InstanceIdentity.displayName)
    }
}

/// Explicit credentials for one gateway route. Part of the node session's reconnect identity.
public struct GatewayNodeSessionCredentials: Sendable, Equatable {
    /// Shared gateway token.
    public let token: String?
    /// Single-use bootstrap (setup-code) token.
    public let bootstrapToken: String?
    /// Gateway password.
    public let password: String?

    /// Creates a credential set.
    public init(
        token: String? = nil,
        bootstrapToken: String? = nil,
        password: String? = nil)
    {
        self.token = token
        self.bootstrapToken = bootstrapToken
        self.password = password
    }
}

/// Credential kind a connect attempt used.
public enum GatewayAuthSource: String, Sendable {
    /// Stored device token.
    case deviceToken = "device-token"
    /// Explicit shared gateway token.
    case sharedToken = "shared-token"
    /// Setup-code bootstrap token.
    case bootstrapToken = "bootstrap-token"
    /// Gateway password.
    case password
    /// No credentials.
    case none
}

/// Opaque binding for the exact credentials selected by one live Gateway socket.
///
/// The binding exposes no credential; HTTP adapters use the channel's separate route-checked access.
public struct GatewayAuthBinding: Equatable, Sendable {
    /// Credential kind.
    public let source: GatewayAuthSource
    /// HMAC-SHA256 hex fingerprint of the credentials, present only when the channel has a binding key.
    public let credentialFingerprint: String?
}

extension GatewayConnectOptions {
    var allowsDeviceAuthPersistence: Bool {
        // Legacy callers must rotate credentials in the same unscoped namespace they read.
        // Fresh pairing instead supplies an owner; explicit ownerless handoffs set false/nil.
        self.allowStoredDeviceAuth || self.deviceAuthGatewayID != nil
    }

    /// Additive connect-frame fields, sent only when this client declares them.
    func applyOptionalConnectParams(to params: inout [String: OpenClawProtocol.AnyCodable]) {
        if !self.commands.isEmpty {
            params["commands"] = OpenClawProtocol.AnyCodable(self.commands)
        }
        if let computerUse = self.computerUse {
            params["computerUse"] = computerUse
        }
        if let pathEnv = self.pathEnv?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pathEnv.isEmpty
        {
            params["pathEnv"] = OpenClawProtocol.AnyCodable(pathEnv)
        }
        if !self.permissions.isEmpty {
            params["permissions"] = OpenClawProtocol.AnyCodable(self.permissions)
        }
    }
}
