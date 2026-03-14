import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawCore

@Suite("Session store parity")
struct SessionStoreParityTests {
    @Test
    func sessionRecordRoundTripsExpandedRuntimeFields() async throws {
        let root = try makeSessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("sessions.json")
        let store = SessionStore(fileURL: fileURL)
        await store.upsert(
            SessionRecord(
                key: "webchat:ios:user-1",
                agentID: "ios-agent",
                updatedAtMs: 1_700_000_000_000,
                lastRoute: SessionRoute(channel: "webchat", accountID: "ios", peerID: "user-1"),
                sessionID: "session-123",
                label: "Support iOS",
                thinkingLevel: "high",
                fastMode: true,
                verboseLevel: "compact",
                reasoningLevel: "deep",
                responseUsage: "tokens",
                elevatedLevel: "off",
                model: "gpt-5",
                spawnedBy: "main",
                spawnedWorkspaceDir: "/tmp/child-workspace",
                spawnDepth: 1,
                sendPolicy: "allow",
                groupActivation: "mention",
                inputProvenance: [
                    "source": AnyCodable("webchat"),
                    "upload": AnyCodable(true),
                ]
            )
        )

        try await store.save()

        let reloaded = SessionStore(fileURL: fileURL)
        try await reloaded.load()
        let record = await reloaded.recordForKey("webchat:ios:user-1")

        #expect(record?.sessionID == "session-123")
        #expect(record?.fastMode == true)
        #expect(record?.spawnedWorkspaceDir == "/tmp/child-workspace")
        #expect(record?.inputProvenance?["source"] == AnyCodable("webchat"))
        #expect(record?.inputProvenance?["upload"] == AnyCodable(true))
        #expect(record?.label == "Support iOS")
    }

    @Test
    func sessionStoreAppliesGatewayPatchForFastModeAndSpawnedWorkspaceDir() async throws {
        let root = try makeSessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        _ = await store.resolveOrCreate(
            sessionKey: "telegram:default:1234",
            defaultAgentID: "support",
            route: SessionRoute(channel: "telegram", accountID: "default", peerID: "1234")
        )

        let patchJSON = #"""
        {
          "key": "telegram:default:1234",
          "label": "Ops inbox",
          "thinkingLevel": "low",
          "fastMode": true,
          "verboseLevel": "full",
          "responseUsage": "full",
          "spawnedBy": "main",
          "spawnedWorkspaceDir": "/tmp/runtime-child",
          "spawnDepth": 2,
          "sendPolicy": "deny"
        }
        """#
        let patch = try JSONDecoder().decode(SessionsPatchParams.self, from: Data(patchJSON.utf8))
        let updated = await store.applyGatewayPatch(patch)

        #expect(updated?.label == "Ops inbox")
        #expect(updated?.thinkingLevel == .low)
        #expect(updated?.fastMode == true)
        #expect(updated?.verboseLevel == .full)
        #expect(updated?.responseUsage == .full)
        #expect(updated?.spawnedBy == "main")
        #expect(updated?.spawnedWorkspaceDir == "/tmp/runtime-child")
        #expect(updated?.spawnDepth == 2)
        #expect(updated?.sendPolicy == .deny)
    }

    @Test
    func sessionStoreUpdateRuntimeStatePreservesExpandedFieldsAcrossResolveOrCreate() async throws {
        let root = try makeSessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        _ = await store.resolveOrCreate(
            sessionKey: "discord:default:abc",
            defaultAgentID: "main",
            route: SessionRoute(channel: "discord", accountID: "default", peerID: "abc")
        )

        _ = await store.updateRuntimeState(
            sessionKey: "discord:default:abc",
            inputProvenance: ["surface": AnyCodable("message-action")],
            fastMode: false,
            spawnedWorkspaceDir: "/tmp/discord-workspace"
        )

        let refreshed = await store.resolveOrCreate(
            sessionKey: "discord:default:abc",
            defaultAgentID: "ops",
            route: SessionRoute(channel: "discord", accountID: "default", peerID: "abc")
        )

        #expect(refreshed.agentID == "main")
        #expect(refreshed.fastMode == false)
        #expect(refreshed.spawnedWorkspaceDir == "/tmp/discord-workspace")
        #expect(refreshed.inputProvenance?["surface"] == AnyCodable("message-action"))
    }

    private func makeSessionRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-session-parity-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
