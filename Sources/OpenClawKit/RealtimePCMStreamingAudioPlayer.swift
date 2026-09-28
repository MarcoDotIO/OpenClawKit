#if canImport(AVFAudio) && (os(iOS) || os(macOS) || os(visionOS))
import AVFAudio
import Foundation

/// Low-latency PCM16 mono player for realtime Talk relay output.
///
/// Incoming chunks are re-framed into 20 ms buffers and scheduled on an `AVAudioPlayerNode`,
/// with at most three buffers queued at once so `stop()` (barge-in) silences output quickly.
/// Playback reports `finished == true` only after the input stream ended and every scheduled
/// buffer was played back.
@MainActor
public final class RealtimePCMStreamingAudioPlayer: PCMStreamingAudioPlaying {
    static let frameDurationSeconds = 0.020
    static let maxScheduledBuffers = 3

    typealias Completion = @Sendable () -> Void
    private let preparePlayback: (Double) throws -> Void
    private let scheduleFrame: (Data, Double, @escaping Completion) throws -> Void
    private let stopPlayback: () -> Void
    private let playbackTime: () -> Double?

    private var generation: UInt64 = 0
    private var nextBufferID: UInt64 = 0
    private var scheduledBufferIDs: Set<UInt64> = []
    private var slotWaiters: [CheckedContinuation<Bool, Never>] = []
    private var playbackContinuation: CheckedContinuation<StreamingPlaybackResult, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputFinished = false

