import Foundation
import OpenClawProtocol

/// Wire contract of the direct Apple Watch node transport: signed HTTPS long-poll on the Gateway's
/// operator port (`/api/nodes/watch/*`, upstream `src/gateway/watch-node-http.ts`).
///
/// watchOS blocks WebSockets and low-level networking for ordinary apps (Apple TN3135), so a Watch
/// that wants to be its own node uses bounded HTTPS polls instead of the node WebSocket:
///
/// 1. `GET challenge` returns `{ok, nonce, ts, expiresAtMs}`.
/// 2. `POST connect` sends connect params signed over the challenge (v3 device proof,
///    ``OpenClawWatchNodeConnectRequest``) and returns a session token plus the node device token.
/// 3. `POST poll` (bearer session token) long-polls for up to ``pollTimeoutMs`` and returns
///    `{ok: true, event: null}` when idle or one queued node event.
/// 4. `POST result` (bearer session token) answers a `node.invoke.request`.
/// 5. `POST disconnect` (bearer session token) ends the session.
///
/// The declared surface must be exactly: no caps, commands ⊆ ``allowedCommands``, permissions ⊆
/// ``allowedPermissions``; the Gateway rejects anything broader. Transport is `https` only with a
/// system-trusted certificate: plain HTTP, self-signed certificates, and fingerprint-only pins are
/// unsupported.
public enum OpenClawWatchNodeHTTP {
    /// Base path of every endpoint.
    public static let basePath = "/api/nodes/watch"
    /// Challenge lifetime on the Gateway.
    public static let challengeTTLMs: Int64 = 60000
    /// Maximum difference between the signature time and the Gateway clock.
    public static let signatureSkewMs: Int64 = 2 * 60000
    /// Longest time the Gateway holds an idle poll open.
    public static let pollTimeoutMs: Int64 = 20000
    /// A session without a poll or result for this long expires.
    public static let sessionIdleMs: Int64 = 75000
    /// Maximum request body size.
    public static let maxBodyBytes = 64 * 1024
    /// Maximum size of one queued node event.
    public static let maxQueuedEventBytes = 64 * 1024
    /// Maximum total size of queued events per session.
    public static let maxQueuedBytes = 512 * 1024
    /// Maximum number of queued events per session.
    public static let maxQueuedEvents = 32
    /// Maximum outstanding challenges per client address.
    public static let maxPendingChallengesPerClient = 8
    /// Gateway client id of the watchOS app (`GATEWAY_CLIENT_IDS.WATCHOS_APP`).
    public static let clientId = "openclaw-watchos"
    /// Client mode.
    public static let clientMode = "node"
    /// Connect role.
    public static let role = "node"
    /// Poll event carrying a ``OpenClawWatchNodeInvokeRequest``.
    public static let invokeRequestEvent = "node.invoke.request"
    /// The only commands a direct Watch node may declare.
    public static let allowedCommands: [String] = [
        OpenClawDeviceCommand.info.rawValue,
        OpenClawDeviceCommand.status.rawValue,
        OpenClawSystemCommand.notify.rawValue,
    ]
    /// The only permissions a direct Watch node may declare.
    public static let allowedPermissions: Set<String> = ["notifications"]

    /// Endpoints under ``basePath``.
    public enum Endpoint: String, Sendable, CaseIterable {
        /// `GET /api/nodes/watch/challenge`.
        case challenge
        /// `POST /api/nodes/watch/connect`.
        case connect
        /// `POST /api/nodes/watch/poll`.
        case poll
        /// `POST /api/nodes/watch/result`.
        case result
        /// `POST /api/nodes/watch/disconnect`.
        case disconnect

        /// HTTP method.
        public var method: String {
            self == .challenge ? "GET" : "POST"
        }

        /// Absolute path below the Gateway origin (before any context path).
        public var path: String {
            "\(OpenClawWatchNodeHTTP.basePath)/\(self.rawValue)"
        }

        /// Client request timeout: 25 s for polls (longer than the Gateway hold), 8 s otherwise.
        public var requestTimeout: TimeInterval {
            self == .poll ? 25 : 8
        }
    }

    /// URL of `endpoint` below an `https` base URL (origin plus optional context path).
    public static func url(for endpoint: Endpoint, baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("nodes")
            .appendingPathComponent("watch")
            .appendingPathComponent(endpoint.rawValue)
    }

