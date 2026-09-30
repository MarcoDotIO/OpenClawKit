import Foundation
import Testing
@testable import OpenClawKit

@Suite("Embedded agent stack", .timeLimit(.minutes(1)))
struct EmbeddedAgentStackTests {
    struct ToolCallingProvider: ModelProvider {
        let id = "stack"
        let capabilities = ModelProviderCapabilities(supportsTools: true, supportsTranscript: true)

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            ModelGenerationResponse(text: "stack says \(request.messages.last?.text ?? "")", providerID: self.id, modelID: "stack-1")
        }
    }

    @Test
    func stackPersistsTranscriptsAndServesRuntimeRPCs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let router = ModelRouter(defaultProviderID: "stack", providers: [ToolCallingProvider()])
        let stack = try await OpenClawSDK.shared.makeEmbeddedAgentStack(
            stateDirectory: root,
            credentialStore: FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json")),
            modelRouter: router
        )
        let tools = await stack.runtime.toolRegistry.descriptors().map(\.name)
        #expect(tools.contains("ask_user"))
        #expect(tools.contains("sessions_spawn"))
        #expect(tools.contains("create_goal"))

        let sent = await stack.server.handle(
            RequestFrame(type: "req", id: "1", method: "sessions.send", params: AnyCodable(["key": AnyCodable("agent:main:main"), "message": AnyCodable("hi")]))
        )
        let runID = try #require(sent.payload?.dictionaryValue?["runId"]?.stringValue)
        #expect(try await awaitCancellable("sent run finished") { await stack.runtime.wait(runID: runID) }?.output == "stack says hi")

        let history = await stack.server.handle(
            RequestFrame(type: "req", id: "2", method: "chat.history", params: AnyCodable(["sessionKey": AnyCodable("agent:main:main")]))
        )
        #expect(history.payload?.dictionaryValue?["messages"]?.arrayValue?.count == 2)
        let sessionID = try #require(await stack.sessionStore.recordForKey("agent:main:main")?.sessionID)
        let transcriptFile = JSONLSessionTranscriptStore.defaultDirectory(stateDirectory: root, agentID: "main")
            .appendingPathComponent("\(sessionID).jsonl")
        #expect(FileManager.default.fileExists(atPath: transcriptFile.path))

        let tasks = await stack.server.handle(RequestFrame(type: "req", id: "3", method: "tasks.list", params: AnyCodable([String: AnyCodable]())))
        #expect(tasks.ok)
    }
}
