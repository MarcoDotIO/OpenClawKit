import Foundation
import Testing
import OpenClawCore
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

@Suite("Approval and question brokers", .timeLimit(.minutes(1)))
struct ApprovalQuestionBrokerTests {
    // MARK: - Approvals

    @Test
    func firstAnswerWinsAndLaterCallersSeeTheRecord() async throws {
        let broker = ApprovalBroker()
        let pending = await broker.request(presentation: .exec(commandText: "git status"), sessionKey: "s", runID: "r")
        #expect(pending.state == .pending)
        #expect(pending.urlPath == "/approvals/\(pending.id)")

        let first = try await broker.resolve(id: pending.id, decision: .allowOnce, reviewer: AgentApprovalReviewer(deviceID: "phone"))
        #expect(first.applied)
        #expect(first.approval.state == .allowed)
        let second = try await broker.resolve(id: pending.id, decision: .deny)
        #expect(second.applied == false)
        #expect(second.approval.decision == .allowOnce)

        let waited = try await broker.waitDecision(id: pending.id)
        #expect(waited.state == .allowed)
        let snapshot = waited.snapshotPayload
        #expect(snapshot["status"] == AnyCodable("allowed"))
        #expect(snapshot["reason"] == AnyCodable("user"))
        #expect(snapshot["resolver"]?.dictionaryValue?["kind"] == AnyCodable("device"))
        #expect(await broker.history().items.map(\.id) == [pending.id])
    }

    @Test
    func snapshotPayloadDecodesAsGeneratedProtocolModel() async throws {
        let broker = ApprovalBroker()
        let pending = await broker.request(presentation: .plugin(title: "Send", description: "Send an email?", toolName: "mail"))
        let data = try JSONEncoder().encode(AnyCodable(pending.snapshotPayload))
        let decoded = try JSONDecoder().decode(ApprovalSnapshot.self, from: data)
        guard case .pending(let snapshot) = decoded else {
            Issue.record("expected pending snapshot")
            return
        }
        #expect(snapshot.id == pending.id)
        _ = try await broker.resolve(id: pending.id, decision: .deny)
        let terminal = try #require(await broker.get(id: pending.id))
        let terminalData = try JSONEncoder().encode(AnyCodable(terminal.snapshotPayload))
        guard case .denied = try JSONDecoder().decode(TerminalApprovalSnapshot.self, from: terminalData) else {
            Issue.record("expected denied snapshot")
            return
        }
    }

    @Test
    func expiryFailsClosed() async throws {
        let broker = ApprovalBroker()
        let pending = await broker.request(presentation: .exec(commandText: "rm -rf build"), timeoutMs: 30)
        let result = try await awaitCancellable("approval expired") { try await broker.waitDecision(id: pending.id) }
        #expect(result.state == .expired)
        #expect(result.reason == .timeout)
        #expect(result.isAllowed == false)
    }

    @Test
    func allowAlwaysMintsReusableGrant() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let grantsURL = directory.appendingPathComponent("grants.json")
        let broker = ApprovalBroker(grantsFileURL: grantsURL)
        let key = try #require(ApprovalBroker.execGrantKey(command: "git status"))
        // Grants bind the exact argv: flags and different paths get their own keys.
        #expect(ApprovalBroker.execGrantKey(command: "git status -s") != key)
        #expect(ApprovalBroker.execGrantKey(command: "/usr/bin/rm -rf /") != ApprovalBroker.execGrantKey(command: "/usr/bin/rm -f x"))

        let waiter = Task {
            await broker.requestAndWait(presentation: .exec(commandText: "git status"), agentID: "main", grantKey: key)
        }
        try await waitUntil("grant approval pending") { await !broker.pending().isEmpty }
        let id = try #require(await broker.pending().first?.id)
        _ = try await broker.resolve(id: id, decision: .allowAlways, grantExpiresInDays: 7)
        #expect(await waiter.value.isAllowed)

