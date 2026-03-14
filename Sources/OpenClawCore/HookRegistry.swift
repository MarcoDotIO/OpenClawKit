import Foundation
import OpenClawProtocol

/// Built-in hook names emitted by runtime subsystems.
public enum HookName: String, Sendable {
    case beforeAgentStart = "before_agent_start"
    case afterToolCall = "after_tool_call"
    case gatewayStart = "gateway_start"
    case gatewayStop = "gateway_stop"
}

/// Hook execution context.
public struct HookContext: Sendable, Equatable {
    /// Optional run identifier.
    public let runID: String?
    /// Optional session key.
    public let sessionKey: String?
    /// Arbitrary metadata payload.
    public let metadata: [String: AnyCodable]

    /// Creates a hook execution context.
    /// - Parameters:
    ///   - runID: Optional run identifier.
    ///   - sessionKey: Optional session key.
    ///   - metadata: Arbitrary metadata payload.
    public init(runID: String? = nil, sessionKey: String? = nil, metadata: [String: AnyCodable] = [:]) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.metadata = metadata
    }
}

/// Hook return value.
public struct HookResult: Sendable, Equatable {
    /// Arbitrary metadata returned by hook handlers.
    public let metadata: [String: AnyCodable]

    /// Creates a hook result payload.
    /// - Parameter metadata: Result metadata map.
    public init(metadata: [String: AnyCodable] = [:]) {
        self.metadata = metadata
    }
}

/// Async hook handler signature.
public typealias HookHandler = @Sendable (HookContext) async throws -> HookResult?

/// Actor-backed registry for hook handlers.
public actor HookRegistry {
    private var handlers: [HookName: [HookHandler]] = [:]

    /// Creates an empty hook registry.
    public init() {}

    /// Registers a hook handler for a hook name.
    /// - Parameters:
    ///   - hook: Hook name.
    ///   - handler: Async hook handler.
    public func register(_ hook: HookName, handler: @escaping HookHandler) {
        var current = self.handlers[hook] ?? []
        current.append(handler)
        self.handlers[hook] = current
    }

    /// Emits a hook and collects non-nil handler results.
    /// - Parameters:
    ///   - hook: Hook name to emit.
    ///   - context: Hook execution context.
    /// - Returns: Collected hook results.
    public func emit(_ hook: HookName, context: HookContext) async throws -> [HookResult] {
        let handlers = self.handlers[hook] ?? []
        var results: [HookResult] = []
        for handler in handlers {
            if let result = try await handler(context) {
                results.append(result)
            }
        }
        return results
    }
}
