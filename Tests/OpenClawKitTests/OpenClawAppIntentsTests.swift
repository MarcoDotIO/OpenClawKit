#if canImport(AppIntents)
import AppIntents
import Foundation
import Testing
@testable import OpenClawAppIntents
import OpenClawKit
#if compiler(>=6.4) && canImport(UserNotifications)
import UserNotifications
#endif
#if compiler(>=6.4) && canImport(NowPlaying)
import NowPlaying
#endif

/// Scripted intent host.
actor FakeIntentHost: OpenClawIntentHost {
    struct Send: Sendable, Equatable {
        let prompt: String
        let sessionKey: String?
        let agentId: String?
        let attachmentCount: Int
    }

    var script: [OpenClawIntentRunEvent] = [
        OpenClawIntentRunEvent(phase: .queued, fractionCompleted: 0),
        OpenClawIntentRunEvent(phase: .streaming, fractionCompleted: 0.4, text: "Hel", sessionKey: "resolved"),
        OpenClawIntentRunEvent(phase: .completed, fractionCompleted: 1, text: "Hello", sessionKey: "resolved"),
    ]
    private(set) var sends: [Send] = []
    private(set) var aborts: [String] = []
    private(set) var talkStarts: [String?] = []
    let sessionRows: [OpenClawIntentSessionSummary] = [
        OpenClawIntentSessionSummary(sessionKey: "main", title: "Main"),
        OpenClawIntentSessionSummary(sessionKey: "team", title: "Team", isGroup: true),
    ]

    func setScript(_ script: [OpenClawIntentRunEvent]) {
        self.script = script
    }

    func sessions(matching query: String?, limit: Int) async throws -> [OpenClawIntentSessionSummary] {
        let rows = self.sessionRows.filter { query == nil || $0.title.localizedCaseInsensitiveContains(query ?? "") }
        return Array(rows.prefix(limit))
    }

    func sessions(forKeys keys: [String]) async throws -> [OpenClawIntentSessionSummary] {
        keys.compactMap { key in self.sessionRows.first { $0.sessionKey == key } }
    }

    func agents() async throws -> [OpenClawIntentAgentSummary] {
        [OpenClawIntentAgentSummary(agentId: "main", displayName: "Aiden", emoji: "🐕"), OpenClawIntentAgentSummary(agentId: "coder", displayName: "Coder")]
    }

    func send(prompt: String, sessionKey: String?, agentId: String?) async throws -> AsyncThrowingStream<OpenClawIntentRunEvent, any Error> {
        try await self.send(prompt: prompt, sessionKey: sessionKey, agentId: agentId, attachments: [])
    }

    func send(
        prompt: String,
        sessionKey: String?,
        agentId: String?,
        attachments: [OpenClawIntentAttachment]) async throws -> AsyncThrowingStream<OpenClawIntentRunEvent, any Error>
    {
        self.sends.append(Send(prompt: prompt, sessionKey: sessionKey, agentId: agentId, attachmentCount: attachments.count))
        let script = self.script
        return AsyncThrowingStream { continuation in
            for event in script {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func abort(sessionKey: String) async {
        self.aborts.append(sessionKey)
    }

    func startTalk(sessionKey: String?) async throws {
        self.talkStarts.append(sessionKey)
    }
}

@Suite("App Intents intents and entities", .serialized)
struct OpenClawAppIntentsTests {
    private func configuredHost() -> FakeIntentHost {
        let host = FakeIntentHost()
        OpenClawAppIntents.configure(host: host)
        OpenClawIntentSessionCache.shared.removeAll()
        return host
    }

    @Test
    func configureRegistersTheHost() {
        let host = self.configuredHost()
        #expect(OpenClawAppIntents.host is FakeIntentHost)
        _ = host
        OpenClawAppIntents.resetHostForTesting()
        #expect(OpenClawAppIntents.host is UnconfiguredOpenClawIntentHost)
    }

    @Test
    func askIntentReturnsTheFinalReply() async throws {
        let host = self.configuredHost()
        let intent = AskOpenClawIntent(
            prompt: "  hi  ",
            session: OpenClawSessionAppEntity(sessionKey: "team", title: "Team"),
            agent: OpenClawAgentAppEntity(summary: OpenClawIntentAgentSummary(agentId: "coder", displayName: "Coder")))
        let result = try await intent.perform()
        #expect(result.value == "Hello")
        #expect(await host.sends == [FakeIntentHost.Send(prompt: "hi", sessionKey: "team", agentId: "coder", attachmentCount: 0)])
    }

    @Test
    func askIntentMapsEmptyPromptsAbortsAndMissingHosts() async throws {
        let host = self.configuredHost()
        // On OS 27 intent errors surface as AppIntentError (CustomAppIntentErrorConvertible).
        let empty = await #expect(throws: (any Error).self) {
            _ = try await AskOpenClawIntent(prompt: "   ").perform()
        }
        #expect(String(describing: empty).contains("The prompt is empty."))
        await host.setScript([OpenClawIntentRunEvent(phase: .aborted, text: "partial")])
        let aborted = await #expect(throws: (any Error).self) {
            _ = try await AskOpenClawIntent(prompt: "go").perform()
        }
        #expect(String(describing: aborted).contains("stopped"))
        OpenClawAppIntents.resetHostForTesting()
        do {
            _ = try await OpenClawIntentActions.ask(prompt: "hi")
            Issue.record("expected hostNotConfigured")
        } catch {
            #expect(error as? OpenClawIntentError == .hostNotConfigured)
        }
    }

    @Test
    func actionsDriveRunProgressFromEvents() async throws {
        let host = self.configuredHost()
        let progress = OpenClawRunProgress(backing: .legacyProgress)
        let text = try await OpenClawIntentActions.ask(prompt: "hi", host: host, progress: progress)
        #expect(text == "Hello")
        #expect(progress.fractionCompleted == 1)
        #expect(progress.phase == .completed)
        #expect(OpenClawIntentActions.dialogText(for: "  ") == "OpenClaw finished without a reply.")
    }

    @Test
    func abortIntentAbortsTheSession() async throws {
        let host = self.configuredHost()
        _ = try await AbortOpenClawRunIntent(session: OpenClawSessionAppEntity(sessionKey: "main")).perform()
        #expect(await host.aborts == ["main"])
    }

    @Test @MainActor
    func startTalkPrefersTheRouterHandler() async throws {
        let host = self.configuredHost()
        OpenClawIntentRouter.shared.startLiveVoiceHandler = nil
        _ = try await StartOpenClawTalkIntent(session: OpenClawSessionAppEntity(sessionKey: "main")).perform()
        #expect(await host.talkStarts == ["main"])

        var routed: [String?] = []
        OpenClawIntentRouter.shared.startLiveVoiceHandler = { key in routed.append(key) }
        defer { OpenClawIntentRouter.shared.startLiveVoiceHandler = nil }
        _ = try await OpenClawStartLiveVoiceIntent(session: nil).perform()
        #expect(routed == [nil])
        #expect(await host.talkStarts == ["main"])
        #expect(StartOpenClawTalkIntent.openAppWhenRun)
    }

    @Test
    func talkStartDeepLinkIsRecognized() throws {
        #expect(OpenClawIntentRouter.isTalkStartURL(OpenClawIntentRouter.talkStartURL))
        #expect(OpenClawIntentRouter.isTalkStartURL(try #require(URL(string: "OPENCLAW://talk/start/"))))
        #expect(!OpenClawIntentRouter.isTalkStartURL(try #require(URL(string: "openclaw://talk/stop"))))
        #expect(!OpenClawIntentRouter.isTalkStartURL(try #require(URL(string: "https://talk/start"))))
    }

    @Test
    func sessionQueryResolvesSearchesAndSuggests() async throws {
        _ = self.configuredHost()
        let query = OpenClawSessionAppEntityQuery()
        let resolved = try await query.entities(for: ["team", "missing"])
        #expect(resolved.map(\.id) == ["team"])
        #expect(resolved.first?.title == "Team")
        #expect(resolved.first?.isGroup == true)
        #expect(try await query.entities(matching: "mai").map(\.id) == ["main"])
        #expect(try await query.suggestedEntities().map(\.id) == ["main", "team"])
        #expect(OpenClawIntentSessionCache.shared.summary(for: "main")?.title == "Main")
    }

    @Test
    func agentQueryListsAndResolvesAgents() async throws {
        _ = self.configuredHost()
        let query = OpenClawAgentAppEntityQuery()
        #expect(try await query.allEntities().map(\.id) == ["main", "coder"])
        #expect(try await query.entities(for: ["coder", "nope"]).map(\.name) == ["Coder"])
    }

    @Test
    func entitiesRoundTripSummaries() {
        let summary = OpenClawIntentSessionSummary(
            sessionKey: "agent:main:main",
            title: "Main",
            agentId: "main",
            updatedAt: Date(timeIntervalSince1970: 10),
            isGroup: false)
        #expect(OpenClawSessionAppEntity(summary: summary).summary == summary)
        #expect(OpenClawSessionAppEntity(sessionKey: "k").title == "k")
        let agent = OpenClawAgentAppEntity(summary: OpenClawIntentAgentSummary(agentId: "a", displayName: "Aiden", emoji: "🐕"))
        #expect(agent.name == "Aiden")
        #expect(agent.emoji == "🐕")
    }

    @Test
    func presentableErrorsAreUserFacing() {
        #expect(OpenClawIntentError.presentable(CancellationError()) as? OpenClawIntentError == .aborted)
        #expect(OpenClawIntentError.hostNotConfigured.errorDescription?.isEmpty == false)
        let generic = OpenClawIntentError.presentable(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "nope"]))
        #expect(generic as? OpenClawIntentError == .runFailed("nope"))
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            let gateway = GatewayResponseError(method: "chat.send", code: "NOT_PAIRED", message: "pair first", details: nil)
            #expect(OpenClawIntentError.presentable(gateway) is AppIntentError)
            let auth = GatewayConnectAuthError(message: "pairing required", detailCode: "PAIRING_REQUIRED", canRetryWithDeviceToken: false)
            #expect(OpenClawIntentError.presentable(auth) is AppIntentError)
            let node = OpenClawNodeError(code: .unavailable, message: "offline")
            #expect(OpenClawIntentError.presentable(node) is AppIntentError)
            #expect(OpenClawIntentError.presentable(OpenClawIntentError.timedOut) is AppIntentError)
        }
        #endif
    }

    @Test
    func os27ConformancesAreAvailable() async throws {
        #if compiler(>=6.4)
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) else { return }
        #expect(RunOpenClawTaskIntent.allowedExecutionTargets == [.main])
        #expect(OpenClawSessionAppEntityQuery.allowedExecutionTargets == [.main, .appIntentsExtension])
        #expect(OpenClawSessionAppEntity(sessionKey: "g", isGroup: true).ownership == .shared)
        #expect(OpenClawSessionAppEntity(sessionKey: "d").ownership == .unknown)
        let intent = RunOpenClawTaskIntent(prompt: "task", session: OpenClawSessionAppEntity(sessionKey: "main"))
        #expect(intent.prompt == "task")

        _ = self.configuredHost()
        let query = OpenClawSessionAppEntityQuery()
        _ = try await query.suggestedEntities()
        let representations = try await query.displayRepresentations(for: ["main", "team"])
        #expect(Set(representations.keys) == ["main", "team"])
        #endif
    }
}

