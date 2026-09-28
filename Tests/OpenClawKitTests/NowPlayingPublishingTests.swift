import Foundation
import Testing
@testable import OpenClawKit
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if compiler(>=6.4) && canImport(NowPlaying)
import NowPlaying
#endif

/// Records every Now Playing call so tests can assert publish/clear sequences.
@MainActor
final class RecordingNowPlayingPublisher: OpenClawNowPlayingPublishing {
    enum Call: Equatable {
        case publish(OpenClawNowPlayingMetadata)
        case setHandler(installed: Bool)
        case clear
    }

    private(set) var calls: [Call] = []
    private(set) var handler: (@MainActor @Sendable (OpenClawNowPlayingCommand) -> Void)?

    func publish(_ metadata: OpenClawNowPlayingMetadata) {
        self.calls.append(.publish(metadata))
    }

    func setCommandHandler(_ handler: (@MainActor @Sendable (OpenClawNowPlayingCommand) -> Void)?) {
        self.handler = handler
        self.calls.append(.setHandler(installed: handler != nil))
    }

    func clear() {
        self.handler = nil
        self.calls.append(.clear)
    }

    func send(_ command: OpenClawNowPlayingCommand) {
        self.handler?(command)
    }
}

@Suite("Now Playing publishing")
@MainActor
struct NowPlayingPublishingTests {
    @Test("metadata defaults describe live playing content")
    func metadataDefaults() {
        let metadata = OpenClawNowPlayingMetadata(contentID: "talk:1", title: "OpenClaw")
        #expect(metadata.subtitle == nil)
        #expect(metadata.duration == nil)
        #expect(metadata.elapsed == 0)
        #expect(metadata.playbackRate == 1)
        #expect(metadata.state == .playing)
    }

    @Test("the extension-safe publisher is backed by MediaPlayer")
    func extensionSafePublisherUsesMediaPlayer() {
        let publisher = OpenClawNowPlaying.makeExtensionSafePublisher()
        #if canImport(MediaPlayer)
        #expect(publisher is MediaPlayerNowPlayingPublisher)
        #endif
        let system = OpenClawNowPlaying.makeSystemPublisher()
        #if compiler(>=6.4) && canImport(NowPlaying)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            #expect(system is MediaSessionNowPlayingPublisher)
            return
        }
        #endif
        #if canImport(MediaPlayer)
        #expect(system is MediaPlayerNowPlayingPublisher)
        #endif
    }

    #if canImport(MediaPlayer)
    @Test("MediaPlayer info maps title, subtitle, timing and the live flag")
    func mediaPlayerInfoMapping() {
        let live = MediaPlayerNowPlayingPublisher.makeNowPlayingInfo(OpenClawNowPlayingMetadata(
            contentID: "talk:1",
            title: "Molty",
            subtitle: "Talk",
            elapsed: 2,
            playbackRate: 1,
            state: .playing))
        #expect(live[MPMediaItemPropertyTitle] as? String == "Molty")
        #expect(live[MPMediaItemPropertyArtist] as? String == "Talk")
        #expect(live[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
        #expect(live[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 2)
        #expect(live[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(live[MPMediaItemPropertyPlaybackDuration] == nil)

        let paused = MediaPlayerNowPlayingPublisher.makeNowPlayingInfo(OpenClawNowPlayingMetadata(
            contentID: "clip:2",
            title: "Clip",
            duration: 30,
            elapsed: 5,
            playbackRate: 1.5,
            state: .paused))
        #expect(paused[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)
        #expect(paused[MPMediaItemPropertyPlaybackDuration] as? Double == 30)
        #expect(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(paused[MPMediaItemPropertyArtist] == nil)
    }
    #endif

    #if compiler(>=6.4) && canImport(NowPlaying)
    @Test("MediaSession snapshots map every playback state")
    func mediaSessionSnapshotMapping() {
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) else { return }
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        func snapshot(_ state: OpenClawNowPlayingMetadata.State, rate: Double = 1.5) -> MediaPlaybackSnapshot {
            MediaSessionNowPlayingPublisher.makeSnapshot(
                OpenClawNowPlayingMetadata(
                    contentID: "talk:1",
                    title: "OpenClaw",
                    elapsed: 3,
                    playbackRate: rate,
                    state: state),
                timestamp: timestamp)
        }
        #expect(snapshot(.playing) == MediaPlaybackSnapshot(
            state: .playing(rate: 1.5), defaultPlaybackRate: 1, elapsedTime: 3, timestamp: timestamp))
        #expect(snapshot(.paused) == MediaPlaybackSnapshot(
            state: .paused, defaultPlaybackRate: 1, elapsedTime: 3, timestamp: timestamp))
        #expect(snapshot(.buffering) == MediaPlaybackSnapshot(
            state: .buffering, defaultPlaybackRate: 1, elapsedTime: 3, timestamp: timestamp))
        #expect(snapshot(.stopped) == MediaPlaybackSnapshot(
            state: .stopped, defaultPlaybackRate: 1, elapsedTime: 3, timestamp: timestamp))
        #expect(snapshot(.interrupted) == MediaPlaybackSnapshot(
            state: .interrupted, defaultPlaybackRate: 1, elapsedTime: 3, timestamp: timestamp))
        #expect(snapshot(.playing) != snapshot(.playing, rate: 1))
    }

    @Test("MediaSession publisher decorates content and publishes commands only with a handler")
    func mediaSessionPublisherContentAndCommands() {
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) else { return }
        let publisher = MediaSessionNowPlayingPublisher()
        var decorated: [String] = []
        publisher.contentDecorator = { content in
            decorated.append(content.id)
            content.genre = "Talk"
        }

        publisher.publish(OpenClawNowPlayingMetadata(contentID: "talk:1", title: "OpenClaw", subtitle: "Talk"))
        #expect(decorated == ["talk:1"])
        let content = publisher.representable.content as? GenericContent
        #expect(content?.id == "talk:1")
        #expect(content?.title == "OpenClaw")
        #expect(content?.subtitle == "Talk")
        #expect(content?.genre == "Talk")
        #expect(publisher.representable.commands.isEmpty)

        publisher.setCommandHandler { _ in }
        #expect(publisher.representable.commands.count == 4)
        publisher.publish(OpenClawNowPlayingMetadata(contentID: "clip:1", title: "Clip", duration: 20))
        #expect(publisher.representable.commands.count == 6)
        #expect(publisher.representable.id == MediaSessionNowPlayingPublisher.representableID)

        publisher.clear()
        #expect(publisher.representable.content == nil)
        #expect(publisher.representable.playbackSnapshot == MediaPlaybackSnapshot(state: .stopped))
        #expect(publisher.representable.commands.isEmpty)
    }
    #endif
}

