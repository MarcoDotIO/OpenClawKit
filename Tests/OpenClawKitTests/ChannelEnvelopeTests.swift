import Foundation
import Testing
@testable import OpenClawChannels

@Suite("Channel envelope v2")
struct ChannelEnvelopeTests {
    @Test
    func equalityIgnoresReceiveTimeAndReplyHelperTargetsTheConversation() {
        let first = InboundMessage(channel: .slack, peerID: "C1", text: "hi", senderID: "U1", chatType: .thread, messageID: "1.2", threadID: "1.0")
        var second = first
        second.receivedAt = first.receivedAt.addingTimeInterval(5)
        #expect(first == second)
        second.senderID = "U2"
        #expect(first != second)

        let reply = first.reply(text: "ok", replyNatively: true)
        #expect(reply.peerID == "C1")
        #expect(reply.replyToID == "1.2")
        #expect(reply.threadID == "1.0")
        #expect(reply.chatType == .thread)
        #expect(first.resolvedAccountID == "default")
        #expect(first.isDirect == false)
    }

    @Test
    func legacyInitializerStaysSourceCompatible() {
        let message = InboundMessage(channel: .telegram, accountID: "work", peerID: "1", text: "hi")
        #expect(message.chatType == .direct)
        #expect(message.eventKind == .userRequest)
        #expect(message.senderID == nil)
        let outbound = OutboundMessage(channel: .telegram, accountID: "work", peerID: "1", text: "hi")
        #expect(outbound.replyToID == nil)
        #expect(outbound.silent == false)
    }
}
