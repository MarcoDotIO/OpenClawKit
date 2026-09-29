import Foundation
import Testing
@testable import OpenClawKit

@MainActor
private final class ScriptedBufferedPlayer: TalkBufferedAudioPlaying {
    var result = StreamingPlaybackResult(finished: true)
    private(set) var played: [Data] = []
    private(set) var stopCount = 0

    func play(data: Data) async -> StreamingPlaybackResult {
        self.played.append(data)
        return self.result
    }

    func stop() -> Double? {
        self.stopCount += 1
        return nil
    }
}

@MainActor
private final class ScriptedPCMPlayer: PCMStreamingAudioPlaying {
    private(set) var sampleRates: [Double] = []
    private(set) var chunks: [Data] = []

    func play(stream: AsyncThrowingStream<Data, Error>, sampleRate: Double) async -> StreamingPlaybackResult {
        self.sampleRates.append(sampleRate)
        do {
            for try await chunk in stream {
                self.chunks.append(chunk)
            }
        } catch {}
        return StreamingPlaybackResult(finished: true)
    }

    func stop() -> Double? {
        nil
    }
}

@MainActor
private final class RecordingSystemVoice: TalkSystemSpeaking {
    var error: (any Error)?
    private(set) var spoken: [(text: String, language: String?)] = []
    private(set) var stopCount = 0
    private(set) var interruptCount = 0

    func speak(text: String, language: String?, onStart: (() -> Void)?) async throws {
        self.spoken.append((text, language))
        onStart?()
        if let error { throw error }
    }

    func stop() {
        self.stopCount += 1
    }

    func interruptForAudioSession() {
        self.interruptCount += 1
    }
}

private struct SynthesisFailure: Error {}

@Suite("Talk speech fallback chain")
@MainActor
struct TalkSpeechFallbackChainTests {
    private let request = TalkGatewaySpeechRequest(text: "Hello there", voiceId: "voice-1")

    @Test("gateway container audio plays through the buffered player")
    func gatewayContainerAudioPlaysBuffered() async throws {
        let buffered = ScriptedBufferedPlayer()
        let system = RecordingSystemVoice()
        let chain = TalkSpeechFallbackChain(
            gatewaySynthesis: { _ in TalkGatewaySpeechAudio(data: Data([9]), provider: "elevenlabs", outputFormat: "mp3_44100_128") },
            bufferedPlayer: buffered,
            systemVoice: system)

        let outcome = try await chain.speak(self.request, provider: "elevenlabs")

        #expect(outcome == .gateway(provider: "elevenlabs", playback: StreamingPlaybackResult(finished: true)))
        #expect(buffered.played == [Data([9])])
        #expect(system.spoken.isEmpty)
    }

    @Test("gateway PCM audio plays through the PCM player at its sample rate")
    func gatewayPCMAudioPlaysThroughPCMPlayer() async throws {
        let pcm = ScriptedPCMPlayer()
        let chain = TalkSpeechFallbackChain(
            gatewaySynthesis: { _ in TalkGatewaySpeechAudio(data: Data([1, 2]), provider: "openai", outputFormat: "pcm_16000") },
            bufferedPlayer: ScriptedBufferedPlayer(),
            pcmPlayer: pcm,
            systemVoice: RecordingSystemVoice())

        _ = try await chain.speak(self.request)

        #expect(pcm.sampleRates == [16000])
        #expect(pcm.chunks == [Data([1, 2])])
    }

    @Test("gateway synthesis failure falls back to the system voice")
    func synthesisFailureFallsBackToSystemVoice() async throws {
        let system = RecordingSystemVoice()
        let chain = TalkSpeechFallbackChain(
            gatewaySynthesis: { _ in throw SynthesisFailure() },
            bufferedPlayer: ScriptedBufferedPlayer(),
            systemVoice: system)

        let outcome = try await chain.speak(
            TalkGatewaySpeechRequest(text: "Hola", directive: TalkDirective(language: "es")),
            provider: "acme")

        #expect(outcome == .systemVoice)
        #expect(system.spoken.map(\.text) == ["Hola"])
        #expect(system.spoken.first?.language == "es")
    }

    @Test("a failed unstarted playback falls back, a stopped one does not")
    func playbackFailureFallsBackButStopDoesNot() async throws {
        let buffered = ScriptedBufferedPlayer()
        buffered.result = StreamingPlaybackResult(finished: false, interruptedAt: nil)
        let system = RecordingSystemVoice()
        let chain = TalkSpeechFallbackChain(
            gatewaySynthesis: { _ in TalkGatewaySpeechAudio(data: Data([9]), provider: "acme", outputFormat: nil) },
            bufferedPlayer: buffered,
            systemVoice: system)

        #expect(try await chain.speak(self.request) == .systemVoice)
        #expect(system.spoken.count == 1)

        buffered.result = StreamingPlaybackResult(finished: false, interruptedAt: 1.5)
        let outcome = try await chain.speak(self.request)
        #expect(outcome == .gateway(provider: "acme", playback: StreamingPlaybackResult(finished: false, interruptedAt: 1.5)))
        #expect(system.spoken.count == 1)
    }

