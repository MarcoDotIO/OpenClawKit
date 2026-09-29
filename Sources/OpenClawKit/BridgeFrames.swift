import Foundation

/// Legacy TCP bridge frame (retired upstream); scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Legacy TCP bridge frame; nodes use the gateway WebSocket protocol")
public struct BridgeBaseFrame: Codable, Sendable {
    public let type: String

    public init(type: String) {
        self.type = type
    }
}

/// Node command invocation delivered to host handlers (from a `node.invoke.request` event).
public struct BridgeInvokeRequest: Codable, Sendable {
    /// Frame type (`invoke`).
    public let type: String
    /// Invocation identifier echoed in the response.
    public let id: String
    /// Node command name, for example `camera.snap`.
    public let command: String
    /// JSON-encoded command params.
    public let paramsJSON: String?
    /// Target node identifier.
    public let nodeId: String?
    /// Session that triggered the invoke.
    public let sessionKey: String?
    /// Invoke timeout in milliseconds.
    public let timeoutMs: Int?
    /// Idempotency key for deduplicating retried invokes.
    public let idempotencyKey: String?

    /// Creates an invoke request.
    public init(
        type: String = "invoke",
        id: String,
        command: String,
        paramsJSON: String? = nil,
        nodeId: String? = nil,
        sessionKey: String? = nil,
        timeoutMs: Int? = nil,
        idempotencyKey: String? = nil)
    {
        self.type = type
        self.id = id
        self.command = command
        self.paramsJSON = paramsJSON
        self.nodeId = nodeId
        self.sessionKey = sessionKey
        self.timeoutMs = timeoutMs
        self.idempotencyKey = idempotencyKey
    }
}

/// Host handler result for a ``BridgeInvokeRequest``.
public struct BridgeInvokeResponse: Codable, Sendable {
    /// Frame type (`invoke-res`).
    public let type: String
    /// Invocation identifier from the request.
    public let id: String
    /// Whether the command succeeded.
    public let ok: Bool
    /// Structured result payload (preferred over ``payloadJSON`` when both are set).
    public let payload: AnyCodable?
    /// JSON-encoded result payload.
    public let payloadJSON: String?
    /// Error when ``ok`` is `false`.
    public let error: OpenClawNodeError?

    /// Creates an invoke response.
    public init(
        type: String = "invoke-res",
        id: String,
        ok: Bool,
        payload: AnyCodable? = nil,
        payloadJSON: String? = nil,
        error: OpenClawNodeError? = nil)
    {
        self.type = type
        self.id = id
        self.ok = ok
        self.payload = payload
        self.payloadJSON = payloadJSON
        self.error = error
    }
}

/// Legacy TCP bridge frame (retired upstream); scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Legacy TCP bridge frame; nodes use the gateway WebSocket protocol")
public struct BridgeEventFrame: Codable, Sendable {
    public let type: String
    public let event: String
    public let payloadJSON: String?

    public init(type: String = "event", event: String, payloadJSON: String? = nil) {
        self.type = type
        self.event = event
        self.payloadJSON = payloadJSON
    }
}

/// Legacy TCP bridge frame (retired upstream); scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Legacy TCP bridge frame; nodes use the gateway WebSocket protocol")
public struct BridgeHello: Codable, Sendable {
    public let type: String
    public let nodeId: String
    public let displayName: String?
    public let token: String?
    public let platform: String?
    public let version: String?
    public let coreVersion: String?
    public let uiVersion: String?
    public let deviceFamily: String?
    public let modelIdentifier: String?
    public let caps: [String]?
    public let commands: [String]?
    public let permissions: [String: Bool]?

    public init(
        type: String = "hello",
        nodeId: String,
        displayName: String?,
        token: String?,
        platform: String?,
        version: String?,
        coreVersion: String? = nil,
        uiVersion: String? = nil,
        deviceFamily: String? = nil,
        modelIdentifier: String? = nil,
        caps: [String]? = nil,
        commands: [String]? = nil,
        permissions: [String: Bool]? = nil)
    {
        self.type = type
        self.nodeId = nodeId
        self.displayName = displayName
        self.token = token
        self.platform = platform
        self.version = version
        self.coreVersion = coreVersion
        self.uiVersion = uiVersion
        self.deviceFamily = deviceFamily
        self.modelIdentifier = modelIdentifier
        self.caps = caps
        self.commands = commands
        self.permissions = permissions
    }
}

/// Legacy TCP bridge frame (retired upstream); scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Legacy TCP bridge frame; nodes use the gateway WebSocket protocol")
public struct BridgeHelloOk: Codable, Sendable {
    public let type: String
    public let serverName: String
    /// Removed upstream with protocol v4 plugin surfaces; still decoded (optional) for old frames.
    @available(
        *,
        deprecated,
        message: "Removed upstream; use hello-ok pluginSurfaceUrls (GatewayNodeSession.pluginSurfaceURL(\"canvas\"))")
    public let canvasHostUrl: String?
    public let mainSessionKey: String?

