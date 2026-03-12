import Foundation
import Testing
@testable import OpenClawCore
@testable import OpenClawProtocol

@Suite("Protocol models")
struct ProtocolModelsTests {
    @Test
    func protocolVersionAndErrorCodesAreStable() {
        #expect(GATEWAY_PROTOCOL_VERSION == 3)
        #expect(ErrorCode.notLinked.rawValue == "NOT_LINKED")
        #expect(ErrorCode.unavailable.rawValue == "UNAVAILABLE")
    }

    @Test
    func requestFrameRoundTrip() throws {
        let frame = RequestFrame(
            type: "req",
            id: "abc",
            method: "agent.run",
            params: AnyCodable(["prompt": AnyCodable("hello")])
        )

        let encoded = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(RequestFrame.self, from: encoded)

        #expect(decoded.type == "req")
        #expect(decoded.id == "abc")
        #expect(decoded.method == "agent.run")
    }

    @Test
    func gatewayFrameEncodeDecode() throws {
        let response = ResponseFrame(
            type: "res",
            id: "r1",
            ok: true,
            payload: AnyCodable(["status": AnyCodable("accepted")]),
            error: nil
        )
        let frame = GatewayFrame.res(response)

        let encoded = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(GatewayFrame.self, from: encoded)

        switch decoded {
        case .res(let payload):
            #expect(payload.ok == true)
            #expect(payload.id == "r1")
        default:
            Issue.record("Expected .res frame")
        }
    }

    @Test
    func typedGatewayPayloadCodecRoundTrips() throws {
        let payload = GatewaySessionPatchParams(
            key: "main",
            label: "Primary",
            modelOverride: "openai/gpt-5.4",
            thinkingLevel: "adaptive",
            sendPolicy: "allow"
        )

        let encoded = try GatewayPayloadCodec.encode(payload)
        let decoded = try GatewayPayloadCodec.decode(GatewaySessionPatchParams.self, from: encoded)

        #expect(decoded == payload)
    }

