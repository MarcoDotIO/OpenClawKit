import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore
@testable import OpenClawModels
import OpenClawProtocol

@Suite("ChatGPT plan errors")
struct ChatGPTPlanErrorTests {
    @Test("Structured subscription-sharing codes map to recoveries")
    func structuredCodes() throws {
        let limit = try #require(ChatGPTPlanError.classify(
            statusCode: 429,
            body: Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Limit reached"}}"#.utf8),
            headers: ["Retry-After": "120"]
        ))
        #expect(limit.kind == .usageLimitReached)
        #expect(limit.isUsageLimit)
        #expect(limit.recovery == .manageUsage)
        #expect(limit.retryAfter == 120)
        #expect(limit.message == "Limit reached")

        let expectations: [(String, Int, ChatGPTPlanError.Recovery)] = [
            ("subscription_sharing_user_not_eligible", 403, .manageUsage),
            ("subscription_sharing_usage_unavailable", 503, .retryLater),
            ("subscription_sharing_unsupported_capability", 400, .changeRequest),
            ("subscription_sharing_route_not_supported", 403, .changeRequest),
            ("subscription_sharing_invalid_user", 401, .signInAgain),
            ("chatpass_v2_scope_not_authorized", 403, .signInAgain),
            ("chatpass_v2_invalid_authorization_context", 403, .signInAgain),
            ("subscription_sharing_user_unavailable", 503, .retryLater),
        ]
        for (code, status, recovery) in expectations {
            let error = try #require(ChatGPTPlanError.classify(statusCode: status, body: Data(#"{"code":"\#(code)"}"#.utf8)))
            #expect(error.code == code)
            #expect(error.recovery == recovery, "\(code)")
        }
        #expect(ChatGPTPlanError.classify(code: "chatpass_v2_scope_not_authorized")?.requiresPlanReconsent == true)
    }

    @Test("Direct-admission detail bodies and unrelated errors")
    func directAdmission() throws {
        let denied = try #require(ChatGPTPlanError.classify(statusCode: 403, body: Data(#"{"detail":"Not admitted"}"#.utf8)))
        #expect(denied.kind == .admissionDenied)
        #expect(denied.code == nil)
        #expect(denied.recovery == .manageUsage)
        #expect(ChatGPTPlanError.classify(statusCode: 401, body: Data(#"{"detail":{"message":"expired"}}"#.utf8))?.recovery == .signInAgain)
        #expect(ChatGPTPlanError.classify(statusCode: 503, body: Data(#"{"detail":"busy"}"#.utf8))?.recovery == .retryLater)
        #expect(ChatGPTPlanError.classify(statusCode: 500, body: Data(#"{"detail":"boom"}"#.utf8)) == nil)
        #expect(ChatGPTPlanError.classify(statusCode: 400, body: Data(#"{"error":{"code":"invalid_request_error"}}"#.utf8)) == nil)
        #expect(ChatGPTPlanError.classify(statusCode: 200, body: Data()) == nil)
        #expect(ChatGPTPlanError.classify(code: "direct_admission") == nil)
        let long = String(repeating: "x", count: 900)
        #expect((ChatGPTPlanError.classify(code: "subscription_sharing_usage_unavailable", message: long)?.message?.count ?? 0) <= 501)
    }
}

