import Foundation
import OpenClawProtocol
import OSLog

/// Output-format helpers for gateway TTS audio.
public enum TalkSpeechOutputFormat {
    /// Sample rate of a raw PCM output format such as `pcm_24000` or `pcm-16000`.
    /// - Parameter outputFormat: Provider output format.
    /// - Returns: The sample rate in Hz, or `nil` for container or unknown formats.
    public static func pcmSampleRate(from outputFormat: String?) -> Double? {
        guard let format = outputFormat?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              format.hasPrefix("pcm")
        else { return nil }
        let digits = format.dropFirst(3).drop { $0 == "_" || $0 == "-" }
        guard let rate = Int(digits), rate > 0 else { return nil }
        return Double(rate)
    }

    /// Whether `outputFormat` is headerless audio that cannot be played without a sample rate.
    public static func isUnsupportedHeaderlessFormat(_ outputFormat: String?) -> Bool {
        guard let format = outputFormat?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return format.hasPrefix("raw-") || format.hasPrefix("raw_") || format == "pcm" ||
            format == "mulaw" || format == "alaw" ||
            format.hasPrefix("mulaw_") || format.hasPrefix("ulaw_") || format.hasPrefix("alaw_")
    }
}

/// Audio returned by gateway TTS (`talk.speak` or `tts.speak`).
public struct TalkGatewaySpeechAudio: Equatable, Sendable {
    /// How the audio must be played.
    public enum PlaybackMode: Equatable, Sendable {
        /// Raw PCM16 mono at the given sample rate.
        case pcm(sampleRate: Double)
        /// A complete container file (MP3, WAV, FLAC, AAC) for a buffered player.
        case buffered
        /// Headerless audio whose sample rate the protocol does not expose.
        case unsupportedRaw(codec: String)
    }

    /// Decoded audio bytes.
    public let data: Data
    /// Provider that synthesized the audio.
    public let provider: String
    /// Provider output format (for example `mp3_44100_128`, `pcm_24000`).
    public let outputFormat: String?

    /// Creates gateway speech audio.
    public init(data: Data, provider: String, outputFormat: String?) {
        self.data = data
        self.provider = provider
        self.outputFormat = outputFormat
    }

    /// How the audio must be played, derived from ``outputFormat``.
    public var playbackMode: PlaybackMode {
        if let sampleRate = TalkSpeechOutputFormat.pcmSampleRate(from: self.outputFormat) {
            return .pcm(sampleRate: sampleRate)
        }
        if TalkSpeechOutputFormat.isUnsupportedHeaderlessFormat(self.outputFormat),
           let codec = self.outputFormat?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        {
            // talk.speak does not expose the sample rate needed to play headerless audio.
            return .unsupportedRaw(codec: codec)
        }
        return .buffered
    }
}

/// One Talk reply to speak through the gateway speech chain.
public struct TalkGatewaySpeechRequest: Sendable {
    /// Text to speak.
    public let text: String
    /// Provider voice id (resolved from aliases).
    public let voiceId: String?
    /// Provider model id.
    public let modelId: String?
    /// Requested output format.
    public let outputFormat: String?
    /// Optional per-reply voice directive.
    public let directive: TalkDirective?

    /// Creates a speech request.
    public init(
        text: String,
        voiceId: String? = nil,
        modelId: String? = nil,
        outputFormat: String? = nil,
        directive: TalkDirective? = nil)
    {
        self.text = text
        self.voiceId = voiceId
        self.modelId = modelId
        self.outputFormat = outputFormat
        self.directive = directive
    }

    /// `talk.speak` parameters for this request (directive tuning included).
    public var speakParams: TalkSpeakParams {
        TalkSpeakParams(
            text: self.text,
            voiceid: self.directive?.voiceId ?? self.voiceId,
            modelid: self.directive?.modelId ?? self.modelId,
            outputformat: self.directive?.outputFormat ?? self.outputFormat,
            speed: self.directive?.speed,
            ratewpm: self.directive?.rateWPM,
            stability: self.directive?.stability,
            similarity: self.directive?.similarity,
            style: self.directive?.style,
            speakerboost: self.directive?.speakerBoost,
            seed: self.directive?.seed,
            normalize: self.directive?.normalize,
            language: self.directive?.language,
            latencytier: self.directive?.latencyTier)
    }
}

extension TalkGatewayClient {
    /// Synthesizes a Talk reply with `talk.speak`.
    /// - Throws: ``TalkGatewayClientError/emptyAudio(method:)`` when no audio is returned.
    public func synthesizeTalkSpeech(_ request: TalkGatewaySpeechRequest) async throws -> TalkGatewaySpeechAudio {
        let result = try await self.speak(request.speakParams)
        guard let data = Data(base64Encoded: result.audiobase64), !data.isEmpty else {
            throw TalkGatewayClientError.emptyAudio(method: TalkGatewayMethod.speak.rawValue)
        }
        return TalkGatewaySpeechAudio(data: data, provider: result.provider, outputFormat: result.outputformat)
    }

