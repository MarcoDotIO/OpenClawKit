import Foundation

// Ported from upstream OpenClaw 2026.9.6 `ChatView.swift`. Adaptations: iOS 17 / macOS 14 fallbacks for the
// iOS 18 scroll-phase and scroll-geometry observers, host display preferences (`OpenClawChatUIPreferences`),
// and platform guards (the view ships on iOS, macOS and visionOS only).

/// Which assistant trace content the transcript shows.
public struct OpenClawChatDisplayOptions: OptionSet, Sendable, Hashable {
    /// Raw option bits.
    public let rawValue: UInt8

    /// Creates options from raw bits.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Show assistant reasoning (thinking) blocks.
    public static let reasoning = Self(rawValue: 1 << 0)
    /// Show tool calls, tool results and live subagent activity.
    public static let toolActivity = Self(rawValue: 1 << 1)
    /// Reasoning plus tool activity.
    public static let assistantTrace: Self = [.reasoning, .toolActivity]

    /// ``assistantTrace`` when `isVisible`, otherwise no trace.
    public static func assistantTrace(_ isVisible: Bool) -> Self {
        isVisible ? .assistantTrace : []
    }
}

enum ChatReaderUserTransition: Equatable {
    case unchanged
    case added(UUID)
    case removed(latestRemainingID: UUID?)
}

enum ChatReaderInitialRestorePolicy: Equatable {
    case liveEdge
    case latestTurn
}

/// Platform-neutral mirror of SwiftUI `ScrollPhase` (iOS 18 / macOS 15), so the follow policy is testable and
/// the iOS 17 / macOS 14 fallback can feed the same state machine.
enum ChatReaderScrollPhase: Equatable {
    case idle
    case tracking
    case interacting
    case decelerating
    case animating
}

func chatReaderInitialRestorePolicy() -> ChatReaderInitialRestorePolicy {
    #if os(iOS)
    .liveEdge
    #else
    .latestTurn
    #endif
}

func chatReaderUserTransition(
    previousID: UUID?,
    visibleIDs: [UUID]) -> ChatReaderUserTransition
{
    let latestID = visibleIDs.last
    if let previousID, !visibleIDs.contains(previousID) {
        return .removed(latestRemainingID: latestID)
    }
    if let latestID, latestID != previousID {
        return .added(latestID)
    }
    return .unchanged
}

func chatReaderHasNewerContent(
    after messageID: UUID,
    visibleIDs: [UUID],
    hasTransientContent: Bool) -> Bool
{
    guard let messageIndex = visibleIDs.firstIndex(of: messageID) else { return false }
    return messageIndex < visibleIDs.index(before: visibleIDs.endIndex) || hasTransientContent
}

/// `hasNewerContentBelow` is derived structurally (a later message or streaming text exists),
/// which is true from the first Writing tick of a turn even when the whole transcript is on
/// screen. Gating on the live-edge geometry keeps the jump affordance hidden until content is
/// actually below the viewport; without it the button flashes during every reply (#108693).
func chatReaderShowsJumpToLatest(
    hasNewerContentBelow: Bool,
    isAtLiveEdge: Bool,
    hasVisibleContent: Bool,
    isLoading: Bool) -> Bool
{
    hasNewerContentBelow && !isAtLiveEdge && hasVisibleContent && !isLoading
}

/// The view's own one-shot positioning always runs in a nil-animation transaction, so
/// `.animating` only comes from system scrolls (status-bar scroll-to-top, keyboard
/// avoidance). Not releasing there lets the next timeline tick yank the reader back down.
func chatReaderScrollReleasesFollow(_ phase: ChatReaderScrollPhase) -> Bool {
    switch phase {
    case .interacting, .animating:
        true
    case .idle, .tracking, .decelerating:
        false
    }
}

// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

private enum ScrollFollowTarget: Equatable {
    case latest
    case turn(UUID)
}

private struct ChatTurnRecapObservation: Equatable {
    let sessionKey: String
    let indicatorVisible: Bool
    let row: ChatTurnRecapSessionRow?
}

/// The chat surface: transcript, working indicators, progress card and composer.
@MainActor
public struct OpenClawChatView: View {
    /// Visual style of the transcript and composer.
    public enum Style {
        /// Full chat chrome.
        case standard
        /// Reduced chrome for onboarding flows (hides the first user message and attachments).
        case onboarding
    }

    /// Composer chrome.
    public enum ComposerChrome {
        /// Toolbar with pickers above a bordered editor.
        case full
        /// Single rounded surface with inline controls (iOS 26 glass, desktop layout on macOS).
        case clean
    }

    /// A tappable starter prompt shown under the empty-state intro (clean chrome).
    public struct StarterPrompt: Hashable, Identifiable, Sendable {
        /// Stable identifier (used in the accessibility identifier).
        public let id: String
        /// Button title.
        public let title: String
        /// Prompt sent when tapped.
        public let prompt: String

        /// Creates a starter prompt.
        public init(id: String, title: String, prompt: String) {
            self.id = id
            self.title = title
            self.prompt = prompt
        }
    }