/// Scripted Responses endpoint for the plan provider.
actor PlanResponsesStub: OpenAICompatibleHTTPTransport, ModelHTTPStreamingTransport {
    struct Reply {
        var status: Int
        var lines: [String]
        var headers: [String: String] = [:]
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private var dataReplies: [HTTPResponseData]

    init(replies: [Reply] = [], dataReplies: [HTTPResponseData] = []) {
        self.replies = replies
        self.dataReplies = dataReplies
    }

    func data(for request: URLRequest) async throws -> HTTPResponseData {
        self.requests.append(request)
        return self.dataReplies.isEmpty ? HTTPResponseData(statusCode: 500, headers: [:], body: Data()) : self.dataReplies.removeFirst()
    }

    func lineStream(for request: URLRequest) async throws -> ModelHTTPLineStream {
        self.requests.append(request)
        let reply = self.replies.isEmpty ? Reply(status: 500, lines: []) : self.replies.removeFirst()
        return ModelHTTPLineStream(statusCode: reply.status, headers: reply.headers, lines: AsyncThrowingStream { continuation in
            for line in reply.lines {
                continuation.yield(line)
            }
            continuation.finish()
        })
    }

    func bodies() -> [Data] {
        self.requests.compactMap(\.httpBody)
    }
}

/// Token provider that hands out `token-1`, then `token-2` after a rejection.
actor PlanTokenStub: ChatGPTPlanAccessTokenProvider {
    private(set) var rejected: [String] = []
    private var current = 1

    func chatGPTPlanAccessToken(rejectedAccessToken: String?) async throws -> String {
        if let rejectedAccessToken {
            self.rejected.append(rejectedAccessToken)
            self.current += 1
        }
        return "token-\(self.current)"
    }
}

@Suite("ChatGPT plan model provider")
struct ChatGPTPlanModelProviderTests {
    static func payloads(_ bodies: [Data]) -> [[String: Any]] {
        bodies.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    static func sse(_ events: [[String: Any]]) -> [String] {
        events.flatMap { event -> [String] in
            let data = (try? JSONSerialization.data(withJSONObject: event)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return ["event: \(event["type"] as? String ?? "")", "data: \(data)", ""]
        }
    }

    static let completedText = sse([
        ["type": "response.created", "response": ["model": "gpt-plan"]],
        ["type": "response.output_text.delta", "delta": "Hello"],
        ["type": "response.output_text.delta", "delta": " there"],
        [
            "type": "response.completed",
            "response": ["model": "gpt-plan", "status": "completed", "usage": ["input_tokens": 5, "output_tokens": 2, "total_tokens": 7]],
        ],
    ])

    private func tools() -> [ModelToolDefinition] {
        [
            ModelToolDefinition(name: "add", description: "Add numbers", parameters: ["type": AnyCodable("object")]),
            ModelToolDefinition(name: "lookup", description: "Look up", parameters: ["type": AnyCodable("object")]),
        ]
    }

    @Test("Requests are shaped for plan usage")
    func requestShape() async throws {
        let transport = PlanResponsesStub(replies: [.init(status: 200, lines: Self.completedText)])
        let tokens = PlanTokenStub()
        let provider = ChatGPTPlanModelProvider(tokenProvider: tokens, defaultModelID: "gpt-plan", transport: transport)
        let request = ModelGenerationRequest(
            sessionKey: "agent:main:direct:alice",
            prompt: "",
            systemPrompt: "Be brief.",
            headers: ["X-Trace": "1", "Authorization": "Bearer spoofed"],
            policy: ModelGenerationPolicy(maxTokens: 64, temperature: 0.2, topP: 0.9, storeResponse: true),
            messages: [
                .system(content: [.text("Extra system rule")]),
                .user(content: [.text("What is 2+3?")]),
                .assistant(content: [.toolCall(ModelToolCall(id: "call_1", name: "add", argumentsJSON: #"{"a":2,"b":3}"#))]),
                .toolResult(ModelToolResult(toolCallID: "call_1", toolName: "add", content: [.text("5")])),
            ],
            tools: self.tools()
        )
        let response = try await provider.generate(request)
        #expect(response.text == "Hello there")
        #expect(response.modelID == "gpt-plan")
        #expect(response.usage?.totalTokens == 7)

        let urlRequest = try #require(await transport.requests.first)
        #expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(urlRequest.value(forHTTPHeaderField: "X-Trace") == "1")

        let payload = try #require(Self.payloads(await transport.bodies()).first)
        #expect(payload["model"] as? String == "gpt-plan")
        #expect(payload["store"] as? Bool == false)
        #expect(payload["stream"] as? Bool == true)
        #expect(payload["instructions"] as? String == "Be brief.")
        #expect(Set(payload.keys).isDisjoint(with: ChatGPTPlanResponsesWire.forbiddenFields))
        let promptCacheKey = try #require(payload["prompt_cache_key"] as? String)
        #expect(!promptCacheKey.contains("alice"))

        let input = try #require(payload["input"] as? [[String: Any]])
        #expect(!input.contains { $0["role"] as? String == "system" })
        #expect(input.first?["role"] as? String == "developer")
        let call = try #require(input.first { $0["type"] as? String == "function_call" })
        #expect(call["namespace"] as? String == "openclaw")
        #expect(call["name"] as? String == "add")
        #expect(input.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == "call_1" })

        let tools = try #require(payload["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "namespace")
        #expect(tools[0]["name"] as? String == "openclaw")
        let functions = try #require(tools[0]["tools"] as? [[String: Any]])
        #expect(functions.map { $0["name"] as? String } == ["add", "lookup"])
        #expect(functions.allSatisfy { $0["type"] as? String == "function" })
        #expect(payload["tool_choice"] == nil)
    }

    @Test("Named tool choice sends only that tool with tool_choice required")
    func namedToolChoice() async throws {
        let transport = PlanResponsesStub(replies: [.init(status: 200, lines: Self.sse([
            [
                "type": "response.output_item.added",
                "output_index": 0,
                "item": ["type": "function_call", "id": "fc_1", "call_id": "call_9", "namespace": "openclaw", "name": "lookup", "arguments": ""],
            ],
            ["type": "response.function_call_arguments.delta", "output_index": 0, "delta": #"{"q":"x"}"#],
            [
                "type": "response.output_item.done",
                "output_index": 0,
                "item": [
                    "type": "function_call", "id": "fc_1", "call_id": "call_9", "namespace": "openclaw", "name": "lookup",
                    "arguments": #"{"q":"x"}"#, "status": "completed",
                ],
            ],
            ["type": "response.completed", "response": ["status": "completed"]],
        ]))])
        let options = ChatGPTPlanModelProvider.Options(toolNamespace: "agent_tools", toolNamespaceDescription: "Agent tools")
        let provider = ChatGPTPlanModelProvider(tokenProvider: PlanTokenStub(), defaultModelID: "gpt-plan", options: options, transport: transport)
        let response = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "Find x", tools: self.tools(), toolChoice: .named("lookup")))
        #expect(response.toolCalls.map(\.name) == ["lookup"])
        #expect(response.toolCalls.first?.id == "call_9")
        #expect(response.toolCalls.first?.argumentsJSON == #"{"q":"x"}"#)
        let payload = try #require(Self.payloads(await transport.bodies()).first)
        #expect(payload["tool_choice"] as? String == "required")
        let namespace = try #require((payload["tools"] as? [[String: Any]])?.first)
        #expect(namespace["name"] as? String == "agent_tools")
        #expect(namespace["description"] as? String == "Agent tools")
        #expect((namespace["tools"] as? [[String: Any]])?.map { $0["name"] as? String } == ["lookup"])
    }

    @Test("A 401 refreshes the token once and retries")
    func unauthorizedRetry() async throws {
        let transport = PlanResponsesStub(replies: [
            .init(status: 401, lines: [#"{"detail":"token expired"}"#]),
            .init(status: 200, lines: Self.completedText),
        ])
        let tokens = PlanTokenStub()
        let provider = ChatGPTPlanModelProvider(tokenProvider: tokens, defaultModelID: "gpt-plan", transport: transport)
        let response = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "Hi"))
        #expect(response.text == "Hello there")
        #expect(await tokens.rejected == ["token-1"])
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer token-2")

        let structured = PlanResponsesStub(replies: [.init(status: 401, lines: [#"{"error":{"code":"subscription_sharing_invalid_user"}}"#])])
        let structuredProvider = ChatGPTPlanModelProvider(tokenProvider: PlanTokenStub(), defaultModelID: "gpt-plan", transport: structured)
        await #expect(throws: ChatGPTPlanError(kind: .invalidUser, statusCode: 401)) {
            try await structuredProvider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "Hi"))
        }
        #expect(await structured.requests.count == 1)
    }

    @Test("Usage-limit responses and response.failed events throw ChatGPTPlanError")
    func planErrors() async throws {
        let limited = PlanResponsesStub(replies: [.init(
            status: 429,
            lines: [#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Plan limit reached"}}"#],
            headers: ["retry-after": "30"]
        )])
        let provider = ChatGPTPlanModelProvider(tokenProvider: PlanTokenStub(), defaultModelID: "gpt-plan", transport: limited)
        do {
            _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "Hi"))
            Issue.record("expected a usage-limit error")
        } catch let error as ChatGPTPlanError {
            #expect(error.isUsageLimit)
            #expect(error.statusCode == 429)
            #expect(error.retryAfter == 30)
        }

        let failed = PlanResponsesStub(replies: [.init(status: 200, lines: Self.sse([
            ["type": "response.output_text.delta", "delta": "Partial"],
            ["type": "response.failed", "response": ["status": "failed", "error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "limit"]]],
        ]))])
        let streaming = ChatGPTPlanModelProvider(tokenProvider: PlanTokenStub(), defaultModelID: "gpt-plan", transport: failed)
        var chunks: [ModelStreamChunk] = []
        do {
            for try await chunk in await streaming.generateStream(ModelGenerationRequest(sessionKey: "s", prompt: "Hi")) {
                chunks.append(chunk)
            }
            Issue.record("expected response.failed to throw")
        } catch let error as ChatGPTPlanError {
            #expect(error.kind == .usageLimitReached)
        }
        #expect(chunks.map(\.text) == ["Partial"])

        let truncated = PlanResponsesStub(replies: [.init(status: 200, lines: Self.sse([["type": "response.output_text.delta", "delta": "Hi"]]))])
        let incomplete = ChatGPTPlanModelProvider(tokenProvider: PlanTokenStub(), defaultModelID: "gpt-plan", transport: truncated)
        await #expect(throws: OpenClawCoreError.self) {
            try await incomplete.generate(ModelGenerationRequest(sessionKey: "s", prompt: "Hi"))
        }

        let noModel = ChatGPTPlanModelProvider(tokenProvider: PlanTokenStub(), transport: PlanResponsesStub())
        await #expect(throws: OpenClawCoreError.self) {
            try await noModel.generate(ModelGenerationRequest(sessionKey: "s", prompt: "Hi"))
        }
    }

    @Test("Model lists keep server order and hide non-list models")
    func listModels() async throws {
        let body = #"{"models":[{"slug":"gpt-a","display_name":"GPT A","visibility":"list"},"#
            + #"{"slug":"gpt-hidden","display_name":"Hidden","visibility":"hide"},{"slug":"gpt-b","display_name":"GPT B","visibility":"list"}]}"#
        let transport = PlanResponsesStub(dataReplies: [
            HTTPResponseData(statusCode: 401, headers: [:], body: Data(#"{"detail":"expired"}"#.utf8)),
            HTTPResponseData(statusCode: 200, headers: [:], body: Data(body.utf8)),
            HTTPResponseData(statusCode: 200, headers: [:], body: Data(body.utf8)),
        ])
        let tokens = PlanTokenStub()
        let provider = ChatGPTPlanModelProvider(tokenProvider: tokens, transport: transport)
        let models = try await provider.listModels()
        #expect(models.map(\.slug) == ["gpt-a", "gpt-b"])
        #expect(models.map(\.displayName) == ["GPT A", "GPT B"])
        #expect(await tokens.rejected == ["token-1"])
        #expect(await transport.requests.first?.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(try await provider.listModels(includeHidden: true).count == 3)
    }
}

#if !os(tvOS) && !os(watchOS)
@Suite("Sign in with ChatGPT loopback listener")
struct SignInWithChatGPTLoopbackListenerTests {
    @Test("The listener binds 127.0.0.1, falls back when the port is busy and ignores other paths")
    func listener() async throws {
        let first = try SignInWithChatGPTLoopbackListener.start(port: 0)
        defer { first.stop() }
        #expect(first.port > 0)
        #expect(first.redirectURI.absoluteString == "http://127.0.0.1:\(first.port)/auth/callback")

        let fallback = try SignInWithChatGPTLoopbackListener.start(port: first.port, allowsFallback: true)
        defer { fallback.stop() }
        #expect(fallback.port != first.port)
        #expect(throws: SignInWithChatGPTError.self) {
            try SignInWithChatGPTLoopbackListener.start(port: first.port, allowsFallback: false)
        }

        first.expect(state: "s1")
        let (_, notFound) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(first.port)/favicon.ico")!)
        #expect((notFound as? HTTPURLResponse)?.statusCode == 404)
        let (_, wrongState) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(first.port)/auth/callback?state=s2&code=c")!)
        #expect((wrongState as? HTTPURLResponse)?.statusCode == 400)

        async let callback = first.waitForCallback()
        let (page, ok) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(first.port)/auth/callback?state=s1&error=access_denied")!)
        #expect((ok as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("didn"))
        let url = try await callback
        #expect(url.query?.contains("error=access_denied") == true)
        // A delivered callback is returned again to later waiters.
        #expect(try await first.waitForCallback() == url)
    }

    @Test("Stopping or cancelling ends waiters")
    func stop() async throws {
        let listener = try SignInWithChatGPTLoopbackListener.start(port: 0)
        let waiter = Task { try await listener.waitForCallback() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        await #expect(throws: CancellationError.self) {
            try await listener.waitForCallback()
        }
    }

    @Test("Request lines and HTML escaping")
    func parsing() {
        #expect(SignInWithChatGPTLoopbackListener.parseRequestLine("GET /auth/callback?x=1 HTTP/1.1\r\nHost: a\r\n\r\n")
            == .init(method: "GET", path: "/auth/callback?x=1"))
        #expect(SignInWithChatGPTLoopbackListener.parseRequestLine("GET http://evil/ HTTP/1.1\r\n") == nil)
        #expect(SignInWithChatGPTLoopbackListener.parseRequestLine("garbage") == nil)
        #expect(SignInWithChatGPTLoopbackListener.escapeHTML("<b>\"A&B\"</b>") == "&lt;b&gt;&quot;A&amp;B&quot;&lt;/b&gt;")
        #expect(SignInWithChatGPTLoopbackListener.html(title: "<t>", message: "m").contains("&lt;t&gt;"))
    }
}
#endif