@Suite("App Intents entity linking")
struct OpenClawAppIntentsEntityLinkingTests {
    actor FakeRelevance: OpenClawRelevantEntitiesUpdating {
        private(set) var calls: [String] = []

        func setNowPlayingSession(_ session: OpenClawSessionAppEntity) async throws {
            self.calls.append("set:\(session.id)")
        }

        func clearNowPlayingSession() async throws {
            self.calls.append("clear")
        }
    }

    @Test
    func sessionEntityIdentifiersRoundTripTheKey() {
        let identifier = OpenClawAppIntents.sessionEntityIdentifier("agent:main:main")
        #expect(identifier.identifier == "agent:main:main")
        #expect(ObjectIdentifier(identifier.entityType) == ObjectIdentifier(OpenClawSessionAppEntity.self))
    }

    @Test
    func talkRelevanceFollowsTalkLifecycle() async {
        let relevance = FakeRelevance()
        let coordinator = OpenClawTalkRelevanceCoordinator(updater: relevance)
        await coordinator.talkStarted(sessionKey: "main", title: "Main")
        await coordinator.talkStarted(sessionKey: "main")
        await coordinator.talkStopped()
        await coordinator.talkStopped()
        await coordinator.talkStarted(sessionKey: "team")
        #expect(await relevance.calls == ["set:main", "clear", "set:team"])
        #expect(await coordinator.activeSessionKey == "team")
    }

