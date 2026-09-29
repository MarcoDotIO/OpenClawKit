import Foundation

// Ported subset of upstream OpenClaw 2026.9.6 `ChatFullMessageReader.swift`: the route-capturing load request.
// The reader view belongs with the transcript views and should reuse this type.

/// A full-message load bound to the session route that was active when the reader opened.
struct ChatFullMessageReaderRequest: Identifiable, Sendable {
    let target: OpenClawChatSessionTarget
    let messageID: String
    private let transport: any OpenClawChatTransport

    @MainActor
    init(viewModel: OpenClawChatViewModel, messageID: String) {
        self.target = viewModel.currentSessionTarget
        self.messageID = messageID
        let transport = viewModel.transport
        self.transport = if viewModel.explicitSessionAgentID == nil, let agentID = self.target.agentID {
            transport.scoped(toAgentID: agentID) ?? transport
        } else {
            transport
        }
    }

    var id: String {
        "\(self.target.agentID ?? "")\u{0}\(self.target.sessionKey)\u{0}\(self.messageID)"
    }

    func load() async throws -> OpenClawChatMessage? {
        try await self.transport.requestFullMessage(sessionKey: self.target.sessionKey, messageID: self.messageID)
    }
}
