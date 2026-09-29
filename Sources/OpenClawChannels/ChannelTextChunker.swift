import Foundation
import OpenClawCore

/// Per-channel outbound text chunker (port of upstream `src/auto-reply/chunk.ts`).
///
/// - Limits are measured in ``ChannelTextChunkUnit`` units (grapheme clusters, UTF-16 code units
///   or UTF-8 bytes); chunks never split a grapheme cluster. A single grapheme cluster larger
///   than the limit is emitted on its own so chunking always makes progress.
/// - `length` mode prefers breaking at a paragraph, then a newline, then a sentence end, then
///   whitespace. `newline` mode only breaks at paragraph boundaries (blank lines), packing
///   paragraphs up to the limit and length-splitting only oversized paragraphs.
/// - Fenced code blocks are never broken silently: when a chunk ends inside a ``` fence the
///   fence is closed and reopened with the same info string (language) in the next chunk.
/// - `maxLines` additionally splits chunks with more lines (Discord: 17), fence-aware.
public enum ChannelTextChunker {
    /// Splits text into chunks.
    /// - Parameters:
    ///   - text: Text to split.
    ///   - limit: Maximum chunk size in `unit`s (values ≤ 0 disable chunking).
    ///   - unit: Measurement unit (default UTF-16 code units, like platform limits and upstream).
    ///   - mode: Chunking mode.
    ///   - maxLines: Optional line cap per chunk.
    /// - Returns: Chunks in order; empty for empty text.
    public static func chunk(
        _ text: String,
        limit: Int,
        unit: ChannelTextChunkUnit = .utf16,
        mode: ChannelTextChunkMode = .length,
        maxLines: Int? = nil
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        guard limit > 0 else { return [text] }
        var chunks: [String]
        switch mode {
        case .length:
            chunks = self.chunkMarkdown(text, limit: limit, unit: unit)
        case .newline:
            chunks = self.chunkByParagraph(text, limit: limit, unit: unit)
        }
        if let maxLines, maxLines > 0 {
            chunks = chunks.flatMap { self.splitByLines($0, maxLines: maxLines) }
        }
        return chunks.filter { !$0.isEmpty }
    }

    /// Splits text using a channel's catalog defaults and configured policy.
    ///
    /// The effective limit is `min(textChunkLimit ?? default, platform limit)`; Telegram rich
    /// messages raise the default to 32768.
    /// - Parameters:
    ///   - text: Text to split.
    ///   - channel: Channel id.
    ///   - policy: Resolved messaging policy (`textChunkLimit`, `streaming.chunkMode`).
    ///   - richMessages: Whether rich messages are enabled.
    /// - Returns: Chunks in order.
    public static func chunk(
        _ text: String,
        for channel: ChannelID,
        policy: ChannelMessagingPolicyConfig = ChannelMessagingPolicyConfig(),
        richMessages: Bool = false
    ) -> [String] {
        let defaults = channel.metadata.textChunking ?? ChannelTextChunkingDefaults(defaultLimit: 4_000)
        let limit = defaults.effectiveLimit(configured: policy.textChunkLimit, richMessages: richMessages)
        return self.chunk(text, limit: limit, unit: defaults.unit, mode: policy.effectiveChunkMode, maxLines: defaults.maxLines)
    }

    /// Measures text in a unit.
    /// - Parameters:
    ///   - text: Text to measure.
    ///   - unit: Measurement unit.
    /// - Returns: Size in units.
    public static func measure(_ text: some StringProtocol, unit: ChannelTextChunkUnit) -> Int {
        switch unit {
        case .chars: text.count
        case .utf16: text.utf16.count
        case .bytes: text.utf8.count
        }
    }

    // MARK: - Length mode (markdown aware)

    private struct Fence {
        let start: Int
        let end: Int
        let contentStart: Int
        let openLine: String
        let marker: String
        let indent: String

        var closeLine: String {
            self.indent + self.marker
        }
    }

    private struct Buffer {
        let chars: [Character]
        let prefix: [Int]
        let unit: ChannelTextChunkUnit

