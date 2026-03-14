import Foundation

public enum OpenClawChatTransportEvent: Sendable {
    case health(ok: Bool)
    case tick
    case chat(OpenClawChatEventPayload)
    case agent(OpenClawAgentEventPayload)
    case seqGap
}

public protocol OpenClawChatTransport: Sendable {
    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload
    func listModels() async throws -> [OpenClawChatModelChoice]
    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse

    func abortRun(sessionKey: String, runId: String) async throws
    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse
    func setSessionModel(sessionKey: String, model: String?) async throws
    func setSessionThinking(sessionKey: String, thinkingLevel: String) async throws

    func requestHealth(timeoutMs: Int) async throws -> Bool
    func events() -> AsyncStream<OpenClawChatTransportEvent>

    func setActiveSessionKey(_ sessionKey: String) async throws
    func resetSession(sessionKey: String) async throws
}

extension OpenClawChatTransport {
    /// Updates the active session key used for push-event routing.
    public func setActiveSessionKey(_: String) async throws {}

    /// Resets one session when the transport supports a server-side reset call.
    public func resetSession(sessionKey _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.reset not supported by this transport"])
    }

    /// Aborts the currently running assistant response for a session when supported.
    public func abortRun(sessionKey _: String, runId _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "chat.abort not supported by this transport"])
    }

    /// Lists recent sessions when the backing transport exposes multi-session history.
    public func listSessions(limit _: Int?) async throws -> OpenClawChatSessionsListResponse {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.list not supported by this transport"])
    }

    /// Lists available model picker choices when the transport supports model discovery.
    public func listModels() async throws -> [OpenClawChatModelChoice] {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "models.list not supported by this transport"])
    }

    /// Changes the current session model when the transport supports session patching.
    public func setSessionModel(sessionKey _: String, model _: String?) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.patch(model) not supported by this transport"])
    }

    /// Changes the current session thinking level when the transport supports session patching.
    public func setSessionThinking(sessionKey _: String, thinkingLevel _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.patch(thinkingLevel) not supported by this transport"])
    }
}
