import AVFoundation
import Foundation

/// Speech output used as the last Talk fallback (after gateway `talk.speak`).
@MainActor
public protocol TalkSystemSpeaking: AnyObject {
    /// Speaks `text`, returning when the utterance finishes.
    /// - Throws: ``TalkSystemSpeechSynthesizer/SpeakError/canceled`` when stopped or replaced.
    func speak(text: String, language: String?, onStart: (() -> Void)?) async throws
    /// Stops the current utterance.
    func stop()
    /// Stops speech for a system audio interruption (the default calls ``stop()``).
    func interruptForAudioSession()
}

/// On-device speech synthesis (`AVSpeechSynthesizer`) for Talk replies.
///
/// One utterance plays at a time; a new ``speak(text:language:onStart:)`` replaces the current
/// one. A per-language watchdog finishes utterances whose delegate callbacks never arrive.
/// When ``nowPlayingPublisher`` is set, speech is published to Now Playing while it plays.
@MainActor
public final class TalkSystemSpeechSynthesizer: NSObject, TalkSystemSpeaking {
    /// Errors thrown by ``speak(text:language:onStart:)``.
    public enum SpeakError: Error {
        /// The utterance was stopped, replaced, or its caller was cancelled.
        case canceled
    }

    /// Process-wide synthesizer.
    public static let shared = TalkSystemSpeechSynthesizer()

    /// Publisher that receives Now Playing metadata while speech plays; `nil` disables publishing.
    public var nowPlayingPublisher: (any OpenClawNowPlayingPublishing)?
    /// Title shown in Now Playing (for example the agent name); defaults to `OpenClaw`.
    public var nowPlayingTitle: String?
    /// Called with `true` when an utterance starts playing and `false` when it finishes or stops.
    public var onSpeakingChanged: (@MainActor (Bool) -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var speakContinuation: CheckedContinuation<Void, Error>?
    private var currentUtterance: AVSpeechUtterance?
    private var didStartCallback: (() -> Void)?
    private var currentToken = UUID()
    private var watchdog: Task<Void, Never>?
    private var publishedMetadata: OpenClawNowPlayingMetadata?
    private var isReportingSpeaking = false

    /// Whether the synthesizer is currently speaking.
    public var isSpeaking: Bool { self.synth.isSpeaking }

    override private init() {
        super.init()
        self.synth.delegate = self
    }

    /// Stops the current utterance; its ``speak(text:language:onStart:)`` call throws `canceled`.
    public func stop() {
        self.currentToken = UUID()
        self.watchdog?.cancel()
        self.watchdog = nil
        self.didStartCallback = nil
        self.synth.stopSpeaking(at: .immediate)
        self.finishCurrent(with: SpeakError.canceled)
    }

    /// Stops speech for a system audio interruption and publishes an `interrupted` Now Playing state.
    public func interruptForAudioSession() {
        let interrupted = self.publishedMetadata
        self.stop()
        guard var interrupted else { return }
        interrupted.state = .interrupted
        self.nowPlayingPublisher?.publish(interrupted)
    }

    /// Speaks `text`, replacing any utterance in progress.
    /// - Parameters:
    ///   - text: Text to speak; whitespace-only text returns immediately.
    ///   - language: BCP-47 voice language, or `nil` for the default voice.
    ///   - onStart: Called once when audio starts.
    /// - Throws: ``SpeakError/canceled`` when stopped, replaced, or when the calling task is
    ///   already cancelled (the playing utterance is then left untouched); an `NSError` with code
    ///   408 when the watchdog expires.
    public func speak(
        text: String,
        language: String? = nil,
        onStart: (() -> Void)? = nil) async throws
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A cancelled caller must not retire the utterance already playing.
        guard !Task.isCancelled else { throw SpeakError.canceled }

        self.stop()
        let token = UUID()
        self.currentToken = token
        self.didStartCallback = onStart

        let utterance = AVSpeechUtterance(string: trimmed)
        if let language, let voice = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = voice
        }
        self.currentUtterance = utterance

