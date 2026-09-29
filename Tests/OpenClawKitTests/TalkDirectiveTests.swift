import Foundation
import Testing
@testable import OpenClawKit

@Suite("Talk directives and voice aliases")
struct TalkDirectiveTests {
    @Test("resolves normalized voice aliases")
    func resolvesNormalizedVoiceAliases() {
        let raw: [String: Any] = [
            " Reader ": " Short-ID ", "longalias1": "mapped", "zero": "0",
            "blank": " ", " ": "ignored", "bool": false,
            "number": NSNumber(value: 0), "null": NSNull(),
        ]
        let aliases = TalkVoiceAliases.normalizedMap(AnyCodable.fromFoundation(raw))

        #expect(aliases == ["reader": "Short-ID", "longalias1": "mapped", "zero": "0"])
        #expect(TalkVoiceAliases.resolve(" READER ", aliases: aliases) == "Short-ID")
        #expect(TalkVoiceAliases.resolve("short-id", aliases: aliases) == "short-id")
        #expect(TalkVoiceAliases.resolve("longalias1", aliases: aliases) == "mapped")
        #expect(TalkVoiceAliases.resolve("abcdefghij", aliases: aliases) == "abcdefghij")
        #expect(TalkVoiceAliases.resolve("unknown", aliases: aliases) == nil)
        #expect(TalkVoiceAliases.resolve(nil, aliases: aliases) == nil)
        #expect(TalkVoiceAliases.normalizedMap(nil).isEmpty)
        #expect(TalkVoiceAliases.normalizedMap(AnyCodable("not-an-object")).isEmpty)
    }

    @Test("voice ids preserve Unicode character semantics")
    func voiceIDsPreserveUnicodeCharacterSemantics() {
        for voice in [
            "声声声声声声声声声声", "١٢٣٤٥٦٧٨٩٠", "abc_def-01",
            String(repeating: "e\u{301}", count: 10),
        ] {
            #expect(TalkVoiceAliases.resolve(voice, aliases: [:]) == voice)
        }
        for voice in ["abcdefghi", String(repeating: "e\u{301}", count: 9), "abc def012", "😀😀😀😀😀😀😀😀😀😀"] {
            #expect(TalkVoiceAliases.resolve(voice, aliases: [:]) == nil)
        }
    }

    @Test("parses a directive and strips its line")
    func parsesDirectiveAndStripsLine() {
        let result = TalkDirectiveParser.parse("""
        {"voice":"abc123","once":true}
        Hello there.
        """)
        #expect(result.directive?.voiceId == "abc123")
        #expect(result.directive?.once == true)
        #expect(result.stripped == "Hello there.")
    }

    @Test("ignores text without a directive")
    func ignoresNonDirective() {
        let text = "Hello world."
        let result = TalkDirectiveParser.parse(text)
        #expect(result.directive == nil)
        #expect(result.stripped == text)
    }

    @Test("keeps the directive line when no field is recognized")
    func keepsUnrecognizedDirectiveLine() {
        let text = """
        {"unknown":"value"}
        Hello.
        """
        let result = TalkDirectiveParser.parse(text)
        #expect(result.directive == nil)
        #expect(result.stripped == text)
    }

    @Test("parses extended options")
    func parsesExtendedOptions() {
        let directiveLine = #"{"voice_id":"v1","model_id":"m1","rate":200,"stability":0.5,"similarity":0.8,"style":0.2,"#
            + #""speaker_boost":true,"seed":1234,"normalize":"auto","lang":"en","output_format":"mp3_44100_128"}"#
        let result = TalkDirectiveParser.parse(directiveLine + "\nHello.")
        #expect(result.directive?.voiceId == "v1")
        #expect(result.directive?.modelId == "m1")
        #expect(result.directive?.rateWPM == 200)
        #expect(result.directive?.stability == 0.5)
        #expect(result.directive?.similarity == 0.8)
        #expect(result.directive?.style == 0.2)
        #expect(result.directive?.speakerBoost == true)
        #expect(result.directive?.seed == 1234)
        #expect(result.directive?.normalize == "auto")
        #expect(result.directive?.language == "en")
        #expect(result.directive?.outputFormat == "mp3_44100_128")
        #expect(result.stripped == "Hello.")
    }

    @Test("skips leading empty lines when parsing a directive")
    func skipsLeadingEmptyLines() {
        let result = TalkDirectiveParser.parse("""


        {"voice":"abc123"}
        Hello there.
        """)
        #expect(result.directive?.voiceId == "abc123")
        #expect(result.stripped == "Hello there.")
    }

    @Test("tracks unknown keys")
    func tracksUnknownKeys() {
        let result = TalkDirectiveParser.parse("""
        {"voice":"abc","mystery":"value","extra":1}
        Hi.
        """)
        #expect(result.directive?.voiceId == "abc")
        #expect(result.unknownKeys == ["extra", "mystery"])
    }
}