    @Test("unsupported headerless audio and missing PCM players fall back to the system voice")
    func unsupportedAudioFallsBack() async throws {
        let system = RecordingSystemVoice()
        let raw = TalkSpeechFallbackChain(
            gatewaySynthesis: { _ in TalkGatewaySpeechAudio(data: Data([9]), provider: "acme", outputFormat: "ulaw_8000") },
            bufferedPlayer: ScriptedBufferedPlayer(),
            systemVoice: system)
        #expect(try await raw.speak(self.request) == .systemVoice)

        let pcmWithoutPlayer = TalkSpeechFallbackChain(
            gatewaySynthesis: { _ in TalkGatewaySpeechAudio(data: Data([9]), provider: "acme", outputFormat: "pcm_24000") },
            bufferedPlayer: ScriptedBufferedPlayer(),
            systemVoice: system)
        #expect(try await pcmWithoutPlayer.speak(self.request) == .systemVoice)
        #expect(system.spoken.count == 2)
    }

    @Test("the system provider and a missing gateway use the system voice only")
    func systemProviderSkipsGateway() async throws {
        var gatewayCalls = 0
        let system = RecordingSystemVoice()
        let chain = TalkSpeechFallbackChain(
            gatewaySynthesis: { _ in
                await MainActor.run { gatewayCalls += 1 }
                return TalkGatewaySpeechAudio(data: Data([9]), provider: "acme", outputFormat: nil)
            },
            bufferedPlayer: ScriptedBufferedPlayer(),
            systemVoice: system)
        #expect(try await chain.speak(self.request, provider: "System") == .systemVoice)
        #expect(gatewayCalls == 0)

        let noGateway = TalkSpeechFallbackChain(
            gatewaySynthesis: nil,
            bufferedPlayer: ScriptedBufferedPlayer(),
            systemVoice: system)
        #expect(try await noGateway.speak(self.request) == .systemVoice)
        #expect(system.spoken.count == 2)
    }

    @Test("a cancelled system utterance reports stopped and stop reaches every route")
    func cancelledSystemVoiceReportsStopped() async throws {
        let buffered = ScriptedBufferedPlayer()
        let system = RecordingSystemVoice()
        system.error = TalkSystemSpeechSynthesizer.SpeakError.canceled
        let chain = TalkSpeechFallbackChain(gatewaySynthesis: nil, bufferedPlayer: buffered, systemVoice: system)

        #expect(try await chain.speak(self.request) == .stopped)
        chain.stop()
        #expect(buffered.stopCount == 1)
        #expect(system.stopCount == 1)
    }

    @Test("other system voice errors propagate")
    func systemVoiceErrorsPropagate() async {
        let system = RecordingSystemVoice()
        system.error = SynthesisFailure()
        let chain = TalkSpeechFallbackChain(gatewaySynthesis: nil, bufferedPlayer: ScriptedBufferedPlayer(), systemVoice: system)
        await #expect(throws: SynthesisFailure.self) {
            try await chain.speak(self.request)
        }
    }

    @Test("the audio session controller routes interruptions and resumption")
    func audioSessionControllerRoutesEvents() async throws {
        let session = FakeTalkAudioSession()
        let speech = RecordingSystemVoice()
        let controller = TalkAudioSessionController(session: session, observeSystemEvents: false)
        controller.speech = speech
        var labels: [String?] = []
        var events: [TalkAudioSessionEvent] = []
        var resumes = 0
        controller.onStateLabelChange = { labels.append($0) }
        controller.onEvent = { events.append($0) }
        controller.onResume = { resumes += 1 }

        try await controller.activate()
        controller.handle(.interrupted)
        controller.handle(.resumptionRecommended(shouldResume: false))
        controller.handle(.resumptionRecommended(shouldResume: true))
        try await controller.deactivate()

        #expect(session.calls == ["activate", "deactivate"])
        #expect(speech.interruptCount == 1)
        #expect(resumes == 1)
        #expect(labels == ["active", "interrupted", "active", nil])
        #expect(controller.stateLabel == nil)
        #expect(events == [
            .activated,
            .interrupted,
            .resumptionRecommended(shouldResume: false),
            .resumptionRecommended(shouldResume: true),
            .deactivated,
        ])
        controller.invalidate()
    }

    @Test("an activation failure surfaces and leaves the state unchanged")
    func activationFailureSurfaces() async {
        let session = FakeTalkAudioSession()
        session.activationError = SynthesisFailure()
        let controller = TalkAudioSessionController(session: session, observeSystemEvents: false)
        await #expect(throws: SynthesisFailure.self) {
            try await controller.activate()
        }
        #expect(controller.stateLabel == nil)
    }
}

@MainActor
private final class FakeTalkAudioSession: TalkAudioSessionControlling {
    var activationError: (any Error)?
    private(set) var calls: [String] = []

    func activate() async throws {
        self.calls.append("activate")
        if let activationError { throw activationError }
    }

    func deactivate() async throws {
        self.calls.append("deactivate")
    }
}
