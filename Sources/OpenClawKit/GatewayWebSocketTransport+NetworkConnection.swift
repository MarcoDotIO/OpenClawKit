#if canImport(Network) && compiler(>=6.2)
import CryptoKit
import Foundation
import Network
import Security

/// Network path changes reported by ``NetworkConnectionWebSocketSession``.
public enum NetworkConnectionPathEvent: Sendable, Equatable {
    /// The connection's current path became viable (`true`) or unviable (`false`).
    case viabilityChanged(Bool)
    /// A better path became available (`true`) or went away (`false`).
    case betterPathAvailable(Bool)
}

/// Opt-in Network.framework transport for ``GatewayChannelActor``.
///
/// Pass it as the channel's session box to run the gateway WebSocket over
/// `NetworkConnection<WebSocket>` instead of `URLSessionWebSocketTask`. Each connection gets its
/// own TLS validator implementing the gateway pinning policy (explicit pin, stored pin, first-use
/// pin after system trust, or system trust alone), and path/viability updates are surfaced so
/// owners can call ``GatewayChannelActor/nudgeReconnect()`` instead of waiting for the watchdog.
/// The URLSession transport remains the default; on watchOS low-level networking is
/// runtime-restricted, so prefer URLSession there.
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
public final class NetworkConnectionWebSocketSession: WebSocketSessioning, GatewayTLSRouteMetadataProviding,
    GatewayDeviceTokenRetryTrustProviding, GatewayTLSFailureProviding, @unchecked Sendable
{
    private let lock = NSLock()
    private let tls: GatewayTLSParams?
    private let onPathEvent: (@Sendable (NetworkConnectionPathEvent) -> Void)?
    private var acceptedFingerprint: String?
    private var pinEnforced = false
    private var lastFailure: GatewayTLSValidationFailure?

    /// Creates a Network.framework WebSocket session.
    /// - Parameters:
    ///   - tls: Pinning parameters for `wss://` routes; `nil` uses system trust.
    ///   - onPathEvent: Called with viability and better-path updates from each connection.
    public init(
        tls: GatewayTLSParams? = nil,
        onPathEvent: (@Sendable (NetworkConnectionPathEvent) -> Void)? = nil)
    {
        self.tls = tls
        self.onPathEvent = onPathEvent
    }

    /// Accepted leaf SHA-256 fingerprint of the most recent `wss://` connection.
    public var effectiveTLSFingerprintSHA256: String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.acceptedFingerprint
    }

    /// `true` once a pin was enforced for the route, which makes device-token retry safe.
    public var allowsDeviceTokenRetryAuth: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.pinEnforced
    }

    /// Returns and clears the most recent TLS rejection.
    public func consumeLastTLSFailure() -> GatewayTLSValidationFailure? {
        self.lock.lock()
        defer { self.lock.unlock() }
        let failure = self.lastFailure
        self.lastFailure = nil
        return failure
    }

    /// Creates a task for a URL.
    public func makeWebSocketTask(url: URL) -> WebSocketTaskBox {
        self.makeWebSocketTask(request: URLRequest(url: url))
    }

    /// Creates a task for an upgrade request, forwarding its headers.
    public func makeWebSocketTask(request: URLRequest) -> WebSocketTaskBox {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
        let validator = NetworkConnectionTLSValidator(
            host: url.host ?? "",
            port: url.port,
            params: self.tls,
            record: { [weak self] outcome in self?.record(outcome) })
        let task = NetworkConnectionWebSocketTask(
            url: url,
            headers: headers.map { (name: $0.key, value: $0.value) },
            validator: validator,
            onPathEvent: self.onPathEvent)
        return WebSocketTaskBox(task: task)
    }

    private func record(_ outcome: NetworkConnectionTLSValidator.Outcome) {
        self.lock.lock()
        defer { self.lock.unlock() }
        switch outcome {
        case let .accepted(fingerprint, enforced):
            self.acceptedFingerprint = fingerprint
            self.pinEnforced = enforced
            self.lastFailure = nil
        case let .rejected(failure):
            self.lastFailure = failure
        }
    }
}

