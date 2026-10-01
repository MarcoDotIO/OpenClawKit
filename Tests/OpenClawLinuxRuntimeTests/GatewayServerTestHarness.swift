import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

/// Shared helpers for the 2026.3.0 gateway suites (wire shapes, events, tools, branches, organization).
enum GatewayServerTestHarness {
    struct Stack {
        let server: GatewayServer
        let runtime: EmbeddedAgentRuntime
        let store: SessionStore
        let root: URL
    }

    static func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    /// A bare server (no runtime attached).
    static func bareServer(
        _ name: String,
        handlers: GatewayServerHandlers = GatewayServerHandlers(),
        startupPending: Bool = false
    ) -> (GatewayServer, SessionStore) {
        let root = self.temporaryRoot(name)
        let store = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        let server = GatewayServer(
            sessionStore: store,
            secretVault: GatewaySecretVault(credentialStore: InMemoryTestCredentialStore()),
            handlers: handlers,
            startupPending: startupPending
        )
        return (server, store)
    }

    /// A server with an attached runtime driven by a scripted provider.
    static func runtimeStack(
        _ name: String,
        turns: [ScriptedToolProvider.Turn],
        fallback: ScriptedToolProvider.Turn? = nil,
        tools: [any AgentTool] = [EchoArgumentTool()],
        options: AgentGatewayOptions = AgentGatewayOptions()
    ) async -> Stack {
        let root = self.temporaryRoot(name)
        let store = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        let provider = ScriptedToolProvider(turns: turns, fallback: fallback)
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: tools),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            sessionStore: store,
            transcriptStore: JSONLSessionTranscriptStore(directory: root.appendingPathComponent("transcripts"))
        )
        let server = GatewayServer(
            sessionStore: store,
            secretVault: GatewaySecretVault(credentialStore: InMemoryTestCredentialStore())
        )
        await runtime.attach(to: server, options: options)
        return Stack(server: server, runtime: runtime, store: store, root: root)
    }

    static func call(
        _ server: GatewayServer,
        _ method: String,
        _ params: [String: AnyCodable] = [:],
        connection: GatewayConnectionContext = .inProcess
    ) async -> ResponseFrame {
        await server.handle(RequestFrame(type: "req", id: UUID().uuidString, method: method, params: AnyCodable(params)), connection: connection)
    }

    static func rawCall(_ server: GatewayServer, _ method: String, json: String) async throws -> ResponseFrame {
        let params = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        return await server.handle(RequestFrame(type: "req", id: UUID().uuidString, method: method, params: params))
    }

    static func payload(_ response: ResponseFrame) throws -> [String: AnyCodable] {
        try #require(response.payload?.dictionaryValue, "expected an object payload, got \(String(describing: response.error))")
    }

    /// JSON object of an encodable value.
    static func object(_ value: some Encodable) throws -> [String: AnyCodable] {
        try #require(try GatewayPayloadCodec.encode(value).dictionaryValue)
    }

    /// Collects frames until `predicate` holds for the collected list, or the stream ends.
    ///
    /// There is no wall-clock deadline: every suite that calls this carries a `.timeLimit`, whose
    /// cancellation ends the stream and the wait with ``AsyncWaitTimeoutError``.
    static func collect(
        _ stream: AsyncStream<EventFrame>,
        _ label: String,
        until predicate: @Sendable ([EventFrame]) -> Bool
    ) async throws -> [EventFrame] {
        var frames: [EventFrame] = []
        for await frame in stream {
            frames.append(frame)
            if predicate(frames) {
                return frames
            }
        }
        if Task.isCancelled {
            throw recordedWaitTimeout(label)
        }
        return frames
    }

    /// Frames that arrive within `milliseconds`, for asserting that nothing arrives. The window is
    /// deliberately wall-clock: a slow pool can only hide a stray frame, never invent one.
    static func frames(_ stream: AsyncStream<EventFrame>, arrivingWithinMs milliseconds: UInt64) async -> [EventFrame] {
        let consumer = Task {
            var frames: [EventFrame] = []
            for await frame in stream {
                frames.append(frame)
            }
            return frames
        }
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        consumer.cancel()
        return await consumer.value
    }

    /// Chat frames of a run, decoded through ``ChatEventFrame``.
    static func chatFrames(_ frames: [EventFrame], runID: String) -> [ChatEventFrame] {
        frames.filter { $0.event == "chat" }.compactMap { try? ChatEventFrame(payload: $0.payload) }.filter { $0.runID == runID }
    }

    /// Async recorder for event callbacks.
    actor Recorder {
        private(set) var frames: [EventFrame] = []

        func record(_ frame: EventFrame) {
            self.frames.append(frame)
        }

        /// Polls the recorded frames until `predicate` holds, with no wall-clock deadline (see
        /// ``GatewayServerTestHarness/collect(_:_:until:)``).
        func waitFor(_ label: String, _ predicate: @Sendable ([EventFrame]) -> Bool) async throws -> [EventFrame] {
            while !Task.isCancelled {
                if predicate(self.frames) { return self.frames }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            throw recordedWaitTimeout(label)
        }
    }
}

/// Tool whose descriptor claims a configurable source (plugin/MCP/channel inventory tests).
struct SourcedEchoTool: AgentTool {
    let name: String
    let source: AgentToolSource
    var risk: ToolRisk?

    var descriptor: AgentToolDescriptor {
        var descriptor = AgentToolDescriptor(
            name: self.name,
            description: "Sourced echo \(self.name).\nSecond line.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["text": AnyCodable(["type": AnyCodable("string")])]),
            ]
        )
        descriptor.source = self.source
        descriptor.risk = self.risk
        descriptor.tags = ["test"]
        return descriptor
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        let text = invocation.arguments["text"]?.stringValue ?? ""
        return .text("\(self.name):\(text)", details: AnyCodable(["echo": AnyCodable(text)]))
    }
}
