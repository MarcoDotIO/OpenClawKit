import Foundation
import OpenClawKit
import Testing
@testable import OpenClawChatStore
@testable import OpenClawChatUI

// The SQLite cache-shaping assertions of upstream `ChatCompletedWorkTests` (2026.9.6). The
// completed-work row assertions need `ChatTranscriptRow`, which ships with the transcript-row
// port; the cache contract (record shaping keeps metadata, display identity and stream-fallback
// markers) is covered here so it holds regardless of the view layer.
@Suite("Transcript cache record shaping")
struct ChatTranscriptCacheShapingTests {
    @Test @MainActor func `phase and boundary metadata survive decode cache sanitize and canonical copies`() throws {
        let raw = #"""
        {"role":"user","phase":"commentary","__openclaw":{"turnBoundary":true,"steerTargetRunId":"active"},
         "content":[{"type":"text","text":"Use blue","textSignature":"{\"v\":1,\"phase\":\"commentary\"}"}]}
        """#
        let message = try Self.decode(raw)
        let copies = [
            message,
            OpenClawChatViewModel.stripInboundMetadata(from: message),
            OpenClawChatViewModel.adoptingCanonicalMessage(message, over: message),
        ] +
            OpenClawChatSQLiteTranscriptCache.cacheableMessages([message])
        for copy in copies {
            let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: JSONEncoder().encode(copy))
            #expect(decoded.phase == "commentary")
            #expect(decoded.turnBoundary == true)
            #expect(decoded.steerTargetRunID == "active")
            #expect(decoded.content.first?.textSignature == message.content.first?.textSignature)
        }
    }

    @Test @MainActor func `gateway split projections keep distinct rows through the cache`() throws {
        // Real history projects text and tools with the same canonical ID, then
        // delivers the parent's final answer on a requester-settle run.
        let text = try Self.decode(#"""
        {"role":"assistant","timestamp":2000,"__openclaw":{"id":"shared","runId":"parent"},
         "openclawStreamFallback":{"source":"segment","itemId":"checking-layout"},
         "content":[{"type":"text","text":"Checking the mobile layout"}]}
        """#)
        let tool = try Self.decode(#"""
        {"role":"assistant","timestamp":2000,"__openclaw":{"id":"shared","runId":"parent"},
         "content":[{"type":"thinking","thinking":"Inspect layout"},
                    {"type":"toolCall","id":"read-1","name":"read"}]}
        """#)
        let result = Self.message("toolResult", "Layout reviewed", at: 3000, run: "parent")
        let final = Self.message("assistant", "Use consistent padding", at: 5000, run: "announce:requester-settle")
        let raw = try [text, tool, result, final].map {
            try JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode($0))
        }
        let decoded = OpenClawChatViewModel.decodeMessages(raw)
        #expect(decoded.count == 4)
        let refreshed = OpenClawChatViewModel.reconcileMessageIDs(
            previous: decoded, incoming: OpenClawChatViewModel.decodeMessages(raw))
        #expect(refreshed.map(\.id) == decoded.map(\.id))
        #expect(Set(refreshed.map(\.id)).count == 4)
        let cached = OpenClawChatSQLiteTranscriptCache.cacheableMessages(decoded)
        #expect(OpenClawChatViewModel.dedupeMessages(cached).count == 4)
    }

    @Test @MainActor func `keyed commentary stream fallback markers survive cache shaping`() throws {
        let first = try Self.decode(#"""
        {"role":"assistant","timestamp":3000,
         "__openclaw":{"id":"shared-commentary","idempotencyKey":"same-parent","runId":"active"},
         "openclawStreamFallback":{"source":"segment","itemId":"first","runId":"active"},
         "content":[{"type":"text","text":"Checking the first file"}]}
        """#)
        let copies = [first, OpenClawChatViewModel.adoptingCanonicalMessage(first, over: first)] +
            OpenClawChatSQLiteTranscriptCache.cacheableMessages([first])
        for copy in copies {
            let encoded = try JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(copy))
            let marker = encoded.dictionaryValue?["openclawStreamFallback"]?.dictionaryValue
            #expect(marker?["itemId"]?.stringValue == "first")
            #expect(marker?["runId"]?.stringValue == "active")
            let roundTrip = try ChatPayloadDecoding.decode(encoded, as: OpenClawChatMessage.self)
            #expect(roundTrip.streamFallback == first.streamFallback)
            #expect(roundTrip.idempotencyKey == "same-parent")
        }
    }

    private static func decode(_ json: String) throws -> OpenClawChatMessage {
        try JSONDecoder().decode(OpenClawChatMessage.self, from: Data(json.utf8))
    }

    private static func message(
        _ role: String,
        _ text: String,
        at timestamp: Double,
        run: String? = nil) -> OpenClawChatMessage
    {
        OpenClawChatMessage(
            role: role,
            content: [.init(type: "text", text: text, mimeType: nil, fileName: nil, content: nil)],
            timestamp: timestamp,
            transcriptRunID: run)
    }
}
