import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawCore

@Suite("Config RPC helpers")
struct ConfigRPCHelperTests {
    static let snapshotJSON = #"""
    {
      "path": "/home/me/.openclaw/openclaw.json",
      "exists": true,
      "raw": "{ gateway: { auth: { token: \"__OPENCLAW_REDACTED__\" } } }",
      "parsed": {"gateway": {}},
      "sourceConfig": {
        "gateway": {"auth": {"mode": "token", "token": "__OPENCLAW_REDACTED__"}},
        "agents": {"entries": {"main": {"skills": ["a", "b"]}}},
        "models": {"providers": {"custom": {"baseUrl": "https://x.invalid", "models": [
          {"id": "m1", "name": "M1", "input": ["text", "image"]}, {"id": "m2", "name": "M2"}]}}},
        "channels": {"telegram": {"allowFrom": ["1", "2"], "groups": {"*": {"requireMention": true}}}}
      },
      "resolved": {},
      "runtimeConfig": {"tools": {"web": {"search": {"enabled": false}}}, "mcp": {"servers": {"a": {"enabled": false}, "b": {}}}},
      "config": {},
      "valid": true,
      "hash": "abc123",
      "issues": [{"path": "x", "message": "bad", "pathSegments": ["x", 0], "allowedValues": ["a"]}],
      "warnings": [],
      "legacyIssues": [{"path": "agents.list", "message": "moved"}],
      "configRevisionHash": "rev-1",
      "appliedConfigHash": null,
      "futureField": true
    }
    """#

    @Test
    func decodesConfigGetSnapshot() throws {
        let snapshot = try ConfigGetSnapshot.decode(Data(Self.snapshotJSON.utf8))
        #expect(snapshot.path == "/home/me/.openclaw/openclaw.json")
        #expect(snapshot.exists)
        #expect(snapshot.valid)
        #expect(snapshot.hash == "abc123")
        #expect(snapshot.configRevisionHash == "rev-1")
        #expect(snapshot.appliedConfigHash == nil)
        #expect(snapshot.issues.first?.pathSegments == [.string("x"), .integer(0)])
        #expect(snapshot.legacyIssues.first?.path == "agents.list")
        #expect(snapshot.sourceConfig?.gateway?.auth?.token?.isRedacted == true)
        #expect(snapshot.isWebSearchEnabled == false)
        #expect(snapshot.mcpServerEnabledStates == ["a": false, "b": true])
    }

    @Test
    func mergePatchComputesReplacePaths() throws {
        let snapshot = try ConfigGetSnapshot.decode(Data(Self.snapshotJSON.utf8))
        var builder = ConfigMergePatchBuilder(base: snapshot.patchBase)
        builder.set(["agents", "entries", "main", "skills"], AnyCodable(.array([AnyCodable(.string("a"))])))
        builder.set(["channels", "telegram", "allowFrom"], AnyCodable(.array([AnyCodable(.string("1")), AnyCodable(.string("2")), AnyCodable(.string("3"))])))
        builder.set(["channels", "telegram", "groups"], nil)
        builder.set(["gateway", "port"], AnyCodable(.int(19_000)))
        let payload = try builder.build()
        #expect(payload.replacePaths == ["agents.entries.main.skills"])
        #expect(payload.raw.contains("\"groups\":null"))
        #expect(!payload.raw.contains("REDACTED"))
        #expect(payload.touchedPaths.contains("channels.telegram.groups"))

        let params = ConfigRPC.patchParams(payload, baseHash: snapshot.hash, note: "trim skills")
        #expect(params.basehash == "abc123")
        #expect(params.replacepaths == ["agents.entries.main.skills"])
        let object = try ConfigRPC.paramsObject(params)
        #expect(object["replacePaths"]?.arrayValue?.count == 1)
        #expect(object["baseHash"]?.stringValue == "abc123")
    }

    @Test
    func idMergedArraysUseBracketPathsAndDeletionsListContainedArrays() throws {
        let snapshot = try ConfigGetSnapshot.decode(Data(Self.snapshotJSON.utf8))
        var builder = ConfigMergePatchBuilder(base: snapshot.patchBase)
        builder.set(["models", "providers", "custom", "models"], AnyCodable(.array([
            AnyCodable(.object(["id": AnyCodable("m1"), "name": AnyCodable("M1"), "input": AnyCodable(.array([AnyCodable("text")]))])),
            AnyCodable(.object(["id": AnyCodable("m2"), "name": AnyCodable("M2")])),
        ])))
        #expect(try builder.build().replacePaths == ["models.providers.custom.models[].input"])

        var removal = ConfigMergePatchBuilder(base: snapshot.patchBase)
        removal.set(["models", "providers", "custom", "models"], AnyCodable(.array([
            AnyCodable(.object(["id": AnyCodable("m1"), "name": AnyCodable("M1"), "input": AnyCodable(.array([AnyCodable("text"), AnyCodable("image")]))])),
        ])))
        #expect(try removal.build().replacePaths == ["models.providers.custom.models"])

        var deletion = ConfigMergePatchBuilder(base: snapshot.patchBase)
        deletion.set(["channels", "telegram"], nil)
        #expect(try deletion.build().replacePaths == ["channels.telegram.allowFrom"])
    }

    @Test
    func diffSkipsRedactedSentinelsAndApplyMatchesRFC7386() throws {
        let snapshot = try ConfigGetSnapshot.decode(Data(Self.snapshotJSON.utf8))
        var target = snapshot.patchBase
        var gateway = target["gateway"]?.dictionaryValue ?? [:]
        gateway["port"] = AnyCodable(.int(18_801))
        target["gateway"] = AnyCodable(.object(gateway))
        target.removeValue(forKey: "channels")
        var builder = ConfigMergePatchBuilder(base: snapshot.patchBase)
        builder.diff(to: target)
        let payload = try builder.build()
        #expect(payload.patch["gateway"]?.dictionaryValue?["auth"] == nil)
        #expect(payload.patch["gateway"]?.dictionaryValue?["port"]?.intValue == 18_801)
        #expect(payload.patch["channels"]?.isNull == true)
        #expect(payload.replacePaths == ["channels.telegram.allowFrom"])
        #expect(ConfigMergePatchBuilder.apply(payload.patch, to: snapshot.patchBase) == target)
    }

    @Test
    func schemaLookupPathValidationMatchesProtocol() {
        #expect(ConfigRPC.isValidSchemaLookupPath("agents.entries.*.tools"))
        #expect(ConfigRPC.isValidSchemaLookupPath("models.providers.custom.models[].input"))
        #expect(!ConfigRPC.isValidSchemaLookupPath("agents entries"))
        #expect(!ConfigRPC.isValidSchemaLookupPath(""))
        #expect(!ConfigRPC.isValidSchemaLookupPath(String(repeating: "a", count: 1_025)))
    }

    @Test
    func writeResultDecodesChangedPaths() throws {
        let json = #"""
        {"ok": true, "path": "/x/openclaw.json", "hash": "h2", "config": {"gateway": {"port": 1}},
         "changedPaths": ["gateway.port"], "restart": {"scheduled": false}}
        """#
        let result = try JSONDecoder().decode(ConfigWriteResult.self, from: Data(json.utf8))
        #expect(result.ok)
        #expect(!result.noop)
        #expect(result.hash == "h2")
        #expect(result.config?.gateway?.port == 1)
        #expect(result.changedPaths == ["gateway.port"])
    }

    actor RecordingSender: ConfigRPCRequestSending {
        var calls: [(String, [String: AnyCodable]?)] = []
        func request(method: String, params: [String: AnyCodable]?, timeoutMs: Double?) async throws -> Data {
            self.calls.append((method, params))
            if method == "config.get" {
                return Data(ConfigRPCHelperTests.snapshotJSON.utf8)
            }
            return Data(#"{"ok": true, "changedPaths": ["gateway.port"], "hash": "h2"}"#.utf8)
        }
    }

    @Test
    func clientHelpersSendPatchWithBaseHash() async throws {
        let sender = RecordingSender()
        let snapshot = try await sender.fetchConfigSnapshot()
        let result = try await sender.patchConfig(from: snapshot) { builder in
            builder.set(["gateway", "port"], AnyCodable(.int(19_001)))
        }
        #expect(result.changedPaths == ["gateway.port"])
        let calls = await sender.calls
        #expect(calls.map(\.0) == ["config.get", "config.patch"])
        #expect(calls.last?.1?["baseHash"]?.stringValue == "abc123")
    }
}
