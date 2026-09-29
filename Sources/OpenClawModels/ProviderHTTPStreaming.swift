import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Response head plus a line stream for incremental (SSE / NDJSON) model responses.
public struct ModelHTTPLineStream: Sendable {
    /// HTTP status code.
    public var statusCode: Int
    /// Response headers.
    public var headers: [String: String]
    /// Body lines without their line terminators; blank lines are preserved.
    public var lines: AsyncThrowingStream<String, Error>

    /// Creates a line stream.
    /// - Parameters:
    ///   - statusCode: HTTP status code.
    ///   - headers: Response headers.
    ///   - lines: Body lines.
    public init(statusCode: Int, headers: [String: String], lines: AsyncThrowingStream<String, Error>) {
        self.statusCode = statusCode
        self.headers = headers
        self.lines = lines
    }

    /// Wraps a fully buffered response as a line stream.
    /// - Parameter response: Buffered response.
    /// - Returns: A line stream replaying the body line by line.
    public static func buffered(_ response: HTTPResponseData) -> ModelHTTPLineStream {
        let lines = ModelHTTPLineSplitter.lines(in: response.body)
        return ModelHTTPLineStream(
            statusCode: response.statusCode,
            headers: response.headers,
            lines: AsyncThrowingStream { continuation in
                for line in lines {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        )
    }
}

/// HTTP transport that can deliver a response body incrementally.
///
/// Providers use it for `generateStream` when their transport conforms; other transports fall back
/// to a buffered request whose body is replayed line by line (same events, not incremental).
public protocol ModelHTTPStreamingTransport: Sendable {
    /// Executes a request and returns the response head with a body line stream.
    /// - Parameter request: Configured URL request.
    /// - Returns: Status, headers and body lines.
    func lineStream(for request: URLRequest) async throws -> ModelHTTPLineStream
}

/// Default HTTP transport for model providers: buffered requests plus incremental line streaming.
///
/// On Apple platforms streaming reads `URLSession.bytes(for:)`; on Linux the body is buffered and
/// replayed, because FoundationNetworking has no incremental byte API.
public actor ModelStreamingHTTPClient: ModelHTTPStreamingTransport {
    private let session: URLSession

    /// Creates a client.
    /// - Parameter session: Backing URL session (defaults to `.shared`).
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Executes a request and returns the buffered response.
    /// - Parameter request: Configured URL request.
    /// - Returns: Response metadata and body.
    public func data(for request: URLRequest) async throws -> HTTPResponseData {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw ProviderErrorRedaction.sanitize(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenClawCoreError.unavailable("Response was not HTTPURLResponse")
        }
        return HTTPResponseData(statusCode: http.statusCode, headers: Self.headers(of: http), body: data)
    }

    /// Executes a request and streams the body line by line.
    /// - Parameter request: Configured URL request.
    /// - Returns: Status, headers and body lines.
    public func lineStream(for request: URLRequest) async throws -> ModelHTTPLineStream {
        #if canImport(FoundationNetworking)
        return ModelHTTPLineStream.buffered(try await self.data(for: request))
        #else
        let session = self.session
        let (head, lines) = try await Self.startStreaming(session: session, request: request)
        return ModelHTTPLineStream(statusCode: head.statusCode, headers: head.headers, lines: lines)
        #endif
    }

    #if !canImport(FoundationNetworking)
    private struct ResponseHead: Sendable {
        var statusCode: Int
        var headers: [String: String]
    }

    /// Holds the request task so cancellation that arrives before the response head can cancel it.
    private final class StreamingTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var cancelled = false

        /// Stores the task, cancelling it at once when cancellation already happened.
        func store(_ task: Task<Void, Never>) {
            self.lock.lock()
            let alreadyCancelled = self.cancelled
            self.task = task
            self.lock.unlock()
            if alreadyCancelled {
                task.cancel()
            }
        }

        func cancel() {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    /// Starts `URLSession.bytes` and returns once the response head arrives.
    ///
    /// Cancelling the caller while it waits for the head cancels the in-flight request (so a proxy
    /// that holds headers back cannot keep generation and token spend running until the timeout);
    /// after the head, terminating the line stream cancels it.
    private static func startStreaming(
        session: URLSession,
        request: URLRequest
    ) async throws -> (ResponseHead, AsyncThrowingStream<String, Error>) {
        let (lines, lineContinuation) = AsyncThrowingStream<String, Error>.makeStream()
        let box = StreamingTaskBox()
        let head: ResponseHead = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { headContinuation in
                let task = Task {
                    var headDelivered = false
                    do {
                        try Task.checkCancellation()
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            throw OpenClawCoreError.unavailable("Response was not HTTPURLResponse")
                        }
                        headDelivered = true
                        headContinuation.resume(returning: ResponseHead(statusCode: http.statusCode, headers: Self.headers(of: http)))
                        var buffer: [UInt8] = []
                        buffer.reserveCapacity(1024)
                        for try await byte in bytes {
                            if byte == 0x0A {
                                lineContinuation.yield(ModelHTTPLineSplitter.decodeLine(buffer))
                                buffer.removeAll(keepingCapacity: true)
                            } else {
                                buffer.append(byte)
                            }
                        }
                        if !buffer.isEmpty {
                            lineContinuation.yield(ModelHTTPLineSplitter.decodeLine(buffer))
                        }
                        lineContinuation.finish()
                    } catch {
                        let sanitized = ProviderErrorRedaction.sanitize(error)
                        lineContinuation.finish(throwing: sanitized)
                        if !headDelivered {
                            headContinuation.resume(throwing: sanitized)
                        }
                    }
                }
                box.store(task)
                lineContinuation.onTermination = { _ in
                    task.cancel()
                }
            }
        } onCancel: {
            box.cancel()
        }
        return (head, lines)
    }
    #endif

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [String: String]()) { partial, entry in
            partial[String(describing: entry.key)] = String(describing: entry.value)
        }
    }
}