    /// Relevance updater whose updates suspend until the test releases them.
    actor SuspendingRelevance: OpenClawRelevantEntitiesUpdating {
        private(set) var calls: [String] = []
        private var suspended: [CheckedContinuation<Void, Never>] = []
        private var failNextSet = false

        func setNowPlayingSession(_ session: OpenClawSessionAppEntity) async throws {
            self.calls.append("set:\(session.id)")
            await withCheckedContinuation { self.suspended.append($0) }
            if self.failNextSet {
                self.failNextSet = false
                throw CancellationError()
            }
        }

        func clearNowPlayingSession() async throws {
            self.calls.append("clear")
        }

        var suspendedCount: Int {
            self.suspended.count
        }

        func resumeAll() {
            let continuations = self.suspended
            self.suspended.removeAll()
            continuations.forEach { $0.resume() }
        }

        func failNextUpdate() {
            self.failNextSet = true
        }
    }

    @Test
    func quickStartAndStopNeverLeavesTheStoppedSessionPublished() async throws {
        let relevance = SuspendingRelevance()
        let coordinator = OpenClawTalkRelevanceCoordinator(updater: relevance)
        let started = Task { await coordinator.talkStarted(sessionKey: "main") }
        while await relevance.suspendedCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        // Stop arrives while the start update is still in flight.
        let stopped = Task { await coordinator.talkStopped() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await relevance.calls == ["set:main"], "the clear waits for the in-flight set")
        await relevance.resumeAll()
        await started.value
        await stopped.value
        #expect(await relevance.calls == ["set:main", "clear"])
        #expect(await coordinator.activeSessionKey == nil)
    }

