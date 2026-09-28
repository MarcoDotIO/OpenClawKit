// Voice-note capture ships on iOS, macOS and visionOS (AVAudioRecorder; microphone permission through
// AVAudioApplication on iOS/visionOS and AVCaptureDevice on macOS). Ported from upstream OpenClaw 2026.9.6
// `VoiceNoteRecorder.swift`.
#if os(iOS) || os(macOS) || os(visionOS)
import AVFAudio
#if os(macOS)
import AVFoundation
#endif
import Foundation
import Observation
import OpenClawKit

private let voiceNoteMaximumDurationSeconds: TimeInterval = 180

/// Audio capture operations driven by the voice-note recorder state machine.
@MainActor
public protocol VoiceNoteAudioCapture: AnyObject {
    /// Requests microphone access when recording is first used.
    func requestPermission() async -> Bool

    /// Starts writing an audio recording to the supplied URL.
    func start(url: URL) throws

    /// Stops capture and returns the recorded duration in seconds.
    func stop() -> TimeInterval

    /// Stops and discards the active capture.
    func cancel()

    /// Reports capture loss after a recording has started.
    func setFailureHandler(_ handler: @escaping @MainActor () -> Void)

    /// Latest capture level in 0...1 for the live waveform, when supported.
    func currentLevel() -> Double?
}

extension VoiceNoteAudioCapture {
    /// Metering is a UI nicety; test captures may skip it.
    public func currentLevel() -> Double? {
        nil
    }
}

/// A completed voice-note recording ready to stage as a chat attachment.
public struct OpenClawVoiceNoteRecording: Equatable, Sendable {
    /// Temporary AAC (.m4a) file; the chat view model removes it after staging.
    public let fileURL: URL
    /// Recorded duration in seconds.
    public let durationSeconds: TimeInterval

    /// Creates a recording.
    public init(fileURL: URL, durationSeconds: TimeInterval) {
        self.fileURL = fileURL
        self.durationSeconds = durationSeconds
    }
}

/// Main-actor voice-note recorder with explicit permission and capture states.
@MainActor
@Observable
public final class OpenClawVoiceNoteRecorder {
    /// Recorder state machine.
    public enum State: Equatable {
        /// Ready to record.
        case idle
        /// Waiting for microphone permission.
        case requestingPermission
        /// Capturing audio.
        case recording(startedAt: Date, fileURL: URL)
        /// Capture finished; the recording awaits staging.
        case finished(recording: OpenClawVoiceNoteRecording)
        /// A composer claimed the recording and is staging it.
        case staging(recording: OpenClawVoiceNoteRecording)
        /// Permission, start or capture failed.
        case failed(message: String)
    }

    /// Longest voice note (180 s); recording finishes automatically at the limit.
    public static let maximumDurationSeconds = voiceNoteMaximumDurationSeconds

    /// Current state.
    public private(set) var state: State = .idle
    /// Seconds recorded so far (the final duration once finished).
    public private(set) var elapsedSeconds: TimeInterval = 0
    /// Live capture level in 0...1 while recording; drives the recording waveform.
    public private(set) var level: Double = 0

    /// Called when capture starts (`true`) and stops (`false`), for microphone arbitration.
    @ObservationIgnored public var onRecordingActiveChanged: (@MainActor (Bool) -> Void)?

    @ObservationIgnored private let capture: any VoiceNoteAudioCapture
    @ObservationIgnored private let durationLimit: TimeInterval
    @ObservationIgnored private let timerIntervalNanoseconds: UInt64
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var captureAdmissionHandler: @MainActor () -> Bool = { true }

    /// Creates a recorder backed by the system audio recorder.
    public convenience init() {
        self.init(capture: OpenClawVoiceNoteAudioCapture())
    }

    /// Creates a recorder with an injectable audio capture seam.
    public init(
        capture: any VoiceNoteAudioCapture,
        durationLimit: TimeInterval = OpenClawVoiceNoteRecorder.maximumDurationSeconds,
        timerIntervalNanoseconds: UInt64 = 100_000_000,
        now: @escaping () -> Date = Date.init)
    {
        self.capture = capture
        self.durationLimit = durationLimit
        self.timerIntervalNanoseconds = timerIntervalNanoseconds
        self.now = now
        self.capture.setFailureHandler { [weak self] in
            self?.captureFailed()
        }
    }

