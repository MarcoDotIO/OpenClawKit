import Foundation
import Testing
@testable import OpenClawChatUI

@Suite("OpenClaw chat UI")
struct OpenClawChatUITests {
    @Test
    func chatPayloadDecodingSupportsLegacyStringContentAndUsageFallback() throws {
        let payload = AnyCodable([
            "role": AnyCodable("assistant"),
            "content": AnyCodable("Hello from Chat UI"),
            "tool_call_id": AnyCodable("call-123"),
            "tool_name": AnyCodable("browser"),
            "usage": AnyCodable([
                "input": AnyCodable(12),
                "output": AnyCodable(4),
                "totalTokens": AnyCodable(16),
            ]),
            "stopReason": AnyCodable("end_turn"),
        ])

        let decoded: OpenClawChatMessage = try ChatPayloadDecoding.decode(payload)

        #expect(decoded.role == "assistant")
        #expect(decoded.content.count == 1)
        #expect(decoded.content.first?.text == "Hello from Chat UI")
        #expect(decoded.toolCallId == "call-123")
        #expect(decoded.toolName == "browser")
        #expect(decoded.usage?.total == 16)
        #expect(decoded.stopReason == "end_turn")
    }

    @Test
    func chatMarkdownPreprocessorStripsInboundMetadataAndExtractsInlineImages() {
        let raw = """
        [Slack 2026-03-14 10:00]
        Conversation info (untrusted metadata):
        ```json
        {"channel":"ops"}
        ```
        [message_id: 123]

        Please help with this.

        ![diagram](data:image/png;base64,AA==)
        """

        let result = ChatMarkdownPreprocessor.preprocess(markdown: raw)

        #expect(result.cleaned == "Please help with this.")
        #expect(result.images.count == 1)
        #expect(result.images.first?.label == "diagram")
    }