    public init(
        type: String = "hello-ok",
        serverName: String,
        canvasHostUrl: String? = nil,
        mainSessionKey: String? = nil)
    {
        self.type = type
        self.serverName = serverName
        self.canvasHostUrl = canvasHostUrl
        self.mainSessionKey = mainSessionKey
    }
}

/// Legacy TCP bridge frame (retired upstream); scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Legacy TCP bridge frame; nodes use the gateway WebSocket protocol")
public struct BridgePairRequest: Codable, Sendable {
    public let type: String
    public let nodeId: String
    public let displayName: String?
    public let platform: String?
    public let version: String?
    public let coreVersion: String?
    public let uiVersion: String?
    public let deviceFamily: String?
    public let modelIdentifier: String?
    public let caps: [String]?
    public let commands: [String]?
    public let permissions: [String: Bool]?
    public let remoteAddress: String?
    public let silent: Bool?

    public init(
        type: String = "pair-request",
        nodeId: String,
        displayName: String?,
        platform: String?,
        version: String?,
        coreVersion: String? = nil,
        uiVersion: String? = nil,
        deviceFamily: String? = nil,
        modelIdentifier: String? = nil,
        caps: [String]? = nil,
        commands: [String]? = nil,
        permissions: [String: Bool]? = nil,
        remoteAddress: String? = nil,
        silent: Bool? = nil)
    {
        self.type = type
        self.nodeId = nodeId
        self.displayName = displayName
        self.platform = platform
        self.version = version
        self.coreVersion = coreVersion
        self.uiVersion = uiVersion
        self.deviceFamily = deviceFamily
        self.modelIdentifier = modelIdentifier
        self.caps = caps
        self.commands = commands
        self.permissions = permissions
        self.remoteAddress = remoteAddress
        self.silent = silent
    }
}

/// Legacy TCP bridge frame (retired upstream); scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Legacy TCP bridge frame; nodes use the gateway WebSocket protocol")
public struct BridgePairOk: Codable, Sendable {
    public let type: String
    public let token: String

    public init(type: String = "pair-ok", token: String) {
        self.type = type
        self.token = token
    }
}

/// Legacy TCP bridge frame (retired upstream); scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Legacy TCP bridge frame; nodes use the gateway WebSocket protocol")
public struct BridgePing: Codable, Sendable {
    public let type: String
    public let id: String

    public init(type: String = "ping", id: String) {
        self.type = type
        self.id = id
    }
}

/// Legacy TCP bridge frame (retired upstream); scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Legacy TCP bridge frame; nodes use the gateway WebSocket protocol")
public struct BridgePong: Codable, Sendable {
    public let type: String
    public let id: String

    public init(type: String = "pong", id: String) {
        self.type = type
        self.id = id
    }
}

/// Legacy TCP bridge frame (retired upstream); scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Legacy TCP bridge frame; nodes use the gateway WebSocket protocol")
public struct BridgeErrorFrame: Codable, Sendable {
    public let type: String
    public let code: String
    public let message: String

    public init(type: String = "error", code: String, message: String) {
        self.type = type
        self.code = code
        self.message = message
    }
}

// MARK: - Optional RPC (node -> bridge)

/// Legacy TCP bridge frame (retired upstream); scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Legacy TCP bridge frame; nodes use the gateway WebSocket protocol")
public struct BridgeRPCRequest: Codable, Sendable {
    public let type: String
    public let id: String
    public let method: String
    public let paramsJSON: String?

    public init(type: String = "req", id: String, method: String, paramsJSON: String? = nil) {
        self.type = type
        self.id = id
        self.method = method
        self.paramsJSON = paramsJSON
    }
}

/// Legacy TCP bridge frame (retired upstream); scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Legacy TCP bridge frame; nodes use the gateway WebSocket protocol")
public struct BridgeRPCError: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Legacy TCP bridge frame (retired upstream); scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Legacy TCP bridge frame; nodes use the gateway WebSocket protocol")
public struct BridgeRPCResponse: Codable, Sendable {
    public let type: String
    public let id: String
    public let ok: Bool
    public let payloadJSON: String?
    public let error: BridgeRPCError?

    public init(
        type: String = "res",
        id: String,
        ok: Bool,
        payloadJSON: String? = nil,
        error: BridgeRPCError? = nil)
    {
        self.type = type
        self.id = id
        self.ok = ok
        self.payloadJSON = payloadJSON
        self.error = error
    }
}
