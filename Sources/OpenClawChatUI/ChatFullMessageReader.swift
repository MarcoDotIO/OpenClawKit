// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import Foundation
import OpenClawKit
import SwiftUI

// Ported from upstream OpenClaw 2026.9.6 `ChatFullMessageReader.swift` (reader view). The route-bound
// load request lives in ChatFullMessageReaderRequest.swift.
@MainActor
struct ChatFullMessageReader: View {
    private enum Phase {
        case loading
        case loaded(String)
        case failed(String)
    }

    let request: ChatFullMessageReaderRequest
    let markdownVariant: ChatMarkdownVariant

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading

    var body: some View {
        NavigationStack {
            Group {
                switch self.phase {
                case .loading:
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading full message…")
                            .font(OpenClawChatTypography.body)
                            .foregroundStyle(.secondary)
                    }
                case let .loaded(markdown):
                    ScrollView {
                        ChatMarkdownRenderer(
                            text: markdown,
                            context: .assistant,
                            variant: self.markdownVariant,
                            textColor: OpenClawChatTheme.assistantText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                case let .failed(message):
                    ContentUnavailableView(
                        String(localized: "Full message unavailable"),
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(message))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Full Message")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { self.dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
        .task(id: self.request.id) {
            await self.loadMessage()
        }
    }

    private func loadMessage() async {
        self.phase = .loading
        do {
            guard let message = try await self.request.load() else {
                self.phase = .failed(String(localized: "The full message is no longer available."))
                return
            }
            let markdown = ChatMessageVisibleText.visibleText(in: message)
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.phase = .failed(String(localized: "The full message has no readable text."))
                return
            }
            self.phase = .loaded(markdown)
        } catch is CancellationError {
            return
        } catch {
            self.phase = .failed(String(localized: "The full message could not be loaded."))
        }
    }
}
#endif