    /// Whether a declared surface is within the direct Watch node bounds (at least one command).
    public static func isBoundedSurface(caps: [String], commands: [String], permissions: [String]) -> Bool {
        caps.isEmpty && !commands.isEmpty
            && commands.allSatisfy(self.allowedCommands.contains)
            && permissions.allSatisfy(self.allowedPermissions.contains)
    }
}

/// `watch.node.setup`: iPhone → Watch setup code for the direct node (sent over WatchConnectivity).
///
/// The setup code is an admin-minted, short-lived, node-only bootstrap credential (upstream mints it with
/// `device.pair.setupCode` and `bootstrapProfile: "voice-node"`). The Watch pairs with it once, stores its
/// own device token, and deletes the bootstrap credential.
public struct OpenClawWatchNodeSetupMessage: Codable, Sendable, Equatable {
    /// Oldest accepted setup: 12 minutes.
    public static let maximumAgeMs: Int64 = 12 * 60 * 1000
    /// Newest accepted setup relative to the Watch clock: 2 minutes in the future.
    public static let maximumClockSkewMs: Int64 = 2 * 60 * 1000

    /// Always ``OpenClawWatchPayloadType/directNodeSetup``.
    public var type: OpenClawWatchPayloadType
    /// Device-pair setup code (see ``GatewayConnectDeepLink/fromSetupCode(_:)``).
    public var setupCode: String
    /// Send time in milliseconds since the Unix epoch.
    public var sentAtMs: Int64

    /// Creates a setup message.
    public init(setupCode: String, sentAtMs: Int64) {
        self.type = .directNodeSetup
        self.setupCode = setupCode
        self.sentAtMs = sentAtMs
    }

    /// Whether ``sentAtMs`` is within the accepted window around `nowMs`.
    public func isFresh(nowMs: Int64) -> Bool {
        let oldest = nowMs.subtractingReportingOverflow(Self.maximumAgeMs)
        let newest = nowMs.addingReportingOverflow(Self.maximumClockSkewMs)
        guard !oldest.overflow, !newest.overflow else { return false }
        return (oldest.partialValue...newest.partialValue).contains(self.sentAtMs)
    }
}

/// `GET challenge` response.
public struct OpenClawWatchNodeChallenge: Codable, Sendable, Equatable {
    /// Single-use challenge nonce.
    public let nonce: String
    /// Gateway time in milliseconds; signs the proof. Older Gateways omitted it.
    public let ts: Int64?
    /// Challenge expiry in milliseconds.
    public let expiresAtMs: Int64?

    /// Creates a challenge.
    public init(nonce: String, ts: Int64?, expiresAtMs: Int64? = nil) {
        self.nonce = nonce
        self.ts = ts
        self.expiresAtMs = expiresAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case nonce
        case ts
        case expiresAtMs
    }

    /// Decodes a challenge, rejecting an empty nonce or a negative timestamp.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.nonce = try container.decode(String.self, forKey: .nonce)
        self.ts = try container.decodeIfPresent(Int64.self, forKey: .ts)
        self.expiresAtMs = try container.decodeIfPresent(Int64.self, forKey: .expiresAtMs)
        guard !self.nonce.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .nonce, in: container, debugDescription: "Gateway challenge nonce must not be empty")
        }
        if let ts, ts < 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .ts, in: container, debugDescription: "Gateway challenge timestamp must be non-negative")
        }
    }

    /// Time to sign: the Gateway `ts`, or `fallbackNowMs` for Gateways that omit it.
    public func signingTimeMs(fallbackNowMs: Int64) -> Int64 {
        self.ts ?? fallbackNowMs
    }
}

/// Credential presented in `connect.auth`.
public enum OpenClawWatchNodeCredential: Sendable, Equatable {
    /// One-time bootstrap token from the setup code (`auth.bootstrapToken`).
    case bootstrap(String)
    /// Node device token issued by an earlier connect (`auth.deviceToken`).
    case device(String)

    /// Token value.
    public var token: String {
        switch self {
        case let .bootstrap(token), let .device(token): token
        }
    }

    /// `connect.auth` key: `bootstrapToken` or `deviceToken`.
    public var authField: String {
        switch self {
        case .bootstrap: "bootstrapToken"
        case .device: "deviceToken"
        }
    }
}

