import AVFoundation
import Foundation

#if !os(watchOS)
/// Options for a movie capture session (`camera.clip`).
public struct CameraMovieSessionOptions: Sendable {
    /// Prefer the front camera when no device is named.
    public let preferFrontCamera: Bool
    /// Explicit capture device identifier.
    public let deviceId: String?
    /// Whether to record microphone audio.
    public let includeAudio: Bool
    /// Maximum clip duration in milliseconds.
    public let durationMs: Int

    /// Creates movie session options.
    public init(
        preferFrontCamera: Bool,
        deviceId: String?,
        includeAudio: Bool,
        durationMs: Int)
    {
        self.preferFrontCamera = preferFrontCamera
        self.deviceId = deviceId
        self.includeAudio = includeAudio
        self.durationMs = durationMs
    }
}

/// Shared camera session assembly helpers used by photo and movie capture commands.
///
/// Unavailable on watchOS, where AVFoundation capture APIs do not exist. Photo and movie outputs are
/// also unavailable on visionOS.
public enum CameraCapturePipelineSupport {
    /// Selects a capture device: the named device when `deviceId` is set (else `deviceNotFoundError`),
    /// otherwise the fallback (else `unavailableError`).
    public static func selectCamera<Device>(
        deviceId: String?,
        matching: (String) -> Device?,
        fallback: () -> Device?,
        unavailableError: @autoclosure () -> Error,
        deviceNotFoundError: (String) -> Error) throws -> Device
    {
        if let deviceId, !deviceId.isEmpty {
            guard let device = matching(deviceId) else {
                throw deviceNotFoundError(deviceId)
            }
            return device
        }
        guard let device = fallback() else {
            throw unavailableError()
        }
        return device
    }

    #if !os(visionOS)
    /// Prepares a photo capture session; `pickCamera` throws its own unavailable/not-found errors.
    public static func preparePhotoSession(
        preferFrontCamera: Bool,
        deviceId: String?,
        pickCamera: (_ preferFrontCamera: Bool, _ deviceId: String?) throws -> AVCaptureDevice,
        mapSetupError: (CameraSessionConfigurationError) -> Error) throws
        -> (session: AVCaptureSession, device: AVCaptureDevice, output: AVCapturePhotoOutput)
    {
        let session = AVCaptureSession()
        session.sessionPreset = .photo

        let device = try pickCamera(preferFrontCamera, deviceId)

        do {
            try CameraSessionConfiguration.addCameraInput(session: session, camera: device)
            let output = try CameraSessionConfiguration.addPhotoOutput(session: session)
            return (session, device, output)
        } catch let setupError as CameraSessionConfigurationError {
            throw mapSetupError(setupError)
        }
    }

    /// Prepares a photo capture session and validates camera setup errors.
    @available(*, deprecated, message: "Use preparePhotoSession(preferFrontCamera:deviceId:pickCamera:mapSetupError:) with a throwing pickCamera")
    public static func preparePhotoSession(
        preferFrontCamera: Bool,
        deviceId: String?,
        pickCamera: (_ preferFrontCamera: Bool, _ deviceId: String?) -> AVCaptureDevice?,
        cameraUnavailableError: @autoclosure () -> Error,
        mapSetupError: (CameraSessionConfigurationError) -> Error) throws
        -> (session: AVCaptureSession, device: AVCaptureDevice, output: AVCapturePhotoOutput)
    {
        try self.preparePhotoSession(
            preferFrontCamera: preferFrontCamera,
            deviceId: deviceId,
            pickCamera: { front, id in
                guard let device = pickCamera(front, id) else { throw cameraUnavailableError() }
                return device
            },
            mapSetupError: mapSetupError)
    }

    /// Prepares a movie capture session; `pickCamera` throws its own unavailable/not-found errors.
    public static func prepareMovieSession(
        options: CameraMovieSessionOptions,
        pickCamera: (_ preferFrontCamera: Bool, _ deviceId: String?) throws -> AVCaptureDevice,
        mapSetupError: (CameraSessionConfigurationError) -> Error) throws
        -> (session: AVCaptureSession, output: AVCaptureMovieFileOutput)
    {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        let camera = try pickCamera(options.preferFrontCamera, options.deviceId)

        do {
            try CameraSessionConfiguration.addCameraInput(session: session, camera: camera)
            let output = try CameraSessionConfiguration.addMovieOutput(
                session: session,
                includeAudio: options.includeAudio,
                durationMs: options.durationMs)
            return (session, output)
        } catch let setupError as CameraSessionConfigurationError {
            throw mapSetupError(setupError)
        }
    }

