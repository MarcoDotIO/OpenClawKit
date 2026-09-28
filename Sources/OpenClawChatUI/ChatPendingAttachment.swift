import Foundation

#if canImport(AppKit)
import AppKit

/// Platform image type used by shared chat UI attachment previews on AppKit.
public typealias OpenClawPlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit

/// Platform image type used by shared chat UI attachment previews on UIKit.
public typealias OpenClawPlatformImage = UIImage
#endif

/// Attachment staged in the composer before it is sent.
///
/// Holds a platform preview image, so it stays in the UI layer rather than the transport-agnostic chat core.
public struct OpenClawPendingAttachment: Identifiable {
    /// Local identity.
    public let id = UUID()
    /// Source file URL, when the attachment came from a file.
    public let url: URL?
    /// Attachment bytes.
    public let data: Data
    /// File name sent with the attachment.
    public let fileName: String
    /// MIME type.
    public let mimeType: String
    /// Attachment type (`file`, `image`, ...).
    public let type: String
    /// Preview image.
    public let preview: OpenClawPlatformImage?
    /// Duration for recorded audio (voice notes).
    public let durationSeconds: Double?

    /// Creates a pending attachment.
    public init(
        url: URL?,
        data: Data,
        fileName: String,
        mimeType: String,
        type: String = "file",
        preview: OpenClawPlatformImage?,
        durationSeconds: Double? = nil)
    {
        self.url = url
        self.data = data
        self.fileName = fileName
        self.mimeType = mimeType
        self.type = type
        self.preview = preview
        self.durationSeconds = durationSeconds
    }
}
