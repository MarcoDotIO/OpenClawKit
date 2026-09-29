import Foundation
import Testing
import OpenClawProtocol

/// Overflow-safe decoding of wire integers from remote gateways (2026.3.0 FX1 review fix).
@Suite("Gateway wire integer decoding")
struct GatewayWireIntegerDecodingTests {
    @Test
    func outOfRangeWireTimestampsDecodeAsMissingInsteadOfTrapping() throws {
        // 2^63 in the spellings JSON encoders produce (Node writes 9223372036854776000); each used to
        // pass `value <= Double(Int64.max)` and trap in `Int64(_:)`.
        for raw in ["9223372036854775808", "9223372036854775808.0", "9223372036854775807.9", "9223372036854776000", "1e300"] {
            let rowJSON = #"{"key":"main","updatedAt":\#(raw),"createdAt":\#(raw),"totalTokens":\#(raw)}"#
            let row = try JSONDecoder().decode(AnyCodable.self, from: Data(rowJSON.utf8))
            let info = try GatewayPayloadCodec.decode(GatewaySessionInfo.self, from: row)
            #expect(info.updatedAtMs == 0, "updatedAt \(raw)")
            #expect(info.createdAtMs == nil)
            #expect(info.totalTokens == nil)
            let waitJSON = #"{"runId":"r","status":"ok","startedAt":\#(raw),"endedAt":\#(raw)}"#
            let wait = try JSONDecoder().decode(GatewayAgentWaitResult.self, from: Data(waitJSON.utf8))
            #expect(wait.startedAt == nil)
            #expect(wait.endedAt == nil)
        }
        let inRangeJSON = #"{"runId":"r","status":"ok","startedAt":1700000000000.9,"endedAt":9223372036854775807}"#
        let inRange = try JSONDecoder().decode(GatewayAgentWaitResult.self, from: Data(inRangeJSON.utf8))
        #expect(inRange.startedAt == 1_700_000_000_000)
        #expect(inRange.endedAt == Int64.max)
    }
}
