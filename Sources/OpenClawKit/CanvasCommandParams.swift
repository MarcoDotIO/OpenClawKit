import Foundation

/// Params for `canvas.navigate`.
public struct OpenClawCanvasNavigateParams: Codable, Sendable, Equatable {
    /// Widget document URL (hosted widget path or app-local canvas URL).
    public var url: String

    /// Creates navigate params.
    public init(url: String) {
        self.url = url
    }
}

/// Canvas panel placement; upstream dropped the public initializer, the SDK keeps it.
public struct OpenClawCanvasPlacement: Codable, Sendable, Equatable {
    /// Left edge.
    public var x: Double?
    /// Top edge.
    public var y: Double?
    /// Width.
    public var width: Double?
    /// Height.
    public var height: Double?

    /// Creates a placement.
    public init(x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Params for `canvas.present`.
public struct OpenClawCanvasPresentParams: Codable, Sendable, Equatable {
    /// Widget document URL to present.
    public var url: String?
    /// Optional panel placement.
    public var placement: OpenClawCanvasPlacement?

    /// Creates present params.
    public init(url: String? = nil, placement: OpenClawCanvasPlacement? = nil) {
        self.url = url
        self.placement = placement
    }
}

/// Params for the retired `canvas.eval` command.
@available(*, deprecated, message: "Retired upstream in OpenClaw 2026.8.1 (#126030); canvas is a widget presenter")
public struct OpenClawCanvasEvalParams: Codable, Sendable, Equatable {
    public var javaScript: String

    public init(javaScript: String) {
        self.javaScript = javaScript
    }
}

/// Image format of the retired `canvas.snapshot` command.
@available(*, deprecated, message: "Retired upstream in OpenClaw 2026.8.1 (#126030); canvas is a widget presenter")
public enum OpenClawCanvasSnapshotFormat: String, Codable, Sendable {
    case png
    case jpeg

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "png":
            self = .png
        case "jpeg", "jpg":
            self = .jpeg
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid snapshot format: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(self.rawValue)
    }
}

/// Params for the retired `canvas.snapshot` command.
@available(*, deprecated, message: "Retired upstream in OpenClaw 2026.8.1 (#126030); canvas is a widget presenter")
public struct OpenClawCanvasSnapshotParams: Codable, Sendable, Equatable {
    public var maxWidth: Int?
    public var quality: Double?
    public var format: OpenClawCanvasSnapshotFormat?

    public init(maxWidth: Int? = nil, quality: Double? = nil, format: OpenClawCanvasSnapshotFormat? = nil) {
        self.maxWidth = maxWidth
        self.quality = quality
        self.format = format
    }
}
