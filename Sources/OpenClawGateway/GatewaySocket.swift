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
/// (``GatewayServer/broadcast(event:payload:)`` and handler ``GatewayEventEmitter`` calls) as event frames.
public actor LoopbackGatewaySocket: GatewaySocket {
    private let server: GatewayServer?
    private let connection: GatewayConnectionContext
    private var open = false
    private var queue: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var eventPump: Task<Void, Never>?

    /// Creates a loopback socket.
    /// - Parameters:
    ///   - server: Optional in-process gateway server dispatcher.
    ///   - connection: Connection identity and grants presented to the server.
    public init(server: GatewayServer? = nil, connection: GatewayConnectionContext = .inProcess) {
        self.server = server
        self.connection = connection
    }

    /// Marks the loopback socket as connected and starts forwarding server events.
    /// - Parameter url: Ignored loopback URL placeholder.
    public func connect(url _: URL) async throws {
        self.open = true
        guard let server, self.eventPump == nil else { return }
        let events = await server.events()
        self.eventPump = Task { [weak self] in
            for await frame in events {
                guard let self else { return }
                await self.forward(frame)
            }
        }
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
        self.eventPump?.cancel()
        self.eventPump = nil
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
