import Foundation
import OpenClawProtocol

enum GeminiInputPart: Sendable, Encodable {
    case text(String)
    case inlineData(mimeType: String, data: String)

    private enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
    }

    private struct InlineDataPayload: Sendable, Encodable {
        let mimeType: String
        let data: String

        private enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case data
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(value, forKey: .text)
        case .inlineData(let mimeType, let data):
            try container.encode(InlineDataPayload(mimeType: mimeType, data: data), forKey: .inlineData)
        }
    }
}

enum GeminiMultimodalSupport {
    static func parts(prompt: String, attachments: [MediaAttachment]) -> [GeminiInputPart] {
        guard !attachments.isEmpty else {
            return [.text(prompt)]
        }

        var parts: [GeminiInputPart] = []
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty {
            parts.append(.text("Analyze the provided attachments and summarize key findings."))
        } else {
            parts.append(.text(prompt))
        }

        for attachment in attachments {
            let displayName = MultimodalAttachmentUtilities.displayName(for: attachment)
            let mimeType = MultimodalAttachmentUtilities.normalizedMimeType(for: attachment)

            if mimeType.hasPrefix("image/") {
                if attachment.data.count <= MultimodalAttachmentUtilities.maxInlineImageBytes {
                    parts.append(.text("Image attachment: \(displayName) (\(mimeType))"))
                    parts.append(
                        .inlineData(
                            mimeType: mimeType,
                            data: attachment.data.base64EncodedString()
                        )
                    )
                } else {
                    parts.append(
                        .text(
                            "Image attachment \(displayName) is too large to inline (\(attachment.data.count) bytes)."
                        )
                    )
                }
                continue
            }

            if let textPreview = MultimodalAttachmentUtilities.inlineTextPreview(for: attachment, mimeType: mimeType) {
                parts.append(.text("Text attachment: \(displayName) (\(mimeType))\n\(textPreview)"))
            } else if attachment.data.count <= MultimodalAttachmentUtilities.maxInlineBinaryBytes {
                parts.append(.text("Binary attachment: \(displayName) (\(mimeType), \(attachment.data.count) bytes)."))
                parts.append(
                    .inlineData(
                        mimeType: mimeType,
                        data: attachment.data.base64EncodedString()
                    )
                )
            } else {
                parts.append(
                    .text(
                        "Binary attachment: \(displayName) (\(mimeType), \(attachment.data.count) bytes) is too large to inline."
                    )
                )
            }
        }

        return parts
    }
}