/// `connect.client` of a direct Watch node.
///
/// The Gateway requires ``id`` `openclaw-watchos`, mode `node`, a platform starting with `watchOS`, and
/// device family `Apple Watch`; platform and device family are also signed into the v3 proof.
public struct OpenClawWatchNodeClientInfo: Codable, Sendable, Equatable {
    /// Client id (``OpenClawWatchNodeHTTP/clientId``).
    public var id: String
    /// Display name (the Watch name).
    public var displayName: String
    /// App version.
    public var version: String
    /// Platform string, for example `watchOS 27.0.0`.
    public var platform: String
    /// Device family (`Apple Watch`).
    public var deviceFamily: String
    /// Client mode (`node`).
    public var mode: String
    /// Stable installation identifier.
    public var instanceId: String
    /// Hardware model identifier, when known.
    public var modelIdentifier: String?

    /// Creates client metadata.
    public init(
        displayName: String,
        version: String,
        platform: String,
        deviceFamily: String,
        instanceId: String,
        modelIdentifier: String? = nil,
        id: String = OpenClawWatchNodeHTTP.clientId,
        mode: String = OpenClawWatchNodeHTTP.clientMode)
    {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.platform = platform
        self.deviceFamily = deviceFamily
        self.mode = mode
        self.instanceId = instanceId
        self.modelIdentifier = modelIdentifier
    }

    /// Metadata of the running app from ``InstanceIdentity`` and the main bundle version.
    ///
    /// Only a watchOS process produces a platform and family the Gateway accepts.
    public static func current(bundle: Bundle = .main) -> OpenClawWatchNodeClientInfo {
        OpenClawWatchNodeClientInfo(
            displayName: InstanceIdentity.displayName,
            version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            platform: InstanceIdentity.platformString,
            deviceFamily: InstanceIdentity.deviceFamily,
            instanceId: InstanceIdentity.instanceId,
            modelIdentifier: InstanceIdentity.modelIdentifier)
    }
}

/// `POST connect` body: gateway connect params with a v3 device proof over the challenge.
///
/// Encoded with exactly upstream's keys; `device.signedAt` is an `Int64` so the millisecond timestamp
/// stays an exact JSON integer on 32-bit watchOS.
public struct OpenClawWatchNodeConnectRequest: Codable, Sendable, Equatable {
    /// Signed device proof (`connect.device`).
    public struct Device: Codable, Sendable, Equatable {
        /// Device id (hex SHA-256 of the public key).
        public var id: String
        /// Base64url raw Ed25519 public key.
        public var publicKey: String
        /// Base64url Ed25519 signature of the v3 payload.
        public var signature: String
        /// Signing time in milliseconds (the challenge `ts`).
        public var signedAt: Int64
        /// Challenge nonce.
        public var nonce: String

        /// Creates a device proof.
        public init(id: String, publicKey: String, signature: String, signedAt: Int64, nonce: String) {
            self.id = id
            self.publicKey = publicKey
            self.signature = signature
            self.signedAt = signedAt
            self.nonce = nonce
        }
    }

    /// Minimum protocol version (direct Watch HTTP exists only on protocol-4 Gateways).
    public var minProtocol: Int
    /// Maximum protocol version.
    public var maxProtocol: Int
    /// Client metadata.
    public var client: OpenClawWatchNodeClientInfo
    /// Declared caps (always empty).
    public var caps: [String]
    /// Declared commands.
    public var commands: [String]
    /// Declared permissions (`notifications`).
    public var permissions: [String: Bool]
    /// Role (`node`).
    public var role: String
    /// Scopes (always empty).
    public var scopes: [String]
    /// Device proof.
    public var device: Device
    /// Exactly one credential: `bootstrapToken` or `deviceToken`.
    public var auth: [String: String]
    /// Preferred locale.
    public var locale: String?
    /// User agent (OS version string).
    public var userAgent: String?

    /// Creates a connect body from explicit parts.
    public init(
        client: OpenClawWatchNodeClientInfo,
        commands: [String] = OpenClawWatchNodeHTTP.allowedCommands,
        permissions: [String: Bool],
        device: Device,
        credential: OpenClawWatchNodeCredential,
        locale: String? = nil,
        userAgent: String? = nil,
        minProtocol: Int = GATEWAY_MIN_PROTOCOL_VERSION,
        maxProtocol: Int = GATEWAY_PROTOCOL_VERSION)
    {
        self.minProtocol = minProtocol
        self.maxProtocol = maxProtocol
        self.client = client
        self.caps = []
        self.commands = commands
        self.permissions = permissions
        self.role = OpenClawWatchNodeHTTP.role
        self.scopes = []
        self.device = device
        self.auth = [credential.authField: credential.token]
        self.locale = locale
        self.userAgent = userAgent
    }

