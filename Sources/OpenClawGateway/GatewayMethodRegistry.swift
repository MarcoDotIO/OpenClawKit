import Foundation
import OpenClawCore
import OpenClawProtocol

/// Handler for one gateway method registered on ``GatewayServer``.
///
/// Return the response payload (`nil` answers `ok: true` without a payload). Throw
/// ``GatewayMethodError`` to choose the wire error code; `OpenClawCoreError.invalidConfiguration`
/// and `DecodingError` map to `INVALID_REQUEST`, every other error maps to `UNAVAILABLE`.
public typealias GatewayMethodHandler = @Sendable (GatewayMethodRequest) async throws -> AnyCodable?

/// Resolves a handler for a method name that has no static registration.
///
/// Resolvers run after registered handlers and before the catalog fallback, which lets modules
/// such as plugin registries serve dynamically registered methods. Return `nil` to pass.
public typealias GatewayMethodResolver = @Sendable (_ method: String) async -> GatewayMethodHandler?

/// Identity and grants of the client connection a gateway request arrived on.
public struct GatewayConnectionContext: Sendable, Equatable {
    /// Upstream operator scope that implies every other operator scope.
    public static let operatorAdminScope = "operator.admin"
    /// Upstream read scope.
    public static let operatorReadScope = "operator.read"
    /// Upstream write scope (implies read, talk and session read/write).
    public static let operatorWriteScope = "operator.write"

    /// Stable connection identifier (upstream `connId`).
    public var connectionID: String
    /// Connection role, `operator` or `node`.
    public var role: String
    /// Granted scopes (for example `operator.read`, `operator.admin`).
    public var scopes: [String]
    /// Client id from connect `client.id` (see ``GatewayClientID``).
    public var clientID: String?
    /// Client mode from connect `client.mode` (see ``GatewayClientMode``).
    public var clientMode: String?
    /// Client version from connect `client.version`.
    public var clientVersion: String?
    /// Client platform from connect `client.platform`.
    public var platform: String?
    /// Human-readable client name from connect `client.displayName`.
    public var displayName: String?
    /// Per-installation client instance id.
    public var instanceID: String?
    /// Paired device id when the connection presented a signed device identity.
    public var deviceID: String?

    /// Creates a connection context.
    /// - Parameters:
    ///   - connectionID: Stable connection identifier.
    ///   - role: Connection role (`operator` or `node`).
    ///   - scopes: Granted scopes.
    ///   - clientID: Client id.
    ///   - clientMode: Client mode.
    ///   - clientVersion: Client version.
    ///   - platform: Client platform.
    ///   - displayName: Human-readable client name.
    ///   - instanceID: Client instance id.
    ///   - deviceID: Paired device id.
    public init(
        connectionID: String = UUID().uuidString,
        role: String = "operator",
        scopes: [String] = [],
        clientID: String? = nil,
        clientMode: String? = nil,
        clientVersion: String? = nil,
        platform: String? = nil,
        displayName: String? = nil,
        instanceID: String? = nil,
        deviceID: String? = nil
    ) {
        self.connectionID = connectionID
        self.role = role
        self.scopes = scopes
        self.clientID = clientID
        self.clientMode = clientMode
        self.clientVersion = clientVersion
        self.platform = platform
        self.displayName = displayName
        self.instanceID = instanceID
        self.deviceID = deviceID
    }

    /// Creates a context from upstream connect params.
    /// - Parameters:
    ///   - connect: Decoded `connect` request params.
    ///   - connectionID: Stable connection identifier.
    ///   - deviceID: Verified device id, when the device signature was checked.
    public init(connect: ConnectParams, connectionID: String = UUID().uuidString, deviceID: String? = nil) {
        self.init(
            connectionID: connectionID,
            role: connect.role ?? "operator",
            scopes: connect.scopes ?? [],
            clientID: connect.client["id"]?.stringValue,
            clientMode: connect.client["mode"]?.stringValue,
            clientVersion: connect.client["version"]?.stringValue,
            platform: connect.client["platform"]?.stringValue,
            displayName: connect.client["displayName"]?.stringValue,
            instanceID: connect.client["instanceId"]?.stringValue,
            deviceID: deviceID
        )
    }

