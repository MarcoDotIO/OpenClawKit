import Foundation
import OpenClawProtocol

enum AnthropicMessageContent: Sendable, Encodable {
    case text(String)
    case blocks([AnthropicMessageBlock])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(value)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

enum AnthropicMessageBlock: Sendable, Encodable {
    case text(String)
    case imageBase64(mediaType: String, data: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case source
    }

    private struct ImageSourcePayload: Sendable, Encodable {
        let type = "base64"
        let mediaType: String
        let data: String

        private enum CodingKeys: String, CodingKey {
            case type
            case mediaType = "media_type"
            case data
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .imageBase64(let mediaType, let data):
            try container.encode("image", forKey: .type)
            try container.encode(ImageSourcePayload(mediaType: mediaType, data: data), forKey: .source)
        }
    }
}

enum AnthropicStyleMultimodalSupport {
    static func userContent(prompt: String, attachments: [MediaAttachment]) -> AnthropicMessageContent {
        guard !attachments.isEmpty else {
            return .text(prompt)
        }

        var blocks: [AnthropicMessageBlock] = []
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty {
            blocks.append(.text("Analyze the provided attachments and summarize key findings."))
        } else {
            blocks.append(.text(prompt))
        }

        for attachment in attachments {
            let displayName = MultimodalAttachmentUtilities.displayName(for: attachment)
            let mimeType = MultimodalAttachmentUtilities.normalizedMimeType(for: attachment)

            if mimeType.hasPrefix("image/") {
                if attachment.data.count <= MultimodalAttachmentUtilities.maxInlineImageBytes {
                    blocks.append(.text("Image attachment: \(displayName) (\(mimeType))"))
                    blocks.append(
                        .imageBase64(
                            mediaType: mimeType,
                            data: attachment.data.base64EncodedString()
                        )
                    )
                } else {
                    blocks.append(
                        .text(
                            "Image attachment \(displayName) is too large to inline (\(attachment.data.count) bytes)."
                        )
                    )
                }
                continue
            }

            if let textPreview = MultimodalAttachmentUtilities.inlineTextPreview(for: attachment, mimeType: mimeType) {
                blocks.append(.text("Text attachment: \(displayName) (\(mimeType))\n\(textPreview)"))
            } else if attachment.data.count <= MultimodalAttachmentUtilities.maxInlineBinaryBytes {
                let base64 = attachment.data.base64EncodedString()
                blocks.append(
                    .text(
                        "Binary attachment: \(displayName) (\(mimeType), \(attachment.data.count) bytes)." +
                        "\nBase64 payload:\n\(base64)"
                    )
                )
            } else {
                blocks.append(
                    .text(
                        "Binary attachment: \(displayName) (\(mimeType), \(attachment.data.count) bytes) is too large to inline."
                    )
                )
            }
        }

        return .blocks(blocks)
    }
}
