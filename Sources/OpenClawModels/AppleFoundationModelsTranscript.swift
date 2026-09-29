import Foundation
import OpenClawProtocol

// Transcript replay planning for Apple Foundation Models, platform-neutral half.
//
// Port of upstream `extensions/apple-fm/assets/AppleFoundationModels.swift` `replay()`: the last
// user message becomes the prompt (an empty prompt resumes after tool output without synthetic user
// text), earlier messages become transcript entries, and tool calls must be answered exactly once by
// matching tool results. Validation errors keep the upstream wording. The Apple-only engine turns a
// plan into a `Transcript` plus `Prompt`.

/// Framework-neutral plan of a Foundation Models transcript.
struct FoundationModelsTranscriptPlan: Sendable, Equatable {
    /// Content of a prompt or tool output.
    enum Part: Sendable, Equatable {
        /// Text segment.
        case text(String)
        /// Image segment with a transcript-unique label (`image-1`, `image-2`, ...).
        case image(MediaAttachment, label: String)
    }

    /// One transcript entry after the instructions.
    enum Entry: Sendable, Equatable {
        /// Earlier user turn.
        case prompt([Part])
        /// Earlier assistant text.
        case response(String)
        /// Earlier assistant reasoning text (OS 27 only; dropped otherwise). Signatures are never
        /// replayed (upstream parity): this provider records none, so any signature in the
        /// transcript was produced by another provider and is opaque to Foundation Models.
        case reasoning(String)
        /// Earlier assistant tool call; `argumentsJSON` is a JSON object.
        case toolCall(ModelToolCall)
        /// Result answering an earlier tool call.
        case toolOutput(id: String, toolName: String, parts: [Part])
    }

    /// Instructions text: the system prompt plus any `system` transcript messages.
    var instructions: String
    /// Entries between the instructions and the prompt.
    var entries: [Entry]
    /// Final prompt parts; empty to resume after tool output.
    var prompt: [Part]

    /// Labels of images in the final prompt.
    var promptImageLabels: [String] {
        self.prompt.compactMap { part in
            if case .image(_, let label) = part { return label }
            return nil
        }
    }

    /// Whether any entry or the prompt carries an image.
    var containsImages: Bool {
        let entryParts = self.entries.flatMap { entry -> [Part] in
            switch entry {
            case .prompt(let parts), .toolOutput(_, _, let parts):
                return parts
            case .response, .reasoning, .toolCall:
                return []
            }
        }
        return (entryParts + self.prompt).contains { part in
            if case .image = part { return true }
            return false
        }
    }

    /// Final prompt text (text parts joined by newlines).
    var promptText: String {
        Self.text(of: self.prompt)
    }

    /// Joined text of the given parts.
    static func text(of parts: [Part]) -> String {
        parts.compactMap { part in
            if case .text(let value) = part { return value }
            return nil
        }.joined(separator: "\n")
    }
}

/// Builds and validates ``FoundationModelsTranscriptPlan`` values (upstream `replay()`).
enum FoundationModelsTranscriptPlanner {
    /// Upstream message for non-text content on models without vision.
    static let textOnlyMessage = "Only text content is supported for user and tool-result messages"

