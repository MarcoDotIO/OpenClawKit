import Foundation
import OpenClawKit
import OpenClawProtocol
import Testing
@testable import OpenClawChatUI
#if canImport(SwiftUI)
import SwiftUI
#endif

// Tests for the SDK-specific chat shell additions (not in upstream OpenClaw): ui.prefs mapping, the provider-catalog
// thinking fallback, Apple Foundation Models rules, session paging, group reordering, the capability catalog builder,
// Listen clip mapping and composer paste / Image Playground helpers.

private final class ShellTestTransport: @unchecked Sendable, OpenClawChatTransport {
    private let lock = NSLock()
    private var requestedLimits: [Int?] = []
    private let sessionsResponse: OpenClawChatSessionsListResponse

    init(sessionsResponse: OpenClawChatSessionsListResponse) {
        self.sessionsResponse = sessionsResponse
    }

    var limits: [Int?] {
        self.lock.withLock { self.requestedLimits }
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        .init(sessionKey: sessionKey, sessionId: nil, messages: [], thinkingLevel: nil)
    }

    func sendMessage(
        sessionKey _: String, message _: String, thinking _: String, idempotencyKey: String,
        attachments _: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        .init(runId: idempotencyKey, status: "started")
    }

    func requestHealth(timeoutMs _: Int) async throws -> Bool {
        true
    }

    func listSessions(
        limit: Int?,
        search _: String?,
        archived _: Bool,
        agentID _: String?) async throws -> OpenClawChatSessionsListResponse
    {
        self.lock.withLock { self.requestedLimits.append(limit) }
        return self.sessionsResponse
    }

    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { $0.finish() }
    }
}

private func sessionEntry(key: String, model: String? = nil, provider: String? = nil) throws -> OpenClawChatSessionEntry {
    var object: [String: String] = ["key": key]
    object["model"] = model
    object["modelProvider"] = provider
    return try JSONDecoder().decode(OpenClawChatSessionEntry.self, from: JSONEncoder().encode(object))
}

struct ChatUIPreferencesTests {
    @Test func `ui prefs map display, send shortcut, theme and accent`() {
        var ui = OpenClawConfigDocument.UI()
        var prefs = OpenClawConfigDocument.UI.Prefs()
        prefs.chatShowThinking = false
        prefs.chatShowToolCalls = true
        prefs.chatSendShortcut = "modifier-enter"
        prefs.themeMode = .dark
        prefs.accent = "#FBBF24"
        ui.prefs = prefs
        ui.seamColor = "#112233"

        let preferences = OpenClawChatUIPreferences(ui: ui)
        #expect(preferences.showsThinking == false)
        #expect(preferences.showsToolCalls == true)
        #expect(preferences.sendRequiresModifier)
        #expect(preferences.accentHex == "#fbbf24")
        #expect(preferences.displayOptions(fallback: .assistantTrace) == [.toolActivity])
        #expect(preferences.displayOptions(fallback: []) == [.toolActivity])
        #if canImport(SwiftUI)
        #expect(preferences.colorScheme == .dark)
        #expect(preferences.accentColor != nil)
        #endif
    }

    @Test func `system and unknown theme modes follow the host`() {
        #if canImport(SwiftUI)
        #expect(OpenClawChatUIPreferences(themeMode: .system).colorScheme == nil)
        #expect(OpenClawChatUIPreferences(themeMode: .init(rawValue: "sepia")).colorScheme == nil)
        #expect(OpenClawChatUIPreferences(themeMode: .light).colorScheme == .light)
        #expect(OpenClawChatUIPreferences().colorScheme == nil)
        #endif
    }

    @Test func `unset preferences keep the fallback options and invalid accents drop`() {
        let preferences = OpenClawChatUIPreferences(accentHex: "not-a-color")
        #expect(preferences.accentHex == nil)
        #expect(preferences.displayOptions(fallback: .assistantTrace) == .assistantTrace)
        #expect(!preferences.sendRequiresModifier)
        #expect(OpenClawChatUIPreferences(ui: nil) == OpenClawChatUIPreferences())
    }

