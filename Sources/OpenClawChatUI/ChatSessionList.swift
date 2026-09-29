// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
//
// SDK adaptation of upstream OpenClaw 2026.9.6 `ChatSessionSidebar.swift` (macOS-only upstream): the same
// `ChatSessionSidebarModel` sections rendered as a swipeable List on iOS, iPadOS and visionOS. macOS keeps the
// upstream sidebar port (`ChatSessionSidebar`).
#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

/// Sessions list for the chat split shell: pinned, grouped, recent and subagent rows with attention badges,
/// swipe actions (pin, unread, archive, delete), rename, fork, color and paging.
///
/// On macOS it renders the native sidebar (agents, collapsible groups, hover previews); on iOS, iPadOS and
/// visionOS it renders a `List` built from the same model. Selecting a row switches the view model's session.
@MainActor
public struct OpenClawChatSessionList: View {
    @Bindable private var viewModel: OpenClawChatViewModel
    private let externalQuery: Binding<String>?
    private let additionalAttentionRequests: [OpenClawChatAttentionRequest]
    private let onSelect: (@MainActor (OpenClawChatSessionEntry) -> Void)?
    @State private var localQuery = ""

    /// Creates a sessions list.
    /// - Parameters:
    ///   - viewModel: The chat view model whose sessions are listed.
    ///   - query: Search text binding; the list keeps its own when `nil`.
    ///   - additionalAttentionRequests: Host-supplied attention requests (for example exec approvals) merged with
    ///     the view model's pending question cards.
    ///   - onSelect: Called after a row switches the session (for example to pop a compact navigation stack).
    public init(
        viewModel: OpenClawChatViewModel,
        query: Binding<String>? = nil,
        additionalAttentionRequests: [OpenClawChatAttentionRequest] = [],
        onSelect: (@MainActor (OpenClawChatSessionEntry) -> Void)? = nil)
    {
        self.viewModel = viewModel
        self.externalQuery = query
        self.additionalAttentionRequests = additionalAttentionRequests
        self.onSelect = onSelect
    }

    private var query: Binding<String> {
        self.externalQuery ?? self.$localQuery
    }

    /// The list body.
    public var body: some View {
        #if os(macOS)
        ChatSessionSidebar(
            viewModel: self.viewModel,
            query: self.query,
            additionalAttentionRequests: self.additionalAttentionRequests)
        #else
        ChatSessionTouchList(
            viewModel: self.viewModel,
            query: self.query,
            additionalAttentionRequests: self.additionalAttentionRequests,
            onSelect: self.onSelect)
        #endif
    }
}

#if !os(macOS)
@MainActor
struct ChatSessionTouchList: View {
    @Bindable var viewModel: OpenClawChatViewModel
    @Binding var query: String
    let additionalAttentionRequests: [OpenClawChatAttentionRequest]
    let onSelect: (@MainActor (OpenClawChatSessionEntry) -> Void)?

