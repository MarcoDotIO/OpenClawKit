import Foundation
import OpenClawCore
import OpenClawProtocol

/// Minimal socket abstraction required by the gateway transport.
public protocol GatewaySocket: Sendable {
    /// Opens a socket connection to the provided URL.
    /// - Parameter url: WebSocket endpoint URL.
    func connect(url: URL) async throws
    /// Sends a raw text frame.
    /// - Parameter text: Text payload.
    func send(text: String) async throws
    /// Receives a raw text frame.
    /// - Returns: Next inbound text payload.
    func receive() async throws -> String
    /// Closes the socket transport.
    func close() async
}

/// In-process loopback socket used by tests and local transport flows.
///
/// When backed by a ``GatewayServer`` the socket also forwards server-emitted events
/// (``GatewayServer/broadcast(event:payload:)`` and handler ``GatewayEventEmitter`` calls) as event
/// frames. The subscription is bound to the socket's connection (``GatewayEventFilter/connection(_:)``),
/// so `session.message`/`session.tool` arrive only for sessions subscribed with
/// `sessions.messages.subscribe`; connecting and closing also update the server's presence
/// (`system-presence`, `presence` events). Events are filtered by the connection's role and scopes
/// (``GatewayEventFilter/hasEventScope(_:event:)``). Like the upstream gateway, a server-backed
/// socket also emits a `tick` event `{ts}` every `tickIntervalMs`, which keeps a ``GatewayClient``
/// tick watchdog satisfied. Give each socket its own ``GatewayConnectionContext/connectionID``
/// when several share one server.
public actor LoopbackGatewaySocket: GatewaySocket {
    /// Upstream `TICK_INTERVAL_MS`.
    public static let defaultTickIntervalMs = 30_000

    private let server: GatewayServer?
    private let connection: GatewayConnectionContext
    private let tickIntervalMs: Int
    private var open = false
    private var queue: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var eventPump: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    /// Creates a loopback socket.
    /// - Parameters:
    ///   - server: Optional in-process gateway server dispatcher.
    ///   - connection: Connection identity and grants presented to the server.
    ///   - tickIntervalMs: Interval of the `tick` events a server-backed socket emits (at least 10 ms).
    public init(
        server: GatewayServer? = nil,
        connection: GatewayConnectionContext = .inProcess,
        tickIntervalMs: Int = LoopbackGatewaySocket.defaultTickIntervalMs
    ) {
        self.server = server
        self.connection = connection
        self.tickIntervalMs = max(10, tickIntervalMs)
    }

    deinit {
        // Ends the server event subscription even when the socket is dropped without `close()`.
        self.eventPump?.cancel()
        self.tickTask?.cancel()
    }

    /// Marks the loopback socket as connected and starts forwarding server events.
    /// - Parameter url: Ignored loopback URL placeholder.
    public func connect(url _: URL) async throws {
        self.open = true
        guard let server, self.eventPump == nil else { return }
        // Register presence before subscribing so the socket does not receive its own join event.
        await server.connectionOpened(self.connection)
        let events = await server.events(filter: .connection(self.connection.connectionID))
        self.eventPump = Task { [weak self] in
            for await frame in events {
                guard let self else { return }
                await self.forward(frame)
            }
        }
        let intervalNs = GatewayTimeouts.nanoseconds(milliseconds: self.tickIntervalMs)
        self.tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNs)
                } catch {
                    return
                }
                guard let self else { return }
                await self.forward(Self.tickFrame())
            }
        }
    }

    /// Upstream maintenance `tick` event (`{ts}`, no sequence number).
    private static func tickFrame() -> EventFrame {
        EventFrame(
            type: "event",
            event: GatewayEventName.tick.rawValue,
            payload: AnyCodable(["ts": AnyCodable(gatewayNowMs())]),
            seq: nil,
            stateversion: nil
        )
    }

    /// Enqueues a synthesized response frame for the provided request frame.
    /// - Parameter text: Raw encoded request frame.
    public func send(text: String) async throws {
        guard self.open else {
            throw OpenClawCoreError.unavailable("Socket is not connected")
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let request = try decoder.decode(RequestFrame.self, from: Data(text.utf8))
        let response: ResponseFrame
        if let server {
            response = await server.handle(request, connection: self.connection)
        } else {
            response = ResponseFrame(
                type: "res",
                id: request.id,
                ok: true,
                payload: AnyCodable(["status": AnyCodable("accepted")]),
                error: nil
            )
        }
        let raw = String(decoding: try encoder.encode(response), as: UTF8.self)
        self.enqueue(raw)
    }

    /// Receives a queued frame or suspends until one is available.
    /// - Returns: Next inbound frame payload.
    public func receive() async throws -> String {
        if let first = self.queue.first {
            self.queue.removeFirst()
            return first
        }

        guard self.open else {
            throw OpenClawCoreError.unavailable("Socket is closed")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    /// Closes the socket, stops event forwarding, and fails all suspended receivers.
    public func close() async {
        self.open = false
        if self.eventPump != nil, let server {
            await server.connectionClosed(connectionID: self.connection.connectionID)
        }
        self.eventPump?.cancel()
        self.eventPump = nil
        self.tickTask?.cancel()
        self.tickTask = nil
        let error = OpenClawCoreError.unavailable("Socket closed")
        let pending = self.waiters
        self.waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: error)
        }
    }

    private func forward(_ frame: EventFrame) {
        guard self.open, let data = try? JSONEncoder().encode(frame) else { return }
        self.enqueue(String(decoding: data, as: UTF8.self))
    }

    private func enqueue(_ raw: String) {
        if let waiter = self.waiters.first {
            self.waiters.removeFirst()
            waiter.resume(returning: raw)
            return
        }
        self.queue.append(raw)
    }
}
