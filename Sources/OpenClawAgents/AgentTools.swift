import Foundation
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

/// Tool contract executed by the embedded runtime.
///
/// A tool implements at least one entry point:
/// - ``execute(arguments:)`` (v1): arguments in, JSON value out.
/// - ``invoke(_:update:)`` (v2): an ``AgentToolInvocation`` in, a structured ``AgentToolOutput``
///   out, with optional partial updates.
///
/// Each entry point has a default implementation built on the other, so v1 tools work with the v2
/// loop and v2 tools work with ``AgentToolRegistry/execute(_:)``. ``descriptor`` tells models what
/// the tool does; the default is derived from ``name`` with an empty parameter schema. Tools report
/// failures by throwing; the loop turns the error into an `isError` result. Cancellation uses
/// structured task cancellation.
public protocol AgentTool: Sendable {
    /// Stable tool name.
    var name: String { get }

    /// Model- and UI-facing description of the tool.
    var descriptor: AgentToolDescriptor { get }

    /// Executes tool logic with JSON-like argument map.
    /// - Parameter arguments: Tool input payload.
    /// - Returns: Tool output payload.
    func execute(arguments: [String: AnyCodable]) async throws -> AnyCodable

    /// Runs the tool for one invocation.
    /// - Parameters:
    ///   - invocation: Call identifier, arguments, and run context.
    ///   - update: Optional callback for partial results.
    /// - Returns: The final tool output.
    func invoke(_ invocation: AgentToolInvocation, update: AgentToolUpdateHandler?) async throws -> AgentToolOutput
}

public extension AgentTool {
    /// Default descriptor: `label` = `name`, empty description, empty-object parameter schema.
    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(name: self.name)
    }

    /// Default v2 entry point: calls ``execute(arguments:)`` and wraps the value with
    /// ``AgentToolOutput/json(_:)`` (the value becomes `details` plus one text block).
    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        // Reached from the default `execute` bridge: the tool implements neither entry point.
        guard !invocation.isExecuteBridge else {
            throw Self.missingEntryPointError(self.name)
        }
        return .json(try await self.execute(arguments: invocation.arguments))
    }

    /// Default v1 entry point: calls ``invoke(_:update:)`` and returns its `details`, or its text
    /// when there are no details. An error output throws.
    func execute(arguments: [String: AnyCodable]) async throws -> AnyCodable {
        var invocation = AgentToolInvocation(arguments: arguments)
        invocation.isExecuteBridge = true
        let output = try await self.invoke(invocation, update: nil)
        if output.isError {
            throw OpenClawCoreError.unavailable("Tool '\(self.name)' failed: \(output.text)")
        }
        return output.details ?? AnyCodable(output.text)
    }

    private static func missingEntryPointError(_ toolName: String) -> OpenClawCoreError {
        OpenClawCoreError.invalidConfiguration(
            "Agent tool '\(toolName)' must implement execute(arguments:) or invoke(_:update:)"
        )
    }
}

/// Tool invocation payload.
public struct AgentToolCall: Sendable, Equatable {
    /// Tool call identifier from the model (`nil` for calls built by hand; the registry assigns one).
    public let id: String?
    /// Tool name to execute.
    public let name: String
    /// Tool arguments.
    public let arguments: [String: AnyCodable]

    /// Creates a tool invocation payload.
    /// - Parameters:
    ///   - id: Optional tool call identifier.
    ///   - name: Tool name.
    ///   - arguments: Optional argument map.
    public init(id: String? = nil, name: String, arguments: [String: AnyCodable] = [:]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Creates a tool call from a model-proposed call; unparseable arguments become an empty map.
    /// - Parameter modelToolCall: Tool call proposed by a model provider.
    public init(_ modelToolCall: ModelToolCall) {
        self.init(id: modelToolCall.id, name: modelToolCall.name, arguments: modelToolCall.arguments ?? [:])
    }

    /// Generates a new tool call identifier (`call_<uuid>`).
    /// - Returns: A unique identifier.
    public static func makeID() -> String {
        "call_\(UUID().uuidString.lowercased())"
    }
}

/// Tool execution result payload.
public struct AgentToolResult: Sendable, Equatable {
    /// Executed tool name.
    public let name: String
    /// Identifier of the tool call this result answers (`nil` for v1 ``AgentToolRegistry/execute(_:)`` results).
    public let toolCallID: String?
    /// Structured tool output.
    public let output: AgentToolOutput
    /// Execution time in milliseconds, when measured.
    public let durationMs: Int?

