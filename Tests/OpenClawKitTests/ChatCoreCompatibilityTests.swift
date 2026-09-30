import Foundation
import OpenClawKit
import OpenClawProtocol
import Testing
@testable import OpenClawChatUI

// Coverage for the OpenClawKit 2026.3.0 chat-core deltas that upstream's own suites do not
// exercise: the legacy transport bridge, the protocol-v4 chat event union, `session.tool`
// events, session-list truncation, and the durable outbox error vocabulary.

private actor ChatCoreCallRecorder {
    private(set) var sessionLimits: [Int?] = []

    func recordSessionLimit(_ limit: Int?) {
        self.sessionLimits.append(limit)
    }
}

private func chatCoreSessionsResponse(hasMore: Bool? = nil, totalCount: Int? = nil) -> OpenClawChatSessionsListResponse {
    OpenClawChatSessionsListResponse(
        ts: nil,
        path: nil,
        count: 1,
        totalCount: totalCount,
        hasMore: hasMore,
        defaults: nil,
        sessions: [cacheSessionEntry(key: "main", updatedAt: 1)])
}

/// A conformer written against the pre-2026.3.0 contract: it only implements the legacy
/// `listModels()` / `listSessions(limit:)` requirements.
private struct LegacyListTransport: OpenClawChatTransport {
    let recorder: ChatCoreCallRecorder

    func listModels() async throws -> [OpenClawChatModelChoice] {
        [OpenClawChatModelChoice(modelID: "gpt-legacy", name: "Legacy", provider: "openai", contextWindow: nil)]
    }

    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse {
        await self.recorder.recordSessionLimit(limit)
        return chatCoreSessionsResponse()
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        OpenClawChatHistoryPayload(sessionKey: sessionKey, sessionId: nil, messages: [], thinkingLevel: "off")
    }

    func sendMessage(
        sessionKey _: String,
        message _: String,
        thinking _: String,
        idempotencyKey _: String,
        attachments _: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        OpenClawChatSendResponse(runId: "run-legacy", status: "started")
    }

    func requestHealth(timeoutMs _: Int) async throws -> Bool {
        true
    }

    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { $0.finish() }
    }
}

/// A 2026.3.0 conformer that pushes scripted events into the view model.
private final class ScriptedEventTransport: @unchecked Sendable, OpenClawChatTransport {
    private let stream: AsyncStream<OpenClawChatTransportEvent>
    private let continuation: AsyncStream<OpenClawChatTransportEvent>.Continuation
    private let sessions: OpenClawChatSessionsListResponse

    init(sessions: OpenClawChatSessionsListResponse = chatCoreSessionsResponse()) {
        var continuation: AsyncStream<OpenClawChatTransportEvent>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.sessions = sessions
    }

    func emit(_ event: OpenClawChatTransportEvent) {
        self.continuation.yield(event)
    }

    func listSessions(limit _: Int?, search _: String?, archived _: Bool) async throws
        -> OpenClawChatSessionsListResponse
    {
        self.sessions
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        OpenClawChatHistoryPayload(sessionKey: sessionKey, sessionId: "sess-main", messages: [], thinkingLevel: "off")
    }

    func sendMessage(
        sessionKey _: String,
        message _: String,
        thinking _: String,
        idempotencyKey _: String,
        attachments _: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        OpenClawChatSendResponse(runId: "run-local", status: "started")
    }

    func requestHealth(timeoutMs _: Int) async throws -> Bool {
        true
    }

    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        self.stream
    }
}

private func chatDelta(
    runID: String,
    deltaText: String? = nil,
    replace: Bool? = nil,
    snapshot: String? = nil) -> OpenClawChatTransportEvent
{
    let message = snapshot.map { text in
        AnyCodable([
            "role": AnyCodable("assistant"),
            "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable(text)])]),
        ])
    }
    return .chat(OpenClawChatEventPayload(
        runId: runID,
        sessionKey: "main",
        state: "delta",
        message: message,
        errorMessage: nil,
        deltaText: deltaText,
        replace: replace))
}

@MainActor
private func bootstrappedViewModel(_ transport: ScriptedEventTransport) async throws -> OpenClawChatViewModel {
    let viewModel = OpenClawChatViewModel(sessionKey: "main", transport: transport)
    viewModel.load()
    try await waitUntil("bootstrap") { await MainActor.run { viewModel.healthOK && !viewModel.isLoading } }
    return viewModel
}

