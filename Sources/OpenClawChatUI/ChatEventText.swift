import Foundation
import OpenClawKit

/// Extracts visible assistant text from `chat` event message snapshots.
public enum OpenClawChatEventText {
    /// Visible assistant text of the event's message snapshot.
    public static func assistantText(from event: OpenClawChatEventPayload) -> String? {
        self.assistantText(fromMessage: event.message)
    }

    /// Visible assistant text of a message snapshot (a string, or `{role, content}` with text blocks).
    public static func assistantText(fromMessage message: AnyCodable?) -> String? {
        guard let message else { return nil }
        if let text = message.stringValue {
            return ChatPayloadDecoding.trimmedNonEmptyString(text)
        }
        guard let object = message.dictionaryValue else { return nil }
        if let role = object["role"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !role.isEmpty,
           role.lowercased() != "assistant"
        {
            return nil
        }
        guard let content = object["content"] else { return nil }
        return self.textContent(from: content)
    }

    private static func textContent(from value: AnyCodable) -> String? {
        if let text = value.stringValue {
            return ChatPayloadDecoding.trimmedNonEmptyString(text)
        }
        let parts: [String] = if let array = value.arrayValue {
            array.compactMap(self.textContentPart(from:))
        } else {
            self.textContentPart(from: value).map { [$0] } ?? []
        }
        return ChatPayloadDecoding.trimmedNonEmptyString(parts.joined(separator: "\n"))
    }

    private static func textContentPart(from value: AnyCodable) -> String? {
        if let text = value.stringValue {
            return ChatPayloadDecoding.trimmedNonEmptyString(text)
        }
        guard let object = value.dictionaryValue else { return nil }
        guard ChatMessageVisibleText.isVisibleContentType(
            object["type"]?.stringValue,
            role: "assistant")
        else { return nil }
        return ChatPayloadDecoding.trimmedNonEmptyString(object["text"]?.stringValue)
    }
}
