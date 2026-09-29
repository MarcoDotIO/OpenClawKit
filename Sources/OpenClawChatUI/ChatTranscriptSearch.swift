// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

// Ported from upstream OpenClaw 2026.9.6 `ChatTranscriptSearch.swift` (macOS find bar), plus a `.searchable`
// adaptation with the same call shape for iOS and visionOS.
struct ChatTranscriptSearchResults: Equatable {
    let messageIDs: [UUID]

    init(rows: [ChatTranscriptRow], query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.messageIDs = query.isEmpty ? [] : rows.compactMap { row in
            guard case let .message(message) = row,
                  ["user", "assistant"].contains(message.role.lowercased()),
                  ChatMessageVisibleText.visibleText(in: message).localizedStandardContains(query)
            else { return nil }
            return message.id
        }
    }

    func selection(after current: UUID?, backwards: Bool = false) -> UUID? {
        guard !self.messageIDs.isEmpty else { return nil }
        guard let current, let index = self.messageIDs.firstIndex(of: current) else {
            return backwards ? self.messageIDs.last : self.messageIDs.first
        }
        let offset = backwards ? self.messageIDs.count - 1 : 1
        return self.messageIDs[(index + offset) % self.messageIDs.count]
    }
}

#if os(macOS)
struct ChatTranscriptSearch: ViewModifier {
    let rows: [ChatTranscriptRow]
    let sessionKey: String
    let isEnabled: Bool
    @Binding var selectedMessageID: UUID?
    @Binding var isPresented: Bool
    let onSelect: (UUID) -> Void
    @State private var query = ""
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        let results = ChatTranscriptSearchResults(rows: self.rows, query: self.query)
        return content
            .safeAreaInset(edge: .top, spacing: 0) {
                if self.isPresented { self.searchBar(results: results) }
            }
            .toolbar {
                if self.isEnabled {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            self.isPresented = true
                            self.isFocused = true
                        } label: {
                            Label("Find in Conversation", systemImage: "magnifyingglass")
                        }
                        .keyboardShortcut("f", modifiers: .command)
                        .help("Find in conversation (⌘F)")
                    }
                }
            }
            .onChange(of: results) { _, results in
                guard self.isPresented else { return }
                if !results.messageIDs.contains(where: { $0 == self.selectedMessageID }) {
                    self.select(results.messageIDs.first)
                }
            }
            .onChange(of: self.sessionKey) { _, _ in self.close() }
            .onChange(of: self.isPresented) { _, isPresented in
                if !isPresented { self.close() }
            }
    }

    private func searchBar(results: ChatTranscriptSearchResults) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in loaded messages", text: self.$query)
                .textFieldStyle(.plain)
                .focused(self.$isFocused)
                .onAppear { self.isFocused = true }
                .onSubmit { self.selectNext(in: results) }
                .onExitCommand { self.close() }
                .accessibilityIdentifier("chat-transcript-search")

            Text(self.resultLabel(results: results))
                .font(OpenClawChatTypography.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()

            Button {
                self.selectNext(in: results, backwards: true)
            } label: {
                Label("Previous Match", systemImage: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(results.messageIDs.isEmpty)
            .help("Previous match (⇧⌘G)")

            Button {
                self.selectNext(in: results)
            } label: {
                Label("Next Match", systemImage: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(results.messageIDs.isEmpty)
            .help("Next match (⌘G)")

            Button(action: self.close) {
                Label("Close Find", systemImage: "xmark")
            }
            .help("Close find (Escape)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func resultLabel(results: ChatTranscriptSearchResults) -> String {
        if self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        guard let selectedMessageID,
              let index = results.messageIDs.firstIndex(of: selectedMessageID)
        else { return String(localized: "No matches") }
        return String(
            format: String(localized: "%lld of %lld"),
            Int64(index + 1),
            Int64(results.messageIDs.count))
    }

    private func selectNext(in results: ChatTranscriptSearchResults, backwards: Bool = false) {
        self.select(results.selection(after: self.selectedMessageID, backwards: backwards))
    }

    private func select(_ messageID: UUID?) {
        self.selectedMessageID = messageID
        if let messageID { self.onSelect(messageID) }
    }

    private func close() {
        self.isPresented = false
        self.query = ""
        self.selectedMessageID = nil
    }
}
#else
/// iOS and visionOS adaptation of upstream's macOS find bar: the system search field (`.searchable`)
/// with Return and toolbar buttons stepping through matches. Same call shape as the macOS modifier.
struct ChatTranscriptSearch: ViewModifier {
    let rows: [ChatTranscriptRow]
    let sessionKey: String
    let isEnabled: Bool
    @Binding var selectedMessageID: UUID?
    @Binding var isPresented: Bool
    let onSelect: (UUID) -> Void
    @State private var query = ""

    func body(content: Content) -> some View {
        let results = ChatTranscriptSearchResults(rows: self.rows, query: self.query)
        if self.isEnabled {
            content
                .searchable(
                    text: self.$query,
                    isPresented: self.$isPresented,
                    prompt: Text("Find in loaded messages"))
                .modifier(ChatTranscriptSearchToolbarBehavior())
                .onSubmit(of: .search) { self.selectNext(in: results) }
                .toolbar {
                    if self.isPresented, !self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ToolbarItemGroup(placement: .bottomBar) {
                            Text(self.resultLabel(results: results))
                                .font(OpenClawChatTypography.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Spacer()
                            Button {
                                self.selectNext(in: results, backwards: true)
                            } label: {
                                Label("Previous Match", systemImage: "chevron.up")
                            }
                            .disabled(results.messageIDs.isEmpty)
                            Button {
                                self.selectNext(in: results)
                            } label: {
                                Label("Next Match", systemImage: "chevron.down")
                            }
                            .disabled(results.messageIDs.isEmpty)
                        }
                    }
                }
                .onChange(of: results) { _, results in
                    guard self.isPresented else { return }
                    if !results.messageIDs.contains(where: { $0 == self.selectedMessageID }) {
                        self.select(results.messageIDs.first)
                    }
                }
                .onChange(of: self.sessionKey) { _, _ in self.close() }
                .onChange(of: self.isPresented) { _, isPresented in
                    if !isPresented { self.close() }
                }
        } else {
            content
        }
    }

    private func resultLabel(results: ChatTranscriptSearchResults) -> String {
        guard let selectedMessageID,
              let index = results.messageIDs.firstIndex(of: selectedMessageID)
        else { return String(localized: "No matches") }
        return String(
            format: String(localized: "%lld of %lld"),
            Int64(index + 1),
            Int64(results.messageIDs.count))
    }

    private func selectNext(in results: ChatTranscriptSearchResults, backwards: Bool = false) {
        self.select(results.selection(after: self.selectedMessageID, backwards: backwards))
    }

    private func select(_ messageID: UUID?) {
        self.selectedMessageID = messageID
        if let messageID { self.onSelect(messageID) }
    }

    private func close() {
        self.isPresented = false
        self.query = ""
        self.selectedMessageID = nil
    }
}

/// Keeps the transcript visible while searching (iOS 17.1+).
private struct ChatTranscriptSearchToolbarBehavior: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.1, visionOS 1.0, *) {
            content.searchPresentationToolbarBehavior(.avoidHidingContent)
        } else {
            content
        }
    }
}
#endif
#endif
