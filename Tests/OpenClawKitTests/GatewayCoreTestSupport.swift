import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

// In-memory WebSocket transport for gateway channel and node session tests. It scripts
// `connect.challenge`, the connect reply, and request replies without any networking.

extension NSLock {
    fileprivate func gatewayCoreWithLock<T>(_ body: () -> T) -> T {
        self.lock()
        defer { self.unlock() }
        return body()
    }
}

enum GatewayCoreJSON {
    static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func object(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data? = switch message {
        case let .data(data): data
        case let .string(text): text.data(using: .utf8)
        @unknown default: nil
        }
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum GatewayCoreFrames {
    static let challengeTimestampMs: Int64 = 1_800_000_000_000

    static func challenge(nonce: String = "nonce-1", ts: Any? = GatewayCoreFrames.challengeTimestampMs) -> [String: Any] {
        var payload: [String: Any] = ["nonce": nonce]
        if let ts { payload["ts"] = ts }
        return ["type": "event", "event": "connect.challenge", "payload": payload]
    }

    static func hello(
        protocolVersion: Int = 4,
        auth: [String: Any] = [:],
        methods: [String]? = [],
        capabilities: [String] = [],
        policy: [String: Any] = ["maxPayload": 26_214_400, "maxBufferedBytes": 52_428_800, "tickIntervalMs": 30000],
        pluginSurfaceUrls: [String: Any]? = nil,
        sessionDefaults: [String: Any]? = nil,
        snapshotOverride: [String: Any]? = nil) -> [String: Any]
    {
        var features: [String: Any] = ["events": [], "capabilities": capabilities]
        if let methods { features["methods"] = methods }
        var snapshot: [String: Any] = snapshotOverride ?? [
            "presence": [["ts": 1]],
            "health": [:],
            "stateVersion": ["presence": 0, "health": 0],
            "uptimeMs": 0,
        ]
        if let sessionDefaults { snapshot["sessionDefaults"] = sessionDefaults }
        var payload: [String: Any] = [
            "type": "hello-ok",
            "protocol": protocolVersion,
            "server": ["version": "test", "connId": "test"],
            "features": features,
            "snapshot": snapshot,
            "policy": policy,
            "auth": auth,
        ]
        if let pluginSurfaceUrls { payload["pluginSurfaceUrls"] = pluginSurfaceUrls }
        return payload
    }

    static func error(
        code: String,
        message: String,
        details: [String: Any]? = nil,
        retryable: Bool? = nil,
        retryAfterMs: Int? = nil) -> [String: Any]
    {
        var error: [String: Any] = ["code": code, "message": message]
        if let details { error["details"] = details }
        if let retryable { error["retryable"] = retryable }
        if let retryAfterMs { error["retryAfterMs"] = retryAfterMs }
        return error
    }

    static func startupUnavailable(retryAfterMs: Int = 100) -> [String: Any] {
        self.error(
            code: "UNAVAILABLE",
            message: "gateway starting",
            details: ["reason": "startup-sidecars"],
            retryable: true,
            retryAfterMs: retryAfterMs)
    }

    static func event(_ name: String, payload: [String: Any]? = nil, seq: Int? = nil) -> [String: Any] {
        var frame: [String: Any] = ["type": "event", "event": name]
        if let payload { frame["payload"] = payload }
        if let seq { frame["seq"] = seq }
        return frame
    }
}

/// How the fake gateway answers one request.
enum GatewayCoreReply {
    /// `{ok: true, payload}`.
    case ok([String: Any])
    /// `{ok: false, error}`.
    case error([String: Any])
    /// No reply (the request stays pending).
    case none
}

/// Script for one fake socket.
struct GatewayCoreSocketScript: @unchecked Sendable {
    enum PingBehavior {
        case immediate
        case never
        case duplicateSuccess
    }

    var challenge: [String: Any]? = GatewayCoreFrames.challenge()
    var connectReply: @Sendable ([String: Any]) -> GatewayCoreReply = { _ in .ok(GatewayCoreFrames.hello()) }
    var requestReply: @Sendable (String, [String: Any]) -> GatewayCoreReply = { _, _ in .ok([:]) }
    var pingBehavior: PingBehavior = .immediate
}

final class GatewayCoreFakeSocket: WebSocketTasking, @unchecked Sendable {
    typealias Message = URLSessionWebSocketTask.Message

    private let lock = NSLock()
    private let script: GatewayCoreSocketScript
    private var _state: URLSessionTask.State = .suspended
    private var closed = false
    private var inbound: [Result<Message, Error>] = []
    private var asyncWaiters: [CheckedContinuation<Message, Error>] = []
    private var callbackWaiter: (@Sendable (Result<Message, Error>) -> Void)?
    private var sent: [[String: Any]] = []
    private var _closeCode: URLSessionWebSocketTask.CloseCode?
    private var _pingCount = 0

    init(script: GatewayCoreSocketScript) {
        self.script = script
    }

    var state: URLSessionTask.State {
        self.lock.gatewayCoreWithLock { self._state }
    }

    var closeCode: URLSessionWebSocketTask.CloseCode? {
        self.lock.gatewayCoreWithLock { self._closeCode }
    }

    var pingCount: Int {
        self.lock.gatewayCoreWithLock { self._pingCount }
    }

    func resume() {
        self.lock.gatewayCoreWithLock { self._state = .running }
        if let challenge = self.script.challenge {
            self.emit(challenge)
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        _ = reason
        let (waiters, callback) = self.lock.gatewayCoreWithLock { () -> (
            [CheckedContinuation<Message, Error>],
            (@Sendable (Result<Message, Error>) -> Void)?)
            in
            if self._closeCode == nil { self._closeCode = closeCode }
            self._state = .canceling
            self.closed = true
            let waiters = self.asyncWaiters
            self.asyncWaiters.removeAll()
            let callback = self.callbackWaiter
            self.callbackWaiter = nil
            return (waiters, callback)
        }
        for waiter in waiters {
            waiter.resume(throwing: URLError(.cancelled))
        }
        callback?(.failure(URLError(.cancelled)))
    }

    func send(_ message: Message) async throws {
        guard let frame = GatewayCoreJSON.object(message) else { return }
        let isClosed = self.lock.gatewayCoreWithLock { () -> Bool in
            self.sent.append(frame)
            return self.closed
        }
        if isClosed { throw URLError(.networkConnectionLost) }
        guard frame["type"] as? String == "req",
              let id = frame["id"] as? String,
              let method = frame["method"] as? String
        else { return }
        let params = frame["params"] as? [String: Any] ?? [:]
        let reply = method == "connect" ? self.script.connectReply(params) : self.script.requestReply(method, params)
        self.respond(id: id, reply: reply)
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        self.lock.gatewayCoreWithLock { self._pingCount += 1 }
        switch self.script.pingBehavior {
        case .immediate:
            pongReceiveHandler(nil)
        case .never:
            break
        case .duplicateSuccess:
            pongReceiveHandler(nil)
            pongReceiveHandler(nil)
        }
    }

    func receive() async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = self.lock.gatewayCoreWithLock { () -> Result<Message, Error>? in
                if !self.inbound.isEmpty { return self.inbound.removeFirst() }
                if self.closed { return .failure(URLError(.cancelled)) }
                self.asyncWaiters.append(continuation)
                return nil
            }
            if let immediate {
                continuation.resume(with: immediate)
            }
        }
    }

    func receive(completionHandler: @escaping @Sendable (Result<Message, Error>) -> Void) {
        let immediate = self.lock.gatewayCoreWithLock { () -> Result<Message, Error>? in
            if !self.inbound.isEmpty { return self.inbound.removeFirst() }
            if self.closed { return .failure(URLError(.cancelled)) }
            self.callbackWaiter = completionHandler
            return nil
        }
        if let immediate {
            completionHandler(immediate)
        }
    }

    // MARK: Test controls

    func respond(id: String, reply: GatewayCoreReply) {
        switch reply {
        case let .ok(payload):
            self.emit(["type": "res", "id": id, "ok": true, "payload": payload])
        case let .error(error):
            self.emit(["type": "res", "id": id, "ok": false, "error": error])
        case .none:
            break
        }
    }

    func emit(_ frame: [String: Any]) {
        self.deliver(.success(.data(GatewayCoreJSON.data(frame))))
    }

    func emitReceiveFailure(_ error: Error = URLError(.networkConnectionLost)) {
        self.lock.gatewayCoreWithLock { self._state = .canceling }
        self.deliver(.failure(error))
    }

    func sentFrames(method: String) -> [[String: Any]] {
        self.lock.gatewayCoreWithLock {
            self.sent.filter { $0["method"] as? String == method }
        }
    }

    func connectParams() -> [String: Any]? {
        self.sentFrames(method: "connect").last?["params"] as? [String: Any]
    }

    func connectAuth() -> [String: Any]? {
        self.connectParams()?["auth"] as? [String: Any]
    }

    private func deliver(_ result: Result<Message, Error>) {
        let target = self.lock.gatewayCoreWithLock { () -> (
            CheckedContinuation<Message, Error>?,
            (@Sendable (Result<Message, Error>) -> Void)?)
            in
            if !self.asyncWaiters.isEmpty {
                return (self.asyncWaiters.removeFirst(), nil)
            }
            if let callback = self.callbackWaiter {
                self.callbackWaiter = nil
                return (nil, callback)
            }
            self.inbound.append(result)
            return (nil, nil)
        }
        if let continuation = target.0 {
            continuation.resume(with: result)
        } else if let callback = target.1 {
            callback(result)
        }
    }
}

final class GatewayCoreFakeSession: WebSocketSessioning, GatewayTLSRouteMetadataProviding,
    GatewayDeviceTokenRetryTrustProviding, GatewayTLSFailureProviding, @unchecked Sendable
{
    private let lock = NSLock()
    private let scriptProvider: @Sendable (Int) -> GatewayCoreSocketScript
    private var sockets: [GatewayCoreFakeSocket] = []
    private var requests: [URLRequest] = []
    private var pendingTLSFailure: GatewayTLSValidationFailure?
    let effectiveTLSFingerprintSHA256: String?
    let allowsDeviceTokenRetryAuth: Bool

    init(
        tlsFingerprint: String? = nil,
        allowsDeviceTokenRetryAuth: Bool = false,
        script: @escaping @Sendable (Int) -> GatewayCoreSocketScript = { _ in GatewayCoreSocketScript() })
    {
        self.effectiveTLSFingerprintSHA256 = tlsFingerprint
        self.allowsDeviceTokenRetryAuth = allowsDeviceTokenRetryAuth
        self.scriptProvider = script
    }

    convenience init(
        tlsFingerprint: String? = nil,
        allowsDeviceTokenRetryAuth: Bool = false,
        fixedScript: GatewayCoreSocketScript)
    {
        self.init(
            tlsFingerprint: tlsFingerprint,
            allowsDeviceTokenRetryAuth: allowsDeviceTokenRetryAuth,
            script: { _ in fixedScript })
    }

    var makeCount: Int {
        self.lock.gatewayCoreWithLock { self.sockets.count }
    }

    var latestSocket: GatewayCoreFakeSocket? {
        self.lock.gatewayCoreWithLock { self.sockets.last }
    }

    func socket(at index: Int) -> GatewayCoreFakeSocket? {
        self.lock.gatewayCoreWithLock { self.sockets.indices.contains(index) ? self.sockets[index] : nil }
    }

    var latestRequest: URLRequest? {
        self.lock.gatewayCoreWithLock { self.requests.last }
    }

    func setTLSFailure(_ failure: GatewayTLSValidationFailure?) {
        self.lock.gatewayCoreWithLock { self.pendingTLSFailure = failure }
    }

    func consumeLastTLSFailure() -> GatewayTLSValidationFailure? {
        self.lock.gatewayCoreWithLock {
            defer { self.pendingTLSFailure = nil }
            return self.pendingTLSFailure
        }
    }

    func makeWebSocketTask(url: URL) -> WebSocketTaskBox {
        self.makeWebSocketTask(request: URLRequest(url: url))
    }

    func makeWebSocketTask(request: URLRequest) -> WebSocketTaskBox {
        let socket = self.lock.gatewayCoreWithLock { () -> GatewayCoreFakeSocket in
            let socket = GatewayCoreFakeSocket(script: self.scriptProvider(self.sockets.count))
            self.sockets.append(socket)
            self.requests.append(request)
            return socket
        }
        return WebSocketTaskBox(task: socket)
    }
}

/// Records callback values from any isolation domain.
final class GatewayCoreRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        self.lock.gatewayCoreWithLock { self.storage.append(value) }
    }

    var values: [Value] {
        self.lock.gatewayCoreWithLock { self.storage }
    }
}

