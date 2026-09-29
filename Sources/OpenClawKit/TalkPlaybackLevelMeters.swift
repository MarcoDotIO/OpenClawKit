import AVFoundation
import Foundation

/// Normalizes an RMS value to the shared 0...1 UI level scale used by every
/// talk animation (mic, playback, recording) so the wave reads identically
/// across surfaces: dB full scale mapped over a 50 dB window.
public enum TalkAudioLevel {
    /// Maps a linear RMS amplitude (0...1) onto the normalized 0...1 level scale.
    /// - Parameter rms: Linear RMS amplitude.
    /// - Returns: A level clamped to 0...1.
    public static func normalized(rms: Double) -> Double {
        self.normalized(decibels: 20 * log10(max(rms, 1e-7)))
    }

    /// Maps a dBFS value onto the normalized 0...1 level scale (-50 dBFS → 0, 0 dBFS → 1).
    /// - Parameter decibels: Level in decibels relative to full scale.
    /// - Returns: A level clamped to 0...1.
    public static func normalized(decibels: Double) -> Double {
        max(0, min(1, (decibels + 50) / 50))
    }

    /// Average RMS across all channels of a float PCM buffer; 0 for degenerate
    /// buffers (Core Audio taps never deliver them in practice). Callable from
    /// realtime audio tap threads.
    /// - Parameter buffer: Float32 PCM buffer, interleaved or deinterleaved.
    /// - Returns: The linear RMS amplitude.
    public static func rms(buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        // Interleaved buffers expose one channel pointer that holds every channel's samples.
        let bufferCount = buffer.format.isInterleaved ? 1 : channelCount
        let samplesPerBuffer = buffer.format.isInterleaved ? frameCount * channelCount : frameCount
        var sum: Double = 0
        for channel in 0..<bufferCount {
            let samples = channelData[channel]
            for index in 0..<samplesPerBuffer {
                let sample = Double(samples[index])
                sum += sample * sample
            }
        }
        return (sum / Double(frameCount * channelCount)).squareRoot()
    }

    /// RMS of little-endian PCM16 mono bytes; 0 for empty data. A trailing odd byte is ignored.
    /// - Parameter data: Little-endian Int16 samples.
    /// - Returns: The linear RMS amplitude (0...1).
    public static func pcm16RMS(_ data: Data) -> Double {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return 0 }
        var sum: Double = 0
        data.withUnsafeBytes { raw in
            // `Data` slices are not guaranteed to be Int16-aligned, so load each sample unaligned.
            for index in 0..<sampleCount {
                let bits = raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                let sample = Double(Int16(littleEndian: bits)) / Double(Int16.max)
                sum += sample * sample
            }
        }
        return (sum / Double(sampleCount)).squareRoot()
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
extension TalkAudioLevel {
    /// Average RMS across all channels of a Sendable read-only PCM buffer (AVFAudio 27 taps).
    ///
    /// Iterates the buffer's `Span` channel views without unsafe pointers, so it can run on the
    /// realtime tap queue without crossing a non-Sendable `AVAudioPCMBuffer`.
    /// - Parameter buffer: Read-only PCM buffer in Float32, Int16, or Int32 format.
    /// - Returns: The linear RMS amplitude.
    public static func rms(buffer: AVReadOnlyAudioPCMBuffer) -> Double {
        let frameCount = buffer.frameLength
        guard frameCount > 0 else { return 0 }
        let channelCount = max(1, Int(buffer.format.channelCount))
        let interleaved = buffer.format.isInterleaved
        let bufferCount = interleaved ? 1 : channelCount
        let samplesPerBuffer = interleaved ? frameCount * channelCount : frameCount
        var sum: Double = 0
        var counted = 0
        for channel in 0..<bufferCount {
            switch buffer.channelData(channel) {
            case let .float(samples):
                let count = min(samplesPerBuffer, samples.count)
                for index in 0..<count {
                    let sample = Double(samples[index])
                    sum += sample * sample
                }
                counted += count
            case let .int16(samples):
                let count = min(samplesPerBuffer, samples.count)
                for index in 0..<count {
                    let sample = Double(samples[index]) / Double(Int16.max)
                    sum += sample * sample
                }
                counted += count
            case let .int32(samples):
                let count = min(samplesPerBuffer, samples.count)
                for index in 0..<count {
                    let sample = Double(samples[index]) / Double(Int32.max)
                    sum += sample * sample
                }
                counted += count
            @unknown default:
                continue
            }
        }
        guard counted > 0 else { return 0 }
        return (sum / Double(counted)).squareRoot()
    }
}
#endif

/// Builds a playback-time-aligned level envelope from PCM16 chunks that stream
/// through the app faster than real time (gateway TTS, provider PCM, realtime
/// relay output). Chunks are RMS-metered on arrival but scheduled at their
/// expected playback offset, so the published level tracks what is audible
/// instead of network arrival bursts.
@MainActor
public final class PCMPlaybackEnvelope {
    private struct Segment {
        let start: TimeInterval
        let end: TimeInterval
        let level: Double
    }

