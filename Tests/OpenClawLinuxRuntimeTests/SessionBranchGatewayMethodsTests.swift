import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

/// `sessions.rewind`, `sessions.fork`, `sessions.branches.list|switch` and `sessions.search`.
@Suite("Session branch gateway methods", .timeLimit(.minutes(1)))
struct SessionBranchGatewayMethodsTests {
    private typealias Harness = GatewayServerTestHarness
    private static let key = "agent:main:main"

    /// Two completed turns: "first question" → "first answer", "second question" → "second answer".
    private func twoTurnStack(_ name: String) async throws -> Harness.Stack {
        let stack = await Harness.runtimeStack(name, turns: [
            ScriptedToolProvider.text("first answer"),
            ScriptedToolProvider.text("second answer"),
            ScriptedToolProvider.text("third answer"),
        ])
        for (index, message) in ["first question", "second question"].enumerated() {
            let sent = try Harness.payload(await Harness.call(stack.server, "sessions.send", [
                "key": AnyCodable(Self.key), "message": AnyCodable(message), "idempotencyKey": AnyCodable("turn-\(index)"),
            ]))
            let runID = try #require(sent["runId"]?.stringValue)
            #expect(try await awaitCancellable("turn \(index) finished") { await stack.runtime.wait(runID: runID) }?.status == "ok")
        }
        return stack
    }

    private func activeEntries(_ stack: Harness.Stack, key: String = Self.key) async throws -> [SessionTranscriptEntry] {
        let store = try #require(stack.runtime.transcriptStore)
        return try await store.activePath(sessionID: await stack.runtime.transcriptSessionID(for: key))
    }