extension ModelStreamingHTTPClient: OpenAICompatibleHTTPTransport, AnthropicHTTPTransport, GeminiHTTPTransport,
    XAIHTTPTransport, BedrockHTTPTransport {}

/// Splits raw bodies into lines, stripping `\r\n` / `\n` terminators and preserving blank lines.
enum ModelHTTPLineSplitter {
    static func lines(in data: Data) -> [String] {
        var lines: [String] = []
        var buffer: [UInt8] = []
        for byte in data {
            if byte == 0x0A {
                lines.append(self.decodeLine(buffer))
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
        }
        if !buffer.isEmpty {
            lines.append(self.decodeLine(buffer))
        }
        return lines
    }

    static func decodeLine(_ bytes: [UInt8]) -> String {
        var slice = bytes[...]
        if slice.last == 0x0D {
            slice = slice.dropLast()
        }
        return String(decoding: slice, as: UTF8.self)
    }
}

/// One server-sent event.
struct ServerSentEvent: Sendable, Equatable {
    /// Event name (`event:` field), when present.
    var event: String?
    /// Joined `data:` payload.
    var data: String
}

/// Incremental SSE parser (WHATWG event-stream framing).
struct ServerSentEventParser {
    private var eventName: String?
    private var dataLines: [String] = []

    /// Consumes one line; returns an event when a blank line completes it.
    mutating func consume(_ line: String) -> ServerSentEvent? {
        if line.isEmpty {
            return self.dispatch()
        }
        if line.hasPrefix(":") {
            return nil
        }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " {
                value = value.dropFirst()
            }
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "event":
            self.eventName = String(value)
        case "data":
            self.dataLines.append(String(value))
        default:
            break
        }
        return nil
    }

    /// Flushes a trailing event that was not followed by a blank line.
    mutating func finish() -> ServerSentEvent? {
        self.dispatch()
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            self.eventName = nil
            self.dataLines.removeAll()
        }
        guard !self.dataLines.isEmpty else {
            return nil
        }
        return ServerSentEvent(event: self.eventName, data: self.dataLines.joined(separator: "\n"))
    }
}

/// Buffered-or-streaming HTTP exchange used by the provider engines.
struct ProviderHTTPExchange: Sendable {
    let providerID: String
    let send: @Sendable (URLRequest) async throws -> HTTPResponseData
    let streamingTransport: (any ModelHTTPStreamingTransport)?

    init(
        providerID: String,
        send: @escaping @Sendable (URLRequest) async throws -> HTTPResponseData,
        streamingTransport: (any ModelHTTPStreamingTransport)?
    ) {
        self.providerID = providerID
        self.send = send
        self.streamingTransport = streamingTransport
    }

    /// Sends a request and returns the 2xx response or throws a normalized error.
    ///
    /// Transport errors are rethrown through ``ProviderErrorRedaction/sanitize(_:)`` so request URLs
    /// never leak into error descriptions.
    func data(for request: URLRequest) async throws -> HTTPResponseData {
        let response: HTTPResponseData
        do {
            response = try await self.send(request)
        } catch {
            throw ProviderErrorRedaction.sanitize(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.statusError(providerID: self.providerID, statusCode: response.statusCode, body: response.body)
        }
        return response
    }

    /// Sends a request and returns its body lines (incremental when the transport supports it).
    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let stream: ModelHTTPLineStream
        do {
            if let streamingTransport {
                stream = try await streamingTransport.lineStream(for: request)
            } else {
                stream = ModelHTTPLineStream.buffered(try await self.send(request))
            }
        } catch {
            throw ProviderErrorRedaction.sanitize(error)
        }
        guard (200..<300).contains(stream.statusCode) else {
            var body = ""
            for try await line in stream.lines {
                body += line + "\n"
                if body.utf8.count > 16_384 {
                    break
                }
            }
            throw Self.statusError(providerID: self.providerID, statusCode: stream.statusCode, body: Data(body.utf8))
        }
        return stream.lines
    }

    /// Builds the provider error for a non-2xx response, appending the provider's error message.
    static func statusError(providerID: String, statusCode: Int, body: Data) -> OpenClawCoreError {
        if let detail = Self.errorDetail(from: body) {
            return .unavailable("\(providerID) request failed with status \(statusCode): \(detail)")
        }
        return .unavailable("\(providerID) request failed with status \(statusCode)")
    }

    private static func errorDetail(from body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        if let json = try? JSONDecoder().decode(AnyCodableErrorEnvelope.self, from: body), let message = json.message {
            return message
        }
        let text = String(decoding: body.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Reads `{"error":{"message":…}}`, `{"error":"…"}`, `{"message":…}` and array-wrapped variants.
private struct AnyCodableErrorEnvelope: Decodable {
    let message: String?

    private struct Detail: Decodable {
        let message: String?
    }

    private enum CodingKeys: String, CodingKey {
        case error
        case message
    }

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer(), let first = try? array.decode(AnyCodableErrorEnvelope.self) {
            self.message = first.message
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let detail = try? container.decode(Detail.self, forKey: .error), let message = detail.message {
            self.message = message
        } else if let message = try? container.decode(String.self, forKey: .error) {
            self.message = message
        } else {
            self.message = try? container.decode(String.self, forKey: .message)
        }
    }
}