    /// The v3 device-auth payload a direct Watch node signs.
    public static func signaturePayload(
        deviceId: String,
        client: OpenClawWatchNodeClientInfo,
        signedAtMs: Int64,
        credential: OpenClawWatchNodeCredential,
        nonce: String) -> String
    {
        GatewayDeviceAuthPayload.buildV3(
            fields: .init(
                deviceId: deviceId,
                client: .init(id: client.id, mode: client.mode),
                role: OpenClawWatchNodeHTTP.role,
                scopes: [],
                signedAtMs: signedAtMs,
                token: credential.token,
                nonce: nonce),
            platform: client.platform,
            deviceFamily: client.deviceFamily)
    }

    /// Builds and signs a connect body for `identity` over `challenge`.
    ///
    /// - Throws: ``OpenClawWatchNodeError/signingFailed`` when the identity cannot sign.
    public static func signed(
        identity: DeviceIdentity,
        challenge: OpenClawWatchNodeChallenge,
        credential: OpenClawWatchNodeCredential,
        client: OpenClawWatchNodeClientInfo,
        notificationsAuthorized: Bool,
        fallbackNowMs: Int64,
        locale: String? = Locale.preferredLanguages.first ?? Locale.current.identifier,
        userAgent: String? = ProcessInfo.processInfo.operatingSystemVersionString) throws
        -> OpenClawWatchNodeConnectRequest
    {
        // Older watch-node Gateways omitted ts; retain their original local-clock behavior.
        let signedAtMs = challenge.signingTimeMs(fallbackNowMs: fallbackNowMs)
        let payload = self.signaturePayload(
            deviceId: identity.deviceId,
            client: client,
            signedAtMs: signedAtMs,
            credential: credential,
            nonce: challenge.nonce)
        guard let signature = DeviceIdentityStore.signPayload(payload, identity: identity),
              let publicKey = DeviceIdentityStore.publicKeyBase64Url(identity)
        else {
            throw OpenClawWatchNodeError.signingFailed
        }
        return OpenClawWatchNodeConnectRequest(
            client: client,
            permissions: ["notifications": notificationsAuthorized],
            device: Device(
                id: identity.deviceId,
                publicKey: publicKey,
                signature: signature,
                signedAt: signedAtMs,
                nonce: challenge.nonce),
            credential: credential,
            locale: locale,
            userAgent: userAgent)
    }
}

/// `POST connect` response.
public struct OpenClawWatchNodeConnectResponse: Decodable, Sendable, Equatable {
    /// Operator credential issued with a voice setup (`deviceTokens[0]`).
    public struct VoiceCredential: Codable, Sendable, Equatable {
        /// Operator device token.
        public let deviceToken: String
        /// Role (`operator`).
        public let role: String
        /// Scopes (exactly ``OpenClawWatchNodeConnectResponse/voiceScopes``).
        public let scopes: [String]
        /// Issue time in milliseconds.
        public let issuedAtMs: Int64?

        /// Creates a voice credential.
        public init(deviceToken: String, role: String, scopes: [String], issuedAtMs: Int64? = nil) {
            self.deviceToken = deviceToken
            self.role = role
            self.scopes = scopes
            self.issuedAtMs = issuedAtMs
        }
    }

    /// Scopes of the standalone Watch Talk operator credential.
    public static let voiceScopes = ["operator.read", "operator.talk"]

    /// Bearer token for poll, result, and disconnect.
    public let sessionToken: String
    /// Node device token to persist for later connects.
    public let deviceToken: String
    /// Voice operator credential, only from a voice bootstrap.
    public let voiceCredential: VoiceCredential?
    /// Node id (the device id).
    public let nodeId: String?
    /// Negotiated protocol version.
    public let protocolVersion: Int?
    /// Gateway poll hold time in milliseconds.
    public let pollTimeoutMs: Int64?

    private enum CodingKeys: String, CodingKey {
        case sessionToken
        case deviceToken
        case deviceTokens
        case nodeId
        case protocolVersion = "protocol"
        case pollTimeoutMs
    }