    @Test func `seam color is the accent fallback`() {
        var ui = OpenClawConfigDocument.UI()
        ui.seamColor = "#112233"
        #expect(OpenClawChatUIPreferences(ui: ui).accentHex == "#112233")
    }
}

#if os(macOS)
struct ChatComposerSendShortcutTests {
    @Test func `return sends and shift-return breaks by default`() {
        #expect(ChatComposerKeyRouting.returnAction(modifierFlags: [], sendRequiresModifier: false) == .send)
        #expect(ChatComposerKeyRouting.returnAction(modifierFlags: [.shift], sendRequiresModifier: false) ==
            .insertNewline)
    }

    @Test func `modifier-enter sends only with command or control`() {
        #expect(ChatComposerKeyRouting.returnAction(modifierFlags: [], sendRequiresModifier: true) == .insertNewline)
        #expect(ChatComposerKeyRouting.returnAction(modifierFlags: [.shift], sendRequiresModifier: true) ==
            .insertNewline)
        #expect(ChatComposerKeyRouting.returnAction(modifierFlags: [.command], sendRequiresModifier: true) == .send)
        #expect(ChatComposerKeyRouting.returnAction(modifierFlags: [.control], sendRequiresModifier: true) == .send)
    }
}
#endif

@MainActor
struct ChatThinkingCatalogFallbackTests {
    private func viewModel(model: String, provider: String) throws -> OpenClawChatViewModel {
        let viewModel = OpenClawChatViewModel(
            sessionKey: "main",
            transport: ShellTestTransport(sessionsResponse: .init(ts: nil, path: nil, count: 0, defaults: nil, sessions: [])))
        viewModel.sessions = try [sessionEntry(key: "main", model: model, provider: provider)]
        return viewModel
    }

    @Test func `catalog profile drives the picker when the gateway sends no levels`() throws {
        let viewModel = try self.viewModel(model: "gpt-5.4", provider: "openai")
        viewModel.syncThinkingLevelOptions()

        let expected = OpenClawReferenceProviderCatalog.thinkingProfile(providerID: "openai", modelID: "gpt-5.4")
        #expect(!expected.levels.isEmpty)
        #expect(viewModel.thinkingLevelOptions.map(\.id) == expected.levels.map(\.rawValue))
        #expect(viewModel.thinkingLevelOptions.first { $0.id == "xhigh" }?.label == "Extra High")
        #expect(viewModel.showsThinkingPicker)
    }

    @Test func `disabling the fallback restores the gateway-only policy`() throws {
        let viewModel = try self.viewModel(model: "gpt-5.4", provider: "openai")
        viewModel.usesCatalogThinkingFallback = false
        #expect(viewModel.thinkingLevelOptions.isEmpty)
        #expect(!viewModel.showsThinkingPicker)
    }

    @Test func `unknown catalog models show no synthesized levels`() throws {
        let viewModel = try self.viewModel(model: "house-model", provider: "fixture")
        viewModel.syncThinkingLevelOptions()
        #expect(viewModel.thinkingLevelOptions.isEmpty)
        #expect(!viewModel.showsThinkingPicker)
    }

    @Test func `apple fm on-device hides thinking even with gateway levels`() throws {
        let viewModel = OpenClawChatViewModel(
            sessionKey: "main",
            transport: ShellTestTransport(sessionsResponse: .init(ts: nil, path: nil, count: 0, defaults: nil, sessions: [])))
        viewModel.sessions = try [JSONDecoder().decode(OpenClawChatSessionEntry.self, from: Data(
            #"{"key":"main","model":"system","modelProvider":"apple-fm","thinkingLevels":[{"id":"off","label":"off"},{"id":"high","label":"high"}]}"#
                .utf8))]
        viewModel.syncThinkingLevelOptions()
        #expect(!viewModel.showsThinkingPicker)
    }

