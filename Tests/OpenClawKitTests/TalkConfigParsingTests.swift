import Foundation
import Testing
@testable import OpenClawKit

@Suite("Talk config parsing")
struct TalkConfigParsingTests {
    @Test("prefers the canonical resolved talk provider payload")
    func prefersCanonicalResolvedPayload() {
        let talk: [String: AnyCodable] = [
            "resolved": AnyCodable([
                "provider": AnyCodable("elevenlabs"),
                "config": AnyCodable(["voiceId": "voice-resolved"]),
            ] as [String: AnyCodable]),
            "provider": AnyCodable("elevenlabs"),
            "providers": AnyCodable(["elevenlabs": ["voiceId": "voice-normalized"]]),
        ]

        let selection = TalkConfigParsing.selectProviderConfig(talk, defaultProvider: "elevenlabs")
        #expect(selection?.provider == "elevenlabs")
        #expect(selection?.normalizedPayload == true)
        #expect(selection?.config["voiceId"]?.stringValue == "voice-resolved")
    }

    @Test("rejects a normalized talk provider payload without resolved")
    func rejectsNormalizedPayloadWithoutResolved() {
        let talk: [String: AnyCodable] = [
            "provider": AnyCodable("elevenlabs"),
            "providers": AnyCodable(["elevenlabs": ["voiceId": "voice-normalized"]]),
            "voiceId": AnyCodable("voice-legacy"),
        ]

        #expect(TalkConfigParsing.selectProviderConfig(talk, defaultProvider: "elevenlabs") == nil)
        let snapshot = TalkConfigSnapshot(talk, defaultProvider: "elevenlabs", defaultSilenceTimeoutMs: 700)
        #expect(snapshot.missingResolvedPayload)
        #expect(snapshot.activeProvider == "elevenlabs")
        #expect(snapshot.providerConfig == nil)
    }

    @Test("falls back to legacy talk fields when the normalized payload is missing")
    func fallsBackToLegacyFields() {
        let talk: [String: AnyCodable] = [
            "voiceId": AnyCodable("voice-legacy"),
            "apiKey": AnyCodable("legacy-key"),
        ]

        let selection = TalkConfigParsing.selectProviderConfig(talk, defaultProvider: "elevenlabs")
        #expect(selection?.provider == "elevenlabs")
        #expect(selection?.normalizedPayload == false)
        #expect(selection?.config["voiceId"]?.stringValue == "voice-legacy")
        #expect(selection?.config["apiKey"]?.stringValue == "legacy-key")
    }

