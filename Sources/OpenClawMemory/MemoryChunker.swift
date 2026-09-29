import Foundation

/// One chunk of a Markdown file (1-based, inclusive line range).
public struct MemoryChunk: Codable, Sendable, Equatable {
    /// First line (1-based).
    public let startLine: Int
    /// Last line (1-based, inclusive).
    public let endLine: Int
    /// Chunk text (lines joined with `\n`).
    public let text: String

    /// Creates a chunk.
    /// - Parameters:
    ///   - startLine: First line.
    ///   - endLine: Last line.
    ///   - text: Text.
    public init(startLine: Int, endLine: Int, text: String) {
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
    }
}

/// Line-based Markdown chunker (port of upstream `chunkMarkdown`, memory-host-sdk).
///
/// Windows hold about ``tokens`` tokens with ``overlap`` tokens carried into the next window. Tokens
/// are estimated as characters / 4 with CJK characters weighted as one token each; lines wider than a
/// window are split without breaking code points.
public struct MemoryChunker: Sendable, Equatable {
    /// Upstream `DEFAULT_CHUNK_TOKENS`.
    public static let defaultTokens = 400
    /// Upstream `DEFAULT_CHUNK_OVERLAP`.
    public static let defaultOverlap = 80
    /// Upstream `CHARS_PER_TOKEN_ESTIMATE`.
    public static let charsPerToken = 4

    /// Target tokens per chunk.
    public let tokens: Int
    /// Overlap tokens.
    public let overlap: Int

    /// Creates a chunker.
    /// - Parameters:
    ///   - tokens: Target tokens per chunk.
    ///   - overlap: Overlap tokens.
    public init(tokens: Int = MemoryChunker.defaultTokens, overlap: Int = MemoryChunker.defaultOverlap) {
        self.tokens = max(1, tokens)
        self.overlap = max(0, overlap)
    }

    /// Estimated character weight (CJK characters count as a full token).
    /// - Parameter text: Text.
    /// - Returns: Weighted character count.
    public static func estimatedChars(_ text: String) -> Int {
        var total = 0
        for scalar in text.unicodeScalars {
            total += MemoryTokenizer.isCJK(scalar) ? Self.charsPerToken : scalar.utf16.count
        }
        return total
    }

    /// Estimated tokens.
    /// - Parameter text: Text.
    /// - Returns: Token estimate.
    public static func estimatedTokens(_ text: String) -> Int {
        (self.estimatedChars(text) + self.charsPerToken - 1) / self.charsPerToken
    }

    /// Splits Markdown into chunks.
    /// - Parameter content: File contents.
    /// - Returns: Chunks in order.
    public func chunk(_ content: String) -> [MemoryChunk] {
        let lines = content.components(separatedBy: "\n")
        let maxChars = max(32, self.tokens * Self.charsPerToken)
        let overlapChars = max(0, self.overlap * Self.charsPerToken)
        var chunks: [MemoryChunk] = []
        var current: [(line: String, lineNo: Int)] = []
        var currentChars = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            chunks.append(MemoryChunk(startLine: first.lineNo, endLine: last.lineNo, text: current.map(\.line).joined(separator: "\n")))
        }

        func carryOverlap(_ window: Int) {
            guard window > 0, !current.isEmpty else {
                current = []
                currentChars = 0
                return
            }
            var accumulated = 0
            var kept: [(line: String, lineNo: Int)] = []
            for entry in current.reversed() {
                let size = Self.estimatedChars(entry.line) + 1
                let remaining = window - accumulated
                if size > remaining {
                    if kept.isEmpty {
                        let tail = Self.tail(of: entry.line, budget: remaining - 1)
                        if !tail.isEmpty {
                            kept.insert((tail, entry.lineNo), at: 0)
                            accumulated += Self.estimatedChars(tail) + 1
                        }
                    }
                    break
                }
                accumulated += size
                kept.insert(entry, at: 0)
                if accumulated >= window { break }
            }
            current = kept
            currentChars = accumulated
        }

        func append(_ segment: String, lineNo: Int, chars: Int) {
            let lineSize = chars + 1
            if currentChars + lineSize > maxChars, !current.isEmpty {
                flush()
                carryOverlap(min(overlapChars, max(0, maxChars - lineSize)))
            }
            current.append((segment, lineNo))
            currentChars += lineSize
        }

        for (index, line) in lines.enumerated() {
            let lineNo = index + 1
            if line.isEmpty {
                append("", lineNo: lineNo, chars: 0)
                continue
            }
            var part = ""
            var partChars = 0
            for scalar in line.unicodeScalars {
                let weight = MemoryTokenizer.isCJK(scalar) ? Self.charsPerToken : scalar.utf16.count
                if partChars + weight > maxChars, !part.isEmpty {
                    append(part, lineNo: lineNo, chars: partChars)
                    part = ""
                    partChars = 0
                }
                part.unicodeScalars.append(scalar)
                partChars += weight
            }
            append(part, lineNo: lineNo, chars: partChars)
        }
        flush()
        return chunks
    }

    static func tail(of text: String, budget: Int) -> String {
        guard budget > 0 else { return "" }
        var accumulated = 0
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars.reversed() {
            let weight = MemoryTokenizer.isCJK(scalar) ? Self.charsPerToken : scalar.utf16.count
            if accumulated + weight > budget { break }
            accumulated += weight
            scalars.append(scalar)
        }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars.reversed())
        return String(result)
    }
}

