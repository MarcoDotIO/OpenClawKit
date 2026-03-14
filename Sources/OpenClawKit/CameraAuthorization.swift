import AVFoundation

/// Shared camera and microphone authorization helper.
public enum CameraAuthorization {
    /// Returns whether the app is authorized for the requested media type, requesting access when needed.
    public static func isAuthorized(for mediaType: AVMediaType) async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation(isolation: nil) { cont in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    cont.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
