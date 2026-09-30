import Foundation
import Testing
@testable import OpenClawChatUI

@MainActor
private final class FakeVoiceNoteAudioCapture: VoiceNoteAudioCapture {
    var permissionGranted = true
    var duration: TimeInterval = 12.5
    var startError: Error?
    var startCount = 0
    var cancelCount = 0
    var activeURL: URL?
    var onStart: (() -> Void)?
    var failureHandler: (@MainActor () -> Void)?

    func requestPermission() async -> Bool {
        self.permissionGranted
    }

    func start(url: URL) throws {
        self.onStart?()
        if let startError { throw startError }
        self.startCount += 1
        self.activeURL = url
        try Data("voice-note".utf8).write(to: url)
    }

    func stop() -> TimeInterval {
        self.duration
    }

    func cancel() {
        self.cancelCount += 1
    }

    func setFailureHandler(_ handler: @escaping @MainActor () -> Void) {
        self.failureHandler = handler
    }

    var meterLevel: Double?

    func currentLevel() -> Double? {
        self.meterLevel
    }

    func failCapture() {
        self.failureHandler?()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct VoiceNoteRecorderTests {
    @MainActor
    @Test func startAndFinishProduceRecordingWithDuration() async throws {
        let capture = FakeVoiceNoteAudioCapture()
        let recorder = OpenClawVoiceNoteRecorder(capture: capture)
        var activeChanges: [Bool] = []
        recorder.onRecordingActiveChanged = { activeChanges.append($0) }
        capture.onStart = { #expect(activeChanges == [true]) }

        let started = await recorder.start()
        #expect(started)
        guard case .recording = recorder.state else {
            Issue.record("Expected recording state")
            return
        }

        let result = try #require(recorder.finish())
        #expect(result.durationSeconds == 12.5)
        #expect(recorder.state == .finished(recording: result))
        #expect(recorder.completedRecording == result)
        #expect(activeChanges == [true, false])
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
        try FileManager.default.removeItem(at: result.fileURL)
    }

    @MainActor
    @Test func completedRecordingHasOneStagingOwner() async throws {
        let capture = FakeVoiceNoteAudioCapture()
        let recorder = OpenClawVoiceNoteRecorder(capture: capture)

        let started = await recorder.start()
        #expect(started)
        let recording = try #require(recorder.finish())

        #expect(recorder.claimCompletedRecording() == recording)
        #expect(recorder.claimCompletedRecording() == nil)
        #expect(recorder.ownsPendingChatAttachment)

        recorder.completeStaging(recording)

        #expect(recorder.state == .idle)
        #expect(!recorder.ownsPendingChatAttachment)
        try FileManager.default.removeItem(at: recording.fileURL)
    }

    @MainActor
    @Test func cancelReturnsToIdleAndDeletesTemporaryFile() async throws {
        let capture = FakeVoiceNoteAudioCapture()
        let recorder = OpenClawVoiceNoteRecorder(capture: capture)

        let started = await recorder.start()
        #expect(started)
        let fileURL = try #require(capture.activeURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        recorder.cancel()

        #expect(recorder.state == .idle)
        #expect(!(FileManager.default.fileExists(atPath: fileURL.path)))
        #expect(capture.cancelCount == 1)
    }

    @MainActor
    @Test func successiveRecordingsUseUniqueTemporaryFiles() async throws {
        let capture = FakeVoiceNoteAudioCapture()
        let recorder = OpenClawVoiceNoteRecorder(
            capture: capture,
            now: { Date(timeIntervalSince1970: 0) })

        let firstStarted = await recorder.start()
        #expect(firstStarted)
        let firstURL = try #require(capture.activeURL)
        recorder.cancel()

        let secondStarted = await recorder.start()
        #expect(secondStarted)
        let secondURL = try #require(capture.activeURL)
        #expect(firstURL != secondURL)
        recorder.cancel()
    }

    @MainActor
    @Test func durationCapAutoFinishes() async throws {
        let capture = FakeVoiceNoteAudioCapture()
        capture.duration = 0.25
        let recorder = OpenClawVoiceNoteRecorder(
            capture: capture,
            durationLimit: 0,
            timerIntervalNanoseconds: 1_000_000)

        let started = await recorder.start()
        #expect(started)
        try await waitUntil("voice note auto-finished") {
            await MainActor.run { recorder.completedRecording != nil }
        }

        let result = try #require(recorder.completedRecording)
        #expect(result.durationSeconds == 0.25)
        #expect(recorder.state == .finished(recording: result))
        try FileManager.default.removeItem(at: result.fileURL)
    }

    @MainActor
    @Test func permissionDeniedBecomesUserVisibleFailure() async {
        let capture = FakeVoiceNoteAudioCapture()
        capture.permissionGranted = false
        let recorder = OpenClawVoiceNoteRecorder(capture: capture)

        let started = await recorder.start()
        #expect(!started)
        guard case let .failed(message) = recorder.state else {
            Issue.record("Expected failure state")
            return
        }
        #expect(message.contains("Microphone access"))
        #expect(capture.startCount == 0)
    }

    @MainActor
    @Test func captureStartFailureReleasesRecordingActivity() async {
        let capture = FakeVoiceNoteAudioCapture()
        capture.startError = NSError(domain: "VoiceNoteRecorderTests", code: 1)
        let recorder = OpenClawVoiceNoteRecorder(capture: capture)
        var activeChanges: [Bool] = []
        recorder.onRecordingActiveChanged = { activeChanges.append($0) }

        let started = await recorder.start()

        #expect(!started)
        #expect(activeChanges == [true, false])
        guard case .failed = recorder.state else {
            Issue.record("Expected failure state")
            return
        }
    }

    @MainActor
    @Test func captureInterruptionFailsAndDeletesTemporaryFile() async throws {
        let capture = FakeVoiceNoteAudioCapture()
        let recorder = OpenClawVoiceNoteRecorder(capture: capture)
        var activeChanges: [Bool] = []
        recorder.onRecordingActiveChanged = { activeChanges.append($0) }

        let started = await recorder.start()
        #expect(started)
        let fileURL = try #require(capture.activeURL)

        capture.failCapture()

        #expect(activeChanges == [true, false])
        #expect(capture.cancelCount == 1)
        #expect(!(FileManager.default.fileExists(atPath: fileURL.path)))
        guard case let .failed(message) = recorder.state else {
            Issue.record("Expected failure state")
            return
        }
        #expect(message.contains("interrupted"))
    }

    @MainActor
    @Test func startIsRefusedWhileAlreadyRecording() async {
        let capture = FakeVoiceNoteAudioCapture()
        let recorder = OpenClawVoiceNoteRecorder(capture: capture)

        let firstStart = await recorder.start()
        let secondStart = await recorder.start()
        #expect(firstStart)
        #expect(!secondStart)
        #expect(capture.startCount == 1)
        recorder.cancel()
    }

    @Test func durationLabelBoundsMalformedHistoryValues() {
        #expect(openClawVoiceNoteDurationLabel(.infinity) == "0:00")
        #expect(openClawVoiceNoteDurationLabel(.nan) == "0:00")
        #expect(openClawVoiceNoteDurationLabel(1e100) == "3:00")
        #expect(openClawVoiceNoteDurationLabel(-1) == "0:00")
    }

    @Test func unifiedMicKeepsVoiceNoteAvailableWithoutDictation() {
        #expect(!(OpenClawChatMicButton.dictationActionEnabled(
            isComposerEnabled: true,
            isAvailable: false,
            isPending: false,
            isActive: false,
            isTalkActive: false,
            isVoiceNoteCaptureActive: false)))
        #expect(OpenClawChatMicButton.voiceNoteRecordingEnabled(
            isComposerEnabled: true,
            isAttachmentInputEnabled: true,
            isDictationActive: false,
            isDictationPending: false,
            isTalkActive: false,
            isRecording: false,
            isRequestingPermission: false))
    }

    @Test func unifiedMicPreventsCompetingVoiceCapture() {
        #expect(!(OpenClawChatMicButton.voiceNoteRecordingEnabled(
            isComposerEnabled: true,
            isAttachmentInputEnabled: true,
            isDictationActive: true,
            isDictationPending: false,
            isTalkActive: false,
            isRecording: false,
            isRequestingPermission: false)))
        #expect(!(OpenClawChatMicButton.voiceNoteRecordingEnabled(
            isComposerEnabled: true,
            isAttachmentInputEnabled: true,
            isDictationActive: false,
            isDictationPending: true,
            isTalkActive: false,
            isRecording: false,
            isRequestingPermission: false)))
        #expect(!(OpenClawChatMicButton.voiceNoteRecordingEnabled(
            isComposerEnabled: true,
            isAttachmentInputEnabled: true,
            isDictationActive: false,
            isDictationPending: false,
            isTalkActive: true,
            isRecording: false,
            isRequestingPermission: false)))
        #expect(!(OpenClawChatMicButton.voiceNoteRecordingEnabled(
            isComposerEnabled: true,
            isAttachmentInputEnabled: true,
            isDictationActive: false,
            isDictationPending: false,
            isTalkActive: false,
            isRecording: true,
            isRequestingPermission: false)))
        #expect(!(OpenClawChatMicButton.dictationActionEnabled(
            isComposerEnabled: true,
            isAvailable: true,
            isPending: false,
            isActive: false,
            isTalkActive: true,
            isVoiceNoteCaptureActive: false)))
        #expect(!(OpenClawChatMicButton.dictationActionEnabled(
            isComposerEnabled: true,
            isAvailable: true,
            isPending: false,
            isActive: false,
            isTalkActive: false,
            isVoiceNoteCaptureActive: true)))
        #expect(OpenClawChatMicButton.dictationActionEnabled(
            isComposerEnabled: false,
            isAvailable: false,
            isPending: false,
            isActive: true,
            isTalkActive: true,
            isVoiceNoteCaptureActive: true))
        #expect(!(OpenClawChatMicButton.dictationActionEnabled(
            isComposerEnabled: false,
            isAvailable: true,
            isPending: false,
            isActive: false,
            isTalkActive: false,
            isVoiceNoteCaptureActive: false)))
    }

    @Test func unifiedMicCancelsPendingDictationStart() {
        #expect(OpenClawChatMicButton.dictationPrimaryAction(
            isPending: true,
            isActive: false) == .cancel)
        #expect(OpenClawChatMicButton.dictationPrimaryAction(
            isPending: true,
            isActive: true) == .finish)
        #expect(OpenClawChatMicButton.dictationPrimaryAction(
            isPending: false,
            isActive: false) == .start)
        #expect(OpenClawChatMicButton.dictationActionEnabled(
            isComposerEnabled: false,
            isAvailable: false,
            isPending: true,
            isActive: false,
            isTalkActive: true,
            isVoiceNoteCaptureActive: true))
    }

    @Test func compactTalkControlYieldsToLocalVoiceCapture() {
        #expect(OpenClawChatComposer.showsCompactTalkControl(
            hasDraftToSend: false,
            hasBlockingRunActivity: false,
            isLocalVoiceCaptureActive: false))
        #expect(!(OpenClawChatComposer.showsCompactTalkControl(
            hasDraftToSend: false,
            hasBlockingRunActivity: false,
            isLocalVoiceCaptureActive: true)))
        #expect(!(OpenClawChatComposer.showsCompactTalkControl(
            hasDraftToSend: true,
            hasBlockingRunActivity: false,
            isLocalVoiceCaptureActive: false)))
        #expect(!(OpenClawChatComposer.showsCompactTalkControl(
            hasDraftToSend: false,
            hasBlockingRunActivity: true,
            isLocalVoiceCaptureActive: false)))
    }

    @MainActor
    @Test func recordingPublishesCaptureLevelsAndResetsOnFinish() async throws {
        let capture = FakeVoiceNoteAudioCapture()
        capture.meterLevel = 0.8
        let recorder = OpenClawVoiceNoteRecorder(
            capture: capture,
            timerIntervalNanoseconds: 2_000_000)

        let started = await recorder.start()
        #expect(started)
        #expect(recorder.level == 0)

        for _ in 0..<200 where recorder.level == 0 {
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        #expect(recorder.level > 0)

        _ = try #require(recorder.finish())
        #expect(recorder.level == 0)
    }

    @MainActor
    @Test func recordButtonRequiresAttachmentInput() {
        let recorder = OpenClawVoiceNoteRecorder(capture: FakeVoiceNoteAudioCapture())
        let control = OpenClawChatVoiceNoteControl(recorder: recorder, isTalkActive: false)
        let button = OpenClawVoiceNoteButton(
            control: control,
            compact: false,
            isComposerEnabled: true,
            isAttachmentInputEnabled: false)

        #expect(!button.isRecordingEnabled)
    }
}