    deinit {
        self.timerTask?.cancel()
    }

    /// Whether audio is being captured.
    public var isRecording: Bool {
        if case .recording = self.state { return true }
        return false
    }

    /// Whether a permission prompt is pending.
    public var isRequestingPermission: Bool {
        self.state == .requestingPermission
    }

    /// True from permission request until the completed recording is staged.
    public var ownsPendingChatAttachment: Bool {
        switch self.state {
        case .requestingPermission, .recording, .finished, .staging:
            true
        case .idle, .failed:
            false
        }
    }

    /// Installs the app's synchronous microphone-ownership gate. The check and
    /// transition to requesting permission run in one MainActor turn.
    public func setCaptureAdmissionHandler(_ handler: @escaping @MainActor () -> Bool) {
        self.captureAdmissionHandler = handler
    }

    /// Failure message, in the failed state.
    public var errorMessage: String? {
        guard case let .failed(message) = self.state else { return nil }
        return message
    }

    /// The finished recording awaiting staging.
    public var completedRecording: OpenClawVoiceNoteRecording? {
        guard case let .finished(recording) = self.state else { return nil }
        return recording
    }

    /// Claims a finished recording exactly once while its captured chat stages it.
    func claimCompletedRecording() -> OpenClawVoiceNoteRecording? {
        guard case let .finished(recording) = self.state else { return nil }
        self.state = .staging(recording: recording)
        return recording
    }

    /// Releases chat ownership after the claimed recording was consumed.
    func completeStaging(_ recording: OpenClawVoiceNoteRecording) {
        guard self.state == .staging(recording: recording) else { return }
        self.state = .idle
        self.elapsedSeconds = 0
    }

    /// Requests permission if needed and starts a new recording.
    @discardableResult
    public func start() async -> Bool {
        guard self.state == .idle || self.errorMessage != nil else { return false }
        guard self.captureAdmissionHandler() else {
            self.fail(message: String(localized: "Another feature is using the microphone."))
            return false
        }

        self.elapsedSeconds = 0
        self.state = .requestingPermission
        guard await self.capture.requestPermission() else {
            self.fail(message: String(localized: "Microphone access is required. Enable it in Settings."))
            return false
        }
        guard self.state == .requestingPermission else { return false }

        let fileURL = self.makeTemporaryFileURL()
        self.onRecordingActiveChanged?(true)
        do {
            try self.capture.start(url: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            self.capture.cancel()
            self.onRecordingActiveChanged?(false)
            self.fail(message: String(
                format: String(localized: "Could not start recording: %@"),
                error.localizedDescription))
            return false
        }

        self.state = .recording(startedAt: self.now(), fileURL: fileURL)
        self.startTimer()
        return true
    }

    /// Finishes the active recording and publishes its attachment handoff.
    @discardableResult
    public func finish() -> OpenClawVoiceNoteRecording? {
        guard case let .recording(_, fileURL) = self.state else { return nil }

        self.timerTask?.cancel()
        self.timerTask = nil
        let duration = max(0, self.capture.stop())
        let recording = OpenClawVoiceNoteRecording(fileURL: fileURL, durationSeconds: duration)
        self.elapsedSeconds = duration
        self.level = 0
        self.state = .finished(recording: recording)
        self.onRecordingActiveChanged?(false)
        return recording
    }

    /// Cancels permission or capture and removes any temporary audio file.
    public func cancel() {
        // The chat view model owns the file after claiming the handoff.
        if case .staging = self.state { return }
        let fileURL: URL? = switch self.state {
        case let .recording(_, fileURL):
            fileURL
        case let .finished(recording):
            recording.fileURL
        default:
            nil
        }

        self.timerTask?.cancel()
        self.timerTask = nil
        self.capture.cancel()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let wasRecording = self.isRecording
        self.elapsedSeconds = 0
        self.level = 0
        self.state = .idle
        if wasRecording {
            self.onRecordingActiveChanged?(false)
        }
    }

    private func startTimer() {
        self.timerTask?.cancel()
        self.timerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.timerIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                guard case let .recording(startedAt, _) = self.state else { return }
                self.elapsedSeconds = max(0, self.now().timeIntervalSince(startedAt))
                if let captureLevel = self.capture.currentLevel() {
                    // Light smoothing keeps the 10 Hz meter poll from stepping visibly.
                    self.level = (self.level * 0.55) + (captureLevel * 0.45)
                }
                if self.elapsedSeconds >= self.durationLimit {
                    self.finish()
                    return
                }
            }
        }
    }

    private func fail(message: String) {
        self.timerTask?.cancel()
        self.timerTask = nil
        let wasRecording = self.isRecording
        self.elapsedSeconds = 0
        self.level = 0
        self.state = .failed(message: message)
        if wasRecording {
            self.onRecordingActiveChanged?(false)
        }
    }

    private func captureFailed() {
        guard case let .recording(_, fileURL) = self.state else { return }
        self.capture.cancel()
        try? FileManager.default.removeItem(at: fileURL)
        self.fail(message: String(localized: "Recording was interrupted. Try again."))
    }

    private func makeTemporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-\(UUID().uuidString).m4a")
    }
}

