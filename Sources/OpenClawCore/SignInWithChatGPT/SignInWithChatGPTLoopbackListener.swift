#if !os(tvOS) && !os(watchOS)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One-shot HTTP listener on `127.0.0.1` that receives the Sign in with ChatGPT browser callback.
///
/// The listener answers `GET /auth/callback?…` with a small "return to the app" page and delivers the
/// callback URL to ``waitForCallback()``. Requests for other paths get `404`; callbacks whose `state`
/// does not match ``expect(state:)`` get `400` and are ignored, so another local process cannot end the
/// sign-in with a forged callback. Only the loopback interface is bound.
///
/// Available on macOS, iOS, visionOS and Linux (tvOS and watchOS have no browser to sign in with).
public final class SignInWithChatGPTLoopbackListener: @unchecked Sendable {
    /// Page shown in the browser after the callback arrives.
    public struct CompletionPage: Sendable, Equatable {
        /// Page title and heading after a successful callback.
        public var successTitle: String
        /// Body text after a successful callback.
        public var successMessage: String
        /// Heading when the callback carries an `error` (for example the user declined).
        public var failureTitle: String
        /// Body text when the callback carries an `error`.
        public var failureMessage: String

        /// Creates a completion page.
        /// - Parameters:
        ///   - successTitle: Success heading.
        ///   - successMessage: Success body.
        ///   - failureTitle: Failure heading.
        ///   - failureMessage: Failure body.
        public init(successTitle: String, successMessage: String, failureTitle: String, failureMessage: String) {
            self.successTitle = successTitle
            self.successMessage = successMessage
            self.failureTitle = failureTitle
            self.failureMessage = failureMessage
        }

        /// Default copy naming the app.
        /// - Parameter appName: App name.
        /// - Returns: A completion page.
        public static func `default`(appName: String) -> Self {
            let name = appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "the app" : appName
            return Self(
                successTitle: "Signed in with ChatGPT",
                successMessage: "You can close this window and return to \(name).",
                failureTitle: "Sign in with ChatGPT didn't finish",
                failureMessage: "You can close this window and return to \(name) to try again."
            )
        }
    }

    /// Bound port.
    public let port: UInt16
    /// Redirect URI for this listener: `http://127.0.0.1:<port>/auth/callback`.
    public let redirectURI: URL

    private let socketDescriptor: Int32
    private let page: CompletionPage
    private let lock = NSLock()
    private var expectedState: String?
    private var delivered: Result<URL, Error>?
    private var waiter: CheckedContinuation<URL, Error>?
    private var isStopped = false
    private var isSocketClosed = false

    private init(socketDescriptor: Int32, port: UInt16, page: CompletionPage) {
        self.socketDescriptor = socketDescriptor
        self.port = port
        self.redirectURI = SignInWithChatGPTConfiguration.callbackURL(port: port)
        self.page = page
    }

    deinit {
        self.stop()
    }

    /// Binds the loopback listener and starts accepting connections on a background thread.
    /// - Parameters:
    ///   - port: Preferred port (`0` picks an ephemeral port).
    ///   - allowsFallback: Bind an ephemeral port when `port` is in use.
    ///   - page: Completion page copy.
    /// - Returns: A running listener; call ``stop()`` when done.
    /// - Throws: ``SignInWithChatGPTError/callbackListenerUnavailable(_:)``.
    public static func start(
        port: UInt16 = SignInWithChatGPTConfiguration.defaultCallbackPort,
        allowsFallback: Bool = true,
        page: CompletionPage = .default(appName: "")
    ) throws -> SignInWithChatGPTLoopbackListener {
        let descriptor: Int32
        do {
            descriptor = try self.bindLoopback(port: port)
        } catch let error as BindError where error.code == EADDRINUSE && allowsFallback && port != 0 {
            do {
                descriptor = try self.bindLoopback(port: 0)
            } catch let fallback as BindError {
                throw SignInWithChatGPTError.callbackListenerUnavailable(fallback.message)
            }
        } catch let error as BindError {
            throw SignInWithChatGPTError.callbackListenerUnavailable(error.message)
        }
        guard let boundPort = self.boundPort(descriptor) else {
            _ = close(descriptor)
            throw SignInWithChatGPTError.callbackListenerUnavailable("could not read the bound port")
        }
        let listener = SignInWithChatGPTLoopbackListener(socketDescriptor: descriptor, port: boundPort, page: page)
        let thread = Thread { [weak listener] in
            listener?.acceptLoop()
        }
        thread.name = "OpenClawKit.SignInWithChatGPT.loopback"
        thread.start()
        return listener
    }

    /// Callback URL delivered so far, if any (non-blocking).
    public var receivedCallbackURL: URL? {
        self.lock.withLock {
            if case .success(let url)? = self.delivered {
                return url
            }
            return nil
        }
    }

    /// Only callbacks whose `state` equals `state` are delivered.
    /// - Parameter state: Pending authorization state.
    public func expect(state: String) {
        self.lock.withLock { self.expectedState = state }
    }

