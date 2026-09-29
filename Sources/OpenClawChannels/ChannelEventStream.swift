import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Streams a long-lived HTTP response line by line (Server-Sent Events, NDJSON).
public protocol ChannelLineStreaming: Sendable {
    /// Opens the request and yields response lines (without the trailing newline).
    /// - Parameter request: Streaming request.
    /// - Returns: Line stream that finishes when the response ends.
    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error>
}

/// `URLSessionDataDelegate`-backed line streamer (works on Apple platforms and Linux).
public struct URLSessionChannelLineStreamer: ChannelLineStreaming {
    /// Creates a line streamer.
    public init() {}

    /// Opens the request and yields lines.
    /// - Parameter request: Streaming request.
    /// - Returns: Line stream.
    public func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let delegate = ChannelLineStreamDelegate(continuation: continuation)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        continuation.onTermination = { _ in
            task.cancel()
            session.invalidateAndCancel()
        }
        task.resume()
        return stream
    }
}

final class ChannelLineStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let lock = NSLock()
    private var buffer = Data()

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    private func locked<T>(_ body: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body()
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            self.continuation.finish(throwing: OpenClawCoreError.unavailable("Event stream failed with status \(http.statusCode)"))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        let lines: [String] = self.locked {
            self.buffer.append(data)
            var result: [String] = []
            while let index = self.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = self.buffer[self.buffer.startIndex..<index]
                if line.last == UInt8(ascii: "\r") {
                    line = line.dropLast()
                }
                result.append(String(decoding: line, as: UTF8.self))
                self.buffer.removeSubrange(self.buffer.startIndex...index)
            }
            return result
        }
        for line in lines {
            self.continuation.yield(line)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        let rest: Data = self.locked {
            defer { self.buffer.removeAll() }
            return self.buffer
        }
        if !rest.isEmpty {
            self.continuation.yield(String(decoding: rest, as: UTF8.self))
        }
        if let error {
            self.continuation.finish(throwing: error)
        } else {
            self.continuation.finish()
        }
    }
}

/// Minimal Server-Sent Events parser: accumulates `data:` lines until a blank line.
struct ChannelSSEParser {
    private var dataLines: [String] = []

    /// Feeds one line; returns the event data when a blank line completes an event.
    mutating func feed(_ line: String) -> String? {
        if line.isEmpty {
            defer { self.dataLines.removeAll() }
            return self.dataLines.isEmpty ? nil : self.dataLines.joined(separator: "\n")
        }
        if line.hasPrefix(":") {
            return nil
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") {
                value.removeFirst()
            }
            self.dataLines.append(value)
        }
        return nil
    }
}