    @State private var viewModel: OpenClawChatViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openClawChatDesktopLayout) private var isDesktopLayout
    @State private var scrollerBottomID = UUID()
    @State private var scrollPosition: UUID?
    @State private var hasPerformedInitialScroll = false
    @State private var lastTurnStartID: UUID?
    @State private var hasNewerContentBelow = false
    @State private var followTarget: ScrollFollowTarget? = .latest
    @State private var isAtLiveEdge = true
    @State private var isUserScrolling = false
    @State private var isKeyboardVisible = false
    @State private var hoveredMessageID: UUID?
    @State private var restoresLiveEdgeAfterKeyboardShows = false
    @State private var expandedUserMessageIDs: Set<UUID> = []
    @State private var searchMessageID: UUID?
    @State private var isSearchPresented = false
    @State private var composerFocusRequest = 0
    @State private var fullMessageRequest: ChatFullMessageReaderRequest?
    #if os(iOS)
    @State private var selectTextMessage: OpenClawChatMessage?
    #endif
    @State private var turnRecapResolver = ChatTurnRecapResolver()
    @State private var turnRecap: ChatTurnRecap?
    @State private var turnRecapSessionKey: String?
    private let showsSessionSwitcher: Bool
    private let drawsBackground: Bool
    private let style: Style
    private let markdownVariant: ChatMarkdownVariant
    private let userAccent: Color?
    private let displayOptions: OpenClawChatDisplayOptions
    private let assistantName: String?
    private let assistantAvatarText: String?
    private let assistantAvatarTint: Color?
    private let showsAssistantAvatars: Bool
    private let composerChrome: ComposerChrome
    private let showsComposer: Bool
    private let isComposerEnabled: Bool
    private let isAttachmentInputEnabled: Bool
    private let messagePlaceholder: String?
    private let emptyAssistantIntro: String?
    private let emptyAssistantPrompts: [StarterPrompt]
    private let talkControl: OpenClawChatTalkControl?
    private let dictationControl: OpenClawChatDictationControl?
    private let voiceNoteControl: OpenClawChatVoiceNoteControl?
    private let speech: OpenClawChatSpeechController?
    private let mediaPlaybackAllowed: @MainActor @Sendable () -> Bool
    private let preferences: OpenClawChatUIPreferences?

    private enum Layout {
        #if os(macOS)
        static let outerPaddingHorizontal: CGFloat = 6
        static let outerPaddingVertical: CGFloat = 0
        static let composerPaddingHorizontal: CGFloat = 0
        static let swarmPaddingHorizontal: CGFloat = 12
        static let swarmPaddingVertical: CGFloat = 8
        static let stackSpacing: CGFloat = 0
        static let messageSpacing: CGFloat = 6
        static let messageListPaddingTop: CGFloat = 12
        static let messageListPaddingBottom: CGFloat = 16
        static let messageListPaddingHorizontal: CGFloat = 6
        static let newTurnAnchor = UnitPoint(x: 0.5, y: 0.18)
        static let liveEdgeThreshold: CGFloat = 48
        #else
        static let outerPaddingHorizontal: CGFloat = 6
        static let outerPaddingVertical: CGFloat = 6
        static let composerPaddingHorizontal: CGFloat = 6
        static let swarmPaddingHorizontal: CGFloat = 6
        static let swarmPaddingVertical: CGFloat = 0
        static let stackSpacing: CGFloat = 6
        static let messageSpacing: CGFloat = 12
        static let messageListPaddingTop: CGFloat = 10
        static let messageListPaddingBottom: CGFloat = 6
        static let messageListPaddingHorizontal: CGFloat = 8
        static let newTurnAnchor = UnitPoint(x: 0.5, y: 0.18)
        static let liveEdgeThreshold: CGFloat = 48
        #endif
    }

    private var readingColumnWidth: CGFloat {
        #if os(macOS)
        self.isDesktopLayout ? 760 : .infinity
        #else
        .infinity
        #endif
    }

    private var collapsesCompletedWork: Bool {
        #if os(iOS)
        true
        #else
        self.isDesktopLayout
        #endif
    }

    /// Creates the chat view.
    ///
    /// Every parameter except `viewModel` has a default, so existing call sites keep compiling.
    /// `showsAssistantTrace` remains as a source-compatible convenience that sets both display options.
    ///
    /// - Parameters:
    ///   - viewModel: The chat view model.
    ///   - drawsBackground: Whether the standard style paints the chat background.
    ///   - showsSessionSwitcher: Whether the full-chrome composer shows the session and settings pickers.
    ///   - style: Standard or onboarding style.
    ///   - markdownVariant: Markdown rendering density.
    ///   - userAccent: User bubble and send button color (defaults to the preferences accent, then the theme).
    ///   - displayOptions: Trace content to show; wins over `preferences` and `showsAssistantTrace`.
    ///   - showsAssistantTrace: Legacy switch for both reasoning and tool activity.
    ///   - assistantName: Assistant display name (avatars, reply labels).
    ///   - assistantAvatarText: Avatar text or emoji.
    ///   - assistantAvatarTint: Avatar tint.
    ///   - showsAssistantAvatars: Whether assistant rows show an avatar.
    ///   - composerChrome: Full or clean composer chrome.
    ///   - showsComposer: Whether the composer is shown (read-only transcripts hide it).
    ///   - isComposerEnabled: Whether typing and sending are allowed.
    ///   - isAttachmentInputEnabled: Whether attachments can be added (defaults to `isComposerEnabled`).
    ///   - messagePlaceholder: Composer placeholder (defaults to "Message…").
    ///   - emptyAssistantIntro: Greeting shown as the first assistant bubble in an empty clean-chrome chat.
    ///   - emptyAssistantPrompts: Starter prompts under the intro.
    ///   - talkControl: Host-provided realtime Talk control.
    ///   - dictationControl: Host-provided dictation control.
    ///   - voiceNoteControl: Host-provided voice-note recorder.
    ///   - speech: Listen (text-to-speech) controller for assistant messages.
    ///   - mediaPlaybackAllowed: Host gate that can block media autoplay (for example during Talk).
    ///   - preferences: Gateway `ui.prefs` display preferences (thinking/tool visibility, send shortcut,
    ///     theme mode and accent).
    public init(
        viewModel: OpenClawChatViewModel,
        drawsBackground: Bool = true,
        showsSessionSwitcher: Bool = false,
        style: Style = .standard,
        markdownVariant: ChatMarkdownVariant = .standard,
        userAccent: Color? = nil,
        displayOptions: OpenClawChatDisplayOptions? = nil,
        showsAssistantTrace: Bool = false,
        assistantName: String? = nil,
        assistantAvatarText: String? = nil,
        assistantAvatarTint: Color? = nil,
        showsAssistantAvatars: Bool = true,
        composerChrome: ComposerChrome = .full,
        showsComposer: Bool = true,
        isComposerEnabled: Bool = true,
        isAttachmentInputEnabled: Bool? = nil,
        messagePlaceholder: String? = nil,
        emptyAssistantIntro: String? = nil,
        emptyAssistantPrompts: [StarterPrompt] = [],
        talkControl: OpenClawChatTalkControl? = nil,
        dictationControl: OpenClawChatDictationControl? = nil,
        voiceNoteControl: OpenClawChatVoiceNoteControl? = nil,
        speech: OpenClawChatSpeechController? = nil,
        mediaPlaybackAllowed: @escaping @MainActor @Sendable () -> Bool = { true },
        preferences: OpenClawChatUIPreferences? = nil)
    {
        _viewModel = State(initialValue: viewModel)
        self.drawsBackground = drawsBackground
        self.showsSessionSwitcher = showsSessionSwitcher
        self.style = style
        self.markdownVariant = markdownVariant
        self.userAccent = userAccent ?? preferences?.accentColor
        self.displayOptions = displayOptions
            ?? preferences?.displayOptions(fallback: .assistantTrace(showsAssistantTrace))
            ?? .assistantTrace(showsAssistantTrace)
        self.assistantName = assistantName
        self.assistantAvatarText = assistantAvatarText
        self.assistantAvatarTint = assistantAvatarTint
        self.showsAssistantAvatars = showsAssistantAvatars
        self.composerChrome = composerChrome
        self.showsComposer = showsComposer
        self.isComposerEnabled = isComposerEnabled
        self.isAttachmentInputEnabled = isAttachmentInputEnabled ?? isComposerEnabled
        self.messagePlaceholder = messagePlaceholder
        self.emptyAssistantIntro = emptyAssistantIntro
        self.emptyAssistantPrompts = emptyAssistantPrompts
        self.talkControl = talkControl
        self.dictationControl = dictationControl
        self.voiceNoteControl = voiceNoteControl
        self.speech = speech
        self.mediaPlaybackAllowed = mediaPlaybackAllowed
        self.preferences = preferences
    }

    /// The chat view body.
    public var body: some View {
        ZStack {
            if self.drawsBackground, self.style == .standard {
                OpenClawChatTheme.background
                    .ignoresSafeArea()
            }

            self.content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(ChatPreferredColorSchemeModifier(colorScheme: self.preferences?.colorScheme))
        .onAppear {
            self.viewModel.refreshSourceContext()
            self.viewModel.load()
        }
        .onChange(of: self.turnRecapObservation, initial: true) { _, observation in
            self.updateTurnRecap(observation)
        }
        .sheet(item: self.$fullMessageRequest) { request in
            ChatFullMessageReader(
                request: request,
                markdownVariant: self.markdownVariant)
        }
        #if os(iOS)
        .sheet(item: self.$selectTextMessage) {
            ChatSelectableTextSheet(text: ChatMessageVisibleText.copyText(in: $0))
        }
        #endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            self.messageList
            #if os(macOS)
                .modifier(ChatTranscriptSearch(
                    rows: self.transcriptRows,
                    sessionKey: self.viewModel.sessionKey,
                    isEnabled: self.isDesktopLayout && self.showsComposer,
                    selectedMessageID: self.$searchMessageID,
                    isPresented: self.$isSearchPresented,
                    onSelect: self.revealSearchMessage))
                .onChange(of: self.isSearchPresented) { wasPresented, isPresented in
                    if wasPresented, !isPresented { self.composerFocusRequest += 1 }
                }
            #endif
                .padding(.horizontal, Layout.outerPaddingHorizontal)
            if !self.usesInlineProgressCard {
                self.progressCard
                    .frame(maxWidth: self.readingColumnWidth)
                    .padding(.horizontal, Layout.composerPaddingHorizontal)
                    .padding(.top, Layout.stackSpacing)
            }
            if self.showsComposer {
                self.turnRecapRow
                    .frame(maxWidth: self.readingColumnWidth)
            }
            self.swarmProgress
                .frame(maxWidth: self.readingColumnWidth)
                .padding(.horizontal, Layout.swarmPaddingHorizontal)
                .padding(.vertical, Layout.swarmPaddingVertical)
                .padding(.top, Layout.stackSpacing)
            if self.showsComposer {
                self.composer
                    .frame(maxWidth: self.readingColumnWidth)
                    .padding(.horizontal, self.isDesktopLayout ? 16 : Layout.composerPaddingHorizontal)
                    .padding(.top, Layout.stackSpacing)
                    .padding(.bottom, self.isDesktopLayout ? 12 : Layout.outerPaddingVertical)
            }
        }
        .padding(.top, Layout.outerPaddingVertical)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var progressCard: some View {
        if let progressCard = self.viewModel.progressCard {
            ChatProgressCard(
                steps: progressCard.steps ?? [],
                markdown: progressCard.markdown,
                isInline: self.usesInlineProgressCard)
        }
    }

    private var usesInlineProgressCard: Bool {
        guard !self.showsComposer else { return false }
        if let steps = self.viewModel.progressCard?.steps, !steps.isEmpty {
            return steps.allSatisfy { $0.status == .completed }
        }
        return !self.viewModel.hasBlockingRunActivity
    }

    @ViewBuilder
    private var swarmProgress: some View {
        let groups = self.viewModel.activeSwarmGroups
        if !groups.isEmpty {
            OpenClawChatSwarmProgressView(groups: groups)
        }
    }

    private var composer: some View {
        OpenClawChatComposer(
            viewModel: self.viewModel,
            style: self.style,
            showsSessionSwitcher: self.showsSessionSwitcher,
            userAccent: self.userAccent,
            assistantName: self.assistantName,
            assistantAvatarText: self.assistantAvatarText,
            assistantAvatarTint: self.assistantAvatarTint,
            composerChrome: self.composerChrome,
            isComposerEnabled: self.isComposerEnabled
                && !self.viewModel.isSendingAttachmentDraft,
            isAttachmentInputEnabled: self.isAttachmentInputEnabled
                && !self.viewModel.isSendingAttachmentDraft,
            messagePlaceholder: self.messagePlaceholder,
            talkControl: self.talkControl,
            dictationControl: self.dictationControl,
            voiceNoteControl: self.voiceNoteControl,
            focusRequest: self.composerFocusRequest,
            sendRequiresModifier: self.preferences?.sendRequiresModifier ?? false)
    }

    @ViewBuilder
    private var turnRecapRow: some View {
        if !self.showsWorkingIndicator,
           self.turnRecapSessionKey == self.viewModel.sessionKey,
           let turnRecap
        {
            ChatTurnRecapRow(recap: turnRecap)
                .padding(.horizontal, Layout.outerPaddingHorizontal + Layout.messageListPaddingHorizontal)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var messageList: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: self.isDesktopLayout ? 16 : Layout.messageSpacing) {
                    self.messageListRows

                    if self.usesInlineProgressCard {
                        self.progressCard
                    }
                    if !self.showsComposer, !self.viewModel.hasBlockingRunActivity {
                        self.turnRecapRow
                    }

                    Color.clear
                    #if os(macOS)
                        .frame(height: Layout.messageListPaddingBottom)
                    #else
                        .frame(height: Layout.messageListPaddingBottom + 1)
                    #endif
                        .id(self.scrollerBottomID)
                        .modifier(ChatReaderLiveEdgeSentinel(onVisibilityChange: self.handleLegacyLiveEdge))
                }
                // Use scroll targets for stable auto-scroll without ScrollViewReader relayout glitches.
                .scrollTargetLayout()
                .padding(.top, self.isDesktopLayout ? 24 : Layout.messageListPaddingTop)
                .frame(maxWidth: self.readingColumnWidth)
                .padding(.horizontal, self.isDesktopLayout ? 16 : Layout.messageListPaddingHorizontal)
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .safeAreaInset(edge: .top, spacing: 0) {
                self.messageListNoticeBanner
            }
            .scrollPosition(id: self.$scrollPosition, anchor: .bottom)
            .modifier(ChatReaderScrollObservation(
                liveEdgeThreshold: Layout.liveEdgeThreshold,
                onLiveEdgeChange: self.handleLiveEdgeChange,
                onPhaseChange: self.handleScrollPhase))

            if self.viewModel.isLoading, self.composerChrome == .full {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            self.messageListOverlay

            if self.showsJumpToLatest {
                self.jumpToLatestButton
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Ensure the message list claims vertical space on the first layout pass.
        .frame(maxHeight: .infinity, alignment: .top)
        .layoutPriority(1)
        .simultaneousGesture(
            TapGesture().onEnded {
                self.dismissKeyboardIfNeeded()
            })
        .onChange(of: self.viewModel.isLoading) { _, isLoading in
            guard !isLoading, !self.hasPerformedInitialScroll else { return }
            self.restoreInitialScrollPosition()
            self.hasPerformedInitialScroll = true
            self.lastTurnStartID = self.latestVisibleTurnStartID
        }
        .onChange(of: self.viewModel.currentSessionTarget) { _, _ in
            self.speech?.stop()
            self.hasPerformedInitialScroll = false
            self.followTarget = .latest
            self.isAtLiveEdge = true
            self.isUserScrolling = false
            self.hasNewerContentBelow = false
            self.lastTurnStartID = nil
        }
        .onChange(of: self.scenePhase) { _, newValue in
            if newValue == .background {
                self.speech?.stop()
            }
            guard newValue == .active else { return }
            self.viewModel.resumeFromForeground()
        }
        .onDisappear {
            self.speech?.stop()
        }
        .onChange(of: self.viewModel.timelineRevision) { _, _ in
            self.handleTimelineChange()
        }
        #if canImport(UIKit) && !os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            self.restoresLiveEdgeAfterKeyboardShows =
                self.followTarget == .latest && !self.isUserScrolling && self.searchMessageID == nil
            self.isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            guard self.restoresLiveEdgeAfterKeyboardShows else { return }
            self.restoresLiveEdgeAfterKeyboardShows = false
            guard self.searchMessageID == nil else { return }
            self.isUserScrolling = false
            self.followTarget = .latest
            self.hasNewerContentBelow = false
            self.moveScrollPosition(to: self.scrollerBottomID)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            self.restoresLiveEdgeAfterKeyboardShows = false
            self.isKeyboardVisible = false
        }
        #endif
    }

    private func handleLiveEdgeChange(_ isAtLiveEdge: Bool) {
        self.isAtLiveEdge = isAtLiveEdge
        guard self.hasPerformedInitialScroll else { return }
        if isAtLiveEdge, !self.isUserScrolling, !self.isFollowingTurn, self.searchMessageID == nil {
            self.followTarget = .latest
            self.hasNewerContentBelow = false
        }
    }

    /// iOS 17 / macOS 14 have no scroll-geometry observer; the bottom sentinel's visibility stands in for the
    /// live-edge distance check there. Newer systems ignore it and use the geometry observer.
    private func handleLegacyLiveEdge(_ isVisible: Bool) {
        if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) { return }
        self.handleLiveEdgeChange(isVisible)
    }

    private func handleScrollPhase(_ phase: ChatReaderScrollPhase) {
        guard self.hasPerformedInitialScroll else { return }
        if phase == .interacting {
            self.restoresLiveEdgeAfterKeyboardShows = false
        }
        if chatReaderScrollReleasesFollow(phase) {
            self.isUserScrolling = true
            self.followTarget = nil
        } else if phase == .idle, self.isUserScrolling {
            self.isUserScrolling = false
            if self.isAtLiveEdge {
                self.followTarget = .latest
                self.hasNewerContentBelow = false
            } else {
                self.hasNewerContentBelow = true
            }
        }
    }

    @ViewBuilder
    private var messageListRows: some View {
        let contextWindowTokens = self.viewModel.contextUsage?.contextWindowTokens

        if let introText = visibleEmptyAssistantIntro {
            ChatAssistantIntroCard(
                text: introText,
                prompts: self.emptyAssistantPrompts,
                onPrompt: { prompt in
                    self.viewModel.input = prompt.prompt
                    self.viewModel.send()
                })
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if self.showsCleanLoadingPlaceholder {
            ChatLoadingBubble()
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        ForEach(self.transcriptRows) { row in
            switch row {
            case let .message(message):
                self.messageRow(for: message, contextWindowTokens: contextWindowTokens)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(OpenClawChatTheme.accent.opacity(self.searchMessageID == message.id ? 0.08 : 0)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                OpenClawChatTheme.accent.opacity(self.searchMessageID == message.id ? 0.55 : 0),
                                lineWidth: 1))
            case let .systemNotice(notice):
                ChatSystemNoticeRow(notice: notice)
                    .frame(maxWidth: .infinity)
            case let .historyDivider(divider):
                ChatHistoryDividerRow(divider: divider)
                    .frame(maxWidth: .infinity)
            case let .completedWork(work):
                ChatCompletedWorkDisclosure(work: work) { message in
                    self.messageRow(for: message, contextWindowTokens: contextWindowTokens)
                }
            }
        }

        OpenClawQuestionCards(viewModel: self.viewModel)

        if self.showsWorkingIndicator {
            ChatTypingIndicatorBubble(
                style: self.style,
                assistantName: self.assistantName,
                assistantAvatarText: self.assistantAvatarText,
                assistantAvatarTint: self.assistantAvatarTint,
                showsAssistantAvatar: self.showsAssistantAvatars,
                isClean: self.composerChrome == .clean,
                runIdentity: self.viewModel.workingIndicatorIdentity,
                outputTokens: self.viewModel.liveRunOutputTokens)
                .equatable()
        }

        if self.displayOptions.contains(.toolActivity), !self.viewModel.subagentActivities.isEmpty {
            ChatSubagentActivityList(
                activities: self.viewModel.subagentActivities,
                hiddenWorkingCount: self.viewModel.hiddenWorkingSubagentCount)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if self.displayOptions.contains(.toolActivity), !self.viewModel.toolActivities.isEmpty {
            ChatPendingToolsBubble(toolCalls: self.viewModel.toolActivities)
                .equatable()
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let text = viewModel.streamingAssistantText, self.hasVisibleStreamingAssistantText {
            ChatStreamingAssistantBubble(
                text: text,
                markdownVariant: self.markdownVariant,
                showsReasoning: self.displayOptions.contains(.reasoning),
                assistantName: self.assistantName,
                assistantAvatarText: self.assistantAvatarText,
                assistantAvatarTint: self.assistantAvatarTint,
                showsAssistantAvatar: self.showsAssistantAvatars,
                isClean: self.composerChrome == .clean)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func messageRow(
        for msg: OpenClawChatMessage,
        contextWindowTokens: Int?) -> some View
    {
        let bubble = ChatMessageBubble(
            message: msg,
            sourcePreviews: self.viewModel.sourcePreviews(for: msg),
            sourceContextRevision: self.viewModel.sourcePreviewState.revision,
            sourceFaviconsEnabled: self.viewModel.sourcePreviewState.context?.automaticallyFetchFavicons == true,
            loadSourceFavicon: { [weak viewModel] host in
                await viewModel?.transport.loadSourceFavicon(host: host)
            },
            style: self.style,
            markdownVariant: self.markdownVariant,
            userAccent: self.userAccent,
            displayOptions: self.displayOptions,
            assistantName: self.assistantName,
            assistantAvatarText: self.assistantAvatarText,
            assistantAvatarTint: self.assistantAvatarTint,
            showsAssistantAvatar: self.showsAssistantAvatars,
            isClean: self.composerChrome == .clean,
            contextWindowTokens: contextWindowTokens,
            userMessageExpanded: self.expandedUserMessageIDs.contains(msg.id),
            onToggleUserMessageExpanded: {
                if self.expandedUserMessageIDs.contains(msg.id) {
                    self.expandedUserMessageIDs.remove(msg.id)
                } else {
                    self.expandedUserMessageIDs.insert(msg.id)
                }
            },
            inlineWidgetResolverReady: self.viewModel.healthOK,
            inlineWidgetResourceResolver: { [weak viewModel] path, failedResource in
                await viewModel?.resolveInlineWidgetResource(path: path, replacing: failedResource)
            },
            mediaArtifactResolverReady: self.viewModel.healthOK,
            mediaPlaybackAllowed: self.mediaPlaybackAllowed,
            loadMediaArtifact: { [weak viewModel] artifactId, kind, playback in
                guard let viewModel else { return nil }
                return try await viewModel.transport.loadMediaArtifact(
                    sessionKey: viewModel.sessionKey,
                    artifactId: artifactId,
                    kind: kind,
                    playback: playback)
            })
            .frame(
                maxWidth: .infinity,
                alignment: msg.role.lowercased() == "user" ? .trailing : .leading)
        let isUser = msg.role.lowercased() == "user"
        let row = VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            bubble
            if let outboxState = self.viewModel.outboxState(for: msg.id) {
                ChatOutboxStatusLabel(state: outboxState)
                    .padding(.trailing, 8)
            }
            if let speech = self.speech,
               let isPreparing = self.speechChipIsPreparing(speech, messageID: msg.id)
            {
                ChatSpeechStatusChip(isPreparing: isPreparing) { speech.stop() }
                    .padding(.leading, 8)
            }
            #if os(iOS)
            if !isUser {
                self.messageActionsMenu(for: msg)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(OpenClawChatTypography.caption)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: CleanChatComposerMetrics.controlTouchSize,
                        height: CleanChatComposerMetrics.controlTouchSize)
                    .contentShape(Rectangle())
                    .padding(.leading, 8)
                    .padding(.bottom, 8)
            }
            #endif
            #if os(macOS)
            if self.isDesktopLayout, isUser || self.isListenable(msg) {
                HStack(spacing: 12) {
                    self.copyMessageButton(for: msg)
                        .help("Copy message")
                        .modifier(ChatHoverAction(revealed: self.hoveredMessageID == msg.id))
                    self.replyMessageButton(for: msg)
                        .help("Reply")
                        .modifier(ChatHoverAction(revealed: self.hoveredMessageID == msg.id))
                    self.listenMessageButton(for: msg)
                        .modifier(ChatHoverAction(revealed: self.hoveredMessageID == msg.id))
                    self.messageActionsMenu(for: msg)
                        .help("Message actions")
                        .modifier(ChatHoverAction(revealed: self.hoveredMessageID == msg.id))
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(OpenClawChatTypography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .accessibilityElement(children: .contain)
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { hovering in
            if hovering {
                self.hoveredMessageID = msg.id
            } else if self.hoveredMessageID == msg.id {
                self.hoveredMessageID = nil
            }
        }
        #if os(iOS)
        if isUser {
            row.contextMenu { self.messageMenuActions(for: msg) }
        } else {
            row
        }
        #else
        row.contextMenu { self.messageMenuActions(for: msg) }
        #endif
    }

    private func messageActionsMenu(for message: OpenClawChatMessage) -> some View {
        Menu {
            self.messageMenuActions(for: message)
        } label: {
            Label("Message Actions", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .accessibilityIdentifier("chat-message-actions")
    }

    @ViewBuilder
    private func messageMenuActions(for message: OpenClawChatMessage) -> some View {
        self.copyMessageButton(for: message)
        #if os(iOS)
        self.selectTextButton(for: message)
        #endif
        self.replyMessageButton(for: message)
        self.openFullMessageButton(for: message)
        self.rewindMessageButton(for: message)
        self.forkMessageButton(for: message)
        self.listenMessageButton(for: message)
        if let outboxState = self.viewModel.outboxState(for: message.id) {
            if outboxState.isFailed {
                Button {
                    self.viewModel.retryOutboxMessage(message.id)
                } label: {
                    Label("Retry Send", systemImage: "arrow.clockwise")
                }
            }
            // In-flight sends may still reach canonical history; hiding them
            // would make a real send look as though it had been cancelled.
            if !outboxState.preventsDeletion {
                Button(role: .destructive) {
                    self.viewModel.deleteOutboxMessage(message.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func listenMessageButton(for message: OpenClawChatMessage) -> some View {
        if let speech = self.speech, self.isListenable(message) {
            Button {
                speech.toggle(messageID: message.id, text: ChatMessageVisibleText.visibleText(in: message))
            } label: {
                Label(
                    speech.isActive(message.id) ? "Stop Listening" : "Listen",
                    systemImage: speech.isActive(message.id) ? "stop.circle" : "speaker.wave.2")
            }
            .help(speech.isActive(message.id) ? "Stop listening" : "Listen")
        }
    }

    private func isListenable(_ msg: OpenClawChatMessage) -> Bool {
        msg.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "assistant"
            && ChatMessageVisibleText.hasVisibleText(in: msg)
    }

    private func speechChipIsPreparing(
        _ speech: OpenClawChatSpeechController,
        messageID: UUID) -> Bool?
    {
        switch speech.phase {
        case let .preparing(id) where id == messageID:
            true
        case let .speaking(id) where id == messageID:
            false
        default:
            nil
        }
    }

    private var transcriptRows: [ChatTranscriptRow] {
        let base: [OpenClawChatMessage]
        if self.style == .onboarding {
            guard let first = viewModel.messages.first else { return [] }
            base = first.role.lowercased() == "user" ? Array(self.viewModel.messages.dropFirst()) : self.viewModel
                .messages
        } else {
            base = self.viewModel.messages
        }
        var rows = ChatTranscriptRow.build(from: self.mergeToolResults(in: base))
        if self.collapsesCompletedWork {
            rows = ChatTranscriptRow.collapseCompletedWork(
                rows,
                runWorking: self.viewModel.hasBlockingRunActivity || self.viewModel.streamingAssistantText != nil,
                activeRunIDs: Set(self.viewModel.liveAdvertisedRunIDs).union(self.viewModel.liveLocalRunIDs),
                searchActive: self.isSearchPresented)
        }
        return rows.compactMap { row in
            switch row {
            case let .message(message):
                return self.shouldDisplayMessage(message) ? row : nil
            case let .completedWork(work):
                let visible = work.messages.filter(self.shouldDisplayMessage)
                return visible.isEmpty ? nil : .completedWork(.init(
                    anchorID: work.anchorID, messages: visible, durationMilliseconds: work.durationMilliseconds))
            default:
                return row
            }
        }
    }

    private var latestVisibleTurnStartID: UUID? {
        self.visibleTurnStartIDs.last
    }

    private var visibleTurnStartIDs: [UUID] {
        self.transcriptRows.compactMap { $0.startsTurn ? $0.id : nil }
    }

    private var isFollowingTurn: Bool {
        if case .turn = self.followTarget {
            return true
        }
        return false
    }

    private var showsJumpToLatest: Bool {
        chatReaderShowsJumpToLatest(
            hasNewerContentBelow: self.hasNewerContentBelow,
            isAtLiveEdge: self.isAtLiveEdge,
            hasVisibleContent: self.hasVisibleMessageListContent,
            isLoading: self.viewModel.isLoading)
    }

    private var jumpToLatestButton: some View {
        Button {
            self.isSearchPresented = false
            self.searchMessageID = nil
            self.followTarget = .latest
            self.hasNewerContentBelow = false
            self.moveScrollPosition(to: self.scrollerBottomID)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(OpenClawChatTheme.subtleCard)
                        .shadow(color: .black.opacity(0.16), radius: 8, y: 3))
                // Padding keeps a ~44pt tap target around the compact visual circle.
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(OpenClawChatTheme.assistantText)
        .accessibilityLabel("Jump to latest reply")
    }

    @ViewBuilder
    private var messageListOverlay: some View {
        if self.viewModel.isLoading {
            EmptyView()
        } else if self.composerChrome == .clean, self.visibleEmptyAssistantIntro != nil {
            EmptyView()
        } else if self.showsCleanLoadingPlaceholder {
            EmptyView()
        } else if let error = activeErrorText {
            if self.hasVisibleMessageListContent {
                EmptyView()
            } else {
                let presentation = self.errorPresentation(for: error)
                ChatNoticeCard(
                    systemImage: presentation.systemImage,
                    title: presentation.title,
                    message: presentation.message,
                    actionTitle: String(localized: "Refresh"),
                    action: { self.viewModel.refresh() })
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if self.showsEmptyState {
            ChatNoticeCard(
                systemImage: "bubble.left.and.bubble.right.fill",
                title: self.emptyStateTitle,
                message: self.emptyStateMessage,
                actionTitle: nil,
                action: nil)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var activeErrorText: String? {
        let showsContextualSignIn = self.showsComposer && self.isDesktopLayout && self.composerChrome == .clean
        let activeError = showsContextualSignIn
            ? self.viewModel.errorText
            : self.viewModel.composerModelAvailabilityMessage ?? self.viewModel.errorText
        guard let text = activeError?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return nil
        }
        return text
    }

    private var hasVisibleMessageListContent: Bool {
        if !self.transcriptRows.isEmpty {
            return true
        }
        return self.hasVisibleTransientContent
    }

    private var hasVisibleStreamingAssistantText: Bool {
        guard let text = self.viewModel.streamingAssistantText else { return false }
        return AssistantTextParser.hasVisibleContent(
            in: text,
            includeThinking: self.displayOptions.contains(.reasoning))
    }

    private var showsWorkingIndicator: Bool {
        self.viewModel.hasBlockingRunActivity &&
            (!self.hasVisibleStreamingAssistantText || self.viewModel.liveUsageRunID != nil)
    }

    private var turnRecapObservation: ChatTurnRecapObservation {
        let row = self.viewModel.currentSessionEntry().map(ChatTurnRecapSessionRow.init)
        return ChatTurnRecapObservation(
            sessionKey: self.viewModel.sessionKey,
            indicatorVisible: self.showsWorkingIndicator,
            row: row)
    }

    private func updateTurnRecap(_ observation: ChatTurnRecapObservation) {
        var resolver = self.turnRecapResolver
        let recap = resolver.resolve(
            sessionKey: observation.sessionKey,
            indicatorVisible: observation.indicatorVisible,
            row: observation.row)
        self.turnRecapResolver = resolver
        self.turnRecap = recap
        self.turnRecapSessionKey = recap == nil ? nil : observation.sessionKey
    }

    private var hasVisibleTransientContent: Bool {
        self.viewModel.hasBlockingRunActivity ||
            (self.displayOptions.contains(.toolActivity) && !self.viewModel.subagentActivities.isEmpty) ||
            (self.displayOptions.contains(.toolActivity) && !self.viewModel.pendingToolCalls.isEmpty) ||
            self.hasVisibleStreamingAssistantText ||
            !self.viewModel.visibleQuestionCards.isEmpty
    }

    @ViewBuilder
    private var messageListNoticeBanner: some View {
        if let error = activeErrorText,
           hasVisibleMessageListContent,
           !self.viewModel.isLoading,
           visibleEmptyAssistantIntro == nil,
           !self.showsCleanLoadingPlaceholder
        {
            let presentation = self.errorPresentation(for: error)
            ChatNoticeBanner(
                systemImage: presentation.systemImage,
                title: presentation.title,
                message: error,
                tint: presentation.tint,
                dismiss: { self.viewModel.errorText = nil },
                refresh: { self.viewModel.refresh() })
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 8)
        }
    }

    private var showsCleanLoadingPlaceholder: Bool {
        self.composerChrome == .clean &&
            self.viewModel.isLoading &&
            self.visibleEmptyAssistantIntro == nil &&
            self.activeErrorText == nil &&
            !self.hasVisibleMessageListContent
    }

    private var visibleEmptyAssistantIntro: String? {
        guard self.composerChrome == .clean,
              self.showsEmptyState,
              !self.viewModel.isLoading,
              self.activeErrorText == nil,
              self.isComposerEnabled
        else {
            return nil
        }
        guard let text = emptyAssistantIntro?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        return text
    }

    private var showsEmptyState: Bool {
        self.viewModel.messages.isEmpty &&
            !self.hasVisibleStreamingAssistantText &&
            !self.viewModel.hasBlockingRunActivity &&
            self.viewModel.subagentActivities.isEmpty &&
            self.viewModel.pendingToolCalls.isEmpty
    }

    private var emptyStateTitle: String {
        #if os(macOS)
        String(localized: "Start a Conversation")
        #else
        String(localized: "Chat")
        #endif
    }

    private var emptyStateMessage: String {
        #if os(macOS)
        if self.preferences?.sendRequiresModifier == true {
            return String(
                localized: "Message your agent to get started.\n⌘-Return sends • Return adds a line break • / shows commands.")
        }
        return String(
            localized: "Message your agent to get started.\nReturn sends • Shift-Return adds a line break • / shows commands.")
        #else
        String(localized: "Type a message below to start.")
        #endif
    }
}

extension OpenClawChatView {
    private func errorPresentation(
        for error: String) -> (title: String, message: String, systemImage: String, tint: Color)
    {
        let lower = error.lowercased()
        if lower.contains("not connected") || lower.contains("socket") {
            return (
                String(localized: "Disconnected"),
                String(localized: "Reconnect to your gateway to continue."),
                "wifi.slash",
                .orange)
        }
        if lower.contains("timed out") {
            return (
                String(localized: "Timed out"),
                String(localized: "The gateway took too long to respond."),
                "clock.badge.exclamationmark",
                .orange)
        }
        // Unknown errors: keep the raw text as the description so it stays actionable.
        return (String(localized: "Something went wrong"), error, "exclamationmark.triangle.fill", .orange)
    }

    private func restoreInitialScrollPosition() {
        switch chatReaderInitialRestorePolicy() {
        case .liveEdge:
            self.followTarget = .latest
            self.hasNewerContentBelow = false
            self.moveScrollPosition(to: self.scrollerBottomID)
        case .latestTurn:
            if let latestTurnStartID = latestVisibleTurnStartID {
                self.followTarget = nil
                self.hasNewerContentBelow = chatReaderHasNewerContent(
                    after: latestTurnStartID,
                    visibleIDs: self.transcriptRows.map(\.id),
                    hasTransientContent: self.hasVisibleTransientContent)
                self.moveScrollPosition(to: latestTurnStartID, anchor: Layout.newTurnAnchor)
            } else {
                self.followTarget = .latest
                self.hasNewerContentBelow = false
                self.moveScrollPosition(to: self.scrollerBottomID)
            }
        }
    }

    private func handleTimelineChange() {
        guard self.hasPerformedInitialScroll else { return }
        // A search result is an explicit reading position. Incoming replies
        // must not pull the reader away until they leave Find.
        guard self.searchMessageID == nil else { return }
        if self.viewModel.messages.isEmpty,
           !self.viewModel.hasBlockingRunActivity,
           self.viewModel.subagentActivities.isEmpty,
           self.viewModel.pendingToolCalls.isEmpty,
           self.viewModel.streamingAssistantText == nil
        {
            self.lastTurnStartID = nil
            self.followTarget = .latest
            self.hasNewerContentBelow = false
            self.moveScrollPosition(to: self.scrollerBottomID)
            return
        }
        let transcriptRows = self.transcriptRows
        let visibleTurnStartIDs = transcriptRows.compactMap { $0.startsTurn ? $0.id : nil }
        switch chatReaderUserTransition(
            previousID: self.lastTurnStartID,
            visibleIDs: visibleTurnStartIDs)
        {
        case let .removed(latestRemainingID):
            self.lastTurnStartID = latestRemainingID
            if case let .turn(messageID) = followTarget,
               !visibleTurnStartIDs.contains(messageID)
            {
                self.followTarget = nil
                self.hasNewerContentBelow = false
            }
            return
        case let .added(latestTurnStartID):
            self.lastTurnStartID = latestTurnStartID
            self.hasNewerContentBelow = false
            // The anchored-question layout assumes a viewport tall enough to read the turn
            // below the anchor. With the keyboard up that space is gone and the reply streams
            // straight past the fold (#108692), so follow the live edge instead.
            if self.isKeyboardVisible {
                self.followTarget = .latest
                self.moveScrollPosition(to: self.scrollerBottomID)
            } else {
                self.followTarget = .turn(latestTurnStartID)
                self.moveScrollPosition(to: latestTurnStartID, anchor: Layout.newTurnAnchor)
            }
            return
        case .unchanged:
            break
        }

        switch self.followTarget {
        case .latest:
            self.hasNewerContentBelow = false
            self.moveScrollPosition(to: self.scrollerBottomID)
        case let .turn(messageID):
            // Reader policy stays on this turn after the one-shot scroll binding is released. Reissuing
            // that target for every streaming delta can loop SwiftUI layout and starve interaction.
            self.hasNewerContentBelow = chatReaderHasNewerContent(
                after: messageID,
                visibleIDs: transcriptRows.map(\.id),
                hasTransientContent: self.hasVisibleTransientContent)
        case nil:
            self.hasNewerContentBelow = true
        }
    }

    private func moveScrollPosition(
        to id: UUID,
        anchor: UnitPoint = .bottom)
    {
        var transaction = Transaction(animation: nil)
        transaction.scrollTargetAnchor = anchor
        withTransaction(transaction) {
            self.scrollPosition = id
        }
        DispatchQueue.main.async {
            guard self.scrollPosition == id else { return }
            // Reader policy lives in followTarget. The binding is only a one-shot positioning request;
            // keeping an overflowing transcript bound to any row can loop SwiftUI scroll layout.
            self.scrollPosition = nil
        }
    }

    private func revealSearchMessage(_ messageID: UUID) {
        self.followTarget = nil
        self.hasNewerContentBelow = true
        self.expandedUserMessageIDs.insert(messageID)
        self.moveScrollPosition(to: messageID, anchor: .top)
    }

    private func dismissKeyboardIfNeeded() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil)
        #endif
    }
}

extension OpenClawChatView {
    private func mergeToolResults(in messages: [OpenClawChatMessage]) -> [OpenClawChatMessage] {
        var result: [OpenClawChatMessage] = []
        result.reserveCapacity(messages.count)

        for message in messages {
            guard self.isToolResultMessage(message) else {
                result.append(message)
                continue
            }

            guard let toolCallId = message.toolCallId,
                  let last = result.last,
                  message.turnBoundary != true,
                  !message.isForwardedTurnBoundary,
                  !last.isForwardedTurnBoundary,
                  message.transcriptRunID == nil || last.transcriptRunID == nil ||
                  message.transcriptRunID == last.transcriptRunID,
                  toolCallIds(in: last).contains(toolCallId)
            else {
                result.append(message)
                continue
            }

            let toolText = self.toolResultText(from: message)
            var content = last.content
            // Preserve empty results too: receiving a result owns the outcome,
            // independently of whether it contains display text.
            content.append(
                OpenClawChatMessageContent(
                    type: "tool_result",
                    text: toolText,
                    thinking: nil,
                    thinkingSignature: nil,
                    mimeType: nil,
                    fileName: nil,
                    content: nil,
                    id: toolCallId,
                    name: message.toolName,
                    arguments: nil,
                    details: message.details,
                    isError: message.isError))

            let merged = OpenClawChatMessage(
                id: last.id,
                role: last.role,
                content: content,
                timestamp: last.timestamp,
                transcriptMessageID: last.transcriptMessageID,
                transcriptRunID: last.transcriptRunID,
                isTruncated: last.isTruncated,
                idempotencyKey: last.idempotencyKey,
                toolCallId: last.toolCallId,
                toolName: last.toolName,
                usage: last.usage,
                stopReason: last.stopReason,
                errorMessage: last.errorMessage,
                details: last.details,
                isError: last.isError,
                provenance: last.provenance,
                historyMarker: last.historyMarker,
                phase: last.phase,
                turnBoundary: last.turnBoundary,
                steerTargetRunID: last.steerTargetRunID,
                streamFallback: last.streamFallback,
                activity: message.activity.map { terminal in
                    (last.activity ?? []).filter { $0.toolCallId != toolCallId } + terminal
                } ?? last.activity)
            result[result.count - 1] = merged
        }

        return result
    }

    private func isToolResultMessage(_ message: OpenClawChatMessage) -> Bool {
        let role = message.role.lowercased()
        return role == "toolresult" || role == "tool_result"
    }

    private func shouldDisplayMessage(_ message: OpenClawChatMessage) -> Bool {
        let primaryText = self.primaryText(in: message)
        if self.hasInlineAttachments(in: message) {
            return true
        }

        if self.isToolResultMessage(message) {
            return self.displayOptions.contains(.toolActivity)
        }

        if !primaryText.isEmpty {
            if message.role.lowercased() == "user" {
                return true
            }
            if AssistantTextParser.hasVisibleContent(
                in: primaryText,
                includeThinking: self.displayOptions.contains(.reasoning))
            {
                return true
            }
        }

        return self.displayOptions.contains(.toolActivity) &&
            (!self.toolCalls(in: message).isEmpty || !self.inlineToolResults(in: message).isEmpty)
    }

    private func primaryText(in message: OpenClawChatMessage) -> String {
        ChatMessageVisibleText.displayText(
            in: message,
            includeThinking: self.displayOptions.contains(.reasoning))
    }

    private func hasInlineAttachments(in message: OpenClawChatMessage) -> Bool {
        message.content.contains(where: \.isInlineAttachment)
    }

    private func toolCalls(in message: OpenClawChatMessage) -> [OpenClawChatMessageContent] {
        message.content.filter(\.isToolCall)
    }

    private func inlineToolResults(in message: OpenClawChatMessage) -> [OpenClawChatMessageContent] {
        message.content.filter(\.isToolResult)
    }

    private func toolCallIds(in message: OpenClawChatMessage) -> Set<String> {
        var ids = Set<String>()
        for content in self.toolCalls(in: message) {
            if let id = content.id {
                ids.insert(id)
            }
        }
        if let toolCallId = message.toolCallId {
            ids.insert(toolCallId)
        }
        return ids
    }

    private func toolResultText(from message: OpenClawChatMessage) -> String {
        self.primaryText(in: message)
    }

    @ViewBuilder
    private func copyMessageButton(for message: OpenClawChatMessage) -> some View {
        let text = ChatMessageVisibleText.copyText(in: message)
        if !text.isEmpty {
            Button {
                ChatPasteboard.copy(text)
            } label: {
                Label {
                    Text("Copy Message")
                        .font(OpenClawChatTypography.body)
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
    }

    #if os(iOS)
    @ViewBuilder
    private func selectTextButton(for message: OpenClawChatMessage) -> some View {
        if !ChatMessageVisibleText.copyText(in: message).isEmpty {
            Button {
                self.selectTextMessage = message
            } label: {
                Label {
                    Text("Select Text").font(OpenClawChatTypography.body)
                } icon: {
                    Image(systemName: "text.cursor")
                }
            }
        }
    }
    #endif

    @ViewBuilder
    private func openFullMessageButton(for message: OpenClawChatMessage) -> some View {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if role == "assistant",
           message.isTruncated,
           let messageID = message.transcriptMessageID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !messageID.isEmpty
        {
            Button {
                self.fullMessageRequest = ChatFullMessageReaderRequest(
                    viewModel: self.viewModel,
                    messageID: messageID)
            } label: {
                Label {
                    Text("Open Full Message")
                        .font(OpenClawChatTypography.body)
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
            }
        }
    }

    @ViewBuilder
    private func rewindMessageButton(for message: OpenClawChatMessage) -> some View {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if self.showsComposer, role == "user",
           message.transcriptMessageID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
            Button {
                Task { await self.viewModel.rewindToMessage(message) }
            } label: {
                Label {
                    Text("Rewind to Here")
                        .font(OpenClawChatTypography.body)
                } icon: {
                    Image(systemName: "arrow.uturn.backward")
                }
            }
            .disabled(self.messageSessionActionsDisabled)
        }
    }

    @ViewBuilder
    private func forkMessageButton(for message: OpenClawChatMessage) -> some View {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if self.showsComposer, role == "user",
           message.transcriptMessageID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
            Button {
                Task { await self.viewModel.forkAtMessage(message) }
            } label: {
                Label {
                    Text("Fork from Here")
                        .font(OpenClawChatTypography.body)
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                }
            }
            .disabled(self.messageSessionActionsDisabled)
        }
    }

    private var messageSessionActionsDisabled: Bool {
        !self.viewModel.canPerformMessageSessionAction
    }

    @ViewBuilder
    private func replyMessageButton(for message: OpenClawChatMessage) -> some View {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let text = ChatReplyQuote.targetText(ChatMessageVisibleText.visibleText(in: message))
        if self.showsComposer, role == "user" || role == "assistant", !text.isEmpty {
            Button {
                self.viewModel.setReplyTarget(
                    messageID: message.id,
                    text: text,
                    senderLabel: self.replySenderLabel(forRole: role))
            } label: {
                Label {
                    Text(String(localized: "Reply"))
                        .font(OpenClawChatTypography.body)
                } icon: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
            }
        }
    }

    private func replySenderLabel(forRole role: String) -> String {
        guard role == "assistant" else { return String(localized: "You") }
        let name = self.assistantName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? String(localized: "Assistant") : name
    }
}

/// Observes scroll phase and live-edge geometry on iOS 18 / macOS 15 / visionOS 2 and later.
///
/// iOS 17 / macOS 14 have neither observer: a drag gesture stands in for the interacting phase and the bottom
/// sentinel (`ChatReaderLiveEdgeSentinel`) for the live-edge distance.
private struct ChatReaderScrollObservation: ViewModifier {
    let liveEdgeThreshold: CGFloat
    let onLiveEdgeChange: (Bool) -> Void
    let onPhaseChange: (ChatReaderScrollPhase) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let distanceFromBottom = geometry.contentSize.height - geometry.visibleRect.maxY
                    return distanceFromBottom <= self.liveEdgeThreshold
                } action: { _, isAtLiveEdge in
                    self.onLiveEdgeChange(isAtLiveEdge)
                }
                .onScrollPhaseChange { _, phase in
                    self.onPhaseChange(ChatReaderScrollPhase(phase))
                }
        } else {
            content
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in self.onPhaseChange(.interacting) }
                        .onEnded { _ in self.onPhaseChange(.idle) })
        }
    }
}

/// Reports when the transcript's bottom sentinel enters or leaves the viewport (iOS 17 / macOS 14 fallback).
private struct ChatReaderLiveEdgeSentinel: ViewModifier {
    let onVisibilityChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { self.onVisibilityChange(true) }
            .onDisappear { self.onVisibilityChange(false) }
    }
}

extension ChatReaderScrollPhase {
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    init(_ phase: ScrollPhase) {
        switch phase {
        case .idle: self = .idle
        case .tracking: self = .tracking
        case .interacting: self = .interacting
        case .decelerating: self = .decelerating
        case .animating: self = .animating
        @unknown default: self = .idle
        }
    }
}

/// Applies `ui.prefs.themeMode` to the chat subtree (`nil`, from `system`, leaves the host appearance alone).
private struct ChatPreferredColorSchemeModifier: ViewModifier {
    let colorScheme: ColorScheme?

    func body(content: Content) -> some View {
        if let colorScheme {
            content.environment(\.colorScheme, colorScheme)
        } else {
            content
        }
    }
}

private struct ChatAssistantIntroCard: View {
    let text: String
    let prompts: [OpenClawChatView.StarterPrompt]
    let onPrompt: (OpenClawChatView.StarterPrompt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Rendered as a grey assistant bubble so the greeting reads like the
            // agent's first message, matching the in-conversation bubble style.
            Text(self.text)
                .font(OpenClawChatTypography.body)
                .foregroundStyle(OpenClawChatTheme.assistantText)
                .multilineTextAlignment(.leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(OpenClawChatTheme.assistantBubble))

            ForEach(self.prompts) { prompt in
                Button {
                    self.onPrompt(prompt)
                } label: {
                    HStack(spacing: 8) {
                        Text(prompt.title)
                            .font(OpenClawChatTypography.body(size: 15, weight: .semibold, relativeTo: .callout))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(OpenClawChatTypography.captionSemiBold)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(OpenClawChatTheme.subtleCard))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-starter-\(prompt.id)")
            }
        }
        .frame(maxWidth: 340, alignment: .leading)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatLoadingBubble: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading chat")
                .font(OpenClawChatTypography.captionSemiBold)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            Capsule()
                .fill(OpenClawChatTheme.subtleCard))
        .padding(.leading, 10)
    }
}

private struct ChatNoticeCard: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        // Native empty/error state: SwiftUI's standard ContentUnavailableView, not a custom card.
        ContentUnavailableView {
            Label(self.title, systemImage: self.systemImage)
                .font(OpenClawChatTypography.headline)
        } description: {
            Text(self.message)
                .font(OpenClawChatTypography.body)
        } actions: {
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(OpenClawChatTypography.body(size: 15, weight: .semibold, relativeTo: .subheadline))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
}

private struct ChatNoticeBanner: View {
    let systemImage: String
    let title: String
    let message: String
    let tint: Color
    let dismiss: () -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: self.systemImage)
                .font(OpenClawChatTypography.display(size: 15, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(self.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(self.title)
                    .font(OpenClawChatTypography.captionSemiBold)

                Text(self.message)
                    .font(OpenClawChatTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button(action: self.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh")

            Button(action: self.dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OpenClawChatTheme.subtleCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)))
    }
}
#endif
