import Foundation
import OpenClawKit
import OpenClawProtocol
import Testing
@testable import OpenClawChatUI

// Gateway agent/session.tool events carry `ts: Date.now()` (~1.7e12 ms), which does not fit the
// 32-bit `Int` of watchOS arm64_32. These tests pin the Int64 decoding so the events are never
// silently dropped by the codec's `try?` (FX3 / F2).

private let millisecondEpoch: Int64 = 1_727_600_000_000

@Suite("Chat millisecond timestamps")
struct ChatMillisecondTimestampTests {
    @Test func `fixture timestamp is outside the 32 bit Int range`() {
        struct ThirtyTwoBitEvent: Decodable {
            let ts: Int32
        }
        #expect(millisecondEpoch > Int64(Int32.max))
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ThirtyTwoBitEvent.self, from: Data(#"{"ts":1727600000000}"#.utf8))
        }
    }

    @Test(arguments: ["agent", "session.tool"])
    func `agent and session tool frames keep 13 digit timestamps`(event: String) throws {
        // On arm64_32 AnyCodable stores an out-of-range integer as `.double`; cover both storages.
        for ts in [AnyCodable(Int(millisecondEpoch)), AnyCodable(Double(millisecondEpoch))] {
            let frame = EventFrame(
                type: "event",
                event: event,
                payload: AnyCodable([
                    "runId": AnyCodable("run-1"),
                    "seq": AnyCodable(3),
                    "stream": AnyCodable("tool"),
                    "ts": ts,
                    "sessionKey": AnyCodable("agent:main:main"),
                    "data": AnyCodable(["phase": AnyCodable("start"), "name": AnyCodable("read")]),
                ]))
            let payload: OpenClawAgentEventPayload
            switch OpenClawChatGatewayPayloadCodec.event(from: frame) {
            case let .agent(agent) where event == "agent":
                payload = agent
            case let .sessionTool(tool) where event == "session.tool":
                payload = tool
            default:
                Issue.record("\(event) frame with a millisecond ts must not be dropped")
                return
            }
            #expect(payload.tsMilliseconds == millisecondEpoch)
            #expect(payload.runId == "run-1")
            #expect(payload.seq == 3)
            #expect(payload.stream == "tool")
            #expect(payload.sessionKey == "agent:main:main")
            #expect(payload.data["name"]?.stringValue == "read")
        }
    }

    @Test func `malformed optional fields do not drop an agent event`() throws {
        let json = #"{"runId":"run-2","stream":"lifecycle","seq":"x","ts":"soon","data":[1],"agentId":7}"#
        let payload = try JSONDecoder().decode(OpenClawAgentEventPayload.self, from: Data(json.utf8))
        #expect(payload.runId == "run-2")
        #expect(payload.stream == "lifecycle")
        #expect(payload.seq == nil)
        #expect(payload.tsMilliseconds == nil)
        #expect(payload.ts == nil)
        #expect(payload.data.isEmpty)
        #expect(payload.agentId == nil)

        // Identity fields stay strict.
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(OpenClawAgentEventPayload.self, from: Data(#"{"stream":"tool"}"#.utf8))
        }
    }

    @Test func `agent event round trips ts as a 64 bit integer`() throws {
        let original = OpenClawAgentEventPayload(
            runId: "run-3",
            seq: 1,
            stream: "assistant",
            tsMilliseconds: millisecondEpoch,
            data: ["text": AnyCodable("hi")])
        let encoded = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect((object["ts"] as? NSNumber)?.int64Value == millisecondEpoch)
        #expect(object["tsMilliseconds"] == nil)
        let decoded = try JSONDecoder().decode(OpenClawAgentEventPayload.self, from: encoded)
        #expect(decoded.tsMilliseconds == millisecondEpoch)

        let legacy = OpenClawAgentEventPayload(runId: "run-4", seq: nil, stream: "tool", ts: 42, data: [:])
        #expect(legacy.tsMilliseconds == 42)
        #expect(legacy.ts == 42)
    }

    @Test func `sessions preview payload keeps 13 digit timestamps and tolerates malformed ones`() throws {
        let preview = try JSONDecoder().decode(
            OpenClawSessionsPreviewPayload.self,
            from: Data(#"{"ts":1727600000000,"previews":[]}"#.utf8))
        #expect(preview.tsMilliseconds == millisecondEpoch)
        #expect(Int64(preview.ts) == Int64(Int(clamping: millisecondEpoch)))

        let fractional = try JSONDecoder().decode(
            OpenClawSessionsPreviewPayload.self,
            from: Data(#"{"ts":1727600000000.0,"previews":[]}"#.utf8))
        #expect(fractional.tsMilliseconds == millisecondEpoch)

        let malformed = try JSONDecoder().decode(
            OpenClawSessionsPreviewPayload.self,
            from: Data(#"{"ts":"now","previews":[]}"#.utf8))
        #expect(malformed.tsMilliseconds == 0)

        let encoded = try JSONEncoder().encode(preview)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect((object["ts"] as? NSNumber)?.int64Value == millisecondEpoch)
    }
}