        init(_ text: String, unit: ChannelTextChunkUnit) {
            self.chars = Array(text)
            self.unit = unit
            var prefix = [0]
            prefix.reserveCapacity(self.chars.count + 1)
            for character in self.chars {
                prefix.append(prefix[prefix.count - 1] + ChannelTextChunker.weight(character, unit: unit))
            }
            self.prefix = prefix
        }

        var count: Int { self.chars.count }

        func weight(_ range: Range<Int>) -> Int {
            self.prefix[range.upperBound] - self.prefix[range.lowerBound]
        }

        /// Largest end index `e > start` with `weight(start..<e) <= budget`, at least `start + 1`.
        func maxEnd(from start: Int, budget: Int) -> Int {
            let target = self.prefix[start] + max(0, budget)
            var low = start + 1
            var high = self.count
            var best = start + 1
            while low <= high {
                let mid = (low + high) / 2
                if self.prefix[mid] <= target {
                    best = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return min(max(best, start + 1), self.count)
        }

        func string(_ range: Range<Int>) -> String {
            String(self.chars[range])
        }
    }

    static func weight(_ character: Character, unit: ChannelTextChunkUnit) -> Int {
        switch unit {
        case .chars: 1
        case .utf16: character.utf16.count
        case .bytes: character.utf8.count
        }
    }

    private static func chunkMarkdown(_ text: String, limit: Int, unit: ChannelTextChunkUnit) -> [String] {
        guard self.measure(text, unit: unit) > limit else { return [text] }
        let buffer = Buffer(text, unit: unit)
        let fences = self.parseFences(buffer.chars)
        var chunks: [String] = []
        var start = 0
        var reopen: Fence?

        while start < buffer.count {
            let reopenLine = reopen.map { self.reopenLine(for: $0, limit: limit, unit: unit) } ?? ""
            let reopenPrefix = reopenLine.isEmpty ? "" : reopenLine + "\n"
            let contentLimit = max(1, limit - self.measure(reopenPrefix, unit: unit))
            if buffer.weight(start..<buffer.count) <= contentLimit {
                chunks.append(reopenPrefix + buffer.string(start..<buffer.count))
                break
            }
            reopen = nil
            let windowEnd = buffer.maxEnd(from: start, budget: contentLimit)
            var breakIndex = self.pickSafeBreak(buffer.chars, start: start, end: windowEnd, fences: fences) ?? windowEnd
            var fenceToSplit: Fence?
            var fence = fences.first { $0.start < breakIndex && breakIndex < $0.end }

            if let found = fence, breakIndex <= found.contentStart, found.start > start {
                // The break would cut the opening fence line: break before the fence instead.
                breakIndex = found.start
                fence = nil
            }

            if let found = fence {
                let closeLine = found.closeLine
                if self.reopenLine(for: found, limit: limit, unit: unit).isEmpty {
                    breakIndex = windowEnd
                } else {
                    let closeWeight = self.measure(closeLine, unit: unit)
                    let maxIfNewline = buffer.maxEnd(from: start, budget: contentLimit - closeWeight)
                    let maxIfNeedNewline = buffer.maxEnd(from: start, budget: contentLimit - closeWeight - 1)
                    let minProgress = reopenPrefix.isEmpty ? max(start + 1, min(found.contentStart + 1, buffer.count)) : start + 1
                    var picked: Int?
                    var candidate = min(maxIfNewline, buffer.count)
                    while candidate >= minProgress, candidate > start {
                        if buffer.chars[candidate - 1].isNewline, candidate < found.end, candidate > found.start {
                            picked = candidate
                            break
                        }
                        candidate -= 1
                    }
                    if let picked {
                        breakIndex = picked
                        fenceToSplit = found
                    } else if minProgress >= maxIfNeedNewline {
                        breakIndex = windowEnd
                        reopen = found
                    } else {
                        breakIndex = maxIfNeedNewline
                        fenceToSplit = (found.start < breakIndex && breakIndex < found.end) ? found : nil
                    }
                }
            }

            let raw = buffer.string(start..<breakIndex)
            guard !raw.isEmpty else { break }
            var chunk = reopenPrefix + raw
            var next = breakIndex
            if let split = fenceToSplit {
                chunk += (raw.last?.isNewline == true ? "" : "\n") + split.closeLine
                reopen = split
            } else if fence == nil {
                chunk = String(chunk.reversed().drop(while: \.isWhitespace).reversed())
                while next < buffer.count, buffer.chars[next].isWhitespace {
                    next += 1
                }
            }
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            start = next
        }
        return chunks
    }

    private static func reopenLine(for fence: Fence, limit: Int, unit: ChannelTextChunkUnit) -> String {
        let markerLine = fence.closeLine
        if self.measure(fence.openLine, unit: unit) + self.measure(markerLine, unit: unit) + 3 <= limit {
            return fence.openLine
        }
        return self.measure(markerLine, unit: unit) * 2 + 3 <= limit ? markerLine : ""
    }

    /// Picks the preferred break index in `(start, end]`: paragraph, newline, sentence, whitespace.
    private static func pickSafeBreak(_ chars: [Character], start: Int, end: Int, fences: [Fence]) -> Int? {
        func insideFence(_ index: Int) -> Bool {
            fences.contains { $0.start < index && index < $0.end }
        }
        let upper = min(end, chars.count - 1)
        guard upper > start else { return nil }
        var lastNewline: Int?
        var lastParagraph: Int?
        var lastSentence: Int?
        var lastWhitespace: Int?
        var depth = 0
        var index = start
        while index <= upper {
            let character = chars[index]
            if character == "(" {
                depth += 1
            } else if character == ")", depth > 0 {
                depth -= 1
            }
            if index > start, !insideFence(index) {
                if character.isNewline {
                    lastNewline = index
                    if index > start + 1, chars[index - 1].isNewline {
                        lastParagraph = index - 1
                    }
                } else if character.isWhitespace, depth == 0 {
                    lastWhitespace = index
                    if ".!?".contains(chars[index - 1]) {
                        lastSentence = index
                    }
                }
            }
            index += 1
        }
        return lastParagraph ?? lastNewline ?? lastSentence ?? lastWhitespace
    }

    private static func parseFences(_ chars: [Character]) -> [Fence] {
        var fences: [Fence] = []
        var open: (start: Int, markerChar: Character, markerLength: Int, openLine: String, marker: String, indent: String)?
        var lineStart = 0
        while lineStart <= chars.count {
            var lineEnd = lineStart
            while lineEnd < chars.count, !chars[lineEnd].isNewline {
                lineEnd += 1
            }
            let line = chars[lineStart..<lineEnd]
            var cursor = line.startIndex
            var indent = ""
            while cursor < line.endIndex, line[cursor] == " ", indent.count < 3 {
                indent.append(" ")
                cursor += 1
            }
            if cursor < line.endIndex, line[cursor] == "`" || line[cursor] == "~" {
                let markerChar = line[cursor]
                var markerEnd = cursor
                while markerEnd < line.endIndex, line[markerEnd] == markerChar {
                    markerEnd += 1
                }
                let markerLength = markerEnd - cursor
                if markerLength >= 3 {
                    let marker = String(line[cursor..<markerEnd])
                    let trailing = String(line[markerEnd..<line.endIndex])
                    if let current = open {
                        if current.markerChar == markerChar, markerLength >= current.markerLength,
                           trailing.allSatisfy({ $0 == " " || $0 == "\t" })
                        {
                            fences.append(
                                Fence(
                                    start: current.start,
                                    end: lineEnd,
                                    contentStart: self.contentStart(forOpenAt: current.start, chars),
                                    openLine: current.openLine,
                                    marker: current.marker,
                                    indent: current.indent
                                )
                            )
                            open = nil
                        }
                    } else {
                        open = (lineStart, markerChar, markerLength, indent + marker + trailing, marker, indent)
                    }
                }
            }
            if lineEnd >= chars.count {
                break
            }
            lineStart = lineEnd + 1
        }
        if let current = open {
            fences.append(
                Fence(
                    start: current.start,
                    end: chars.count,
                    contentStart: self.contentStart(forOpenAt: current.start, chars),
                    openLine: current.openLine,
                    marker: current.marker,
                    indent: current.indent
                )
            )
        }
        return fences
    }

    private static func contentStart(forOpenAt start: Int, _ chars: [Character]) -> Int {
        var index = start
        while index < chars.count, !chars[index].isNewline {
            index += 1
        }
        return min(index + 1, chars.count)
    }

    // MARK: - Newline (paragraph) mode

    private static func chunkByParagraph(_ text: String, limit: Int, unit: ChannelTextChunkUnit) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\u{2029}", with: "\n\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
        let chars = Array(normalized)
        let fences = self.parseFences(chars)
        var paragraphs: [String] = []
        var separators: [String] = []
        var current: [Character] = []
        var index = 0
        while index < chars.count {
            if chars[index] == "\n", !fences.contains(where: { $0.start < index && index < $0.end }) {
                var probe = index + 1
                while probe < chars.count, chars[probe] == " " || chars[probe] == "\t" {
                    probe += 1
                }
                if probe < chars.count, chars[probe] == "\n" {
                    var separatorEnd = probe
                    while separatorEnd < chars.count, chars[separatorEnd] == "\n" {
                        separatorEnd += 1
                    }
                    paragraphs.append(String(current))
                    separators.append(String(chars[index..<separatorEnd]))
                    current = []
                    index = separatorEnd
                    continue
                }
            }
            current.append(chars[index])
            index += 1
        }
        paragraphs.append(String(current))
        guard paragraphs.count > 1 else {
            return self.chunkMarkdown(normalized, limit: limit, unit: unit)
        }

        var chunks: [String] = []
        var pending = ""
        for (offset, rawParagraph) in paragraphs.enumerated() {
            let paragraph = String(rawParagraph.reversed().drop(while: \.isWhitespace).reversed())
            guard !paragraph.isEmpty else { continue }
            let separator = offset > 0 ? separators[offset - 1] : "\n\n"
            if pending.isEmpty {
                if self.measure(paragraph, unit: unit) <= limit {
                    pending = paragraph
                } else {
                    chunks.append(contentsOf: self.chunkMarkdown(paragraph, limit: limit, unit: unit))
                }
                continue
            }
            let candidate = pending + separator + paragraph
            if self.measure(candidate, unit: unit) <= limit {
                pending = candidate
                continue
            }
            chunks.append(pending)
            pending = ""
            if self.measure(paragraph, unit: unit) <= limit {
                pending = paragraph
            } else {
                chunks.append(contentsOf: self.chunkMarkdown(paragraph, limit: limit, unit: unit))
            }
        }
        if !pending.isEmpty {
            chunks.append(pending)
        }
        return chunks
    }

