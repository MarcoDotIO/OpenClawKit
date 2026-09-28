import Foundation

/// Share Extension image policy built on the shared, orientation-normalizing JPEG transcoder.
public enum ShareImageProcessor {
    /// Longest oriented edge of a shared image, in pixels.
    public static let maxLongEdgePx = 2560
    /// Initial JPEG quality.
    public static let jpegQuality = 0.9
    /// Maximum encoded size of a shared image, in bytes.
    public static let maxPayloadBytes = 5_000_000

    /// Why a shared image could not be prepared.
    public enum ProcessError: Error, Equatable, Sendable {
        /// The data is not a readable image.
        case invalidImage
        /// JPEG encoding failed.
        case encodeFailed
        /// No encoding fit ``ShareImageProcessor/maxPayloadBytes``.
        case sizeLimitExceeded
    }

    /// Returns capped, metadata-free JPEG data for a shared image.
    public static func processForUpload(data: Data) throws -> Data {
        do {
            return try JPEGTranscoder.transcodeToJPEG(
                imageData: data,
                maxLongEdgePx: self.maxLongEdgePx,
                quality: self.jpegQuality,
                maxBytes: self.maxPayloadBytes).data
        } catch JPEGTranscodeError.decodeFailed, JPEGTranscodeError.propertiesMissing {
            throw ProcessError.invalidImage
        } catch JPEGTranscodeError.sizeLimitExceeded {
            throw ProcessError.sizeLimitExceeded
        } catch {
            throw ProcessError.encodeFailed
        }
    }
}
