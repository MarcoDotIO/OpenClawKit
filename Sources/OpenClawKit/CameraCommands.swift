import Foundation

/// Camera node commands.
public enum OpenClawCameraCommand: String, Codable, Sendable {
    /// `camera.list`: enumerate cameras (safe default).
    case list = "camera.list"
    /// `camera.snap`: capture a photo (dangerous; explicit allow).
    case snap = "camera.snap"
    /// `camera.clip`: record a short clip (dangerous; explicit allow).
    case clip = "camera.clip"
    /// `camera.ptz.status`: read pan/tilt/zoom state (macOS default).
    case ptzStatus = "camera.ptz.status"
    /// `camera.ptz.control`: move a PTZ camera (dangerous; explicit allow).
    case ptzControl = "camera.ptz.control"
}

/// Pan/tilt/zoom operation for `camera.ptz.control`.
public enum OpenClawCameraPTZOperation: String, Codable, Sendable {
    /// Move to absolute `target` values.
    case set
    /// Move by relative `delta` values.
    case move
    /// Return to the home position.
    case home
}

/// Pan/tilt/zoom axis values; omitted axes are left unchanged.
public struct OpenClawCameraPTZAxisValues: Codable, Sendable, Equatable {
    /// Pan in degrees.
    public var panDegrees: Double?
    /// Tilt in degrees.
    public var tiltDegrees: Double?
    /// Zoom as a percentage of the supported range.
    public var zoomPercent: Double?

    /// Creates axis values.
    public init(
        panDegrees: Double? = nil,
        tiltDegrees: Double? = nil,
        zoomPercent: Double? = nil)
    {
        self.panDegrees = panDegrees
        self.tiltDegrees = tiltDegrees
        self.zoomPercent = zoomPercent
    }
}

/// Params for `camera.ptz.status`.
public struct OpenClawCameraPTZStatusParams: Codable, Sendable, Equatable {
    /// Camera device identifier from `camera.list`.
    public var deviceId: String

    /// Creates status params.
    public init(deviceId: String) {
        self.deviceId = deviceId
    }
}

/// Params for `camera.ptz.control`.
public struct OpenClawCameraPTZControlParams: Codable, Sendable, Equatable {
    /// Camera device identifier from `camera.list`.
    public var deviceId: String
    /// Requested operation.
    public var operation: OpenClawCameraPTZOperation
    /// Absolute target for ``OpenClawCameraPTZOperation/set``.
    public var target: OpenClawCameraPTZAxisValues?
    /// Relative delta for ``OpenClawCameraPTZOperation/move``.
    public var delta: OpenClawCameraPTZAxisValues?

    /// Creates control params.
    public init(
        deviceId: String,
        operation: OpenClawCameraPTZOperation,
        target: OpenClawCameraPTZAxisValues? = nil,
        delta: OpenClawCameraPTZAxisValues? = nil)
    {
        self.deviceId = deviceId
        self.operation = operation
        self.target = target
        self.delta = delta
    }
}

public enum OpenClawCameraFacing: String, Codable, Sendable {
    case back
    case front
}

public enum OpenClawCameraImageFormat: String, Codable, Sendable {
    case jpg
    case jpeg
}

public enum OpenClawCameraVideoFormat: String, Codable, Sendable {
    case mp4
}

public struct OpenClawCameraSnapParams: Codable, Sendable, Equatable {
    public var facing: OpenClawCameraFacing?
    public var maxWidth: Int?
    public var quality: Double?
    public var format: OpenClawCameraImageFormat?
    public var deviceId: String?
    public var delayMs: Int?

    public init(
        facing: OpenClawCameraFacing? = nil,
        maxWidth: Int? = nil,
        quality: Double? = nil,
        format: OpenClawCameraImageFormat? = nil,
        deviceId: String? = nil,
        delayMs: Int? = nil)
    {
        self.facing = facing
        self.maxWidth = maxWidth
        self.quality = quality
        self.format = format
        self.deviceId = deviceId
        self.delayMs = delayMs
    }
}

public struct OpenClawCameraClipParams: Codable, Sendable, Equatable {
    public var facing: OpenClawCameraFacing?
    public var durationMs: Int?
    public var includeAudio: Bool?
    public var format: OpenClawCameraVideoFormat?
    public var deviceId: String?

    public init(
        facing: OpenClawCameraFacing? = nil,
        durationMs: Int? = nil,
        includeAudio: Bool? = nil,
        format: OpenClawCameraVideoFormat? = nil,
        deviceId: String? = nil)
    {
        self.facing = facing
        self.durationMs = durationMs
        self.includeAudio = includeAudio
        self.format = format
        self.deviceId = deviceId
    }
}
