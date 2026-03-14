import Foundation

#if canImport(ElevenLabsKit)
import ElevenLabsKit

/// Result returned after streaming playback completes.
public typealias StreamingPlaybackResult = ElevenLabsKit.StreamingPlaybackResult
/// Player surface used for encoded audio streams.
public typealias StreamingAudioPlayer = ElevenLabsKit.StreamingAudioPlayer
/// Player surface used for raw PCM audio streams.
public typealias PCMStreamingAudioPlayer = ElevenLabsKit.PCMStreamingAudioPlayer
#else
/// Result returned after a streaming playback attempt.
public struct StreamingPlaybackResult: Sendable, Equatable {
    /// Total duration that was played when the player reports it.
    public var durationSeconds: Double?

    /// Creates a playback result with an optional duration.
    public init(durationSeconds: Double? = nil) {
        self.durationSeconds = durationSeconds
    }
}
#endif

/// Playback contract for encoded audio streams.
@MainActor
public protocol StreamingAudioPlaying {
    /// Starts playback for a stream of encoded audio chunks.
    func play(stream: AsyncThrowingStream<Data, Error>) async -> StreamingPlaybackResult
    /// Stops playback and returns the elapsed duration when available.
    func stop() -> Double?
}

/// Playback contract for PCM audio streams.
@MainActor
public protocol PCMStreamingAudioPlaying {
    /// Starts playback for a PCM stream at the provided sample rate.
    func play(stream: AsyncThrowingStream<Data, Error>, sampleRate: Double) async -> StreamingPlaybackResult
    /// Stops playback and returns the elapsed duration when available.
    func stop() -> Double?
}

#if canImport(ElevenLabsKit)
extension StreamingAudioPlayer: StreamingAudioPlaying {}
extension PCMStreamingAudioPlayer: PCMStreamingAudioPlaying {}
#endif
