import Foundation
import OpenClawCore

/// Error raised by ``FoundationModelsProvider`` with a stable, framework-independent code.
///
/// Apple framework errors (`LanguageModelError` on OS 27, the deprecated
/// `LanguageModelSession.GenerationError` on OS 26, Private Cloud Compute errors,
/// `GeneratedContent.ParsingError`, ...) are mapped onto these codes so routing, failover and
/// compaction can react without importing FoundationModels. ``coreError`` converts to the
/// two-case ``OpenClawCoreError`` for callers that only handle that type.
public struct FoundationModelsError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    /// Stable error code.
    public enum Code: String, Codable, Sendable, Equatable, CaseIterable {
        /// The model or its assets are unavailable.
        case unavailable
        /// The transcript exceeds the model's context window (compaction may help).
        case contextOverflow = "context_overflow"
        /// Requests are rate limited or the Private Cloud Compute quota is exhausted.
        case rateLimited = "rate_limited"
        /// A safety guardrail blocked the request or response.
        case guardrail
        /// The model refused to answer.
        case refusal
        /// The request needs a capability the model lacks (for example vision or reasoning).
        case unsupportedCapability = "unsupported_capability"
        /// The request uses unsupported content, guides, or a locale the model does not support.
        case unsupported
        /// Generation timed out.
        case timeout
        /// The session is already responding to another request.
        case busy
        /// The model returned structured output that fails the caller's schema.
        case invalidStructuredOutput = "invalid_structured_output"
        /// The request itself is malformed (for example an unmatched tool result).
        case invalidRequest = "invalid_request"
        /// A JSON Schema cannot be converted into a Foundation Models generation schema.
        case invalidSchema = "invalid_schema"
        /// Private Cloud Compute could not reach the network.
        case networkFailure = "network_failure"
        /// Private Cloud Compute is temporarily unavailable.
        case serviceUnavailable = "service_unavailable"
        /// An in-process tool failed.
        case toolFailed = "tool_failed"
        /// Any other framework error.
        case unknown
    }

    /// Stable error code.
    public var code: Code
    /// User-facing message (never echoes model output).
    public var message: String
    /// Whether retrying the same request later may succeed.
    public var retryable: Bool
    /// When a rate limit or quota resets, when known.
    public var resetDate: Date?
    /// Model context window for ``Code/contextOverflow``.
    public var contextSize: Int?
    /// Token count that overflowed the context window.
    public var tokenCount: Int?
    /// Missing capability name (`vision`, `reasoning`, `toolCalling`, `guidedGeneration`).
    public var capability: String?
    /// In-process tool calls (``FoundationModelsToolExecutionMode/executeInProcess(_:)``) that already
    /// ran before the request failed, in order. Record them in the transcript before retrying: a
    /// retry would run their side effects again. Non-empty values make the error non-retryable.
    public var executedToolCalls: [FoundationModelsExecutedToolCall]

    /// Creates an error.
    /// - Parameters:
    ///   - code: Stable error code.
    ///   - message: User-facing message.
    ///   - retryable: Whether a retry may succeed; defaults per code.
    ///   - resetDate: Rate-limit or quota reset date.
    ///   - contextSize: Context window for overflow errors.
    ///   - tokenCount: Overflowing token count.
    ///   - capability: Missing capability name.
    ///   - executedToolCalls: In-process tool calls that ran before the failure.
    public init(
        code: Code,
        message: String,
        retryable: Bool? = nil,
        resetDate: Date? = nil,
        contextSize: Int? = nil,
        tokenCount: Int? = nil,
        capability: String? = nil,
        executedToolCalls: [FoundationModelsExecutedToolCall] = []
    ) {
        self.code = code
        self.message = message
        self.retryable = executedToolCalls.isEmpty ? (retryable ?? Self.defaultRetryable(code)) : false
        self.resetDate = resetDate
        self.contextSize = contextSize
        self.tokenCount = tokenCount
        self.capability = capability
        self.executedToolCalls = executedToolCalls
    }

    /// A copy that records in-process tool calls which already ran; such errors are not retryable.
    /// - Parameter calls: Executed calls (no change when empty).
    /// - Returns: The error.
    func recordingExecutedToolCalls(_ calls: [FoundationModelsExecutedToolCall]) -> FoundationModelsError {
        guard !calls.isEmpty else { return self }
        var copy = self
        copy.executedToolCalls = calls
        copy.retryable = false
        let names = calls.map(\.call.name).joined(separator: ", ")
        copy.message += " In-process tools already ran (\(names)); record them before retrying."
        return copy
    }

    /// Localized description (the message).
    public var errorDescription: String? {
        self.message
    }

    /// `"<code>: <message>"`, so string-based failure classification sees the code.
    public var description: String {
        "\(self.code.rawValue): \(self.message)"
    }

    /// Equivalent ``OpenClawCoreError``: request/schema/capability problems become
    /// `invalidConfiguration`, everything else `unavailable`.
    public var coreError: OpenClawCoreError {
        switch self.code {
        case .invalidRequest, .invalidSchema, .unsupported, .unsupportedCapability, .invalidStructuredOutput:
            return .invalidConfiguration(self.description)
        default:
            return .unavailable(self.description)
        }
    }

    private static func defaultRetryable(_ code: Code) -> Bool {
        switch code {
        case .rateLimited, .timeout, .busy, .networkFailure, .serviceUnavailable:
            return true
        default:
            return false
        }
    }

    // MARK: Upstream messages

    /// Structured-output prefix used by upstream `stream.ts`.
    static let invalidStructuredResponsePrefix = "Apple Foundation Models returned an invalid structured response"

    /// Structured output contains a number that cannot be validated exactly.
    static let unsafeNumber = FoundationModelsError(
        code: .invalidStructuredOutput,
        message: "\(invalidStructuredResponsePrefix): an unsafe numeric value cannot be validated without losing precision."
    )

    /// Structured output is not valid JSON (the model text is never echoed).
    static let malformedJSON = FoundationModelsError(
        code: .invalidStructuredOutput,
        message: "\(invalidStructuredResponsePrefix): malformed JSON."
    )

    /// Structured output violates the caller's schema at the given paths.
    /// - Parameter paths: Violating instance paths (dotted, `<root>` for the root).
    /// - Returns: The error.
    static func schemaViolation(paths: [String]) -> FoundationModelsError {
        FoundationModelsError(
            code: .invalidStructuredOutput,
            message: "\(invalidStructuredResponsePrefix) at \(paths.joined(separator: ", "))."
        )
    }

    /// Malformed request (upstream helper `BridgeError` messages).
    /// - Parameter message: Upstream message.
    /// - Returns: The error.
    static func invalidRequest(_ message: String) -> FoundationModelsError {
        FoundationModelsError(code: .invalidRequest, message: message)
    }

    /// Unconvertible JSON Schema (upstream helper `dynamicSchema` messages).
    /// - Parameter message: Upstream message.
    /// - Returns: The error.
    static func invalidSchema(_ message: String) -> FoundationModelsError {
        FoundationModelsError(code: .invalidSchema, message: message)
    }
}