    @Test func `apple fm rules distinguish on-device from private cloud compute`() {
        #expect(OpenClawChatViewModel.hidesThinkingControl(providerID: "apple-fm", modelID: "system"))
        #expect(OpenClawChatViewModel.hidesThinkingControl(providerID: "foundation", modelID: "apple-foundation-default"))
        #expect(!OpenClawChatViewModel.hidesThinkingControl(providerID: "apple-fm", modelID: "private-cloud-compute"))
        #expect(!OpenClawChatViewModel.hidesThinkingControl(providerID: "openai", modelID: "system"))
        #expect(OpenClawChatViewModel.isPrivateCloudComputeModel(providerID: "apple-fm", modelID: "pcc"))
        #expect(OpenClawChatViewModel.isPrivateCloudComputeModel(providerID: "foundation", modelID: "private-cloud-compute"))
        #expect(!OpenClawChatViewModel.isPrivateCloudComputeModel(providerID: "apple-fm", modelID: "system"))
    }

    @Test func `model reference prefers the explicit provider and strips its prefix`() throws {
        let session = try sessionEntry(key: "main", model: "openai/gpt-5.4", provider: "openai")
        #expect(OpenClawChatViewModel.thinkingModelReference(session: session, defaults: nil, modelChoice: nil) ==
            .init(providerID: "openai", modelID: "gpt-5.4", agentRuntime: nil))
        let bare = try sessionEntry(key: "main", model: "anthropic/claude-opus-4-7")
        #expect(OpenClawChatViewModel.thinkingModelReference(session: bare, defaults: nil, modelChoice: nil)?
            .providerID == "anthropic")
        let unqualified = try sessionEntry(key: "main", model: "gpt-5.4")
        #expect(OpenClawChatViewModel.thinkingModelReference(session: unqualified, defaults: nil, modelChoice: nil) == nil)
    }
}