    @State private var presentedAttention: OpenClawChatAttentionPresentation?
    @State private var sessionPendingDeletion: OpenClawChatSessionEntry?
    @State private var sessionPendingRename: OpenClawChatSessionEntry?
    @State private var renameText = ""
    @State private var groups: [OpenClawChatSessionGroup] = []
    @State private var inspectedSession: OpenClawChatSessionEntry?
    @State private var isPresentingGroups = false
    @State private var isPresentingAllThreads = false
    @State private var isPresentingNewSessionOptions = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            self.list(now: context.date)
        }
    }

    private var routingContract: String? {
        self.viewModel.agentCatalog?.sessionRoutingContract ?? self.viewModel.sessionRoutingContract
    }

    private func list(now: Date) -> some View {
        let sections = ChatSessionSidebarModel.sections(
            sessions: self.viewModel.sessions,
            currentSessionKey: self.viewModel.sessionKey,
            mainSessionKey: self.viewModel.selectedAgentMainSessionKey,
            activeAgentID: self.viewModel.selectedAgentID,
            groups: self.groups,
            query: self.query,
            sessionRoutingContract: self.routingContract)
        let selectedKey = ChatSessionSidebarModel.selectedSessionKey(
            sessions: self.viewModel.sessions,
            currentSessionKey: self.viewModel.sessionKey,
            mainSessionKey: self.viewModel.selectedAgentMainSessionKey,
            activeAgentID: self.viewModel.selectedAgentID,
            sessionRoutingContract: self.routingContract)
        return List {
            ForEach(sections) { section in
                Section {
                    ForEach(self.flattened(section.nodes), id: \.node.id) { item in
                        self.row(item.node, depth: item.depth, isSelected: item.node.session.key == selectedKey, now: now)
                    }
                } header: {
                    Text(self.sectionTitle(section))
                        .font(OpenClawChatTypography.caption)
                }
            }
            if sections.isEmpty {
                Text(self.query.isEmpty
                    ? String(localized: "No threads yet")
                    : String(localized: "No matching threads"))
                    .font(OpenClawChatTypography.caption)
                    .foregroundStyle(.secondary)
            }
            if self.query.isEmpty {
                ChatSessionPagingFooter(viewModel: self.viewModel)
            }
        }
        .modifier(ChatSessionListStyle())
        .searchable(text: self.$query, prompt: String(localized: "Search threads"))
        .refreshable {
            self.viewModel.refreshSessions(limit: OpenClawChatViewModel.sessionListFetchLimit)
        }
        .toolbar { self.toolbar }
        .task(id: self.groupRefreshID) {
            self.viewModel.refreshSessions(limit: OpenClawChatViewModel.sessionListFetchLimit)
            if let groups = try? await self.viewModel.fetchSessionGroups() {
                self.groups = groups
            }
        }
        .sheet(item: self.$inspectedSession) { session in
            ChatSessionInspectorSheet(viewModel: self.viewModel, session: session)
        }
        .sheet(isPresented: self.$isPresentingGroups) {
            ChatSessionGroupsSheet(viewModel: self.viewModel)
        }
        .sheet(isPresented: self.$isPresentingAllThreads) {
            ChatSessionsSheet(viewModel: self.viewModel)
        }
        .sheet(isPresented: self.$isPresentingNewSessionOptions) {
            ChatNewSessionOptionsPopover(viewModel: self.viewModel) {
                self.isPresentingNewSessionOptions = false
            }
            .presentationDetents([.medium])
        }
        .alert(String(localized: "Rename Thread"), isPresented: self.isPresentingRenameAlert) {
            TextField(String(localized: "Thread name"), text: self.$renameText)
            Button(String(localized: "Rename")) {
                if let session = self.sessionPendingRename {
                    self.viewModel.renameSession(key: session.key, label: self.renameText, agentID: session.agentId)
                }
                self.sessionPendingRename = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                self.sessionPendingRename = nil
            }
        }
        .confirmationDialog(self.deleteDialogTitle, isPresented: self.isPresentingDeleteDialog) {
            Button(String(localized: "Delete Thread"), role: .destructive) {
                if let session = self.sessionPendingDeletion {
                    self.viewModel.deleteSession(session.key, agentID: session.agentId)
                }
                self.sessionPendingDeletion = nil
            }
        } message: {
            Text(String(localized: "The thread and its transcript are removed from the gateway."))
                .font(OpenClawChatTypography.body)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    self.isPresentingNewSessionOptions = true
                } label: {
                    Label(String(localized: "New Thread Options…"), systemImage: "slider.horizontal.3")
                }
                Button {
                    self.isPresentingGroups = true
                } label: {
                    Label(String(localized: "Groups"), systemImage: "folder")
                }
                Button {
                    self.isPresentingAllThreads = true
                } label: {
                    Label(String(localized: "All Threads…"), systemImage: "rectangle.stack")
                }
            } label: {
                Label(String(localized: "New Thread"), systemImage: "square.and.pencil")
            } primaryAction: {
                Task { await self.viewModel.startNewSession() }
            }
            .disabled(self.viewModel.isCreatingSession)
            .accessibilityIdentifier("chat-new-thread")
        }
    }

    private struct FlatNode {
        let node: ChatSessionSidebarModel.Node
        let depth: Int
    }

    /// Subagent children render indented under their parent (the macOS sidebar uses an OutlineGroup).
    private func flattened(_ nodes: [ChatSessionSidebarModel.Node], depth: Int = 0) -> [FlatNode] {
        nodes.flatMap { node in
            [FlatNode(node: node, depth: depth)] + self.flattened(node.children, depth: min(depth + 1, 3))
        }
    }

    private func sectionTitle(_ section: ChatSessionSidebarModel.Section) -> String {
        guard let title = section.title else { return String(localized: "Recent") }
        return title
    }

    private func row(
        _ node: ChatSessionSidebarModel.Node,
        depth: Int,
        isSelected: Bool,
        now: Date) -> some View
    {
        let session = node.session
        let attention = self.attentionSummary(sessions: [session] + node.children.map(\.session), now: now)
        let timestamp = ChatSessionSidebarModel.activityTimestamp(for: session).map {
            Date(timeIntervalSince1970: $0 / 1000).formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        }
        let subtitle = self.rowSubtitle(for: session, now: now)
        return Button {
            self.select(session)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ChatSessionSidebarModel.displayName(for: session))
                        .font(OpenClawChatTypography.body(
                            size: 15, weight: session.unread == true ? .semibold : .regular, relativeTo: .body))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(OpenClawChatTypography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    if let timestamp {
                        Text(verbatim: timestamp)
                            .font(OpenClawChatTypography.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 5) {
                        if let attention {
                            OpenClawChatAttentionBadge(
                                summary: attention,
                                targetID: "session:\(session.key)",
                                presentation: self.$presentedAttention)
                        }
                        self.badges(for: node)
                    }
                }
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.vertical, 2)
            .overlay(alignment: .leading) {
                OpenClawSessionColorStripe(color: session.color)
                    .offset(x: -8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? OpenClawChatTheme.accent.opacity(0.10) : nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chat-session-\(session.key)")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                self.viewModel.setSessionPinned(key: session.key, pinned: !session.isPinned, agentID: session.agentId)
            } label: {
                Label(
                    session.isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
                    systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            .tint(OpenClawChatTheme.accent)
            Button {
                self.viewModel.setSessionUnread(key: session.key, unread: session.unread != true, agentID: session.agentId)
            } label: {
                Label(
                    session.unread == true ? String(localized: "Mark Read") : String(localized: "Mark Unread"),
                    systemImage: session.unread == true ? "envelope.open" : "envelope.badge")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if ChatSessionSidebarModel.canDeleteSession(
                key: session.key,
                mainSessionKey: self.viewModel.selectedAgentMainSessionKey)
            {
                Button(role: .destructive) {
                    self.sessionPendingDeletion = session
                } label: {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
            }
            if ChatSessionSidebarModel.canArchiveSession(
                session,
                mainSessionKey: self.viewModel.selectedAgentMainSessionKey)
            {
                Button {
                    self.viewModel.setSessionArchived(session, archived: !session.isArchived)
                } label: {
                    Label(
                        session.isArchived ? String(localized: "Restore") : String(localized: "Archive"),
                        systemImage: session.isArchived ? "tray.and.arrow.up" : "archivebox")
                }
                .tint(.orange)
            }
        }
        .contextMenu { self.contextMenu(for: session) }
    }

    @ViewBuilder
    private func badges(for node: ChatSessionSidebarModel.Node) -> some View {
        if self.viewModel.healthOK, node.badges.queuedCount > 0 {
            Image(systemName: "hourglass")
                .foregroundStyle(OpenClawChatTheme.warning)
                .accessibilityLabel(String(localized: "Thread queued"))
        }
        if self.viewModel.healthOK, node.badges.runningCount > 0 {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Thread running"))
        }
        if node.badges.failedCount > 0 {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OpenClawChatTheme.warning)
                .accessibilityLabel(String(localized: "Thread failed"))
        }
        if node.session.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Pinned"))
        }
        let isCurrentSession = self.viewModel.matchesCurrentSessionKey(
            incoming: node.session.key,
            current: self.viewModel.sessionKey)
        if node.children.contains(where: \.badges.hasUnread) || (node.session.unread == true && !isCurrentSession) {
            Circle()
                .fill(.tint)
                .frame(width: 8, height: 8)
                .accessibilityLabel(String(localized: "Unread"))
        }
    }

    @ViewBuilder
    private func contextMenu(for session: OpenClawChatSessionEntry) -> some View {
        Button {
            self.inspectedSession = session
        } label: {
            Label(String(localized: "Get Info…"), systemImage: "info.circle")
        }
        Button {
            self.renameText = session.label ?? session.displayName ?? ""
            self.sessionPendingRename = session
        } label: {
            Label(String(localized: "Rename…"), systemImage: "pencil")
        }
        Button {
            Task {
                await self.viewModel.forkSession(
                    key: session.key,
                    fromLastCompleted: session.hasActiveRun == true,
                    agentID: session.agentId)
            }
        } label: {
            Label(
                session.hasActiveRun == true
                    ? String(localized: "Fork from last completed message")
                    : String(localized: "Fork"),
                systemImage: "arrow.triangle.branch")
        }
        OpenClawSessionColorMenu(color: session.color) { color in
            Task { await self.viewModel.setSessionColor(key: session.key, color: color, agentID: session.agentId) }
        }
        Button {
            ChatPasteboard.copy(session.key)
        } label: {
            Label(String(localized: "Copy Session Key"), systemImage: "doc.on.doc")
        }
    }

    private func select(_ session: OpenClawChatSessionEntry) {
        if session.isArchived {
            // Archived sessions reject new sends; restore before switching (upstream ChatSessionsSheet).
            Task {
                guard await self.viewModel.restoreSession(session) else { return }
                self.viewModel.switchSession(to: session.key, agentID: session.agentId)
                self.onSelect?(session)
            }
            return
        }
        if session.key != self.viewModel.sessionKey {
            self.viewModel.switchSession(to: session.key, agentID: session.agentId)
        }
        self.onSelect?(session)
    }

    private func attentionSummary(
        sessions: [OpenClawChatSessionEntry],
        now: Date) -> OpenClawChatAttentionSummary?
    {
        ChatSessionSidebarModel.attentionSummary(
            requests: self.viewModel.pendingQuestionAttentionRequests + self.additionalAttentionRequests,
            sessions: sessions,
            mainSessionKey: self.viewModel.selectedAgentMainSessionKey,
            activeAgentID: self.viewModel.selectedAgentID,
            sessionRoutingContract: self.routingContract,
            now: now)
    }

    private func rowSubtitle(for session: OpenClawChatSessionEntry, now: Date) -> String? {
        let nowMs = now.timeIntervalSince1970 * 1000
        let activity = ChatSessionSidebarModel.activity(for: session, now: nowMs)
        if let activity, activity.kind == .attention { return activity.text }
        if self.viewModel.healthOK, let activity, [.running, .queued].contains(activity.kind) { return activity.text }
        if self.viewModel.matchesCurrentSessionKey(
            incoming: session.key, agentId: session.agentId, current: self.viewModel.sessionKey),
            let current = ChatSessionSidebarModel.messagePreview(from: self.viewModel.messages)
        { return current }
        let workSubtitle = ChatSessionSidebarModel.workSubtitle(for: session)
        return ChatSessionSidebarModel.subtitle(for: session, workSubtitle: workSubtitle, now: nowMs)
    }

    private var groupRefreshID: String {
        let categories = self.viewModel.sessions.compactMap(\.category).sorted().joined(separator: "|")
        return "\(self.viewModel.healthOK)|\(categories)|\(self.viewModel.sessionGroupsRevision)"
    }

    private var deleteDialogTitle: String {
        let name = self.sessionPendingDeletion.map(ChatSessionSidebarModel.displayName(for:)) ?? ""
        return String(format: String(localized: "Delete “%@”?"), name)
    }

    private var isPresentingDeleteDialog: Binding<Bool> {
        Binding(
            get: { self.sessionPendingDeletion != nil },
            set: { if !$0 { self.sessionPendingDeletion = nil } })
    }

    private var isPresentingRenameAlert: Binding<Bool> {
        Binding(
            get: { self.sessionPendingRename != nil },
            set: { if !$0 { self.sessionPendingRename = nil } })
    }
}

private struct ChatSessionListStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.listStyle(.insetGrouped)
        #else
        content.listStyle(.sidebar)
        #endif
    }
}
#endif

