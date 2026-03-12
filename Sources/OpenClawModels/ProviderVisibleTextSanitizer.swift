import Foundation

/// Sanitizes provider output before it becomes user-visible.
public enum ProviderVisibleTextSanitizer {
    /// Removes hidden reasoning blocks and provider-internal tags from visible output.
    /// - Parameter raw: Raw provider text.
    /// - Returns: Sanitized text suitable for user-visible surfaces.
    public static func sanitizeVisibleText(_ raw: String) -> String {
        guard raw.isEmpty == false else {
            return ""
        }

        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        for pair in Self.pairedBlockMarkers {
            text = Self.removePairedBlock(
                from: text,
                startPattern: pair.start,
                endPattern: pair.end
            )
        }
        for marker in Self.openEndedMarkers {
            text = Self.removeOpenEndedBlock(from: text, startPattern: marker)
        }
        text = Self.removeStandaloneMarkers(from: text)
        return Self.normalizeWhitespace(in: text)
    }

    /// Extracts the most likely JSON payload from model output.
    /// - Parameter raw: Raw provider text.
    /// - Returns: Trimmed JSON candidate text.
    public static func extractJSONPayload(_ raw: String) -> String {
        let sanitized = self.sanitizeVisibleText(raw)
        guard sanitized.isEmpty == false else {
            return ""
        }
        if let fenced = Self.firstFencedBlock(in: sanitized) {
            return fenced.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let pairedBlockMarkers: [(start: String, end: String)] = [
        ("<thinking\\b[^>]*>", "</thinking>"),
        ("<reasoning\\b[^>]*>", "</reasoning>"),
        ("<analysis\\b[^>]*>", "</analysis>"),
        ("<think\\b[^>]*>", "</think>"),
        ("<\\|start_of_reasoning\\|>", "<\\|end_of_reasoning\\|>"),
        ("\\[reasoning\\]", "\\[/reasoning\\]"),
        ("```(?:thinking|reasoning|analysis)\\s*", "```"),
        ("<\\|channel:analysis\\|>", "<\\|channel:final\\|>"),
    ]

    private static let openEndedMarkers: [String] = [
        "<thinking\\b[^>]*>",
        "<reasoning\\b[^>]*>",
        "<analysis\\b[^>]*>",
        "<think\\b[^>]*>",
        "<\\|start_of_reasoning\\|>",
        "\\[reasoning\\]",
        "```(?:thinking|reasoning|analysis)\\s*",
        "<\\|channel:analysis\\|>",
    ]

    private static func removePairedBlock(
        from raw: String,
        startPattern: String,
        endPattern: String
    ) -> String {
        let pattern = "(?is)\(startPattern).*?\(endPattern)"
        return Self.replacing(pattern: pattern, in: raw, with: "")
    }

    private static func removeOpenEndedBlock(from raw: String, startPattern: String) -> String {
        let pattern = "(?is)\(startPattern).*?$"
        return Self.replacing(pattern: pattern, in: raw, with: "")
    }

    private static func removeStandaloneMarkers(from raw: String) -> String {
        let markers = [
            "(?is)</thinking>",
            "(?is)</reasoning>",
            "(?is)</analysis>",
            "(?is)</think>",
            "(?is)<\\|end_of_reasoning\\|>",
            "(?is)<\\|channel:final\\|>",
            "(?is)\\[/reasoning\\]",
        ]
        return markers.reduce(raw) { partial, pattern in
            Self.replacing(pattern: pattern, in: partial, with: "")
        }
    }

    private static func normalizeWhitespace(in raw: String) -> String {
        var lines = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        var collapsed: [String] = []
        var lastWasBlank = false
        for line in lines {
            if line.isEmpty {
                if lastWasBlank == false {
                    collapsed.append("")
                    lastWasBlank = true
                }
                continue
            }
            collapsed.append(line)
            lastWasBlank = false
        }
        return collapsed.joined(separator: "\n")
    }

    private static func firstFencedBlock(in raw: String) -> String? {
        let pattern = "(?is)```(?:json|javascript|js)?\\s*(.*?)\\s*```"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let captureRange = Range(match.range(at: 1), in: raw)
        else {
            return nil
        }
        return String(raw[captureRange])
    }

    private static func replacing(pattern: String, in raw: String, with replacement: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: replacement)
    }
}