    /// Tool return value: the output `details`, or its text when there are no details.
    public var value: AnyCodable {
        self.output.details ?? AnyCodable(self.output.text)
    }

    /// Whether the tool failed.
    public var isError: Bool {
        self.output.isError
    }

    /// Creates a tool result payload from a v1 value.
    /// - Parameters:
    ///   - name: Tool name.
    ///   - value: Tool output value.
    public init(name: String, value: AnyCodable) {
        self.init(name: name, toolCallID: nil, output: .json(value))
    }

    /// Creates a tool result payload from a structured output.
    /// - Parameters:
    ///   - name: Tool name.
    ///   - toolCallID: Identifier of the answered tool call.
    ///   - output: Structured tool output.
    ///   - durationMs: Optional execution time in milliseconds.
    public init(name: String, toolCallID: String?, output: AgentToolOutput, durationMs: Int? = nil) {
        self.name = name
        self.toolCallID = toolCallID
        self.output = output
        self.durationMs = durationMs.map { Swift.max(0, $0) }
    }

    /// Tool-result message for the model transcript (uses a generated identifier when ``toolCallID`` is `nil`).
    public var modelToolResult: ModelToolResult {
        self.output.modelToolResult(toolCallID: self.toolCallID ?? AgentToolCall.makeID(), toolName: self.name)
    }
}

/// Actor-backed registry for runtime tools.
public actor AgentToolRegistry {
    /// Upstream tool-name aliases (`src/agents/tool-policy-shared.ts`).
    public static let toolNameAliases: [String: String] = [
        "bash": "exec",
        "apply-patch": "apply_patch",
        "cron": "automations",
    ]

    private var tools: [String: any AgentTool] = [:]
    private var ownerPluginIDs: [String: String] = [:]

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
        self.ownerPluginIDs[tool.name] = nil
    }

    /// Registers a tool, validating its model-facing name and rejecting duplicates.
    /// - Parameters:
    ///   - tool: Tool implementation.
    ///   - ownerPluginID: Plugin that owns the tool, if any.
    ///   - replacing: Allow replacing an already registered tool with the same name.
    /// - Throws: ``OpenClawCoreError/invalidConfiguration(_:)`` for invalid names or duplicates.
    public func register(_ tool: any AgentTool, ownerPluginID: String?, replacing: Bool = false) throws {
        let name = tool.name
        guard AgentToolDescriptor.isValidName(name) else {
            throw OpenClawCoreError.invalidConfiguration(
                "Tool name '\(name)' must match ^[A-Za-z][A-Za-z0-9_-]{0,63}$"
            )
        }
        if !replacing, self.tools[name] != nil {
            let owner = self.ownerPluginIDs[name].map { " (owned by plugin '\($0)')" } ?? ""
            throw OpenClawCoreError.invalidConfiguration("Tool '\(name)' is already registered\(owner)")
        }
        self.tools[name] = tool
        let trimmedOwner = ownerPluginID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ownerPluginIDs[name] = trimmedOwner?.isEmpty == false ? trimmedOwner : nil
    }

    /// Removes a tool.
    /// - Parameter name: Tool name.
    /// - Returns: `true` when a tool was removed.
    @discardableResult
    public func unregister(named name: String) -> Bool {
        self.ownerPluginIDs[name] = nil
        return self.tools.removeValue(forKey: name) != nil
    }