    private let onLevel: @MainActor (Double?) -> Void
    private var segments: [Segment] = []
    private var bytesPerSecond: Double = 0
    private var startedAt: ContinuousClock.Instant?
    private var scheduleEnd: TimeInterval = 0
    private var publishTask: Task<Void, Never>?

    /// Creates an envelope that publishes levels (or `nil` when idle) through `onLevel`.
    /// - Parameter onLevel: Receives normalized 0...1 levels at ~30 Hz, and `nil` on cancel.
    public init(onLevel: @escaping @MainActor (Double?) -> Void) {
        self.onLevel = onLevel
    }

    /// Starts a new envelope; the playback clock is anchored to the first chunk.
    /// - Parameter sampleRate: PCM16 mono sample rate in Hz.
    public func begin(sampleRate: Double) {
        self.cancel()
        self.bytesPerSecond = max(1, sampleRate * Double(MemoryLayout<Int16>.size))
    }

    /// Meters one PCM16 chunk and schedules its level at its expected playback offset.
    /// - Parameter chunk: Little-endian Int16 mono samples.
    public func append(_ chunk: Data) {
        guard self.bytesPerSecond > 1, !chunk.isEmpty else { return }
        let now = ContinuousClock.now
        if self.startedAt == nil {
            self.startedAt = now
            self.startPublishing()
        }
        guard let startedAt = self.startedAt else { return }
        let elapsed = Self.seconds(startedAt.duration(to: now))
        // Chunks queue behind whatever is already scheduled; a stalled stream
        // resumes at "now" instead of leaving a phantom backlog gap.
        var start = max(elapsed, self.scheduleEnd)
        // Meter in ~50 ms windows: a whole clip can arrive as one chunk, and a
        // single RMS for it would render a flat line instead of an envelope.
        let windowBytes = max(2, Int(self.bytesPerSecond * 0.05) & ~1)
        var offset = chunk.startIndex
        while offset < chunk.endIndex {
            let end = min(offset + windowBytes, chunk.endIndex)
            let window = chunk[offset..<end]
            let duration = Double(window.count) / self.bytesPerSecond
            self.segments.append(Segment(
                start: start,
                end: start + duration,
                level: TalkAudioLevel.normalized(rms: TalkAudioLevel.pcm16RMS(Data(window)))))
            start += duration
            offset = end
        }
        self.scheduleEnd = start
    }

    /// Passes PCM chunks through to a player while metering them into this
    /// envelope, so the published level follows the audible speech. Callers
    /// `cancel()` once playback returns.
    /// - Parameters:
    ///   - stream: Source PCM16 mono chunks.
    ///   - sampleRate: PCM sample rate in Hz.
    /// - Returns: A stream that yields the same chunks.
    public func metering(
        _ stream: AsyncThrowingStream<Data, Error>,
        sampleRate: Double) -> AsyncThrowingStream<Data, Error>
    {
        self.begin(sampleRate: sampleRate)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                do {
                    for try await chunk in stream {
                        self?.append(chunk)
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Stops immediately (interruption/teardown) and clears the published level.
    public func cancel() {
        self.publishTask?.cancel()
        self.publishTask = nil
        self.segments = []
        self.startedAt = nil
        self.scheduleEnd = 0
        self.onLevel(nil)
    }

    private func startPublishing() {
        self.publishTask?.cancel()
        self.publishTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.publish() else {
                    self.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    /// Publishes the level at the current playback position; false once the
    /// scheduled tail (plus a drain grace) has fully played out.
    private func publish() -> Bool {
        guard let startedAt = self.startedAt else { return false }
        let elapsed = Self.seconds(startedAt.duration(to: .now))
        if elapsed > self.scheduleEnd + 0.5 {
            return false
        }
        self.segments.removeAll { $0.end < elapsed }
        let level = self.segments.first { elapsed >= $0.start && elapsed < $0.end }?.level ?? 0
        self.onLevel(level)
        return true
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

/// Publishes the live output level of an `AVAudioPlayer` (buffered TTS clips)
/// via its built-in metering at ~30 Hz. Detach clears the level to nil so the
/// consumer can distinguish "silent" from "not playing".
@MainActor
final class AudioPlayerLevelMeter {
    private let onLevel: @MainActor (Double?) -> Void
    private var pollTask: Task<Void, Never>?
    private weak var player: AVAudioPlayer?

    init(onLevel: @escaping @MainActor (Double?) -> Void) {
        self.onLevel = onLevel
    }

    func attach(_ player: AVAudioPlayer) {
        self.detach()
        player.isMeteringEnabled = true
        self.player = player
        self.pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                player.updateMeters()
                self.onLevel(TalkAudioLevel.normalized(decibels: Double(player.averagePower(forChannel: 0))))
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    func detach() {
        self.pollTask?.cancel()
        self.pollTask = nil
        self.player = nil
        self.onLevel(nil)
    }
}
