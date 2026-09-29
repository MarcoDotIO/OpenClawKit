import Foundation
import OpenClawKit

/// Surface a delegated-model request came from (framework-agnostic mirror of
/// `_ModelDelegationConfiguration`, used for prompt shaping).
enum ModelDelegationSurface: Equatable, Sendable {
    /// Siri / system assistant, optionally with selected text.
    case systemAssistant(selectedText: String?)
    /// Writing Tools with the selection and the full text.
    case writingTools(selectedText: String?, allText: String?)
    /// Shortcuts, requesting a specific output type (`text`, `number`, `boolean`, `date`,
    /// `textList`, `uuidList`, `dictionary`).
    case shortcuts(outputType: String)
    /// Visual Intelligence.
    case visualIntelligence
    /// Image Playground (not supported by OpenClaw; text answers only).
    case imagePlayground
}

/// Pure prompt shaping for the experimental model-delegation adapter.
enum ModelDelegationPromptShaper {
    /// Session key prefix for delegated conversations.
    static let sessionKeyPrefix = "siri:"

    /// Maps a system conversation identifier to an OpenClaw session key.
    static func sessionKey(conversationIdentifier: String?) -> String? {
        let trimmed = conversationIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : Self.sessionKeyPrefix + trimmed
    }

    /// Builds the `chat.send` message for a delegated prompt.
    static func message(prompt: String, surface: ModelDelegationSurface) -> String {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch surface {
        case let .systemAssistant(selectedText):
            guard let selected = Self.nonEmpty(selectedText) else { return request }
            return "Selected text:\n<<<\n\(selected)\n>>>\n\n\(request)"
        case let .writingTools(selectedText, allText):
            var parts = [
                "You are acting as Apple Writing Tools. Apply the request to the selected text and "
                    + "return only the resulting text, without commentary.",
            ]
            if let selected = Self.nonEmpty(selectedText) {
                parts.append("Selected text:\n<<<\n\(selected)\n>>>")
            } else if let all = Self.nonEmpty(allText) {
                parts.append("Text:\n<<<\n\(all)\n>>>")
            }
            parts.append("Request: \(request)")
            return parts.joined(separator: "\n\n")
        case let .shortcuts(outputType):
            return "\(request)\n\n\(Self.outputInstruction(for: outputType))"
        case .visualIntelligence, .imagePlayground:
            return request
        }
    }

    /// Output-format instruction for a Shortcuts output type.
    static func outputInstruction(for outputType: String) -> String {
        switch outputType {
        case "number":
            return "Respond with a single number only."
        case "boolean":
            return "Respond with only `true` or `false`."
        case "date":
            return "Respond with a single ISO 8601 date only."
        case "textList":
            return "Respond with a JSON array of strings only."
        case "uuidList":
            return "Respond with a JSON array of UUID strings only."
        case "dictionary":
            return "Respond with a single JSON object only."
        default:
            return "Respond with plain text only."
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if ExperimentalAppleModelDelegation
#if compiler(>=6.4) && canImport(AppIntents) && (os(iOS) || os(macOS) || os(visionOS))
import AppIntents

/// EXPERIMENTAL: OpenClaw as a delegated model for Siri, Writing Tools and Shortcuts.
///
/// Built on the underscored AppIntents 27 `_ModelDelegationIntent` API and only compiled with the
/// `ExperimentalAppleModelDelegation` package trait (off by default). The API is undocumented, may
/// require an entitlement, and may change or disappear in any 27.x SDK update.
///
/// Delegated conversations map to OpenClaw sessions `siri:<conversationIdentifier>`; prompt files
/// are forwarded as `chat.send` attachments. Replies stream through the configured
/// ``OpenClawIntentHost``.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@_ModelDelegationIntent
public struct OpenClawModelDelegationIntent {
    /// Intent title.
    public static let title: LocalizedStringResource = "OpenClaw"

    /// Delegated surfaces OpenClaw handles.
    public static var supportedFeatures: _ModelDelegationFeatures {
        [.systemAssistant, .writingTools, .shortcuts]
    }

    /// Creates the intent (required by App Intents).
    public init() {}

    /// Handles one delegated request (called by the macro-generated `perform()`).
    public func perform(
        prompt: IntentPrompt,
        conversationIdentifier: String?,
        responseStream: IntentResponseStream<_ModelDelegationOutput>,
        configuration: _ModelDelegationConfiguration) async throws -> _ModelDelegationResult
    {
        let surface = Self.surface(for: configuration)
        let message = ModelDelegationPromptShaper.message(prompt: prompt.text, surface: surface)
        let attachments = prompt.files.map { file in
            OpenClawIntentAttachment(
                data: file.data,
                mimeType: file.type?.preferredMIMEType ?? "application/octet-stream",
                fileName: file.filename)
        }
        responseStream.setStatus("Thinking")
        let isWritingTools: Bool
        if case .writingTools = surface {
            isWritingTools = true
        } else {
            isWritingTools = false
        }

        var emitted = ""
        do {
            let stream = try await OpenClawAppIntents.host.send(
                prompt: message,
                sessionKey: ModelDelegationPromptShaper.sessionKey(conversationIdentifier: conversationIdentifier),
                agentId: nil,
                attachments: attachments)
            for try await event in stream {
                guard let text = event.text, text.count > emitted.count, text.hasPrefix(emitted) else { continue }
                let delta = String(text.dropFirst(emitted.count))
                emitted = text
                if !isWritingTools {
                    responseStream.append(text: delta)
                }
            }
        } catch {
            throw OpenClawIntentError.presentable(error)
        }
        if isWritingTools {
            responseStream.append(writingToolsOutput: emitted)
        }
        return .complete()
    }

    static func surface(for configuration: _ModelDelegationConfiguration) -> ModelDelegationSurface {
        switch configuration {
        case let .systemAssistant(assistant):
            return .systemAssistant(selectedText: assistant.selectedText)
        case let .writingTools(tools):
            return .writingTools(selectedText: tools.selectedText, allText: tools.allText)
        case let .shortcuts(shortcuts):
            return .shortcuts(outputType: shortcuts.outputType.rawValue)
        case .visualIntelligence:
            return .visualIntelligence
        case .imagePlayground:
            return .imagePlayground
        @unknown default:
            return .systemAssistant(selectedText: nil)
        }
    }
}

extension OpenClawAppIntents {
    /// EXPERIMENTAL: whether the system enabled OpenClaw as a delegated model.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    @MainActor
    public static var modelDelegationStatus: _ModelDelegationIntentEnabledStatus {
        OpenClawModelDelegationIntent.enabledStatus
    }
}
#endif
#endif
