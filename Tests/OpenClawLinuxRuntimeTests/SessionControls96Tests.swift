import Foundation
import Testing
@testable import OpenClawCore
import OpenClawProtocol

@Suite("Session controls 2026.9.6")
struct SessionControls96Tests {
    private func makeStore() -> SessionStore {
        SessionStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("session-controls-\(UUID().uuidString)")
                .appendingPathComponent("sessions.json")
        )
    }

    // MARK: - Vocabulary

    @Test
    func traceLevelNormalizesUpstreamAliases() {
        #expect(TraceLevel.normalize("TRUE") == .on)
        #expect(TraceLevel.normalize("unfiltered") == .raw)
        #expect(TraceLevel.normalize(" no ") == .off)
        #expect(TraceLevel.normalize("verbose") == nil)
        #expect(TraceLevel.normalize(nil) == nil)
    }

    @Test
    func permissionModeVocabularyAndProjections() throws {
        #expect(SessionPermissionMode.normalize("read-only") == .readOnly)
        #expect(SessionPermissionMode.normalize("READ_ONLY") == .readOnly)
        #expect(SessionPermissionMode.normalize("readonly") == .readOnly)
        #expect(SessionPermissionMode.normalize("admin") == nil)
        #expect(SessionPermissionMode.full.requiredScope == "operator.admin")
        #expect(SessionPermissionMode.guarded.requiredScope == "operator.write")
        #expect(SessionPermissionMode.readOnly.execMode == .deny)
        #expect(SessionPermissionMode.guarded.execMode == .ask)
        #expect(SessionPermissionMode.workspace.execMode == .auto)
        #expect(SessionPermissionMode.full.execMode == .full)
        #expect(SessionPermissionMode.from(execMode: .allowlist) == .guarded)
        let encoded = try JSONEncoder().encode(SessionPermissionMode.readOnly)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"read-only\"")
    }

    @Test
    func legacyExecPolicyMigrationNeverGrantsFull() {
        #expect(SessionPermissionMode.migratingLegacyExecPolicy(security: .deny, ask: nil) == .readOnly)
        #expect(SessionPermissionMode.migratingLegacyExecPolicy(security: .allowlist, ask: .onMiss) == .guarded)
        #expect(SessionPermissionMode.migratingLegacyExecPolicy(security: .allowlist, ask: .off) == .guarded)
        #expect(SessionPermissionMode.migratingLegacyExecPolicy(security: .full, ask: .always) == .readOnly)
        #expect(SessionPermissionMode.migratingLegacyExecPolicy(security: .full, ask: .off) == nil)
        // Missing security on a non-sandbox host inherits full, which projects to full (never granted).
        #expect(SessionPermissionMode.migratingLegacyExecPolicy(security: nil, ask: .onMiss) == nil)
        // Sandbox hosts use the stricter deny base.
        #expect(SessionPermissionMode.migratingLegacyExecPolicy(security: nil, ask: .off, execHost: .sandbox) == .readOnly)
        #expect(SessionPermissionMode.migratingLegacyExecPolicy(security: nil, ask: nil) == nil)
    }

    @Test
    func fastModeSettingDecodesBooleansAndAuto() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(FastModeSetting.self, from: Data("true".utf8)) == .on)
        #expect(try decoder.decode(FastModeSetting.self, from: Data("false".utf8)) == .off)
        #expect(try decoder.decode(FastModeSetting.self, from: Data("\"auto\"".utf8)) == .auto)
        #expect(try decoder.decode(FastModeSetting.self, from: Data("\"fast\"".utf8)) == .on)
        #expect(String(decoding: try JSONEncoder().encode(FastModeSetting.auto), as: UTF8.self) == "\"auto\"")
        #expect(String(decoding: try JSONEncoder().encode(FastModeSetting.on), as: UTF8.self) == "true")
        #expect(FastModeSetting.auto.boolValue == nil)
    }

    @Test
    func toolOverridesNormalizeLikeUpstream() {
        let overrides = SessionToolOverrides(
            mcpServers: [:],
            mcpToolsDeny: ["docs": ["b", "a", "a", ""], "empty": []],
            skills: ["pdf": true],
            webSearch: true
        )
        let normalized = overrides.normalized()
        #expect(normalized?.mcpServers == nil)
        #expect(normalized?.mcpToolsDeny == ["docs": ["a", "b"]])
        #expect(normalized?.skills == ["pdf": true])
        #expect(normalized?.webSearch == nil)
        #expect(SessionToolOverrides(webSearch: true).isEmpty)
        #expect(SessionToolOverrides(mcpServers: ["docs": false]).deniesMCPTool(server: "docs", tool: "x"))
    }

    // MARK: - Record coding

    @Test
    func sessionRecordUsesInt64TimestampsAndDropsRetiredExecFields() throws {
        let json = """
        {"key":"agent:main:main","agentID":"main","updatedAtMs":1790000000123,
         "execSecurity":"allowlist","execAsk":"on-miss","fastMode":"auto","traceLevel":"raw",
         "permissionMode":null,"pinnedAtMs":1790000000000}
        """
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        #expect(record.updatedAtMs == 1_790_000_000_123)
        #expect(record.permissionMode == .guarded)
        #expect(record.fastModeSetting == .auto)
        #expect(record.fastMode == nil)
        #expect(record.traceLevel == .raw)
        #expect(record.pinned)
        let encoded = try JSONDecoder().decode([String: AnyCodable].self, from: JSONEncoder().encode(record))
        #expect(encoded["execSecurity"] == nil)
        #expect(encoded["execAsk"] == nil)
        #expect(encoded["permissionMode"] == AnyCodable("guarded"))
        #expect(encoded["fastMode"] == AnyCodable("auto"))
    }

    @Test
    func legacyFullAccessRecordDoesNotMigrateToFull() throws {
        let json = #"{"key":"k","agentID":"main","updatedAtMs":1,"execSecurity":"full","execAsk":"off"}"#
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        #expect(record.permissionMode == nil)
    }

    // MARK: - Patch

    @Test
    func patchRejectsRetiredExecFieldsIncludingNull() async {
        let store = self.makeStore()
        for raw: [String: AnyCodable] in [
            ["key": AnyCodable("s1"), "execSecurity": AnyCodable("full")],
            ["key": AnyCodable("s1"), "execAsk": .nullValue],
        ] {
            do {
                try await store.applyPatch(raw, defaultAgentID: "main")
                Issue.record("expected retired-field rejection")
            } catch let error as SessionPatchError {
                #expect(error == .invalid(SessionStore.retiredExecPolicyMessage))
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
        #expect(await store.recordForKey("s1") == nil)
    }

    @Test
    func patchGatesFullPermissionOnAdminScope() async throws {
        let store = self.makeStore()
        let guarded = try await store.applyPatch(
            ["key": AnyCodable("s1"), "permissionMode": AnyCodable("guarded")],
            defaultAgentID: "main",
            grantedScopes: ["operator.write"]
        )
        #expect(guarded.record.permissionMode == .guarded)
        #expect(guarded.created)
        #expect(guarded.record.sessionID != nil)

        do {
            try await store.applyPatch(
                ["key": AnyCodable("s1"), "permissionMode": AnyCodable("full")],
                defaultAgentID: "main",
                grantedScopes: ["operator.write"]
            )
            Issue.record("expected missing scope")
        } catch let error as SessionPatchError {
            guard case .missingScope(let scope, _) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(scope == "operator.admin")
        }

        let full = try await store.applyPatch(
            ["key": AnyCodable("s1"), "permissionMode": AnyCodable("full")],
            defaultAgentID: "main",
            grantedScopes: ["operator.admin"]
        )
        #expect(full.record.permissionMode == .full)
        #expect(full.permissionModeChanged)

        let cleared = try await store.applyPatch(["key": AnyCodable("s1"), "permissionMode": .nullValue], defaultAgentID: "main")
        #expect(cleared.record.permissionMode == nil)

        do {
            try await store.applyPatch(["key": AnyCodable("s1"), "permissionMode": AnyCodable("root")], defaultAgentID: "main")
            Issue.record("expected invalid permission mode")
        } catch let error as SessionPatchError {
            #expect(error.errorDescription?.contains("read-only") == true)
        }
    }

    @Test
    func patchAppliesLifecycleAndDisplayFields() async throws {
        let store = self.makeStore()
        do {
            try await store.applyPatch(["key": AnyCodable("s2"), "archived": AnyCodable(true)], defaultAgentID: "main")
            Issue.record("archiving an unknown session must fail")
        } catch {}

        _ = try await store.applyPatch(
            [
                "key": AnyCodable("s2"),
                "label": AnyCodable("Planning"),
                "icon": AnyCodable("sparkles"),
                "traceLevel": AnyCodable("on"),
                "fastMode": AnyCodable("auto"),
                "toolOverrides": AnyCodable(["mcpServers": AnyCodable(["docs": AnyCodable(false)])]),
                "pinned": AnyCodable(true),
                "unread": AnyCodable(true),
            ],
            defaultAgentID: "main"
        )
        var record = try #require(await store.recordForKey("s2"))
        #expect(record.label == "Planning")
        #expect(record.icon == "sparkles")
        #expect(record.traceLevel == .on)
        #expect(record.fastModeSetting == .auto)
        #expect(record.toolOverrides?.mcpServers == ["docs": false])
        #expect(record.pinned)
        #expect(record.unread)

        record = try await store.applyPatch(["key": AnyCodable("s2"), "archived": AnyCodable(true)], defaultAgentID: "main").record
        #expect(record.archived)
        #expect(record.pinned == false)
        do {
            try await store.applyPatch(["key": AnyCodable("s2"), "pinned": AnyCodable(true)], defaultAgentID: "main")
            Issue.record("pinning an archived session must fail")
        } catch let error as SessionPatchError {
            #expect(error.errorDescription?.contains("archived") == true)
        }

        record = try await store.applyPatch(
            ["key": AnyCodable("s2"), "unread": AnyCodable(false), "label": .nullValue, "traceLevel": .nullValue],
            defaultAgentID: "main"
        ).record
        #expect(record.unread == false)
        #expect(record.lastReadAtMs != nil)
        #expect(record.label == nil)
        #expect(record.traceLevel == nil)

        do {
            try await store.applyPatch(["key": AnyCodable("s2"), "traceLevel": AnyCodable("loud")], defaultAgentID: "main")
            Issue.record("expected invalid trace level")
        } catch {}
        do {
            try await store.applyPatch(["key": AnyCodable("s2"), "agentRuntime": AnyCodable("codex")], defaultAgentID: "main")
            Issue.record("agentRuntime requires a model")
        } catch {}
        do {
            try await store.applyPatch(
                ["key": AnyCodable("s2"), "expectedSessionId": AnyCodable("stale")],
                defaultAgentID: "main"
            )
            Issue.record("expected session fence")
        } catch {}
    }

    @Test
    func childSessionsCannotBePinned() async throws {
        let store = self.makeStore()
        let key = SessionKey.subagentKey(agentID: "main")
        _ = try await store.applyPatch(["key": AnyCodable(key)], defaultAgentID: "main")
        do {
            try await store.applyPatch(["key": AnyCodable(key), "pinned": AnyCodable(true)], defaultAgentID: "main")
            Issue.record("expected child pin rejection")
        } catch let error as SessionPatchError {
            #expect(error.errorDescription?.contains("child") == true)
        }
    }

    @Test
    func resolveOrCreateAssignsTranscriptIdentityAndResetRotates() async throws {
        let store = self.makeStore()
        let created = await store.resolveOrCreate(sessionKey: "main", defaultAgentID: "main", route: nil)
        let sessionID = try #require(created.sessionID)
        let again = await store.resolveOrCreate(sessionKey: "main", defaultAgentID: "main", route: nil)
        #expect(again.sessionID == sessionID)
        let rotated = try #require(await store.rotateSession(forKey: "main"))
        #expect(rotated.sessionID != sessionID)
        #expect(rotated.parentSessionID == sessionID)
    }

    // MARK: - Canonical session keys

    @Test
    func agentIDNormalizationMatchesUpstream() {
        #expect(SessionKey.normalizeAgentID("Ops") == "ops")
        #expect(SessionKey.normalizeAgentID("  My Agent!! ") == "my-agent")
        #expect(SessionKey.normalizeAgentID("--weird__id--") == "weird__id")
        #expect(SessionKey.normalizeAgentID("!!!") == "main")
        #expect(SessionKey.normalizeAgentID(nil) == "main")
        #expect(SessionKey.normalizeAgentID(String(repeating: "a", count: 80)).count == 64)
        #expect(SessionKey.isValidAgentID("A1_b-2"))
        #expect(SessionKey.isValidAgentID("-a") == false)
    }

    @Test
    func sessionKeyShapesMatchUpstream() {
        #expect(SessionKey.mainKey(agentID: "Ops") == "agent:ops:main")
        #expect(SessionKey.toStoreKey(agentID: "Ops", requestKey: "Incident-42") == "agent:ops:incident-42")
        #expect(SessionKey.toStoreKey(agentID: "ops", requestKey: "main", mainKey: "work") == "agent:ops:work")
        #expect(SessionKey.toStoreKey(agentID: "ops", requestKey: "agent:main:incident-42") == "agent:main:incident-42")
        #expect(SessionKey.toStoreKey(agentID: "main", requestKey: "agent:main:main") == "agent:main:main")
        #expect(SessionKey.toStoreKey(agentID: "ops", requestKey: "UNKNOWN") == "agent:ops:unknown")
        #expect(SessionKey.toStoreKey(agentID: "ops", requestKey: "  ") == "agent:ops:main")
        #expect(SessionKey.parse("agent:voice:room::part") == SessionKey.Parsed(agentID: "voice", rest: "room::part"))
        #expect(SessionKey.parse("agent::broken") == nil)
        #expect(SessionKey.parse("agent:main") == nil)
        #expect(SessionKey.parse("main") == nil)
        #expect(SessionKey.toRequestKey("agent:ops:work") == "work")
    }

    @Test
    func peerKeysMatchUpstreamShapes() {
        #expect(
            SessionKey.peerKey(agentID: "Main", channel: "Telegram", accountID: "Bot1", peerKind: .direct, peerID: "U1", dmScope: .perAccountChannelPeer)
                == "agent:main:telegram:bot1:direct:u1"
        )
        #expect(SessionKey.peerKey(agentID: "main", channel: "slack", peerID: "U1", dmScope: .perChannelPeer) == "agent:main:slack:direct:u1")
        #expect(SessionKey.peerKey(agentID: "main", channel: "slack", peerID: "U1", dmScope: .perPeer) == "agent:main:direct:u1")
        #expect(SessionKey.peerKey(agentID: "main", channel: "slack", peerID: "U1", dmScope: .main) == "agent:main:main")
        #expect(
            SessionKey.peerKey(agentID: "Main", channel: "Telegram", peerKind: .group, peerID: "MiXeDGroup")
                == "agent:main:telegram:group:mixedgroup"
        )
        let mixed = "VWATodkf2hc8zdOS76q9Tb0+5Bi522E03qLdaQ/9ypg="
        #expect(SessionKey.peerKey(agentID: "Main", channel: "Signal", peerKind: .group, peerID: mixed) == "agent:main:signal:group:\(mixed)")
        #expect(SessionKey.parse("Agent:Main:Signal:Group:\(mixed)") == SessionKey.Parsed(agentID: "main", rest: "signal:group:\(mixed)"))
        #expect(SessionKey.peerKey(agentID: "main", channel: "slack", peerKind: .group, peerID: "g", groupScope: .main) == "agent:main:main")
        #expect(SessionKey.isSubagentKey(SessionKey.subagentKey(agentID: "ops")))
    }

    @Test
    func canonicalResolverFormatIsOptIn() {
        let config = OpenClawConfig()
        let context = SessionRoutingContext(channel: "telegram", accountID: "default", peerID: "1234")
        let legacy = SessionKeyResolver.derive(context: context, config: config, format: .legacy)
        #expect(legacy == SessionKeyResolver.derive(context: context, config: config))
        let canonical = SessionKeyResolver.derive(context: context, config: config, format: .canonical, agentID: "main")
        #expect(canonical.hasPrefix("agent:main:telegram:"))
        #expect(SessionKey.isAgentScoped(canonical))
    }
}