    @Test
    func toolResultFormatterSummarizesNodeListsAndErrors() {
        let nodes = ToolResultTextFormatter.format(
            text: #"""
            {"nodes":[
              {"displayName":"Phone","connected":true,"platform":"iOS","osVersion":"18.0"},
              {"name":"Tablet","connected":false}
            ]}
            """#,
            toolName: "nodes"
        )
        let error = ToolResultTextFormatter.format(
            text: #"""
            {"status":"error","message":"agent=main action=run: timed out waiting for gateway\ntrace"}
            """#,
            toolName: nil
        )

        #expect(nodes.contains("2 nodes found."))
        #expect(nodes.contains("Phone - connected, iOS, 18.0"))
        #expect(nodes.contains("Tablet - offline"))
        #expect(error == "Error: timed out waiting for gateway")
    }

    @Test
    func chatViewModelBootstrapLoadsHistoryModelsAndSessions() async {
        let transport = MockChatTransport(
            historyBySession: [
                "main": OpenClawChatHistoryPayload(
                    sessionKey: "main",
                    sessionId: "run-1",
                    messages: [
                        AnyCodable([
                            "role": AnyCodable("user"),
                            "timestamp": AnyCodable(1_000.0),
                            "content": AnyCodable(
                                """
                                [Slack 2026-03-14 10:00]
                                Conversation info (untrusted metadata):
                                ```json
                                {"channel":"ops"}
                                ```
                                [message_id: 123]

                                Please help.
                                """
                            ),
                        ]),
                    ],
                    thinkingLevel: "high"
                ),
            ],
            models: [
                OpenClawChatModelChoice(
                    modelID: "gpt-4.1",
                    name: "GPT-4.1",
                    provider: "openai",
                    contextWindow: 128_000
                ),
            ],
            sessionsResponse: OpenClawChatSessionsListResponse(
                ts: 1_000,
                path: "/tmp/sessions.json",
                count: 1,
                defaults: OpenClawChatSessionsDefaults(model: "gpt-4.1", contextTokens: 128_000, mainSessionKey: "main"),
                sessions: [
                    OpenClawChatSessionEntry(
                        key: "main",
                        kind: "chat",
                        displayName: "Main",
                        surface: nil,
                        subject: nil,
                        room: nil,
                        space: nil,
                        updatedAt: 1_000,
                        sessionId: "run-1",
                        systemSent: nil,
                        abortedLastRun: nil,
                        thinkingLevel: "high",
                        verboseLevel: nil,
                        inputTokens: 12,
                        outputTokens: 4,
                        totalTokens: 16,
                        modelProvider: "openai",
                        model: "gpt-4.1",
                        contextTokens: 128_000
                    ),
                ]
            ),
            healthOK: true
        )

        let viewModel = await MainActor.run {
            OpenClawChatViewModel(sessionKey: "main", transport: transport)
        }

        await MainActor.run {
            viewModel.load()
        }

        let loaded = await Self.waitUntil {
            await MainActor.run {
                !viewModel.isLoading &&
                    viewModel.healthOK &&
                    viewModel.messages.count == 1 &&
                    viewModel.modelChoices.count == 1
            }
        }

        #expect(loaded)
        await MainActor.run {
            #expect(viewModel.thinkingLevel == "high")
            #expect(viewModel.messages.first?.content.first?.text == "Please help.")
            #expect(viewModel.showsModelPicker)
            #expect(viewModel.defaultModelLabel == "Default: openai/gpt-4.1")
            #expect(viewModel.sessionChoices.first?.key == "main")
            #expect(viewModel.sessionChoices.first?.displayName == "Main")
        }
        #expect(transport.activeSessionKeys == ["main"])
        #expect(transport.historyRequests == ["main"])
    }

    @Test
    func chatViewModelAppliesAgentStreamAndPendingToolEvents() async {
        let transport = MockChatTransport(
            historyBySession: [
                "main": OpenClawChatHistoryPayload(
                    sessionKey: "main",
                    sessionId: "run-1",
                    messages: [],
                    thinkingLevel: "off"
                ),
            ],
            models: [],
            sessionsResponse: OpenClawChatSessionsListResponse(
                ts: 1_000,
                path: nil,
                count: 1,
                defaults: OpenClawChatSessionsDefaults(model: nil, contextTokens: nil, mainSessionKey: "main"),
                sessions: [
                    OpenClawChatSessionEntry(
                        key: "main",
                        kind: "chat",
                        displayName: "Main",
                        surface: nil,
                        subject: nil,
                        room: nil,
                        space: nil,
                        updatedAt: 1_000,
                        sessionId: "run-1",
                        systemSent: nil,
                        abortedLastRun: nil,
                        thinkingLevel: nil,
                        verboseLevel: nil,
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: nil,
                        modelProvider: nil,
                        model: nil,
                        contextTokens: nil
                    ),
                ]
            ),
            healthOK: true
        )

        let viewModel = await MainActor.run {
            OpenClawChatViewModel(sessionKey: "main", transport: transport)
        }

        await MainActor.run {
            viewModel.load()
        }

        let bootstrapped = await Self.waitUntil {
            await MainActor.run { !viewModel.isLoading && viewModel.healthOK }
        }
        #expect(bootstrapped)

        transport.emit(
            .agent(
                OpenClawAgentEventPayload(
                    runId: "run-1",
                    seq: 1,
                    stream: "assistant",
                    ts: 1,
                    data: ["text": AnyCodable("streaming reply")]
                )
            )
        )

        let sawStreamingText = await Self.waitUntil {
            await MainActor.run { viewModel.streamingAssistantText == "streaming reply" }
        }
        #expect(sawStreamingText)

        transport.emit(
            .agent(
                OpenClawAgentEventPayload(
                    runId: "run-1",
                    seq: 2,
                    stream: "tool",
                    ts: 2,
                    data: [
                        "phase": AnyCodable("start"),
                        "name": AnyCodable("browser"),
                        "toolCallId": AnyCodable("tool-1"),
                        "args": AnyCodable(["url": AnyCodable("https://docs.openclaw.ai")]),
                    ]
                )
            )
        )

        let sawPendingTool = await Self.waitUntil {
            await MainActor.run { viewModel.pendingToolCalls.count == 1 }
        }
        #expect(sawPendingTool)
        await MainActor.run {
            #expect(viewModel.pendingToolCalls.first?.name == "browser")
            #expect(viewModel.pendingToolCalls.first?.args?.dictionaryValue?["url"] == AnyCodable("https://docs.openclaw.ai"))
        }

        transport.emit(
            .agent(
                OpenClawAgentEventPayload(
                    runId: "run-1",
                    seq: 3,
                    stream: "tool",
                    ts: 3,
                    data: [
                        "phase": AnyCodable("result"),
                        "name": AnyCodable("browser"),
                        "toolCallId": AnyCodable("tool-1"),
                    ]
                )
            )
        )

        let clearedTool = await Self.waitUntil {
            await MainActor.run { viewModel.pendingToolCalls.isEmpty }
        }
        #expect(clearedTool)
    }

    private static func waitUntil(
        timeoutMs: Int = 1_000,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

private final class MockChatTransport: @unchecked Sendable, OpenClawChatTransport {
    let historyBySession: [String: OpenClawChatHistoryPayload]
    let models: [OpenClawChatModelChoice]
    let sessionsResponse: OpenClawChatSessionsListResponse
    let healthOK: Bool

    private let stream: AsyncStream<OpenClawChatTransportEvent>
    private var continuation: AsyncStream<OpenClawChatTransportEvent>.Continuation?

    var historyRequests: [String] = []
    var activeSessionKeys: [String] = []

    init(
        historyBySession: [String: OpenClawChatHistoryPayload],
        models: [OpenClawChatModelChoice],
        sessionsResponse: OpenClawChatSessionsListResponse,
        healthOK: Bool
    ) {
        self.historyBySession = historyBySession
        self.models = models
        self.sessionsResponse = sessionsResponse
        self.healthOK = healthOK

        var continuation: AsyncStream<OpenClawChatTransportEvent>.Continuation?
        self.stream = AsyncStream<OpenClawChatTransportEvent> { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        self.historyRequests.append(sessionKey)
        return self.historyBySession[sessionKey] ?? OpenClawChatHistoryPayload(
            sessionKey: sessionKey,
            sessionId: nil,
            messages: [],
            thinkingLevel: nil
        )
    }

    func listModels() async throws -> [OpenClawChatModelChoice] {
        self.models
    }

    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]
    ) async throws -> OpenClawChatSendResponse {
        OpenClawChatSendResponse(runId: idempotencyKey, status: "queued")
    }

    func abortRun(sessionKey: String, runId: String) async throws {}

    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse {
        self.sessionsResponse
    }

    func setSessionModel(sessionKey: String, model: String?) async throws {}

    func setSessionThinking(sessionKey: String, thinkingLevel: String) async throws {}

    func requestHealth(timeoutMs: Int) async throws -> Bool {
        self.healthOK
    }

    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        self.stream
    }

    func setActiveSessionKey(_ sessionKey: String) async throws {
        self.activeSessionKeys.append(sessionKey)
    }

    func resetSession(sessionKey: String) async throws {}

    func emit(_ event: OpenClawChatTransportEvent) {
        self.continuation?.yield(event)
    }
}