struct ChatPrivateCloudQuotaNoticeTests {
    @Test func `notice appears only for an exhausted private cloud compute quota`() {
        #expect(ChatPrivateCloudQuotaNotice(
            isPrivateCloudComputeSelected: false,
            quota: FoundationModelsQuotaSnapshot(limitReached: true)) == nil)
        #expect(ChatPrivateCloudQuotaNotice(
            isPrivateCloudComputeSelected: true,
            quota: FoundationModelsQuotaSnapshot(limitReached: false, approachingLimit: true)) == nil)
        #expect(ChatPrivateCloudQuotaNotice(isPrivateCloudComputeSelected: true, quota: nil) == nil)

        let now = Date(timeIntervalSince1970: 1_000_000)
        let notice = ChatPrivateCloudQuotaNotice(
            isPrivateCloudComputeSelected: true,
            quota: FoundationModelsQuotaSnapshot(
                limitReached: true,
                resetDate: now.addingTimeInterval(3600),
                canRequestIncrease: true),
            now: now)
        #expect(notice?.canRequestIncrease == true)
        #expect(notice?.message.hasPrefix("Private Cloud Compute limit reached") == true)
        #expect(notice?.message.contains("resets") == true)
    }

    @MainActor
    private func privateCloudViewModel() throws -> OpenClawChatViewModel {
        let viewModel = OpenClawChatViewModel(
            sessionKey: "main",
            transport: ShellTestTransport(sessionsResponse: .init(ts: nil, path: nil, count: 0, defaults: nil, sessions: [])))
        viewModel.sessions = try [sessionEntry(key: "main", model: "private-cloud-compute", provider: "apple-fm")]
        return viewModel
    }

    @MainActor
    @Test func `remote gateway chats never read this device's quota`() throws {
        // Default: no in-process quota provider, so an exhausted local quota must not show a notice or
        // the local limit-increase offer for runs a remote gateway executes.
        let viewModel = try self.privateCloudViewModel()
        #expect(viewModel.isPrivateCloudComputeSelected)
        #expect(viewModel.privateCloudQuotaProvider == nil)
        #expect(viewModel.privateCloudQuotaNotice() == nil)
    }

    @MainActor
    @Test func `in process quota provider drives the notice only while pcc is selected`() throws {
        final class CallCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() { self.lock.withLock { self.count += 1 } }
            var value: Int { self.lock.withLock { self.count } }
        }
        let calls = CallCounter()
        let viewModel = try self.privateCloudViewModel()
        viewModel.privateCloudQuotaProvider = {
            calls.increment()
            return FoundationModelsQuotaSnapshot(limitReached: true, canRequestIncrease: true)
        }
        let notice = try #require(viewModel.privateCloudQuotaNotice())
        #expect(notice.canRequestIncrease)
        #expect(calls.value == 1)

        viewModel.sessions = try [sessionEntry(key: "main", model: "system", provider: "apple-fm")]
        #expect(!viewModel.isPrivateCloudComputeSelected)
        #expect(viewModel.privateCloudQuotaNotice() == nil)
        #expect(calls.value == 1)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChatSessionPagingTests {
    @Test func `paging status summarizes truncated lists only`() {
        #expect(ChatSessionPagingStatus(loadedCount: 10, totalCount: 10, isTruncated: false) == nil)
        #expect(ChatSessionPagingStatus(loadedCount: 10, totalCount: nil, isTruncated: false) == nil)
        let withTotal = ChatSessionPagingStatus(loadedCount: 200, totalCount: 523, isTruncated: true)
        #expect(withTotal?.summary == "Showing 200 of 523 threads")
        let implicit = ChatSessionPagingStatus(loadedCount: 5, totalCount: 9, isTruncated: false)
        #expect(implicit?.totalCount == 9)
        let unknownTotal = ChatSessionPagingStatus(loadedCount: 50, totalCount: nil, isTruncated: true)
        #expect(unknownTotal?.summary == "Showing 50 threads")
    }

    @Test func `load more grows the limit and later refreshes keep the paged rows`() async throws {
        let rows = try (0..<3).map { try sessionEntry(key: "s\($0)") }
        let transport = ShellTestTransport(sessionsResponse: OpenClawChatSessionsListResponse(
            ts: nil, path: nil, count: rows.count, totalCount: 900, offset: 0, nextOffset: 3, hasMore: true,
            defaults: nil, sessions: rows))
        let viewModel = OpenClawChatViewModel(sessionKey: "main", transport: transport)

        await viewModel.fetchSessions(limit: 200)
        #expect(viewModel.sessionsListIsTruncated)
        #expect(viewModel.sessionsTotalCount == 900)

        viewModel.loadMoreSessions()
        try await waitUntil("load more finished") {
            await MainActor.run { !viewModel.isLoadingMoreSessions }
        }
        let pagedLimit = OpenClawChatViewModel.sessionListFetchLimit + OpenClawChatViewModel.sessionListPageSize
        #expect(transport.limits.last == .some(pagedLimit))

        await viewModel.fetchSessions(limit: 50)
        #expect(transport.limits.last == .some(pagedLimit))
        await viewModel.fetchSessions(limit: nil)
        #expect(transport.limits.last == .some(nil))
    }

    @Test func `group reorder keeps unknown names out and missing names last`() {
        #expect(OpenClawChatViewModel.reorderedGroupCatalog(
            current: ["Work", "Home", "Later"],
            requested: ["Later", "Gone", "Work", "Later"]) == ["Later", "Work", "Home"])
        #expect(OpenClawChatViewModel.reorderedGroupCatalog(current: [], requested: ["A"]).isEmpty)
    }
}

struct ChatComposerCapabilityCatalogBuilderTests {
    private let admin = OpenClawChatComposerCapabilityAccess(
        operatorScopes: ["operator.admin"],
        sessionsPatchAdvertised: true,
        sessionSettingsContract: true,
        sessionSettingsCAS: true)

