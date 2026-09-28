import Foundation

// OpenClawKit ships its own playback seams instead of depending on ElevenLabsKit (upstream's
// `Talk` trait). Hosts that use ElevenLabsKit players can conform them to these protocols with a
// small adapter that maps ElevenLabsKit's result into `StreamingPlaybackResult`.

/// Result returned after a streaming or buffered playback attempt.
///
/// Mirrors the upstream OpenClaw (ElevenLabsKit) result shape: `finished` is `true` only when
/// every queued sample drained; `interruptedAt` carries the playback position when playback was
/// stopped or failed part way through.
public struct StreamingPlaybackResult: Sendable, Equatable {
    /// Whether playback drained every queued sample. `false` when stopped, interrupted, or failed.
    public var finished: Bool
    /// Playback position, in seconds, at which playback was interrupted, when the player reports it.
    public var interruptedAt: Double?
    /// Total duration that was played, in seconds, when the player reports it.
    public var durationSeconds: Double?

    /// Creates a playback result.
    /// - Parameters:
    ///   - finished: Whether playback drained every queued sample.
    ///   - interruptedAt: Playback position in seconds when playback was interrupted.
    ///   - durationSeconds: Total played duration in seconds, when known.
    public init(finished: Bool, interruptedAt: Double? = nil, durationSeconds: Double? = nil) {
        self.finished = finished
        self.interruptedAt = interruptedAt
        self.durationSeconds = durationSeconds
    }

    /// Creates a completed playback result with an optional duration.
    ///
    /// Kept for source compatibility with 2026.2.x callers; the result reports `finished == true`.
    /// - Parameter durationSeconds: Total played duration in seconds, when known.
    public init(durationSeconds: Double? = nil) {
        self.init(finished: true, interruptedAt: nil, durationSeconds: durationSeconds)
    }
}

/// Playback contract for encoded audio streams.
@MainActor
public protocol StreamingAudioPlaying {
    /// Starts playback for a stream of encoded audio chunks.
    func play(stream: AsyncThrowingStream<Data, Error>) async -> StreamingPlaybackResult
    /// Stops playback and returns the elapsed duration when available.
    func stop() -> Double?
}

/// Playback contract for PCM audio streams (little-endian Int16 mono).
@MainActor
public protocol PCMStreamingAudioPlaying {
    /// Starts playback for a PCM stream at the provided sample rate.
    func play(stream: AsyncThrowingStream<Data, Error>, sampleRate: Double) async -> StreamingPlaybackResult
    /// Stops playback and returns the elapsed duration when available.
    func stop() -> Double?
}

/// Playback contract for complete, container-encoded audio clips (MP3, WAV, FLAC, AAC).
@MainActor
public protocol TalkBufferedAudioPlaying {
    /// Plays one complete clip and returns when it finishes, fails, or is stopped.
    func play(data: Data) async -> StreamingPlaybackResult
    /// Stops playback and returns the playback position when available.
    func stop() -> Double?
    /// Installs a handler for normalized (0...1) output levels; `nil` means not playing.
    func setLevelHandler(_ handler: (@MainActor (Double?) -> Void)?)
}

extension TalkBufferedAudioPlaying {
    /// Level metering is a UI nicety; test doubles and custom players may skip it.
    public func setLevelHandler(_: (@MainActor (Double?) -> Void)?) {}
}
