import Foundation
import OpenClawCore

// Contract glue between Apple Foundation Models types and the provider-neutral model contract:
// in-process tool executions travel on ``ModelGenerationResponse/executedToolCalls`` and
// context-window overflows are reported through ``ModelContextOverflowReporting``.

public extension FoundationModelsExecutedToolCall {
    /// Provider-neutral record of this execution.
    var modelExecutedToolCall: ModelExecutedToolCall {
        ModelExecutedToolCall(call: self.call, result: self.modelToolResult)
    }
}

public extension FoundationModelsGenerationResult {
    /// The response with ``executedToolCalls`` attached as ``ModelGenerationResponse/executedToolCalls``.
    var responseWithExecutedToolCalls: ModelGenerationResponse {
        guard !self.executedToolCalls.isEmpty else { return self.response }
        return self.response.withExecutedToolCalls(self.executedToolCalls.map(\.modelExecutedToolCall))
    }
}

extension FoundationModelsError: ModelContextOverflowReporting {
    /// Whether the error is a context-window overflow (``Code/contextOverflow``) that is safe to
    /// retry after compaction: `false` once in-process tools already ran
    /// (``executedToolCalls``), because an automatic retry would repeat their side effects.
    public var isContextOverflow: Bool {
        self.code == .contextOverflow && self.executedToolCalls.isEmpty
    }

    /// Model context window reported with the overflow.
    public var overflowContextSize: Int? {
        self.contextSize
    }

    /// Token count reported with the overflow.
    public var overflowTokenCount: Int? {
        self.tokenCount
    }
}