@Suite("Chat core 2026.3.0 compatibility", .timeLimit(.minutes(1)))
struct ChatCoreCompatibilityTests {
    // MARK: Legacy transport bridge

    @Test
    func legacyListModelsBridgesOnlyUnscopedCatalogs() async throws {
        let transport: any OpenClawChatTransport = LegacyListTransport(recorder: ChatCoreCallRecorder())

        let models = try await transport.listModels(agentID: nil)
        #expect(models.map(\.modelID) == ["gpt-legacy"])

        let error = await #expect(throws: NSError.self) {
            try await transport.listModels(agentID: "research")
        }
        #expect(error?.localizedDescription == "models.list not supported by this transport")
    }

    @Test
    func legacyListSessionsBridgesPlainListingsAndForwardsTheLimit() async throws {
        let recorder = ChatCoreCallRecorder()
        let transport: any OpenClawChatTransport = LegacyListTransport(recorder: recorder)

        _ = try await transport.listSessions(limit: 25, search: nil, archived: false)
        _ = try await transport.listSessions(limit: nil, search: "   ", archived: false)
        #expect(await recorder.sessionLimits == [25, nil])

        await #expect(throws: NSError.self) {
            try await transport.listSessions(limit: 25, search: "invoice", archived: false)
        }
        await #expect(throws: NSError.self) {
            try await transport.listSessions(limit: 25, search: nil, archived: true)
        }
        #expect(await recorder.sessionLimits == [25, nil])
    }

    @Test
    func unimplementedOperationsFailWithANamedUnsupportedError() async {
        let transport: any OpenClawChatTransport = LegacyListTransport(recorder: ChatCoreCallRecorder())

        let error = await #expect(throws: NSError.self) {
            try await transport.abortRun(sessionKey: "main", runId: "run-1")
        }
        #expect(error?.domain == "OpenClawChatTransport")
        #expect(error?.localizedDescription == "chat.abort not supported by this transport")
    }

    @Test
    func legacyConformerBootstrapsTheViewModel() async throws {
        let recorder = ChatCoreCallRecorder()
        let transport = LegacyListTransport(recorder: recorder)
        let viewModel = await MainActor.run { OpenClawChatViewModel(sessionKey: "main", transport: transport) }

        await MainActor.run { viewModel.load() }
        try await waitUntil("legacy sessions listed") { await !recorder.sessionLimits.isEmpty }
        try await waitUntil("legacy models listed") {
            await MainActor.run { viewModel.modelChoices.map(\.modelID) == ["gpt-legacy"] }
        }
    }

    // MARK: Protocol-v4 chat event union

    @Test(arguments: [
        ("delta", OpenClawChatEventState.delta, false),
        ("final", .final, true),
        ("aborted", .aborted, true),
        ("error", .error, true),
        ("status", .status, false),
        (" FINAL ", .final, true),
        ("compacting", .unknown("compacting"), false),
    ])
    func chatEventStatesParseAndClassify(raw: String, expected: OpenClawChatEventState, terminal: Bool) {
        let state = OpenClawChatEventState(rawValue: raw)
        #expect(state == expected)
        #expect(state.isTerminal == terminal)
    }

    @Test
    func missingChatEventStateIsNonTerminal() {
        #expect(OpenClawChatEventState(rawValue: nil) == .missing)
        #expect(OpenClawChatEventState(rawValue: "  ") == .missing)
        #expect(!OpenClawChatEventState.missing.isTerminal)
    }

    @Test
    func v4DeltaFramesDecodeDeltaTextAndReplace() throws {
        let data = Data(#"""
        {"runId":"run-1","sessionKey":"main","seq":4,"state":"delta","deltaText":"lo","replace":true}
        """#.utf8)
        let payload = try JSONDecoder().decode(OpenClawChatEventPayload.self, from: data)

        #expect(payload.kind == .delta)
        #expect(payload.seq == 4)
        #expect(payload.deltaText == "lo")
        #expect(payload.replace == true)
        #expect(payload.message == nil)
    }

    @Test
    func v4TerminalFramesDecodeStopReasonAndYield() throws {
        let data = Data(#"""
        {"runId":"run-1","sessionKey":"main","state":"final","stopReason":"end_turn","yielded":true,
         "message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
        """#.utf8)
        let payload = try JSONDecoder().decode(OpenClawChatEventPayload.self, from: data)

        #expect(payload.kind == .final)
        #expect(payload.stopReason == "end_turn")
        #expect(payload.yielded == true)
        #expect(OpenClawChatEventText.assistantText(from: payload) == "done")
    }

    @Test
    func chatEventsWithMalformedStateFieldsStillDecode() throws {
        let data = Data(#"""
        {"runId":"run-1","sessionKey":"main","state":"status","seq":"four","deltaText":7,"replace":"yes",
         "phase":"retrying"}
        """#.utf8)
        let payload = try JSONDecoder().decode(OpenClawChatEventPayload.self, from: data)

        #expect(payload.kind == .status)
        #expect(payload.runId == "run-1")
        #expect(payload.seq == nil)
        #expect(payload.deltaText == nil)
        #expect(payload.replace == nil)
        #expect(payload.phase == "retrying")
    }

    @Test
    func viewModelAppendsReplacesAndPrefersSnapshotsForV4Deltas() async throws {
        let transport = ScriptedEventTransport()
        let viewModel = try await bootstrappedViewModel(transport)

        transport.emit(chatDelta(runID: "run-v4", deltaText: "Hel"))
        transport.emit(chatDelta(runID: "run-v4", deltaText: "lo"))
        try await waitUntil("appended delta") {
            await MainActor.run { viewModel.streamingAssistantText == "Hello" }
        }

        transport.emit(chatDelta(runID: "run-v4", deltaText: "Rewritten", replace: true))
        try await waitUntil("replaced delta") {
            await MainActor.run { viewModel.streamingAssistantText == "Rewritten" }
        }

        transport.emit(chatDelta(runID: "run-v4", deltaText: " ignored", snapshot: "Snapshot wins"))
        try await waitUntil("snapshot delta") {
            await MainActor.run { viewModel.streamingAssistantText == "Snapshot wins" }
        }

        transport.emit(chatDelta(runID: "run-v4", deltaText: "!"))
        try await waitUntil("delta appended to snapshot") {
            await MainActor.run { viewModel.streamingAssistantText == "Snapshot wins!" }
        }
        #expect(await MainActor.run { viewModel.pendingRunCount } == 1)
    }

    @Test
    func statusAndUnknownChatStatesNeverRetireTheRun() async throws {
        let transport = ScriptedEventTransport()
        let viewModel = try await bootstrappedViewModel(transport)

        transport.emit(chatDelta(runID: "run-v4", deltaText: "Working"))
        try await waitUntil("delta adopted") { await MainActor.run { viewModel.pendingRunCount == 1 } }

        for state in ["status", "compacting"] {
            transport.emit(.chat(OpenClawChatEventPayload(
                runId: "run-v4", sessionKey: "main", state: state, message: nil, errorMessage: nil,
                phase: "retrying")))
        }
        transport.emit(chatDelta(runID: "run-v4", deltaText: " still"))
        try await waitUntil("stream continued after status") {
            await MainActor.run { viewModel.streamingAssistantText == "Working still" }
        }
        #expect(await MainActor.run { viewModel.pendingRunCount } == 1)

        transport.emit(.chat(OpenClawChatEventPayload(
            runId: "run-v4", sessionKey: "main", state: "final", message: nil, errorMessage: nil,
            stopReason: "end_turn")))
        try await waitUntil("final retires the run") {
            await MainActor.run { viewModel.pendingRunCount == 0 && viewModel.streamingAssistantText == nil }
        }

        // A terminal frame drops the run's delta buffer; a later run starts clean.
        transport.emit(chatDelta(runID: "run-next", deltaText: "Fresh"))
        try await waitUntil("next run streams from an empty buffer") {
            await MainActor.run { viewModel.streamingAssistantText == "Fresh" }
        }
    }

    // MARK: session.tool events

    @Test
    func sessionToolFramesDecodeWithTheirSessionSnapshot() throws {
        let frame = EventFrame(
            type: "event",
            event: "session.tool",
            payload: AnyCodable([
                "runId": AnyCodable("run-remote"),
                "stream": AnyCodable("tool"),
                "ts": AnyCodable(1000),
                "data": AnyCodable([
                    "phase": AnyCodable("start"),
                    "name": AnyCodable("exec"),
                    "toolCallId": AnyCodable("call-1"),
                ]),
                "sessionKey": AnyCodable("agent:main:main"),
                "agentId": AnyCodable("main"),
            ]))

        guard case let .sessionTool(payload) = OpenClawChatGatewayPayloadCodec.event(from: frame) else {
            Issue.record("expected sessionTool")
            return
        }
        #expect(payload.runId == "run-remote")
        #expect(payload.stream == "tool")
        #expect(payload.sessionKey == "agent:main:main")
        #expect(payload.agentId == "main")
        #expect(payload.data["toolCallId"]?.stringValue == "call-1")
    }

    @Test
    func sessionToolEventsMirrorAnotherClientsToolActivity() async throws {
        let transport = ScriptedEventTransport()
        let viewModel = try await bootstrappedViewModel(transport)

        func toolEvent(sessionKey: String, phase: String) -> OpenClawChatTransportEvent {
            .sessionTool(OpenClawAgentEventPayload(
                runId: "run-remote",
                seq: 1,
                stream: "tool",
                ts: 1000,
                data: [
                    "phase": AnyCodable(phase),
                    "name": AnyCodable("exec"),
                    "toolCallId": AnyCodable("call-\(sessionKey)"),
                ],
                sessionKey: sessionKey,
                agentId: nil))
        }

        transport.emit(toolEvent(sessionKey: "other", phase: "start"))
        transport.emit(toolEvent(sessionKey: "main", phase: "start"))
        try await waitUntil("tool started") {
            await MainActor.run { viewModel.pendingToolCalls.map(\.toolCallId) == ["call-main"] }
        }

        transport.emit(toolEvent(sessionKey: "main", phase: "result"))
        try await waitUntil("tool finished") { await MainActor.run { viewModel.pendingToolCalls.isEmpty } }
    }

    // MARK: Session list paging

    @Test(arguments: [
        (Bool?.none, Int?.none, false),
        (true, nil, true),
        (false, 1, false),
        (nil, 5, true),
    ])
    func sessionListsReportTruncation(hasMore: Bool?, totalCount: Int?, truncated: Bool) {
        #expect(chatCoreSessionsResponse(hasMore: hasMore, totalCount: totalCount).isTruncated == truncated)
    }

    @Test
    func viewModelPublishesSessionListTruncation() async throws {
        let transport = ScriptedEventTransport(sessions: chatCoreSessionsResponse(totalCount: 40))
        let viewModel = try await bootstrappedViewModel(transport)

        try await waitUntil("sessions loaded") { await MainActor.run { viewModel.sessionsListIsTruncated } }
    }

    @Test
    func newCommandSessionsEmitCommandHooks() {
        let request = OpenClawChatGatewayRequests.createSessionFromNewCommand(
            key: "agent:main:new-1",
            agentID: " main ",
            parentSessionKey: "agent:main:main")

        #expect(request.method == "sessions.create")
        #expect(request.params["key"]?.stringValue == "agent:main:new-1")
        #expect(request.params["emitCommandHooks"]?.boolValue == true)
        #expect(request.params["agentId"]?.stringValue == "main")
        #expect(request.params["parentSessionKey"]?.stringValue == "agent:main:main")
    }

    // MARK: Durable outbox vocabulary

    @Test
    func outboxErrorCodesKeepTheirStoredValues() {
        typealias Code = OpenClawChatOutboxErrorCode
        // Stores persist these strings; they must stay byte-identical with upstream's SQLite outbox.
        #expect([
            Code.expired, Code.unconfirmed, Code.unknownTarget, Code.changedTarget, Code.clientUpgradeRequired,
            Code.settingsUpgradeRequired, Code.settingsGatewayUpgradeRequired, Code.settingsReviewRequired,
            Code.settingsChanged,
        ] == [
            "expired", "delivery_unconfirmed", "delivery_target_unknown", "delivery_target_changed",
            "client_upgrade_required", "settings_client_upgrade_required", "settings_gateway_upgrade_required",
            "settings_review_required", "settings_changed",
        ])
        #expect(Code.commandMaxAge == 48 * 60 * 60)
    }

    @Test
    func outboxDisplayMessagesTranslateCodesAndStripBranchParkMarkers() {
        typealias Code = OpenClawChatOutboxErrorCode
        #expect(Code.displayMessage(nil) == nil)
        #expect(Code.displayMessage("gateway offline") == "gateway offline")
        #expect(Code.displayMessage("gateway offline\n# branch-park:leaf-1") == "gateway offline")
        for code in [Code.clientUpgradeRequired, Code.settingsUpgradeRequired, Code.settingsGatewayUpgradeRequired,
                     Code.settingsReviewRequired, Code.settingsChanged]
        {
            let message = Code.displayMessage(code)
            #expect(message != nil)
            #expect(message != code)
        }
    }
}
