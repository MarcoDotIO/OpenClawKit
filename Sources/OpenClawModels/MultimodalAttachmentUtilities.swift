import Foundation
import OpenClawProtocol

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
}
