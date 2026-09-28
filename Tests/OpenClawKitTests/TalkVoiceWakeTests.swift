import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

@Suite("Talk voice wake")
struct TalkVoiceWakeTests {
    private let triggers = ["openclaw", "hey claw"]

    @Test("a trigger followed by speech yields the command")
    func triggerWithCommandYieldsCommand() {
        #expect(TalkWakeWordMatcher.match(transcript: "OpenClaw, what's the weather?", triggers: self.triggers)
            == .command("what's the weather?", trigger: "openclaw"))
        #expect(TalkWakeWordMatcher.match(transcript: "hey claw turn on the lights", triggers: self.triggers)
            == .command("turn on the lights", trigger: "hey claw"))
    }

    @Test("trigger-only utterances are accepted so hosts can open listening mode")
    func triggerOnlyUtterancesAreAccepted() {
        #expect(TalkWakeWordMatcher.match(transcript: "OpenClaw", triggers: self.triggers) == .triggerOnly(trigger: "openclaw"))
        #expect(TalkWakeWordMatcher.match(transcript: "openclaw?", triggers: self.triggers) == .triggerOnly(trigger: "openclaw"))
        #expect(TalkWakeWordMatcher.match(transcript: "um, openclaw uh", triggers: self.triggers)
            == .triggerOnly(trigger: "openclaw"))
        #expect(TalkWakeWordMatcher.match(transcript: "openclaw ok", triggers: self.triggers, minCommandLength: 3)
            == .triggerOnly(trigger: "openclaw"))
    }

    @Test("leading fillers are allowed but other leading words are not")
    func leadingFillersAllowed() {
        #expect(TalkWakeWordMatcher.match(transcript: "um openclaw open notes", triggers: self.triggers)
            == .command("open notes", trigger: "openclaw"))
        #expect(TalkWakeWordMatcher.match(transcript: "tell openclaw something", triggers: self.triggers) == nil)
    }

    @Test("ASCII triggers need word boundaries and matching is diacritic insensitive")
    func asciiTriggersNeedWordBoundaries() {
        #expect(TalkWakeWordMatcher.match(transcript: "openclawish things", triggers: self.triggers) == nil)
        #expect(TalkWakeWordMatcher.match(transcript: "ÖpenClaw status", triggers: ["öpenclaw"])
            == .command("status", trigger: "öpenclaw"))
        #expect(TalkWakeWordMatcher.match(transcript: "", triggers: self.triggers) == nil)
        #expect(TalkWakeWordMatcher.match(transcript: "hello", triggers: []) == nil)
    }

    @Test("the longest trigger at the earliest position wins")
    func longestEarliestTriggerWins() {
        #expect(TalkWakeWordMatcher.matchedTriggerWord(
            transcript: "hey claw hey there",
            triggers: ["hey", "hey claw"]) == "hey claw")
    }

    @Test("wake transcripts route to the selected session through chat.send")
    func wakeTranscriptsRouteToSelectedSession() throws {
        #expect(TalkVoiceWakeRoute().targetSessionKey == "main")
        #expect(TalkVoiceWakeRoute(targetSessionKey: "  ").targetSessionKey == "main")
        let route = TalkVoiceWakeRoute(targetSessionKey: " agent:main:telegram:direct:12345 ")
        #expect(route.targetSessionKey == "agent:main:telegram:direct:12345")
        let parsed = try #require(route.sessionKeyRoute)
        #expect(parsed.channel == "telegram")
        #expect(parsed.to == "12345")
        #expect(TalkVoiceWakeRoute(targetSessionKey: "main").sessionKeyRoute == nil)

        let params = route.chatSendParams(transcript: "open notes", deviceName: "Studio Mac", idempotencyKey: "k-1")
        #expect(params.sessionkey == "agent:main:telegram:direct:12345")
        #expect(params.idempotencykey == "k-1")
        #expect(params.message.hasPrefix("User talked via voice recognition on Studio Mac"))
        #expect(params.message.hasSuffix("\n\nopen notes"))
        let verbatim = TalkVoiceWakeRoute(targetSessionKey: "chat-2").chatSendParams(transcript: "hi")
        #expect(verbatim.message == "hi")
        #expect(!verbatim.idempotencykey.isEmpty)
        let encoded = try #require(String(data: try JSONEncoder().encode(verbatim), encoding: .utf8))
        #expect(encoded.contains("\"sessionKey\":\"chat-2\""))
    }
}