    /// Prepares a movie capture session and validates camera or microphone setup errors.
    @available(*, deprecated, message: "Use prepareMovieSession(options:pickCamera:mapSetupError:)")
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
        try self.prepareMovieSession(
            options: CameraMovieSessionOptions(
                preferFrontCamera: preferFrontCamera,
                deviceId: deviceId,
                includeAudio: includeAudio,
                durationMs: durationMs),
            pickCamera: { front, id in
                guard let device = pickCamera(front, id) else { throw cameraUnavailableError() }
                return device
            },
            mapSetupError: mapSetupError)
    }

    /// Prepares and starts a movie session, then waits briefly for the camera pipeline to warm up.
    ///
    /// Deprecated: the caller owns stopping the returned session, which leaks it on cancellation.
    @available(*, deprecated, message: "Use withWarmMovieSession(options:pickCamera:mapSetupError:operation:)")
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
            options: CameraMovieSessionOptions(
                preferFrontCamera: preferFrontCamera,
                deviceId: deviceId,
                includeAudio: includeAudio,
                durationMs: durationMs),
            pickCamera: { front, id in
                guard let device = pickCamera(front, id) else { throw cameraUnavailableError() }
                return device
            },
            mapSetupError: mapSetupError)
        prepared.session.startRunning()
        await self.warmUpCaptureSession()
        return prepared
    }

    /// Starts a movie session, warms it up, runs `operation` against its output and always stops the
    /// session afterward, including on cancellation (checked before start, after warm-up and before
    /// the operation).
    public static func withWarmMovieSession<T>(
        options: CameraMovieSessionOptions,
        pickCamera: (_ preferFrontCamera: Bool, _ deviceId: String?) throws -> AVCaptureDevice,
        mapSetupError: (CameraSessionConfigurationError) -> Error,
        operation: (AVCaptureMovieFileOutput) async throws -> T) async throws -> T
    {
        try Task.checkCancellation()
        let prepared = try self.prepareMovieSession(
            options: options,
            pickCamera: pickCamera,
            mapSetupError: mapSetupError)
        return try await self.withCaptureSessionLifecycle(
            start: { prepared.session.startRunning() },
            stop: { prepared.session.stopRunning() },
            warmUp: { try await self.warmUpCaptureSessionCancellable() },
            operation: { try await operation(prepared.output) })
    }

    /// Runs an async operation against a warmed movie output and stops the session afterward.
    @available(*, deprecated, message: "Use withWarmMovieSession(options:pickCamera:mapSetupError:operation:)")
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
        try await self.withWarmMovieSession(
            options: CameraMovieSessionOptions(
                preferFrontCamera: preferFrontCamera,
                deviceId: deviceId,
                includeAudio: includeAudio,
                durationMs: durationMs),
            pickCamera: { front, id in
                guard let device = pickCamera(front, id) else { throw cameraUnavailableError() }
                return device
            },
            mapSetupError: mapSetupError,
            operation: operation)
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
    #endif

    /// Starts a session, warms it up and runs `operation`, always stopping the session once started.
    static func withCaptureSessionLifecycle<T>(
        start: () -> Void,
        stop: () -> Void,
        warmUp: () async throws -> Void,
        operation: () async throws -> T) async throws -> T
    {
        try Task.checkCancellation()
        start()
        defer { stop() }

        try Task.checkCancellation()
        try await warmUp()
        try Task.checkCancellation()
        return try await operation()
    }

    /// Waits briefly after `startRunning()` to reduce blank first-frame captures on some devices.
    public static func warmUpCaptureSession() async {
        try? await self.warmUpCaptureSessionCancellable()
    }

    /// Cancellation-aware warm-up used by the lifecycle helpers.
    static func warmUpCaptureSessionCancellable() async throws {
        // A short delay after `startRunning()` significantly reduces "blank first frame" captures on some devices.
        try await Task.sleep(nanoseconds: 150_000_000) // 150ms
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
#endif