    /// Plans a transcript.
    /// - Parameters:
    ///   - systemPrompt: Primary system prompt.
    ///   - messages: Transcript (``ModelGenerationRequest/resolvedMessages``).
    ///   - allowImages: Whether image parts become attachments (OS 27 models with vision).
    ///   - allowReasoning: Whether assistant thinking is replayed (OS 27); otherwise it is dropped.
    /// - Returns: The plan.
    /// - Throws: ``FoundationModelsError`` (``FoundationModelsError/Code/invalidRequest``) with the
    ///   upstream messages.
    static func plan(
        systemPrompt: String?,
        messages: [ModelMessage],
        allowImages: Bool,
        allowReasoning: Bool
    ) throws -> FoundationModelsTranscriptPlan {
        guard !messages.isEmpty else {
            throw FoundationModelsError.invalidRequest("At least one message is required")
        }
        var history = messages
        var imageCounter = 0
        var instructions: [String] = []
        if let systemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !systemPrompt.isEmpty {
            instructions.append(systemPrompt)
        }
        var promptContent: [ModelContentPart] = []
        if case .user(let content) = history.last {
            history.removeLast()
            promptContent = content
        }
        var entries: [FoundationModelsTranscriptPlan.Entry] = []
        var pending: [String: String] = [:]
        for message in history {
            switch message {
            case .system(let content):
                let text = FoundationModelsTranscriptPlan.text(
                    of: try Self.parts(content, allowImages: false, imageCounter: &imageCounter)
                )
                if !text.isEmpty {
                    instructions.append(text)
                }
            case .user(let content):
                entries.append(.prompt(try Self.parts(content, allowImages: allowImages, imageCounter: &imageCounter)))
            case .assistant(let content):
                for part in content {
                    switch part {
                    case .text(let text):
                        entries.append(.response(text))
                    case .thinking(let text, _):
                        if allowReasoning {
                            entries.append(.reasoning(text))
                        }
                    case .toolCall(let call):
                        guard pending[call.id] == nil else {
                            throw FoundationModelsError.invalidRequest("Duplicate tool call id")
                        }
                        guard let arguments = call.arguments else {
                            throw FoundationModelsError.invalidRequest("Expected object: toolCall.arguments")
                        }
                        pending[call.id] = call.name
                        entries.append(.toolCall(ModelToolCall(id: call.id, name: call.name, arguments: arguments)))
                    }
                }
            case .toolResult(let result):
                guard pending.removeValue(forKey: result.toolCallID) == result.toolName else {
                    throw FoundationModelsError.invalidRequest("Unmatched tool result")
                }
                entries.append(
                    .toolOutput(
                        id: result.toolCallID,
                        toolName: result.toolName,
                        parts: try Self.parts(result.content, allowImages: allowImages, imageCounter: &imageCounter)
                    )
                )
            }
        }
        guard pending.isEmpty else {
            throw FoundationModelsError.invalidRequest("Tool calls are missing results")
        }
        // Labels follow transcript order, so the prompt's images are numbered after earlier ones.
        let promptParts = try Self.parts(promptContent, allowImages: allowImages, imageCounter: &imageCounter)
        return FoundationModelsTranscriptPlan(
            instructions: instructions.joined(separator: "\n\n"),
            entries: entries,
            prompt: promptParts
        )
    }

    /// Validates the host tool names of a request (upstream `Duplicate tool name`).
    /// - Parameter tools: Tool declarations.
    /// - Throws: ``FoundationModelsError`` when two tools share a name.
    static func validateToolNames(_ tools: [ModelToolDefinition]) throws {
        guard Set(tools.map(\.name)).count == tools.count else {
            throw FoundationModelsError.invalidRequest("Duplicate tool name")
        }
    }

    private static func parts(
        _ content: [ModelContentPart],
        allowImages: Bool,
        imageCounter: inout Int
    ) throws -> [FoundationModelsTranscriptPlan.Part] {
        try content.map { part in
            switch part {
            case .text(let text):
                return .text(text)
            case .image(let attachment):
                guard allowImages,
                      MultimodalAttachmentUtilities.normalizedMimeType(for: attachment).hasPrefix("image/"),
                      attachment.byteCount <= MultimodalAttachmentUtilities.maxInlineImageBytes
                else {
                    throw FoundationModelsError.invalidRequest(Self.textOnlyMessage)
                }
                imageCounter += 1
                return .image(attachment, label: "image-\(imageCounter)")
            case .attachment(let attachment):
                let mimeType = MultimodalAttachmentUtilities.normalizedMimeType(for: attachment)
                if mimeType.hasPrefix("image/") {
                    return try Self.parts([.image(attachment)], allowImages: allowImages, imageCounter: &imageCounter)[0]
                }
                // Text-like attachments are inlined like the HTTP providers do; binaries are rejected.
                guard let preview = MultimodalAttachmentUtilities.inlineTextPreview(for: attachment, mimeType: mimeType) else {
                    throw FoundationModelsError.invalidRequest(Self.textOnlyMessage)
                }
                return .text("[Attachment \(MultimodalAttachmentUtilities.displayName(for: attachment))]\n\(preview)")
            }
        }
    }
}
