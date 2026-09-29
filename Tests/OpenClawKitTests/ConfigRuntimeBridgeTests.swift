import Foundation
import Testing
@testable import OpenClawCore
@testable import OpenClawKit

/// Minimal recording reporter for the config runtime bridge tests.
private final class ConfigBridgeStateRecorder: OpenClawSystemStateReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(label: String?, stable: OpenClawStateMetadata, volatile: OpenClawStateMetadata)] = []

    var transitions: [(label: String?, stable: OpenClawStateMetadata, volatile: OpenClawStateMetadata)] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func reportTransition(
        _ domain: OpenClawStateDomain,
        to label: String?,
        stable: OpenClawStateMetadata,
        volatile: OpenClawStateMetadata)
    {
        guard domain == .config else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storage.append((label, stable, volatile))
    }

    func reportVolatileUpdate(_ domain: OpenClawStateDomain, _ volatile: OpenClawStateMetadata) {}
}

@Suite("Config runtime bridge", .serialized)
struct ConfigRuntimeBridgeTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-config-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func loaded(_ json: String) throws -> OpenClawConfigDocumentStore.LoadedConfigDocument {
        try OpenClawConfigDocumentStore.decodeLoaded(Data(json.utf8), migrateLegacyKeys: true)
    }

    // MARK: Health snapshots

    @Test
    func storeEventsMapToConfigHealthStates() throws {
        let clean = try Self.loaded(#"{"meta": {"lastTouchedVersion": "2026.9.6"}}"#)
        #expect(OpenClawConfigHealthSnapshot(event: .loaded(clean), pathKind: .default).state == .loaded)

        let migrated = try Self.loaded(#"{"memorySearch": {"enabled": true}}"#)
        let migratedSnapshot = OpenClawConfigHealthSnapshot(event: .loaded(migrated), pathKind: .override)
        #expect(migratedSnapshot.state == .migrated)
        #expect(migratedSnapshot.migrationCount > 0)
        #expect(migratedSnapshot.pathKind == .override)

        let future = try Self.loaded(#"{"meta": {"lastTouchedVersion": "2099.1.1"}}"#)
        #expect(OpenClawConfigHealthSnapshot(event: .loaded(future), pathKind: .default).state == .futureVersionBlocked)

        let invalid = try Self.loaded(#"{"channels": {"telegram": {"dmPolicy": "allowlist"}}}"#)
        let invalidSnapshot = OpenClawConfigHealthSnapshot(event: .loaded(invalid), pathKind: .default)
        #expect(invalidSnapshot.state == .invalid)
        #expect(invalidSnapshot.issueCount >= 1)

        #expect(OpenClawConfigHealthSnapshot(event: .loadFailed(message: "x"), pathKind: .default).state == .invalid)
        let conflict = OpenClawConfigDocumentStore.Event.writeRefused(
            .conflict(expectedHash: "a", actualHash: "0123456789abcdef"),
            document: OpenClawConfigDocument()
        )
        let conflictSnapshot = OpenClawConfigHealthSnapshot(event: conflict, pathKind: .default)
        #expect(conflictSnapshot.state == .writeConflict)
        #expect(conflictSnapshot.volatileMetadata["configRevisionHash"] == .string("01234567"))
        let futureWrite = OpenClawConfigDocumentStore.Event.writeRefused(
            .futureVersion(touchedVersion: "2099.1.1", currentVersion: "2026.9.6"),
            document: OpenClawConfigDocument()
        )
        #expect(OpenClawConfigHealthSnapshot(event: futureWrite, pathKind: .default).state == .futureVersionBlocked)
        let saved = OpenClawConfigDocumentStore.Event.saved(clean, appliedMigrations: [ConfigMigrationChange(id: "m", message: "Moved x")])
        #expect(OpenClawConfigHealthSnapshot(event: saved, pathKind: .default).state == .migrated)
    }

    @Test
    func reportingStoreReportsLoadsSavesAndConflictsAndHonorsDiagnosticsOptOut() async throws {
        let directory = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("openclaw.json")
        let recorder = ConfigBridgeStateRecorder()
        let store = OpenClawConfigDocumentStore.reportingHealth(fileURL: url, environment: [:], stateReporter: recorder)

        _ = try await store.load()
        let saved = try await store.save(OpenClawConfigDocument(), expectedHash: nil)
        do {
            try await store.save(OpenClawConfigDocument(), expectedHash: "stale")
            Issue.record("expected a conflict")
        } catch {}
        #expect(recorder.transitions.map(\.label) == ["loaded", "loaded", "write-conflict"])
        #expect(recorder.transitions.first?.stable["configPathKind"] == .string("override"))
        #expect(recorder.transitions.first?.stable["upstreamParityVersion"] == .string(OpenClawConfigDocument.upstreamParityVersion))
        // Only privacy-safe metadata: never the path.
        for transition in recorder.transitions {
            for value in transition.stable.values.map({ "\($0)" }) + transition.volatile.values.map({ "\($0)" }) {
                #expect(!value.contains(directory.path))
            }
        }

        var quiet = OpenClawConfigDocument()
        quiet.diagnostics = OpenClawConfigDocument.Diagnostics()
        quiet.diagnostics?.enabled = false
        try await store.save(quiet, expectedHash: saved.hash)
        #expect(recorder.transitions.count == 3)
    }

    // MARK: Runtime pieces

    @Test
    func groupChatOptionsFollowUpstreamFallbacks() throws {
        let document = try OpenClawConfigDocument.decode(Data(#"""
        {"messages": {"visibleReplies": "message_tool", "groupChat": {"unmentionedInbound": "room_event"}}}
        """#.utf8))
        let options = AutoReplyGroupChatOptions(messages: document.messages)
        #expect(options == AutoReplyGroupChatOptions(unmentionedInbound: .roomEvent, visibleReplies: .messageTool))

        let overridden = try OpenClawConfigDocument.decode(Data(#"""
        {"messages": {"visibleReplies": "message_tool", "groupChat": {"visibleReplies": true, "unmentionedInbound": "future"}}}
        """#.utf8))
        let expected = AutoReplyGroupChatOptions(unmentionedInbound: .userRequest, visibleReplies: .automatic)
        #expect(AutoReplyGroupChatOptions(messages: overridden.messages) == expected)
        #expect(AutoReplyGroupChatOptions(messages: nil) == AutoReplyGroupChatOptions())
    }

    @Test
    func loadConfigRuntimeBuildsRuntimeInputs() async throws {
        let directory = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("openclaw.json")
        try Data(#"""
        {
          "meta": {"lastTouchedVersion": "2026.9.6"},
          "session": {"legacyChannelAccountKeys": true},
          "messages": {"groupChat": {"unmentionedInbound": "room_event", "visibleReplies": "message_tool"}},
          "models": {"catalogRefresh": {"enabled": true}},
          "mcp": {"servers": {"fs": {"command": "/usr/local/bin/mcp-fs"}}},
          "channels": {
            "defaults": {"groupPolicy": "open"},
            "telegram": {"enabled": true, "botToken": "${TELEGRAM_TOKEN}", "dmPolicy": "allowlist", "allowFrom": ["42"]},
            "matrix": {"homeserver": "https://matrix.example.com"}
          }
        }
        """#.utf8).write(to: url)
        let recorder = ConfigBridgeStateRecorder()
        let runtime = try await OpenClawSDK.shared.loadConfigRuntime(
            fromOpenClawJSON: url,
            environment: ["TELEGRAM_TOKEN": "123:abc"],
            stateReporter: recorder
        )
        #expect(runtime.config.channels.telegram.enabled)
        #expect(runtime.config.channels.telegram.botToken == "123:abc")
        #expect(runtime.loaded.document.channels?.channels["telegram"]?.raw["botToken"]?.stringValue == "${TELEGRAM_TOKEN}")
        #expect(runtime.config.channels.compatibility.legacySessionAccountKeys)
        #expect(runtime.config.channels.rawSection(named: "matrix") != nil)
        #expect(runtime.config.models.catalogRefresh?.enabled == true)
        #expect(runtime.config.mcp?.servers?["fs"]?.command == "/usr/local/bin/mcp-fs")
        #expect(runtime.groupChat == AutoReplyGroupChatOptions(unmentionedInbound: .roomEvent, visibleReplies: .messageTool))
        let policy = runtime.messagingPolicy(for: "telegram")
        #expect(policy.dmPolicy == .allowlist)
        #expect(policy.allowFrom == ["42"])
        #expect(policy.groupPolicy == .open)
        #expect(runtime.health.state == .loaded)
        #expect(runtime.health.pathKind == .override)
        #expect(recorder.transitions.map(\.label) == ["loaded"])
        #expect(runtime.issues.isEmpty)

        // Missing env references surface as issues instead of failing the load.
        let missing = try await OpenClawSDK.shared.loadConfigRuntime(fromOpenClawJSON: url, environment: [:], stateReporter: NoopSystemStateReporter())
        #expect(missing.issues.contains { $0.message.contains("TELEGRAM_TOKEN") })
    }

    // MARK: Exec allowlist persistence

    @Test
    func execAllowlistsPersistInTheSharedExecApprovalsDocument() async throws {
        let stateDirectory = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let store = ExecApprovalsSQLiteAllowlistStore(stateDirectoryURL: stateDirectory)
        #expect(try store.loadAllowlist(agentID: "main").isEmpty)

        let path = ["PATH": "/usr/bin:/bin"]
        let security = SecurityRuntime(allowlistStore: store)
        let grant = try #require(try await security.recordAllowAlways(argv: ["printf", "ok"], cwd: "/", commandText: "printf ok", environment: path))
        try await security.addExecAllowlistEntry(ExecAllowlistEntry(id: "manual-rg", pattern: "rg", argPattern: #"^--files$"#), agentID: "main")

        let document = try #require(try ExecApprovalsSQLiteStore.read(stateDirectoryURL: stateDirectory)?.document)
        let stored = try #require(document.agents?["main"]?.allowlist)
        #expect(stored.map(\.id) == [grant.id, "manual-rg"])
        #expect(stored.first?.source == ExecAllowlistEntry.allowAlwaysSource)
        #expect(stored.first?.argPattern == grant.argPattern)
        #expect(stored.last?.argPattern == #"^--files$"#)

        // A fresh runtime reads the shared document and honors the grant.
        let reloaded = SecurityRuntime(allowlistStore: store)
        #expect(try await reloaded.evaluateExec(argv: ["printf", "ok"], cwd: "/", environment: path)?.id == grant.id)
        #expect(try await reloaded.evaluateExec(argv: ["printf", "changed"], cwd: "/", environment: path) == nil)
        let usage = try store.loadAllowlist(agentID: "main").first { $0.id == grant.id }
        #expect((usage?.lastUsedAt ?? 0) > Int64(0))

        // The legacy `default` agent key reads as `main`.
        try ExecApprovalsSQLiteStore.write(
            ExecApprovalsDocument(
                version: 1,
                agents: ["default": ExecApprovalsAgentDocument(allowlist: [ExecApprovalsAllowlistEntry(id: "legacy", pattern: "*")])]
            ),
            stateDirectoryURL: stateDirectory
        )
        #expect(try store.loadAllowlist(agentID: "main").map(\.id) == ["legacy"])
        try store.saveAllowlist([], agentID: "default")
        #expect(try ExecApprovalsSQLiteStore.read(stateDirectoryURL: stateDirectory)?.document.agents == nil)
    }

    @Test
    func securityRuntimeNeverServesOrWritesBackRevokedRules() async throws {
        let stateDirectory = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let store = ExecApprovalsSQLiteAllowlistStore(stateDirectoryURL: stateDirectory)
        let path = ["PATH": "/usr/bin:/bin"]
        let printf = try #require(ExecCommandResolution.resolve(argv: ["printf"], environment: path)?.resolvedRealPath)
        let echo = try #require(ExecCommandResolution.resolve(argv: ["echo"], environment: path)?.resolvedRealPath)
        let ruleA = ExecAllowlistEntry(id: "a", pattern: printf)
        let ruleB = ExecAllowlistEntry(id: "b", pattern: echo)
        let security = SecurityRuntime(allowlistStore: store)
        try await security.setExecAllowlist([ruleA, ruleB])
        #expect(try await security.evaluateExec(argv: ["echo", "hi"], cwd: "/", environment: path)?.id == "b")

        // Another writer (the gateway, `system.execApprovals.set`) revokes B and adds C.
        try ExecApprovalsSQLiteStore.write(
            ExecApprovalsDocument(
                version: 1,
                agents: ["main": ExecApprovalsAgentDocument(allowlist: [
                    ExecApprovalsAllowlistEntry(id: "a", pattern: printf),
                    ExecApprovalsAllowlistEntry(id: "c", pattern: "rg"),
                ])]
            ),
            stateDirectoryURL: stateDirectory
        )
        #expect(try await security.evaluateExec(argv: ["echo", "hi"], cwd: "/", environment: path) == nil)
        #expect(try await security.allowlistEvaluator(environment: path).allows(commandText: "echo hi") == false)
        #expect(try store.loadAllowlist(agentID: "main").map(\.id) == ["a", "c"])

        // An allowed use of A records usage without dropping C or restoring B.
        #expect(try await security.evaluateExec(argv: ["printf", "ok"], cwd: "/", environment: path)?.id == "a")
        let stored = try store.loadAllowlist(agentID: "main")
        #expect(stored.map(\.id) == ["a", "c"])
        #expect((stored.first?.lastUsedAt ?? 0) > Int64(0))
        #expect(stored.first?.lastUsedCommand == "printf ok")

        // Adds and allow-always grants are merged into the current document too.
        try await security.addExecAllowlistEntry(ExecAllowlistEntry(id: "d", pattern: "ls"))
        #expect(try store.loadAllowlist(agentID: "main").map(\.id) == ["a", "c", "d"])
    }

    @Test
    func legacyDefaultAgentFoldsIntoMainSoRevocationsStick() async throws {
        let stateDirectory = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let store = ExecApprovalsSQLiteAllowlistStore(stateDirectoryURL: stateDirectory)
        try ExecApprovalsSQLiteStore.write(
            ExecApprovalsDocument(
                version: 1,
                agents: [
                    "main": ExecApprovalsAgentDocument(allowlist: [ExecApprovalsAllowlistEntry(id: "a", pattern: "/usr/bin/a")]),
                    "default": ExecApprovalsAgentDocument(
                        security: .allowlist,
                        allowlist: [
                            ExecApprovalsAllowlistEntry(id: "a-dup", pattern: "/USR/BIN/A"),
                            ExecApprovalsAllowlistEntry(id: "b", pattern: "/usr/bin/b"),
                        ]
                    ),
                ]
            ),
            stateDirectoryURL: stateDirectory
        )
        // Reads show the union upstream enforces.
        #expect(try store.loadAllowlist(agentID: "main").map(\.id) == ["a", "b"])
        #expect(try store.loadAllowlist(agentID: "default").map(\.id) == ["a", "b"])

        // Revoking B through the SDK removes it from the one merged list and drops `default`.
        let security = SecurityRuntime(allowlistStore: store)
        try await security.setExecAllowlist(try await security.execAllowlist().filter { $0.id != "b" })
        let record = try #require(try ExecApprovalsSQLiteStore.read(stateDirectoryURL: stateDirectory))
        #expect(record.document.agents?["default"] == nil)
        #expect(record.document.agents?["main"]?.allowlist?.map(\.id) == ["a"])
        #expect(record.document.agents?["main"]?.security == .allowlist)
        #expect(!record.rawJSON.contains("\"default\""))
    }
}