    /// Waits for the callback URL. Cancelling the task stops the listener.
    /// - Returns: The callback URL (`http://127.0.0.1:<port>/auth/callback?…`).
    /// - Throws: `CancellationError` when cancelled or stopped before a callback arrived.
    public func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                self.lock.lock()
                if let delivered = self.delivered {
                    self.lock.unlock()
                    continuation.resume(with: delivered)
                    return
                }
                if self.isStopped {
                    self.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.waiter = continuation
                self.lock.unlock()
            }
        } onCancel: {
            self.stop()
        }
    }

    /// Stops listening. Pending ``waitForCallback()`` calls throw `CancellationError`. Always call it
    /// when done: the accept thread keeps the listener alive until it stops or delivers a callback.
    public func stop() {
        self.lock.lock()
        guard !self.isStopped else {
            self.lock.unlock()
            return
        }
        self.isStopped = true
        let waiter = self.waiter
        self.waiter = nil
        if self.delivered == nil {
            self.delivered = .failure(CancellationError())
        }
        if !self.isSocketClosed {
            // Wakes the accept loop, which closes the descriptor; closing here could race with a
            // descriptor number being reused while the loop still polls it.
            _ = shutdown(self.socketDescriptor, Int32(SHUT_RDWR))
        }
        self.lock.unlock()
        waiter?.resume(throwing: CancellationError())
    }

    // MARK: - Accept loop

    private var stopped: Bool {
        self.lock.withLock { self.isStopped }
    }

    private func acceptLoop() {
        while !self.stopped {
            var descriptor = pollfd(fd: self.socketDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready <= 0 || self.stopped {
                continue
            }
            let client = accept(self.socketDescriptor, nil, nil)
            guard client >= 0 else { continue }
            if self.handle(client: client) {
                break
            }
        }
        self.lock.withLock {
            self.isSocketClosed = true
            _ = close(self.socketDescriptor)
        }
    }

    /// Serves one connection; returns `true` once the callback was delivered.
    private func handle(client: Int32) -> Bool {
        defer { _ = close(client) }
        Self.configureClientSocket(client)
        guard let target = Self.readRequestTarget(client) else {
            Self.respond(client, status: "400 Bad Request", html: nil)
            return false
        }
        guard target.method == "GET" else {
            Self.respond(client, status: "405 Method Not Allowed", html: nil)
            return false
        }
        let path = target.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard path == SignInWithChatGPTConfiguration.callbackPath else {
            Self.respond(client, status: "404 Not Found", html: nil)
            return false
        }
        guard let url = URL(string: "http://\(SignInWithChatGPTConfiguration.callbackHost):\(self.port)\(target.path)") else {
            Self.respond(client, status: "400 Bad Request", html: nil)
            return false
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = query.first { $0.name == "state" }?.value ?? ""
        let expected = self.lock.withLock { self.expectedState }
        if let expected, !SignInWithChatGPTAuthorizationCallback.constantTimeEquals(state, expected) {
            Self.respond(client, status: "400 Bad Request", html: nil)
            return false
        }
        let failed = query.contains { $0.name == "error" }
        let title = failed ? self.page.failureTitle : self.page.successTitle
        let message = failed ? self.page.failureMessage : self.page.successMessage
        Self.respond(client, status: "200 OK", html: Self.html(title: title, message: message))
        self.deliver(url)
        return true
    }

    private func deliver(_ url: URL) {
        self.lock.lock()
        guard self.delivered == nil else {
            self.lock.unlock()
            return
        }
        self.delivered = .success(url)
        let waiter = self.waiter
        self.waiter = nil
        self.lock.unlock()
        waiter?.resume(returning: url)
    }

    // MARK: - HTTP

    struct RequestTarget: Equatable {
        var method: String
        var path: String
    }

    /// Parses the request line of an HTTP/1.x request head.
    static func parseRequestLine(_ head: String) -> RequestTarget? {
        guard let line = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else { return nil }
        return RequestTarget(method: String(parts[0]), path: String(parts[1]))
    }

    private static func readRequestTarget(_ client: Int32) -> RequestTarget? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var head = Data()
        while head.count < 16_384 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            head.append(contentsOf: buffer[0..<count])
            if head.range(of: Data("\r\n\r\n".utf8)) != nil {
                break
            }
        }
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        return self.parseRequestLine(text)
    }

    private static func respond(_ client: Int32, status: String, html: String?) {
        let body = html ?? "<!doctype html><title>\(status)</title><p>\(status)</p>"
        let bodyData = Data(body.utf8)
        let head = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        let payload = [UInt8](Data(head.utf8) + bodyData)
        var offset = 0
        while offset < payload.count {
            let sent = payload.withUnsafeBytes { raw in
                send(client, raw.baseAddress!.advanced(by: offset), payload.count - offset, Self.sendFlags)
            }
            guard sent > 0 else { return }
            offset += sent
        }
    }

    static func html(title: String, message: String) -> String {
        let title = self.escapeHTML(title)
        let message = self.escapeHTML(message)
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>\(title)</title>\
        <style>body{font:16px -apple-system,system-ui,sans-serif;margin:0;min-height:100vh;display:flex;\
        align-items:center;justify-content:center;background:#fff;color:#0d0d0d}main{max-width:28rem;padding:2rem;\
        text-align:center}h1{font-size:1.4rem}@media (prefers-color-scheme:dark){body{background:#0d0d0d;color:#fff}}\
        </style></head><body><main><h1>\(title)</h1><p>\(message)</p></main></body></html>
        """
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Sockets

    private struct BindError: Error {
        let code: Int32
        let message: String
    }

    #if canImport(Glibc)
    private static let sendFlags = Int32(MSG_NOSIGNAL)
    #else
    private static let sendFlags: Int32 = 0
    #endif

    private static func bindLoopback(port: UInt16) throws -> Int32 {
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let descriptor = socket(AF_INET, streamType, 0)
        guard descriptor >= 0 else {
            throw BindError(code: errno, message: "socket() failed (errno \(errno))")
        }
        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port.bigEndian)
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            _ = close(descriptor)
            throw BindError(code: code, message: code == EADDRINUSE ? "port \(port) is in use" : "bind() failed (errno \(code))")
        }
        guard listen(descriptor, 8) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw BindError(code: code, message: "listen() failed (errno \(code))")
        }
        return descriptor
    }

    private static func boundPort(_ descriptor: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func configureClientSocket(_ client: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }
}
#endif
