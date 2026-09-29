import Foundation
import Testing
@testable import OpenClawChannels
import OpenClawCore

@Suite("Channel outbound text chunker")
struct ChannelTextChunkerTests {
    @Test
    func shortTextIsOneChunkAndEmptyTextIsNone() {
        #expect(ChannelTextChunker.chunk("hello", limit: 10) == ["hello"])
        #expect(ChannelTextChunker.chunk("", limit: 10).isEmpty)
        #expect(ChannelTextChunker.chunk("hello world", limit: 0) == ["hello world"])
    }

    @Test
    func emojiHeavyRepliesStayWithinUTF16PlatformLimits() {
        let list = (0..<400).map { _ in "Item 😀 ok" }.joined(separator: "\n")
        #expect(list.count < 4_000)
        #expect(list.utf16.count > 4_000)
        let telegram = ChannelTextChunker.chunk(list, for: .telegram)
        #expect(telegram.count >= 2)
        #expect(telegram.allSatisfy { $0.utf16.count <= 4_000 })
        #expect(telegram.joined(separator: "\n") == list)
        #expect(ChannelTextChunker.chunk(list, limit: 4_000).allSatisfy { $0.utf16.count <= 4_000 })

        let sms = ChannelTextChunker.chunk(String(list.prefix(1_500)), for: .sms)
        #expect(sms.allSatisfy { $0.utf16.count <= 1_500 })
        for channel in [ChannelID.telegram, .sms, .line, .whatsapp, .discord, .signal, .slack] {
            #expect(channel.metadata.textChunking?.unit == .utf16, "\(channel.rawValue)")
        }
        #expect(ChannelID.googlechat.metadata.textChunking?.unit == .bytes)
    }

    @Test
    func prefersParagraphThenNewlineThenSentenceThenWhitespace() {
        let paragraphs = "First paragraph here.\n\nSecond paragraph here."
        #expect(ChannelTextChunker.chunk(paragraphs, limit: 30) == ["First paragraph here.", "Second paragraph here."])

        let lines = "line one is here\nline two is here"
        #expect(ChannelTextChunker.chunk(lines, limit: 20) == ["line one is here", "line two is here"])

        let sentences = "One sentence. Two words here"
        #expect(ChannelTextChunker.chunk(sentences, limit: 20) == ["One sentence.", "Two words here"])

        let words = "alpha beta gamma delta"
        let chunks = ChannelTextChunker.chunk(words, limit: 11)
        #expect(chunks == ["alpha beta", "gamma delta"])
    }

    @Test
    func everyChunkRespectsTheLimitInItsUnit() {
        let text = String(repeating: "word ", count: 400)
        for unit in ChannelTextChunkUnit.allCases {
            let chunks = ChannelTextChunker.chunk(text, limit: 97, unit: unit)
            #expect(chunks.count > 1)
            for chunk in chunks {
                #expect(ChannelTextChunker.measure(chunk, unit: unit) <= 97)
            }
        }
    }

    @Test
    func neverSplitsGraphemeClusters() {
        let family = "👨‍👩‍👧‍👦"
        let flags = "🇺🇸🇯🇵"
        let text = String(repeating: family, count: 10) + flags + String(repeating: "é", count: 5)
        let chunks = ChannelTextChunker.chunk(text, limit: 30, unit: .utf16)
        #expect(chunks.joined() == text)
        // Splitting a cluster would change the total Character count.
        #expect(chunks.map(\.count).reduce(0, +) == text.count)
        for chunk in chunks {
            #expect(ChannelTextChunker.measure(chunk, unit: .utf16) <= 30)
        }
        // Each family emoji is 11 UTF-16 units: two fit in 30.
        #expect(chunks.first == family + family)
    }

    @Test
    func byteUnitsHandleMultibyteText() {
        let text = String(repeating: "日本語", count: 20) // 3 bytes per character
        let chunks = ChannelTextChunker.chunk(text, limit: 30, unit: .bytes)
        #expect(chunks.allSatisfy { $0.utf8.count <= 30 })
        #expect(chunks.first?.count == 10)
        #expect(chunks.joined() == text)
    }