    /// Creates a response.
    public init(
        sessionToken: String,
        deviceToken: String,
        voiceCredential: VoiceCredential? = nil,
        nodeId: String? = nil,
        protocolVersion: Int? = nil,
        pollTimeoutMs: Int64? = nil)
    {
        self.sessionToken = sessionToken
        self.deviceToken = deviceToken
        self.voiceCredential = voiceCredential
        self.nodeId = nodeId
        self.protocolVersion = protocolVersion
        self.pollTimeoutMs = pollTimeoutMs
    }

    /// Decodes a response, requiring non-empty tokens and, when `deviceTokens` is present, exactly one
    /// operator credential with exactly the voice scopes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionToken = try container.decode(String.self, forKey: .sessionToken)
        self.deviceToken = try container.decode(String.self, forKey: .deviceToken)
        guard !self.sessionToken.isEmpty, !self.deviceToken.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .deviceToken,
                in: container,
                debugDescription: "Expected non-empty Watch credentials.")
        }
        if let credentials = try container.decodeIfPresent([VoiceCredential].self, forKey: .deviceTokens) {
            guard credentials.count == 1,
                  let credential = credentials.first,
                  credential.role == "operator",
                  !credential.deviceToken.isEmpty,
                  credential.scopes.sorted() == Self.voiceScopes
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .deviceTokens,
                    in: container,
                    debugDescription: "Watch voice requires exactly operator.read and operator.talk.")
            }
            self.voiceCredential = credential
        } else {
            self.voiceCredential = nil
        }
        self.nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
        self.protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
        self.pollTimeoutMs = try container.decodeIfPresent(Int64.self, forKey: .pollTimeoutMs)
    }
}

/// `node.invoke.request` payload delivered by a poll.
public struct OpenClawWatchNodeInvokeRequest: Codable, Sendable, Equatable {
    /// Invocation id echoed in the result.
    public let id: String
    /// Target node id.
    public let nodeId: String
    /// Command name.
    public let command: String
    /// JSON-encoded params, or nil.
    public let paramsJSON: String?
    /// Invoke timeout in milliseconds.
    public let timeoutMs: Int64?
    /// Idempotency key.
    public let idempotencyKey: String?
    /// Session that triggered the invoke.
    public let sessionKey: String?

    /// Creates an invoke request.
    public init(
        id: String,
        nodeId: String,
        command: String,
        paramsJSON: String? = nil,
        timeoutMs: Int64? = nil,
        idempotencyKey: String? = nil,
        sessionKey: String? = nil)
    {
        self.id = id
        self.nodeId = nodeId
        self.command = command
        self.paramsJSON = paramsJSON
        self.timeoutMs = timeoutMs
        self.idempotencyKey = idempotencyKey
        self.sessionKey = sessionKey
    }

    /// The equivalent ``BridgeInvokeRequest`` for node command handlers (timeout clamped to `Int`).
    public var bridgeRequest: BridgeInvokeRequest {
        BridgeInvokeRequest(
            id: self.id,
            command: self.command,
            paramsJSON: self.paramsJSON,
            nodeId: self.nodeId,
            sessionKey: self.sessionKey,
            timeoutMs: self.timeoutMs.map { Int(clamping: $0) },
            idempotencyKey: self.idempotencyKey)
    }
}

/// One node event returned by a poll.
public struct OpenClawWatchNodeEvent: Decodable, Sendable, Equatable {
    /// Event name.
    public let event: String
    /// Decoded invoke request when ``event`` is ``OpenClawWatchNodeHTTP/invokeRequestEvent``.
    public let invokeRequest: OpenClawWatchNodeInvokeRequest?

    /// Creates an event.
    public init(event: String, invokeRequest: OpenClawWatchNodeInvokeRequest? = nil) {
        self.event = event
        self.invokeRequest = invokeRequest
    }

    private enum CodingKeys: String, CodingKey {
        case event
        case payload
    }

    /// Decodes an event; payloads of other events are ignored so unknown events never fail a poll.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.event = try container.decode(String.self, forKey: .event)
        if self.event == OpenClawWatchNodeHTTP.invokeRequestEvent {
            self.invokeRequest = try container.decodeIfPresent(OpenClawWatchNodeInvokeRequest.self, forKey: .payload)
        } else {
            self.invokeRequest = nil
        }
    }
}

/// `POST poll` response: `{ok: true, event: null}` when idle.
public struct OpenClawWatchNodePollResponse: Decodable, Sendable, Equatable {
    /// Queued event, or nil when the poll timed out idle.
    public let event: OpenClawWatchNodeEvent?

