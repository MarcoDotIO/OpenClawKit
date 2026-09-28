// TEMPORARY merge shim (wave 2). DELETE at merge once W5b chatui-render lands.
//
// The chat shell (ChatView, the composer, the session views and the speech controller) is ported from upstream
// OpenClaw 2026.9.6 and calls transcript-rendering types that W5b ports in parallel from the same upstream
// files. So the shell compiles on its own branch, this file declares exactly those upstream names with minimal
// internal stand-in implementations. Each section names the upstream file whose W5b port replaces it; after the
// W5b merge, delete the sections whose names W5b defines (duplicate-declaration errors point at them) and keep
// any section W5b did not port.
//
// Nothing here is public API, and no behavior is load-bearing: the stand-ins only keep the shell usable.
import Foundation
import OpenClawKit
#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
#endif

// MARK: - Stand-in for upstream ChatTranscriptRows.swift (faithful pure-logic port) + ChatCompletedWork.swift

enum ChatTranscriptRow: Hashable, Identifiable {
    enum SystemNoticeKind: Hashable {
        case restartRecovery
        case gatewayRestarted
        case generic
    }

    struct SystemNotice: Hashable {
        let id: UUID
        let kind: SystemNoticeKind
        let body: String
        let timestamp: Double?

        var label: String {
            switch self.kind {
            case .restartRecovery:
                String(localized: "System · restart recovery")
            case .gatewayRestarted:
                String(localized: "System · gateway restarted")
            case .generic:
                String(localized: "System")
            }
        }
    }

    enum HistoryDividerKind: Hashable {
        case compaction
        case reset
    }

    struct HistoryDivider: Hashable {
        let id: UUID
        let kind: HistoryDividerKind
        let savedTokens: Double?
        let timestamp: Double?

        var label: String {
            switch self.kind {
            case .compaction:
                String(localized: "Compacted history")
            case .reset:
                String(localized: "Session reset")
            }
        }
    }

    struct CompletedWork: Hashable {
        let anchorID: UUID
        let messages: [OpenClawChatMessage]
        let durationMilliseconds: Double?

        var id: UUID {
            var bytes = self.anchorID.uuid
            bytes.0 ^= 0x80
            return UUID(uuid: bytes)
        }
    }

    case message(OpenClawChatMessage)
    case systemNotice(SystemNotice)
    case historyDivider(HistoryDivider)
    case completedWork(CompletedWork)

    var id: UUID {
        switch self {
        case let .message(message): message.id
        case let .systemNotice(notice): notice.id
        case let .historyDivider(divider): divider.id
        case let .completedWork(work): work.id
        }
    }

    var startsTurn: Bool {
        switch self {
        case let .message(message):
            message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user" ||
                message.turnBoundary == true || message.isForwardedTurnBoundary
        case .systemNotice:
            true
        case .historyDivider, .completedWork:
            false
        }
    }

    init?(_ message: OpenClawChatMessage) {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if role == "system", let marker = message.historyMarker {
            switch marker.kind {
            case "compaction":
                self = .historyDivider(HistoryDivider(
                    id: message.id, kind: .compaction, savedTokens: nil, timestamp: message.timestamp))
            case "reset":
                self = .historyDivider(HistoryDivider(
                    id: message.id, kind: .reset, savedTokens: nil, timestamp: message.timestamp))
            default:
                return nil
            }
            return
        }
        if role == "user", message.provenance?.kind == "internal_system" {
            let body = ChatMessageVisibleText.visibleText(in: message)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = .systemNotice(SystemNotice(id: message.id, kind: .generic, body: body, timestamp: message.timestamp))
            return
        }
        self = .message(message)
    }

    static func build(from messages: [OpenClawChatMessage]) -> [Self] {
        messages.compactMap(Self.init)
    }

    /// Stand-in: W5b's port folds finished tool work into a disclosure; this keeps every row visible.
    static func collapseCompletedWork(
        _ rows: [Self],
        runWorking _: Bool,
        activeRunIDs _: Set<String> = [],
        searchActive _: Bool = false) -> [Self]
    {
        rows
    }
}