    /// Creates a player backed by its own `AVAudioEngine` and `AVAudioPlayerNode`.
    ///
    /// The host owns the audio session (category and activation) on iOS and visionOS.
    public convenience init() {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        var format: AVAudioFormat?
        self.init(
            preparePlayback: { sampleRate in
                node.stop()
                engine.stop()
                engine.disconnectNodeOutput(node)
                guard let nextFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false)
                else {
                    throw NSError(domain: "RealtimePCMStreamingAudioPlayer", code: 1)
                }
                format = nextFormat
                engine.connect(node, to: engine.mainMixerNode, format: nextFormat)
                engine.prepare()
                try engine.start()
                node.play()
            },
            scheduleFrame: { data, _, completion in
                guard let format else {
                    throw NSError(domain: "RealtimePCMStreamingAudioPlayer", code: 2)
                }
                try Self.schedule(data: data, format: format, on: node, completion: completion)
            },
            stopPlayback: {
                node.stop()
                engine.stop()
            },
            playbackTime: {
                guard let renderTime = node.lastRenderTime,
                      let playerTime = node.playerTime(forNodeTime: renderTime)
                else { return nil }
                return Double(playerTime.sampleTime) / playerTime.sampleRate
            })
    }

    init(
        preparePlayback: @escaping (Double) throws -> Void,
        scheduleFrame: @escaping (Data, Double, @escaping Completion) throws -> Void,
        stopPlayback: @escaping () -> Void,
        playbackTime: @escaping () -> Double?)
    {
        self.preparePlayback = preparePlayback
        self.scheduleFrame = scheduleFrame
        self.stopPlayback = stopPlayback
        self.playbackTime = playbackTime
    }

    /// Plays PCM16 mono chunks from `stream` until it ends and every frame played back.
    /// - Parameters:
    ///   - stream: Little-endian Int16 mono chunks of any size.
    ///   - sampleRate: Sample rate in Hz; non-positive rates fail immediately.
    /// - Returns: `finished == true` once drained; `false` when stopped or failed.
    public func play(
        stream: AsyncThrowingStream<Data, Error>,
        sampleRate: Double) async -> StreamingPlaybackResult
    {
        _ = self.stop()
        guard sampleRate > 0 else {
            return StreamingPlaybackResult(finished: false, interruptedAt: nil)
        }
        self.generation &+= 1
        let generation = self.generation
        do {
            try self.preparePlayback(sampleRate)
        } catch {
            return StreamingPlaybackResult(finished: false, interruptedAt: nil)
        }
        return await withCheckedContinuation { continuation in
            self.playbackContinuation = continuation
            self.inputTask = Task { @MainActor [weak self] in
                await self?.consume(stream: stream, sampleRate: sampleRate, generation: generation)
            }
        }
    }

    /// Stops playback immediately and returns the playback position when known.
    public func stop() -> Double? {
        let interruptedAt = self.playbackTime()
        self.generation &+= 1
        self.inputTask?.cancel()
        self.inputTask = nil
        self.inputFinished = false
        self.scheduledBufferIDs.removeAll()
        let waiters = self.slotWaiters
        self.slotWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: false)
        }
        let continuation = self.playbackContinuation
        self.playbackContinuation = nil
        self.stopPlayback()
        continuation?.resume(returning: StreamingPlaybackResult(
            finished: false,
            interruptedAt: interruptedAt))
        return interruptedAt
    }

    private func consume(
        stream: AsyncThrowingStream<Data, Error>,
        sampleRate: Double,
        generation: UInt64) async
    {
        let frameBytes = max(
            MemoryLayout<Int16>.size,
            Int((sampleRate * Self.frameDurationSeconds).rounded()) * MemoryLayout<Int16>.size)
        var pending = Data()
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                pending.append(chunk)
                while pending.count >= frameBytes {
                    let frame = Data(pending.prefix(frameBytes))
                    pending.removeFirst(frameBytes)
                    guard await self.schedule(
                        frame: frame,
                        sampleRate: sampleRate,
                        generation: generation)
                    else { return }
                }
            }
            if !pending.isEmpty {
                pending.append(Data(repeating: 0, count: frameBytes - pending.count))
                guard await self.schedule(
                    frame: pending,
                    sampleRate: sampleRate,
                    generation: generation)
                else { return }
            }
            guard self.generation == generation else { return }
            self.inputFinished = true
            self.finishIfDrained(generation: generation)
        } catch {
            self.finish(generation: generation, finished: false)
        }
    }

    private func schedule(frame: Data, sampleRate: Double, generation: UInt64) async -> Bool {
        while self.generation == generation,
              self.scheduledBufferIDs.count >= Self.maxScheduledBuffers
        {
            let admitted = await withCheckedContinuation { continuation in
                self.slotWaiters.append(continuation)
            }
            guard admitted else { return false }
        }
        guard self.generation == generation, !Task.isCancelled else { return false }
        self.nextBufferID &+= 1
        let bufferID = self.nextBufferID
        self.scheduledBufferIDs.insert(bufferID)
        do {
            try self.scheduleFrame(frame, sampleRate) { [weak self] in
                Task { @MainActor in
                    self?.completed(bufferID: bufferID, generation: generation)
                }
            }
            return true
        } catch {
            self.scheduledBufferIDs.remove(bufferID)
            self.finish(generation: generation, finished: false)
            return false
        }
    }

    private func completed(bufferID: UInt64, generation: UInt64) {
        guard self.generation == generation,
              self.scheduledBufferIDs.remove(bufferID) != nil
        else { return }
        if !self.slotWaiters.isEmpty {
            self.slotWaiters.removeFirst().resume(returning: true)
        }
        self.finishIfDrained(generation: generation)
    }

    private func finishIfDrained(generation: UInt64) {
        guard self.inputFinished, self.scheduledBufferIDs.isEmpty else { return }
        self.finish(generation: generation, finished: true)
    }

    private func finish(generation: UInt64, finished: Bool) {
        guard self.generation == generation else { return }
        let interruptedAt = finished ? nil : self.playbackTime()
        self.generation &+= 1
        self.scheduledBufferIDs.removeAll()
        let waiters = self.slotWaiters
        self.slotWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: false)
        }
        self.inputTask = nil
        self.inputFinished = false
        let continuation = self.playbackContinuation
        self.playbackContinuation = nil
        self.stopPlayback()
        continuation?.resume(returning: StreamingPlaybackResult(
            finished: finished,
            interruptedAt: interruptedAt))
    }
}

extension RealtimePCMStreamingAudioPlayer {
    /// Copies one PCM16 frame into a buffer and schedules it with a played-back completion.
    ///
    /// On AVFAudio 27 the frame is scheduled as a Sendable `AVReadOnlyAudioPCMBuffer` with a
    /// `@Sendable` completion, so no mutable `AVAudioPCMBuffer` outlives this call.
    nonisolated static func schedule(
        data: Data,
        format: AVAudioFormat,
        on node: AVAudioPlayerNode,
        completion: @escaping Completion) throws
    {
        let buffer = try self.makeBuffer(data: data, format: format)
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            node.scheduleBuffer(
                AVReadOnlyAudioPCMBuffer(copying: buffer),
                completionCallbackType: .dataPlayedBack)
            { completion() }
            return
        }
        #endif
        node.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack)
        { _ in completion() }
    }

    /// Builds an Int16 mono buffer holding exactly `data` (little-endian samples).
    nonisolated static func makeBuffer(data: Data, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.int16ChannelData?[0]
        else {
            throw NSError(domain: "RealtimePCMStreamingAudioPlayer", code: 3)
        }
        buffer.frameLength = frames
        let byteCount = Int(frames) * MemoryLayout<Int16>.size
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            UnsafeMutableRawPointer(channel).copyMemory(from: base, byteCount: byteCount)
        }
        return buffer
    }
}
#endif