    /// Creates a poll response.
    public init(event: OpenClawWatchNodeEvent?) {
        self.event = event
    }
}

/// `POST result` body: `{id, ok, payloadJSON?, error?: {code?, message?}}`.
public struct OpenClawWatchNodeInvokeResult: Codable, Sendable, Equatable {
    /// Error shape accepted by the Gateway.
    public struct ErrorBody: Codable, Sendable, Equatable {
        /// Error code (for example `INVALID_REQUEST`).
        public let code: String?
        /// Error message.
        public let message: String?

        /// Creates an error body.
        public init(code: String?, message: String?) {
            self.code = code
            self.message = message
        }
    }

    /// Invocation id.
    public let id: String
    /// Whether the command succeeded.
    public let ok: Bool
    /// JSON-encoded result payload.
    public let payloadJSON: String?
    /// Error when ``ok`` is false.
    public let error: ErrorBody?

    /// Creates a result.
    public init(id: String, ok: Bool, payloadJSON: String? = nil, error: ErrorBody? = nil) {
        self.id = id
        self.ok = ok
        self.payloadJSON = payloadJSON
        self.error = error
    }

    /// Maps a handler response; a structured `payload` without `payloadJSON` is serialized to JSON.
    public init(response: BridgeInvokeResponse) throws {
        var payloadJSON = response.payloadJSON
        if payloadJSON == nil, let payload = response.payload {
            let data = try JSONEncoder().encode(payload)
            payloadJSON = String(bytes: data, encoding: .utf8)
        }
        self.init(
            id: response.id,
            ok: response.ok,
            payloadJSON: payloadJSON,
            error: response.error.map { ErrorBody(code: $0.code.rawValue, message: $0.message) })
    }
}

/// Error raised by the direct Watch node client.
public enum OpenClawWatchNodeError: Error, LocalizedError, Sendable, Equatable {
    /// No direct connection is configured; send setup from the iPhone.
    case notConfigured
    /// The setup has no trusted `https` endpoint, or carries a shared token/password.
    case insecureEndpoint
    /// The setup message is outside the accepted time window.
    case expiredSetup
    /// The setup message is older than one already accepted.
    case staleSetup
    /// Neither a bootstrap token nor a stored device token is available.
    case missingCredential
    /// The device identity could not be loaded or created.
    case identityUnavailable(String)
    /// The device identity could not sign the proof.
    case signingFailed
    /// The Gateway answered with a non-2xx status.
    case http(status: Int, detail: String)
    /// The Gateway response was not the expected shape.
    case invalidResponse(String)
    /// The node device token could not be persisted.
    case credentialStorageFailed
    /// The configuration could not be persisted.
    case configurationStorageFailed
    /// A voice credential arrived on a device-token reconnect; voice needs a new setup.
    case voiceRequiresNewSetup
    /// The voice credential could not be persisted.
    case voiceSetupIncomplete

    /// Whether the Gateway rejected the credential or session (HTTP 401).
    public var isUnauthorized: Bool {
        if case let .http(status, _) = self { return status == 401 }
        return false
    }

    /// Human-readable description.
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "Use iPhone Settings to enable direct connection.")
        case .insecureEndpoint:
            String(localized: "Direct mode requires a trusted HTTPS Gateway endpoint.")
        case .expiredSetup:
            String(localized: "Ignored an expired direct connection setup. Send setup again from iPhone.")
        case .staleSetup:
            String(localized: "Ignored an older direct connection setup.")
        case .missingCredential:
            String(localized: "No watch device credential")
        case let .identityUnavailable(detail):
            String(localized: "Could not save the watch device identity") + " (\(detail))"
        case .signingFailed:
            String(localized: "Could not sign watch identity")
        case let .http(status, detail):
            detail.isEmpty ? "Gateway HTTP error (\(status))" : detail
        case let .invalidResponse(detail):
            String(localized: "Invalid Gateway response") + " (\(detail))"
        case .credentialStorageFailed:
            String(localized: "Could not save the watch device credential")
        case .configurationStorageFailed:
            String(localized: "Could not save direct connection securely.")
        case .voiceRequiresNewSetup:
            String(localized: "Voice access requires a new setup from iPhone Settings.")
        case .voiceSetupIncomplete:
            String(localized: "Voice setup was incomplete. Send voice setup again from iPhone.")
        }
    }
}