/// CJK-aware tokenizer shared by BM25, MMR and snippets (upstream `memory/tokenize.ts`).
public enum MemoryTokenizer {
    /// Whether a scalar belongs to a CJK-family script without word boundaries.
    /// - Parameter scalar: Unicode scalar.
    /// - Returns: `true` for Hiragana, Katakana, CJK ideographs (incl. Extension A) and Hangul.
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0x1100...0x11FF:
            return true
        default:
            return false
        }
    }

    /// Lowercased ASCII-alphanumeric/underscore tokens, CJK unigrams and adjacent-CJK bigrams, in order.
    /// - Parameter text: Text.
    /// - Returns: Tokens (duplicates kept for term frequency).
    public static func tokens(_ text: String) -> [String] {
        let lower = text.lowercased()
        var tokens: [String] = []
        var word = String.UnicodeScalarView()
        var previousCJK: Unicode.Scalar?
        var unigrams: [String] = []
        func flushWord() {
            if !word.isEmpty {
                tokens.append(String(word))
                word = String.UnicodeScalarView()
            }
        }
        for scalar in lower.unicodeScalars {
            if self.isCJK(scalar) {
                flushWord()
                if let previousCJK {
                    var bigram = String.UnicodeScalarView()
                    bigram.append(previousCJK)
                    bigram.append(scalar)
                    tokens.append(String(bigram))
                }
                unigrams.append(String(scalar))
                previousCJK = scalar
            } else {
                previousCJK = nil
                if scalar.properties.isAlphabetic || (48...57).contains(scalar.value) || scalar == "_" {
                    word.append(scalar)
                } else {
                    flushWord()
                }
            }
        }
        flushWord()
        return tokens + unigrams
    }

    /// Token set for Jaccard similarity.
    /// - Parameter text: Text.
    /// - Returns: Distinct tokens.
    public static func tokenSet(_ text: String) -> Set<String> {
        Set(self.tokens(text))
    }

    /// Jaccard similarity of two token sets (1 when both are empty).
    /// - Parameters:
    ///   - lhs: First set.
    ///   - rhs: Second set.
    /// - Returns: Similarity in `0...1`.
    public static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        if lhs.isEmpty && rhs.isEmpty { return 1 }
        if lhs.isEmpty || rhs.isEmpty { return 0 }
        let intersection = lhs.intersection(rhs).count
        return Double(intersection) / Double(lhs.count + rhs.count - intersection)
    }
}

/// Okapi BM25 index over tokenized documents (`k1 = 1.2`, `b = 0.75`, SDK defaults).
public struct BM25Index: Codable, Sendable, Equatable {
    /// Term frequency saturation.
    public var k1: Double
    /// Length normalization.
    public var b: Double
    private var termFrequencies: [String: [String: Int]] = [:]
    private var documentLengths: [String: Int] = [:]
    private var documentFrequency: [String: Int] = [:]
    private var totalLength = 0

    /// Creates an empty index.
    /// - Parameters:
    ///   - k1: Saturation.
    ///   - b: Length normalization.
    public init(k1: Double = 1.2, b: Double = 0.75) {
        self.k1 = k1
        self.b = b
    }

    /// Number of documents.
    public var count: Int {
        self.documentLengths.count
    }

    /// Adds or replaces a document.
    /// - Parameters:
    ///   - id: Document identifier.
    ///   - text: Document text.
    public mutating func upsert(id: String, text: String) {
        self.remove(id: id)
        let tokens = MemoryTokenizer.tokens(text)
        var frequencies: [String: Int] = [:]
        for token in tokens { frequencies[token, default: 0] += 1 }
        self.termFrequencies[id] = frequencies
        self.documentLengths[id] = tokens.count
        self.totalLength += tokens.count
        for term in frequencies.keys { self.documentFrequency[term, default: 0] += 1 }
    }

    /// Removes a document.
    /// - Parameter id: Document identifier.
    public mutating func remove(id: String) {
        guard let frequencies = self.termFrequencies.removeValue(forKey: id) else { return }
        self.totalLength -= self.documentLengths.removeValue(forKey: id) ?? 0
        for term in frequencies.keys {
            let remaining = (self.documentFrequency[term] ?? 1) - 1
            self.documentFrequency[term] = remaining > 0 ? remaining : nil
        }
    }

    /// Scores documents for a query.
    /// - Parameters:
    ///   - query: Query text.
    ///   - limit: Maximum hits.
    /// - Returns: `(id, score)` pairs with positive scores, best first (ties by id).
    public func search(_ query: String, limit: Int) -> [(id: String, score: Double)] {
        let terms = Array(Set(MemoryTokenizer.tokens(query)))
        guard !terms.isEmpty, !self.documentLengths.isEmpty else { return [] }
        let documentCount = Double(self.documentLengths.count)
        let averageLength = max(1, Double(self.totalLength) / documentCount)
        var scores: [String: Double] = [:]
        for term in terms {
            guard let df = self.documentFrequency[term], df > 0 else { continue }
            let idf = log(1 + (documentCount - Double(df) + 0.5) / (Double(df) + 0.5))
            for (id, frequencies) in self.termFrequencies {
                guard let tf = frequencies[term] else { continue }
                let length = Double(self.documentLengths[id] ?? 0)
                let numerator = Double(tf) * (self.k1 + 1)
                let denominator = Double(tf) + self.k1 * (1 - self.b + self.b * length / averageLength)
                scores[id, default: 0] += idf * numerator / denominator
            }
        }
        return scores
            .filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(max(0, limit))
            .map { (id: $0.key, score: $0.value) }
    }
}