// MARK: - Stand-in for upstream ChatWorkingProgress.swift (turn recap)

struct ChatTurnRecap: Equatable, Sendable {
    let runtimeMs: Double
    let outputTokens: Int?
}

struct ChatTurnRecapSessionRow: Equatable, Sendable {
    let status: String?
    let endedAt: Double?
    let runtimeMs: Double?
    let outputTokens: Int?

    init(_ entry: OpenClawChatSessionEntry) {
        self.status = entry.status
        self.endedAt = entry.endedAt
        self.runtimeMs = entry.runtimeMs
        self.outputTokens = entry.outputTokens
    }
}

/// Stand-in: never produces a recap (W5b's port watches the working indicator and settles one).
struct ChatTurnRecapResolver {
    mutating func resolve(
        sessionKey _: String,
        indicatorVisible _: Bool,
        row _: ChatTurnRecapSessionRow?,
        now _: Date = Date()) -> ChatTurnRecap?
    {
        nil
    }
}

// MARK: - Stand-in for upstream ChatMediaPlaybackCoordinator.swift (single active media owner)

@MainActor
protocol ChatMediaPlaybackOwner: AnyObject {
    func stopForMediaPlaybackInterruption()
}

@MainActor
final class ChatMediaPlaybackCoordinator {
    static let shared = ChatMediaPlaybackCoordinator()

    private weak var activeOwner: (any ChatMediaPlaybackOwner)?

    func activate(_ owner: any ChatMediaPlaybackOwner) {
        if let activeOwner = self.activeOwner, activeOwner !== owner {
            activeOwner.stopForMediaPlaybackInterruption()
        }
        self.activeOwner = owner
    }

    func release(_ owner: any ChatMediaPlaybackOwner) {
        guard self.activeOwner === owner else { return }
        self.activeOwner = nil
    }

    func isActive(_ owner: any ChatMediaPlaybackOwner) -> Bool {
        self.activeOwner === owner
    }
}

// MARK: - Stand-in for upstream ChatTranscriptExporter.swift

enum ChatTranscriptExporter {
    static func filename(sessionTitle: String, sessionKey: String) -> String {
        let base = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sessionKey : sessionTitle
        let safe = base.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        return String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + ".md"
    }
}

extension OpenClawChatViewModel {
    func exportTranscriptMarkdown() -> String {
        self.messages.map { message in
            "**\(message.role)**\n\n\(ChatMessageVisibleText.visibleText(in: message))"
        }
        .joined(separator: "\n\n---\n\n")
    }
}

#if os(iOS) || os(macOS) || os(visionOS)

// MARK: - Stand-in for upstream ChatTypography.swift (system fonts; the SDK ships no brand fonts)

enum OpenClawChatTypography {
    static let bodySize: CGFloat = 17

    static var headline: Font {
        self.display(size: 17, weight: .semibold, relativeTo: .headline)
    }

    static func heading(level: Int) -> Font {
        switch level {
        case 1: self.display(size: 24, weight: .bold, relativeTo: .title2)
        case 2: self.display(size: 21, weight: .bold, relativeTo: .title3)
        case 3: self.display(size: 19, weight: .semibold, relativeTo: .headline)
        default: self.body(size: 17, weight: .semibold, relativeTo: .body)
        }
    }

    static var callout: Font {
        self.body(size: 16, weight: .regular, relativeTo: .callout)
    }

    static var body: Font {
        self.body(size: self.bodySize, weight: .regular, relativeTo: .body)
    }

    static var formControl: Font {
        #if os(macOS)
        self.body(size: 13, weight: .regular, relativeTo: .body)
        #else
        self.body
        #endif
    }