/// Per-connection TLS decision for ``NetworkConnectionWebSocketSession``.
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
final class NetworkConnectionTLSValidator: Sendable {
    enum Outcome: Sendable {
        case accepted(fingerprint: String?, enforced: Bool)
        case rejected(GatewayTLSValidationFailure)
    }

    private let host: String
    private let port: Int?
    private let params: GatewayTLSParams?
    private let record: @Sendable (Outcome) -> Void

    init(host: String, port: Int?, params: GatewayTLSParams?, record: @escaping @Sendable (Outcome) -> Void) {
        self.host = host
        self.port = port
        self.params = params
        self.record = record
    }

    func evaluate(_ trust: SecTrust) -> Bool {
        let outcome = Self.decide(
            observed: Self.leafFingerprint(trust),
            systemTrustOk: SecTrustEvaluateWithError(trust, nil),
            host: self.host,
            port: self.port,
            params: self.params)
        self.record(outcome)
        if case .accepted = outcome { return true }
        return false
    }

    /// Pinning policy: an explicit or stored pin must match; a first-use pin is saved only after
    /// system trust passes; without pins, system trust (or a non-required policy) decides.
    static func decide(
        observed: String?,
        systemTrustOk: Bool,
        host: String,
        port: Int?,
        params: GatewayTLSParams?) -> Outcome
    {
        guard let params else {
            return systemTrustOk
                ? .accepted(fingerprint: observed, enforced: false)
                : .rejected(self.failure(.untrustedCertificate, host, port, nil, observed, systemTrustOk, nil))
        }
        let expected = params.expectedFingerprint.map(self.normalize)
            ?? params.storeKey.flatMap { GatewayTLSStore.loadFingerprint(stableID: $0) }.map(self.normalize)
        if let expected, !expected.isEmpty {
            guard let observed else {
                return .rejected(self.failure(.certificateUnavailable, host, port, expected, nil, systemTrustOk, params.storeKey))
            }
            return observed == expected
                ? .accepted(fingerprint: observed, enforced: true)
                : .rejected(self.failure(.pinMismatch, host, port, expected, observed, systemTrustOk, params.storeKey))
        }
        if params.allowTOFU, let observed, systemTrustOk {
            if let storeKey = params.storeKey {
                GatewayTLSStore.saveFingerprint(observed, stableID: storeKey)
            }
            return .accepted(fingerprint: observed, enforced: true)
        }
        if systemTrustOk || !params.required {
            return .accepted(fingerprint: observed, enforced: false)
        }
        return .rejected(self.failure(.untrustedCertificate, host, port, nil, observed, systemTrustOk, params.storeKey))
    }

    private static func failure(
        _ kind: GatewayTLSValidationFailureKind,
        _ host: String,
        _ port: Int?,
        _ expected: String?,
        _ observed: String?,
        _ systemTrustOk: Bool,
        _ storeKey: String?) -> GatewayTLSValidationFailure
    {
        GatewayTLSValidationFailure(
            kind: kind,
            host: host,
            storeKey: storeKey,
            expectedFingerprint: expected,
            observedFingerprint: observed,
            systemTrustOk: systemTrustOk,
            port: port)
    }

    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["sha-256:", "sha256:", "sha-256", "sha256"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        return value.filter(\.isHexDigit)
    }

    private static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// `WebSocketTasking` adapter over `NetworkConnection<WebSocket>`.
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
public final class NetworkConnectionWebSocketTask: WebSocketTasking, @unchecked Sendable {
    /// Transport failures surfaced by the adapter.
    public enum TransportError: Error, Sendable, Equatable {
        /// The peer closed the WebSocket.
        case closed(code: UInt16?)
        /// A message kind URLSession has no representation for.
        case unexpectedMessage
    }

    private let connection: NetworkConnection<WebSocket>
    private let lock = NSLock()
    private var _state: URLSessionTask.State = .suspended

    /// Creates a task for `url` with upgrade `headers` and system-trust TLS (no pin).
    public convenience init(url: URL, headers: [(name: String, value: String)] = []) {
        self.init(
            url: url,
            headers: headers,
            validator: NetworkConnectionTLSValidator(host: url.host ?? "", port: url.port, params: nil, record: { _ in }),
            onPathEvent: nil)
    }

