#if canImport(Network) && compiler(>=6.2)
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
/// `NetworkConnection<WebSocket>` instead of `URLSessionWebSocketTask`. Certificates are evaluated
/// by the same policy as ``GatewayTLSPinningSession`` (``GatewayTLSServerTrust``): an explicit pin,
/// the stored pin claimed through ``GatewayTLSStore`` (first use only after system trust for the
/// requested hostname, failing closed when pin storage is unavailable), staged-pin promotion,
/// `requiresSystemTrust`, or system trust alone. The enforced pin survives reconnects of the same
/// session. A rejected certificate surfaces as ``GatewayTLSValidationError``, so pin mismatches pause
/// automatic reconnects and produce a rotation request. Path/viability updates are surfaced so owners
/// can call ``GatewayChannelActor/nudgeReconnect()`` instead of waiting for the watchdog.
/// The URLSession transport remains the default; on watchOS low-level networking is
/// runtime-restricted, so prefer URLSession there.
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
public final class NetworkConnectionWebSocketSession: WebSocketSessioning, GatewayTLSRouteMetadataProviding,
    GatewayDeviceTokenRetryTrustProviding, GatewayTLSFailureProviding, GatewayTLSPinRotationAccepting,
    @unchecked Sendable
{
    /// Parameters used when the session has no pinning parameters: system trust for the host only.
    static let systemTrustOnlyParams = GatewayTLSParams(
        required: true,
        expectedFingerprint: nil,
        allowTOFU: false,
        storeKey: nil,
        requiresSystemTrust: true)

    /// Trust owner shared with the URLSession transport; its `URLSession` is never created here.
    private let trustPolicy: GatewayTLSPinningSession
    private let onPathEvent: (@Sendable (NetworkConnectionPathEvent) -> Void)?

    /// Creates a Network.framework WebSocket session.
    /// - Parameters:
    ///   - tls: Pinning parameters for `wss://` routes; `nil` uses system trust for the host.
    ///   - onPathEvent: Called with viability and better-path updates from each connection.
    public init(
        tls: GatewayTLSParams? = nil,
        onPathEvent: (@Sendable (NetworkConnectionPathEvent) -> Void)? = nil)
    {
        self.trustPolicy = GatewayTLSPinningSession(params: tls ?? Self.systemTrustOnlyParams)
        self.onPathEvent = onPathEvent
    }

    /// Accepted leaf SHA-256 fingerprint of the most recent `wss://` connection.
    public var effectiveTLSFingerprintSHA256: String? {
        self.trustPolicy.effectiveTLSFingerprintSHA256
    }

    /// `true` once a pin is enforced for the route, which makes device-token retry safe.
    public var allowsDeviceTokenRetryAuth: Bool {
        self.trustPolicy.allowsDeviceTokenRetryAuth
    }

    /// Returns and clears the most recent TLS rejection.
    public func consumeLastTLSFailure() -> GatewayTLSValidationFailure? {
        self.trustPolicy.consumeLastTLSFailure()
    }

    /// Accepts a pin rotation the user reviewed (see ``GatewayTLSPinningSession/acceptPinRotation(_:)``).
    /// - Parameter request: Rotation request from the pin mismatch.
    /// - Returns: `true` when the rotation was stored and this session now enforces the new pin.
    @discardableResult
    public func acceptPinRotation(_ request: GatewayTLSPinRotationRequest) -> Bool {
        self.trustPolicy.acceptPinRotation(request)
    }

    /// Evaluates a server trust for `url`; returns the rejection, or `nil` when it was accepted.
    func serverTrustFailure(_ trust: SecTrust, for url: URL) -> GatewayTLSValidationFailure? {
        self.trustPolicy.serverTrustFailure(trust, for: url)
    }

    /// Creates a task for a URL.
    public func makeWebSocketTask(url: URL) -> WebSocketTaskBox {
        self.makeWebSocketTask(request: URLRequest(url: url))
    }

    /// Creates a task for an upgrade request, forwarding its headers.
    public func makeWebSocketTask(request: URLRequest) -> WebSocketTaskBox {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
        // A rejection recorded by an earlier attempt must never be attributed to this one.
        _ = self.trustPolicy.consumeLastTLSFailure()
        let trustPolicy = self.trustPolicy
        let task = NetworkConnectionWebSocketTask(
            url: url,
            headers: headers.map { (name: $0.key, value: $0.value) },
            validate: { trust in trustPolicy.serverTrustFailure(trust, for: url) },
            onPathEvent: self.onPathEvent)
        return WebSocketTaskBox(task: task)
    }
}

