import Foundation
import Testing
@testable import OpenClawChatUI
@testable import OpenClawKit

/// The in-process server's session rows, `sessions.changed`, `session.message` and protocol-v4
/// `chat` payloads decode through the ChatUI transport models.
@Suite("Gateway server ChatUI compatibility")
struct GatewayServerChatUICompatTests {
    private func makeStack(_ name: String, turns: [String]) async throws -> (GatewayServer, EmbeddedAgentRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        let router = ModelRouter()
        await router.register(QueueProvider(texts: turns))
        try await router.setDefaultProviderID("queue")
        let store = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        let runtime = EmbeddedAgentRuntime(
            modelRouter: router,
            sessionStore: store,
            transcriptStore: JSONLSessionTranscriptStore(directory: root.appendingPathComponent("transcripts"))
        )
        let server = GatewayServer(
            sessionStore: store,
            secretVault: GatewaySecretVault(credentialStore: FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json")))
        )
        await runtime.attach(to: server)
        return (server, runtime, root)
    }

    actor QueueProvider: ModelProvider {
        let id = "queue"
        private var texts: [String]

        init(texts: [String]) {
            self.texts = texts
        }

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            ModelGenerationResponse(text: self.texts.isEmpty ? "done" : self.texts.removeFirst(), providerID: self.id, modelID: "queue-1")
        }
    }

    actor FrameRecorder {
        private(set) var frames: [EventFrame] = []
        func record(_ frame: EventFrame) { self.frames.append(frame) }

        func wait(_ predicate: @Sendable ([EventFrame]) -> Bool) async -> [EventFrame] {
            for _ in 0..<500 {
                if predicate(self.frames) { return self.frames }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return self.frames
        }
    }

    @Test
    func sessionRowsAndListDecodeAsChatSessionEntries() async throws {
        let (server, _, root) = try await self.makeStack("chatui-rows", turns: [])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await server.handle(RequestFrame(type: "req", id: "1", method: "sessions.patch", params: AnyCodable([
            "key": AnyCodable("agent:main:main"),
            "label": AnyCodable("Primary"),
            "pinned": AnyCodable(true),
            "fastMode": AnyCodable("auto"),
            "permissionMode": AnyCodable("workspace"),
            "toolOverrides": AnyCodable(["webSearch": AnyCodable(false)]),
            "color": AnyCodable("teal"),
        ])))
        let list = await server.handle(RequestFrame(type: "req", id: "2", method: "sessions.list", params: nil))
        let decoded = try GatewayPayloadCodec.decode(OpenClawChatSessionsListResponse.self, from: list.payload)
        let entry = try #require(decoded.sessions.first)
        #expect(entry.key == "agent:main:main")
        #expect(entry.kind == "direct")
        #expect(entry.agentId == "main")
        #expect(entry.label == "Primary")
        #expect(entry.pinned == true)
        #expect(entry.color == "teal")
        #expect(entry.fastMode == .automatic)
        #expect(entry.permissionMode == .workspace)
        #expect(entry.toolOverrides?.webSearch == false)
        #expect((entry.updatedAt ?? 0) > 1_600_000_000_000)
        #expect(decoded.count == 1)
    }

    @Test
    func runEventsDecodeThroughChatTransportModels() async throws {
        let (server, _, root) = try await self.makeStack("chatui-events", turns: ["hello there"])
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = FrameRecorder()
        let client = GatewayClient(
            socketFactory: { LoopbackGatewaySocket(server: server, connection: GatewayConnectionContext(connectionID: "chatui", scopes: ["operator.admin"])) },
            onEvent: { await recorder.record($0) }
        )
        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        _ = try await client.send(method: "sessions.messages.subscribe", params: ["key": AnyCodable("agent:main:main")])
        let ack = try await client.send(method: "chat.send", params: [
            "sessionKey": AnyCodable("agent:main:main"),
            "message": AnyCodable("hi"),
            "idempotencyKey": AnyCodable("ui-run-1"),
        ])
        let send = try GatewayPayloadCodec.decode(OpenClawChatSendResponse.self, from: ack.payload)
        #expect(send.runId == "ui-run-1")

        let frames = await recorder.wait { frames in
            frames.contains { $0.event == "chat" && $0.payload?.dictionaryValue?["state"] == AnyCodable("final") }
                && frames.filter { $0.event == "session.message" }.count >= 2
                && frames.contains { $0.event == "sessions.changed" && $0.payload?.dictionaryValue?["phase"] == AnyCodable("end") }
        }
        await client.disconnect()

        let chat = try frames.filter { $0.event == "chat" }.map { try GatewayPayloadCodec.decode(OpenClawChatEventPayload.self, from: $0.payload) }
        #expect(chat.first?.kind == .status)
        let delta = try #require(chat.first { $0.kind == .delta })
        #expect(delta.runId == "ui-run-1")
        #expect(delta.deltaText == "hello there")
        let final = try #require(chat.last)
        #expect(final.kind == .final)
        #expect(final.stopReason == "stop")
        #expect(OpenClawChatEventText.assistantText(from: final) == "hello there")

        let messages = try frames.filter { $0.event == "session.message" }
            .map { try GatewayPayloadCodec.decode(OpenClawSessionMessageEventPayload.self, from: $0.payload) }
        #expect(messages.map { $0.message?.role } == ["user", "assistant"])
        #expect(messages.map(\.messageSeq) == [1, 2])

        let changes = try frames.filter { $0.event == "sessions.changed" }
            .map { try GatewayPayloadCodec.decode(OpenClawChatSessionsChangedEvent.self, from: $0.payload) }
        let end = try #require(changes.last { $0.phase == "end" })
        #expect(end.sessionKey == "agent:main:main")
        #expect(end.status == "done")
        #expect(end.hasActiveRun == false)
        #expect(end.session?.key == "agent:main:main")
    }
}