        // The grant answers the next request without a pending approval.
        let reused = await broker.requestAndWait(presentation: .exec(commandText: "git status"), agentID: "main", grantKey: key)
        #expect(reused.isAllowed)
        #expect(await broker.pending().isEmpty)
        let grants = await broker.listGrants()
        #expect(grants.count == 1)
        #expect(grants.first?.useCount == 1)

        // Grants persist and can be revoked.
        let reloaded = ApprovalBroker(grantsFileURL: grantsURL)
        #expect(await reloaded.hasGrant(kind: .exec, key: key, agentID: "main"))
        let grantID = try #require(grants.first?.id)
        #expect(await reloaded.revokeGrant(grantID) == "revoked")
        #expect(await reloaded.revokeGrant(grantID) == "already-revoked")
        #expect(await reloaded.revokeGrant("missing") == "not-found")
        #expect(await reloaded.hasGrant(kind: .exec, key: key, agentID: "main") == false)
    }

    @Test
    func runCancellationCancelsPendingApprovals() async throws {
        let broker = ApprovalBroker()
        let pending = await broker.request(presentation: .exec(commandText: "make"), runID: "run-1")
        #expect(await broker.cancel(runID: "run-1") == 1)
        let record = try #require(await broker.get(id: pending.id))
        #expect(record.state == .cancelled)
        #expect(record.reason == .runAborted)
        do {
            _ = try await broker.resolve(id: pending.id, decision: .allowOnce, kind: .plugin)
            Issue.record("expected kind mismatch")
        } catch let error as ApprovalBrokerError {
            #expect(error == .kindMismatch(expected: .plugin, actual: .exec))
        }
        do {
            _ = try await broker.resolve(id: "missing", decision: .deny)
            Issue.record("expected not found")
        } catch {}
    }

    @Test
    func abortingARunCancelsItsApprovalWait() async throws {
        let provider = ScriptedToolProvider(turns: [
            ScriptedToolProvider.call("echo", id: "c1", ["text": AnyCodable("one")]),
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool()]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            hooks: AgentLoopHooks(beforeToolCall: { _ in .requireApproval(AgentToolApprovalRequest(title: "Echo", description: "Allow?")) })
        )
        let runID = await runtime.start(AgentRunRequest(runID: "wait-approval", sessionKey: "w", prompt: "go"), streaming: false)
        try await waitUntil("tool approval pending") { await !runtime.approvals.pending().isEmpty }
        let pending = try #require(await runtime.approvals.pending().first)
        #expect(pending.runID == runID)
        await runtime.abort(runID: runID)
        let result = try #require(await awaitCancellable("aborted run finished") { await runtime.wait(runID: runID) })
        #expect(result.status == "error")
        #expect(await runtime.approvals.get(id: pending.id)?.state == .cancelled)
    }

    // MARK: - Questions

    @Test
    func askUserNormalizationEnforcesLimits() throws {
        let valid: [String: AnyCodable] = [
            "questions": AnyCodable([
                AnyCodable([
                    "id": AnyCodable("color"),
                    "header": AnyCodable("Favorite color please"),
                    "question": AnyCodable("Pick a color"),
                    "options": AnyCodable([AnyCodable(["label": AnyCodable("Red")]), AnyCodable(["label": AnyCodable(" Blue ")])]),
                ]),
            ]),
            "timeoutSeconds": AnyCodable(5),
        ]
        let normalized = try AskUserTool.normalize(valid)
        #expect(normalized.timeoutSeconds == 30)
        #expect(normalized.questions.first?.header == "Favorite col")
        #expect(normalized.questions.first?.options.map(\.label) == ["Red", "Blue"])
        #expect(normalized.questions.first?.isOther == true)
        #expect(try AskUserTool.normalizeTimeoutSeconds(AnyCodable(99_999)) == 3_600)
        #expect(try AskUserTool.normalizeTimeoutSeconds(nil) == 900)

        var oneOption = valid
        oneOption["questions"] = AnyCodable([
            AnyCodable([
                "id": AnyCodable("x"),
                "header": AnyCodable("H"),
                "question": AnyCodable("Q"),
                "options": AnyCodable([AnyCodable(["label": AnyCodable("Only")])]),
            ]),
        ])
        #expect(throws: QuestionBrokerError.self) { try AskUserTool.normalize(oneOption) }
        var badID = valid
        badID["questions"] = AnyCodable([
            AnyCodable([
                "id": AnyCodable("Bad-Id"),
                "header": AnyCodable("H"),
                "question": AnyCodable("Q"),
                "options": AnyCodable([AnyCodable(["label": AnyCodable("A")]), AnyCodable(["label": AnyCodable("B")])]),
            ]),
        ])
        #expect(throws: QuestionBrokerError.self) { try AskUserTool.normalize(badID) }
    }

    @Test
    func askUserToolRoundTripsThroughTheBroker() async throws {
        let broker = QuestionBroker()
        let tool = AskUserTool(broker: broker)
        let arguments: [String: AnyCodable] = [
            "questions": AnyCodable([
                AnyCodable([
                    "id": AnyCodable("size"),
                    "header": AnyCodable("Size"),
                    "question": AnyCodable("Which size?"),
                    "options": AnyCodable([AnyCodable(["label": AnyCodable("S")]), AnyCodable(["label": AnyCodable("L")])]),
                ]),
            ]),
        ]
        let asking = Task {
            try await tool.invoke(AgentToolInvocation(arguments: arguments, context: AgentToolInvocationContext(runID: "r", sessionKey: "chat")), update: nil)
        }
        try await waitUntil("question pending") { await broker.pendingQuestion(sessionKey: "chat") != nil }
        let id = try #require(await broker.pendingQuestion(sessionKey: "chat")?.id)

        // One pending question per session.
        let second = try await tool.invoke(AgentToolInvocation(arguments: arguments, context: AgentToolInvocationContext(sessionKey: "chat")), update: nil)
        #expect(second.isError)
        #expect(second.text == AskUserTool.pendingQuestionMessage)

        let record = try await broker.resolve(id: id, answers: ["size": ["L"]], resolvedBy: "watch", resolutionID: "tap-1")
        #expect(record.payload["answers"]?.dictionaryValue?["answers"]?.dictionaryValue?["size"] == AnyCodable([AnyCodable("L")]))
        // Replaying the same resolution id is idempotent.
        #expect(try await broker.resolve(id: id, answers: ["size": ["S"]], resolutionID: "tap-1").answers == ["size": ["L"]])
        let output = try await asking.value
        #expect(output.isError == false)
        #expect(output.text.hasPrefix("Size: L"))
        #expect(output.details?.dictionaryValue?["status"] == AnyCodable("answered"))
        let wire = try JSONEncoder().encode(AnyCodable(record.payload))
        _ = try JSONDecoder().decode(QuestionRecord.self, from: wire)
    }

    @Test
    func questionsExpireAndCancel() async throws {
        let broker = QuestionBroker()
        let prompt = AgentQuestionPrompt(
            questionID: "q",
            header: "Q",
            question: "Ok?",
            options: [AgentQuestionOption(label: "Yes"), AgentQuestionOption(label: "No")]
        )
        let expiring = try await broker.request(questions: [prompt], timeoutMs: 30)
        #expect(try await awaitCancellable("question expired") { try await broker.waitAnswer(id: expiring.id) } == .expired)

        let cancelled = try await broker.request(questions: [prompt], runID: "run-9")
        #expect(try await broker.waitAnswer(id: cancelled.id, timeoutMs: 20) == .pending)
        #expect(await broker.cancel(runID: "run-9") == 1)
        #expect(try await broker.waitAnswer(id: cancelled.id) == .cancelled)
        #expect(await broker.list().count == 2)
        do {
            try await broker.resolve(id: cancelled.id, answers: ["q": ["Yes"]])
            Issue.record("expected not pending")
        } catch let error as QuestionBrokerError {
            #expect(error == .notPending(cancelled.id, .cancelled))
        }
        do {
            try await broker.request(questions: [])
            Issue.record("expected invalid")
        } catch {}
    }
}