/// The TLS rejection one connection's certificate validator recorded.
private final class NetworkConnectionTLSRejection: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: GatewayTLSValidationFailure?

    var failure: GatewayTLSValidationFailure? {
        self.lock.withLock { self.recorded }
    }

    func record(_ failure: GatewayTLSValidationFailure) {
        self.lock.withLock { self.recorded = failure }
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
    private let url: URL
    private let tlsRejection: NetworkConnectionTLSRejection
    private let lock = NSLock()
    private var _state: URLSessionTask.State = .suspended

    /// Creates a task for `url` with upgrade `headers` and system-trust TLS for the host (no pin).
    public convenience init(url: URL, headers: [(name: String, value: String)] = []) {
        let trustPolicy = GatewayTLSPinningSession(params: NetworkConnectionWebSocketSession.systemTrustOnlyParams)
        self.init(
            url: url,
            headers: headers,
            validate: { trust in trustPolicy.serverTrustFailure(trust, for: url) },
            onPathEvent: nil)
    }

    /// - Parameter validate: Evaluates the server trust of a `wss://` connection and returns the
    ///   rejection, or `nil` to accept the certificate.
    init(
        url: URL,
        headers: [(name: String, value: String)],
        validate: @escaping @Sendable (SecTrust) -> GatewayTLSValidationFailure?,
        onPathEvent: (@Sendable (NetworkConnectionPathEvent) -> Void)?)
    {
        let rejection = NetworkConnectionTLSRejection()
        self.url = url
        self.tlsRejection = rejection
        let endpoint = NWEndpoint.url(url)
        if url.scheme?.lowercased() == "wss" {
            self.connection = NetworkConnection(to: endpoint) {
                WebSocket {
                    TLS {
                        TCP()
                    }
                    .certificateValidator { _, secTrust in
                        guard let failure = validate(sec_trust_copy_ref(secTrust).takeRetainedValue()) else {
                            return true
                        }
                        rejection.record(failure)
                        return false
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

    /// Network.framework reports a rejected certificate as an `NWError`, never a `URLError`. Surface
    /// the validator's typed rejection instead, and any other TLS failure as
    /// `URLError(.secureConnectionFailed)`, so channels treat both like the URLSession transport.
    func mapConnectionError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let failure = self.tlsRejection.failure {
            return GatewayTLSValidationError(failure: failure, context: "connect to gateway @ \(self.url.absoluteString)")
        }
        if let networkError = error as? NWError, case .tls = networkError {
            return URLError(.secureConnectionFailed, userInfo: [NSUnderlyingErrorKey: error])
        }
        return error
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
        let code = Self.networkCloseCode(closeCode)
        Task {
            try? await connection.close(code: code, reason: text)
        }
    }

    /// Maps a URLSession close code (including 4000-4999 application codes such as the tick timeout).
    static func networkCloseCode(_ closeCode: URLSessionWebSocketTask.CloseCode) -> NWProtocolWebSocket.CloseCode {
        let raw = closeCode.rawValue
        if (4000...4999).contains(raw) {
            return .applicationCode(UInt16(raw))
        }
        if let defined = NWProtocolWebSocket.CloseCode.Defined(rawValue: UInt16(clamping: raw)) {
            return .protocolCode(defined)
        }
        return .protocolCode(.goingAway)
    }

    /// Sends one text or binary message.
    public func send(_ message: URLSessionWebSocketTask.Message) async throws {
        do {
            switch message {
            case let .data(data):
                try await self.connection.send(data)
            case let .string(text):
                try await self.connection.send(text)
            @unknown default:
                throw TransportError.unexpectedMessage
            }
        } catch let error as TransportError {
            throw error
        } catch {
            throw self.mapConnectionError(error)
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
                pongReceiveHandler(self.mapConnectionError(error))
            }
        }
    }

    /// Receives the next text or binary message; control frames are skipped.
    public func receive() async throws -> URLSessionWebSocketTask.Message {
        while true {
            let message: WebSocket.Message<Data>
            do {
                message = try await self.connection.receive()
            } catch {
                throw self.mapConnectionError(error)
            }
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
