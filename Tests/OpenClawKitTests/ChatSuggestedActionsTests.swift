import Foundation
import Testing
@testable import OpenClawChatUI

@Suite("Chat suggested actions input")
struct ChatSuggestedActionsTests {
    private func message(
        _ role: String,
        _ text: String,
        at timestamp: Double,
        provenance: OpenClawChatInputProvenance? = nil) -> OpenClawChatMessage
    {
        OpenClawChatMessage(
            role: role,
            content: [OpenClawChatMessageContent(type: "text", text: text, mimeType: nil, fileName: nil, content: nil)],
            timestamp: timestamp,
            provenance: provenance)
    }

    @Test func `only inbound messages with visible text produce suggestions`() {
        let user = self.message("user", "Book a table", at: 1000)
        let reply = self.message("assistant", "Call +1 555 0100 at 7pm", at: 2000)
        let thinkingOnly = self.message("assistant", "<think>plan</think>", at: 3000)
        let tool = self.message("toolResult", "ok", at: 4000)
        let history = [user, reply, thinkingOnly, tool]

        #expect(ChatSuggestedActionsInput(message: user, history: history, assistantName: nil, limit: 5) == nil)
        #expect(ChatSuggestedActionsInput(message: thinkingOnly, history: history, assistantName: nil, limit: 5) == nil)
        #expect(ChatSuggestedActionsInput(message: tool, history: history, assistantName: nil, limit: 5) == nil)

        let input = ChatSuggestedActionsInput(message: reply, history: history, assistantName: "Molty", limit: 5)
        #expect(input?.message.body == "Call +1 555 0100 at 7pm")
        #expect(input?.message.senderName == "Molty")
        #expect(input?.message.isFromUser == false)
        #expect(input?.message.date == Date(timeIntervalSince1970: 2))
        #expect(input?.previousMessages.map(\.body) == ["Book a table"])
        #expect(input?.previousMessages.first?.isFromUser == true)
    }

    @Test func `external channel users are inbound and history is capped to the latest entries`() {
        let external = self.message(
            "user",
            "Are we still on for Friday?",
            at: 5000,
            provenance: OpenClawChatInputProvenance(kind: "external_user", sourceChannel: "telegram"))
        let history = (0..<8).map { self.message($0.isMultiple(of: 2) ? "user" : "assistant", "m\($0)", at: Double($0)) }
            + [external]

        let input = ChatSuggestedActionsInput(message: external, history: history, assistantName: nil, limit: 3)

        #expect(input?.message.isFromUser == false)
        #expect(input?.message.senderName == "telegram")
        #expect(input?.previousMessages.map(\.body) == ["m5", "m6", "m7"])
        #expect(ChatSuggestedActionsInput(message: external, history: history, assistantName: nil, limit: 0)?
            .previousMessages.isEmpty == true)
    }
}
