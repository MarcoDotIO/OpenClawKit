import Foundation
import OpenClawProtocol

/// Coarse classification of a gateway endpoint, reported instead of the host name.
public enum OpenClawGatewayEndpointKind: String, Sendable, CaseIterable {
    /// Loopback (`localhost`, `127.0.0.0/8`, `::1`).
    case loopback
    /// Local network (RFC 1918, link-local, `.local`, bare LAN host names, tailnet names).
    case lan
    /// Anything else.
    case remote

    /// Classifies a gateway URL without retaining its host.
    /// - Parameter url: Gateway WebSocket URL.
    public init(url: URL) {
        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            self = .remote
            return
        }
        if LoopbackHost.isLoopbackHost(host) {
            self = .loopback
        } else if LoopbackHost.isLocalNetworkHost(host) {
            self = .lan
        } else {
            self = .remote
        }
    }
}

/// Gateway connection states reported on ``OpenClawStateDomain/gateway``.
public enum OpenClawGatewayConnectionStateLabel: String, Sendable, CaseIterable {
    /// Opening the WebSocket.
    case connecting
    /// The connect challenge nonce arrived; the signed connect request is in flight.
    case authenticating
    /// `hello-ok` was accepted.
    case connected
    /// The socket failed or a tick was missed; a reconnect is scheduled.
    case reconnecting
    /// Reconnects are paused after a non-recoverable auth failure.
    case authPaused
}

/// Identity of a gateway connection, reported as stable metadata.
///
/// Holds no secrets and no host names: only the role/mode/client id, which credential kind was
/// used, the negotiated protocol, a coarse endpoint classification, and whether TLS is pinned.
public struct OpenClawGatewayStateContext: Sendable, Equatable {
    /// Connect role (`operator` or `node`).
    public var role: String
    /// Client mode (`ui`, `node`, `cli`, ...).
    public var clientMode: String
    /// Client id (`ios-app`, `macos-app`, ...).
    public var clientId: String
    /// Credential kind used for the connect attempt (``GatewayAuthSource`` raw value).
    public var authSource: String
    /// Gateway protocol version.
    public var protocolVersion: Int
    /// Endpoint classification.
    public var endpointKind: OpenClawGatewayEndpointKind
    /// Whether the TLS leaf certificate is pinned.
    public var tlsPinned: Bool

    /// Creates a gateway state context.
    /// - Parameters:
    ///   - role: Connect role.
    ///   - clientMode: Client mode.
    ///   - clientId: Client id.
    ///   - authSource: Credential kind.
    ///   - protocolVersion: Negotiated or offered protocol version.
    ///   - endpointKind: Endpoint classification.
    ///   - tlsPinned: Whether TLS is pinned.
    public init(
        role: String,
        clientMode: String,
        clientId: String,
        authSource: GatewayAuthSource = .none,
        protocolVersion: Int = GATEWAY_PROTOCOL_VERSION,
        endpointKind: OpenClawGatewayEndpointKind,
        tlsPinned: Bool = false)
    {
        self.role = role
        self.clientMode = clientMode
        self.clientId = clientId
        self.authSource = authSource.rawValue
        self.protocolVersion = protocolVersion
        self.endpointKind = endpointKind
        self.tlsPinned = tlsPinned
    }

    /// Creates a context from connect options and the gateway URL.
    /// - Parameters:
    ///   - url: Gateway URL (only its classification is kept).
    ///   - options: Connect options, or `nil` for the operator defaults.
    ///   - authSource: Credential kind used for the attempt.
    ///   - tlsPinned: Whether TLS is pinned.
    public init(
        url: URL,
        options: GatewayConnectOptions?,
        authSource: GatewayAuthSource = .none,
        tlsPinned: Bool = false)
    {
        self.init(
            role: options?.role ?? "operator",
            clientMode: options?.clientMode ?? "ui",
            clientId: options?.clientId ?? "unknown",
            authSource: authSource,
            protocolVersion: GATEWAY_PROTOCOL_VERSION,
            endpointKind: OpenClawGatewayEndpointKind(url: url),
            tlsPinned: tlsPinned)
    }

    /// Stable metadata reported with every gateway transition.
    public var stableMetadata: OpenClawStateMetadata {
        [
            "role": .string(self.role),
            "clientMode": .string(self.clientMode),
            "clientId": .string(self.clientId),
            "authSource": .string(self.authSource),
            "protocolVersion": .int(self.protocolVersion),
            "endpointKind": .string(self.endpointKind.rawValue),
            "tlsPinned": .bool(self.tlsPinned),
        ]
    }
}

