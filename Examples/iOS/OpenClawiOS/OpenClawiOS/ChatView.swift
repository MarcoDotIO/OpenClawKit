import SwiftUI
import UniformTypeIdentifiers
import OpenClawProtocol
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Chat interface for interacting with the deployed agent instance.
struct ChatView: View {
    @EnvironmentObject private var appState: OpenClawAppState
    @FocusState private var composerFocused: Bool
    @State private var showingFileImporter = false
    #if canImport(PhotosUI)
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

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

                HStack {
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
                        .font(.subheadline)
                    }
                    .accessibilityIdentifier("skill-picker-menu")

                    Spacer()
                }
                .padding(.horizontal)

                if !appState.pendingAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(appState.pendingAttachments) { attachment in
                                HStack(spacing: 6) {
                                    Text("\(attachment.fileName) • \(attachment.byteCountLabel)")
                                        .font(.caption)
                                        .lineLimit(1)
                                    Button {
                                        appState.removePendingAttachment(id: attachment.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Image(systemName: "paperclip.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat-attach-file-button")
                    .disabled(!appState.isDeployed)

                    #if canImport(PhotosUI)
                    if #available(iOS 16.0, *) {
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Image(systemName: "photo.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat-attach-photo-button")
                        .disabled(!appState.isDeployed)
                    }
                    #endif

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
                    .disabled(
                        !appState.isDeployed ||
                            (
                                appState.pendingMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                    !appState.hasPendingAttachments
                            )
                    )
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Chat")
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let fileURL = urls.first else {
                    return
                }
                _ = appState.importAttachment(from: fileURL)
            }
            #if canImport(PhotosUI)
            .onChange(of: selectedPhotoItem) { _, selected in
                guard #available(iOS 16.0, *), let selected else {
                    return
                }
                Task {
                    defer { selectedPhotoItem = nil }
                    guard let data = try? await selected.loadTransferable(type: Data.self) else {
                        return
                    }
                    let mimeType = selected.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
                    let fallbackName = "photo-\(UUID().uuidString.prefix(8)).jpg"
                    _ = appState.stageAttachment(
                        data: data,
                        mimeType: mimeType,
                        fileName: fallbackName
                    )
                }
            }
            #endif
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
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role.rawValue.capitalized)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let attachments = message.attachments, !attachments.isEmpty {
                ForEach(attachments) { attachment in
                    if attachment.mimeType.hasPrefix("image/"), let uiImage = UIImage(data: attachment.data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        HStack {
                            Image(systemName: "doc.fill")
                            Text(attachment.fileName ?? "File")
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
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
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            }
        }
        .padding(Theme.bubblePadding)
        .background(color)
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
        .frame(maxWidth: Theme.bubbleMaxWidth, alignment: alignment)
    }
}

#Preview {
    ChatView()
        .environmentObject(OpenClawAppState())
}
