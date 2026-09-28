#if canImport(AVFAudio) && (os(iOS) || os(macOS) || os(visionOS))
import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

@Suite("Realtime Talk relay playback")
@MainActor
struct RealtimeTalkRelaySessionPlaybackTests {
    private func makeSession(
        requests: RealtimeRelayStartupRequestLog? = nil,
        player: any PCMStreamingAudioPlaying,
        audioCapture: TestRealtimeTalkAudioCapture = TestRealtimeTalkAudioCapture(),
        onStatus: @escaping (String) -> Void = { _ in },
        onIssue: @escaping (RealtimeTalkRelayIssue) -> Void = { _ in },
        onTermination: @escaping (RealtimeTalkRelayTermination) -> Void = { _ in },
        onSpeakingChanged: @escaping (Bool) -> Void = { _ in }) -> RealtimeTalkRelaySession
    {
        let transport: RealtimeTalkRelayTransport = if let requests {
            RealtimeTalkRelayTransport(
                subscribeServerEvents: { _ in AsyncStream { $0.finish() } },
                request: { method, params, _ in
                    await requests.record(method: method, params: params)
                    return Data(#"{"ok":true}"#.utf8)
                })
        } else {
            unusedRealtimeRelayTransport()
        }
        let session = RealtimeTalkRelaySession(
            transport: transport,
            options: .init(sessionKey: "main", provider: "openai", model: nil, voice: nil),
            audioCapture: audioCapture,
            pcmPlayer: player,
            onStatus: onStatus,
            onIssue: onIssue,
            onTermination: onTermination,
            onSpeakingChanged: onSpeakingChanged)
        session._test_setRelaySessionId("relay-1")
        return session
    }

    @Test("output playback finish is idempotent and clears the barge-in start time")
    func outputPlaybackFinishIsIdempotent() {
        var speakingStates: [Bool] = []
        let session = RealtimeTalkRelaySession(
            transport: unusedRealtimeRelayTransport(),
            options: .init(sessionKey: "main", provider: nil, model: nil, voice: nil),
            audioCapture: TestRealtimeTalkAudioCapture(),
            pcmPlayer: UnusedPCMStreamingAudioPlayer(),
            onStatus: { _ in },
            onSpeakingChanged: { speakingStates.append($0) })

        session._test_markOutputAudioStarted(nowMs: 100)
        #expect(session._test_isOutputPlaying())
        #expect(session._test_outputStartedAtMs() == 100)

        session._test_markOutputPlaybackFinished()
        session._test_markOutputPlaybackFinished()
        #expect(!session._test_isOutputPlaying())
        #expect(session._test_outputStartedAtMs() == nil)
        #expect(speakingStates == [false])

        session._test_markOutputAudioStarted(nowMs: 500)
        #expect(session._test_isOutputPlaying())
        #expect(session._test_outputStartedAtMs() == 500)
        session._test_markOutputPlaybackFinished()
        #expect(!session._test_isOutputPlaying())
        #expect(session._test_outputStartedAtMs() == nil)
        #expect(speakingStates == [false, false])
    }

    @Test("playback mark is acknowledged after output finishes")
    func playbackMarkAcknowledgedAfterOutput() async throws {
        let requests = RealtimeRelayStartupRequestLog()
        let session = self.makeSession(requests: requests, player: UnusedPCMStreamingAudioPlayer())
        session._test_markOutputAudioStarted(nowMs: 100)

        await session._test_handleGatewayEvent(playbackMarkEvent("audio-1"))
        #expect(await requests.snapshot().isEmpty)

        session._test_markOutputPlaybackFinished()
        try await requests.waitForRequestCount(1)

        let recorded = await requests.snapshot()
        #expect(recorded.count == 1)
        let request = try #require(recorded.first)
        #expect(request.method == "talk.session.acknowledgeMark")
        #expect(request.params?["sessionId"]?.stringValue == "relay-1")
        #expect(request.params?["markName"]?.stringValue == "audio-1")
    }

    @Test("output buffer cap plus one terminates visibly and requests recovery")
    func outputBufferOverflowTerminates() async throws {
        let requests = RealtimeRelayStartupRequestLog()
        let player = StalledPCMStreamingAudioPlayer()
        let terminationObserved = RealtimeRelayTestSignal<RealtimeTalkRelayTermination>()
        var issues: [RealtimeTalkRelayIssue] = []
        var terminations: [RealtimeTalkRelayTermination] = []
        let session = self.makeSession(
            requests: requests,
            player: player,
            onIssue: { issues.append($0) },
            onTermination: {
                terminations.append($0)
                terminationObserved.send($0)
            })

        for _ in 0...32 {
            await session._test_handleGatewayEvent(
                outputAudioEvent(turnId: "turn-1", data: Data(repeating: 1, count: 960)))
        }
        #expect(try await terminationObserved.next("output buffer overflow") == .outputPlaybackOverflow)

        #expect(issues.map(\.phase) == ["output-playback"])
        #expect(terminations == [.outputPlaybackOverflow])
        #expect(player.stopCount == 1)
        try await requests.waitForRequestCount(1)
        #expect(await requests.snapshot().contains(where: { $0.method == "talk.session.close" }))
    }

    @Test("a new turn supersedes a stalled prior playback drain")
    func newTurnSupersedesStalledDrain() async throws {
        let requests = RealtimeRelayStartupRequestLog()
        let player = StalledPCMStreamingAudioPlayer()
        let session = self.makeSession(requests: requests, player: player)

        await session._test_handleGatewayEvent(outputAudioEvent(turnId: "turn-a"))
        try await player.waitForPlaybackCount(1)
        await session._test_handleGatewayEvent(playbackMarkEvent("turn-a-mark"))
        await session._test_handleGatewayEvent(outputAudioEvent(turnId: "turn-b"))
        try await player.waitForPlaybackCount(2)
        try await requests.waitForRequestCount(1)

        #expect(player.playCount == 2)
        #expect(player.stopCount == 1)
        let acknowledgements = await requests.snapshot().filter {
            $0.method == "talk.session.acknowledgeMark"
        }
        #expect(acknowledgements.count == 1)
        #expect(acknowledgements.first?.params?["markName"]?.stringValue == "turn-a-mark")
        session.stop()
    }

    @Test("unfinished current playback terminates visibly and requests recovery")
    func unfinishedPlaybackTerminates() async throws {
        let requests = RealtimeRelayStartupRequestLog()
        let player = IndexedPCMStreamingAudioPlayer()
        let terminated = RealtimeRelayTestSignal<RealtimeTalkRelayTermination>()
        let requestObserved = RealtimeRelayTestSignal<String>()
        var statuses: [String] = []
        var issues: [RealtimeTalkRelayIssue] = []
        let session = RealtimeTalkRelaySession(
            transport: RealtimeTalkRelayTransport(
                subscribeServerEvents: { _ in AsyncStream { $0.finish() } },
                request: { method, params, _ in
                    await requests.record(method: method, params: params)
                    requestObserved.send(method)
                    return Data(#"{"ok":true}"#.utf8)
                }),
            options: .init(sessionKey: "main", provider: "openai", model: nil, voice: nil),
            audioCapture: TestRealtimeTalkAudioCapture(),
            pcmPlayer: player,
            onStatus: { statuses.append($0) },
            onIssue: { issues.append($0) },
            onTermination: { terminated.send($0) },
            onSpeakingChanged: { _ in })
        defer {
            session.stop()
            player.shutdown()
        }
        session._test_setRelaySessionId("relay-1")

        await session._test_handleGatewayEvent(outputAudioEvent(turnId: "turn-1"))
        try await player.waitForPlayback(0)
        player.fail(0)
        #expect(try await terminated.next("unfinished playback recovery") == .outputPlaybackOverflow)

        let message = "Realtime audio playback failed. Reconnecting…"
        #expect(statuses == [message])
        #expect(issues.map(\.phase) == ["output-playback"])
        #expect(issues.map(\.message) == [message])
        #expect(!session._test_isOutputPlaying())
        #expect(try await requestObserved.next("relay close request") == "talk.session.close")
        #expect(await requests.snapshot().map(\.method) == ["talk.session.close"])
    }

    @Test("elapsed microphone time cannot retire pending playback", arguments: [false, true])
    func elapsedMicrophoneTimeCannotRetirePlayback(cancelOutput: Bool) async throws {
        let requests = RealtimeRelayStartupRequestLog()
        let player = IndexedPCMStreamingAudioPlayer()
        let audioCapture = TestRealtimeTalkAudioCapture()
        audioCapture.suppressesInputDuringOutput = true
        let speakingChanged = RealtimeRelayTestSignal<Bool>()
        var speakingStates: [Bool] = []
        let session = self.makeSession(
            requests: requests,
            player: player,
            audioCapture: audioCapture,
            onSpeakingChanged: {
                speakingStates.append($0)
                speakingChanged.send($0)
            })
        defer {
            session.stop()
            player.shutdown()
        }
        session._test_prepareAudioSender(relaySessionId: "relay-1")

        await session._test_handleGatewayEvent(outputAudioEvent(
            turnId: "turn-1", data: Data(repeating: 1, count: 960)))
        try await player.waitForPlayback(0)
        #expect(try await speakingChanged.next("playback start") == true)
        await session._test_handleGatewayEvent(playbackMarkEvent("pending-output"))
        await session._test_handleGatewayEvent(outputAudioDoneEvent(turnId: "turn-1"))

        // Input timestamps can outlive estimated audio duration while the device
        // still owns undrained output. Time alone cannot acknowledge hearing it.
        let laterTimestamp = ProcessInfo.processInfo.systemUptime * 1000 + 1000
        let suppressed = session._test_enqueueMicrophoneFrame(Data([0, 0]), timestampMs: laterTimestamp)
        #expect(suppressed == nil)
        await suppressed?.value
        #expect(player.activePlaybackIndexes.contains(0))
        #expect(session._test_isOutputPlaying())
        #expect(speakingStates == [true])
        #expect(await requests.snapshot().isEmpty)

        if cancelOutput {
            #expect(session.cancelOutput())
            let cancellation = try #require(session._test_outputCancellationTask())
            await cancellation.value
            let recorded = await requests.snapshot()
            #expect(recorded.map(\.method) == ["talk.session.cancelOutput"])
            #expect(recorded.first?.params?["turnId"]?.stringValue == "turn-1")
            await session._test_handleGatewayEvent(outputClearEvent(turnId: "turn-1"))
        } else {
            player.complete(0)
        }
        #expect(try await speakingChanged.next("playback retirement") == false)
        try await requests.waitForRequestCount(cancelOutput ? 2 : 1)
        #expect(!session._test_isOutputPlaying())
        #expect(speakingStates == [true, false])
        let acknowledgements = await requests.snapshot().filter { $0.method == "talk.session.acknowledgeMark" }
        #expect(acknowledgements.count == 1)
        #expect(acknowledgements.first?.params?["markName"]?.stringValue == "pending-output")

        let resumed = try #require(session._test_enqueueMicrophoneFrame(
            Data([0, 0]), timestampMs: laterTimestamp + 20))
        await resumed.value
        #expect(await requests.snapshot().last?.method == "talk.session.appendAudio")
    }

