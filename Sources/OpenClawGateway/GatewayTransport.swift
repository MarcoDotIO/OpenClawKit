import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Gateway endpoint definition.
public struct GatewayEndpoint: Sendable, Equatable {
    /// Endpoint URL.
    public let url: URL
    /// Optional TLS leaf fingerprint expected from remote.
    public let serverFingerprint: String?

    /// Creates a gateway endpoint.
    /// - Parameters:
    ///   - url: Gateway URL.
    ///   - serverFingerprint: Optional TLS fingerprint for pinning checks.
    public init(url: URL, serverFingerprint: String? = nil) {
        self.url = url
        self.serverFingerprint = serverFingerprint
    }
}

/// TLS validation settings used by the gateway client.
public struct GatewayTLSSettings: Sendable {
    /// Optional required fingerprint value.
    public let expectedFingerprint: String?
    /// Whether TLS fingerprint validation is required when expected fingerprint is absent.
    public let required: Bool

    /// Creates TLS settings.
    /// - Parameters:
    ///   - expectedFingerprint: Expected fingerprint value.
    ///   - required: Whether fingerprint is mandatory.
    public init(expectedFingerprint: String? = nil, required: Bool = false) {
        self.expectedFingerprint = expectedFingerprint
        self.required = required
    }
}

/// Errors surfaced by gateway transport operations.
public enum GatewayTransportError: Error, LocalizedError, Sendable {
    /// Socket is not currently connected.
    case notConnected
    /// Request exceeded its timeout.
    case requestTimeout(requestID: String)
    /// Received frame did not decode/validate.
    case invalidFrame(String)
    /// TLS fingerprint validation failed.
    case tlsFingerprintMismatch
    /// Remote gateway returned an error response.
    case remote(ErrorShape)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Gateway is not connected"
        case .requestTimeout(let requestID):
            return "Gateway request timed out (\(requestID))"
        case .invalidFrame(let detail):
            return "Invalid gateway frame: \(detail)"
        case .tlsFingerprintMismatch:
            return "Gateway TLS fingerprint mismatch"
        case .remote(let error):
            return "Gateway remote error (\(error.code)): \(error.message)"
        }
    }
}

