import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

@Suite("Agent gateway methods")
struct AgentGatewayMethodsTests {
    private struct Harness {
        let server: GatewayServer
        let runtime: EmbeddedAgentRuntime
        let store: SessionStore
        let provider: ScriptedToolProvider
    }

    private func makeHarness(turns: [ScriptedToolProvider.Turn], fallback: ScriptedToolProvider.Turn? = nil) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-gateway-\(UUID().uuidString)")
        let store = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        let provider = ScriptedToolProvider(turns: turns, fallback: fallback)
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool()]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            sessionStore: store,
            transcriptStore: JSONLSessionTranscriptStore(directory: root.appendingPathComponent("transcripts"))
        )
        let server = GatewayServer(
            sessionStore: store,
            secretVault: GatewaySecretVault(credentialStore: InMemoryTestCredentialStore())
        )
        await runtime.attach(to: server)
        return Harness(server: server, runtime: runtime, store: store, provider: provider)
    }

    private func call(_ server: GatewayServer, _ method: String, _ params: [String: AnyCodable] = [:]) async -> ResponseFrame {
        await server.handle(RequestFrame(type: "req", id: UUID().uuidString, method: method, params: AnyCodable(params)))
    }

    @Test
    func sessionsSendRunsTheLoopAndHistoryReturnsAgentMessages() async throws {
        let harness = try await self.makeHarness(turns: [
            ScriptedToolProvider.call("echo", id: "c1", ["text": AnyCodable("hi")]),
            ScriptedToolProvider.text("all done"),
        ])
        let events = await harness.server.events()
        let sent = await self.call(harness.server, "sessions.send", ["key": AnyCodable("agent:main:main"), "message": AnyCodable("hello")])
        #expect(sent.ok)
        let runID = try #require(sent.payload?.dictionaryValue?["runId"]?.stringValue)

        let waited = await self.call(harness.server, "agent.wait", ["runId": AnyCodable(runID), "timeoutMs": AnyCodable(5_000)])
        #expect(waited.ok)
        #expect(waited.payload?.dictionaryValue?["status"] == AnyCodable("ok"))
        #expect(waited.payload?.dictionaryValue?["output"] == AnyCodable("all done"))
        #expect(waited.payload?.dictionaryValue?["runId"] == AnyCodable(runID))

        let history = await self.call(harness.server, "chat.history", ["sessionKey": AnyCodable("agent:main:main")])
        let messages = try #require(history.payload?.dictionaryValue?["messages"]?.arrayValue)
        #expect(messages.compactMap { $0.dictionaryValue?["role"]?.stringValue } == ["user", "assistant", "toolResult", "assistant"])
        let decoded = try JSONDecoder().decode([AgentMessage].self, from: JSONEncoder().encode(AnyCodable(messages)))
        #expect(decoded.last?.text == "all done")

        var sawAgentEvent = false
        for await frame in events {
            if frame.event == "agent", frame.payload?.dictionaryValue?["runId"] == AnyCodable(runID) {
                sawAgentEvent = true
                break
            }
        }
        #expect(sawAgentEvent)
    }

    @Test
    func sessionsCreateStartsARunAndPatchCancelsApprovalsOnPermissionChange() async throws {
        let harness = try await self.makeHarness(turns: [ScriptedToolProvider.text("created")])
        let created = await self.call(harness.server, "sessions.create", [
            "key": AnyCodable("agent:main:work"),
            "label": AnyCodable("Work"),
            "permissionMode": AnyCodable("guarded"),
            "message": AnyCodable("start"),
        ])
        #expect(created.ok)
        let payload = try #require(created.payload?.dictionaryValue)
        #expect(payload["runStarted"] == AnyCodable(true))
        #expect(payload["sessionId"]?.stringValue != nil)
        #expect(payload["entry"]?.dictionaryValue?["permissionMode"] == AnyCodable("guarded"))
        let runID = try #require(payload["runId"]?.stringValue)
        #expect(await harness.runtime.wait(runID: runID, timeoutMs: 5_000)?.status == "ok")

        let approval = await harness.runtime.approvals.request(presentation: .exec(commandText: "ls"), sessionKey: "agent:main:work")
        let patched = await self.call(harness.server, "sessions.patch", ["key": AnyCodable("agent:main:work"), "permissionMode": AnyCodable("read-only")])
        #expect(patched.ok)
        #expect(patched.payload?.dictionaryValue?["entry"]?.dictionaryValue?["permissionMode"] == AnyCodable("read-only"))
        #expect(await harness.runtime.approvals.get(id: approval.id)?.state == .cancelled)

        let retired = await self.call(harness.server, "sessions.patch", ["key": AnyCodable("agent:main:work"), "execAsk": .nullValue])
        #expect(retired.ok == false)
        #expect(retired.error?.errorCode == .invalidRequest)

        let reset = await self.call(harness.server, "sessions.reset", ["key": AnyCodable("agent:main:work")])
        #expect(reset.ok)
        let rotated = try #require(await harness.store.recordForKey("agent:main:work"))
        #expect(rotated.parentSessionID == payload["sessionId"]?.stringValue)
        let emptyHistory = await self.call(harness.server, "chat.history", ["sessionKey": AnyCodable("agent:main:work")])
        #expect(emptyHistory.payload?.dictionaryValue?["messages"]?.arrayValue?.isEmpty == true)

        let deleted = await self.call(harness.server, "sessions.delete", ["key": AnyCodable("agent:main:work")])
        #expect(deleted.payload?.dictionaryValue?["deleted"] == AnyCodable(true))
        #expect(await harness.store.recordForKey("agent:main:work") == nil)
    }

    @Test
    func unifiedAndLegacyApprovalRPCsShareTheBroker() async throws {
        let harness = try await self.makeHarness(turns: [])
        let requested = await self.call(harness.server, "exec.approval.request", [
            "command": AnyCodable("git push"),
            "twoPhase": AnyCodable(true),
            "sessionKey": AnyCodable("s"),
        ])
        #expect(requested.ok)
        let id = try #require(requested.payload?.dictionaryValue?["id"]?.stringValue)
        let list = await self.call(harness.server, "exec.approval.list")
        #expect(list.payload?.arrayValue?.first?.dictionaryValue?["id"] == AnyCodable(id))

        let unified = await self.call(harness.server, "approval.get", ["id": AnyCodable(id)])
        #expect(unified.payload?.dictionaryValue?["approval"]?.dictionaryValue?["status"] == AnyCodable("pending"))

        let resolved = await self.call(harness.server, "approval.resolve", [
            "id": AnyCodable(id),
            "kind": AnyCodable("exec"),
            "decision": AnyCodable("allow-always"),
            "grantExpiresInDays": AnyCodable(3),
        ])
        #expect(resolved.payload?.dictionaryValue?["applied"] == AnyCodable(true))
        let again = await self.call(harness.server, "exec.approval.resolve", ["id": AnyCodable(id), "decision": AnyCodable("deny")])
        #expect(again.payload?.dictionaryValue?["applied"] == AnyCodable(false))

        let waited = await self.call(harness.server, "exec.approval.waitDecision", ["id": AnyCodable(id)])
        #expect(waited.payload?.dictionaryValue?["decision"] == AnyCodable("allow-always"))
        let grants = await self.call(harness.server, "exec.approval.grants.list")
        let grant = try #require(grants.payload?.dictionaryValue?["grants"]?.arrayValue?.first?.dictionaryValue)
        #expect(grant["command"] == AnyCodable("git push"))
        let history = await self.call(harness.server, "approval.history", ["limit": AnyCodable(10)])
        #expect(history.payload?.dictionaryValue?["items"]?.arrayValue?.count == 1)
        let missing = await self.call(harness.server, "approval.get", ["id": AnyCodable("nope")])
        #expect(missing.error?.errorCode == .approvalNotFound)
    }

    @Test
    func questionRPCsAndEvents() async throws {
        let harness = try await self.makeHarness(turns: [])
        let events = await harness.server.events()
        let requested = await self.call(harness.server, "question.request", [
            "sessionKey": AnyCodable("s"),
            "questions": AnyCodable([
                AnyCodable([
                    "questionId": AnyCodable("pick"),
                    "header": AnyCodable("Pick"),
                    "question": AnyCodable("Which?"),
                    "options": AnyCodable([AnyCodable(["label": AnyCodable("A")]), AnyCodable(["label": AnyCodable("B")])]),
                ]),
            ]),
        ])
        #expect(requested.ok)
        let id = try #require(requested.payload?.dictionaryValue?["id"]?.stringValue)
        let pending = await self.call(harness.server, "question.waitAnswer", ["id": AnyCodable(id), "timeoutMs": AnyCodable(10)])
        #expect(pending.payload?.dictionaryValue?["status"] == AnyCodable("pending"))
        let resolved = await self.call(harness.server, "question.resolve", [
            "id": AnyCodable(id),
            "answers": AnyCodable(["answers": AnyCodable(["pick": AnyCodable([AnyCodable("B")])])]),
            "resolutionId": AnyCodable("r1"),
        ])
        #expect(resolved.payload?.dictionaryValue?["status"] == AnyCodable("answered"))
        let answered = await self.call(harness.server, "question.waitAnswer", ["id": AnyCodable(id), "includeResolutionId": AnyCodable(true)])
        #expect(answered.payload?.dictionaryValue?["resolutionId"] == AnyCodable("r1"))
        let listed = await self.call(harness.server, "question.list")
        #expect(listed.payload?.dictionaryValue?["questions"]?.arrayValue?.count == 1)

        let secret = await self.call(harness.server, "question.request", [
            "questions": AnyCodable([
                AnyCodable([
                    "questionId": AnyCodable("token"),
                    "header": AnyCodable("Token"),
                    "question": AnyCodable("Paste token"),
                    "options": AnyCodable([AnyCodable]()),
                    "secretStore": AnyCodable(["name": AnyCodable("API_TOKEN"), "kind": AnyCodable("secret")]),
                ]),
            ]),
        ])
        #expect(secret.error?.errorCode == .unavailable)

        var names: [String] = []
        for await frame in events {
            names.append(frame.event)
            if names.contains("question.requested"), names.contains("question.resolved") {
                break
            }
        }
        #expect(names.contains("question.requested"))
    }

    @Test
    func sessionsAbortAndCompact() async throws {
        let harness = try await self.makeHarness(
            turns: [
                { _ in
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return ModelGenerationResponse(text: "late", providerID: "scripted")
                },
            ],
            fallback: ScriptedToolProvider.text("SUMMARY")
        )
        let sent = await self.call(harness.server, "sessions.send", ["key": AnyCodable("k"), "message": AnyCodable("slow")])
        let runID = try #require(sent.payload?.dictionaryValue?["runId"]?.stringValue)
        try await Task.sleep(nanoseconds: 50_000_000)
        let aborted = await self.call(harness.server, "sessions.abort", ["key": AnyCodable("k")])
        #expect(aborted.payload?.dictionaryValue?["aborted"] == AnyCodable(true))
        let waited = await self.call(harness.server, "agent.wait", ["runId": AnyCodable(runID), "timeoutMs": AnyCodable(2_000)])
        #expect(waited.payload?.dictionaryValue?["status"] == AnyCodable("error"))

        let compacted = await self.call(harness.server, "sessions.compact", ["key": AnyCodable("k")])
        #expect(compacted.ok)
        #expect(compacted.payload?.dictionaryValue?["compacted"] != nil)
    }
}

/// Minimal credential store for gateway tests.
actor InMemoryTestCredentialStore: CredentialStore {
    private var values: [String: String] = [:]

    func loadSecret(for key: String) async throws -> String? {
        self.values[key]
    }

    func saveSecret(_ value: String, for key: String) async throws {
        self.values[key] = value
    }

    func deleteSecret(for key: String) async throws {
        self.values[key] = nil
    }
}
