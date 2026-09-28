import Foundation
import OpenClawKit

// Ported subset of upstream OpenClaw 2026.9.6 `ChatCompletedWork.swift`: message-level work classification
// used by source previews. The transcript-row collapsing (`ChatTranscriptRow.collapseCompletedWork`)
// belongs with the transcript rows and shares these helpers.

extension OpenClawChatMessage {
    var isForwardedTurnBoundary: Bool {
        self.provenance?.kind == "inter_session" && self.provenance?.sourceTool == "sessions_send"
    }

    var workRunID: String? {
        if let transcriptRunID, !transcriptRunID.isEmpty { return transcriptRunID }
        if let key = self.idempotencyKey, key.hasSuffix(":user") { return String(key.dropLast(5)) }
        let fallbackRunID = self.streamFallback?.runId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackRunID?.isEmpty == false ? fallbackRunID : nil
    }

    var hasWorkMedia: Bool {
        self.content.contains { $0.isInlineAttachment || $0.preview?.inlineWidgetPath != nil }
    }

    var hasWorkReplyContent: Bool {
        self.hasWorkMedia || (self.role.lowercased() == "assistant" && ChatMessageVisibleText.hasVisibleText(in: self))
    }

    var workPhase: String? {
        if self.streamSegmentID != nil { return "commentary" }
        struct Signature: Decodable {
            let v: Int?
            let phase: String?
        }
        let blocks = self.content.filter { ChatMessageVisibleText.isVisibleContentType($0.type, role: "assistant") }
        let phases = blocks.map { block -> String? in
            guard let data = block.textSignature?.data(using: .utf8),
                  let signature = try? JSONDecoder().decode(Signature.self, from: data),
                  signature.v == 1,
                  let phase = signature.phase,
                  ["commentary", "final_answer"].contains(phase)
            else { return nil }
            return phase
        }
        if zip(blocks, phases).contains(where: { block, phase in
            phase == "final_answer" && !(block.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }) { return "final_answer" }
        if let phase = self.phase, ["commentary", "final_answer"].contains(phase) { return phase }
        let explicit = Set(phases.compactMap(\.self))
        return explicit.count == 1 ? explicit.first : nil
    }

    /// Whether this is the completed visible reply of a turn (not commentary, not unresolved work).
    var isCompletedReply: Bool {
        self.role.lowercased() == "assistant" && !self.isForwardedTurnBoundary &&
            self.hasWorkReplyContent && self.workPhase != "commentary" && !self.hasUnresolvedWork
    }

    var isCollapsibleWork: Bool {
        !self.hasWorkMedia && !self.isForwardedTurnBoundary &&
            (["tool", "toolresult", "tool_result"].contains(self.role.lowercased()) ||
                (self.role.lowercased() == "assistant" && self.workPhase != "final_answer"))
    }

    var hasUnresolvedWork: Bool {
        if self.isError == true || self.stopReason == "error" || self.stopReason == "aborted" { return true }
        if ["tool", "toolresult", "tool_result"].contains(self.role.lowercased()),
           ChatToolActivity.resultIsError(self.isError, text: ChatMessageVisibleText.visibleText(in: self))
        { return true }
        let results = self.content.filter(\.isToolResult)
        if results.contains(where: { ChatToolActivity.resultIsError($0.isError, text: $0.text) }) { return true }
        return self.content.contains { block in
            block.isToolCall &&
                !results.contains { $0.id != nil && $0.id == block.id }
        }
    }
}
