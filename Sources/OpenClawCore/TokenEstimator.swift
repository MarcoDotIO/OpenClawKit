import Foundation
import OpenClawProtocol

/// Heuristic token estimator shared by context management and compaction.
///
/// Roughly four characters per token for Latin text; CJK and other wide scripts count about one
/// token per character. Images count a fixed budget, tool schemas count their JSON size. Estimates
/// are conservative upper bounds for budgeting, not billing numbers.
public enum TokenEstimator {
    /// Tokens charged for one image block.
    public static let imageTokens = 1_200
    /// Per-message framing overhead.
    public static let messageOverheadTokens = 4

    /// Estimates tokens for a string.
    /// - Parameter text: Text.
    /// - Returns: Estimated tokens.
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var narrow = 0
        var wide = 0
        for scalar in text.unicodeScalars {
            if Self.isWide(scalar) {
                wide += 1
            } else {
                narrow += 1
            }
        }
        return wide + Int((Double(narrow) / 4).rounded(.up))
    }

    /// Estimates tokens for a transcript message.
    /// - Parameter message: Message.
    /// - Returns: Estimated tokens.
    public static func estimate(_ message: AgentMessage) -> Int {
        let body: Int
        switch message {
        case .user(let user):
            body = Self.estimate(user.content.blocks)
        case .assistant(let assistant):
            body = Self.estimate(assistant.content)
        case .toolResult(let result):
            body = Self.estimate(result.content) + Self.estimate(result.toolName)
        case .other:
            body = Self.estimate(message.text)
        }
        return body + Self.messageOverheadTokens
    }

    /// Estimates tokens for messages.
    /// - Parameter messages: Messages.
    /// - Returns: Estimated tokens.
    public static func estimate(_ messages: [AgentMessage]) -> Int {
        messages.reduce(0) { $0 + Self.estimate($1) }
    }

    /// Estimates tokens for content blocks.
    /// - Parameter blocks: Blocks.
    /// - Returns: Estimated tokens.
    public static func estimate(_ blocks: [AgentContentBlock]) -> Int {
        blocks.reduce(0) { total, block in
            switch block {
            case .text(let text, _):
                return total + Self.estimate(text)
            case .image:
                return total + Self.imageTokens
            case .thinking(let thinking):
                return total + Self.estimate(thinking.thinking)
            case .toolCall(let call):
                return total + Self.estimate(call.name) + Self.estimateJSON(AnyCodable(.object(call.arguments)))
            case .unknown(_, let raw):
                return total + Self.estimateJSON(AnyCodable(.object(raw)))
            }
        }
    }

    /// Estimates tokens for a JSON value (for example a tool parameter schema).
    /// - Parameter value: JSON value.
    /// - Returns: Estimated tokens.
    public static func estimateJSON(_ value: AnyCodable) -> Int {
        guard let data = try? JSONEncoder().encode(value) else { return 0 }
        return Self.estimate(String(decoding: data, as: UTF8.self))
    }

    /// Estimates the overhead of declaring tools (name, description and parameter schema per tool).
    /// - Parameter tools: Tuples of name, description and JSON Schema.
    /// - Returns: Estimated tokens.
    public static func estimateToolSchemas(_ tools: [(name: String, description: String, parameters: [String: AnyCodable])]) -> Int {
        tools.reduce(0) { total, tool in
            total + Self.estimate(tool.name) + Self.estimate(tool.description) + Self.estimateJSON(AnyCodable(.object(tool.parameters))) + 8
        }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, // Hangul Jamo
             0x2E80...0x2FDF, // CJK radicals
             0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x30FF, // Hiragana, Katakana
             0x3100...0x31FF, // Bopomofo, Hangul compatibility, Kanbun
             0x3400...0x4DBF, // CJK extension A
             0x4E00...0x9FFF, // CJK unified ideographs
             0xA960...0xA97F, // Hangul Jamo extended A
             0xAC00...0xD7AF, // Hangul syllables
             0xF900...0xFAFF, // CJK compatibility ideographs
             0xFF00...0xFFEF, // Half/full-width forms
             0x1F300...0x1FAFF, // Emoji
             0x20000...0x2FA1F: // CJK extensions B+
            return true
        default:
            return false
        }
    }
}
