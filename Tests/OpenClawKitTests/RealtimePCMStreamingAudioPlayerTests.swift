#if canImport(AVFAudio) && (os(iOS) || os(macOS) || os(visionOS))
import AVFAudio
import Foundation
import Testing
@testable import OpenClawKit

private struct RealtimePCMPlaybackWaitTimeout: Error {
    let label: String
}

private struct RealtimePCMPlaybackFailure: Error {}

private let realtimePCMPlaybackWaitTimeoutSeconds = 15.0

@MainActor
private final class RealtimePCMPlaybackBackend {
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private(set) var scheduledFrames: [Data] = []
    private(set) var completions: [@Sendable () -> Void] = []
    private(set) var activeCount = 0
    private(set) var maxActiveCount = 0
    private var completedCallbacks = 0
    private var scheduledWaiters: [UUID: Waiter] = [:]
    private var completionWaiters: [UUID: Waiter] = [:]

    func prepare(sampleRate _: Double) throws {}

    func schedule(
        data: Data,
        sampleRate _: Double,
        completion: @escaping @Sendable () -> Void) throws
    {
        self.scheduledFrames.append(data)
        self.activeCount += 1
        self.maxActiveCount = max(self.maxActiveCount, self.activeCount)
        self.resumeScheduledWaiters()
        self.completions.append { [weak self] in
            Task { @MainActor in
                self?.activeCount -= 1
                self?.completedCallbacks += 1
                self?.resumeCompletionWaiters()
                completion()
            }
        }
    }

    func stop() {
        self.activeCount = 0
    }

    func complete(at index: Int = 0) {
        self.completions.remove(at: index)()
    }

    func takeCompletion(at index: Int = 0) -> @Sendable () -> Void {
        self.completions.remove(at: index)
    }

    func waitForScheduledFrames(_ count: Int) async throws {
        if self.scheduledFrames.count >= count { return }
        try await AsyncTimeout.withTimeout(
            seconds: realtimePCMPlaybackWaitTimeoutSeconds,
            onTimeout: { RealtimePCMPlaybackWaitTimeout(label: "scheduled frames \(count)") },
            operation: { try await self.waitForScheduledFramesWithoutDeadline(count) })
    }

    func waitForCompletionCallbacks(_ count: Int) async throws {
        if self.completedCallbacks >= count { return }
        try await AsyncTimeout.withTimeout(
            seconds: realtimePCMPlaybackWaitTimeoutSeconds,
            onTimeout: { RealtimePCMPlaybackWaitTimeout(label: "completion callbacks \(count)") },
            operation: { try await self.waitForCompletionCallbacksWithoutDeadline(count) })
    }

    private func waitForScheduledFramesWithoutDeadline(_ count: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if self.scheduledFrames.count >= count {
                    continuation.resume()
                } else {
                    self.scheduledWaiters[id] = Waiter(count: count, continuation: continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelScheduledWaiter(id) }
        }
    }

    private func waitForCompletionCallbacksWithoutDeadline(_ count: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if self.completedCallbacks >= count {
                    continuation.resume()
                } else {
                    self.completionWaiters[id] = Waiter(count: count, continuation: continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelCompletionWaiter(id) }
        }
    }

