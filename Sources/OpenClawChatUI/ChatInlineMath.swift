import CoreGraphics
import Foundation

// Ported from upstream OpenClaw 2026.9.6 `ChatInlineMath.swift`.
//
// Upstream typesets LaTeX with SwiftMath (MTMathUILabel/MTMathImage). SwiftMath is not an
// OpenClawKit dependency: the scanner and the hostile-input guards are ported verbatim, and math
// that passes them renders as its LaTeX source in the monospaced chat face (inline) or as a
// code-style block labelled "LaTeX" (display). `ChatInlineMathImageCache.image` is the single
// seam a SwiftMath-backed renderer would fill.

struct ChatInlineMathSpan {
    let latex: String
    let source: String
}

enum ChatInlineMathScanner {
    enum Piece: Equatable {
        case markdown(String)
        case math(latex: String, source: String)
        case literal(String)
    }

    static let maxSpanCount = 16
    static let maxSourceBytes = 200

    static func pieces(in markdown: String) -> [Piece] {
        guard markdown.contains(#"\("#) else { return [.markdown(markdown)] }

        var pieces: [Piece] = []
        var textStart = markdown.startIndex
        var cursor = markdown.startIndex
        var spanCount = 0
        let codeSpans = self.confirmedCodeSpans(in: markdown)
        var codeSpanIndex = 0

        while cursor < markdown.endIndex {
            if codeSpanIndex < codeSpans.count,
               cursor == codeSpans[codeSpanIndex].lowerBound
            {
                cursor = codeSpans[codeSpanIndex].upperBound
                codeSpanIndex += 1
                continue
            }

            guard markdown[cursor...].hasPrefix(#"\("#),
                  !ChatMarkdownBlockSyntax.isEscaped(at: cursor, in: markdown)
            else {
                cursor = markdown.index(after: cursor)
                continue
            }

            if textStart < cursor {
                pieces.append(.markdown(String(markdown[textStart..<cursor])))
            }
            let opener = cursor
            let contentStart = markdown.index(cursor, offsetBy: 2)
            guard let candidate = self.candidate(
                startingAt: contentStart,
                in: markdown,
                codeSpans: codeSpans)
            else {
                pieces.append(.literal(String(markdown[opener...])))
                return pieces
            }

            spanCount += 1
            let source = String(markdown[opener..<candidate.end])
            let latex = String(markdown[contentStart..<candidate.closeStart])
            if spanCount <= self.maxSpanCount,
               !candidate.containsNewline,
               source.utf8.count <= self.maxSourceBytes
            {
                pieces.append(.math(latex: latex, source: source))
            } else {
                pieces.append(.literal(source))
            }
            cursor = candidate.end
            textStart = cursor
        }

        if textStart < markdown.endIndex {
            pieces.append(.markdown(String(markdown[textStart...])))
        }
        return pieces
    }

    private struct Candidate {
        let closeStart: String.Index
        let end: String.Index
        let containsNewline: Bool
    }

    private static func candidate(
        startingAt start: String.Index,
        in markdown: String,
        codeSpans: [Range<String.Index>]) -> Candidate?
    {
        var cursor = start
        var codeSpanIndex = self.firstCodeSpan(endingAfter: start, in: codeSpans)
        var containsNewline = false
        while cursor < markdown.endIndex {
            if codeSpanIndex < codeSpans.count,
               cursor == codeSpans[codeSpanIndex].lowerBound
            {
                cursor = codeSpans[codeSpanIndex].upperBound
                codeSpanIndex += 1
                continue
            }
            let character = markdown[cursor]
            if character == "\n" || character == "\r" {
                containsNewline = true
            }
            if markdown[cursor...].hasPrefix(#"\)"#),
               !ChatMarkdownBlockSyntax.isEscaped(at: cursor, in: markdown)
            {
                return Candidate(
                    closeStart: cursor,
                    end: markdown.index(cursor, offsetBy: 2),
                    containsNewline: containsNewline)
            }
            cursor = markdown.index(after: cursor)
        }
        return nil
    }

    private struct BacktickRun {
        let start: String.Index
        let end: String.Index
        let length: Int
        let canOpen: Bool
    }

    private static func confirmedCodeSpans(in markdown: String) -> [Range<String.Index>] {
        var runs: [BacktickRun] = []
        var cursor = markdown.startIndex
        while cursor < markdown.endIndex {
            guard markdown[cursor] == "`" else {
                cursor = markdown.index(after: cursor)
                continue
            }
            let end = self.endOfBacktickRun(at: cursor, in: markdown)
            runs.append(BacktickRun(
                start: cursor,
                end: end,
                length: markdown.distance(from: cursor, to: end),
                canOpen: !ChatMarkdownBlockSyntax.isEscaped(at: cursor, in: markdown)))
            cursor = end
        }

        var nextMatchingRun = [Int?](repeating: nil, count: runs.count)
        var nextIndexByLength: [Int: Int] = [:]
        for index in runs.indices.reversed() {
            nextMatchingRun[index] = nextIndexByLength[runs[index].length]
            nextIndexByLength[runs[index].length] = index
        }

        var spans: [Range<String.Index>] = []
        var index = 0
        while index < runs.count {
            guard runs[index].canOpen,
                  let closeIndex = nextMatchingRun[index]
            else {
                index += 1
                continue
            }
            spans.append(runs[index].start..<runs[closeIndex].end)
            index = closeIndex + 1
        }
        return spans
    }

    private static func firstCodeSpan(
        endingAfter index: String.Index,
        in spans: [Range<String.Index>]) -> Int
    {
        var lower = 0
        var upper = spans.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if spans[middle].upperBound <= index {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func endOfBacktickRun(at start: String.Index, in markdown: String) -> String.Index {
        var end = start
        while end < markdown.endIndex, markdown[end] == "`" {
            end = markdown.index(after: end)
        }
        return end
    }
}

/// Validated LaTeX, the fallback counterpart of SwiftMath's `MTMathList`.
struct ChatMathList: Equatable {
    let latex: String
}

/// Validated math is stable after its delimiter closes. A bounded cache avoids
/// repeating validation as later streaming deltas rerender old blocks.
@MainActor
enum ChatMathParseCache {
    private enum Result {
        case parsed(ChatMathList)
        case invalid
    }

    private static var cache: [String: Result] = [:]
    private static let capacity = 80
    private static let maxNestingDepth = 64
    private static let maxCommandCount = 128
    private static let unsafeCommands = [#"\color"#, #"\colorbox"#, #"\textcolor"#]

    /// Returns the validated math for `latex`, or nil when the source should stay literal text.
    /// The guards match upstream's SwiftMath admission rules so both renderers accept the same input.
    static func mathList(latex: String) -> ChatMathList? {
        guard !latex.isEmpty else { return nil }
        // Upstream's typesetter silently drops unsupported Unicode instead of reporting a parse
        // error; keep the same ASCII-only admission so both renderers agree.
        guard latex.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        // Bound hostile nesting before any recursive group handling.
        guard self.isWithinParserLimits(latex) else { return nil }
        // Chat owns the surrounding color, so color commands stay raw source.
        guard !self.unsafeCommands.contains(where: latex.contains) else { return nil }
        if let hit = self.cache[latex] {
            if case let .parsed(mathList) = hit {
                return mathList
            }
            return nil
        }

        let result: Result = self.hasBalancedGroups(latex) ? .parsed(ChatMathList(latex: latex)) : .invalid
        if self.cache.count >= self.capacity {
            self.cache.removeAll(keepingCapacity: true)
        }
        self.cache[latex] = result
        if case let .parsed(mathList) = result {
            return mathList
        }
        return nil
    }

    private static func isWithinParserLimits(_ latex: String) -> Bool {
        var depth = 0
        var commandCount = 0
        var escaped = false
        for character in latex {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                commandCount += 1
                if commandCount > self.maxCommandCount {
                    return false
                }
                escaped = true
            } else if character == "{" {
                depth += 1
                if depth > self.maxNestingDepth {
                    return false
                }
            } else if character == "}" {
                depth = max(0, depth - 1)
            }
        }
        return true
    }

    /// Unbalanced unescaped braces are a parse error in every LaTeX math parser.
    private static func hasBalancedGroups(_ latex: String) -> Bool {
        var depth = 0
        var escaped = false
        for character in latex {
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth < 0 { return false }
            default:
                break
            }
        }
        return depth == 0
    }
}

@MainActor
enum ChatInlineMathImageCache {
    private static let maxRenderedPixelArea: CGFloat = 262_144
    private static let maxRenderedPixelDimension: CGFloat = 4096

    /// Bitmap admission check shared with any typeset renderer: hostile input must not request an
    /// empty or oversized backing bitmap.
    static func isSafeImageSize(_ size: CGSize, scale: CGFloat) -> Bool {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0
        else { return false }
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        return pixelWidth.isFinite && pixelHeight.isFinite &&
            pixelWidth <= self.maxRenderedPixelDimension &&
            pixelHeight <= self.maxRenderedPixelDimension &&
            pixelWidth * pixelHeight <= self.maxRenderedPixelArea
    }
}
