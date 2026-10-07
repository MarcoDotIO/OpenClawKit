import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import Testing
@testable import OpenClawModels

@Suite("OpenAI Decisions client")
struct OpenAIDecisionsClientTests {
    actor Transport: OpenAICompatibleHTTPTransport {
        let response: HTTPResponseData
        private(set) var requests: [URLRequest] = []

        init(_ body: String, status: Int = 200, headers: [String: String] = [:]) {
            self.response = HTTPResponseData(statusCode: status, headers: headers, body: Data(body.utf8))
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.requests.append(request)
            return self.response
        }
    }

    static func response(_ answers: String) -> String {
        """
        {"model":"gpt-6-luna","answers":\(answers),"usage":{
          "input_tokens":42,"input_tokens_details":{"cached_tokens":3,"cache_write_tokens":2},
          "output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":42}}
        """
    }

    static let predicate = OpenAIDecisionQuestion.predicate(name: "damaged", instructions: "Does the item have damage?")
    static let predicateAnswer = """
    [{"type":"predicate","name":"damaged","probability":0.95}]
    """

    @Test
    func officialEndpointAuthAndExactPayload() async throws {
        let transport = Transport(Self.response(Self.predicateAnswer))
        let client = try OpenAIDecisionsClient(
            environment: ["OPENAI_API_KEY": "test-key"],
            options: .init(organizationID: "org-test", projectID: "proj-test", timeoutInterval: 12),
            transport: transport
        )
        let response = try await client.create(.init(input: .text("A broken screen."), questions: [Self.predicate], safetyIdentifier: "opaque-id"))
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/decisions")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 12)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Organization") == "org-test")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Project") == "proj-test")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["model", "input", "questions", "safety_identifier"])
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["input"] as? String == "A broken screen.")
        #expect(body["safety_identifier"] as? String == "opaque-id")
        #expect(response.answer(named: "damaged") == .predicate(name: "damaged", probability: 0.95))
        #expect(response.answer(named: "missing") == nil)
        #expect(response.usage.inputTokens == 42)
        #expect(response.usage.outputTokens == 0)
        #expect(response.usage.totalTokens == 42)
        #expect(response.usage.cachedTokens == 3)
        #expect(response.usage.cacheWriteTokens == 2)
        #expect(response.usage.modelUsage.inputTokens == 37)
        #expect(response.usage.modelUsage.totalTokens == 42)
    }

    @Test
    func allAnswersPreserveTypedChoicesScoresAndRefusals() async throws {
        let choices: [OpenAIDecisionChoice] = [.init(value: .bool(true)), .init(value: .string("true"))]
        let transport = Transport(Self.response("""
        [
          {"type":"predicate","name":"damaged","probability":0.95},
          {"type":"choice","name":"category","choice":true,"confidence":0.9,
           "probabilities":[{"value":true,"probability":0.9},{"value":"true","probability":0.1}]},
          {"type":"score","name":"severity","score":0.7,"confidence":0.8,
           "probabilities":[{"value":0,"label":"Low","probability":0.3},{"value":1,"label":"High","probability":0.7}]},
          {"type":"refusal","name":null}
        ]
        """))
        let client = try OpenAIDecisionsClient(apiKey: "test-key", transport: transport)
        let response = try await client.create(.init(input: .text("Damaged"), questions: [
            Self.predicate,
            .choice(name: "category", instructions: "Choose a category", choices: choices),
            .score(name: "severity", instructions: "Rate severity", levels: [.init(label: "Low"), .init(label: "High")]),
            .predicate(instructions: "An independent question")
        ]))
        guard case .choice(_, let value, let confidence, let probabilities) = response.answers[1] else {
            Issue.record("Expected choice answer")
            return
        }
        #expect(value == .bool(true))
        #expect(confidence == 0.9)
        #expect(probabilities.map(\.value) == [.bool(true), .string("true")])
        guard case .score(_, let score, _, let levels) = response.answers[2] else {
            Issue.record("Expected score answer")
            return
        }
        #expect(score == 0.7)
        #expect(levels.map(\.value) == [0, 1])
        #expect(levels.map(\.label) == ["Low", "High"])
        #expect(response.answers[3] == .refusal(name: nil))
        let request = try #require(await transport.requests.first)
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let questions = try #require(body["questions"] as? [[String: Any]])
        #expect(questions[1]["type"] as? String == "choice")
        #expect(questions[2]["type"] as? String == "score")
        #expect(questions[3]["name"] == nil)
        let encodedChoices = try #require(questions[1]["choices"] as? [[String: Any]])
        #expect(encodedChoices[0]["value"] as? Bool == true)
        #expect(encodedChoices[1]["value"] as? String == "true")
    }

    @Test
    func imagesAndTextMessagesUseOnlySupportedWireFields() async throws {
        let transport = Transport(Self.response(Self.predicateAnswer))
        let client = try OpenAIDecisionsClient(apiKey: "test-key", options: .init(baseURL: URL(string: "https://gateway.example/v1/")!), transport: transport)
        _ = try await client.create(.init(input: .messages([
            .init(content: .text("Check the photo")),
            .init(content: .parts([.text("Visible damage?"), .image(data: Data([1, 2, 3]), mimeType: "image/png", detail: .original)]))
        ]), questions: [Self.predicate]))
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/v1/decisions")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["input"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "user"])
        #expect(messages[0]["content"] as? String == "Check the photo")
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(parts[0]["type"] as? String == "input_text")
        #expect(parts[1]["image_url"] as? String == "data:image/png;base64,AQID")
        #expect(parts[1]["detail"] as? String == "original")
    }

    @Test(arguments: [401, 403, 429, 500])
    func httpErrorsPreserveMetadataRedactKeyAndNeverRetry(status: Int) async throws {
        let transport = Transport(
            """
            {"error":{"code":"insufficient_quota","type":"quota_error","message":"Rejected test-secret and Bearer other-secret"}}
            """,
            status: status, headers: ["X-Request-ID": "req-test", "Retry-After": "5"]
        )
        let client = try OpenAIDecisionsClient(apiKey: "test-secret", transport: transport)
        do {
            _ = try await client.create(.init(input: .text("Damage"), questions: [Self.predicate]))
            Issue.record("Expected HTTP failure")
        } catch let error as OpenAIDecisionsHTTPError {
            #expect(error.statusCode == status)
            #expect(error.code == "insufficient_quota")
            #expect(error.type == "quota_error")
            #expect(error.requestID == "req-test")
            #expect(error.retryAfter == "5")
            #expect(!String(describing: error).contains("test-secret"))
            #expect(!error.localizedDescription.contains("other-secret"))
        }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: ["not JSON", "{}", Self.response("[{\"type\":\"future\",\"name\":\"damaged\"}]"),
                      Self.response("[{\"type\":\"predicate\",\"name\":\"damaged\"}]")])
    func malformedResponsesFailWithoutLeakingBody(body: String) async throws {
        let client = try OpenAIDecisionsClient(apiKey: "test-key", transport: Transport(body))
        await #expect(throws: OpenClawCoreError.self) {
            try await client.create(.init(input: .text("Damage"), questions: [Self.predicate]))
        }
    }

    @Test(arguments: ["[]", "[{\"type\":\"predicate\",\"name\":\"wrong\",\"probability\":0.5}]",
                      "[{\"type\":\"refusal\",\"name\":null}]"])
    func mismatchedAnswerCountOrNamesFail(answers: String) async throws {
        let client = try OpenAIDecisionsClient(apiKey: "test-key", transport: Transport(Self.response(answers)))
        await #expect(throws: OpenClawCoreError.self) {
            try await client.create(.init(input: .text("Damage"), questions: [Self.predicate]))
        }
    }

    @Test
    func mismatchedAnswerTypeFails() async throws {
        let transport = Transport(Self.response("""
        [{"type":"predicate","name":"category","probability":0.5}]
        """))
        let client = try OpenAIDecisionsClient(apiKey: "test-key", transport: transport)
        await #expect(throws: OpenClawCoreError.self) {
            try await client.create(.init(input: .text("text"), questions: [
                .choice(name: "category", instructions: "Choose", choices: [.init(value: .bool(true)), .init(value: .bool(false))])
            ]))
        }
    }

    @Test
    func documentedChoiceAndImageBoundariesAreAccepted() throws {
        let image = OpenAIDecisionInputPart.image(data: Data([1]), mimeType: "image/png")
        try OpenAIDecisionRequest(
            input: .messages([
                .init(content: .parts(Array(repeating: image, count: 64))),
                .init(content: .parts(Array(repeating: image, count: 64)))
            ]),
            questions: [.choice(instructions: "Choose", choices: (0..<255).map { .init(value: .string(String($0))) })]
        ).validate()
        #expect(throws: OpenClawCoreError.self) {
            try OpenAIDecisionRequest(input: .text("text"), questions: [
                .choice(instructions: "Choose", choices: (0..<256).map { .init(value: .string(String($0))) })
            ]).validate()
        }
    }

    @Test
    func invalidRequestsFailBeforeNetwork() async throws {
        let image = OpenAIDecisionInputPart.image(data: Data([1]), mimeType: "image/png")
        let invalid: [OpenAIDecisionRequest] = [
            .init(model: " ", input: .text("text"), questions: [Self.predicate]),
            .init(input: .text("text"), questions: []),
            .init(input: .text("text"), questions: [Self.predicate, Self.predicate]),
            .init(input: .text("text"), questions: [Self.predicate], safetyIdentifier: String(repeating: "x", count: 129)),
            .init(input: .text("text"), questions: [.choice(instructions: "choose", choices: [.init(value: .bool(true))])]),
            .init(input: .text("text"), questions: [.choice(instructions: "choose", choices: [.init(value: .bool(true)), .init(value: .bool(true))])]),
            .init(input: .text("text"), questions: [.score(instructions: "rate", levels: [])]),
            .init(input: .messages([.init(content: .parts([.image(dataURL: "https://example.com/image.png")]))]), questions: [Self.predicate]),
            .init(input: .messages([.init(content: .parts([.image(dataURL: "data:image/png;base64,invalid!")]))]), questions: [Self.predicate]),
            .init(input: .messages([
                .init(content: .parts(Array(repeating: image, count: 64))),
                .init(content: .parts(Array(repeating: image, count: 65)))
            ]), questions: [Self.predicate])
        ]
        let transport = Transport("{}")
        let client = try OpenAIDecisionsClient(apiKey: "test-key", transport: transport)
        for request in invalid {
            await #expect(throws: OpenClawCoreError.self) { try await client.create(request) }
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func configurationRejectsMissingKeysUnsafeURLsAndInvalidTimeouts() throws {
        #expect(throws: OpenClawCoreError.self) { try OpenAIDecisionsClient(environment: [:]) }
        #expect(throws: OpenClawCoreError.self) { try OpenAIDecisionsClient(apiKey: " \n ") }
        for raw in ["file:///tmp/decisions", "https://user:pass@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#fragment"] {
            #expect(throws: OpenClawCoreError.self) {
                try OpenAIDecisionsClient(apiKey: "test-key", options: .init(baseURL: URL(string: raw)!))
            }
        }
        for timeout in [0.0, -1, .infinity, .nan] {
            #expect(throws: OpenClawCoreError.self) { try OpenAIDecisionsClient(apiKey: "test-key", options: .init(timeoutInterval: timeout)) }
        }
    }

    @Test
    func cancellationStopsBeforeNetwork() async throws {
        let transport = Transport("{}")
        let client = try OpenAIDecisionsClient(apiKey: "test-key", transport: transport)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.create(.init(input: .text("text"), questions: [Self.predicate]))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func transportTimeoutKeepsCodeAndDropsFailingURL() async throws {
        struct FailingTransport: OpenAICompatibleHTTPTransport {
            func data(for request: URLRequest) async throws -> HTTPResponseData {
                throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://example.com?key=secret")!])
            }
        }
        let client = try OpenAIDecisionsClient(apiKey: "test-key", transport: FailingTransport())
        do {
            _ = try await client.create(.init(input: .text("text"), questions: [Self.predicate]))
            Issue.record("Expected timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
            #expect(!String(describing: error).contains("key=secret"))
            #expect(error.userInfo[NSURLErrorFailingURLErrorKey] == nil)
        }
    }
}
