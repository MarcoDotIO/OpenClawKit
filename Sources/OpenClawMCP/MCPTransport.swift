import Foundation

/// Errors raised by MCP transports and the client.
public enum MCPTransportError: Error, LocalizedError, Sendable, Equatable {
    /// The transport was closed; pending requests fail with this error.
    case closed(String)
    /// A request timed out.
    case timeout(method: String, milliseconds: Int)
    /// A single SSE event or stdio line exceeded the size cap.
    case eventTooLarge(limit: Int)
    /// HTTP failure.
    case http(status: Int, message: String)
    /// The server answered with an unexpected payload.
    case protocolViolation(String)
    /// The server negotiated a protocol version the client does not support.
    case unsupportedProtocolVersion(String)
    /// The transport cannot run on this platform (stdio on iOS-family platforms).
    case unsupportedOnPlatform(String)
    /// The server requires authorization (HTTP 401).
    case unauthorized(String)

    /// Human-readable description.
    public var errorDescription: String? {
        switch self {
        case .closed(let reason):
            return "MCP transport closed: \(reason)"
        case .timeout(let method, let milliseconds):
            return "MCP request \(method) timed out after \(milliseconds)ms"
        case .eventTooLarge(let limit):
            return "MCP SSE event exceeds \(limit) bytes"
        case .http(let status, let message):
            return "MCP HTTP error \(status): \(message)"
        case .protocolViolation(let message):
            return "MCP protocol violation: \(message)"
        case .unsupportedProtocolVersion(let version):
            return "MCP server negotiated unsupported protocol version \(version)"
        case .unsupportedOnPlatform(let message):
            return "MCP transport unsupported on this platform: \(message)"
        case .unauthorized(let message):
            return "MCP server requires authorization: \(message)"
        }
    }
}

/// Event delivered by a transport to the client.
public enum MCPTransportEvent: Sendable {
    /// A JSON-RPC message from the server.
    case message(MCPJSONRPCMessage)
    /// The transport closed (with an error when abnormal).
    case closed(MCPTransportError?)
}

/// A bidirectional JSON-RPC channel to one MCP server.
///
/// ``send(_:)`` delivers a message; responses and server-initiated messages arrive on
/// ``events``. Streamable HTTP transports may deliver the responses of a POST on the same stream.
public protocol MCPTransport: Sendable {
    /// Messages and close events from the server.
    var events: AsyncStream<MCPTransportEvent> { get }

    /// Opens the transport (spawns the process, opens the SSE stream, …).
    func start() async throws

    /// Sends one message.
    /// - Parameter message: JSON-RPC message.
    func send(_ message: MCPJSONRPCMessage) async throws

    /// Records the negotiated protocol version (HTTP transports send it as `MCP-Protocol-Version`).
    /// - Parameter version: Negotiated version.
    func setProtocolVersion(_ version: String) async

    /// Closes the transport; pending requests fail.
    func close() async
}

public extension MCPTransport {
    /// Default: transports that do not use the version header ignore it.
    func setProtocolVersion(_: String) async {}
}

/// Streaming HTTP client used by the HTTP transports (inject a fake in tests).
public protocol MCPHTTPStreaming: Sendable {
    /// Performs a request and streams the response body.
    /// - Parameter request: URL request.
    /// - Returns: The response head and a body byte stream.
    func stream(_ request: URLRequest) async throws -> (response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>)
}
