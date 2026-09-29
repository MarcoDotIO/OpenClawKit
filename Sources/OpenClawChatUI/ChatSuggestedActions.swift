// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import Foundation
import SwiftUI
#if compiler(>=6.4) && canImport(SuggestedActions)
import SuggestedActions
#endif

// OpenClawKit-specific (no upstream counterpart): Apple Intelligence suggested actions (SuggestedActions
// framework, iOS/macOS/visionOS 27) under the latest inbound message. Opt-in with
// `.openClawSuggestedActions(true)`; the transcript passes the preceding messages as context.

extension EnvironmentValues {
    /// Whether chat shows system suggested actions under the latest inbound message (27+). Default false.
    @Entry public var openClawSuggestedActionsEnabled = false
}

extension View {
    /// Shows Apple Intelligence suggested actions under the latest inbound chat message (iOS, macOS and
    /// visionOS 27+). Off by default.
    public func openClawSuggestedActions(_ enabled: Bool) -> some View {
        self.environment(\.openClawSuggestedActionsEnabled, enabled)
    }
}

/// Plain-text projection of chat messages for suggested-action generation.
struct ChatSuggestedActionsInput: Equatable {
    struct Entry: Equatable {
        let id: UUID
        let date: Date
        let body: String
        let isFromUser: Bool
        let senderName: String
    }

    let message: Entry
    let previousMessages: [Entry]

    /// Builds the projection for `message`, or nil when it is not an inbound message with visible text.
    /// `previousMessages` keeps at most `limit` of the latest visible user/assistant messages before it.
    init?(message: OpenClawChatMessage, history: [OpenClawChatMessage], assistantName: String?, limit: Int) {
        guard let entry = Self.entry(for: message, assistantName: assistantName), !entry.isFromUser else {
            return nil
        }
        self.message = entry
        let prior = history.prefix { $0.id != message.id }
        self.previousMessages = Array(prior.compactMap { Self.entry(for: $0, assistantName: assistantName) }
            .suffix(max(0, limit)))
    }

    private static func entry(for message: OpenClawChatMessage, assistantName: String?) -> Entry? {
        let role = message.role.lowercased()
        guard role == "user" || role == "assistant" else { return nil }
        let text = ChatMessageVisibleText.visibleText(in: message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let isOwnerUser = role == "user" && message.provenance?.kind != "external_user"
        let date = message.timestamp.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let sender: String = if role == "assistant" {
            assistantName ?? "Assistant"
        } else if isOwnerUser {
            "You"
        } else {
            message.provenance?.sourceChannel ?? "Contact"
        }
        return Entry(id: message.id, date: date, body: text, isFromUser: isOwnerUser, senderName: sender)
    }
}

/// Suggested actions for one inbound message; renders nothing before 27 or when disabled.
struct ChatSuggestedActionsRow: View {
    let message: OpenClawChatMessage
    let history: [OpenClawChatMessage]
    let assistantName: String?
    @Environment(\.openClawSuggestedActionsEnabled) private var isEnabled

    var body: some View {
        #if compiler(>=6.4) && canImport(SuggestedActions)
        if self.isEnabled, #available(iOS 27.0, macOS 27.0, visionOS 27.0, *),
           let input = ChatSuggestedActionsInput(
               message: self.message,
               history: self.history,
               assistantName: self.assistantName,
               limit: SuggestedActionsMessage.previousMessagesLimit)
        {
            ChatSystemSuggestedActionsView(input: input)
        }
        #endif
    }
}

#if compiler(>=6.4) && canImport(SuggestedActions)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private struct ChatSystemSuggestedActionsView: View {
    let input: ChatSuggestedActionsInput
    @State private var preparedID: UUID?

    var body: some View {
        Group {
            if self.preparedID == self.input.message.id {
                SuggestedActionsView(
                    message: Self.message(self.input.message),
                    previousMessages: self.input.previousMessages.map(Self.message))
            }
        }
        // Prefetch once the message is final so the row appears with its actions instead of popping in.
        .task(id: self.input.message.id) {
            await SuggestedActionsView.generate(
                message: Self.message(self.input.message),
                previousMessages: self.input.previousMessages.map(Self.message))
            guard !Task.isCancelled else { return }
            self.preparedID = self.input.message.id
        }
    }

    private static func message(_ entry: ChatSuggestedActionsInput.Entry) -> SuggestedActionsMessage {
        let you = SuggestedActionsMessage.Participant(name: "You", handle: "user", isUser: true)
        let sender = entry.isFromUser
            ? you
            : SuggestedActionsMessage.Participant(name: entry.senderName, handle: entry.senderName, isUser: false)
        return SuggestedActionsMessage(
            id: entry.id,
            date: entry.date,
            subject: nil,
            body: AttributedString(entry.body),
            sender: sender,
            recipients: entry.isFromUser ? [] : [you])
    }
}
#endif
#endif
