import Foundation

/// Chat-specific image upload policy built on the shared JPEG transcoder.
///
/// Run every picked or pasted image through ``processForUpload(data:)`` before `chat.send`: it
/// normalizes orientation, converts HEIC/HEIF and PNG to JPEG, strips EXIF/GPS metadata and caps the
/// result at ``maxLongEdgePx`` / ``maxPayloadBytes``.
public enum ChatImageProcessor {
    /// Longest oriented edge of an uploaded chat image, in pixels.
    public static let maxLongEdgePx = 1600
    /// Initial JPEG quality.
    public static let jpegQuality = 0.8
    /// Maximum encoded size of an uploaded chat image, in bytes.
    public static let maxPayloadBytes = 3_500_000

    /// Why an image could not be prepared for upload.
    public enum ProcessError: Error, LocalizedError, Sendable {
        /// The data is not an image ImageIO can read.
        case notAnImage
        /// The image has no readable dimensions.
        case decodeFailed
        /// No encoding fit the upload limit, or encoding failed.
        case encodeFailed

        /// Human-readable description.
        public var errorDescription: String? {
            switch self {
            case .notAnImage:
                "The data is not a recognizable image."
            case .decodeFailed:
                "The image could not be decoded."
            case .encodeFailed:
                "The image could not be resized to fit the chat upload limit."
            }
        }
    }

    /// Returns capped, metadata-free JPEG data for a chat attachment.
    public static func processForUpload(data: Data) throws -> Data {
        do {
            let result = try JPEGTranscoder.transcodeToJPEG(
                imageData: data,
                maxLongEdgePx: self.maxLongEdgePx,
                quality: self.jpegQuality,
                maxBytes: self.maxPayloadBytes)
            return result.data
        } catch JPEGTranscodeError.decodeFailed {
            throw ProcessError.notAnImage
        } catch JPEGTranscodeError.propertiesMissing {
            throw ProcessError.decodeFailed
        } catch JPEGTranscodeError.sizeLimitExceeded {
            throw ProcessError.encodeFailed
        } catch {
            throw ProcessError.encodeFailed
        }
    }
}