/// Volatile gateway connection details (counters and timestamps only).
public struct OpenClawGatewayVolatileState: Sendable, Equatable {
    /// Current reconnect backoff in milliseconds.
    public var backoffMs: Int?
    /// Number of requests awaiting a response.
    public var pendingRequests: Int?
    /// Last event sequence number seen.
    public var lastSeq: Int?
    /// Time of the last gateway tick.
    public var lastTickAt: Date?
    /// Gateway auth detail code (`GatewayConnectAuthError.detailCodeRaw`) when auth failed.
    public var authDetailCode: String?
    /// Connection problem classification, when known.
    public var problemKind: String?

    /// Creates volatile gateway state.
    /// - Parameters:
    ///   - backoffMs: Reconnect backoff.
    ///   - pendingRequests: Pending request count.
    ///   - lastSeq: Last event sequence.
    ///   - lastTickAt: Last tick time.
    ///   - authDetailCode: Auth detail code.
    ///   - problemKind: Connection problem kind.
    public init(
        backoffMs: Int? = nil,
        pendingRequests: Int? = nil,
        lastSeq: Int? = nil,
        lastTickAt: Date? = nil,
        authDetailCode: String? = nil,
        problemKind: String? = nil)
    {
        self.backoffMs = backoffMs
        self.pendingRequests = pendingRequests
        self.lastSeq = lastSeq
        self.lastTickAt = lastTickAt
        self.authDetailCode = authDetailCode
        self.problemKind = problemKind
    }

    /// Metadata representation (absent values are omitted).
    public var metadata: OpenClawStateMetadata {
        var metadata: OpenClawStateMetadata = [:]
        if let backoffMs { metadata["backoffMs"] = .int(backoffMs) }
        if let pendingRequests { metadata["pendingRequests"] = .int(pendingRequests) }
        if let lastSeq { metadata["lastSeq"] = .int(lastSeq) }
        if let lastTickAt { metadata["lastTickAt"] = .date(lastTickAt) }
        if let authDetailCode, !authDetailCode.isEmpty { metadata["authDetailCode"] = .string(authDetailCode) }
        if let problemKind, !problemKind.isEmpty { metadata["problemKind"] = .string(problemKind) }
        return metadata
    }
}

/// Reports the gateway connection lifecycle on ``OpenClawStateDomain/gateway``.
///
/// Gateway transports call one method per lifecycle point (see ``OpenClawGatewayConnectionStateLabel``);
/// the helper owns the labels, the stable metadata and the privacy rules, so call sites stay one line.
public struct OpenClawGatewayStateReporter: Sendable {
    /// Destination reporter.
    public let reporter: any OpenClawSystemStateReporting
    /// Connection identity reported as stable metadata.
    public var context: OpenClawGatewayStateContext

    /// Creates a gateway state reporter.
    /// - Parameters:
    ///   - reporter: Destination reporter; `nil` uses ``OpenClawSystemState/shared``.
    ///   - context: Connection identity.
    public init(reporter: (any OpenClawSystemStateReporting)? = nil, context: OpenClawGatewayStateContext) {
        self.reporter = OpenClawSystemState.resolve(reporter)
        self.context = context
    }

    /// Reports a lifecycle transition.
    /// - Parameters:
    ///   - label: New state, or `nil` when the channel shut down.
    ///   - volatile: Volatile details.
    public func report(_ label: OpenClawGatewayConnectionStateLabel?, volatile: OpenClawGatewayVolatileState = .init()) {
        self.reporter.reportTransition(
            .gateway,
            to: label?.rawValue,
            stable: label == nil ? [:] : self.context.stableMetadata,
            volatile: label == nil ? [:] : volatile.metadata)
    }

    /// Reports `connecting` (before the WebSocket task is created).
    public func connecting(backoffMs: Int? = nil) {
        self.report(.connecting, volatile: .init(backoffMs: backoffMs))
    }

    /// Reports `authenticating` (after the connect challenge nonce arrived).
    public func authenticating() {
        self.report(.authenticating)
    }

    /// Reports `connected` (after `hello-ok` was handled).
    /// - Parameters:
    ///   - pendingRequests: Pending request count.
    ///   - lastSeq: Last event sequence.
    public func connected(pendingRequests: Int? = nil, lastSeq: Int? = nil) {
        self.report(.connected, volatile: .init(pendingRequests: pendingRequests, lastSeq: lastSeq))
    }

