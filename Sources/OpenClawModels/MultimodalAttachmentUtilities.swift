import Foundation
import OpenClawCore
import OpenClawProtocol
#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

enum MultimodalAttachmentUtilities {
    static let maxInlineImageBytes = 10 * 1024 * 1024
    static let maxInlineTextBytes = 64 * 1024
    static let maxInlineBinaryBytes = 512 * 1024

    static func normalizedMimeType(for attachment: MediaAttachment) -> String {
        attachment.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func displayName(for attachment: MediaAttachment) -> String {
        let trimmed = attachment.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return "attachment-\(attachment.id.uuidString.prefix(8))"
    }

    static func inlineTextPreview(for attachment: MediaAttachment, mimeType: String) -> String? {
        guard Self.supportsTextInlining(mimeType: mimeType) else {
            return nil
        }
        let clippedData = attachment.data.prefix(Self.maxInlineTextBytes)
        guard var text = String(data: clippedData, encoding: .utf8) else {
            return nil
        }
        if attachment.data.count > Self.maxInlineTextBytes {
            text += "\n...[truncated]"
        }
        return text
    }

    static func supportsTextInlining(mimeType: String) -> Bool {
        if mimeType.hasPrefix("text/") {
            return true
        }
        return [
            "application/json",
            "application/xml",
            "application/x-yaml",
            "application/yaml",
            "application/javascript",
            "application/x-javascript",
        ].contains(mimeType)
    }

    /// Resizes an image to the model's `mediaInput.image` limits before base64 encoding.
    ///
    /// The longest side targets `preferredSidePx` (capped at `maxSidePx`); `maxPixels` and
    /// `maxBytes` shrink further (re-encoding as JPEG when needed). Images already within limits and
    /// images that cannot be decoded pass through unchanged. Resizing uses ImageIO/CoreGraphics and
    /// is a no-op where they are unavailable (Linux).
    /// - Parameters:
    ///   - attachment: Image attachment.
    ///   - limits: Model image limits.
    /// - Returns: The prepared attachment.
    static func prepareImage(_ attachment: MediaAttachment, limits: ModelImageInputLimits) -> MediaAttachment {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else {
            return attachment
        }
        guard var targetSide = self.targetLongestSide(width: width, height: height, limits: limits) else {
            if let maxBytes = limits.maxBytes, attachment.data.count > maxBytes {
                return self.reencode(source: source, attachment: attachment, longestSide: max(width, height), maxBytes: maxBytes)
            }
            return attachment
        }
        targetSide = max(1, targetSide)
        return self.reencode(source: source, attachment: attachment, longestSide: targetSide, maxBytes: limits.maxBytes)
        #else
        return attachment
        #endif
    }

    /// Longest side after applying limits, or `nil` when the image already fits.
    static func targetLongestSide(width: Int, height: Int, limits: ModelImageInputLimits) -> Int? {
        let longest = max(width, height)
        var target = longest
        if let preferred = limits.preferredSidePx, preferred > 0 {
            target = min(target, preferred)
        }
        if let maxSide = limits.maxSidePx, maxSide > 0 {
            target = min(target, maxSide)
        }
        if let maxPixels = limits.maxPixels, maxPixels > 0 {
            let scale = Double(target) / Double(longest)
            let pixels = Double(width) * scale * Double(height) * scale
            if pixels > Double(maxPixels) {
                let reduction = (Double(maxPixels) / pixels).squareRoot()
                target = max(1, Int((Double(target) * reduction).rounded(.down)))
            }
        }
        return target < longest ? target : nil
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    private static func reencode(source: CGImageSource, attachment: MediaAttachment, longestSide: Int, maxBytes: Int?) -> MediaAttachment {
        var side = longestSide
        let mime = self.normalizedMimeType(for: attachment)
        var outputType = mime == "image/png" ? "public.png" : "public.jpeg"
        var outputMime = mime == "image/png" ? "image/png" : "image/jpeg"
        for _ in 0..<6 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return attachment
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, outputType as CFString, 1, nil) else {
                return attachment
            }
            let properties: [CFString: Any] = outputType == "public.jpeg" ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                return attachment
            }
            let data = output as Data
            if let maxBytes, data.count > maxBytes {
                // Fall back to JPEG and shrink until the payload fits.
                outputType = "public.jpeg"
                outputMime = "image/jpeg"
                side = max(1, Int(Double(side) * 0.75))
                continue
            }
            return MediaAttachment(id: attachment.id, mimeType: outputMime, data: data, fileName: attachment.fileName, metadata: attachment.metadata)
        }
        return attachment
    }
    #endif
}