    @Test
    func oversizedSingleGraphemeStillMakesProgress() {
        let chunks = ChannelTextChunker.chunk("👍👍", limit: 1, unit: .bytes)
        #expect(chunks == ["👍", "👍"])
    }

    @Test
    func closesAndReopensFencedCodeBlocks() {
        let body = (1...30).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let text = "Intro text.\n\n```swift\n\(body)\n```\n\nOutro."
        let chunks = ChannelTextChunker.chunk(text, limit: 160)
        #expect(chunks.count > 2)
        for chunk in chunks {
            #expect(chunk.count <= 160)
            let fences = chunk.components(separatedBy: "\n").filter { $0.hasPrefix("```") }
            #expect(fences.count % 2 == 0, "unbalanced fences in chunk: \(chunk)")
        }
        let reopened = chunks.dropFirst().filter { $0.hasPrefix("```swift\n") }
        #expect(!reopened.isEmpty)
        #expect(chunks.last?.hasSuffix("Outro.") == true)
        // Reassembling the code body preserves every line.
        let joined = chunks.joined(separator: "\n")
        for index in 1...30 {
            #expect(joined.contains("let value\(index) = \(index)"))
        }
    }

    @Test
    func newlineModePacksParagraphs() {
        let text = "a1\n\nb2\n\nc3"
        #expect(ChannelTextChunker.chunk(text, limit: 100, mode: .newline) == ["a1\n\nb2\n\nc3"])
        #expect(ChannelTextChunker.chunk(text, limit: 7, mode: .newline) == ["a1\n\nb2", "c3"])
        let fenced = "```\nx\n\ny\n```\n\nafter"
        let chunks = ChannelTextChunker.chunk(fenced, limit: 14, mode: .newline)
        #expect(chunks.first == "```\nx\n\ny\n```")
        #expect(chunks.last == "after")
    }

    @Test
    func discordLineCapSplitsAtSeventeenLines() {
        let text = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let chunks = ChannelTextChunker.chunk(text, for: .discord)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.components(separatedBy: "\n").count <= 17 })
        #expect(chunks.joined(separator: "\n") == text)
    }

    @Test
    func lineCapKeepsFencesBalanced() {
        let code = (1...30).map { "print(\($0))" }.joined(separator: "\n")
        let chunks = ChannelTextChunker.chunk("```python\n\(code)\n```", limit: 2_000, maxLines: 10)
        #expect(chunks.count > 1)
        for chunk in chunks {
            let lines = chunk.components(separatedBy: "\n")
            #expect(lines.count <= 10)
            #expect(lines.filter { $0.hasPrefix("```") }.count == 2)
        }
    }

    @Test
    func googleChatUsesThirtyTwoThousandBytes() {
        let text = String(repeating: "é", count: 20_000) // 40,000 bytes
        let chunks = ChannelTextChunker.chunk(text, for: .googlechat)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.utf8.count <= 32_000 })
        #expect(chunks.first?.utf8.count == 32_000)
    }

    @Test
    func effectiveLimitUsesConfigClampedToPlatform() {
        var policy = ChannelMessagingPolicyConfig()
        policy.textChunkLimit = 10
        #expect(ChannelTextChunker.chunk("aaaa bbbb cccc", for: .telegram, policy: policy) == ["aaaa bbbb", "cccc"])
        policy.textChunkLimit = 100_000
        let long = String(repeating: "x", count: 5_000)
        #expect(ChannelTextChunker.chunk(long, for: .telegram, policy: policy).first?.count == 4_096)
        #expect(ChannelTextChunker.chunk(long, for: .telegram, policy: policy, richMessages: true).count == 1)
        #expect(ChannelTextChunker.chunk(String(repeating: "y", count: 1_700), for: .sms).count == 2)
    }
}