struct GatewayCoreWaitTimeout: Error, CustomStringConvertible {
    let label: String
    var description: String {
        "Timeout waiting for: \(self.label)"
    }
}

/// Polls `condition` until it holds.
///
/// There is no wall-clock deadline: a saturated test pool must only slow the wait down. Every suite
/// that calls this carries a `.timeLimit`, whose cancellation ends the wait with
/// ``GatewayCoreWaitTimeout``.
func gatewayCoreWaitUntil(
    _ label: String,
    _ condition: @escaping @Sendable () async -> Bool) async throws
{
    while !Task.isCancelled {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    // Swift Testing drops errors thrown after a time-limit cancellation, so record which wait hung.
    let timeout = GatewayCoreWaitTimeout(label: label)
    Issue.record(timeout)
    throw timeout
}

func gatewayCoreTemporaryStateDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("openclaw-gateway-core-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func gatewayCoreOptions(
    role: String = "operator",
    scopes: [String] = ["operator.read"],
    scopesAreExplicit: Bool = false,
    caps: [String] = [],
    clientMode: String? = nil,
    includeDeviceIdentity: Bool = false,
    allowStoredDeviceAuth: Bool = true,
    deviceAuthGatewayID: String? = nil,
    deviceProofPayload: GatewayDeviceProofPayloadVersion = .v2Compatible,
    minimumProtocolVersion: Int? = nil) -> GatewayConnectOptions
{
    GatewayConnectOptions(
        role: role,
        scopes: scopes,
        scopesAreExplicit: scopesAreExplicit,
        caps: caps,
        commands: [],
        permissions: [:],
        clientId: role == "node" ? GatewayClientID.nodeHost.rawValue : GatewayClientID.iosApp.rawValue,
        clientMode: clientMode ?? (role == "node" ? "node" : "ui"),
        clientDisplayName: "Gateway Core Test",
        includeDeviceIdentity: includeDeviceIdentity,
        allowStoredDeviceAuth: allowStoredDeviceAuth,
        deviceAuthGatewayID: deviceAuthGatewayID,
        deviceProofPayload: deviceProofPayload,
        minimumProtocolVersion: minimumProtocolVersion)
}
