import Foundation
import OpenClawProtocol

/// A `terminal.data` or `terminal.exit` event for one terminal session.
public enum GatewayTerminalEvent: Sendable {
    /// Output bytes (UTF-8 text as sent by the gateway) with their sequence number.
    case data(TerminalDataEvent)
    /// The terminal process exited.
    case exit(TerminalExitEvent)
}

/// Typed client for workspace terminals (`terminal.*`, upstream 2026.7.1).
///
/// Terminals need `operator.admin` and `gateway.terminal.enabled`; check ``isAvailable(advertisedMethods:)``
/// against hello-ok `features.methods` before showing terminal UI. Rendering (for example SwiftTerm)
/// is left to the app.
public struct GatewayTerminalClient: Sendable {
    /// Underlying request sender.
    public let sender: any GatewayRequestSending
    /// Request timeout in milliseconds (`nil` uses the channel default).
    public var timeoutMs: Double?

    /// Creates a terminal client.
    public init(sender: any GatewayRequestSending, timeoutMs: Double? = nil) {
        self.sender = sender
        self.timeoutMs = timeoutMs
    }

    /// Whether the gateway advertises the terminal surface.
    public static func isAvailable(advertisedMethods: [String]) -> Bool {
        let methods = Set(advertisedMethods)
        return methods.contains("terminal.open") && methods.contains("terminal.input")
    }

    /// `terminal.open`: starts a terminal for an agent workspace.
    public func open(agentId: String? = nil, sessionKey: String? = nil, cols: Int, rows: Int) async throws
        -> TerminalOpenResult
    {
        try await self.sender.request(
            method: "terminal.open",
            params: TerminalOpenParams(agentid: agentId, sessionkey: sessionKey, cols: cols, rows: rows),
            timeoutMs: self.timeoutMs)
    }

    /// `terminal.input`: writes input to the terminal.
    public func input(sessionId: String, data: String) async throws {
        _ = try await self.ack("terminal.input", TerminalInputParams(sessionid: sessionId, data: data))
    }

    /// `terminal.resize`.
    public func resize(sessionId: String, cols: Int, rows: Int) async throws {
        _ = try await self.ack("terminal.resize", TerminalResizeParams(sessionid: sessionId, cols: cols, rows: rows))
    }

    /// `terminal.close`.
    public func close(sessionId: String) async throws {
        _ = try await self.ack("terminal.close", TerminalCloseParams(sessionid: sessionId))
    }

    /// `terminal.attach`: attaches to an existing terminal and replays its recent output buffer.
    public func attach(sessionId: String) async throws -> TerminalAttachResult {
        try await self.sender.request(
            method: "terminal.attach",
            params: TerminalAttachParams(sessionid: sessionId),
            timeoutMs: self.timeoutMs)
    }

    /// `terminal.list`.
    public func list() async throws -> [TerminalSessionInfo] {
        let result: TerminalListResult = try await self.sender.request(method: "terminal.list", timeoutMs: self.timeoutMs)
        return result.sessions
    }

    /// `terminal.upload`: stages a file and inserts its quoted path at the prompt; it never executes it.
    public func upload(sessionId: String, name: String, contents: Data) async throws -> TerminalUploadResult {
        try await self.sender.request(
            method: "terminal.upload",
            params: TerminalUploadParams(sessionid: sessionId, name: name, contentbase64: contents.base64EncodedString()),
            timeoutMs: self.timeoutMs)
    }

    /// Filters gateway event frames to one terminal session's `terminal.data` / `terminal.exit` events.
    /// The stream finishes after the exit event or when `frames` ends.
    public static func events(
        from frames: AsyncStream<EventFrame>,
        sessionId: String) -> AsyncStream<GatewayTerminalEvent>
    {
        AsyncStream { continuation in
            let task = Task {
                for await frame in frames {
                    guard let event = self.decodeEvent(frame), event.sessionId == sessionId else { continue }
                    continuation.yield(event)
                    if case .exit = event { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decodes a terminal event frame; `nil` for other events.
    public static func decodeEvent(_ frame: EventFrame) -> GatewayTerminalEvent? {
        guard let payload = frame.payload, let data = try? JSONEncoder().encode(payload) else { return nil }
        switch frame.event {
        case GatewayEventName.terminalData.rawValue:
            return (try? JSONDecoder().decode(TerminalDataEvent.self, from: data)).map(GatewayTerminalEvent.data)
        case GatewayEventName.terminalExit.rawValue:
            return (try? JSONDecoder().decode(TerminalExitEvent.self, from: data)).map(GatewayTerminalEvent.exit)
        default:
            return nil
        }
    }

    private func ack(_ method: String, _ params: some Encodable) async throws -> TerminalAckResult {
        try await self.sender.request(method: method, params: params, timeoutMs: self.timeoutMs)
    }
}

extension GatewayTerminalEvent {
    /// Terminal session the event belongs to.
    public var sessionId: String {
        switch self {
        case let .data(event): event.sessionid
        case let .exit(event): event.sessionid
        }
    }
}

/// Typed client for browsing and previewing agent workspace files (`agents.workspace.*`).
///
/// The gateway enforces size caps and read-only scopes; previews of large or binary files may be
/// truncated or refused.
public struct GatewayWorkspaceFilesClient: Sendable {
    /// Underlying request sender.
    public let sender: any GatewayRequestSending
    /// Request timeout in milliseconds (`nil` uses the channel default).
    public var timeoutMs: Double?

    /// Creates a workspace files client.
    public init(sender: any GatewayRequestSending, timeoutMs: Double? = nil) {
        self.sender = sender
        self.timeoutMs = timeoutMs
    }

    /// `agents.workspace.list`: one page of a workspace directory.
    public func list(agentId: String, path: String? = nil, offset: Int? = nil, limit: Int? = nil) async throws
        -> AgentsWorkspaceListResult
    {
        try await self.sender.request(
            method: "agents.workspace.list",
            params: AgentsWorkspaceListParams(agentid: agentId, path: path, offset: offset, limit: limit),
            timeoutMs: self.timeoutMs)
    }

    /// `agents.workspace.get`: one file's preview content.
    public func get(agentId: String, path: String) async throws -> AgentsWorkspaceFile {
        let result: AgentsWorkspaceGetResult = try await self.sender.request(
            method: "agents.workspace.get",
            params: AgentsWorkspaceGetParams(agentid: agentId, path: path),
            timeoutMs: self.timeoutMs)
        return result.file
    }

    /// Decodes a file's `content` according to its `encoding` (`utf8` text or `base64` bytes).
    public static func contentData(of file: AgentsWorkspaceFile) -> Data? {
        switch file.encoding.stringValue?.lowercased() {
        case "base64":
            Data(base64Encoded: file.content)
        case "utf8", "utf-8", "text", nil:
            Data(file.content.utf8)
        default:
            nil
        }
    }
}