/// Actor-backed gateway client with reconnect and request/response tracking.
public actor GatewayClient {
    /// Factory used to create new socket instances.
    public typealias SocketFactory = @Sendable () -> any GatewaySocket
    /// Event callback for inbound event frames.
    public typealias EventHandler = @Sendable (EventFrame) async -> Void

    private let socketFactory: SocketFactory
    private let tls: GatewayTLSSettings
    private let onEvent: EventHandler?
    private let tickIntervalMs: Int
    private let initialReconnectBackoffMs: UInt64
    private let tickTimeoutMultiplier = 2

    private var socket: (any GatewaySocket)?
    private var receiveTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var endpoint: GatewayEndpoint?
    private var connected = false
    private var lastTick = Date()
    private var reconnectBackoffMs: UInt64 = 500
    private var pending: [String: CheckedContinuation<ResponseFrame, Error>] = [:]

    /// Creates a gateway client.
    /// - Parameters:
    ///   - socketFactory: Socket factory closure.
    ///   - tls: TLS pinning settings.
    ///   - tickIntervalMs: Tick interval in milliseconds.
    ///   - initialReconnectBackoffMs: Initial reconnect delay in milliseconds.
    ///   - onEvent: Optional event callback.
    public init(
        socketFactory: @escaping SocketFactory = { LoopbackGatewaySocket() },
        tls: GatewayTLSSettings = GatewayTLSSettings(),
        tickIntervalMs: Int = 30_000,
        initialReconnectBackoffMs: UInt64 = 500,
        onEvent: EventHandler? = nil
    ) {
        self.socketFactory = socketFactory
        self.tls = tls
        self.tickIntervalMs = max(10, tickIntervalMs)
        self.initialReconnectBackoffMs = max(10, initialReconnectBackoffMs)
        self.onEvent = onEvent
        self.reconnectBackoffMs = max(10, initialReconnectBackoffMs)
    }

    /// Connects to a gateway endpoint and starts receive/watchdog loops.
    /// - Parameter endpoint: Gateway endpoint.
    public func connect(to endpoint: GatewayEndpoint) async throws {
        self.endpoint = endpoint
        self.shouldReconnect = true
        try await self.establishConnection()
    }

    /// Disconnects and cancels all background gateway tasks.
    public func disconnect() async {
        self.shouldReconnect = false
        self.reconnectTask?.cancel()
        self.reconnectTask = nil
        self.receiveTask?.cancel()
        self.receiveTask = nil
        self.watchdogTask?.cancel()
        self.watchdogTask = nil
        if let socket = self.socket {
            await socket.close()
        }
        self.socket = nil
        self.failAllPending(with: GatewayTransportError.notConnected)
        self.connected = false
        self.endpoint = nil
    }

    /// Returns current connection state.
    /// - Returns: `true` when connected.
    public func isConnected() -> Bool {
        self.connected
    }

    /// Sends a request frame and awaits response with timeout.
    /// - Parameters:
    ///   - method: Gateway method name.
    ///   - params: Request parameters.
    ///   - timeoutMs: Timeout in milliseconds.
    /// - Returns: Decoded response frame.
    public func send(
        method: String,
        params: [String: AnyCodable] = [:],
        timeoutMs: Int = 15_000
    ) async throws -> ResponseFrame
    {
        guard self.connected, let socket = self.socket else {
            throw GatewayTransportError.notConnected
        }

        let id = UUID().uuidString
        let frame = RequestFrame(type: "req", id: id, method: method, params: AnyCodable(params))
        let raw = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            self.pending[id] = continuation

            Task { [weak self] in
                do {
                    try await socket.send(text: raw)
                } catch {
                    await self?.failPending(id: id, with: error)
                }
            }

            let timeoutNs = UInt64(max(0, timeoutMs)) * 1_000_000
            Task { [weak self] in
                if (try? await Task.sleep(nanoseconds: timeoutNs)) == nil {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.failPending(id: id, with: GatewayTransportError.requestTimeout(requestID: id))
            }
        }
    }

    /// Sends a typed request and decodes the typed response payload.
    /// - Parameters:
    ///   - method: Gateway method name.
    ///   - timeoutMs: Timeout in milliseconds.
    ///   - type: Response payload type.
    /// - Returns: Decoded typed response payload.
    public func request<T: Decodable>(
        _ method: String,
        timeoutMs: Int = 15_000,
        as type: T.Type = T.self
    ) async throws -> T {
        let response = try await self.send(method: method, timeoutMs: timeoutMs)
        return try Self.decodeResponse(type, from: response)
    }

    /// Sends a typed request payload and decodes the typed response payload.
    /// - Parameters:
    ///   - method: Gateway method name.
    ///   - params: Typed request payload.
    ///   - timeoutMs: Timeout in milliseconds.
    ///   - type: Response payload type.
    /// - Returns: Decoded typed response payload.
    public func request<P: Encodable, T: Decodable>(
        _ method: String,
        params: P,
        timeoutMs: Int = 15_000,
        as type: T.Type = T.self
    ) async throws -> T {
        let encoded = try GatewayPayloadCodec.encode(params)
        guard case .object(let object) = encoded.value else {
            throw GatewayTransportError.invalidFrame("Typed gateway params must encode to an object")
        }
        let response = try await self.send(method: method, params: object, timeoutMs: timeoutMs)
        return try Self.decodeResponse(type, from: response)
    }

    private func establishConnection() async throws {
        guard let endpoint else {
            throw GatewayTransportError.notConnected
        }

        try self.validateTLS(for: endpoint)

        self.receiveTask?.cancel()
        self.watchdogTask?.cancel()
        self.reconnectTask?.cancel()
        self.reconnectTask = nil

        let socket = self.socketFactory()
        try await socket.connect(url: endpoint.url)
        self.socket = socket
        self.connected = true
        self.lastTick = Date()
        self.reconnectBackoffMs = self.initialReconnectBackoffMs

        self.startReceiveLoop(using: socket)
        self.startTickWatchdog()
    }

    private static func decodeResponse<T: Decodable>(_ type: T.Type, from response: ResponseFrame) throws -> T {
        guard response.ok else {
            if let error = response.error {
                let shape = try GatewayPayloadCodec.decode(ErrorShape.self, from: AnyCodable(error))
                throw GatewayTransportError.remote(shape)
            }
            throw GatewayTransportError.invalidFrame("Gateway response marked as failed without an error payload")
        }
        return try GatewayPayloadCodec.decode(type, from: response.payload)
    }

    private func startReceiveLoop(using socket: any GatewaySocket) {
        self.receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let raw = try await socket.receive()
                    await self?.handleInbound(raw)
                } catch {
                    await self?.handleSocketFailure(error)
                    return
                }
            }
        }
    }

    private func startTickWatchdog() {
        self.watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sleepNs = UInt64(self.tickIntervalMs) * 1_000_000
                do {
                    try await Task.sleep(nanoseconds: sleepNs)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.validateTickDeadline()
            }
        }
    }

    private func validateTickDeadline() {
        guard self.connected else { return }
        let timeoutSeconds = TimeInterval(self.tickIntervalMs * self.tickTimeoutMultiplier) / 1000
        guard Date().timeIntervalSince(self.lastTick) >= timeoutSeconds else { return }

        Task { [weak self] in
            if let socket = await self?.socket {
                await socket.close()
            }
            await self?.handleSocketFailure(GatewayTransportError.requestTimeout(requestID: "tick"))
        }
    }

    private func handleInbound(_ raw: String) {
        let data = Data(raw.utf8)
        do {
            let frame = try JSONDecoder().decode(GatewayFrame.self, from: data)
            switch frame {
            case .res(let response):
                self.resolvePending(id: response.id, with: response)
            case .event(let event):
                if event.event == "tick" {
                    self.lastTick = Date()
                }
                if let onEvent = self.onEvent {
                    Task {
                        await onEvent(event)
                    }
                }
            case .req:
                break
            case .unknown:
                break
            }
        } catch {
            // Ignore malformed frames in loopback contexts; production sockets should enforce framing.
        }
    }

    private func resolvePending(id: String, with response: ResponseFrame) {
        guard let pending = self.pending.removeValue(forKey: id) else { return }
        pending.resume(returning: response)
    }

    private func failPending(id: String, with error: Error) {
        guard let pending = self.pending.removeValue(forKey: id) else { return }
        pending.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let unresolved = self.pending.values
        self.pending.removeAll()
        for continuation in unresolved {
            continuation.resume(throwing: error)
        }
    }

    private func handleSocketFailure(_ error: Error) {
        self.connected = false
        self.socket = nil
        self.failAllPending(with: error)
        self.receiveTask?.cancel()
        self.receiveTask = nil
        self.watchdogTask?.cancel()
        self.watchdogTask = nil

        guard self.shouldReconnect, self.endpoint != nil else { return }
        self.scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard self.reconnectTask == nil else { return }
        let delay = self.reconnectBackoffMs
        self.reconnectBackoffMs = min(delay * 2, 5_000)

        self.reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000)
            } catch {
                await self?.clearReconnectTaskIfFinished()
                return
            }
            guard let self else { return }
            guard !Task.isCancelled else {
                await self.clearReconnectTaskIfFinished()
                return
            }
            guard await self.shouldAttemptReconnect() else {
                await self.clearReconnectTaskIfFinished()
                return
            }
            do {
                try await self.establishConnection()
            } catch is CancellationError {
                await self.clearReconnectTaskIfFinished()
                return
            } catch {
                await self.handleSocketFailure(error)
            }
            await self.clearReconnectTaskIfFinished()
        }
    }

    private func shouldAttemptReconnect() -> Bool {
        self.shouldReconnect && self.endpoint != nil
    }

    private func clearReconnectTaskIfFinished() {
        self.reconnectTask = nil
    }

    private func validateTLS(for endpoint: GatewayEndpoint) throws {
        guard endpoint.url.scheme?.lowercased() == "wss" else {
            return
        }

        let expected = self.tls.expectedFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expected, !expected.isEmpty else {
            if self.tls.required {
                throw GatewayTransportError.tlsFingerprintMismatch
            }
            return
        }

        let actual = endpoint.serverFingerprint ?? ""
        let normalizedExpected = OpenClawSecurity.normalizeFingerprint(expected)
        let normalizedActual = OpenClawSecurity.normalizeFingerprint(actual)
        guard !normalizedActual.isEmpty, normalizedExpected == normalizedActual else {
            throw GatewayTransportError.tlsFingerprintMismatch
        }
    }
}
