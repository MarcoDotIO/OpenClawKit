import Foundation
import OpenClawProtocol

/// Route-bound request context for the model sign-in sheet.
///
/// Requests stay bound to the agent and physical connection captured when the sheet opens.
/// Ported from upstream `ChatModelSignIn.swift` (the sheet itself is a view-layer concern).
public struct OpenClawChatModelSignInContext: Sendable {
    /// Agent the sign-in targets.
    public let agentID: String
    /// Sends a gateway request (method, params) on the captured connection.
    public let request: @MainActor @Sendable (String, [String: AnyCodable]) async throws -> Data
    /// Whether the captured connection and presentation are still current.
    public let isCurrent: @MainActor @Sendable () async -> Bool

    /// Creates a sign-in context.
    public init(
        agentID: String,
        request: @escaping @MainActor @Sendable (String, [String: AnyCodable]) async throws -> Data,
        isCurrent: @escaping @MainActor @Sendable () async -> Bool)
    {
        self.agentID = agentID
        self.request = request
        self.isCurrent = isCurrent
    }
}