/// AVAudioRecorder-backed AAC voice-note capture.
@MainActor
public final class OpenClawVoiceNoteAudioCapture: NSObject, VoiceNoteAudioCapture, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var ownsAudioSession = false
    private var failureHandler: (@MainActor () -> Void)?

    override public init() {
        super.init()
        #if os(iOS) || os(visionOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.audioSessionInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance())
        #endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Installs the capture-loss handler.
    public func setFailureHandler(_ handler: @escaping @MainActor () -> Void) {
        self.failureHandler = handler
    }

    /// Requests microphone access (AVAudioApplication on iOS/visionOS, AVCaptureDevice on macOS).
    public func requestPermission() async -> Bool {
        #if os(iOS) || os(visionOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
        #elseif os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            return false
        }
        #else
        return false
        #endif
    }

    /// Starts AAC mono capture (24 kHz, 32 kbps) to `url`.
    public func start(url: URL) throws {
        do {
            #if os(iOS) || os(visionOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true)
            self.ownsAudioSession = true
            #endif

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw NSError(
                    domain: "OpenClawVoiceNoteAudioCapture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Audio recorder refused to start"])
            }
            self.recorder = recorder
        } catch {
            self.deactivateAudioSession()
            throw error
        }
    }

    /// Stops capture and returns the recorded duration.
    public func stop() -> TimeInterval {
        guard let recorder = self.recorder else { return 0 }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.deactivateAudioSession()
        return duration
    }

    /// Stops and discards the capture.
    public func cancel() {
        self.recorder?.stop()
        self.recorder = nil
        self.deactivateAudioSession()
    }

    /// Normalized average power of the live recording.
    public func currentLevel() -> Double? {
        guard let recorder, recorder.isRecording else { return nil }
        recorder.updateMeters()
        return TalkAudioLevel.normalized(decibels: Double(recorder.averagePower(forChannel: 0)))
    }

    /// Treats encoder errors as capture loss.
    nonisolated public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        Task { @MainActor [weak self] in
            self?.captureDidFail()
        }
    }

    #if os(iOS) || os(visionOS)
    @objc nonisolated private func audioSessionInterrupted(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            rawType == AVAudioSession.InterruptionType.began.rawValue
        else { return }
        Task { @MainActor [weak self] in
            self?.captureDidFail()
        }
    }
    #endif

    private func captureDidFail() {
        guard self.recorder != nil else { return }
        self.recorder?.stop()
        self.recorder = nil
        self.deactivateAudioSession()
        self.failureHandler?()
    }

    private func deactivateAudioSession() {
        #if os(iOS) || os(visionOS)
        guard self.ownsAudioSession else { return }
        self.ownsAudioSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

func openClawVoiceNoteDurationLabel(_ durationSeconds: TimeInterval) -> String {
    guard durationSeconds.isFinite else { return "0:00" }
    let boundedDuration = min(
        max(0, durationSeconds),
        voiceNoteMaximumDurationSeconds)
    let totalSeconds = Int(boundedDuration)
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
}
#endif
