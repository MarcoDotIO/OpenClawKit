import Foundation
import OpenClawKit
import Testing
@testable import OpenClawChatStore
@testable import OpenClawChatUI

// A gateway route change must not let branch scopes reconciled against the previous gateway
// context authorize an outbox replay on the new one (FX3 / F1 defense in depth).

private struct RouteChangeTransport: OpenClawChatTransport {
    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        OpenClawChatHistoryPayload(sessionKey: sessionKey, sessionId: "session-main", messages: [], thinkingLevel: "off")
    }

    func sendMessage(
        sessionKey _: String,
        message _: String,
        thinking _: String,
        idempotencyKey: String,
        attachments _: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        OpenClawChatSendResponse(runId: idempotencyKey, status: "started")
    }

    func requestHealth(timeoutMs _: Int) async throws -> Bool {
        true
    }

    func listSessions(
        limit _: Int?,
        search _: String?,
        archived _: Bool) async throws -> OpenClawChatSessionsListResponse
    {
        OpenClawChatSessionsListResponse(ts: nil, path: nil, count: 0, defaults: nil, sessions: [])
    }

    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { _ in }
    }
}

@MainActor
@Suite("Chat view model route change outbox fencing")
struct ChatViewModelRouteChangeOutboxTests {
    @Test func `route change drops branch scopes reconciled against the previous gateway`() throws {
        let (store, _, directory) = try makeOutboxStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = OpenClawChatOutboxScope(sessionKey: "main", agentID: nil)
        let viewModel = OpenClawChatViewModel(
            sessionKey: "main",
            transport: RouteChangeTransport(),
            outbox: store)
        viewModel.reconciledOutboxBranchScopes.insert(scope)
        let generation = viewModel.outboxBranchConnectionGeneration

        // A reconnect of the same connection context keeps the reconciliation.
        viewModel.handleTransportEvent(.seqGap)
        #expect(viewModel.reconciledOutboxBranchScopes.contains(scope))
        #expect(viewModel.outboxBranchConnectionGeneration == generation)

        // A different connection context (endpoint, credentials or gateway) must reconcile again.
        viewModel.handleTransportEvent(.routeChanged)
        #expect(!viewModel.reconciledOutboxBranchScopes.contains(scope))
        #expect(viewModel.outboxBranchConnectionGeneration != generation)
    }
}