    private func cancelScheduledWaiter(_ id: UUID) {
        self.scheduledWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func cancelCompletionWaiter(_ id: UUID) {
        self.completionWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func resumeScheduledWaiters() {
        let ready = self.scheduledWaiters.filter { self.scheduledFrames.count >= $0.value.count }
        for (id, waiter) in ready {
            self.scheduledWaiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    private func resumeCompletionWaiters() {
        let ready = self.completionWaiters.filter { self.completedCallbacks >= $0.value.count }
        for (id, waiter) in ready {
            self.completionWaiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }
}

@MainActor
private final class RealtimePCMPlaybackResultProbe {
    private(set) var results: [StreamingPlaybackResult] = []

    func record(_ result: StreamingPlaybackResult) {
        self.results.append(result)
    }
}

@MainActor
private func makeRealtimePCMPlayer(
    backend: RealtimePCMPlaybackBackend) -> RealtimePCMStreamingAudioPlayer
{
    RealtimePCMStreamingAudioPlayer(
        preparePlayback: backend.prepare,
        scheduleFrame: backend.schedule,
        stopPlayback: backend.stop,
        playbackTime: { nil })
}

private func waitForPlayback(_ task: Task<Void, Never>, label: String) async throws {
    try await AsyncTimeout.withTimeout(
        seconds: realtimePCMPlaybackWaitTimeoutSeconds,
        onTimeout: { RealtimePCMPlaybackWaitTimeout(label: label) },
        operation: { await task.value })
}

@Suite("Realtime PCM streaming audio player")
@MainActor
struct RealtimePCMStreamingAudioPlayerTests {
    private let sampleRate = 8000.0
    private var frameBytes: Int {
        Int(self.sampleRate * RealtimePCMStreamingAudioPlayer.frameDurationSeconds) * 2
    }

    @Test("prepare failure returns unfinished playback")
    func prepareFailureReturnsUnfinished() async {
        let player = RealtimePCMStreamingAudioPlayer(
            preparePlayback: { _ in throw RealtimePCMPlaybackFailure() },
            scheduleFrame: { _, _, _ in },
            stopPlayback: {},
            playbackTime: { nil })
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.finish()

        let result = await player.play(stream: stream, sampleRate: self.sampleRate)

        #expect(!result.finished)
        #expect(result.interruptedAt == nil)
    }

    @Test("a non-positive sample rate fails without preparing")
    func nonPositiveSampleRateFails() async {
        var prepared = false
        let player = RealtimePCMStreamingAudioPlayer(
            preparePlayback: { _ in prepared = true },
            scheduleFrame: { _, _, _ in },
            stopPlayback: {},
            playbackTime: { nil })
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.finish()

        let result = await player.play(stream: stream, sampleRate: 0)

        #expect(!result.finished)
        #expect(!prepared)
    }

    @Test("schedule failure returns unfinished playback")
    func scheduleFailureReturnsUnfinished() async throws {
        let player = RealtimePCMStreamingAudioPlayer(
            preparePlayback: { _ in },
            scheduleFrame: { _, _, _ in throw RealtimePCMPlaybackFailure() },
            stopPlayback: {},
            playbackTime: { nil })
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let playback = Task {
            await player.play(stream: stream, sampleRate: self.sampleRate)
        }
        continuation.yield(Data(repeating: 1, count: self.frameBytes))
        continuation.finish()

        let probe = RealtimePCMPlaybackResultProbe()
        let observed = Task {
            await probe.record(playback.value)
        }
        try await waitForPlayback(observed, label: "schedule failure")

        #expect(probe.results.count == 1)
        #expect(probe.results.first?.finished == false)
        #expect(probe.results.first?.interruptedAt == nil)
    }

    @Test("withheld completions cap scheduling and one completion admits one frame")
    func withheldCompletionsCapScheduling() async throws {
        let backend = RealtimePCMPlaybackBackend()
        let player = makeRealtimePCMPlayer(backend: backend)
        let probe = RealtimePCMPlaybackResultProbe()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let playback = Task {
            let result = await player.play(stream: stream, sampleRate: self.sampleRate)
            probe.record(result)
        }

        continuation.yield(Data(repeating: 1, count: self.frameBytes * 5))
        continuation.finish()
        try await backend.waitForScheduledFrames(3)
        #expect(backend.scheduledFrames.count == 3)
        #expect(backend.maxActiveCount == 3)
        #expect(probe.results.isEmpty)

        backend.complete()
        try await backend.waitForScheduledFrames(4)
        #expect(backend.scheduledFrames.count == 4)
        #expect(backend.maxActiveCount == 3)
        #expect(probe.results.isEmpty)

        backend.complete()
        try await backend.waitForScheduledFrames(5)
        for _ in 0..<3 {
            backend.complete()
        }
        try await waitForPlayback(playback, label: "five-frame playback")
        #expect(probe.results.count == 1)
        #expect(probe.results.first?.finished == true)
        #expect(probe.results.first?.interruptedAt == nil)
        #expect(backend.scheduledFrames.count == 5)
        #expect(backend.scheduledFrames.allSatisfy { $0.count == self.frameBytes })
    }

    @Test("a trailing partial frame is zero-padded to a whole frame")
    func trailingPartialFrameIsPadded() async throws {
        let backend = RealtimePCMPlaybackBackend()
        let player = makeRealtimePCMPlayer(backend: backend)
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let playback = Task {
            _ = await player.play(stream: stream, sampleRate: self.sampleRate)
        }
        continuation.yield(Data(repeating: 7, count: self.frameBytes + 10))
        continuation.finish()
        try await backend.waitForScheduledFrames(2)
        #expect(backend.scheduledFrames.map(\.count) == [self.frameBytes, self.frameBytes])
        #expect(backend.scheduledFrames[1].prefix(10) == Data(repeating: 7, count: 10))
        #expect(backend.scheduledFrames[1].dropFirst(10).allSatisfy { $0 == 0 })
        backend.complete()
        backend.complete()
        try await waitForPlayback(playback, label: "padded playback")
    }

    @Test("playback finishes only after input and every scheduled frame complete")
    func playbackFinishesAfterEveryFrame() async throws {
        let backend = RealtimePCMPlaybackBackend()
        let player = makeRealtimePCMPlayer(backend: backend)
        let probe = RealtimePCMPlaybackResultProbe()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let playback = Task {
            let result = await player.play(stream: stream, sampleRate: self.sampleRate)
            probe.record(result)
        }

        continuation.yield(Data(repeating: 1, count: self.frameBytes * 2))
        continuation.finish()
        try await backend.waitForScheduledFrames(2)
        #expect(backend.completions.count == 2)
        #expect(probe.results.isEmpty)

        backend.complete()
        #expect(backend.completions.count == 1)
        #expect(probe.results.isEmpty)
        backend.complete()
        try await waitForPlayback(playback, label: "completed input playback")
        #expect(probe.results.count == 1)
        #expect(probe.results.first?.finished == true)
        #expect(probe.results.first?.interruptedAt == nil)
    }

    @Test("stop and restart ignore stale buffer completions")
    func stopRestartIgnoresStaleCompletions() async throws {
        let backend = RealtimePCMPlaybackBackend()
        let player = makeRealtimePCMPlayer(backend: backend)
        let (firstStream, firstContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let firstProbe = RealtimePCMPlaybackResultProbe()
        let firstPlayback = Task {
            let result = await player.play(stream: firstStream, sampleRate: self.sampleRate)
            firstProbe.record(result)
        }
        firstContinuation.yield(Data(repeating: 1, count: self.frameBytes))
        try await backend.waitForScheduledFrames(1)
        let staleCompletion = backend.takeCompletion()

        _ = player.stop()
        try await waitForPlayback(firstPlayback, label: "stopped A playback")
        #expect(firstProbe.results.map(\.finished) == [false])

        let (secondStream, secondContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let probe = RealtimePCMPlaybackResultProbe()
        let secondPlayback = Task {
            let result = await player.play(stream: secondStream, sampleRate: self.sampleRate)
            probe.record(result)
        }
        secondContinuation.yield(Data(repeating: 2, count: self.frameBytes * 5))
        secondContinuation.finish()
        try await backend.waitForScheduledFrames(4)
        #expect(backend.activeCount == 3)
        #expect(probe.results.isEmpty)

        staleCompletion()
        try await backend.waitForCompletionCallbacks(1)
        #expect(backend.scheduledFrames.count == 4)
        #expect(backend.completions.count == 3)
        #expect(firstProbe.results.map(\.finished) == [false])
        #expect(probe.results.isEmpty)
        backend.complete()
        try await backend.waitForScheduledFrames(5)
        #expect(backend.scheduledFrames.count == 5)
        #expect(probe.results.isEmpty)
        backend.complete()
        try await backend.waitForScheduledFrames(6)
        #expect(backend.scheduledFrames.count == 6)
        #expect(probe.results.isEmpty)
        for _ in 0..<3 {
            backend.complete()
        }
        try await waitForPlayback(secondPlayback, label: "replacement B playback")
        #expect(probe.results.count == 1)
        #expect(probe.results.first?.finished == true)
        #expect(probe.results.first?.interruptedAt == nil)
    }

    @Test("stop resumes the active playback exactly once")
    func stopResumesActivePlaybackOnce() async throws {
        let backend = RealtimePCMPlaybackBackend()
        let player = makeRealtimePCMPlayer(backend: backend)
        let probe = RealtimePCMPlaybackResultProbe()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let playback = Task {
            let result = await player.play(stream: stream, sampleRate: self.sampleRate)
            probe.record(result)
        }
        continuation.yield(Data(repeating: 1, count: self.frameBytes * 5))
        try await backend.waitForScheduledFrames(3)

        _ = player.stop()
        _ = player.stop()
        try await waitForPlayback(playback, label: "stopped active playback")

        #expect(probe.results.count == 1)
        #expect(probe.results.first?.finished == false)
    }

    @Test("frames copy into an Int16 mono buffer byte for byte")
    func framesCopyIntoInt16Buffer() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: false))
        let samples: [Int16] = [0, 1, -1, Int16.max, Int16.min]
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }

        let buffer = try RealtimePCMStreamingAudioPlayer.makeBuffer(data: data, format: format)

        #expect(buffer.frameLength == AVAudioFrameCount(samples.count))
        let channel = try #require(buffer.int16ChannelData?[0])
        #expect((0..<samples.count).map { channel[$0] } == samples)
    }
}
#endif