    @Test("stale player completion cannot finish replacement turn playback")
    func stalePlayerCompletionCannotFinishReplacement() async throws {
        let player = IndexedPCMStreamingAudioPlayer()
        let replacementFinished = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1))
        var replacementIsCompleting = false
        var speakingStates: [Bool] = []
        let session = self.makeSession(player: player, onSpeakingChanged: {
            speakingStates.append($0)
            if replacementIsCompleting, !$0 { replacementFinished.continuation.yield() }
        })
        defer {
            replacementFinished.continuation.finish()
            session.stop()
            player.shutdown()
        }

        await session._test_handleGatewayEvent(outputAudioEvent(turnId: "turn-a"))
        try await player.waitForPlayback(0)
        await session._test_handleGatewayEvent(outputAudioEvent(turnId: "turn-b"))
        try await player.waitForPlayback(1)

        #expect(player.activePlaybackIndexes.contains(1))
        #expect(speakingStates == [true, false, true])

        player.complete(0)
        try await player.waitUntilCompletionWasHandled(0)

        #expect(player.activePlaybackIndexes.contains(1))
        #expect(session._test_isOutputPlaying())
        #expect(speakingStates == [true, false, true])

        replacementIsCompleting = true
        player.complete(1)
        _ = try await waitForRealtimeRelayEvent(
            replacementFinished.stream,
            operation: "replacement playback to finish")

        #expect(!session._test_isOutputPlaying())
        #expect(speakingStates == [true, false, true, false])
    }

    @Test("cancelled playback task cannot start after its replacement")
    func cancelledPlaybackCannotStartAfterReplacement() async throws {
        let player = DrainingPCMStreamingAudioPlayer()
        let audioA = Data(repeating: 0x0A, count: 960)
        let audioB = Data(repeating: 0x0B, count: 960)
        let speakingChanged = RealtimeRelayTestSignal<Bool>()
        var speakingStates: [Bool] = []
        let session = self.makeSession(player: player, onSpeakingChanged: {
            speakingStates.append($0)
            speakingChanged.send($0)
        })
        defer { session.stop() }

        let replace = Task { @MainActor in
            await session._test_handleGatewayEvent(outputAudioEvent(turnId: "turn-a", data: audioA))
            await session._test_handleGatewayEvent(outputAudioEvent(turnId: "turn-b", data: audioB))
            await session._test_handleGatewayEvent(outputAudioDoneEvent(turnId: "turn-b"))
        }
        await replace.value
        try await player.waitForPlaybackCount(1)
        for expected in [true, false, true, false] {
            #expect(try await speakingChanged.next("playback state \(expected)") == expected)
        }

        #expect(player.playCount == 1)
        #expect(player.frames == [audioB])
        #expect(speakingStates == [true, false, true, false])
    }

    @Test("provider clear stops buffered keyed output after provider completion", arguments: [false, true])
    func providerClearStopsBufferedOutput(keyed: Bool) async throws {
        let requests = RealtimeRelayStartupRequestLog()
        let player = StalledPCMStreamingAudioPlayer()
        var speakingStates: [Bool] = []
        let session = self.makeSession(requests: requests, player: player, onSpeakingChanged: {
            speakingStates.append($0)
        })
        defer { session.stop() }

        await session._test_handleGatewayEvent(
            outputAudioEvent(turnId: "turn-1", data: Data(repeating: 1, count: 960)))
        try await player.waitForPlaybackCount(1)
        await session._test_handleGatewayEvent(playbackMarkEvent("buffered-output"))
        await session._test_handleGatewayEvent(outputAudioDoneEvent(turnId: "turn-1"))
        #expect(player.stopCount == 0)
        #expect(speakingStates == [true])

        await session._test_handleGatewayEvent(outputClearEvent(
            turnId: keyed ? "turn-1" : nil, talkEventType: "output.audio.done"))
        try #require(player.stopCount == 1)
        #expect(speakingStates == [true, false])
        try await requests.waitForRequestCount(1)
        let acknowledgements = await requests.snapshot()
        #expect(acknowledgements.map(\.method) == ["talk.session.acknowledgeMark"])
        #expect(acknowledgements.first?.params?["markName"]?.stringValue == "buffered-output")

        await session._test_handleGatewayEvent(outputClearEvent(
            turnId: keyed ? "turn-1" : nil, talkEventType: "output.audio.done"))
        #expect(player.stopCount == 1)
        #expect(speakingStates == [true, false])
        #expect(await requests.snapshot().count == 1)
    }

    @Test("a stale relay session cannot clear successor playback", arguments: [nil, "turn-a"] as [String?])
    func staleRelayCannotClearSuccessor(turnId: String?) async {
        var speakingStates: [Bool] = []
        let session = self.makeSession(player: StalledPCMStreamingAudioPlayer(), onSpeakingChanged: {
            speakingStates.append($0)
        })
        await session._test_handleGatewayEvent(outputAudioEvent(turnId: "turn-a"))
        session._test_setRelaySessionId("relay-2")
        await session._test_handleGatewayEvent(
            outputAudioEvent(turnId: "turn-b", relaySessionId: "relay-2"))

        await session._test_handleGatewayEvent(outputClearEvent(turnId: turnId))

        #expect(session._test_isOutputPlaying())
        #expect(speakingStates == [true, false, true])
        session.stop()
    }

    @Test("turn-scoped audio without a turn id terminates visibly")
    func audioWithoutTurnIDTerminates() async {
        var issues: [RealtimeTalkRelayIssue] = []
        var terminations: [RealtimeTalkRelayTermination] = []
        let session = self.makeSession(
            player: StalledPCMStreamingAudioPlayer(),
            onIssue: { issues.append($0) },
            onTermination: { terminations.append($0) })

        await session._test_handleGatewayEvent(realtimeRelayEvent(
            #"{"relaySessionId":"relay-1","type":"audio","audioBase64":"\#(Data([0x01]).base64EncodedString())"}"#))

        #expect(issues.map(\.phase) == ["output-playback"])
        #expect(terminations == [.outputPlaybackOverflow])
    }

    @Test("a large provider audio delta is rebuffered into bounded ordered frames")
    func largeDeltaIsRebuffered() async throws {
        let player = DrainingPCMStreamingAudioPlayer()
        var issues: [RealtimeTalkRelayIssue] = []
        var terminations: [RealtimeTalkRelayTermination] = []
        let session = self.makeSession(
            player: player,
            onIssue: { issues.append($0) },
            onTermination: { terminations.append($0) })
        defer { session.stop() }
        let audio = Data((0..<(960 * 2 + 480)).map { UInt8($0 % 251) })

        await session._test_handleGatewayEvent(outputAudioEvent(turnId: "turn-1", data: audio))
        await session._test_handleGatewayEvent(outputAudioDoneEvent(turnId: "turn-1"))
        try await player.waitUntilPlaybackFinished()

        #expect(player.frames.map(\.count) == [960, 960, 480])
        #expect(player.frames.reduce(into: Data()) { $0.append($1) } == audio)
        #expect(issues.isEmpty)
        #expect(terminations.isEmpty)
    }

    @Test("an exact maximum output audio frame is accepted")
    func exactMaximumFrameIsAccepted() async {
        var issues: [RealtimeTalkRelayIssue] = []
        var terminations: [RealtimeTalkRelayTermination] = []
        let session = self.makeSession(
            player: StalledPCMStreamingAudioPlayer(),
            onIssue: { issues.append($0) },
            onTermination: { terminations.append($0) })

        await session._test_handleGatewayEvent(
            outputAudioEvent(turnId: "turn-1", data: Data(repeating: 1, count: 960)))

        #expect(issues.isEmpty)
        #expect(terminations.isEmpty)
        #expect(session._test_isOutputPlaying())
        session.stop()
    }
}
#endif