    /// Trusted in-process caller with full operator grants (the default for ``GatewayServer/handle(_:)``).
    public static let inProcess = GatewayConnectionContext(
        connectionID: "in-process",
        role: "operator",
        scopes: [Self.operatorAdminScope],
        clientID: GatewayClientID.gatewayClient.rawValue,
        clientMode: GatewayClientMode.backend.rawValue
    )

    /// Returns whether this connection satisfies a method scope from ``GatewayMethodDescriptor/scope``.
    ///
    /// Mirrors upstream `operatorScopeSatisfied`: `operator.admin` implies every operator scope and
    /// `operator.write` implies read, talk and session read/write. `node` requires the node role and
    /// `dynamic` is resolved by the handler itself.
    /// - Parameter scope: Required scope.
    /// - Returns: `true` when the connection may call a method with that scope.
    public func allows(scope: String) -> Bool {
        let required = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        switch required {
        case "", "dynamic":
            return true
        case "node":
            return self.role == "node"
        default:
            break
        }
        let granted = Set(self.scopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard required.hasPrefix("operator.") else {
            return granted.contains(required)
        }
        guard self.role == "operator" else {
            return false
        }
        if granted.contains(required) || granted.contains(Self.operatorAdminScope) {
            return true
        }
        let writeImplied: Set<String> = [
            Self.operatorReadScope,
            "operator.talk",
            "operator.sessions.read",
            "operator.sessions.write",
        ]
        if writeImplied.contains(required), granted.contains(Self.operatorWriteScope) {
            return true
        }
        if required == "operator.sessions.read",
           granted.contains(Self.operatorReadScope) || granted.contains("operator.sessions.write")
        {
            return true
        }
        return false
    }
}

/// Emits server-to-client events from inside a gateway method handler.
public struct GatewayEventEmitter: Sendable {
    private let sink: @Sendable (_ event: String, _ payload: AnyCodable?) async -> Void

    /// Creates an emitter that forwards to a sink.
    /// - Parameter sink: Receives each event name and payload.
    public init(_ sink: @escaping @Sendable (_ event: String, _ payload: AnyCodable?) async -> Void) {
        self.sink = sink
    }

    /// Emitter that drops every event.
    public static let discard = GatewayEventEmitter { _, _ in }

    /// Emits an event by wire name.
    /// - Parameters:
    ///   - event: Event name (see ``GatewayEventName`` for upstream names).
    ///   - payload: Optional event payload.
    public func emit(_ event: String, payload: AnyCodable? = nil) async {
        await self.sink(event, payload)
    }

    /// Emits an upstream event.
    /// - Parameters:
    ///   - event: Upstream event name.
    ///   - payload: Optional event payload.
    public func emit(_ event: GatewayEventName, payload: AnyCodable? = nil) async {
        await self.sink(event.rawValue, payload)
    }

    /// Emits an event with a typed payload.
    /// - Parameters:
    ///   - event: Event name.
    ///   - payload: Encodable payload, JSON-encoded into the event frame.
    /// - Throws: Encoding errors for the payload.
    public func emit(_ event: String, encoding payload: some Encodable) async throws {
        await self.sink(event, try AnyCodable(encoding: payload))
    }
}

/// Context passed to a ``GatewayMethodHandler``.
public struct GatewayMethodRequest: Sendable {
    /// Request frame id.
    public let id: String
    /// Wire method name.
    public let method: String
    /// Raw request params exactly as received (`nil` when the frame omitted them).
    public let rawParams: AnyCodable?
    /// Catalog or registration descriptor for the method, when one exists.
    public let descriptor: GatewayMethodDescriptor?
    /// Connection the request arrived on.
    public let connection: GatewayConnectionContext
    /// Event hook for server-to-client events emitted while handling the request.
    public let events: GatewayEventEmitter

    /// Creates a request context (useful for unit-testing handlers directly).
    /// - Parameters:
    ///   - id: Request frame id.
    ///   - method: Wire method name.
    ///   - rawParams: Raw request params.
    ///   - descriptor: Method descriptor.
    ///   - connection: Connection context.
    ///   - events: Event emitter.
    public init(
        id: String = UUID().uuidString,
        method: String,
        rawParams: AnyCodable? = nil,
        descriptor: GatewayMethodDescriptor? = nil,
        connection: GatewayConnectionContext = .inProcess,
        events: GatewayEventEmitter = .discard
    ) {
        self.id = id
        self.method = method
        self.rawParams = rawParams
        self.descriptor = descriptor
        self.connection = connection
        self.events = events
    }

