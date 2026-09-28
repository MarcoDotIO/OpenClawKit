import Foundation
import OpenClawKit

// Ported subset of upstream OpenClaw 2026.9.6 `ChatToolActivityViews.swift`: the tool activity item model and
// `ChatToolActivity` pairing/classification. Row views belong with the transcript views.

/// One tool call (and its result, when available) in a transcript activity card.
struct ChatToolActivityItem: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case finished
        case failed
        case blocked
        case unavailable

        var title: LocalizedStringResource {
            switch self {
            case .running: "Working"
            case .finished: "Finished"
            case .failed: "Failed"
            case .blocked: "Blocked"
            case .unavailable: "No result"
            }
        }
    }

    let id: String
    let name: String?
    let arguments: AnyCodable?
    let details: AnyCodable?
    let resultText: String?
    let state: State
    let liveDiffStat: ChatToolDiffStat?
    var activity: OpenClawAgentActivityItem?
    var activityPrepared = false

    var isVisible: Bool {
        self.activity?.isVisible ?? !self.activityPrepared
    }

    var displayState: State {
        guard let activity = self.activity else { return self.state }
        switch activity.status {
        case "running": return .running
        case "completed": return .finished
        case "failed": return .failed
        case "blocked": return .blocked
        default: return .unavailable
        }
    }

    var isError: Bool {
        self.displayState == .failed
    }

    var isPending: Bool {
        self.displayState == .running
    }
}

/// Tool activity classification helpers.
enum ChatToolActivity {
    /// Whether a tool result is an error, from its flag or its JSON/text payload.
    static func resultIsError(_ flag: Bool?, text: String?) -> Bool {
        if let flag { return flag }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if ["tool not found", "tool not found."].contains(text.lowercased()) { return true }
        guard text.utf16.count <= 20000,
              text.hasPrefix("{"), text.hasSuffix("}"),
              let data = text.data(using: .utf8),
              let result = try? JSONDecoder().decode(AnyCodable.self, from: data).dictionaryValue
        else { return false }
        if let flag = result["isError"]?.boolValue ?? result["is_error"]?.boolValue { return flag }
        if let error = result["error"] {
            if let text = error.stringValue,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            if error.boolValue == true || error.dictionaryValue != nil || error.arrayValue != nil { return true }
        }
        return ["error", "failed", "timeout"].contains(
            result["status"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }

    /// Pairs tool calls with their results (by call id), appending orphaned results.
    static func items(
        calls: [OpenClawChatMessageContent],
        results: [OpenClawChatMessageContent]) -> [ChatToolActivityItem]
    {
        var remainingResults = Array(results.enumerated())
        var items = calls.enumerated().map { index, call in
            let resultIndex = call.id.flatMap { callID in
                remainingResults.firstIndex { _, result in result.id == callID }
            }
            let result = resultIndex.map { remainingResults.remove(at: $0).element }

            return ChatToolActivityItem(
                id: call.id ?? "call-\(index)",
                name: call.name,
                arguments: call.arguments,
                details: result?.details,
                resultText: result?.text,
                state: result
                    .map { Self.resultIsError($0.isError, text: $0.text) ? .failed : .finished } ?? .unavailable,
                liveDiffStat: nil)
        }

        items.append(contentsOf: remainingResults.map { index, result in
            ChatToolActivityItem(
                id: result.id ?? "result-\(index)",
                name: result.name,
                arguments: nil,
                details: result.details,
                resultText: result.text,
                state: Self.resultIsError(result.isError, text: result.text) ? .failed : .finished,
                liveDiffStat: nil)
        })
        return items
    }
}