        let watchdogTimeout = Self.watchdogTimeoutSeconds(
            text: trimmed,
            language: language ?? utterance.voice?.language)
        self.watchdog?.cancel()
        self.watchdog = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(watchdogTimeout * 1_000_000_000))
            if Task.isCancelled { return }
            guard self.currentToken == token else { return }
            if self.synth.isSpeaking {
                self.synth.stopSpeaking(at: .immediate)
            }
            self.finishCurrent(
                with: NSError(domain: "TalkSystemSpeechSynthesizer", code: 408, userInfo: [
                    NSLocalizedDescriptionKey: "system TTS timed out after \(watchdogTimeout)s",
                ]))
        }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { cont in
                self.speakContinuation = cont
                self.synth.speak(utterance)
            }
        }, onCancel: {
            Task { @MainActor in
                // A replacement may start before this actor hop runs. Cancellation
                // must stop only the utterance owned by the canceled call.
                guard self.currentToken == token else { return }
                self.stop()
            }
        })

        if self.currentToken != token {
            throw SpeakError.canceled
        }
    }

    /// Hang-guard timeout for an utterance: a per-language speech estimate times three.
    ///
    /// Speech rates follow Pellegrino et al. (2019) syllable-per-second data, adjusted for TTS
    /// synthesis: Korean 0.25 s/char, Chinese 0.28 s/char, Japanese 0.20 s/char (10 s minimum),
    /// otherwise 0.08 s/char (3 s minimum); the estimate is clamped to 300 s before the 3x margin.
    /// Normal completion relies on `didFinish`; the watchdog only guards lost callbacks.
    static func watchdogTimeoutSeconds(text: String, language: String?) -> Double {
        let normalizedLanguage = language?.lowercased() ?? "en"
        let perCharSeconds: Double
        let minSeconds: Double
        if normalizedLanguage.hasPrefix("ko") {
            perCharSeconds = 0.25
            minSeconds = 10.0
        } else if normalizedLanguage.hasPrefix("zh") {
            perCharSeconds = 0.28
            minSeconds = 10.0
        } else if normalizedLanguage.hasPrefix("ja") {
            perCharSeconds = 0.20
            minSeconds = 10.0
        } else {
            perCharSeconds = 0.08
            minSeconds = 3.0
        }
        let estimatedSeconds = max(minSeconds, min(300.0, Double(text.count) * perCharSeconds))
        return estimatedSeconds * 3.0
    }

    private func matchesCurrentUtterance(_ utteranceID: ObjectIdentifier) -> Bool {
        guard let currentUtterance = self.currentUtterance else { return false }
        return ObjectIdentifier(currentUtterance) == utteranceID
    }

    private func handleStart(utteranceID: ObjectIdentifier) {
        guard self.matchesCurrentUtterance(utteranceID) else { return }
        let callback = self.didStartCallback
        self.didStartCallback = nil
        self.publishNowPlaying()
        self.reportSpeaking(true)
        callback?()
    }

    private func handleFinish(utteranceID: ObjectIdentifier, error: Error?) {
        guard self.matchesCurrentUtterance(utteranceID) else { return }
        self.watchdog?.cancel()
        self.watchdog = nil
        self.finishCurrent(with: error)
    }

    private func finishCurrent(with error: Error?) {
        self.currentUtterance = nil
        self.didStartCallback = nil
        self.clearNowPlaying()
        self.reportSpeaking(false)
        let cont = self.speakContinuation
        self.speakContinuation = nil
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: ())
        }
    }

    private func publishNowPlaying() {
        guard let publisher = self.nowPlayingPublisher else { return }
        let metadata = OpenClawNowPlayingMetadata(
            contentID: "talk:\(self.currentToken.uuidString)",
            title: self.nowPlayingTitle ?? "OpenClaw",
            subtitle: "Talk",
            duration: nil,
            elapsed: 0,
            playbackRate: 1,
            state: .playing)
        self.publishedMetadata = metadata
        publisher.setCommandHandler { [weak self] command in
            switch command {
            case .pause, .stop, .togglePlayPause:
                self?.stop()
            case .play, .skipForward, .skipBackward:
                break
            }
        }
        publisher.publish(metadata)
    }

    private func clearNowPlaying() {
        guard self.publishedMetadata != nil else { return }
        self.publishedMetadata = nil
        self.nowPlayingPublisher?.clear()
    }

    private func reportSpeaking(_ speaking: Bool) {
        guard self.isReportingSpeaking != speaking else { return }
        self.isReportingSpeaking = speaking
        self.onSpeakingChanged?(speaking)
    }
}

extension TalkSystemSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    /// `AVSpeechSynthesizerDelegate` start callback.
    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance)
    {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.handleStart(utteranceID: utteranceID)
        }
    }

    /// `AVSpeechSynthesizerDelegate` finish callback.
    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance)
    {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.handleFinish(utteranceID: utteranceID, error: nil)
        }
    }

    /// `AVSpeechSynthesizerDelegate` cancel callback.
    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance)
    {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.handleFinish(utteranceID: utteranceID, error: SpeakError.canceled)
        }
    }
}

#if DEBUG
extension TalkSystemSpeechSynthesizer {
    // Package tests drive the Now Playing lifecycle without native speech services.
    func _test_simulateStart() {
        let utterance = AVSpeechUtterance(string: "test")
        self.currentUtterance = utterance
        self.handleStart(utteranceID: ObjectIdentifier(utterance))
    }

    // Package tests finish the simulated utterance.
    func _test_simulateFinish() {
        guard let utterance = self.currentUtterance else { return }
        self.handleFinish(utteranceID: ObjectIdentifier(utterance), error: nil)
    }
}
#endif
