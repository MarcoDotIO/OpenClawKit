import Foundation
import OpenClawKit

// Ported subset of upstream OpenClaw 2026.9.6 `ChatToolActivityViews.swift` (`ChatToolActivity` result
// classification). Tool activity items and row views belong with the transcript views; extend this enum there.

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
}