    #if os(iOS)
    static var bodyUIFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.systemFont(ofSize: self.bodySize))
    }
    #endif

    static var footnote: Font {
        self.body(size: 13, weight: .regular, relativeTo: .footnote)
    }

    static var footnoteSemiBold: Font {
        self.body(size: 13, weight: .semibold, relativeTo: .footnote)
    }

    static var caption: Font {
        self.body(size: 12, weight: .regular, relativeTo: .caption)
    }

    static var captionSemiBold: Font {
        self.body(size: 12, weight: .semibold, relativeTo: .caption)
    }

    static var caption2: Font {
        self.body(size: 11, weight: .regular, relativeTo: .caption2)
    }

    static func body(size: CGFloat, weight: Font.Weight, relativeTo textStyle: Font.TextStyle) -> Font {
        Font.system(textStyle).weight(weight)
    }

    static func display(size: CGFloat, weight: Font.Weight, relativeTo textStyle: Font.TextStyle) -> Font {
        Font.system(textStyle).weight(weight)
    }

    static func mono(size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle) -> Font {
        Font.system(textStyle, design: .monospaced).weight(weight)
    }

    #if os(macOS)
    static func navigationAvatar(size: CGFloat) -> Font {
        Font.system(size: size, weight: .medium)
    }
    #endif
}

// MARK: - Stand-in for upstream ChatCopyButton.swift

enum ChatPasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

struct ChatHoverAction: ViewModifier {
    let revealed: Bool

    func body(content: Content) -> some View {
        content.opacity(self.revealed ? 1 : 0)
    }
}

// MARK: - Stand-ins for upstream ChatMessageViews.swift rows and chips

struct ChatSystemNoticeRow: View {
    let notice: ChatTranscriptRow.SystemNotice

