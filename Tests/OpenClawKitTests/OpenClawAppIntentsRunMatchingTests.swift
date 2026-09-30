import Foundation
import Testing
@testable import OpenClawAppIntents
import OpenClawKit

/// Gateway transport whose `chat.send` stays pending until the test acknowledges it.
private actor HeldChatSendRequester: OpenClawIntentGatewayRequesting {
    /// Params of each `chat.send`, yielded the moment the request arrives.
    nonisolated let sends: AsyncStream<[String: AnyCodable]>
    private let sendsContinuation: AsyncStream<[String: AnyCodable]>.Continuation
    private(set) var abortParams: [[String: AnyCodable]] = []
    private var pendingSend: CheckedContinuation<Data, any Error>?

    init() {
        (self.sends, self.sendsContinuation) = AsyncStream.makeStream()
    }

    func request(method: String, params: [String: AnyCodable]?, timeoutMs: Double?) async throws -> Data {
        switch method {
        case "chat.send":
            self.sendsContinuation.yield(params ?? [:])
            return try await withCheckedThrowingContinuation { self.pendingSend = $0 }
        case "chat.abort":
            self.abortParams.append(params ?? [:])
            return Data("{}".utf8)
        default:
            return Data("{}".utf8)
        }
    }

    func acknowledge(json: String) {
        self.pendingSend?.resume(returning: Data(json.utf8))
        self.pendingSend = nil
    }
}

private func chatEvent(_ fields: [String: String]) -> EventFrame {
    EventFrame(type: "event", event: "chat", payload: AnyCodable(fields.mapValues { AnyCodable($0) }))
}

/// Returns the idempotency key of the first `chat.send` once it reaches the requester.
///
/// Event-driven rather than deadline-polled: under a saturated test pool the send can take
/// seconds to arrive, which must only slow the test down. The suite's time limit bounds a real hang.
private func waitForSend(_ requester: HeldChatSendRequester) async throws -> String {
    for await params in requester.sends {
        return try #require(params["idempotencyKey"]?.stringValue)
    }
    // The stream is never finished, so iteration only ends when the time limit cancels the test.
    throw CancellationError()
}

@Suite("App Intents run matching", .timeLimit(.minutes(1)))
struct OpenClawAppIntentsRunMatchingTests {
    @Test
    func anotherAgentsRunBeforeTheAckNeverHijacksTheIntent() async throws {
        let requester = HeldChatSendRequester()
        let host = GatewayOpenClawIntentHost(requester: requester)
        let send = Task { try await host.send(prompt: "Ask OpenClaw", sessionKey: "main", agentId: nil) }
        let idempotencyKey = try await waitForSend(requester)

        // Agent `ops` streams in `agent:ops:main` while chat.send is still being admitted.
        await host.ingest(chatEvent(["runId": "ops1", "sessionKey": "agent:ops:main", "state": "delta", "deltaText": "ops text"]))
        await host.ingest(chatEvent(["runId": "ops1", "sessionKey": "agent:ops:main", "state": "final"]))
        // The default agent's other run in exactly our session is buffered, never adopted.
        await host.ingest(chatEvent(["runId": "other", "sessionKey": "main", "state": "final"]))

        // An abort before the ack targets our own run.
        await host.abort(sessionKey: "main")
        #expect(await requester.abortParams.last?["runId"]?.stringValue == idempotencyKey)

        await requester.acknowledge(json: #"{"runId":"\#(idempotencyKey)","status":"started"}"#)
        let stream = try await send.value
        await host.ingest(chatEvent(["runId": idempotencyKey, "sessionKey": "agent:main:main", "state": "delta", "deltaText": "ours"]))
        await host.ingest(chatEvent(["runId": idempotencyKey, "sessionKey": "agent:main:main", "state": "final"]))
        var events: [OpenClawIntentRunEvent] = []
        for try await event in stream {
            events.append(event)
        }
        #expect(events.last?.phase == .completed)
        #expect(events.last?.text == "ours")
        #expect(events.last?.runId == idempotencyKey)
        #expect(!events.contains { $0.text?.contains("ops") == true })
    }

    @Test
    func preAckEventsOfTheAckedRunAreReplayed() async throws {
        let requester = HeldChatSendRequester()
        let host = GatewayOpenClawIntentHost(requester: requester)
        let send = Task { try await host.send(prompt: "hi", sessionKey: "main", agentId: "coder") }
        _ = try await waitForSend(requester)
        // A gateway that assigns its own run id streams before the ack.
        await host.ingest(chatEvent(["runId": "g1", "sessionKey": "agent:coder:main", "state": "delta", "deltaText": "Hel"]))
        await host.ingest(chatEvent(["runId": "busy", "sessionKey": "agent:main:main", "state": "delta", "deltaText": "no"]))
        await host.ingest(chatEvent(["runId": "g1", "sessionKey": "agent:coder:main", "state": "delta", "deltaText": "lo"]))
        await requester.acknowledge(json: #"{"runId":"g1"}"#)
        let stream = try await send.value
        await host.ingest(chatEvent(["runId": "g1", "sessionKey": "agent:coder:main", "state": "final"]))
        var events: [OpenClawIntentRunEvent] = []
        for try await event in stream {
            events.append(event)
        }
        #expect(events.last?.text == "Hello")
        #expect(events.last?.runId == "g1")
    }

    @Test
    func sessionKeysMatchOnlyTheRequestedAgent() {
        #expect(GatewayOpenClawIntentHost.sessionKeysMatch("main", "main", agentId: nil))
        #expect(GatewayOpenClawIntentHost.sessionKeysMatch("main", "agent:main:main", agentId: nil))
        #expect(GatewayOpenClawIntentHost.sessionKeysMatch("main", "Agent:Coder:Main", agentId: "coder"))
        #expect(!GatewayOpenClawIntentHost.sessionKeysMatch("main", "agent:ops:main", agentId: nil))
        #expect(!GatewayOpenClawIntentHost.sessionKeysMatch("main", "agent:main:main", agentId: "coder"))
    }
}
