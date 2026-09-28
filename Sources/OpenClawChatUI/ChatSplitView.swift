// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
//
// Composable replacement for upstream OpenClaw 2026.9.6's macOS-only `ChatWindowShell`: a sessions sidebar plus the
// chat transcript in a NavigationSplitView. On macOS it composes the ported window shell; on iPadOS and visionOS it
// pairs `OpenClawChatSessionList` with the clean-chrome chat, and iPhone collapses to a stack. It has no window
// management or Quick Chat.
#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

/// Sessions sidebar plus chat detail for desktop, iPad and Vision Pro hosts.
///
/// The detail runs in the desktop layout (`openClawChatDesktopLayout`: 760 pt reading column on macOS, collapsed
/// completed work) with the clean composer, whose inline controls carry the model picker, effort (thinking and
/// fast mode) and execution permissions. The toolbar holds the thread actions and new-thread options.
@MainActor
public struct OpenClawChatSplitView: View {
    @State private var viewModel: OpenClawChatViewModel
    private let externalQuery: Binding<String>?
    private let additionalAttentionRequests: [OpenClawChatAttentionRequest]
    private let userAccent: Color?
    private let displayOptions: OpenClawChatDisplayOptions?
    private let preferences: OpenClawChatUIPreferences?
    private let emptyAssistantIntro: String?
    private let emptyAssistantPrompts: [OpenClawChatView.StarterPrompt]
    private let talkControl: OpenClawChatTalkControl?
    private let dictationControl: OpenClawChatDictationControl?
    private let voiceNoteControl: OpenClawChatVoiceNoteControl?
    private let speech: OpenClawChatSpeechController?
    private let mediaPlaybackAllowed: @MainActor @Sendable () -> Bool
    #if !os(macOS)
    @State private var localQuery = ""
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var isPresentingNewSessionOptions = false
    @State private var isRenamingSession = false
    @State private var isConfirmingClearHistory = false
    @State private var renameText = ""
    #endif

    /// Creates the split view.
    /// - Parameters:
    ///   - viewModel: The chat view model shared by the sidebar and the chat.
    ///   - sidebarQuery: Session search text; the view keeps its own when `nil`.
    ///   - additionalAttentionRequests: Host-supplied attention requests shown as sidebar badges.
    ///   - userAccent: User bubble and send button color.
    ///   - displayOptions: Transcript trace options (defaults to `preferences`, then no trace).
    ///   - preferences: Gateway `ui.prefs` display preferences.
    ///   - emptyAssistantIntro: Greeting shown in an empty chat.
    ///   - emptyAssistantPrompts: Starter prompts under the greeting.
    ///   - talkControl: Host-provided realtime Talk control.
    ///   - dictationControl: Host-provided dictation control.
    ///   - voiceNoteControl: Host-provided voice-note recorder.
    ///   - speech: Listen controller for assistant messages.
    ///   - mediaPlaybackAllowed: Host gate for media autoplay.
    public init(
        viewModel: OpenClawChatViewModel,
        sidebarQuery: Binding<String>? = nil,
        additionalAttentionRequests: [OpenClawChatAttentionRequest] = [],
        userAccent: Color? = nil,
        displayOptions: OpenClawChatDisplayOptions? = nil,
        preferences: OpenClawChatUIPreferences? = nil,
        emptyAssistantIntro: String? = nil,
        emptyAssistantPrompts: [OpenClawChatView.StarterPrompt] = [],
        talkControl: OpenClawChatTalkControl? = nil,
        dictationControl: OpenClawChatDictationControl? = nil,
        voiceNoteControl: OpenClawChatVoiceNoteControl? = nil,
        speech: OpenClawChatSpeechController? = nil,
        mediaPlaybackAllowed: @escaping @MainActor @Sendable () -> Bool = { true })
    {
        _viewModel = State(initialValue: viewModel)
        self.externalQuery = sidebarQuery
        self.additionalAttentionRequests = additionalAttentionRequests
        self.userAccent = userAccent
        self.displayOptions = displayOptions
        self.preferences = preferences
        self.emptyAssistantIntro = emptyAssistantIntro
        self.emptyAssistantPrompts = emptyAssistantPrompts
        self.talkControl = talkControl
        self.dictationControl = dictationControl
        self.voiceNoteControl = voiceNoteControl
        self.speech = speech
        self.mediaPlaybackAllowed = mediaPlaybackAllowed
    }

