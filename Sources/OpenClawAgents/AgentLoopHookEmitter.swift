import Foundation
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

// Typed `HookRegistry` emission for the agent loop (upstream `src/agents/embedded-agent-runner/run/*`
// and `src/agents/harness/*-hook-helpers.ts`). Every call first checks `hasHandlers(for:)`, so runs
// without registered handlers never encode transcript payloads.

/// Upstream `wrapPluginSystemContextSection` header fencing plugin-provided system context.
public enum AgentHookSystemContext {
    /// Header line placed above plugin-injected system context.
    public static let header = "OpenClaw plugin-injected system context. This block is not workspace file content."

    /// Fences plugin system context so prompt compaction and transcript views can tell it apart from
    /// workspace files (upstream `wrapPluginSystemContextSection`).
    /// - Parameter value: Raw context.
    /// - Returns: The fenced section, or `nil` when `value` is empty.
    public static func wrap(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return "---\n\n\(Self.header)\n\n\(trimmed)\n\n---"
    }

    /// Joins hook system context around a base system prompt (upstream
    /// `composeSystemPromptWithHookContext`); `nil` when the hooks add nothing.
    /// - Parameters:
    ///   - base: Base system prompt.
    ///   - prepend: Context placed before the base prompt.
    ///   - append: Context placed after the base prompt.
    /// - Returns: The composed prompt, or `nil` when neither `prepend` nor `append` is set.
    public static func compose(base: String?, prepend: String?, append: String?) -> String? {
        let before = Self.wrap(prepend)
        let after = Self.wrap(append)
        guard before != nil || after != nil else { return nil }
        let parts = [before, base?.trimmingCharacters(in: .whitespacesAndNewlines), after]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.joined(separator: "\n\n")
    }

    /// Upstream `resolveBlockMessage` prefix used when a `before_agent_run` handler blocks a run.
    public static let blockMessagePrefix = "Your message could not be sent"

    /// Upstream `resolveBlockMessage`.
    /// - Parameters:
    ///   - message: Handler-provided user message.
    ///   - blockedBy: Blocking plugin (or hook) identifier.
    /// - Returns: The user-facing block message.
    public static func blockMessage(_ message: String?, blockedBy: String?) -> String {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let by = blockedBy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (text.isEmpty, by.isEmpty) {
        case (false, false):
            return "\(Self.blockMessagePrefix): \(text) (blocked by \(by))"
        case (false, true):
            return "\(Self.blockMessagePrefix): \(text)"
        case (true, false):
            return "\(Self.blockMessagePrefix): blocked by \(by)"
        case (true, true):
            return "\(Self.blockMessagePrefix): blocked"
        }
    }
}

/// Run-scoped wrapper around an optional shared ``HookRegistry``.
struct AgentLoopHookEmitter: Sendable {
    let registry: HookRegistry?
    let runID: String
    let sessionKey: String
    let agentID: String

    var context: HookContext {
        HookContext(runID: self.runID, sessionKey: self.sessionKey, agentID: self.agentID)
    }

    func has(_ hook: HookName) async -> Bool {
        guard let registry else { return false }
        return await registry.hasHandlers(for: hook)
    }

    /// Emits an observe-only hook; the event is only built when handlers exist.
    func observe<Event: Encodable & Sendable>(
        _ hook: HookName,
        metadata: [String: AnyCodable] = [:],
        _ event: @Sendable () -> Event
    ) async {
        guard let registry, await registry.hasHandlers(for: hook) else { return }
        var context = self.context
        context.metadata = metadata
        await registry.emitObserving(hook, event: event(), context: context)
    }

    // MARK: Gates and modifiers

    func beforeAgentRun(_ event: @Sendable () -> BeforeAgentRunEvent) async -> InputGateDecision {
        guard let registry, await registry.hasHandlers(for: .beforeAgentRun) else { return .pass }
        return await registry.runBeforeAgentRun(event(), context: self.context)
    }

    func beforeModelResolve(_ event: @Sendable () -> BeforeModelResolveEvent) async -> BeforeModelResolveResult? {
        guard let registry, await registry.hasHandlers(for: .beforeModelResolve) else { return nil }
        return await registry.runBeforeModelResolve(event(), context: self.context)
    }

    func beforePromptBuild(_ event: @Sendable () -> BeforePromptBuildEvent) async -> BeforePromptBuildResult? {
        guard let registry, await registry.hasHandlers(for: .beforePromptBuild) else { return nil }
        return await registry.runBeforePromptBuild(event(), context: self.context)
    }

    func beforeToolCall(_ event: BeforeToolCallEvent) async -> BeforeToolCallDecision? {
        guard let registry, await registry.hasHandlers(for: .beforeToolCall) else { return nil }
        return await registry.runBeforeToolCall(event, context: self.context)
    }

    func toolResultPersist(_ event: @Sendable () -> ToolResultPersistEvent) async -> ToolResultPersistResult? {
        guard let registry, await registry.hasHandlers(for: .toolResultPersist) else { return nil }
        return await registry.runToolResultPersist(event(), context: self.context)
    }

    func beforeMessageWrite(_ event: @Sendable () -> BeforeMessageWriteEvent) async -> BeforeMessageWriteResult? {
        guard let registry, await registry.hasHandlers(for: .beforeMessageWrite) else { return nil }
        return await registry.runBeforeMessageWrite(event(), context: self.context)
    }

    func messageSending(_ event: @Sendable () -> MessageSendingEvent) async -> MessageSendingResult? {
        guard let registry, await registry.hasHandlers(for: .messageSending) else { return nil }
        return await registry.runMessageSending(event(), context: self.context)
    }

    // MARK: Payload helpers

    /// JSON form of transcript messages for hook payloads.
    static func encode(_ messages: [AgentMessage]) -> [AnyCodable] {
        messages.compactMap { HookPayloadCoding.encode($0) }
    }

    /// JSON form of model messages for hook payloads.
    static func encode(_ messages: [ModelMessage]) -> [AnyCodable] {
        messages.compactMap { HookPayloadCoding.encode($0) }
    }

    /// Usage map in the upstream `llm_output` shape.
    static func usageMap(_ usage: ModelUsage?) -> [String: Int]? {
        guard let usage else { return nil }
        return [
            "input": usage.inputTokens,
            "output": usage.outputTokens,
            "cacheRead": usage.cacheReadTokens,
            "cacheWrite": usage.cacheWriteTokens,
            "total": usage.totalTokens,
        ]
    }
}

/// `before_reset` event (upstream `PluginHookBeforeResetEvent`), emitted before a session reset
/// rotates the transcript.
public struct AgentSessionResetHookEvent: Codable, Sendable, Equatable {
    /// Transcript file, when the store is file-backed.
    public var sessionFile: String?
    /// Messages on the transcript's active path before the reset.
    public var messages: [AnyCodable]?
    /// Reset reason (`reset`, `new`, `idle`, `daily`, …).
    public var reason: String?

    /// Creates the event.
    /// - Parameters:
    ///   - sessionFile: Transcript file.
    ///   - messages: Messages before the reset.
    ///   - reason: Reset reason.
    public init(sessionFile: String? = nil, messages: [AnyCodable]? = nil, reason: String? = nil) {
        self.sessionFile = sessionFile
        self.messages = messages
        self.reason = reason
    }
}