    @Test("legacy fallback can be disabled")
    func legacyFallbackCanBeDisabled() {
        let talk: [String: AnyCodable] = ["voiceId": AnyCodable("voice-legacy")]
        #expect(TalkConfigParsing.selectProviderConfig(
            talk,
            defaultProvider: "elevenlabs",
            allowLegacyFallback: false) == nil)
    }

    @Test("rejects normalized payloads whose provider is missing from providers or ambiguous")
    func rejectsMismatchedOrAmbiguousProviders() {
        let mismatch: [String: AnyCodable] = [
            "provider": AnyCodable("acme"),
            "providers": AnyCodable(["elevenlabs": ["voiceId": "voice-normalized"]]),
        ]
        #expect(TalkConfigParsing.selectProviderConfig(mismatch, defaultProvider: "elevenlabs") == nil)

        let ambiguous: [String: AnyCodable] = [
            "providers": AnyCodable([
                "acme": ["voiceId": "voice-acme"],
                "elevenlabs": ["voiceId": "voice-eleven"],
            ]),
        ]
        #expect(TalkConfigParsing.selectProviderConfig(ambiguous, defaultProvider: "elevenlabs") == nil)
    }

    @Test("bridges nested Foundation dictionaries")
    func bridgesFoundationDictionary() {
        let raw: [String: Any] = [
            "provider": "elevenlabs",
            "providers": ["elevenlabs": ["voiceId": "voice-normalized", "stability": 0.5]],
            "silenceTimeoutMs": NSNumber(value: 1500),
        ]

        let bridged = TalkConfigParsing.bridgeFoundationDictionary(raw)
        #expect(bridged?["provider"]?.stringValue == "elevenlabs")
        let nested = bridged?["providers"]?.dictionaryValue?["elevenlabs"]?.dictionaryValue
        #expect(nested?["voiceId"]?.stringValue == "voice-normalized")
        #expect(nested?["stability"]?.doubleValue == 0.5)
        #expect(TalkConfigParsing.resolvedSilenceTimeoutMs(bridged, fallback: 700) == 1500)
    }

    @Test("resolves positive integer timeouts and keeps integral doubles")
    func resolvesPositiveIntegerTimeouts() {
        #expect(TalkConfigParsing.resolvedPositiveInt(AnyCodable(1500), fallback: 700) == 1500)
        #expect(TalkConfigParsing.resolvedPositiveInt(AnyCodable(1500.0), fallback: 700) == 1500)
        #expect(TalkConfigParsing.resolvedPositiveInt(AnyCodable(1500.5), fallback: 700) == 700)
        #expect(TalkConfigParsing.resolvedPositiveInt(AnyCodable(0), fallback: 700) == 700)
        #expect(TalkConfigParsing.resolvedPositiveInt(AnyCodable(-5), fallback: 700) == 700)
        #expect(TalkConfigParsing.resolvedPositiveInt(AnyCodable(true), fallback: 700) == 700)
        #expect(TalkConfigParsing.resolvedPositiveInt(AnyCodable("1500"), fallback: 700) == 700)
        #expect(TalkConfigParsing.resolvedPositiveInt(nil, fallback: 700) == 700)
    }

    @Test("resolves and normalizes speech locale identifiers")
    func resolvesSpeechLocaleIdentifiers() {
        #expect(TalkConfigParsing.resolvedSpeechLocaleID(["speechLocale": AnyCodable(" ru_RU ")]) == "ru-RU")
        #expect(TalkConfigParsing.resolvedSpeechLocaleID(["speechLocale": AnyCodable("")], fallback: "en-US") == "en-US")
        #expect(TalkConfigParsing.normalizedSpeechLocaleID("  ") == nil)
        #expect(TalkConfigParsing.normalizedExplicitSpeechLocaleID("auto") == nil)
        #expect(TalkConfigParsing.normalizedExplicitSpeechLocaleID("pt_BR") == "pt-BR")
        #expect(TalkConfigParsing.normalizedExplicitSpeechLocaleID("system", automaticID: "system") == nil)
    }

    @Test("resolves the speech recognition locale from supported fallbacks")
    func resolvesRecognitionLocaleFromSupportedFallbacks() {
        let locale = TalkConfigParsing.resolvedSpeechRecognitionLocaleID(
            preferredLocaleIDs: ["zz-ZZ", "fr_FR"],
            supportedLocaleIDs: ["fr-FR", "en-US"])
        let fallback = TalkConfigParsing.resolvedSpeechRecognitionLocaleID(
            preferredLocaleIDs: ["zz-ZZ", nil, "yy-YY"],
            supportedLocaleIDs: ["en_US"])
        let unsupported = TalkConfigParsing.resolvedSpeechRecognitionLocaleID(
            preferredLocaleIDs: ["zz-ZZ"],
            fallbackLocaleID: "yy-YY",
            supportedLocaleIDs: ["en-US"])
        let unconstrained = TalkConfigParsing.resolvedSpeechRecognitionLocaleID(
            preferredLocaleIDs: [nil, "de-DE"],
            supportedLocaleIDs: [])

        #expect(locale == "fr-FR")
        #expect(fallback == "en-US")
        #expect(unsupported == nil)
        #expect(unconstrained == "de-DE")
    }

    @Test("firstNonEmptyString trims and honors key priority")
    func firstNonEmptyStringHonorsPriority() {
        let config: [String: AnyCodable] = [
            "speakerVoice": AnyCodable("  "),
            "voice": AnyCodable(" alloy "),
            "number": AnyCodable(3),
        ]
        #expect(TalkConfigParsing.firstNonEmptyString(config, keys: ["speakerVoice", "voice"]) == "alloy")
        #expect(TalkConfigParsing.firstNonEmptyString(config, keys: ["number"]) == nil)
        #expect(TalkConfigParsing.firstNonEmptyString(nil, keys: ["voice"]) == nil)
    }

    @Test("snapshot keeps speaker voice precedence separate from voice")
    func snapshotKeepsSpeakerVoicePrecedence() throws {
        let talk = try talkPayload("""
        {"realtime":{"provider":" OpenAI ","model":" top-model ","voice":" top-voice ",
          "providers":{"openai":{"model":"provider-model","speakerVoice":"provider-speaker","voice":"provider-voice"}}}}
        """)
        let snapshot = TalkConfigSnapshot(talk, defaultProvider: "elevenlabs", defaultSilenceTimeoutMs: 900)
        #expect(snapshot.realtime.provider == "OpenAI")
        #expect(snapshot.realtime.providerConfig?["model"]?.stringValue == "provider-model")
        #expect(snapshot.realtime.modelId == "top-model")
        #expect(snapshot.realtime.voice == "top-voice")
        #expect(snapshot.realtime.speakerVoice == "top-voice")
        #expect(snapshot.interruptOnSpeech == nil)

        let speakerOnly = TalkConfigSnapshot(try talkPayload("""
        {"interruptOnSpeech":false,
         "realtime":{"speakerVoice":" top-speaker ","providers":{"openai":{"voice":"provider-voice"}}}}
        """), defaultProvider: "elevenlabs", defaultSilenceTimeoutMs: 900)
        #expect(speakerOnly.realtime.provider == "openai")
        #expect(speakerOnly.realtime.voice == "provider-voice")
        #expect(speakerOnly.realtime.speakerVoice == "top-speaker")
        #expect(speakerOnly.interruptOnSpeech == false)
    }

    @Test("snapshot projects realtime routing, instructions and voice aliases")
    func snapshotProjectsRealtimeRouting() throws {
        let snapshot = TalkConfigSnapshot(try talkPayload("""
        {"resolved":{"provider":"ElevenLabs","config":{"voiceAliases":{" Reader ":" voice-reader-01 "}}},
         "silenceTimeoutMs":1200.0,"speechLocale":"en_GB",
         "realtime":{"provider":"openai","mode":"Realtime","transport":"Gateway-Relay","brain":"AGENT-CONSULT",
           "consultRouting":"Force-Agent-Consult","instructions":"  Keep answers short.  "}}
        """), defaultProvider: "system", defaultSilenceTimeoutMs: 700)

        #expect(snapshot.activeProvider == "elevenlabs")
        #expect(snapshot.normalizedPayload)
        #expect(!snapshot.missingResolvedPayload)
        #expect(snapshot.voiceAliases == ["reader": "voice-reader-01"])
        #expect(snapshot.silenceTimeoutMs == 1200)
        #expect(snapshot.speechLocaleID == "en-GB")
        #expect(snapshot.realtime.mode == "realtime")
        #expect(snapshot.realtime.transport == "gateway-relay")
        #expect(snapshot.realtime.brain == "agent-consult")
        #expect(snapshot.realtime.consultRouting == "force-agent-consult")
        #expect(snapshot.realtime.instructions == "Keep answers short.")
        #expect(snapshot.realtime.talkMode == .realtime)
        #expect(snapshot.realtime.talkTransport == .gatewayRelay)
        #expect(snapshot.realtime.talkBrain == .agentConsult)
        #expect(snapshot.realtime.usesGatewayRealtimeRelay)
        #expect(snapshot.realtime.modelId == nil)
        #expect(snapshot.realtime.clientSessionModelId == TalkRealtimeDefaults.openAIModel)
    }

    @Test("an absent talk payload uses defaults")
    func absentPayloadUsesDefaults() {
        let snapshot = TalkConfigSnapshot(nil, defaultProvider: "system", defaultSilenceTimeoutMs: 800)
        #expect(snapshot.activeProvider == "system")
        #expect(!snapshot.missingResolvedPayload)
        #expect(snapshot.silenceTimeoutMs == 800)
        #expect(snapshot.voiceAliases.isEmpty)
        #expect(snapshot.realtime.provider == nil)
        #expect(!snapshot.realtime.usesGatewayRealtimeRelay)
        #expect(snapshot.realtime.clientSessionModelId == nil)
    }

    private func talkPayload(_ json: String) throws -> [String: AnyCodable] {
        try JSONDecoder().decode([String: AnyCodable].self, from: Data(json.utf8))
    }
}

@Suite("Talk prompt builder")
struct TalkPromptBuilderTests {
    @Test("the prompt ends with the transcript")
    func promptEndsWithTranscript() {
        let prompt = TalkPromptBuilder.build(transcript: "Hello", interruptedAtSeconds: nil)
        #expect(prompt.contains("Talk Mode active."))
        #expect(prompt.hasSuffix("\n\nHello"))
    }

    @Test("the prompt includes the interruption point when provided")
    func promptIncludesInterruption() {
        let prompt = TalkPromptBuilder.build(transcript: "Hi", interruptedAtSeconds: 1.234)
        #expect(prompt.contains("Assistant speech interrupted at 1.2s."))
    }

    @Test("the voice directive hint is on by default and can be disabled")
    func voiceDirectiveHintToggles() {
        let withHint = TalkPromptBuilder.build(transcript: "Hello", interruptedAtSeconds: nil)
        #expect(withHint.contains("ElevenLabs voice (id or alias)"))
        let withoutHint = TalkPromptBuilder.build(
            transcript: "Hello",
            interruptedAtSeconds: nil,
            includeVoiceDirectiveHint: false)
        #expect(!withoutHint.contains("ElevenLabs voice"))
        #expect(withoutHint.contains("Talk Mode active."))
    }
}
