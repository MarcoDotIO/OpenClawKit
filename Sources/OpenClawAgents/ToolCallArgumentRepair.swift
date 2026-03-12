import Foundation
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

/// Provider families with known malformed tool-argument edge cases.
public enum ToolCallArgumentProvider: String, Sendable, Equatable, CaseIterable {
    case anthropicCompatible = "anthropic-compatible"
    case kimiCompatible = "kimi-compatible"
}

/// Tracks and repairs malformed provider-emitted tool arguments.
public struct ToolCallArgumentRepairer: Sendable {
    /// Indicates whether the last decode required repair.
    public private(set) var lastRepairApplied: Bool

    /// Creates a repairer with cleared state.
    public init(lastRepairApplied: Bool = false) {
        self.lastRepairApplied = lastRepairApplied
    }

    /// Decodes provider-emitted raw arguments into a JSON object payload.
    /// - Parameters:
    ///   - raw: Raw argument string.
    ///   - provider: Provider family hint.
    /// - Returns: Decoded JSON object payload.
    public mutating func parseArguments(
        _ raw: String,
        provider: ToolCallArgumentProvider
    ) throws -> [String: AnyCodable] {
        if let decoded = try Self.decodeJSONObject(from: raw) {
            self.lastRepairApplied = false
            return decoded
        }

        let repaired = Self.repair(raw, provider: provider)
        guard let decoded = try Self.decodeJSONObject(from: repaired) else {
            throw OpenClawCoreError.invalidConfiguration("Unable to decode tool-call arguments for \(provider.rawValue)")
        }
        self.lastRepairApplied = true
        return decoded
    }

    private static func decodeJSONObject(from raw: String) throws -> [String: AnyCodable]? {
        let candidate = ProviderVisibleTextSanitizer.extractJSONPayload(raw)
        guard candidate.isEmpty == false, let data = candidate.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([String: AnyCodable].self, from: data)
    }

    private static func repair(_ raw: String, provider: ToolCallArgumentProvider) -> String {
        var candidate = ProviderVisibleTextSanitizer.extractJSONPayload(raw)
        if provider == .kimiCompatible,
           let range = candidate.range(of: "arguments=", options: [.caseInsensitive])
        {
            candidate = String(candidate[range.upperBound...])
        }

        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("\""), candidate.hasSuffix("\""),
           let data = candidate.data(using: .utf8),
           let nested = try? JSONDecoder().decode(String.self, from: data)
        {
            candidate = nested
        }

        if candidate.contains("\"") == false, candidate.contains("'") {
            candidate = candidate.replacingOccurrences(of: "'", with: "\"")
        }

        candidate = Self.replacing(
            pattern: #"([{\[,]\s*)([A-Za-z_][A-Za-z0-9_\-]*)(\s*:)"#,
            in: candidate,
            with: "$1\"$2\"$3"
        )
        candidate = Self.replacing(
            pattern: #",(\s*[}\]])"#,
            in: candidate,
            with: "$1"
        )
        return Self.balance(candidate)
    }

    private static func balance(_ raw: String) -> String {
        let openBraces = raw.filter { $0 == "{" }.count
        let closeBraces = raw.filter { $0 == "}" }.count
        let openBrackets = raw.filter { $0 == "[" }.count
        let closeBrackets = raw.filter { $0 == "]" }.count

        var balanced = raw
        if openBrackets > closeBrackets {
            balanced.append(String(repeating: "]", count: openBrackets - closeBrackets))
        }
        if openBraces > closeBraces {
            balanced.append(String(repeating: "}", count: openBraces - closeBraces))
        }
        return balanced
    }

    private static func replacing(pattern: String, in raw: String, with replacement: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: replacement)
    }
}

public extension AgentToolCall {
    /// Builds a tool call by repairing provider-emitted raw argument text when needed.
    /// - Parameters:
    ///   - name: Tool name.
    ///   - rawArguments: Provider-emitted raw argument payload.
    ///   - provider: Provider family hint.
    ///   - repairer: Mutable repair state.
    /// - Returns: Normalized tool call payload.
    static func repaired(
        name: String,
        rawArguments: String,
        provider: ToolCallArgumentProvider,
        using repairer: inout ToolCallArgumentRepairer
    ) throws -> AgentToolCall {
        let arguments = try repairer.parseArguments(rawArguments, provider: provider)
        return AgentToolCall(name: name, arguments: arguments)
    }
}