    var body: some View {
        VStack(spacing: 4) {
            Text(self.notice.label).font(OpenClawChatTypography.captionSemiBold).foregroundStyle(.secondary)
            Text(self.notice.body).font(OpenClawChatTypography.footnote).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ChatHistoryDividerRow: View {
    let divider: ChatTranscriptRow.HistoryDivider

    var body: some View {
        Text(self.divider.label)
            .font(OpenClawChatTypography.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }
}

struct ChatSpeechStatusChip: View {
    let isPreparing: Bool
    let onStop: () -> Void

    var body: some View {
        Button(action: self.onStop) {
            Label(
                self.isPreparing ? String(localized: "Preparing audio…") : String(localized: "Speaking"),
                systemImage: self.isPreparing ? "hourglass" : "speaker.wave.2.fill")
                .font(OpenClawChatTypography.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

struct ChatOutboxStatusLabel: View {
    let state: OpenClawChatOutboxMessageState

    var body: some View {
        Text(self.state.isFailed ? String(localized: "Not delivered") : String(localized: "Sending…"))
            .font(OpenClawChatTypography.caption)
            .foregroundStyle(self.state.isFailed ? AnyShapeStyle(OpenClawChatTheme.danger) : AnyShapeStyle(.secondary))
    }
}

extension ChatMessageBubble {
    init(
        message: OpenClawChatMessage,
        sourcePreviews _: [ChatSourcePreview],
        sourceContextRevision _: UUID,
        sourceFaviconsEnabled _: Bool,
        loadSourceFavicon _: @escaping @MainActor @Sendable (String) async -> Data?,
        style: OpenClawChatView.Style,
        markdownVariant: ChatMarkdownVariant,
        userAccent: Color?,
        displayOptions: OpenClawChatDisplayOptions,
        assistantName _: String?,
        assistantAvatarText _: String?,
        assistantAvatarTint _: Color?,
        showsAssistantAvatar _: Bool,
        isClean _: Bool,
        contextWindowTokens _: Int?,
        userMessageExpanded _: Bool,
        onToggleUserMessageExpanded _: @escaping @MainActor () -> Void,
        inlineWidgetResolverReady _: Bool,
        inlineWidgetResourceResolver _: @escaping @MainActor @Sendable (
            String,
            OpenClawChatWidgetResource?) async -> OpenClawChatWidgetResource?,
        mediaArtifactResolverReady _: Bool,
        mediaPlaybackAllowed _: @escaping @MainActor @Sendable () -> Bool,
        loadMediaArtifact _: @escaping @MainActor @Sendable (
            String,
            OpenClawChatMediaKind,
            OpenClawChatPlaybackMode?) async throws -> OpenClawChatLoadedMedia?)
    {
        self.init(
            message: message,
            style: style,
            markdownVariant: markdownVariant,
            userAccent: userAccent,
            showsAssistantTrace: !displayOptions.isEmpty)
    }
}

extension ChatTypingIndicatorBubble {
    init(
        style: OpenClawChatView.Style,
        assistantName _: String?,
        assistantAvatarText _: String?,
        assistantAvatarTint _: Color?,
        showsAssistantAvatar _: Bool,
        isClean _: Bool,
        runIdentity _: String,
        outputTokens _: Int?)
    {
        self.init(style: style)
    }
}

extension ChatStreamingAssistantBubble {
    init(
        text: String,
        markdownVariant: ChatMarkdownVariant,
        showsReasoning: Bool,
        assistantName _: String?,
        assistantAvatarText _: String?,
        assistantAvatarTint _: Color?,
        showsAssistantAvatar _: Bool,
        isClean _: Bool)
    {
        self.init(text: text, markdownVariant: markdownVariant, showsAssistantTrace: showsReasoning)
    }
}

// MARK: - Stand-in for upstream ChatCompletedWorkDisclosure.swift

struct ChatCompletedWorkDisclosure<Content: View>: View {
    let work: ChatTranscriptRow.CompletedWork
    @ViewBuilder let messageContent: (OpenClawChatMessage) -> Content
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: self.$isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(self.work.messages) { message in
                    self.messageContent(message)
                }
            }
        } label: {
            Text(String(localized: "Worked")).font(OpenClawChatTypography.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Stand-in for upstream ChatQuestionCard.swift views

struct OpenClawQuestionCards: View {
    let viewModel: OpenClawChatViewModel

    var body: some View {
        EmptyView()
    }
}

// MARK: - Stand-in for upstream ChatSubagentActivityViews.swift

struct ChatSubagentActivityList: View {
    let activities: [ChatSubagentActivity]
    let hiddenWorkingCount: Int

    var body: some View {
        EmptyView()
    }
}

// MARK: - Stand-in for upstream ChatProgressCard.swift

struct ChatProgressCard: View {
    let steps: [ProgressCardStep]
    let markdown: String?
    let isInline: Bool

    var body: some View {
        if let markdown, !markdown.isEmpty {
            Text(markdown).font(OpenClawChatTypography.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Stand-in for upstream ChatWorkingClawView.swift (turn recap row)

struct ChatTurnRecapRow: View {
    let recap: ChatTurnRecap

    var body: some View {
        EmptyView()
    }
}

// MARK: - Stand-in for upstream Swarm.swift views

struct OpenClawChatSwarmProgressView: View {
    let groups: [OpenClawChatSwarmGroup]

    var body: some View {
        EmptyView()
    }
}

// MARK: - Stand-ins for upstream ChatFullMessageReader.swift / ChatSelectableTextSheet.swift

struct ChatFullMessageReader: View {
    let request: ChatFullMessageReaderRequest
    let markdownVariant: ChatMarkdownVariant

    var body: some View {
        ProgressView()
    }
}

struct ChatSelectableTextSheet: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(self.text).textSelection(.enabled).padding()
        }
    }
}

// MARK: - Stand-in for upstream ChatTranscriptSearch.swift (macOS Find)

#if os(macOS)
struct ChatTranscriptSearch: ViewModifier {
    let rows: [ChatTranscriptRow]
    let sessionKey: String
    let isEnabled: Bool
    @Binding var selectedMessageID: UUID?
    @Binding var isPresented: Bool
    let onSelect: (UUID) -> Void

    func body(content: Content) -> some View {
        content
    }
}
#endif
#endif
