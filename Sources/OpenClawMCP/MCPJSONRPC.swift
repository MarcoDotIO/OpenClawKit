import Foundation
import OpenClawProtocol

/// JSON-RPC 2.0 request identifier (MCP clients use integers; servers may send strings).
public enum MCPRequestID: Codable, Sendable, Hashable, CustomStringConvertible {
    /// Integer id.
    case int(Int)
    /// String id.
    case string(String)

    /// Decodes an id.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    /// Encodes an id.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    /// Textual form.
    public var description: String {
        switch self {
        case .int(let value): return String(value)
        case .string(let value): return value
        }
    }

    /// JSON form.
    public var anyCodable: AnyCodable {
        switch self {
        case .int(let value): return AnyCodable(value)
        case .string(let value): return AnyCodable(value)
        }
    }
}

/// JSON-RPC error object.
public struct MCPJSONRPCError: Error, LocalizedError, Codable, Sendable, Equatable {
    /// Error code (`-32601` method not found, `-32602` invalid params, …).
    public let code: Int
    /// Message.
    public let message: String
    /// Optional structured data.
    public let data: AnyCodable?

    /// Creates an error.
    /// - Parameters:
    ///   - code: Code.
    ///   - message: Message.
    ///   - data: Data.
    public init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// Human-readable description.
    public var errorDescription: String? {
        "MCP error \(self.code): \(self.message)"
    }
}

/// One JSON-RPC 2.0 message exchanged with an MCP server.
public enum MCPJSONRPCMessage: Sendable, Equatable {
    /// Request expecting a response.
    case request(id: MCPRequestID, method: String, params: AnyCodable?)
    /// Notification (no response).
    case notification(method: String, params: AnyCodable?)
    /// Successful response.
    case response(id: MCPRequestID, result: AnyCodable)
    /// Error response.
    case error(id: MCPRequestID?, error: MCPJSONRPCError)

    /// Encodes the message as a JSON object.
    public var jsonObject: AnyCodable {
        var object: [String: AnyCodable] = ["jsonrpc": AnyCodable("2.0")]
        switch self {
        case .request(let id, let method, let params):
            object["id"] = id.anyCodable
            object["method"] = AnyCodable(method)
            if let params { object["params"] = params }
        case .notification(let method, let params):
            object["method"] = AnyCodable(method)
            if let params { object["params"] = params }
        case .response(let id, let result):
            object["id"] = id.anyCodable
            object["result"] = result
        case .error(let id, let error):
            object["id"] = id?.anyCodable ?? AnyCodable.nullValue
            var errorObject: [String: AnyCodable] = ["code": AnyCodable(error.code), "message": AnyCodable(error.message)]
            if let data = error.data { errorObject["data"] = data }
            object["error"] = AnyCodable(errorObject)
        }
        return AnyCodable(object)
    }

    /// Serializes the message as compact JSON (no embedded newlines).
    /// - Returns: UTF-8 JSON bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self.jsonObject)
    }

    /// Parses one message, or a batch array, from JSON data.
    /// - Parameter data: JSON bytes.
    /// - Returns: Parsed messages.
    public static func decode(_ data: Data) throws -> [MCPJSONRPCMessage] {
        let value = try JSONDecoder().decode(AnyCodable.self, from: data)
        if let array = value.arrayValue {
            return try array.map(Self.parse)
        }
        return [try Self.parse(value)]
    }

    /// Parses one JSON-RPC object.
    /// - Parameter value: JSON value.
    /// - Returns: The message.
    public static func parse(_ value: AnyCodable) throws -> MCPJSONRPCMessage {
        guard let object = value.dictionaryValue else {
            throw MCPJSONRPCError(code: -32600, message: "JSON-RPC message must be an object")
        }
        let id: MCPRequestID? = {
            switch object["id"]?.value {
            case .int(let int): return .int(int)
            case .double(let double) where double.rounded() == double: return .int(Int(double))
            case .string(let string): return .string(string)
            default: return nil
            }
        }()
        if let method = object["method"]?.stringValue {
            if let id {
                return .request(id: id, method: method, params: object["params"])
            }
            return .notification(method: method, params: object["params"])
        }
        if let error = object["error"]?.dictionaryValue {
            return .error(
                id: id,
                error: MCPJSONRPCError(
                    code: error["code"]?.intValue ?? -32603,
                    message: error["message"]?.stringValue ?? "unknown error",
                    data: error["data"]
                )
            )
        }
        if let id {
            return .response(id: id, result: object["result"] ?? AnyCodable([String: AnyCodable]()))
        }
        throw MCPJSONRPCError(code: -32600, message: "invalid JSON-RPC message")
    }
}

/// Incremental Server-Sent Events parser (WHATWG event-stream rules).
struct MCPSSEParser {
    /// One dispatched event.
    struct Event: Equatable {
        var event: String
        var data: String
        var id: String?
    }

    /// Upstream MCP SDK `STDIO_DEFAULT_MAX_BUFFER_SIZE` (10 MiB), also used as the SSE event cap.
    static let defaultMaxEventBytes = OpenClawMCP.defaultMaxMessageBytes

    private var buffer = Data()
    private var eventName = ""
    private var dataLines: [String] = []
    private var lastID: String?
    private var retainedBytes = 0
    let maxEventBytes: Int

    init(maxEventBytes: Int = MCPSSEParser.defaultMaxEventBytes) {
        self.maxEventBytes = maxEventBytes
    }

    /// Feeds bytes and returns completed events.
    mutating func feed(_ chunk: Data) throws -> [Event] {
        self.buffer.append(chunk)
        var events: [Event] = []
        while let newline = self.buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            var lineData = self.buffer[self.buffer.startIndex..<newline]
            var consumed = newline + 1
            if self.buffer[newline] == 0x0D, consumed < self.buffer.endIndex, self.buffer[consumed] == 0x0A {
                consumed += 1
            } else if self.buffer[newline] == 0x0D, consumed == self.buffer.endIndex {
                // A trailing CR may be the first half of CRLF; wait for more bytes.
                break
            }
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            let line = String(decoding: lineData, as: UTF8.self)
            self.buffer.removeSubrange(self.buffer.startIndex..<consumed)
            if let event = try self.process(line: line) {
                events.append(event)
            }
        }
        if self.buffer.count + self.retainedBytes > self.maxEventBytes {
            throw MCPTransportError.eventTooLarge(limit: self.maxEventBytes)
        }
        return events
    }

    /// Flushes a trailing event when the stream ends without a blank line.
    mutating func finish() -> Event? {
        if !self.buffer.isEmpty {
            let line = String(decoding: self.buffer, as: UTF8.self)
            self.buffer.removeAll()
            _ = try? self.process(line: line)
        }
        return self.dispatch()
    }

    private mutating func process(line: String) throws -> Event? {
        if line.isEmpty {
            return self.dispatch()
        }
        if line.hasPrefix(":") {
            return nil
        }
        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event":
            self.eventName = value
        case "data":
            self.retainedBytes += value.utf8.count + 1
            if self.retainedBytes > self.maxEventBytes {
                throw MCPTransportError.eventTooLarge(limit: self.maxEventBytes)
            }
            self.dataLines.append(value)
        case "id":
            if !value.contains("\0") { self.lastID = value }
        default:
            break
        }
        return nil
    }

    private mutating func dispatch() -> Event? {
        defer {
            self.eventName = ""
            self.dataLines = []
            self.retainedBytes = 0
        }
        guard !self.dataLines.isEmpty else { return nil }
        return Event(event: self.eventName.isEmpty ? "message" : self.eventName, data: self.dataLines.joined(separator: "\n"), id: self.lastID)
    }
}