    /// Reports `reconnecting` (receive failure or missed tick).
    /// - Parameters:
    ///   - backoffMs: Reconnect backoff.
    ///   - pendingRequests: Pending request count.
    ///   - problemKind: Optional connection problem classification.
    public func reconnecting(backoffMs: Int?, pendingRequests: Int? = nil, problemKind: String? = nil) {
        self.report(
            .reconnecting,
            volatile: .init(backoffMs: backoffMs, pendingRequests: pendingRequests, problemKind: problemKind))
    }

    /// Reports `authPaused` (reconnect paused after a non-recoverable auth failure).
    /// - Parameter authDetailCode: `GatewayConnectAuthError.detailCodeRaw`.
    public func authPaused(authDetailCode: String?) {
        self.report(.authPaused, volatile: .init(authDetailCode: authDetailCode))
    }

    /// Reports a volatile update for the current state (tick, pending request count, sequence).
    /// - Parameter volatile: Volatile details.
    public func update(_ volatile: OpenClawGatewayVolatileState) {
        self.reporter.reportVolatileUpdate(.gateway, volatile.metadata)
    }

    /// Reports that the channel shut down (no active state).
    public func disconnected() {
        self.report(nil)
    }
}

/// Reports node-role invoke execution on ``OpenClawStateDomain/nodeInvoke``.
public struct OpenClawNodeInvokeStateReporter: Sendable {
    /// Destination reporter.
    public let reporter: any OpenClawSystemStateReporting

    /// Creates a node-invoke state reporter.
    /// - Parameter reporter: Destination reporter; `nil` uses ``OpenClawSystemState/shared``.
    public init(reporter: (any OpenClawSystemStateReporting)? = nil) {
        self.reporter = OpenClawSystemState.resolve(reporter)
    }

    /// Reports that a `node.invoke.request` started executing.
    /// - Parameters:
    ///   - command: Node command name (for example `camera.snap`).
    ///   - invokeId: Gateway invoke id.
    public func invoking(command: String, invokeId: String) {
        self.reporter.reportTransition(
            .nodeInvoke,
            to: "invoking",
            stable: ["command": .string(command), "invokeId": .string(invokeId)],
            volatile: [:])
    }

    /// Reports the invoke outcome, then clears the state once the result was sent.
    /// - Parameter ok: Whether the invoke succeeded.
    public func finished(ok: Bool) {
        self.reporter.reportVolatileUpdate(.nodeInvoke, ["ok": .bool(ok)])
        self.reporter.reportTransition(.nodeInvoke, to: nil, stable: [:], volatile: [:])
    }
}

/// Talk-mode states reported on ``OpenClawStateDomain/talk``.
public enum OpenClawTalkStateLabel: String, Sendable, CaseIterable {
    /// Capturing user speech.
    case listening
    /// Waiting for the agent reply.
    case thinking
    /// Playing the agent reply.
    case speaking
}

/// Reports talk mode on ``OpenClawStateDomain/talk``.
public struct OpenClawTalkStateReporter: Sendable {
    /// Destination reporter.
    public let reporter: any OpenClawSystemStateReporting

    /// Creates a talk state reporter.
    /// - Parameter reporter: Destination reporter; `nil` uses ``OpenClawSystemState/shared``.
    public init(reporter: (any OpenClawSystemStateReporting)? = nil) {
        self.reporter = OpenClawSystemState.resolve(reporter)
    }

    /// Reports a talk state.
    /// - Parameters:
    ///   - label: New state, or `nil` when talk is idle.
    ///   - provider: Optional speech provider id (for example `system`, `elevenlabs`).
    public func report(_ label: OpenClawTalkStateLabel?, provider: String? = nil) {
        var stable: OpenClawStateMetadata = [:]
        if label != nil, let provider, !provider.isEmpty {
            stable["provider"] = .string(provider)
        }
        self.reporter.reportTransition(.talk, to: label?.rawValue, stable: stable, volatile: [:])
    }

    /// Reports `listening`.
    public func listening() { self.report(.listening) }

    /// Reports `thinking`.
    public func thinking() { self.report(.thinking) }

    /// Reports `speaking`.
    /// - Parameter provider: Optional speech provider id.
    public func speaking(provider: String? = nil) { self.report(.speaking, provider: provider) }

    /// Reports that talk is idle (speech finished or cancelled).
    public func idle() { self.report(nil) }
}
