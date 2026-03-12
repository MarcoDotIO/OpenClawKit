import SwiftUI
import OpenClawProtocol

/// Chat interface for interacting with the deployed agent instance.
struct ChatView: View {
    @EnvironmentObject private var appState: OpenClawAppState
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if !appState.isDeployed {
                    Text("Deploy the agent from the Deploy tab to enable chat.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(appState.messages) { message in
                                ChatBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, 40)
                        .padding(.vertical, 20)
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .onChange(of: appState.messages.count) { _, _ in
                        guard let lastID = appState.messages.last?.id else { return }
                        withAnimation {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }

                if !appState.latestSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Latest Summary")
                            .font(.headline)
                        Text(appState.latestSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }

                HStack(spacing: 14) {
                    Menu {
                        Button("Automatic") {
                            appState.selectedSkillName = ""
                        }
                        if !appState.selectableSkillItems.isEmpty {
                            Divider()
                        }
                        ForEach(appState.selectableSkillItems) { skill in
                            Button(skill.name) {
                                appState.selectedSkillName = skill.name
                            }
                        }
                    } label: {
                        Label(
                            appState.selectedSkillName.isEmpty ? "Skill: Automatic" : "Skill: \(appState.selectedSkillName)",
                            systemImage: "wand.and.stars"
                        )
                        .font(.headline)
                    }
                    .accessibilityIdentifier("skill-picker-menu")

                    TextField("Type a message...", text: $appState.pendingMessage)
                        .textFieldStyle(.automatic)
                        .focused($composerFocused)
                        .disabled(!appState.isDeployed)
                        .onSubmit {
                            Task {
                                await appState.sendPendingMessage()
                            }
                        }

                    Button("Send") {
                        Task {
                            await appState.sendPendingMessage()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !appState.isDeployed ||
                            appState.pendingMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .navigationTitle("Chat")
        }
    }
}

/// tvOS-optimized bubble used by the sample chat timeline.
private struct ChatBubble: View {
    let message: OpenClawAppState.ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble(color: Theme.assistantBubbleColor, alignment: .leading)
                Spacer(minLength: Theme.bubbleSpacing)
            } else if message.role == .user {
                Spacer(minLength: Theme.bubbleSpacing)
                bubble(color: Theme.userBubbleColor, alignment: .trailing)
            } else {
                Spacer(minLength: Theme.bubbleSpacing)
                bubble(color: Theme.systemBubbleColor, alignment: .leading)
                Spacer(minLength: Theme.bubbleSpacing)
            }
        }
    }

    @ViewBuilder
    private func bubble(color: Color, alignment: Alignment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.role.rawValue.capitalized)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            
            if let attachments = message.attachments, !attachments.isEmpty {
                ForEach(attachments) { attachment in
                    if attachment.mimeType.hasPrefix("image/"), let uiImage = UIImage(data: attachment.data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 400)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        HStack {
                            Image(systemName: "doc.fill")
                            Text(attachment.fileName ?? "File")
                                .font(.callout)
                                .lineLimit(1)
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            if !message.text.isEmpty {
                Group {
                    if let attr = try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .full)) {
                        Text(attr)
                    } else {
                        Text(message.text)
                    }
                }
                .font(.title3)
                .foregroundStyle(.primary)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            }
        }
        .padding(Theme.bubblePadding)
        .background(color)
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
        .frame(maxWidth: Theme.bubbleMaxWidth, alignment: alignment)
        .focusable(true)
    }
}

#Preview {
    ChatView()
        .environmentObject(OpenClawAppState())
}
