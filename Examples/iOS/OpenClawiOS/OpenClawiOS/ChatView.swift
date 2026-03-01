import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Chat interface for interacting with the deployed agent instance.
struct ChatView: View {
    @EnvironmentObject private var appState: OpenClawAppState
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if !appState.isDeployed {
                    Text("Deploy the agent from the Deploy tab to enable chat.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(appState.messages) { message in
                                ChatBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: appState.messages.count) { _, _ in
                        guard let lastID = appState.messages.last?.id else { return }
                        withAnimation {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }

                if !appState.latestSummary.isEmpty {
                    Text("Latest summary:\n\(appState.latestSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                HStack(spacing: 8) {
                    TextField("Send a message...", text: $appState.pendingMessage, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($composerFocused)
                        .disabled(!appState.isDeployed)

                    Button("Send") {
                        Task {
                            await appState.sendPendingMessage()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.isDeployed || appState.pendingMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        self.composerFocused = false
                        self.dismissKeyboard()
                    }
                }
            }
        }
    }

    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

/// iMessage-style bubble used by the sample chat timeline.
private struct ChatBubble: View {
    let message: OpenClawAppState.ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble(color: .blue.opacity(0.14), alignment: .leading)
                Spacer(minLength: 24)
            } else if message.role == .user {
                Spacer(minLength: 24)
                bubble(color: .green.opacity(0.14), alignment: .trailing)
            } else {
                Spacer(minLength: 24)
                bubble(color: .orange.opacity(0.14), alignment: .leading)
                Spacer(minLength: 24)
            }
        }
    }

    @ViewBuilder
    private func bubble(color: Color, alignment: Alignment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role.rawValue.capitalized)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(message.text)
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
        }
        .padding(10)
        .background(color)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 280, alignment: alignment)
    }
}

#Preview {
    ChatView()
        .environmentObject(OpenClawAppState())
}