    @Test
    func aFailedUpdateIsRetriedForTheSameSession() async throws {
        let relevance = SuspendingRelevance()
        let coordinator = OpenClawTalkRelevanceCoordinator(updater: relevance)
        await relevance.failNextUpdate()
        let failed = Task { await coordinator.talkStarted(sessionKey: "main") }
        while await relevance.suspendedCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        await relevance.resumeAll()
        await failed.value
        #expect(await coordinator.activeSessionKey == nil)

        let retried = Task { await coordinator.talkStarted(sessionKey: "main") }
        while await relevance.suspendedCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        await relevance.resumeAll()
        await retried.value
        #expect(await relevance.calls == ["set:main", "set:main"])
        #expect(await coordinator.activeSessionKey == "main")
    }

    @Test
    func notificationAndNowPlayingContentLinkSessionsOnOS27() {
        #if compiler(>=6.4)
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) else { return }
        #if canImport(UserNotifications)
        // Observed on macOS 27.2: outside an app bundle the notification content does not retain
        // the identifiers (it returns []), so a bare test process only checks that linking is safe.
        let content = UNMutableNotificationContent()
        content.linkOpenClawSession("agent:main:telegram:dm:1")
        #expect(content.appEntityIdentifiers.count <= 1)
        #endif
        #if canImport(NowPlaying)
        var media = GenericContent(id: "talk:1", title: "OpenClaw", subtitle: "Talk", type: .audio, duration: nil, artwork: nil)
        media.linkOpenClawSession("main")
        #expect(media.appEntityIdentifiers.map(\.identifier) == ["main"])
        #endif
        #endif
    }
}

@Suite("Model delegation prompt shaping")
struct ModelDelegationPromptShaperTests {
    @Test
    func conversationsMapToSiriSessions() {
        #expect(ModelDelegationPromptShaper.sessionKey(conversationIdentifier: "abc") == "siri:abc")
        #expect(ModelDelegationPromptShaper.sessionKey(conversationIdentifier: "  ") == nil)
        #expect(ModelDelegationPromptShaper.sessionKey(conversationIdentifier: nil) == nil)
    }

    @Test
    func promptsAreShapedPerSurface() {
        #expect(ModelDelegationPromptShaper.message(prompt: " hi ", surface: .systemAssistant(selectedText: nil)) == "hi")
        #expect(ModelDelegationPromptShaper.message(prompt: "explain", surface: .systemAssistant(selectedText: "E=mc2"))
            == "Selected text:\n<<<\nE=mc2\n>>>\n\nexplain")
        let writing = ModelDelegationPromptShaper.message(
            prompt: "make it formal",
            surface: .writingTools(selectedText: "hey there", allText: "hey there, pal"))
        #expect(writing.contains("Apple Writing Tools"))
        #expect(writing.contains("Selected text:\n<<<\nhey there\n>>>"))
        #expect(!writing.contains("pal"))
        #expect(writing.hasSuffix("Request: make it formal"))
        let fullText = ModelDelegationPromptShaper.message(prompt: "fix", surface: .writingTools(selectedText: nil, allText: "all"))
        #expect(fullText.contains("Text:\n<<<\nall\n>>>"))
        #expect(ModelDelegationPromptShaper.message(prompt: "count", surface: .shortcuts(outputType: "number"))
            == "count\n\nRespond with a single number only.")
        #expect(ModelDelegationPromptShaper.outputInstruction(for: "dictionary") == "Respond with a single JSON object only.")
        #expect(ModelDelegationPromptShaper.outputInstruction(for: "future") == "Respond with plain text only.")
        #expect(ModelDelegationPromptShaper.message(prompt: "look", surface: .visualIntelligence) == "look")
    }
}
#endif
