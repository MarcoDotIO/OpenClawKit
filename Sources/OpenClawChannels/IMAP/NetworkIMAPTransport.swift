#if canImport(Network)
import Foundation
import Network
import OpenClawCore

/// Implicit-TLS IMAP transport over `NWConnection` (Apple platforms).
public final class NetworkIMAPTransport: IMAPTransport, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let queue = DispatchQueue(label: "ai.openclaw.imap.connection")
    private let lock = NSLock()
    private var connection: NWConnection?

    /// Creates a transport.
    /// - Parameters:
    ///   - host: IMAP host.
    ///   - port: Port (993 for implicit TLS).
    public init(host: String, port: Int = 993) {
        self.host = host
        self.port = port
    }

    /// Connects with TLS and waits until the connection is ready.
    public func open() async throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: self.port)) else {
            throw OpenClawCoreError.invalidConfiguration("Invalid IMAP port \(self.port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(self.host), port: port, using: .tls)
        self.withLock { self.connection = connection }
        let resumed = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                case .waiting(let error):
                    if resumed.claim() {
                        connection.cancel()
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: IMAPError.connectionClosed) }
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    /// Sends bytes.
    /// - Parameter data: Bytes.
    public func write(_ data: Data) async throws {
        guard let connection = self.withLock({ self.connection }) else {
            throw IMAPError.connectionClosed
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Receives the next chunk (empty at end of stream).
    /// - Returns: Bytes.
    public func read() async throws -> Data {
        guard let connection = self.withLock({ self.connection }) else {
            return Data()
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// Cancels the connection.
    public func close() async {
        let connection = self.withLock { () -> NWConnection? in
            let current = self.connection
            self.connection = nil
            return current
        }
        connection?.cancel()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body()
    }
}

/// Resumes a continuation at most once across callback invocations.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.done else { return false }
        self.done = true
        return true
    }
}
#endif