    private let config = Data(#"""
    {"runtimeConfig":{"mcp":{"servers":{"github":{"enabled":true},"linear":{"enabled":false}}},
     "tools":{"web":{"search":{"enabled":false}}}}}
    """#.utf8)

    private let tools = Data(#"""
    {"agentId":"main","profile":"default","groups":[{"id":"mcp","label":"MCP","source":"mcp","tools":[
      {"id":"github__search","label":"Search","description":"","rawDescription":"","source":"mcp",
       "mcpServer":"github","mcpToolName":"search"},
      {"id":"github__search_dup","label":"","description":"","rawDescription":"","source":"mcp",
       "mcpServer":"github","mcpToolName":"search","deniedBySession":true},
      {"id":"notes__read","label":"","description":"","rawDescription":"","source":"mcp",
       "mcpServer":"notes","mcpToolName":"read","deniedBySession":true},
      {"id":"exec","label":"Exec","description":"","rawDescription":"","source":"core"}]}],
     "notices":[{"id":"n1","severity":"warning","message":"Notes server restarting","servers":["notes"]}]}
    """#.utf8)

    @Test func `catalog joins configured servers with effective mcp tools`() {
        let catalog = OpenClawChatComposerCapabilityCatalog.build(
            config: .loaded(self.config),
            skills: .unavailable,
            tools: .loaded(self.tools),
            access: self.admin)

        #expect(catalog.connectors.map(\.name) == ["github", "linear", "notes"])
        #expect(catalog.connectors.first { $0.name == "linear" }?.baseEnabled == false)
        #expect(catalog.connectors.first { $0.name == "github" }?.tools.map(\.name) == ["search"])
        let notes = catalog.connectors.first { $0.name == "notes" }
        #expect(notes?.tools.first?.label == "read")
        #expect(notes?.tools.first?.sessionDenied == true)
        #expect(notes?.notice == "Notes server restarting")
        #expect(!catalog.webSearchBaseEnabled)
        #expect(catalog.webSearchAvailable)
        #expect(catalog.connectorsAvailable)
        #expect(catalog.toolAccessAvailable)
        #expect(!catalog.skillsAvailable)
        #expect(catalog.loadFailureMessage == nil)
        #expect(catalog.permissionMutationAvailable)
        #expect(catalog.canSelectFullPermission)
        #expect(catalog.toolOverrideMutationAvailable)
    }

    @Test func `write scope may change permissions but not select full or override tools`() {
        let catalog = OpenClawChatComposerCapabilityCatalog.build(
            config: .unavailable,
            skills: .unavailable,
            tools: .unavailable,
            access: .init(
                operatorScopes: ["operator.write"],
                sessionsPatchAdvertised: true,
                sessionSettingsContract: true,
                sessionSettingsCAS: true))
        #expect(catalog.sessionSettingsAvailable)
        #expect(catalog.permissionMutationAvailable)
        #expect(!catalog.canSelectFullPermission)
        #expect(!catalog.toolOverrideMutationAvailable)
        #expect(catalog.modelMutationAvailable)
        #expect(!catalog.effortMutationAvailable)
    }

    @Test func `gateways without the CAS contract need an upgrade for overrides`() {
        let catalog = OpenClawChatComposerCapabilityCatalog.build(
            config: .failed,
            skills: .failed,
            tools: .unavailable,
            access: .init(
                operatorScopes: ["operator.admin"],
                sessionsPatchAdvertised: true,
                sessionSettingsContract: true,
                sessionSettingsCAS: false))
        #expect(!catalog.permissionMutationAvailable)
        #expect(catalog.toolOverrideMutationRequiresGatewayUpgrade)
        #expect(catalog.loadFailureMessage == "Could not load: Web Search and Connectors, Skills. Retry.")
    }

    @Test func `unlisted patch method keeps model and effort mutations available`() {
        #expect(OpenClawChatComposerCapabilityCatalog.mutationAvailable(methodSupport: nil, allowedByScope: false))
        #expect(!OpenClawChatComposerCapabilityCatalog.mutationAvailable(methodSupport: false, allowedByScope: true))
        #expect(OpenClawChatComposerCapabilityCatalog.mutationAvailable(methodSupport: true, allowedByScope: true))
    }
}

#if !os(watchOS)
struct ChatSpeechSynthesisTests {
    @Test func `gateway audio maps output formats to container hints`() {
        let clip = OpenClawChatSpeechClip(gatewayAudio: TalkGatewaySpeechAudio(
            data: Data([1, 2, 3]),
            provider: "elevenlabs",
            outputFormat: "mp3_44100_128"))
        #expect(clip.data == Data([1, 2, 3]))
        #expect(clip.outputFormat == "mp3_44100_128")
        #expect(clip.fileExtension == "mp3")
        #expect(OpenClawChatSpeechClip.containerExtension(outputFormat: "wav-24k") == "wav")
        #expect(OpenClawChatSpeechClip.containerExtension(outputFormat: "pcm_24000") == nil)
        #expect(OpenClawChatSpeechClip.containerExtension(outputFormat: nil) == nil)
        #expect(OpenClawChatSpeechClip(gatewayAudio: TalkGatewaySpeechAudio(
            data: Data([0]), provider: "p", outputFormat: "pcm_24000")).isHeaderlessAudio)
    }

    @Test func `on-device synthesis always defers to the local voice`() async {
        await #expect(throws: (any Error).self) {
            _ = try await OpenClawChatSpeechController.onDeviceSpeechSynthesis("hello")
        }
    }
}
#endif

#if os(iOS) || os(macOS) || os(visionOS)
struct ChatComposerInputHelperTests {
    @Test func `pasted images get stable names and mime types`() {
        let png = ChatPastedAttachment.imageMetadata(contentType: .png, index: 0)
        #expect(png.fileName == "pasted-image-1.png")
        #expect(png.mimeType == "image/png")
        let jpeg = ChatPastedAttachment.imageMetadata(contentType: .jpeg, index: 2)
        #expect(jpeg.fileName == "pasted-image-3.jpeg")
        #expect(jpeg.mimeType == "image/jpeg")
    }

    @Test func `only local media files paste as attachments`() {
        #expect(ChatPastedAttachment.acceptsFile(URL(fileURLWithPath: "/tmp/photo.heic")))
        #expect(ChatPastedAttachment.acceptsFile(URL(fileURLWithPath: "/tmp/clip.mov")))
        #expect(!ChatPastedAttachment.acceptsFile(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(!ChatPastedAttachment.acceptsFile(URL(string: "https://example.com/photo.png")!))
    }

    @Test func `image playground concepts come from a non-command draft`() {
        #expect(ChatImagePlaygroundSupport.concept(fromDraft: "  a red panda  ") == "a red panda")
        #expect(ChatImagePlaygroundSupport.concept(fromDraft: "/new") == nil)
        #expect(ChatImagePlaygroundSupport.concept(fromDraft: " \n ") == nil)
        #expect(ChatImagePlaygroundSupport.concept(fromDraft: String(repeating: "x", count: 900))?.count == 500)
    }

    @Test func `authenticated images load only http requests`() {
        #expect(ChatAuthenticatedImage<EmptyView>.isLoadable(URLRequest(url: URL(string: "https://gw.local/a.png")!)))
        #expect(!ChatAuthenticatedImage<EmptyView>.isLoadable(URLRequest(url: URL(fileURLWithPath: "/tmp/a.png"))))
    }
}
#endif

#if os(iOS)
struct ChatComposerIOSPasteSupportTests {
    @Test func `pasteboard items prefer png data and fall back to images`() {
        let items: [[String: Any]] = [
            ["public.jpeg": Data([1]), "public.png": Data([2])],
            ["public.utf8-plain-text": "hello"],
        ]
        let attachments = ChatComposerIOSPasteSupport.imageAttachments(items: items)
        #expect(attachments.count == 1)
        #expect(attachments.first?.data == Data([2]))
        #expect(attachments.first?.fileName == "pasted-image-1.png")
        #expect(attachments.first?.mimeType == "image/png")
    }
}
#endif

struct ChatSuggestedActionsTargetTests {
    private func message(
        _ role: String,
        _ text: String,
        provenance: OpenClawChatInputProvenance? = nil) -> OpenClawChatMessage
    {
        OpenClawChatMessage(
            role: role,
            content: [OpenClawChatMessageContent(type: "text", text: text, mimeType: nil, fileName: nil, content: nil)],
            timestamp: 1000,
            provenance: provenance)
    }

    @Test func `latest inbound message is the only suggested actions target`() {
        let user = self.message("user", "Book a table")
        let reply = self.message("assistant", "Call +1 555 0100 at 7pm")
        let thinkingOnly = self.message("assistant", "<think>plan</think>")
        let tool = self.message("toolResult", "ok")

        #expect(chatSuggestedActionsMessageID(in: [user, reply, thinkingOnly, tool]) == reply.id)
        #expect(chatSuggestedActionsMessageID(in: [reply, user]) == nil)
        #expect(chatSuggestedActionsMessageID(in: []) == nil)

        let external = self.message(
            "user",
            "Running late",
            provenance: OpenClawChatInputProvenance(kind: "external_user", sourceChannel: "telegram"))
        #expect(chatSuggestedActionsMessageID(in: [reply, external]) == external.id)
    }
}