    private func userEntryID(_ entries: [SessionTranscriptEntry], text: String) throws -> String {
        try #require(entries.first { entry in
            if case .message(.user(let user)) = entry.payload { return user.content.text == text }
            return false
        }?.id)
    }

    @Test
    func rewindMovesTheLeafAndBranchesListAndSwitch() async throws {
        let stack = try await self.twoTurnStack("branches-rewind")
        let events = await stack.server.events(filter: .only(.sessionsChanged))
        let entries = try await self.activeEntries(stack)
        let secondUser = try self.userEntryID(entries, text: "second question")
        let assistantID = try #require(entries.last?.id)

        let notUser = await Harness.call(stack.server, "sessions.rewind", ["sessionKey": AnyCodable(Self.key), "entryId": AnyCodable(assistantID)])
        #expect(notUser.error?.errorCode == .invalidRequest)
        #expect(notUser.error?.message.contains("not a user message") == true)
        let wrongAgent = await Harness.call(stack.server, "sessions.rewind", [
            "sessionKey": AnyCodable(Self.key), "agentId": AnyCodable("other"), "entryId": AnyCodable(secondUser),
        ])
        #expect(wrongAgent.error?.errorCode == .invalidRequest)

        let rewound = try Harness.payload(await Harness.call(stack.server, "sessions.rewind", [
            "sessionKey": AnyCodable(Self.key), "agentId": AnyCodable("main"), "entryId": AnyCodable(secondUser),
        ]))
        #expect(rewound["editorText"] == AnyCodable("second question"))
        let history = try Harness.payload(await Harness.call(stack.server, "chat.history", ["sessionKey": AnyCodable(Self.key)]))
        #expect(history["messages"]?.arrayValue?.compactMap { $0.dictionaryValue?["role"]?.stringValue } == ["user", "assistant"])

        let listed = try Harness.payload(await Harness.call(stack.server, "sessions.branches.list", ["sessionKey": AnyCodable(Self.key)]))
        let branches = try GatewayPayloadCodec.decode(SessionsBranchesListResult.self, from: AnyCodable(listed)).branches
        #expect(branches.count == 2)
        let inactive = try #require(branches.first { !$0.active })
        #expect(inactive.leafentryid == assistantID)
        #expect(inactive.headline == "second question")
        #expect(inactive.updatedat?.contains("T") == true)

        let alreadyActive = try #require(branches.first { $0.active })
        let sameBranch = await Harness.call(stack.server, "sessions.branches.switch", [
            "sessionKey": AnyCodable(Self.key), "leafEntryId": AnyCodable(alreadyActive.leafentryid),
        ])
        #expect(sameBranch.error?.message.contains("already active") == true)
        let switched = await Harness.call(stack.server, "sessions.branches.switch", [
            "sessionKey": AnyCodable(Self.key), "leafEntryId": AnyCodable(assistantID),
        ])
        #expect(switched.ok)
        #expect(try await self.activeEntries(stack).last?.id == assistantID)

        // Lifecycle changes of the earlier runs may still be in flight; keep the DAG reasons only.
        let dagReasons: Set<String> = ["rewind", "branch-switch"]
        let frames = try await Harness.collect(events, "rewind and branch-switch frames") { frames in
            frames.filter { dagReasons.contains($0.payload?.dictionaryValue?["reason"]?.stringValue ?? "") }.count >= 2
        }
        let reasons = frames.compactMap { $0.payload?.dictionaryValue?["reason"]?.stringValue }.filter(dagReasons.contains)
        #expect(reasons == ["rewind", "branch-switch"])

        let unknown = try Harness.payload(await Harness.call(stack.server, "sessions.branches.list", ["sessionKey": AnyCodable("agent:main:none")]))
        #expect(unknown["branches"] == AnyCodable([AnyCodable]()))
    }

    @Test
    func forkCopiesTheActivePathBeforeTheEntry() async throws {
        let stack = try await self.twoTurnStack("branches-fork")
        _ = await Harness.call(stack.server, "sessions.patch", [
            "key": AnyCodable(Self.key), "label": AnyCodable("Main"), "permissionMode": AnyCodable("guarded"),
        ])
        let entries = try await self.activeEntries(stack)
        let secondUser = try self.userEntryID(entries, text: "second question")
        let forked = try Harness.payload(await Harness.call(stack.server, "sessions.fork", [
            "sessionKey": AnyCodable(Self.key), "entryId": AnyCodable(secondUser),
        ]))
        let result = try GatewayPayloadCodec.decode(SessionsForkResult.self, from: AnyCodable(forked))
        #expect(result.sessionkey.hasPrefix("agent:main:fork:"))
        #expect(result.editortext == "second question")

        let forkHistory = try Harness.payload(await Harness.call(stack.server, "chat.history", ["sessionKey": AnyCodable(result.sessionkey)]))
        #expect(forkHistory["messages"]?.arrayValue?.compactMap { $0.dictionaryValue?["role"]?.stringValue } == ["user", "assistant"])
        let record = try #require(await stack.store.recordForKey(result.sessionkey))
        #expect(record.permissionMode == .guarded)
        #expect(record.label == "Main (fork)")
        #expect(record.parentSessionID == (await stack.store.recordForKey(Self.key))?.sessionID)
        // The source session is unchanged.
        #expect(try await self.activeEntries(stack).count == entries.count)

        // The fork continues independently.
        let sent = try Harness.payload(await Harness.call(stack.server, "sessions.send", [
            "key": AnyCodable(result.sessionkey), "message": AnyCodable("fork follow-up"),
        ]))
        let runID = try #require(sent["runId"]?.stringValue)
        #expect(try await awaitCancellable("fork run finished") { await stack.runtime.wait(runID: runID) }?.status == "ok")
        #expect(try await self.activeEntries(stack, key: result.sessionkey).count == 4)
    }

    @Test
    func searchMatchesWordsAndPhrasesPerAgent() async throws {
        let stack = try await self.twoTurnStack("branches-search")
        let words = try Harness.payload(await Harness.call(stack.server, "sessions.search", ["query": AnyCodable("SECOND answer")]))
        let result = try GatewayPayloadCodec.decode(SessionsSearchResult.self, from: AnyCodable(words))
        #expect(result.results.count == 1)
        #expect(result.results.first?.snippet == "second answer")
        #expect(result.results.first?.role == AnyCodable("assistant"))
        #expect(result.sessions?.first?.key == Self.key)

        let phrase = try Harness.payload(await Harness.call(stack.server, "sessions.search", ["query": AnyCodable("\"first question\"")]))
        #expect(phrase["results"]?.arrayValue?.count == 1)
        let loose = try Harness.payload(await Harness.call(stack.server, "sessions.search", ["query": AnyCodable("question")]))
        #expect(loose["results"]?.arrayValue?.count == 2)
        let otherAgent = try Harness.payload(
            await Harness.call(stack.server, "sessions.search", ["query": AnyCodable("question"), "agentId": AnyCodable("ops")])
        )
        #expect(otherAgent["results"]?.arrayValue?.isEmpty == true)
        let limited = try Harness.payload(await Harness.call(stack.server, "sessions.search", ["query": AnyCodable("question"), "limit": AnyCodable(1)]))
        #expect(limited["truncated"] == AnyCodable(true))
        #expect(await Harness.call(stack.server, "sessions.search").error?.errorCode == .invalidRequest)
    }

    @Test
    func mutationsRefuseWhileARunIsActive() async throws {
        let stack = await Harness.runtimeStack("branches-busy", turns: [
            ScriptedToolProvider.text("done"),
            { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return ModelGenerationResponse(text: "late", providerID: "scripted")
            },
        ])
        let first = try Harness.payload(await Harness.call(stack.server, "sessions.send", ["key": AnyCodable(Self.key), "message": AnyCodable("one")]))
        let firstRunID = try #require(first["runId"]?.stringValue)
        _ = try await awaitCancellable("first run finished") { await stack.runtime.wait(runID: firstRunID) }
        let entries = try await self.activeEntries(stack)
        let userID = try self.userEntryID(entries, text: "one")
        _ = await Harness.call(stack.server, "sessions.send", ["key": AnyCodable(Self.key), "message": AnyCodable("two")])
        try await Task.sleep(nanoseconds: 50_000_000)
        let busy = await Harness.call(stack.server, "sessions.rewind", ["sessionKey": AnyCodable(Self.key), "entryId": AnyCodable(userID)])
        #expect(busy.error?.errorCode == .unavailable)
        _ = await Harness.call(stack.server, "sessions.abort", ["key": AnyCodable(Self.key)])
    }
}
