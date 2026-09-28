import Foundation
import ImageIO
import OpenClawKit

/// Chat image upload policy (long edge 1600 px, JPEG quality 0.8, 3.5 MB), matching upstream `ChatImageProcessor`.
///
/// Implemented over the kit's `JPEGTranscoder` so the view model does not depend on the kit-side
/// `ChatImageProcessor` port; switch to it once that type is available.
enum ChatAttachmentImageProcessing {
    static let maxLongEdgePx = 1600
    static let jpegQuality = 0.8
    static let maxPayloadBytes = 3_500_000

    enum ProcessError: Error, LocalizedError, Sendable {
        case notAnImage
        case decodeFailed
        case encodeFailed

        var errorDescription: String? {
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

    static func processForUpload(data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ProcessError.notAnImage
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              rawWidth.intValue > 0, rawHeight.intValue > 0
        else {
            throw ProcessError.decodeFailed
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotates90 = (5...8).contains(orientation)
        let width = rotates90 ? rawHeight.intValue : rawWidth.intValue
        let height = rotates90 ? rawWidth.intValue : rawHeight.intValue
        // JPEGTranscoder bounds the oriented width; derive the width that keeps the long edge in budget.
        let maxWidth = width >= height
            ? self.maxLongEdgePx
            : max(1, Int((Double(self.maxLongEdgePx) * Double(width) / Double(height)).rounded(.down)))
        do {
            return try JPEGTranscoder.transcodeToJPEG(
                imageData: data,
                maxWidthPx: maxWidth,
                quality: self.jpegQuality,
                maxBytes: self.maxPayloadBytes).data
        } catch JPEGTranscodeError.decodeFailed {
            throw ProcessError.notAnImage
        } catch JPEGTranscodeError.propertiesMissing {
            throw ProcessError.decodeFailed
        } catch {
            throw ProcessError.encodeFailed
        }
    }
}
