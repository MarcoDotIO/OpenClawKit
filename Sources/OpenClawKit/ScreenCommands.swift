import Foundation

/// Screen node commands.
public enum OpenClawScreenCommand: String, Codable, Sendable {
    /// `screen.snapshot`: capture one still frame (desktop default).
    case snapshot = "screen.snapshot"
    /// `screen.record`: record a short clip (dangerous; explicit allow).
    case record = "screen.record"
}

/// Image format of a `screen.snapshot` result.
public enum OpenClawScreenSnapshotFormat: String, Codable, Sendable {
    /// JPEG (the default).
    case jpeg
    /// PNG.
    case png

    /// Detects the format from the image data header (`FF D8 FF` for JPEG, the PNG signature for PNG).
    public init?(sniffing data: Data) {
        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            self = .jpeg
        } else if bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            self = .png
        } else {
            return nil
        }
    }
}

/// Params for `screen.snapshot`.
///
/// The type existed at the 2026.4.25 pin and was later dead-coded upstream (the macOS app keeps a
/// private copy); the SDK keeps it public so host apps decode the same wire shape.
public struct OpenClawScreenSnapshotParams: Codable, Sendable, Equatable {
    /// Display index (0-based); `nil` means the main display.
    public var screenIndex: Int?
    /// Maximum output width in pixels (never upscales).
    public var maxWidth: Int?
    /// JPEG quality, 0...1.
    public var quality: Double?
    /// Requested format (defaults to JPEG).
    public var format: OpenClawScreenSnapshotFormat?

    /// Creates snapshot params.
    public init(
        screenIndex: Int? = nil,
        maxWidth: Int? = nil,
        quality: Double? = nil,
        format: OpenClawScreenSnapshotFormat? = nil)
    {
        self.screenIndex = screenIndex
        self.maxWidth = maxWidth
        self.quality = quality
        self.format = format
    }

    /// Stable error for params that fail strict decoding.
    public static let invalidParamsError = OpenClawNodeError(
        code: .invalidRequest,
        message: "INVALID_REQUEST: invalid screen snapshot params")

    /// Decodes invoke `paramsJSON` strictly, before any capture happens. `nil`/empty input means
    /// defaults; malformed JSON, unknown formats, wrong types or a negative `screenIndex` throw
    /// ``invalidParamsError``.
    public static func decodeInvokeParams(_ paramsJSON: String?) throws -> Self {
        guard let paramsJSON, !paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self()
        }
        guard let params = try? JSONDecoder().decode(Self.self, from: Data(paramsJSON.utf8)) else {
            throw self.invalidParamsError
        }
        if let screenIndex = params.screenIndex, screenIndex < 0 {
            throw self.invalidParamsError
        }
        if let quality = params.quality, !quality.isFinite {
            throw self.invalidParamsError
        }
        return params
    }

    /// Effective capture settings, matching the upstream macOS node: format defaults to JPEG,
    /// `maxWidth` defaults to 1600 (JPEG) / 900 (PNG) when absent or non-positive, and quality
    /// defaults to 0.72 clamped to `0.05...1`.
    public var normalized: (format: OpenClawScreenSnapshotFormat, maxWidth: Int, quality: Double) {
        let format = self.format ?? .jpeg
        let maxWidth = self.maxWidth.flatMap { $0 > 0 ? $0 : nil } ?? (format == .png ? 900 : 1600)
        let quality = min(1.0, max(0.05, self.quality ?? 0.72))
        return (format: format, maxWidth: maxWidth, quality: quality)
    }
}

/// Result payload of `screen.snapshot`.
public struct OpenClawScreenSnapshotPayload: Codable, Sendable, Equatable {
    /// Image format of ``base64``.
    public var format: String
    /// Base64-encoded image bytes.
    public var base64: String
    /// Display frame identity for later `computer.act` coordinates (see ``OpenClawComputerInputGeometry``).
    public var displayFrameId: String?
    /// Image width in pixels.
    public var width: Int
    /// Image height in pixels.
    public var height: Int
    /// Display index that was captured.
    public var screenIndex: Int?
    /// Capture time in milliseconds since the Unix epoch.
    public var capturedAtMs: Int64

    /// Creates a snapshot payload.
    public init(
        format: String,
        base64: String,
        displayFrameId: String? = nil,
        width: Int,
        height: Int,
        screenIndex: Int? = nil,
        capturedAtMs: Int64)
    {
        self.format = format
        self.base64 = base64
        self.displayFrameId = displayFrameId
        self.width = width
        self.height = height
        self.screenIndex = screenIndex
        self.capturedAtMs = capturedAtMs
    }
}

extension OpenClawNodeError {
    /// Stable error when a snapshot would not fit in the `node.invoke.result` frame.
    public static let screenSnapshotPayloadTooLarge = OpenClawNodeError(
        code: .unavailable,
        message: "UNAVAILABLE: screen snapshot payload too large; reduce maxWidth or use jpeg")

    /// Stable error when screen capture fails (TCC denied, capture or encode failure).
    public static let screenSnapshotFailed = OpenClawNodeError(
        code: .unavailable,
        message: "UNAVAILABLE: screen snapshot failed")

    /// Stable error when no display is available to capture.
    public static let screenSnapshotNoDisplays = OpenClawNodeError(
        code: .invalidRequest,
        message: "INVALID_REQUEST: no displays available for screen snapshot")

    /// Stable error for a `screenIndex` that does not name a display.
    public static func invalidScreenIndex(_ index: Int) -> OpenClawNodeError {
        OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: invalid screen index \(index)")
    }
}

/// Params for `screen.record`.
public struct OpenClawScreenRecordParams: Codable, Sendable, Equatable {
    /// Display index (0-based).
    public var screenIndex: Int?
    /// Clip duration in milliseconds (clamp with ``CaptureRateLimits/clampDurationMs(_:defaultMs:minMs:maxMs:)``).
    public var durationMs: Int?
    /// Frames per second (clamp with ``CaptureRateLimits/clampFps(_:defaultFps:minFps:maxFps:)``).
    public var fps: Double?
    /// Container format (`mp4`).
    public var format: String?
    /// Whether to record audio.
    public var includeAudio: Bool?

    /// Creates record params.
    public init(
        screenIndex: Int? = nil,
        durationMs: Int? = nil,
        fps: Double? = nil,
        format: String? = nil,
        includeAudio: Bool? = nil)
    {
        self.screenIndex = screenIndex
        self.durationMs = durationMs
        self.fps = fps
        self.format = format
        self.includeAudio = includeAudio
    }
}

/// Result payload of `screen.record` (shared by every recorder backend).
public struct OpenClawScreenRecordPayload: Codable, Sendable, Equatable {
    /// Container format (`mp4`).
    public var format: String
    /// Base64-encoded clip bytes.
    public var base64: String
    /// Requested (clamped) duration in milliseconds.
    public var durationMs: Int?
    /// Requested frame rate.
    public var fps: Double?
    /// Display index that was recorded.
    public var screenIndex: Int?
    /// Whether the clip has an audio track.
    public var hasAudio: Bool

    /// Creates a record payload.
    public init(
        format: String = "mp4",
        base64: String,
        durationMs: Int? = nil,
        fps: Double? = nil,
        screenIndex: Int? = nil,
        hasAudio: Bool)
    {
        self.format = format
        self.base64 = base64
        self.durationMs = durationMs
        self.fps = fps
        self.screenIndex = screenIndex
        self.hasAudio = hasAudio
    }
}
