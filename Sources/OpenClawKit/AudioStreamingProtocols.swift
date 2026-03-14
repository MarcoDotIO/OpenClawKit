import Foundation

#if canImport(ElevenLabsKit)
import ElevenLabsKit

public typealias StreamingPlaybackResult = ElevenLabsKit.StreamingPlaybackResult
public typealias StreamingAudioPlayer = ElevenLabsKit.StreamingAudioPlayer
public typealias PCMStreamingAudioPlayer = ElevenLabsKit.PCMStreamingAudioPlayer
#else
public struct StreamingPlaybackResult: Sendable, Equatable {
    public var durationSeconds: Double?

    public init(durationSeconds: Double? = nil) {
        self.durationSeconds = durationSeconds
    }
}
#endif

@MainActor
public protocol StreamingAudioPlaying {
    func play(stream: AsyncThrowingStream<Data, Error>) async -> StreamingPlaybackResult
    func stop() -> Double?
}

@MainActor
public protocol PCMStreamingAudioPlaying {
    func play(stream: AsyncThrowingStream<Data, Error>, sampleRate: Double) async -> StreamingPlaybackResult
    func stop() -> Double?
}

#if canImport(ElevenLabsKit)
extension StreamingAudioPlayer: StreamingAudioPlaying {}
extension PCMStreamingAudioPlayer: PCMStreamingAudioPlaying {}
#endif