@Suite("Talk system speech synthesizer", .serialized)
@MainActor
struct TalkSystemSpeechSynthesizerTests {
    @Test("the watchdog defaults to the Latin profile")
    func watchdogDefaultsToLatinProfile() {
        let timeout = TalkSystemSpeechSynthesizer.watchdogTimeoutSeconds(
            text: String(repeating: "a", count: 100),
            language: nil)
        #expect(abs(timeout - 24.0) < 0.001)
    }

    @Test("the watchdog uses per-language profiles", arguments: [
        ("ko-KR", "가", 75.0),
        ("zh-CN", "你", 84.0),
        ("ja-JP", "あ", 60.0),
        ("en-US", "a", 24.0),
    ])
    func watchdogUsesLanguageProfiles(language: String, character: String, expected: Double) {
        let timeout = TalkSystemSpeechSynthesizer.watchdogTimeoutSeconds(
            text: String(repeating: character, count: 100),
            language: language)
        #expect(abs(timeout - expected) < 0.001)
    }

    @Test("the watchdog applies per-language minimums and clamps long utterances")
    func watchdogMinimumsAndClamp() {
        #expect(abs(TalkSystemSpeechSynthesizer.watchdogTimeoutSeconds(text: "hi", language: "en") - 9.0) < 0.001)
        #expect(abs(TalkSystemSpeechSynthesizer.watchdogTimeoutSeconds(text: "안녕", language: "ko") - 30.0) < 0.001)
        #expect(abs(TalkSystemSpeechSynthesizer.watchdogTimeoutSeconds(
            text: String(repeating: "a", count: 10000),
            language: "en-US") - 900.0) < 0.001)
    }

    @Test("a pre-cancelled caller throws without touching the synthesizer")
    func preCancelledCallerThrows() async {
        let speaker = TalkSystemSpeechSynthesizer.shared
        let recorder = RecordingNowPlayingPublisher()
        speaker.nowPlayingPublisher = recorder
        defer { speaker.nowPlayingPublisher = nil }
        let attempt = Task { @MainActor in
            try await speaker.speak(text: "Cancelled successor speech.", language: "en-US")
        }
        attempt.cancel()
        let result = await attempt.result
        #expect(throws: TalkSystemSpeechSynthesizer.SpeakError.self) { try result.get() }
        #expect(recorder.calls.isEmpty)
        #expect(!speaker.isSpeaking)
    }

    @Test("speech publishes live Talk metadata on start and clears on finish")
    func speechPublishesNowPlayingLifecycle() {
        let speaker = TalkSystemSpeechSynthesizer.shared
        let recorder = RecordingNowPlayingPublisher()
        var speaking: [Bool] = []
        speaker.nowPlayingPublisher = recorder
        speaker.nowPlayingTitle = "Molty"
        speaker.onSpeakingChanged = { speaking.append($0) }
        defer {
            speaker.nowPlayingPublisher = nil
            speaker.nowPlayingTitle = nil
            speaker.onSpeakingChanged = nil
        }

        speaker._test_simulateStart()
        speaker._test_simulateFinish()

        #expect(recorder.calls.count == 3)
        #expect(recorder.calls.first == .setHandler(installed: true))
        guard recorder.calls.count == 3, case let .publish(metadata) = recorder.calls[1] else {
            Issue.record("Expected a publish call, got \(recorder.calls)")
            return
        }
        #expect(metadata.contentID.hasPrefix("talk:"))
        #expect(metadata.title == "Molty")
        #expect(metadata.subtitle == "Talk")
        #expect(metadata.duration == nil)
        #expect(metadata.state == .playing)
        #expect(metadata.playbackRate == 1)
        #expect(recorder.calls[2] == .clear)
        #expect(speaking == [true, false])
    }

    @Test("remote pause stops speech and clears Now Playing")
    func remotePauseStopsSpeech() {
        let speaker = TalkSystemSpeechSynthesizer.shared
        let recorder = RecordingNowPlayingPublisher()
        speaker.nowPlayingPublisher = recorder
        defer { speaker.nowPlayingPublisher = nil }

        speaker._test_simulateStart()
        recorder.send(.pause)

        #expect(recorder.calls.last == .clear)
        #expect(recorder.calls.filter { $0 == .clear }.count == 1)
    }

    @Test("an audio-session interruption publishes the interrupted state")
    func interruptionPublishesInterruptedState() {
        let speaker = TalkSystemSpeechSynthesizer.shared
        let recorder = RecordingNowPlayingPublisher()
        speaker.nowPlayingPublisher = recorder
        defer {
            speaker.nowPlayingPublisher = nil
            speaker.stop()
        }

        speaker._test_simulateStart()
        speaker.interruptForAudioSession()

        guard case let .publish(metadata) = recorder.calls.last else {
            Issue.record("Expected a final publish, got \(recorder.calls)")
            return
        }
        #expect(metadata.state == .interrupted)
        #expect(recorder.calls.contains(.clear))
    }

    @Test("the audio session controller interrupts the synthesizer through the protocol requirement")
    func controllerInterruptsSynthesizerThroughProtocol() {
        let speaker = TalkSystemSpeechSynthesizer.shared
        let recorder = RecordingNowPlayingPublisher()
        speaker.nowPlayingPublisher = recorder
        let controller = TalkAudioSessionController(session: nil, observeSystemEvents: false)
        controller.speech = speaker
        defer {
            speaker.nowPlayingPublisher = nil
            speaker.stop()
        }

        speaker._test_simulateStart()
        controller.handle(.interrupted)

        guard case let .publish(metadata) = recorder.calls.last else {
            Issue.record("Expected an interrupted publish, got \(recorder.calls)")
            return
        }
        #expect(metadata.state == .interrupted)
        #expect(controller.stateLabel == "interrupted")
    }

    @Test("an interruption with nothing playing publishes nothing")
    func idleInterruptionPublishesNothing() {
        let speaker = TalkSystemSpeechSynthesizer.shared
        let recorder = RecordingNowPlayingPublisher()
        speaker.nowPlayingPublisher = recorder
        defer { speaker.nowPlayingPublisher = nil }

        speaker.interruptForAudioSession()

        #expect(recorder.calls.isEmpty)
    }
}