    /// The split view body.
    public var body: some View {
        #if os(macOS)
        OpenClawChatWindowShell(
            viewModel: self.viewModel,
            userAccent: self.userAccent,
            attentionRequests: self.additionalAttentionRequests,
            displayOptions: self.displayOptions,
            emptyAssistantIntro: self.emptyAssistantIntro,
            emptyAssistantPrompts: self.emptyAssistantPrompts,
            talkControl: self.talkControl,
            dictationControl: self.dictationControl,
            voiceNoteControl: self.voiceNoteControl,
            speech: self.speech,
            mediaPlaybackAllowed: self.mediaPlaybackAllowed,
            preferences: self.preferences,
            sessionQuery: self.externalQuery)
        #else
        NavigationSplitView(preferredCompactColumn: self.$preferredCompactColumn) {
            OpenClawChatSessionList(
                viewModel: self.viewModel,
                query: self.externalQuery ?? self.$localQuery,
                additionalAttentionRequests: self.additionalAttentionRequests,
                onSelect: { _ in self.preferredCompactColumn = .detail })
                .navigationTitle(String(localized: "Threads"))
        } detail: {
            OpenClawChatView(
                viewModel: self.viewModel,
                userAccent: self.userAccent,
                displayOptions: self.displayOptions,
                assistantName: self.viewModel.selectedAgent?.displayName,
                assistantAvatarText: self.viewModel.selectedAgent?.emoji,
                composerChrome: .clean,
                messagePlaceholder: self.viewModel.selectedAgent.map {
                    String(format: String(localized: "Message %@…"), $0.displayName)
                },
                emptyAssistantIntro: self.emptyAssistantIntro,
                emptyAssistantPrompts: self.emptyAssistantPrompts,
                talkControl: self.talkControl,
                dictationControl: self.dictationControl,
                voiceNoteControl: self.voiceNoteControl,
                speech: self.speech,
                mediaPlaybackAllowed: self.mediaPlaybackAllowed,
                preferences: self.preferences)
                .environment(\.openClawChatDesktopLayout, true)
                .navigationTitle(self.activeSessionTitle)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { self.detailToolbar }
        }
        .task { await self.viewModel.refreshAgents() }
        .sheet(isPresented: self.$isPresentingNewSessionOptions) {
            ChatNewSessionOptionsPopover(viewModel: self.viewModel) {
                self.isPresentingNewSessionOptions = false
            }
            .presentationDetents([.medium])
        }
        .alert(String(localized: "Rename Thread"), isPresented: self.$isRenamingSession) {
            TextField(String(localized: "Thread name"), text: self.$renameText)
            Button(String(localized: "Rename")) {
                let target = self.viewModel.currentSessionTarget
                self.viewModel.renameSession(key: target.sessionKey, label: self.renameText, agentID: target.agentID)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            String(localized: "Clear this thread's history?"),
            isPresented: self.$isConfirmingClearHistory)
        {
            Button(String(localized: "Clear History"), role: .destructive) {
                self.viewModel.requestSessionReset()
            }
        }
        .onChange(of: self.viewModel.pendingRunCount) { previous, current in
            // Run completion changes timestamps and token totals; pull them once per run instead of polling.
            if previous > 0, current == 0 {
                self.viewModel.refreshSessions(limit: OpenClawChatViewModel.sessionListFetchLimit)
            }
        }
        #endif
    }

    #if !os(macOS)
    private var activeSessionEntry: OpenClawChatSessionEntry? {
        self.viewModel.currentSessionEntry()
    }

    private var activeSessionTitle: String {
        if let entry = self.activeSessionEntry {
            return ChatSessionSidebarModel.displayName(for: entry)
        }
        return ChatSessionSidebarModel.displayName(forKey: self.viewModel.sessionKey)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    Task { await self.viewModel.startNewSession() }
                } label: {
                    Label(String(localized: "New Thread"), systemImage: "square.and.pencil")
                }
                .disabled(self.viewModel.isCreatingSession)
                Button {
                    self.isPresentingNewSessionOptions = true
                } label: {
                    Label(String(localized: "New Thread Options…"), systemImage: "slider.horizontal.3")
                }
                Divider()
                Button {
                    self.renameText = self.activeSessionEntry?.label ?? self.activeSessionTitle
                    self.isRenamingSession = true
                } label: {
                    Label(String(localized: "Rename Thread…"), systemImage: "pencil")
                }
                Button {
                    let target = self.viewModel.currentSessionTarget
                    Task { await self.viewModel.forkSession(key: target.sessionKey, agentID: target.agentID) }
                } label: {
                    Label(
                        self.activeSessionEntry?.hasActiveRun == true
                            ? String(localized: "Fork from last completed message")
                            : String(localized: "Fork"),
                        systemImage: "arrow.triangle.branch")
                }
                Button {
                    let target = self.viewModel.currentSessionTarget
                    self.viewModel.setSessionPinned(
                        key: self.activeSessionEntry?.key ?? target.sessionKey,
                        pinned: self.activeSessionEntry?.pinned != true,
                        agentID: target.agentID)
                } label: {
                    Label(
                        self.activeSessionEntry?.pinned == true ? String(localized: "Unpin") : String(localized: "Pin"),
                        systemImage: self.activeSessionEntry?.pinned == true ? "pin.slash" : "pin")
                }
                OpenClawSessionColorMenu(color: self.activeSessionEntry?.color) { color in
                    let target = self.viewModel.currentSessionTarget
                    Task {
                        await self.viewModel.setSessionColor(key: target.sessionKey, color: color, agentID: target.agentID)
                    }
                }
                Divider()
                Button {
                    self.viewModel.requestSessionCompact()
                } label: {
                    Label(String(localized: "Compact Thread"), systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .disabled(!self.viewModel.canRequestSessionCompact)
                Button(role: .destructive) {
                    self.isConfirmingClearHistory = true
                } label: {
                    Label(String(localized: "Clear History…"), systemImage: "trash")
                }
            } label: {
                Label(String(localized: "Thread"), systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("chat-thread-actions")
        }
    }
    #endif
}
#endif
