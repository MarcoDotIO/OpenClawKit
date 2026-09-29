import Foundation
import OpenClawCore
import OpenClawProtocol

// Additive contract pieces for providers that run tools themselves, report context overflow in a
// typed way, or authenticate with non-secret local markers.

/// A tool call a provider executed in-process while generating, with the result it fed back to the
/// model (see ``ModelGenerationResponse/executedToolCalls``).
public struct ModelExecutedToolCall: Sendable, Equatable, Codable {
    /// The executed call.
    public var call: ModelToolCall
    /// Result returned to the model.
    public var result: ModelToolResult

    /// Creates an executed-call record.
    /// - Parameters:
    ///   - call: The executed call.
    ///   - result: Result returned to the model (its `toolCallID` should match `call.id`).
    public init(call: ModelToolCall, result: ModelToolResult) {
        self.call = call
        self.result = result
    }

    /// Transcript messages for executed calls: one assistant message holding every call, then one
    /// tool-result message per call, in order. Empty input returns no messages.
    /// - Parameter calls: Executed calls.
    /// - Returns: Transcript messages.
    public static func transcriptMessages(for calls: [ModelExecutedToolCall]) -> [ModelMessage] {
        guard !calls.isEmpty else { return [] }
        return [.assistant(content: calls.map { .toolCall($0.call) })] + calls.map { .toolResult($0.result) }
    }
}

/// Errors that know they were caused by a context-window overflow.
///
/// Agent loops check this before falling back to message heuristics, so providers with structured
/// errors (for example ``FoundationModelsError`` with code `context_overflow`) trigger overflow
/// compaction reliably.
public protocol ModelContextOverflowReporting: Error {
    /// Whether the request overflowed the model's context window.
    var isContextOverflow: Bool { get }
    /// Model context window in tokens, when known.
    var overflowContextSize: Int? { get }
    /// Token count that overflowed, when known.
    var overflowTokenCount: Int? { get }
}

public extension ModelContextOverflowReporting {
    /// Default: unknown context size.
    var overflowContextSize: Int? { nil }
    /// Default: unknown token count.
    var overflowTokenCount: Int? { nil }
}

/// Helpers for provider credentials that are not secrets.
public enum ModelProviderSecrets {
    /// API-key markers that identify on-device or local auth profiles instead of carrying a secret
    /// (`apple-fm-local` for Apple Foundation Models).
    public static let nonSecretAuthMarkers: Set<String> = [FoundationModelsProvider.localAuthMarker]

    /// Whether an API key is a non-secret local marker; such keys are never forwarded as credentials
    /// and should not be reported as plaintext secrets.
    /// - Parameter apiKey: Configured API key.
    /// - Returns: `true` for a known marker.
    public static func isNonSecretAuthMarker(_ apiKey: String?) -> Bool {
        guard let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return false
        }
        return self.nonSecretAuthMarkers.contains(trimmed)
    }
}
