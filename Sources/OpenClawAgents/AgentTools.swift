import Foundation
import OpenClawProtocol

/// Tool contract executed by the embedded runtime.
public protocol AgentTool: Sendable {
    /// Stable tool name.
    var name: String { get }
    /// Executes tool logic with JSON-like argument map.
    /// - Parameter arguments: Tool input payload.
    /// - Returns: Tool output payload.
    func execute(arguments: [String: AnyCodable]) async throws -> AnyCodable
}

/// Tool invocation payload.
public struct AgentToolCall: Sendable, Equatable {
    /// Tool name to execute.
    public let name: String
    /// Tool arguments.
    public let arguments: [String: AnyCodable]

    /// Creates a tool invocation payload.
    /// - Parameters:
    ///   - name: Tool name.
    ///   - arguments: Optional argument map.
    public init(name: String, arguments: [String: AnyCodable] = [:]) {
        self.name = name
        self.arguments = arguments
    }
}

/// Tool execution result payload.
public struct AgentToolResult: Sendable, Equatable {
    /// Executed tool name.
    public let name: String
    /// Tool return value.
    public let value: AnyCodable

    /// Creates a tool result payload.
    /// - Parameters:
    ///   - name: Tool name.
    ///   - value: Tool output value.
    public init(name: String, value: AnyCodable) {
        self.name = name
        self.value = value
    }
}

/// Actor-backed registry for runtime tools.
public actor AgentToolRegistry {
    private var tools: [String: any AgentTool] = [:]

    /// Creates an empty tool registry.
    public init(tools: [any AgentTool] = []) {
        for tool in tools {
            self.tools[tool.name] = tool
        }
    }

    /// Registers (or replaces) a tool implementation by name.
    /// - Parameter tool: Tool implementation.
    public func register(_ tool: any AgentTool) {
        self.tools[tool.name] = tool
    }

    /// Returns whether a tool name is currently registered.
    /// - Parameter name: Tool name.
    /// - Returns: `true` when tool exists.
    public func hasTool(named name: String) -> Bool {
        self.tools[name] != nil
    }

    /// Executes a registered tool call.
    /// - Parameter call: Tool invocation payload.
    /// - Returns: Tool execution result.
    public func execute(_ call: AgentToolCall) async throws -> AgentToolResult {
        guard let tool = self.tools[call.name] else {
            throw AgentRuntimeError.toolNotFound(call.name)
        }
        let value = try await tool.execute(arguments: call.arguments)
        return AgentToolResult(name: call.name, value: value)
    }
}