    /// Synthesizes playable speech for an assistant message with `tts.speak`.
    /// - Throws: ``TalkGatewayClientError/emptyAudio(method:)`` when no audio is returned.
    public func synthesizeMessageSpeech(text: String) async throws -> TalkGatewaySpeechAudio {
        let result = try await self.ttsSpeak(text: text)
        guard let data = Data(base64Encoded: result.audiobase64), !data.isEmpty else {
            throw TalkGatewayClientError.emptyAudio(method: TalkGatewayMethod.ttsSpeak.rawValue)
        }
        return TalkGatewaySpeechAudio(data: data, provider: result.provider, outputFormat: result.outputformat)
    }
}

/// Which speech route played a Talk reply.
public enum TalkSpeechOutcome: Equatable, Sendable {
    /// Gateway `talk.speak` audio played.
    case gateway(provider: String, playback: StreamingPlaybackResult)
    /// The on-device system voice spoke the reply.
    case systemVoice
    /// Playback was stopped before it completed; no fallback ran.
    case stopped
}

/// Speaks Talk replies with the macOS 2026.4.29 ordering: gateway `talk.speak` first, then the
/// on-device system voice when gateway synthesis or playback fails.
///
/// Realtime providers speak for themselves; use this chain when no realtime provider is
/// configured, or for the `system` Talk provider (system voice only).
@MainActor
public final class TalkSpeechFallbackChain {
    /// Synthesizes gateway speech; `nil` skips the gateway step.
    public typealias GatewaySynthesis = @Sendable (TalkGatewaySpeechRequest) async throws -> TalkGatewaySpeechAudio

    /// Talk provider id that selects the on-device voice only.
    public static let systemProviderID = "system"

    private let logger = Logger(subsystem: "ai.openclaw", category: "talk.tts")
    private let gatewaySynthesis: GatewaySynthesis?
    private let bufferedPlayer: any TalkBufferedAudioPlaying
    private let pcmPlayer: (any PCMStreamingAudioPlaying)?
    private let systemVoice: any TalkSystemSpeaking
    private var generation: UInt64 = 0

    /// Creates a fallback chain.
    /// - Parameters:
    ///   - gatewaySynthesis: Gateway speech (for example `client.synthesizeTalkSpeech`), or `nil`.
    ///   - bufferedPlayer: Player for container audio.
    ///   - pcmPlayer: Player for raw PCM audio; PCM replies fall back to the system voice without one.
    ///   - systemVoice: On-device voice.
    public init(
        gatewaySynthesis: GatewaySynthesis?,
        bufferedPlayer: any TalkBufferedAudioPlaying,
        pcmPlayer: (any PCMStreamingAudioPlaying)? = nil,
        systemVoice: any TalkSystemSpeaking)
    {
        self.gatewaySynthesis = gatewaySynthesis
        self.bufferedPlayer = bufferedPlayer
        self.pcmPlayer = pcmPlayer
        self.systemVoice = systemVoice
    }

    /// Speaks one reply.
    /// - Parameters:
    ///   - request: Reply text and voice settings.
    ///   - provider: Active Talk provider; ``systemProviderID`` skips the gateway.
    ///   - language: System-voice language.
    /// - Returns: The route that played the reply.
    /// - Throws: The system voice error when every route failed, or `CancellationError`.
    @discardableResult
    public func speak(
        _ request: TalkGatewaySpeechRequest,
        provider: String? = nil,
        language: String? = nil) async throws -> TalkSpeechOutcome
    {
        self.generation &+= 1
        let generation = self.generation
        let usesGateway = provider?.lowercased() != Self.systemProviderID
        if usesGateway, let gatewaySynthesis {
            do {
                let audio = try await gatewaySynthesis(request)
                try Task.checkCancellation()
                guard self.generation == generation else { return .stopped }
                if let playback = await self.play(audio) {
                    guard self.generation == generation else { return .stopped }
                    // A stopped clip reports its position; only an unstarted or failed clip falls back.
                    if playback.finished || playback.interruptedAt != nil {
                        return .gateway(provider: audio.provider, playback: playback)
                    }
                    self.logger.error("talk gateway audio playback failed; falling back to system voice")
                } else {
                    self.logger.error("talk gateway audio format unsupported; falling back to system voice")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.logger.error(
                    "talk gateway TTS failed: \(error.localizedDescription, privacy: .public); falling back to system voice")
            }
        }
        guard self.generation == generation else { return .stopped }
        do {
            try await self.systemVoice.speak(text: request.text, language: language ?? request.directive?.language, onStart: nil)
        } catch TalkSystemSpeechSynthesizer.SpeakError.canceled {
            return .stopped
        }
        return .systemVoice
    }

    /// Stops every route; an in-flight ``speak(_:provider:language:)`` returns ``TalkSpeechOutcome/stopped``.
    public func stop() {
        self.generation &+= 1
        _ = self.bufferedPlayer.stop()
        _ = self.pcmPlayer?.stop()
        self.systemVoice.stop()
    }

    private func play(_ audio: TalkGatewaySpeechAudio) async -> StreamingPlaybackResult? {
        switch audio.playbackMode {
        case .buffered:
            return await self.bufferedPlayer.play(data: audio.data)
        case let .pcm(sampleRate):
            guard let pcmPlayer = self.pcmPlayer else { return nil }
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(audio.data)
                continuation.finish()
            }
            return await pcmPlayer.play(stream: stream, sampleRate: sampleRate)
        case .unsupportedRaw:
            return nil
        }
    }
}
