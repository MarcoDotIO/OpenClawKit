import Foundation

/// Minimal WebSocket task surface the gateway channel drives.
///
/// `URLSessionWebSocketTask` conforms directly; custom transports (test fakes, Network.framework
/// adapters) implement it to plug into ``GatewayChannelActor``.
public protocol WebSocketTasking: AnyObject {
    /// Current task state; the channel treats anything but `.running` as a stopped socket.
    var state: URLSessionTask.State { get }
    /// Starts the task.
    func resume()
    /// Closes the socket with a WebSocket close code and optional reason.
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    /// Sends one message.
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    /// Sends a ping and reports the pong (or failure) through `pongReceiveHandler`.
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
    /// Receives the next message.
    func receive() async throws -> URLSessionWebSocketTask.Message
    /// Receives the next message through a completion handler.
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
}

extension URLSessionWebSocketTask: WebSocketTasking {}

/// Carries the native request owner's completion across transports that retain their own RPC state.
///
/// The channel finishes the lifetime when the pending request resolves (response, timeout,
/// cancellation, or disconnect), so transports that keep per-request state can release it.
public final class WebSocketRequestLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var onFinish: (@Sendable () -> Void)?

    /// Creates an active lifetime.
    public init() {}

    /// Enqueues request work while holding the same lock that orders its retirement.
    ///
    /// The action must only enqueue work; running I/O here would block cancellation.
    /// - Parameters:
    ///   - action: Admission work, run only while the lifetime is still active.
    ///   - onFinish: Called once when the lifetime finishes after a successful admission.
    /// - Returns: `false` when the lifetime already finished and `action` did not run.
    public func performIfActive(
        _ action: () -> Void,
        onFinish: @escaping @Sendable () -> Void) -> Bool
    {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.finished else { return false }
        action()
        self.onFinish = onFinish
        return true
    }

    /// Finishes the lifetime and runs the registered finish handler exactly once.
    public func finish() {
        self.lock.lock()
        guard !self.finished else {
            self.lock.unlock()
            return
        }
        self.finished = true
        let action = self.onFinish
        self.onFinish = nil
        self.lock.unlock()
        action?()
    }
}

/// Optional transport seam for custom WebSocket tasks that keep their own RPC state.
///
/// When a task conforms, ``WebSocketTaskBox/sendRequest(_:lifetime:)`` hands it the request's
/// ``WebSocketRequestLifetime`` instead of calling plain `send`.
public protocol WebSocketRequestSending: WebSocketTasking {
    /// Sends one request frame bound to its caller-owned lifetime.
    func sendRequest(_ message: URLSessionWebSocketTask.Message, lifetime: WebSocketRequestLifetime) async throws
}

/// Resumes a ping continuation exactly once even when URLSession races callbacks.
private final class WebSocketPingContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(_ resume: () -> Void) {
        self.lock.lock()
        if self.didResume {
            self.lock.unlock()
            return
        }
        self.didResume = true
        self.lock.unlock()
        resume()
    }
}

/// Sendable box around one WebSocket task.
public struct WebSocketTaskBox: @unchecked Sendable {
    /// Bounds a ping whose pong handler URLSession may never invoke. Long enough that a
    /// slow-but-live link still pongs, short enough that a wedged keepalive recovers.
    public static let pingTimeout: Duration = .seconds(10)

    /// Boxed task.
    public let task: any WebSocketTasking

    /// Wraps a WebSocket task.
    public init(task: any WebSocketTasking) {
        self.task = task
    }

    /// Current task state.
    public var state: URLSessionTask.State {
        self.task.state
    }

    /// Starts the task.
    public func resume() {
        self.task.resume()
    }

    /// Closes the socket.
    public func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.task.cancel(with: closeCode, reason: reason)
    }

    /// Sends one message.
    public func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await self.task.send(message)
    }

    /// Sends one request frame, forwarding its lifetime to transports that track RPC state.
    public func sendRequest(
        _ message: URLSessionWebSocketTask.Message,
        lifetime: WebSocketRequestLifetime) async throws
    {
        if let transport = self.task as? any WebSocketRequestSending {
            try await transport.sendRequest(message, lifetime: lifetime)
        } else {
            try await self.task.send(message)
        }
    }

    /// Receives the next message.
    public func receive() async throws -> URLSessionWebSocketTask.Message {
        try await self.task.receive()
    }

    /// Receives the next message through a completion handler.
    public func receive(
        completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    {
        self.task.receive(completionHandler: completionHandler)
    }

    /// Sends a ping and waits for the pong, failing with `URLError(.timedOut)` after `timeout`.
    ///
    /// URLSession drops the pong handler entirely when the task is cancelled or closed
    /// mid-flight, which would otherwise orphan the continuation and wedge the keepalive loop.
    /// The deadline guarantees the continuation always resumes; a gate keeps that resume
    /// exactly once even when URLSession invokes the pong handler more than once.
    public func sendPing(timeout: Duration = WebSocketTaskBox.pingTimeout) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = WebSocketPingContinuationGate()
            let deadline = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Cancelled because a pong arrived first; that callback owns the resume.
                    return
                }
                gate.resumeOnce {
                    // URLError keeps this indistinguishable from a transport timeout for callers.
                    ThrowingContinuationSupport.resumeVoid(continuation, error: URLError(.timedOut))
                }
            }
            self.task.sendPing { error in
                deadline.cancel()
                // Only the first pong result owns this checked continuation or Swift traps the app.
                gate.resumeOnce {
                    ThrowingContinuationSupport.resumeVoid(continuation, error: error)
                }
            }
        }
    }
}

/// Factory for WebSocket tasks.
public protocol WebSocketSessioning: AnyObject {
    /// Creates a task for a URL.
    func makeWebSocketTask(url: URL) -> WebSocketTaskBox
    /// Creates a task for a full upgrade request (headers included).
    func makeWebSocketTask(request: URLRequest) -> WebSocketTaskBox
}

extension WebSocketSessioning {
    /// Compatibility path for existing session conformers that only build tasks from URLs.
    ///
    /// URLSession overrides this requirement so operator headers stay attached to the upgrade
    /// request; conformers that ignore headers drop them here.
    public func makeWebSocketTask(request: URLRequest) -> WebSocketTaskBox {
        let url = request.url ?? URL(fileURLWithPath: "/")
        return self.makeWebSocketTask(url: url)
    }
}

extension URLSession: WebSocketSessioning {
    /// Creates a task for a URL.
    public func makeWebSocketTask(url: URL) -> WebSocketTaskBox {
        self.makeWebSocketTask(request: URLRequest(url: url))
    }

    /// Creates a task for a full upgrade request, raising the message ceiling to 16 MB.
    public func makeWebSocketTask(request: URLRequest) -> WebSocketTaskBox {
        let task = self.webSocketTask(with: request)
        // Avoid "Message too long" receive errors for large snapshots / history payloads.
        task.maximumMessageSize = 16 * 1024 * 1024 // 16 MB
        return WebSocketTaskBox(task: task)
    }
}

/// Sendable box around a WebSocket session.
public struct WebSocketSessionBox: @unchecked Sendable {
    /// Boxed session.
    public let session: any WebSocketSessioning

    /// Wraps a WebSocket session.
    public init(session: any WebSocketSessioning) {
        self.session = session
    }
}