    // MARK: - Line cap

    private static func splitByLines(_ chunk: String, maxLines: Int) -> [String] {
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > maxLines else { return [chunk] }
        var result: [String] = []
        var buffer: [String] = []
        var contentLines = 0
        var fence: (openLine: String, closeLine: String, markerChar: Character, markerLength: Int)?
        for (offset, line) in lines.enumerated() {
            buffer.append(line)
            contentLines += 1
            let trimmed = line.drop { $0 == " " }
            if let first = trimmed.first, first == "`" || first == "~" {
                let markerLength = trimmed.prefix { $0 == first }.count
                if markerLength >= 3 {
                    if let current = fence {
                        let rest = trimmed.dropFirst(markerLength)
                        if current.markerChar == first, markerLength >= current.markerLength,
                           rest.allSatisfy({ $0 == " " || $0 == "\t" })
                        {
                            fence = nil
                        }
                    } else {
                        let indent = String(line.prefix { $0 == " " })
                        fence = (line, indent + String(repeating: first, count: markerLength), first, markerLength)
                    }
                }
            }
            let hasMore = offset < lines.count - 1
            let budget = max(1, maxLines - (fence == nil ? 0 : 1))
            if hasMore, contentLines > 0, buffer.count >= budget {
                var out = buffer
                if let current = fence {
                    out.append(current.closeLine)
                }
                result.append(out.joined(separator: "\n"))
                buffer = fence.map { [$0.openLine] } ?? []
                contentLines = 0
            }
        }
        if contentLines > 0 {
            result.append(buffer.joined(separator: "\n"))
        }
        return result
    }
}
