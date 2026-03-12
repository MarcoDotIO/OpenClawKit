import Foundation
import OpenClawProtocol

enum OpenAIStyleMessageContent: Sendable, Equatable, Encodable {
    case text(String)
    case parts([OpenAIStyleMessagePart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(value)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

enum OpenAIStyleMessagePart: Sendable, Equatable, Encodable {
    case text(String)
    case imageDataURL(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    private struct ImageURLPayload: Sendable, Equatable, Encodable {
        let url: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .imageDataURL(let dataURL):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURLPayload(url: dataURL), forKey: .imageURL)
        }
    }
}

enum OpenAIStyleMultimodalSupport {
    static func userContent(prompt: String, attachments: [MediaAttachment]) -> OpenAIStyleMessageContent {
        guard !attachments.isEmpty else {
            return .text(prompt)
        }

        var parts: [OpenAIStyleMessagePart] = []
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
                    let base64 = attachment.data.base64EncodedString()
                    parts.append(.text("Image attachment: \(displayName) (\(mimeType))"))
                    parts.append(.imageDataURL("data:\(mimeType);base64,\(base64)"))
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
            } else {
                if attachment.data.count <= MultimodalAttachmentUtilities.maxInlineBinaryBytes {
                    let base64 = attachment.data.base64EncodedString()
                    parts.append(
                        .text(
                            "Binary attachment: \(displayName) (\(mimeType), \(attachment.data.count) bytes)." +
                            "\nBase64 payload:\n\(base64)"
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
        }

        return .parts(parts)
    }
}
