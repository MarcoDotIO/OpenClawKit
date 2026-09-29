import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol
import Testing

// Cross-platform smoke checks for the OpenClaw 2026.9.6 protocol sync. Unlike
// LinuxRuntimeSmokeTests these run on every host, so Linux CI exercises the vendored
// models, the typed AnyCodable accessors and the catalog-driven in-process server.
@Suite("Protocol sync smoke")
struct ProtocolSyncSmokeTests {
    @Test
    func helloOkAndErrorResponseFramesDecode() throws {
        let hello = Data(
            #"""
            {
              "type": "res",
              "id": "connect-1",
              "ok": true,
              "payload": {
                "type": "hello-ok",
                "protocol": 4,
                "server": { "version": "2026.9.6" },
                "features": { "methods": ["sessions.list"], "events": ["tick"] },
                "snapshot": {
                  "presence": [],
                  "health": {},
                  "stateVersion": { "presence": 1, "health": 2 },
                  "uptimeMs": 9001
                },
                "pluginSurfaceUrls": { "canvas": "https://gateway.example/canvas" },
                "auth": { "role": "operator", "scopes": ["operator.read"] },
                "policy": { "tickIntervalMs": 30000 }
              }
            }
            """#.utf8
        )
        guard case .res(let response) = try JSONDecoder().decode(GatewayFrame.self, from: hello) else {
            Issue.record("Expected a response frame")
            return
        }
        let ok = try GatewayPayloadCodec.decode(HelloOk.self, from: response.payload)
        #expect(ok._protocol == GATEWAY_PROTOCOL_VERSION)
        #expect(ok.pluginsurfaceurls?["canvas"]?.stringValue == "https://gateway.example/canvas")
        #expect(ok.auth["scopes"]?.arrayValue?.compactMap(\.stringValue) == ["operator.read"])
        #expect(ok.policy["tickIntervalMs"]?.intValue == 30_000)
        #expect(ok.snapshot.stateversion.health == 2)

        let failure = Data(
            #"""
            {
              "type": "res",
              "id": "r2",
              "ok": false,
              "error": {
                "code": "FORBIDDEN",
                "message": "missing scope: operator.admin",
                "details": { "code": "MISSING_SCOPE", "missingScope": "operator.admin", "requiredScopes": ["operator.admin"] }
              }
            }
            """#.utf8
        )
        guard case .res(let failed) = try JSONDecoder().decode(GatewayFrame.self, from: failure) else {
            Issue.record("Expected a response frame")
            return
        }
        let error = try #require(failed.error)
        #expect(error.errorCode == .forbidden)
        #expect(error.typedDetails?.missingscope == "operator.admin")
    }

    @Test
    func anyCodableKeepsNumberKindsAndGeneratedCompatAccessorsWork() throws {
        let decoded = try JSONDecoder().decode(
            AnyCodable.self,
            from: Data(#"{"one":1,"yes":true,"ts":1800000000000,"half":0.5}"#.utf8)
        )
        let object = try #require(decoded.dictionaryValue)
        #expect(object["one"]?.boolValue == nil)
        #expect(object["one"]?.intValue == 1)
        #expect(object["yes"]?.boolValue == true)
        #expect(object["ts"]?.int64Value == 1_800_000_000_000)
        #expect(object["half"]?.doubleValue == 0.5)
        #expect(AnyCodable(ErrorShape(code: "UNAVAILABLE", message: "busy")).dictionaryValue?["code"]?.stringValue == "UNAVAILABLE")

        #expect(ChatSendParams(sessionkey: "main", message: "hi", fastmode: true, idempotencykey: "k").fastmode == true)
        #expect(AgentsUpdateParams(agentid: "work", model: "openai/gpt-5.6").model == "openai/gpt-5.6")
    }

    @Test
    func inProcessServerUsesTheMethodCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("protocol-sync-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = GatewayServer(
            sessionStore: SessionStore(fileURL: root.appendingPathComponent("sessions.json")),
            secretVault: GatewaySecretVault(credentialStore: FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json")))
        )
        func call(_ method: String) async -> ResponseFrame {
            await server.handle(RequestFrame(type: "req", id: UUID().uuidString, method: method, params: AnyCodable([String: AnyCodable]())))
        }

        #expect(await call("sessions.list").ok == true)
        #expect(await call("health").error?.errorCode == .unavailable)
        #expect(await call("sessions.compaction.list").error?.errorCode == .invalidRequest)
        #expect(await call("not.a.method").error?.errorCode == .invalidRequest)
        #expect(GatewayMethodCatalog.descriptors.count == 482)
    }
}