    /// Returns whether a tool name is currently registered.
    /// - Parameter name: Tool name.
    /// - Returns: `true` when tool exists.
    public func hasTool(named name: String) -> Bool {
        self.tools[name] != nil
    }

    /// Returns a registered tool by exact name, falling back to its canonical alias.
    /// - Parameter name: Tool name or alias (for example `bash` for `exec`).
    /// - Returns: The tool, if registered.
    public func tool(named name: String) -> (any AgentTool)? {
        if let tool = self.tools[name] {
            return tool
        }
        return self.tools[Self.canonicalName(name)]
    }

    /// Plugin that owns a registered tool, when it was registered with one.
    /// - Parameter name: Tool name.
    /// - Returns: Owner plugin identifier.
    public func ownerPluginID(forTool name: String) -> String? {
        self.ownerPluginIDs[name]
    }

    /// Descriptors of every registered tool, sorted by name.
    /// - Returns: Tool descriptors.
    public func descriptors() -> [AgentToolDescriptor] {
        self.tools.keys.sorted().compactMap { self.tools[$0]?.descriptor }
    }

    /// Provider-facing tool declarations for every registered tool, sorted by name.
    /// - Returns: Model tool definitions.
    public func modelToolDefinitions() -> [ModelToolDefinition] {
        self.descriptors().modelToolDefinitions
    }

    /// Normalizes a tool name for policy matching: trims, lowercases, and applies upstream aliases
    /// (`bash` -> `exec`, `apply-patch` -> `apply_patch`, `cron` -> `automations`).
    /// - Parameter name: Tool name or alias.
    /// - Returns: Canonical tool name.
    public static func canonicalName(_ name: String) -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.toolNameAliases[normalized] ?? normalized
    }

    /// Executes a registered tool call (v1 path).
    /// - Parameter call: Tool invocation payload.
    /// - Returns: Tool execution result.
    public func execute(_ call: AgentToolCall) async throws -> AgentToolResult {
        guard let tool = self.tools[call.name] else {
            throw AgentRuntimeError.toolNotFound(call.name)
        }
        let value = try await tool.execute(arguments: call.arguments)
        return AgentToolResult(name: call.name, value: value)
    }

    /// Invokes a tool call through the v2 entry point, never throwing tool failures.
    ///
    /// Unknown tools produce an error result (`Tool not found: <name>`); errors thrown by the tool
    /// become `isError` results carrying the error description. Only task cancellation is rethrown.
    /// - Parameters:
    ///   - call: Tool call; a `call_<uuid>` identifier is assigned when `id` is `nil`.
    ///   - context: Run-scoped context.
    ///   - update: Optional callback for partial results.
    /// - Returns: The tool result, including timing.
    /// - Throws: `CancellationError` when the surrounding task is cancelled.
    public func invoke(
        _ call: AgentToolCall,
        context: AgentToolInvocationContext = AgentToolInvocationContext(),
        update: AgentToolUpdateHandler? = nil
    ) async throws -> AgentToolResult {
        let toolCallID = call.id ?? AgentToolCall.makeID()
        guard let tool = self.tool(named: call.name) else {
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Tool not found: \(call.name)"))
        }
        let invocation = AgentToolInvocation(toolCallID: toolCallID, arguments: call.arguments, context: context)
        let startedAt = Date()
        let output: AgentToolOutput
        do {
            output = try await tool.invoke(invocation, update: update)
        } catch let error as CancellationError {
            throw error
        } catch {
            try Task.checkCancellation()
            output = .error(Self.describe(error))
        }
        let durationMs = RuntimeTime.elapsedMilliseconds(since: startedAt)
        // Echo the called name: some providers require tool results to match the proposed call name.
        return AgentToolResult(name: call.name, toolCallID: toolCallID, output: output, durationMs: durationMs)
    }

    private static func describe(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return String(describing: error)
    }
}
