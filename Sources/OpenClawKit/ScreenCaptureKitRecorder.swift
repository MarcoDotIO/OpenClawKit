#if compiler(>=6.4) && canImport(ScreenCaptureKit) && (os(iOS) || os(visionOS))
import AVFoundation
import Foundation
import ScreenCaptureKit

/// Opt-in iOS/visionOS 27 `screen.record` backend built on ScreenCaptureKit.
///
/// Unlike the in-app ReplayKit path, ScreenCaptureKit can record content the user picks in the system
/// sharing picker, so it always needs user interaction: call ``pickContent(includeMicrophone:)`` while
/// the app is in the foreground and the user asked for it, then ``record(filter:params:)``. Keep ReplayKit
/// as the default for agent-initiated captures, which cannot show a picker unattended. Hosts that
/// support this path may advertise the local permission key ``permissionKey`` in `connect.permissions`.
///
/// `screen.record` params are unchanged: the duration is clamped with
/// ``CaptureRateLimits/clampDurationMs(_:defaultMs:minMs:maxMs:)``, `fps` is reported (clamped to at
/// most 30) but ScreenCaptureKit on iOS does not expose a frame-interval setting, and only `mp4` is
/// supported.
@available(iOS 27.0, visionOS 27.0, *)
@MainActor
public final class ScreenCaptureKitRecorder {
    /// Local `connect.permissions` key for the system (picker-based) recording path.
    nonisolated public static let permissionKey = "screenRecordingSystem"

    /// Errors specific to the ScreenCaptureKit path.
    public enum RecorderError: Error, Equatable, LocalizedError, Sendable {
        /// The user dismissed the picker.
        case cancelled
        /// The picker or stream is unavailable on this device.
        case unavailable(String)
        /// Only `mp4` is supported.
        case unsupportedFormat(String)

        /// Human-readable description.
        public var errorDescription: String? {
            switch self {
            case .cancelled: "UNAVAILABLE: screen recording was cancelled"
            case let .unavailable(reason): "UNAVAILABLE: \(reason)"
            case let .unsupportedFormat(format): "INVALID_REQUEST: screen format must be mp4 (got \(format))"
            }
        }
    }

    private let picker = SCContentSharingPicker.shared
    private var activeObserver: PickerObserver?

    /// Creates a recorder.
    public init() {}

    /// Whether the system sharing picker is available.
    public var isAvailable: Bool {
        self.picker.isAvailable
    }

    /// Presents the system picker and returns the content the user selected.
    public func pickContent(includeMicrophone: Bool = false) async throws -> SCContentFilter {
        guard self.picker.isAvailable else {
            throw RecorderError.unavailable("the screen sharing picker is unavailable")
        }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = includeMicrophone
        self.picker.defaultConfiguration = configuration
        let observer = PickerObserver()
        self.activeObserver = observer
        self.picker.add(observer)
        defer {
            self.picker.remove(observer)
            self.picker.isActive = false
            self.activeObserver = nil
        }
        self.picker.isActive = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                observer.install(continuation)
                self.picker.present()
            }
        } onCancel: {
            observer.finish(.failure(CancellationError()))
        }
    }

    /// Records the picked content for the requested duration and returns the `screen.record` payload.
    public func record(filter: SCContentFilter, params: OpenClawScreenRecordParams) async throws
        -> OpenClawScreenRecordPayload
    {
        if let format = params.format?.lowercased(), !format.isEmpty, format != "mp4" {
            throw RecorderError.unsupportedFormat(format)
        }
        let durationMs = CaptureRateLimits.clampDurationMs(params.durationMs)
        let fps = CaptureRateLimits.clampFps(params.fps, maxFps: 30)
        let includeAudio = params.includeAudio ?? false

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = includeAudio
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-screen-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url
        recordingConfiguration.outputFileType = .mp4
        let delegate = RecordingDelegate()
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: delegate)
        try stream.addRecordingOutput(output)

        try await stream.startCapture()
        do {
            try await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
        } catch {
            // Cancelled within the invoke timeout: stop the system recorder before returning.
            try? await stream.stopCapture()
            throw error
        }
        try await stream.stopCapture()
        try await delegate.waitForFinish()

        let data = try Data(contentsOf: url)
        return OpenClawScreenRecordPayload(
            base64: data.base64EncodedString(),
            durationMs: durationMs,
            fps: fps,
            screenIndex: params.screenIndex,
            hasAudio: includeAudio)
    }
}

@available(iOS 27.0, visionOS 27.0, *)
private final class PickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SCContentFilter, any Error>?
    private var pending: Result<SCContentFilter, any Error>?

    func install(_ continuation: CheckedContinuation<SCContentFilter, any Error>) {
        let pending: Result<SCContentFilter, any Error>? = self.lock.withLock {
            if let pending = self.pending { return pending }
            self.continuation = continuation
            return nil
        }
        if let pending {
            continuation.resume(with: pending)
        }
    }

    func finish(_ result: Result<SCContentFilter, any Error>) {
        let continuation: CheckedContinuation<SCContentFilter, any Error>? = self.lock.withLock {
            guard let continuation = self.continuation else {
                if self.pending == nil { self.pending = result }
                return nil
            }
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        self.finish(.failure(ScreenCaptureKitRecorder.RecorderError.cancelled))
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        self.finish(.success(filter))
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        self.finish(.failure(ScreenCaptureKitRecorder.RecorderError.unavailable(error.localizedDescription)))
    }
}

@available(iOS 27.0, visionOS 27.0, *)
private final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var outcome: Result<Void, any Error>?

    func waitForFinish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let outcome: Result<Void, any Error>? = self.lock.withLock {
                if let outcome = self.outcome { return outcome }
                self.continuation = continuation
                return nil
            }
            if let outcome {
                continuation.resume(with: outcome)
            }
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        let continuation: CheckedContinuation<Void, any Error>? = self.lock.withLock {
            guard self.outcome == nil else { return nil }
            self.outcome = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        self.finish(.success(()))
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        self.finish(.failure(error))
    }
}
#endif
