import AVFoundation
import Foundation

/// Shared camera session assembly helpers used by photo and movie capture commands.
public enum CameraCapturePipelineSupport {
    /// Prepares a photo capture session and validates camera setup errors.
    public static func preparePhotoSession(
        preferFrontCamera: Bool,
        deviceId: String?,
        pickCamera: (_ preferFrontCamera: Bool, _ deviceId: String?) -> AVCaptureDevice?,
        cameraUnavailableError: @autoclosure () -> Error,
        mapSetupError: (CameraSessionConfigurationError) -> Error) throws
        -> (session: AVCaptureSession, device: AVCaptureDevice, output: AVCapturePhotoOutput)
    {
        let session = AVCaptureSession()
        session.sessionPreset = .photo

        guard let device = pickCamera(preferFrontCamera, deviceId) else {
            throw cameraUnavailableError()
        }

        do {
            try CameraSessionConfiguration.addCameraInput(session: session, camera: device)
            let output = try CameraSessionConfiguration.addPhotoOutput(session: session)
            return (session, device, output)
        } catch let setupError as CameraSessionConfigurationError {
            throw mapSetupError(setupError)
        }
    }

    /// Prepares a movie capture session and validates camera or microphone setup errors.
    public static func prepareMovieSession(
        preferFrontCamera: Bool,
        deviceId: String?,
        includeAudio: Bool,
        durationMs: Int,
        pickCamera: (_ preferFrontCamera: Bool, _ deviceId: String?) -> AVCaptureDevice?,
        cameraUnavailableError: @autoclosure () -> Error,
        mapSetupError: (CameraSessionConfigurationError) -> Error) throws
        -> (session: AVCaptureSession, output: AVCaptureMovieFileOutput)
    {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let camera = pickCamera(preferFrontCamera, deviceId) else {
            throw cameraUnavailableError()
        }

        do {
            try CameraSessionConfiguration.addCameraInput(session: session, camera: camera)
            let output = try CameraSessionConfiguration.addMovieOutput(
                session: session,
                includeAudio: includeAudio,
                durationMs: durationMs)
            return (session, output)
        } catch let setupError as CameraSessionConfigurationError {
            throw mapSetupError(setupError)
        }
    }

    /// Prepares and starts a movie session, then waits briefly for the camera pipeline to warm up.
    public static func prepareWarmMovieSession(
        preferFrontCamera: Bool,
        deviceId: String?,
        includeAudio: Bool,
        durationMs: Int,
        pickCamera: (_ preferFrontCamera: Bool, _ deviceId: String?) -> AVCaptureDevice?,
        cameraUnavailableError: @autoclosure () -> Error,
        mapSetupError: (CameraSessionConfigurationError) -> Error) async throws
        -> (session: AVCaptureSession, output: AVCaptureMovieFileOutput)
    {
        let prepared = try self.prepareMovieSession(
            preferFrontCamera: preferFrontCamera,
            deviceId: deviceId,
            includeAudio: includeAudio,
            durationMs: durationMs,
            pickCamera: pickCamera,
            cameraUnavailableError: cameraUnavailableError(),
            mapSetupError: mapSetupError)
        prepared.session.startRunning()
        await self.warmUpCaptureSession()
        return prepared
    }

    /// Runs an async operation against a warmed movie output and stops the session afterward.
    public static func withWarmMovieSession<T>(
        preferFrontCamera: Bool,
        deviceId: String?,
        includeAudio: Bool,
        durationMs: Int,
        pickCamera: (_ preferFrontCamera: Bool, _ deviceId: String?) -> AVCaptureDevice?,
        cameraUnavailableError: @autoclosure () -> Error,
        mapSetupError: (CameraSessionConfigurationError) -> Error,
        operation: (AVCaptureMovieFileOutput) async throws -> T) async throws -> T
    {
        let prepared = try await self.prepareWarmMovieSession(
            preferFrontCamera: preferFrontCamera,
            deviceId: deviceId,
            includeAudio: includeAudio,
            durationMs: durationMs,
            pickCamera: pickCamera,
            cameraUnavailableError: cameraUnavailableError(),
            mapSetupError: mapSetupError)
        defer { prepared.session.stopRunning() }
        return try await operation(prepared.output)
    }

    /// Maps low-level movie setup errors onto higher-level command errors.
    public static func mapMovieSetupError<E: Error>(
        _ setupError: CameraSessionConfigurationError,
        microphoneUnavailableError: @autoclosure () -> E,
        captureFailed: (String) -> E) -> E
    {
        if case .microphoneUnavailable = setupError {
            return microphoneUnavailableError()
        }
        return captureFailed(setupError.localizedDescription)
    }

    /// Builds photo settings that prefer JPEG output when the device supports it.
    public static func makePhotoSettings(output: AVCapturePhotoOutput) -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings = {
            if output.availablePhotoCodecTypes.contains(.jpeg) {
                return AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            }
            return AVCapturePhotoSettings()
        }()
        settings.photoQualityPrioritization = .quality
        return settings
    }

    /// Captures one photo and resolves with the resulting JPEG or HEIC bytes.
    public static func capturePhotoData(
        output: AVCapturePhotoOutput,
        makeDelegate: (CheckedContinuation<Data, Error>) -> any AVCapturePhotoCaptureDelegate) async throws -> Data
    {
        var delegate: (any AVCapturePhotoCaptureDelegate)?
        let rawData: Data = try await withCheckedThrowingContinuation { cont in
            let captureDelegate = makeDelegate(cont)
            delegate = captureDelegate
            output.capturePhoto(with: self.makePhotoSettings(output: output), delegate: captureDelegate)
        }
        withExtendedLifetime(delegate) {}
        return rawData
    }

    /// Waits briefly after `startRunning()` to reduce blank first-frame captures on some devices.
    public static func warmUpCaptureSession() async {
        // A short delay after `startRunning()` significantly reduces "blank first frame" captures on some devices.
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
    }

    /// Returns a human-readable label for a camera position.
    public static func positionLabel(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .front: "front"
        case .back: "back"
        default: "unspecified"
        }
    }
}