    init(
        url: URL,
        headers: [(name: String, value: String)],
        validator: NetworkConnectionTLSValidator,
        onPathEvent: (@Sendable (NetworkConnectionPathEvent) -> Void)?)
    {
        let endpoint = NWEndpoint.url(url)
        if url.scheme?.lowercased() == "wss" {
            self.connection = NetworkConnection(to: endpoint) {
                WebSocket {
                    TLS {
                        TCP()
                    }
                    .certificateValidator { _, secTrust in
                        validator.evaluate(sec_trust_copy_ref(secTrust).takeRetainedValue())
                    }
                }
                .additionalHeaders(headers)
                .maximumMessageSize(16 * 1024 * 1024)
                .autoReplyPing(true)
            }
        } else {
            self.connection = NetworkConnection(to: endpoint) {
                WebSocket {
                    TCP()
                }
                .additionalHeaders(headers)
                .maximumMessageSize(16 * 1024 * 1024)
                .autoReplyPing(true)
            }
        }
        self.connection.onStateUpdate { [weak self] _, state in
            self?.apply(state)
        }
        if let onPathEvent {
            self.connection.onViabilityUpdate { _, viable in
                onPathEvent(.viabilityChanged(viable))
            }
            self.connection.onBetterPathUpdate { _, better in
                onPathEvent(.betterPathAvailable(better))
            }
        }
    }

    private func apply(_ state: NetworkChannel<WebSocket>.State) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self._state != .canceling else { return }
        switch state {
        case .setup, .preparing, .waiting:
            self._state = .suspended
        case .ready:
            self._state = .running
        case .failed, .cancelled:
            self._state = .completed
        @unknown default:
            self._state = .completed
        }
    }

    /// Current task state (`.running` once the upgrade completed).
    public var state: URLSessionTask.State {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._state
    }

    /// A delivered message proves the upgrade completed even if the state callback lags.
    private func markRunningAfterDelivery() {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self._state == .suspended {
            self._state = .running
        }
    }

    /// No-op: one-to-one connections start on their first send or receive.
    public func resume() {}

    /// Closes the WebSocket with the matching close code.
    public func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.lock.lock()
        self._state = .canceling
        self.lock.unlock()
        let connection = self.connection
        let text = reason.flatMap { String(data: $0, encoding: .utf8) }
        let code = (try? NWProtocolWebSocket.CloseCode(rawValue: UInt16(clamping: closeCode.rawValue)))
            ?? .protocolCode(.goingAway)
        Task {
            try? await connection.close(code: code, reason: text)
        }
    }

    /// Sends one text or binary message.
    public func send(_ message: URLSessionWebSocketTask.Message) async throws {
        switch message {
        case let .data(data):
            try await self.connection.send(data)
        case let .string(text):
            try await self.connection.send(text)
        @unknown default:
            throw TransportError.unexpectedMessage
        }
    }

    /// Sends a WebSocket ping and reports the pong.
    public func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        let connection = self.connection
        Task {
            do {
                try await connection.ping(Data())
                pongReceiveHandler(nil)
            } catch {
                pongReceiveHandler(error)
            }
        }
    }

    /// Receives the next text or binary message; control frames are skipped.
    public func receive() async throws -> URLSessionWebSocketTask.Message {
        while true {
            let message = try await self.connection.receive()
            switch message.metadata.opcode {
            case .text:
                self.markRunningAfterDelivery()
                return .string(String(decoding: message.content, as: UTF8.self))
            case .binary:
                self.markRunningAfterDelivery()
                return .data(message.content)
            case .close:
                let code: UInt16? = switch message.metadata.closeCode {
                case let .protocolCode(defined)?: defined.rawValue
                case let .applicationCode(value)?: value
                case let .privateCode(value)?: value
                case nil: nil
                @unknown default: nil
                }
                throw TransportError.closed(code: code)
            default:
                continue
            }
        }
    }

    /// Receives the next message through a completion handler.
    public func receive(
        completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    {
        Task {
            do {
                completionHandler(.success(try await self.receive()))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }
}
#endif