/// "Showing N of M" footer with a Load More action when the gateway truncated the session list.
@MainActor
struct ChatSessionPagingFooter: View {
    let viewModel: OpenClawChatViewModel

    var body: some View {
        if let status = ChatSessionPagingStatus(
            loadedCount: self.viewModel.sessions.count,
            totalCount: self.viewModel.sessionsTotalCount,
            isTruncated: self.viewModel.sessionsListIsTruncated)
        {
            HStack(spacing: 8) {
                Text(status.summary)
                    .font(OpenClawChatTypography.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    self.viewModel.loadMoreSessions()
                } label: {
                    if self.viewModel.isLoadingMoreSessions {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(String(localized: "Load More"))
                            .font(OpenClawChatTypography.captionSemiBold)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(self.viewModel.isLoadingMoreSessions)
                .accessibilityIdentifier("chat-sessions-load-more")
            }
        }
    }
}
#endif

/// Paging summary for a possibly truncated session list (`sessions.list` `totalCount` / `hasMore`).
struct ChatSessionPagingStatus: Equatable {
    let loadedCount: Int
    let totalCount: Int?

    /// `nil` when every row is loaded.
    init?(loadedCount: Int, totalCount: Int?, isTruncated: Bool) {
        let knownMore = totalCount.map { loadedCount < $0 } ?? false
        guard isTruncated || knownMore else { return nil }
        self.loadedCount = loadedCount
        self.totalCount = totalCount.map { max($0, loadedCount) }
    }

    var summary: String {
        if let totalCount {
            return String(
                format: String(localized: "Showing %1$@ of %2$@ threads"),
                self.loadedCount.formatted(),
                totalCount.formatted())
        }
        return String(format: String(localized: "Showing %@ threads"), self.loadedCount.formatted())
    }
}
