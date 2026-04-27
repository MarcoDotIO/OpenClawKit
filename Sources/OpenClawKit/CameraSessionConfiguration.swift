import AVFoundation
import CoreMedia

/// Errors thrown while assembling AVFoundation capture sessions.
public enum CameraSessionConfigurationError: LocalizedError {
    case addCameraInputFailed
    case addPhotoOutputFailed
    case microphoneUnavailable
    case addMicrophoneInputFailed
    case addMovieOutputFailed

    /// User-facing description of the camera setup failure.
    public var errorDescription: String? {
        switch self {
        case .addCameraInputFailed:
            "Failed to add camera input"
        case .addPhotoOutputFailed:
            "Failed to add photo output"
        case .microphoneUnavailable:
            "Microphone unavailable"
        case .addMicrophoneInputFailed:
            "Failed to add microphone input"
        case .addMovieOutputFailed:
            "Failed to add movie output"
        }
    }
}

/// Low-level AVFoundation helpers that wire camera, microphone, and output objects into a capture session.
public enum CameraSessionConfiguration {
    /// Adds the requested camera input to a session.
    public static func addCameraInput(session: AVCaptureSession, camera: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CameraSessionConfigurationError.addCameraInputFailed
        }
        session.addInput(input)
    }

    #if !os(visionOS)
    /// Adds a photo output configured for high-quality captures.
    public static func addPhotoOutput(session: AVCaptureSession) throws -> AVCapturePhotoOutput {
        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            throw CameraSessionConfigurationError.addPhotoOutputFailed
        }
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .quality
        return output
    }

    /// Adds a movie output and optional microphone input to a capture session.
    public static func addMovieOutput(
        session: AVCaptureSession,
        includeAudio: Bool,
        durationMs: Int) throws -> AVCaptureMovieFileOutput
    {
        if includeAudio {
            guard let mic = AVCaptureDevice.default(for: .audio) else {
                throw CameraSessionConfigurationError.microphoneUnavailable
            }
            let micInput = try AVCaptureDeviceInput(device: mic)
            guard session.canAddInput(micInput) else {
                throw CameraSessionConfigurationError.addMicrophoneInputFailed
            }
            session.addInput(micInput)
        }

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else {
            throw CameraSessionConfigurationError.addMovieOutputFailed
        }
        session.addOutput(output)
        output.maxRecordedDuration = CMTime(value: Int64(durationMs), timescale: 1000)
        return output
    }
    #endif
}