    @Test
    func browserRequestPayloadRoundTrips() throws {
        let payload = GatewayBrowserRequestParams(
            method: "POST",
            path: "/act",
            query: ["profile": "default"],
            body: AnyCodable(["kind": AnyCodable("resize")]),
            timeoutMs: 3_000,
            workspaceRoot: "/tmp/workspace",
            spawnedWorkspaceRoot: "/tmp/spawned"
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(GatewayBrowserRequestParams.self, from: encoded)

        #expect(decoded == payload)
    }

    @Test
    func typedGatewayModelsCoverConstructorsAndNilPayloadDecoding() throws {
        let connect = ConnectParams(
            minProtocol: 1,
            maxProtocol: 3,
            client: ["name": AnyCodable("OpenClawKit")],
            caps: ["sessions", "skills"],
            commands: ["agent.run"],
            permissions: ["exec": AnyCodable(true)],
            pathEnv: "/usr/bin",
            role: "sdk",
            scopes: ["runtime"],
            device: ["platform": AnyCodable("macos")],
            auth: ["kind": AnyCodable("oauth")]
        )
        #expect(connect.maxProtocol == 3)
        #expect(connect.client["name"] == AnyCodable("OpenClawKit"))

        let event = EventFrame(
            type: "event",
            event: "tick",
            payload: AnyCodable(["seq": AnyCodable(7)]),
            seq: 7
        )
        let eventEncoded = try JSONEncoder().encode(GatewayFrame.event(event))
        let eventDecoded = try JSONDecoder().decode(GatewayFrame.self, from: eventEncoded)
        switch eventDecoded {
        case .event(let payload):
            #expect(payload.event == "tick")
            #expect(payload.seq == 7)
        default:
            Issue.record("Expected .event frame")
        }

        let requestEncoded = try JSONEncoder().encode(
            GatewayFrame.req(
                RequestFrame(type: "req", id: "req-1", method: "sessions.list", params: AnyCodable([String: AnyCodable]()))
            )
        )
        let requestDecoded = try JSONDecoder().decode(GatewayFrame.self, from: requestEncoded)
        switch requestDecoded {
        case .req(let payload):
            #expect(payload.method == "sessions.list")
        default:
            Issue.record("Expected .req frame")
        }

        do {
            let _ = try JSONDecoder().decode(GatewayFrame.self, from: Data(#"{"type":"bogus"}"#.utf8))
            Issue.record("Expected invalid gateway frame type to fail decoding")
        } catch {
            #expect(String(describing: error).contains("Unsupported frame type"))
        }

        let empty = try GatewayPayloadCodec.decode(EmptyPayload.self, from: nil)
        #expect(empty == EmptyPayload())

        let optionalString = try GatewayPayloadCodec.decode(String?.self, from: nil)
        #expect(optionalString == nil)

        let accepted = GatewayAgentAccepted(runID: "run-1")
        let wait = GatewayAgentWaitResult(
            runID: "run-1",
            status: "ok",
            sessionKey: "main",
            output: "output",
            error: nil
        )
        let session = GatewaySessionInfo(
            key: "main",
            agentID: "assistant",
            updatedAtMs: 42,
            channel: "telegram",
            accountID: "acct",
            peerID: "peer",
            label: "Primary",
            modelOverride: "openai/gpt-5.4",
            thinkingLevel: "xhigh",
            verboseLevel: "full",
            reasoningLevel: "stream",
            responseUsage: "full",
            elevatedLevel: "ask",
            groupActivation: "always",
            sendPolicy: "allow",
            execHost: "gateway",
            execSecurity: "allowlist",
            execAsk: "on-miss",
            execNode: "node-20"
        )
        let models = GatewayModelsListResult(
            models: [
                GatewayModelCatalogEntry(
                    providerID: "openai",
                    modelID: "gpt-5.4",
                    displayName: "GPT-5.4",
                    api: "responses",
                    authMode: "oauth"
                ),
            ]
        )
        let skills = GatewaySkillsListResult(
            skills: [
                GatewaySkillDescriptor(
                    name: "hello",
                    description: "hello skill",
                    source: "workspace",
                    entrypoint: "scripts/hello.sh",
                    userInvocable: true
                ),
            ]
        )
        let secrets = GatewaySecretsListResult(secrets: [GatewaySecretDescriptor(key: "openai")])
        let mutation = GatewaySessionMutationResult(ok: true, key: "main", session: session, deleted: false)
        let browserResponse = GatewayBrowserResponse(
            status: 200,
            headers: ["content-type": "application/json"],
            body: AnyCodable(["ok": AnyCodable(true)])
        )
        let invokedSkill = GatewaySkillInvokeResult(skillName: "hello", output: "world", executorID: "shell", durationMs: 5)
        let setSecret = GatewaySecretSetParams(key: "openai", value: "token")
        let deleteSecret = GatewaySecretDeleteParams(key: "openai")
        let browserRequest = GatewayBrowserRequestParams(
            method: "GET",
            path: "/browser",
            query: ["profile": "default"],
            body: AnyCodable(["refresh": AnyCodable(true)]),
            timeoutMs: 100,
            workspaceRoot: "/tmp/workspace",
            spawnedWorkspaceRoot: "/tmp/spawned"
        )
        let payloads: [Any] = [
            accepted,
            wait,
            GatewayAgentRequest(sessionKey: "main", prompt: "hello", message: "world", modelProviderID: "openai", modelID: "gpt-5.4", timeoutMs: 123, deliver: true),
            GatewayAgentWaitParams(runID: "run-1", timeoutMs: 100),
            GatewaySessionListResult(sessions: [session]),
            GatewaySessionGetParams(key: "main"),
            GatewaySessionGetResult(session: session),
            GatewaySessionPatchParams(
                key: "main",
                agentID: "assistant",
                label: "Primary",
                modelOverride: "openai/gpt-5.4",
                thinkingLevel: "adaptive",
                verboseLevel: "full",
                reasoningLevel: "stream",
                responseUsage: "full",
                elevatedLevel: "ask",
                groupActivation: "always",
                sendPolicy: "allow",
                execHost: "gateway",
                execSecurity: "allow-list",
                execAsk: "on_miss",
                execNode: "node-20"
            ),
            GatewaySessionKeyParams(key: "main"),
            mutation,
            models,
            skills,
            GatewaySkillInvokeParams(name: "hello", input: "world"),
            invokedSkill,
            secrets,
            setSecret,
            deleteSecret,
            GatewaySecretMutationResult(ok: true, key: "openai", deleted: true),
            browserRequest,
            browserResponse,
        ]
        #expect(payloads.count == 20)
    }

    @Test
    func replayEventEnvelopeRoundTripMaintainsSchemaContract() throws {
        let event = ReplayEvent(
            schemaVersion: 1,
            eventID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            sequenceNumber: 42,
            subsystem: "runtime",
            name: "run.completed",
            runID: "run-123",
            sessionKey: "session-main",
            occurredAt: Date(timeIntervalSince1970: 1_234_567),
            metadata: [
                "providerID": "openai",
                "latencyMs": "122",
            ],
            payload: AnyCodable([
                "usage": AnyCodable(["totalTokens": AnyCodable(98)]),
            ])
        )
        let envelope = ReplayEventEnvelope(
            event: event,
            previousEventHash: "aa",
            eventHash: "bb",
            signature: ReplayEventSignature(
                algorithm: "secp256r1-sha256",
                keyID: "device-key-1",
                value: "ZmFrZS1zaWduYXR1cmU="
            ),
            recordedAt: Date(timeIntervalSince1970: 1_234_568)
        )

        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(ReplayEventEnvelope.self, from: encoded)
        #expect(decoded == envelope)
    }

    @Test
    func mediaAttachmentRoundTripPreservesBytesAndMetadata() throws {
        let attachment = MediaAttachment(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            mimeType: "image/png",
            data: Data([0, 17, 222, 255]),
            fileName: "camera-shot.png",
            metadata: [
                "source": "camera",
                "kind": "image",
            ]
        )

        let encoded = try JSONEncoder().encode(attachment)
        let decoded = try JSONDecoder().decode(MediaAttachment.self, from: encoded)

        #expect(decoded == attachment)
        #expect(decoded.byteCount == 4)
    }
}