    /// Request params as a JSON object (empty when params are absent, `null`, or not an object).
    public var params: [String: AnyCodable] {
        self.rawParams?.dictionaryValue ?? [:]
    }

    /// Decodes the params into a typed model.
    /// - Parameter type: Target params type.
    /// - Returns: Decoded params.
    /// - Throws: ``GatewayMethodError`` with `INVALID_REQUEST` when the params do not decode.
    public func decodeParams<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        do {
            return try GatewayPayloadCodec.decode(type, from: self.rawParams)
        } catch {
            throw GatewayMethodError.invalidParams(method: self.method, underlying: error)
        }
    }

    /// Returns the first non-empty string param among `keys` (for upstream/legacy key aliases).
    /// - Parameter keys: Candidate keys in priority order.
    /// - Returns: The trimmed string value, or `nil`.
    public func stringParam(_ keys: String...) -> String? {
        let params = self.params
        for key in keys {
            if let value = params[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

/// Typed gateway error that maps onto an upstream `ErrorShape`.
public struct GatewayMethodError: Error, LocalizedError, Sendable, Equatable {
    /// Upstream error code.
    public let code: ErrorCode
    /// Human-readable message.
    public let message: String
    /// Structured details (see `GatewayErrorDetails`).
    public let details: AnyCodable?
    /// Whether the caller may retry.
    public let retryable: Bool?
    /// Suggested retry delay in milliseconds.
    public let retryAfterMs: Int?

    /// Creates a typed gateway error.
    /// - Parameters:
    ///   - code: Upstream error code.
    ///   - message: Human-readable message.
    ///   - details: Structured details.
    ///   - retryable: Whether the caller may retry.
    ///   - retryAfterMs: Suggested retry delay in milliseconds.
    public init(
        code: ErrorCode,
        message: String,
        details: AnyCodable? = nil,
        retryable: Bool? = nil,
        retryAfterMs: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.details = details
        self.retryable = retryable
        self.retryAfterMs = retryAfterMs
    }

    /// Wire representation of the error.
    public var errorShape: ErrorShape {
        ErrorShape(
            code: self.code.rawValue,
            message: self.message,
            details: self.details,
            retryable: self.retryable,
            retryafterms: self.retryAfterMs
        )
    }

    /// Localized description (the error message).
    public var errorDescription: String? {
        self.message
    }

    /// `INVALID_REQUEST`: the payload failed validation or method preconditions.
    /// - Parameters:
    ///   - message: Human-readable message.
    ///   - details: Structured details.
    /// - Returns: Typed error.
    public static func invalidRequest(_ message: String, details: AnyCodable? = nil) -> GatewayMethodError {
        GatewayMethodError(code: .invalidRequest, message: message, details: details)
    }

    /// `INVALID_REQUEST` for params that do not decode into the method's params model.
    /// - Parameters:
    ///   - method: Wire method name.
    ///   - underlying: Decoding error.
    /// - Returns: Typed error.
    public static func invalidParams(method: String, underlying: Error) -> GatewayMethodError {
        GatewayMethodError(code: .invalidRequest, message: "invalid \(method) params: \(underlying)")
    }

    /// `UNAVAILABLE`: the method or a dependency is not available right now.
    /// - Parameters:
    ///   - message: Human-readable message.
    ///   - retryable: Whether the caller may retry.
    ///   - retryAfterMs: Suggested retry delay in milliseconds.
    ///   - details: Structured details.
    /// - Returns: Typed error.
    public static func unavailable(
        _ message: String,
        retryable: Bool? = nil,
        retryAfterMs: Int? = nil,
        details: AnyCodable? = nil
    ) -> GatewayMethodError {
        GatewayMethodError(code: .unavailable, message: message, details: details, retryable: retryable, retryAfterMs: retryAfterMs)
    }

    /// `FORBIDDEN`: the caller lacks permission for the operation.
    /// - Parameters:
    ///   - message: Human-readable message.
    ///   - details: Structured details.
    /// - Returns: Typed error.
    public static func forbidden(_ message: String, details: AnyCodable? = nil) -> GatewayMethodError {
        GatewayMethodError(code: .forbidden, message: message, details: details)
    }

    /// `FORBIDDEN` with upstream `MISSING_SCOPE` details.
    /// - Parameters:
    ///   - scope: Missing scope.
    ///   - requiredScopes: Scopes the method requires (defaults to `[scope]`).
    /// - Returns: Typed error.
    public static func missingScope(_ scope: String, requiredScopes: [String] = []) -> GatewayMethodError {
        let required = requiredScopes.isEmpty ? [scope] : requiredScopes
        let details = AnyCodable([
            "code": AnyCodable("MISSING_SCOPE"),
            "missingScope": AnyCodable(scope),
            "requiredScopes": AnyCodable(required.map(AnyCodable.init)),
        ])
        return GatewayMethodError(code: .forbidden, message: "missing scope: \(scope)", details: details)
    }

    /// `NOT_PAIRED`: the device still needs pairing approval.
    /// - Parameter message: Human-readable message.
    /// - Returns: Typed error.
    public static func notPaired(_ message: String) -> GatewayMethodError {
        GatewayMethodError(code: .notPaired, message: message)
    }

    /// `APPROVAL_NOT_FOUND`: an approval resolution referenced a missing or expired approval.
    /// - Parameter message: Human-readable message.
    /// - Returns: Typed error.
    public static func approvalNotFound(_ message: String) -> GatewayMethodError {
        GatewayMethodError(code: .approvalNotFound, message: message)
    }

    /// Maps any error thrown by a handler onto its wire shape.
    /// - Parameter error: Thrown error.
    /// - Returns: Wire error shape.
    public static func errorShape(for error: Error) -> ErrorShape {
        switch error {
        case let error as GatewayMethodError:
            return error.errorShape
        case let error as OpenClawCoreError:
            switch error {
            case .invalidConfiguration:
                return GatewayMethodError.invalidRequest(error.localizedDescription).errorShape
            case .unavailable:
                return GatewayMethodError.unavailable(error.localizedDescription).errorShape
            }
        case is DecodingError:
            return GatewayMethodError.invalidRequest("invalid params: \(error)").errorShape
        default:
            return GatewayMethodError.unavailable(error.localizedDescription).errorShape
        }
    }
}

/// Anything that accepts gateway method registrations; ``GatewayServer`` conforms.
///
/// Feature modules expose `register…GatewayMethods(on:)` functions against this protocol so they do
/// not depend on a concrete server:
/// ```swift
/// public func registerSkillGatewayMethods(on registrar: some GatewayMethodRegistrar) async {
///     await registrar.register(method: "skills.status") { request in
///         AnyCodable(["skills": AnyCodable([AnyCodable]())])
///     }
/// }
/// ```
public protocol GatewayMethodRegistrar: Sendable {
    /// Registers (or replaces) the handler for `method`.
    /// - Parameters:
    ///   - method: Wire method name.
    ///   - descriptor: Metadata for the method; `nil` uses the upstream catalog descriptor when the
    ///     method is a core method, otherwise the method is treated as unscoped.
    ///   - handler: Handler invoked for each request.
    func register(method: String, descriptor: GatewayMethodDescriptor?, handler: @escaping GatewayMethodHandler) async
}

public extension GatewayMethodRegistrar {
    /// Registers (or replaces) the handler for `method` using the catalog descriptor, if any.
    /// - Parameters:
    ///   - method: Wire method name.
    ///   - handler: Handler invoked for each request.
    func register(method: String, handler: @escaping GatewayMethodHandler) async {
        await self.register(method: method, descriptor: nil, handler: handler)
    }

    /// Registers a handler with typed params and a typed response.
    ///
    /// Params that fail to decode are rejected with `INVALID_REQUEST` before `handler` runs.
    /// - Parameters:
    ///   - method: Wire method name.
    ///   - descriptor: Optional method metadata.
    ///   - params: Params type to decode.
    ///   - handler: Handler receiving decoded params and the request context.
    func register<Params: Decodable & Sendable, Response: Encodable & Sendable>(
        method: String,
        descriptor: GatewayMethodDescriptor? = nil,
        params: Params.Type,
        handler: @escaping @Sendable (Params, GatewayMethodRequest) async throws -> Response
    ) async {
        await self.register(method: method, descriptor: descriptor) { request in
            let decoded = try request.decodeParams(Params.self)
            let response = try await handler(decoded, request)
            return try GatewayPayloadCodec.encode(response)
        }
    }
}
