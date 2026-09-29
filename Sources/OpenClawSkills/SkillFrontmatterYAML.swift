import Foundation
import OpenClawProtocol

// YAML-subset and JSON5 parsing used for SKILL.md frontmatter.
//
// This is deliberately a subset: it covers what upstream skill files use (top-level `key: value`,
// quoted scalars, `|`/`>` block scalars, flow collections spanning lines, and simple indented
// block mappings and sequences). Values keep insertion order so structured values re-serialize the
// way upstream `JSON.stringify` does.

/// Ordered JSON-like value produced by the frontmatter and JSON5 parsers.
indirect enum FrontmatterValue: Equatable, Sendable {
    case string(String)
    case number(String)
    case bool(Bool)
    case null
    case array([FrontmatterValue])
    case object([FrontmatterMember])

    /// Compact JSON serialization in insertion order (upstream `JSON.stringify`).
    var jsonString: String {
        switch self {
        case .string(let value):
            return Self.quoteJSON(value)
        case .number(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .array(let items):
            return "[" + items.map(\.jsonString).joined(separator: ",") + "]"
        case .object(let members):
            return "{" + members.map { Self.quoteJSON($0.key) + ":" + $0.value.jsonString }.joined(separator: ",") + "}"
        }
    }

    /// Scalar text as upstream coerces it into the flat frontmatter map (`nil` for null).
    var frontmatterText: String? {
        switch self {
        case .string(let value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return nil
        case .array, .object:
            return self.jsonString
        }
    }

    var isStructured: Bool {
        switch self {
        case .array, .object:
            return true
        default:
            return false
        }
    }

    /// Converts into the SDK's enum-backed `AnyCodable`.
    var anyCodable: AnyCodable {
        switch self {
        case .string(let value):
            return AnyCodable(.string(value))
        case .number(let raw):
            if let int = Int(raw) {
                return AnyCodable(.int(int))
            }
            if raw.lowercased().hasPrefix("0x") || raw.lowercased().hasPrefix("-0x") {
                let negative = raw.hasPrefix("-")
                let digits = raw.dropFirst(negative ? 3 : 2)
                if let value = Int(digits, radix: 16) {
                    return AnyCodable(.int(negative ? -value : value))
                }
            }
            return AnyCodable(.double(Double(raw) ?? 0))
        case .bool(let value):
            return AnyCodable(.bool(value))
        case .null:
            return AnyCodable(.null)
        case .array(let items):
            return AnyCodable(.array(items.map(\.anyCodable)))
        case .object(let members):
            var dict: [String: AnyCodable] = [:]
            for member in members {
                dict[member.key] = member.value.anyCodable
            }
            return AnyCodable(.object(dict))
        }
    }

    static func quoteJSON(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }
}

/// One ordered object member.
struct FrontmatterMember: Equatable, Sendable {
    let key: String
    let value: FrontmatterValue
}

/// Error raised by the YAML-subset and JSON5 parsers.
struct FrontmatterSyntaxError: Error, Equatable, Sendable {
    let code: String
    let message: String
}

// MARK: - Flow / JSON5 parser

/// Parser for JSON5 text and YAML flow collections.
///
/// Accepts trailing commas, unquoted identifier keys, single- and double-quoted strings, `//`,
/// `/* */` and ` #` comments, hex numbers, and YAML plain scalars inside flow collections. Nesting is
/// limited to ``maxDepth`` levels (`TOO_DEEP`), so a hostile SKILL.md cannot overflow the stack.
struct FlowValueParser {
    /// Deepest collection nesting accepted.
    static let maxDepth = 64

    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var depth = 0

    init(_ text: String) {
        self.scalars = Array(text.unicodeScalars)
    }

    /// Parses one complete value; trailing non-whitespace (other than comments) is an error.
    static func parseDocument(_ text: String) throws -> FrontmatterValue {
        var parser = FlowValueParser(text)
        parser.skipTrivia()
        let value = try parser.parseValue(inFlow: false)
        parser.skipTrivia()
        guard parser.index >= parser.scalars.count else {
            throw FrontmatterSyntaxError(code: "TRAILING_CONTENT", message: "unexpected trailing content")
        }
        return value
    }

    /// Returns whether `text` has balanced brackets outside of quotes (used to find multi-line flow ends).
    static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        var quote: Unicode.Scalar?
        var escaped = false
        for scalar in text.unicodeScalars {
            if let active = quote {
                if escaped {
                    escaped = false
                } else if scalar == "\\" && active == "\"" {
                    escaped = true
                } else if scalar == active {
                    quote = nil
                }
                continue
            }
            switch scalar {
            case "\"", "'":
                quote = scalar
            case "{", "[":
                depth += 1
            case "}", "]":
                depth -= 1
            default:
                break
            }
        }
        return depth <= 0 && quote == nil
    }

    private var current: Unicode.Scalar? {
        self.index < self.scalars.count ? self.scalars[self.index] : nil
    }

    private func peek(_ offset: Int) -> Unicode.Scalar? {
        let target = self.index + offset
        return target < self.scalars.count ? self.scalars[target] : nil
    }

    private mutating func skipTrivia() {
        while let scalar = self.current {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{FEFF}" {
                self.index += 1
            } else if scalar == "/" && self.peek(1) == "/" {
                while let next = self.current, next != "\n" { self.index += 1 }
            } else if scalar == "/" && self.peek(1) == "*" {
                self.index += 2
                while self.current != nil, !(self.current == "*" && self.peek(1) == "/") { self.index += 1 }
                self.index = min(self.scalars.count, self.index + 2)
            } else if scalar == "#" && self.isCommentStart() {
                while let next = self.current, next != "\n" { self.index += 1 }
            } else {
                break
            }
        }
    }

    private func isCommentStart() -> Bool {
        guard self.index > 0 else { return true }
        let previous = self.scalars[self.index - 1]
        return previous == " " || previous == "\t" || previous == "\n" || previous == "," || previous == "{" || previous == "["
    }

    private mutating func parseValue(inFlow: Bool) throws -> FrontmatterValue {
        self.skipTrivia()
        guard let scalar = self.current else {
            throw FrontmatterSyntaxError(code: "UNEXPECTED_END", message: "unexpected end of input")
        }
        switch scalar {
        case "{":
            return try self.parseObject()
        case "[":
            return try self.parseArray()
        case "\"", "'":
            return .string(try self.parseQuoted())
        default:
            return try self.parsePlain(inFlow: inFlow)
        }
    }

    private mutating func enterCollection() throws {
        self.depth += 1
        if self.depth > Self.maxDepth {
            throw FrontmatterSyntaxError(code: "TOO_DEEP", message: "flow collection nesting exceeds \(Self.maxDepth)")
        }
    }

    private mutating func parseObject() throws -> FrontmatterValue {
        try self.enterCollection()
        defer { self.depth -= 1 }
        self.index += 1
        var members: [FrontmatterMember] = []
        while true {
            self.skipTrivia()
            guard let scalar = self.current else {
                throw FrontmatterSyntaxError(code: "UNTERMINATED_OBJECT", message: "missing closing }")
            }
            if scalar == "}" {
                self.index += 1
                return .object(members)
            }
            let key: String
            if scalar == "\"" || scalar == "'" {
                key = try self.parseQuoted()
            } else {
                key = try self.parseBareKey()
            }
            self.skipTrivia()
            guard self.current == ":" else {
                throw FrontmatterSyntaxError(code: "EXPECTED_COLON", message: "expected ':' after key \(key)")
            }
            self.index += 1
            let value = try self.parseValue(inFlow: true)
            if let existing = members.firstIndex(where: { $0.key == key }) {
                members[existing] = FrontmatterMember(key: key, value: value)
            } else {
                members.append(FrontmatterMember(key: key, value: value))
            }
            self.skipTrivia()
            if self.current == "," {
                self.index += 1
                continue
            }
            if self.current == "}" {
                continue
            }
            throw FrontmatterSyntaxError(code: "EXPECTED_COMMA", message: "expected ',' or '}' in object")
        }
    }

    private mutating func parseArray() throws -> FrontmatterValue {
        try self.enterCollection()
        defer { self.depth -= 1 }
        self.index += 1
        var items: [FrontmatterValue] = []
        while true {
            self.skipTrivia()
            guard let scalar = self.current else {
                throw FrontmatterSyntaxError(code: "UNTERMINATED_ARRAY", message: "missing closing ]")
            }
            if scalar == "]" {
                self.index += 1
                return .array(items)
            }
            items.append(try self.parseValue(inFlow: true))
            self.skipTrivia()
            if self.current == "," {
                self.index += 1
                continue
            }
            if self.current == "]" {
                continue
            }
            throw FrontmatterSyntaxError(code: "EXPECTED_COMMA", message: "expected ',' or ']' in array")
        }
    }

    private mutating func parseBareKey() throws -> String {
        var key = String.UnicodeScalarView()
        while let scalar = self.current, scalar != ":", scalar != ",", scalar != "}", scalar != "\n" {
            key.append(scalar)
            self.index += 1
        }
        let trimmed = String(key).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw FrontmatterSyntaxError(code: "EMPTY_KEY", message: "empty object key")
        }
        return trimmed
    }

    private mutating func parseQuoted() throws -> String {
        guard let quote = self.current else {
            throw FrontmatterSyntaxError(code: "UNEXPECTED_END", message: "unexpected end of input")
        }
        self.index += 1
        var output = String.UnicodeScalarView()
        while let scalar = self.current {
            self.index += 1
            if scalar == quote {
                // YAML single-quoted strings escape a quote by doubling it.
                if quote == "'" && self.current == "'" {
                    output.append("'")
                    self.index += 1
                    continue
                }
                return String(output)
            }
            if scalar == "\\" {
                guard let escaped = self.current else { break }
                self.index += 1
                switch escaped {
                case "n": output.append("\n")
                case "t": output.append("\t")
                case "r": output.append("\r")
                case "b": output.append("\u{08}")
                case "f": output.append("\u{0C}")
                case "0": output.append("\0")
                case "\n": continue
                case "u":
                    let hex = String(String.UnicodeScalarView(self.scalars[self.index..<min(self.scalars.count, self.index + 4)]))
                    if hex.count == 4, let value = UInt32(hex, radix: 16) {
                        self.index += 4
                        // Combine UTF-16 surrogate pairs (`😀`).
                        if (0xD800...0xDBFF).contains(value), self.current == "\\", self.peek(1) == "u" {
                            let lowHex = String(String.UnicodeScalarView(self.scalars[(self.index + 2)..<min(self.scalars.count, self.index + 6)]))
                            if lowHex.count == 4, let low = UInt32(lowHex, radix: 16), (0xDC00...0xDFFF).contains(low) {
                                self.index += 6
                                let combined = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                                if let scalar = Unicode.Scalar(combined) { output.append(scalar) }
                                continue
                            }
                        }
                        if let scalar = Unicode.Scalar(value) { output.append(scalar) }
                    } else {
                        output.append("u")
                    }
                default:
                    output.append(escaped)
                }
                continue
            }
            output.append(scalar)
        }
        throw FrontmatterSyntaxError(code: "UNTERMINATED_STRING", message: "missing closing quote")
    }

    private mutating func parsePlain(inFlow: Bool) throws -> FrontmatterValue {
        var raw = String.UnicodeScalarView()
        while let scalar = self.current {
            if inFlow && (scalar == "," || scalar == "]" || scalar == "}") { break }
            if scalar == "\n" && inFlow { break }
            if scalar == "#" && self.isCommentStart() { break }
            if scalar == "/" && (self.peek(1) == "/" || self.peek(1) == "*") {
                // `//` inside a plain scalar (for example a URL) is data, not a comment.
                let previous = self.index > 0 ? self.scalars[self.index - 1] : " "
                if previous == " " || previous == "\t" { break }
            }
            raw.append(scalar)
            self.index += 1
        }
        let text = String(raw).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            throw FrontmatterSyntaxError(code: "EMPTY_VALUE", message: "expected a value")
        }
        return Self.classifyPlain(text)
    }

    /// Classifies a plain scalar with YAML core-schema rules (bool, null, numbers).
    static func classifyPlain(_ text: String) -> FrontmatterValue {
        switch text {
        case "true", "True", "TRUE":
            return .bool(true)
        case "false", "False", "FALSE":
            return .bool(false)
        case "null", "Null", "NULL", "~":
            return .null
        default:
            break
        }
        if let int = Int(text.hasPrefix("+") ? String(text.dropFirst()) : text) {
            return .number(String(int))
        }
        let lower = text.lowercased()
        if lower.hasPrefix("0x") || lower.hasPrefix("-0x"), Int(lower.replacingOccurrences(of: "0x", with: ""), radix: 16) != nil {
            return .number(text)
        }
        let isNumeric = text.range(of: "^[-+]?(\\d+\\.?\\d*|\\.\\d+)([eE][-+]?\\d+)?$", options: .regularExpression) != nil
        if isNumeric, let double = Double(text) {
            if double.rounded() == double, abs(double) < 9.0e15 {
                return .number(String(Int(double)))
            }
            return .number(String(double))
        }
        return .string(text)
    }
}

// MARK: - YAML subset

/// YAML-subset parser for frontmatter blocks.
struct YAMLSubsetParser {
    private struct Line {
        let raw: String
        let indent: Int
        let content: String
        var isBlank: Bool { self.content.isEmpty || self.content.hasPrefix("#") }
    }

    private let lines: [Line]

    init(_ block: String) {
        self.lines = block.components(separatedBy: "\n").map { raw in
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let content = raw.trimmingCharacters(in: .whitespaces)
            return Line(raw: raw, indent: indent, content: content)
        }
    }

    /// Parses the block as a top-level mapping in declaration order.
    func parseTopLevel() throws -> [FrontmatterMember] {
        var index = 0
        let firstContent = self.lines.firstIndex { !$0.isBlank }
        guard let firstContent else { return [] }
        let rootIndent = self.lines[firstContent].indent
        let value = try self.parseMapping(from: &index, indent: rootIndent, depth: 0)
        guard case .object(let members) = value else {
            throw FrontmatterSyntaxError(code: "INVALID_ROOT", message: "frontmatter must be a YAML mapping")
        }
        if let stray = self.lines[index...].first(where: { !$0.isBlank }) {
            throw FrontmatterSyntaxError(code: "UNEXPECTED_CONTENT", message: "unexpected content: \(stray.content)")
        }
        return members
    }

    private func nextContentIndex(from index: Int) -> Int? {
        var cursor = index
        while cursor < self.lines.count {
            if !self.lines[cursor].isBlank { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func checkDepth(_ depth: Int) throws {
        if depth > FlowValueParser.maxDepth {
            throw FrontmatterSyntaxError(code: "TOO_DEEP", message: "YAML nesting exceeds \(FlowValueParser.maxDepth)")
        }
    }

    private func parseMapping(from index: inout Int, indent: Int, depth: Int) throws -> FrontmatterValue {
        try Self.checkDepth(depth)
        var members: [FrontmatterMember] = []
        while let cursor = self.nextContentIndex(from: index) {
            let line = self.lines[cursor]
            if line.indent < indent { break }
            if line.indent > indent {
                throw FrontmatterSyntaxError(code: "BAD_INDENT", message: "unexpected indentation: \(line.content)")
            }
            guard let (key, rest) = Self.splitKey(line.content) else {
                throw FrontmatterSyntaxError(code: "BLOCK_AS_IMPLICIT_KEY", message: "expected key: value, got \(line.content)")
            }
            index = cursor + 1
            let value = try self.parseValue(rest: rest, from: &index, parentIndent: indent, depth: depth + 1)
            if let existing = members.firstIndex(where: { $0.key == key }) {
                members[existing] = FrontmatterMember(key: key, value: value)
            } else {
                members.append(FrontmatterMember(key: key, value: value))
            }
        }
        return .object(members)
    }

    private func parseSequence(from index: inout Int, indent: Int, depth: Int) throws -> FrontmatterValue {
        try Self.checkDepth(depth)
        var items: [FrontmatterValue] = []
        while let cursor = self.nextContentIndex(from: index) {
            let line = self.lines[cursor]
            if line.indent < indent || !(line.content == "-" || line.content.hasPrefix("- ")) { break }
            if line.indent > indent {
                throw FrontmatterSyntaxError(code: "BAD_INDENT", message: "unexpected indentation: \(line.content)")
            }
            let rest = line.content == "-" ? "" : String(line.content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            index = cursor + 1
            if let (key, value) = Self.splitKey(rest), !rest.hasPrefix("\""), !rest.hasPrefix("'"), !rest.hasPrefix("{"), !rest.hasPrefix("[") {
                // `- key: value` starts an inline mapping item; continuation keys are indented further.
                var members = [FrontmatterMember(key: key, value: try self.parseValue(rest: value, from: &index, parentIndent: indent + 2, depth: depth + 1))]
                if let next = self.nextContentIndex(from: index), self.lines[next].indent > indent {
                    let nested = try self.parseMapping(from: &index, indent: self.lines[next].indent, depth: depth + 1)
                    if case .object(let more) = nested { members.append(contentsOf: more) }
                }
                items.append(.object(members))
            } else {
                items.append(try self.parseValue(rest: rest, from: &index, parentIndent: indent, depth: depth + 1))
            }
        }
        return .array(items)
    }

    private func parseValue(rest: String, from index: inout Int, parentIndent: Int, depth: Int) throws -> FrontmatterValue {
        try Self.checkDepth(depth)
        let value = Self.stripTrailingComment(rest)
        if value.isEmpty {
            guard let next = self.nextContentIndex(from: index), self.lines[next].indent > parentIndent else {
                return .null
            }
            let child = self.lines[next]
            if child.content.hasPrefix("{") || child.content.hasPrefix("[") {
                return try self.parseFlow(startingWith: "", from: &index, parentIndent: parentIndent)
            }
            // One nesting level per collection: the caller already counted this value.
            if child.content == "-" || child.content.hasPrefix("- ") {
                return try self.parseSequence(from: &index, indent: child.indent, depth: depth)
            }
            if Self.splitKey(child.content) != nil, !child.content.hasPrefix("\""), !child.content.hasPrefix("'") {
                return try self.parseMapping(from: &index, indent: child.indent, depth: depth)
            }
            return .string(self.foldPlain(initial: "", from: &index, parentIndent: parentIndent))
        }
        if let indicator = value.first, indicator == "|" || indicator == ">",
           value.range(of: "^[|>][1-9]?[-+]?[1-9]?$", options: .regularExpression) != nil
        {
            return .string(self.parseBlockScalar(header: value, from: &index, parentIndent: parentIndent))
        }
        if value.hasPrefix("{") || value.hasPrefix("[") {
            return try self.parseFlow(startingWith: value, from: &index, parentIndent: parentIndent)
        }
        if value.hasPrefix("\"") || value.hasPrefix("'") {
            var text = value
            // Quoted scalars may continue on following lines until the closing quote.
            while !Self.isClosedQuote(text), let next = self.nextContentIndex(from: index), self.lines[next].indent > parentIndent {
                text += " " + self.lines[next].content
                index = next + 1
            }
            return try FlowValueParser.parseDocument(text)
        }
        return FlowValueParser.classifyPlain(self.foldPlain(initial: value, from: &index, parentIndent: parentIndent))
    }

    private func parseFlow(startingWith start: String, from index: inout Int, parentIndent: Int) throws -> FrontmatterValue {
        var text = start
        while !(FlowValueParser.isBalanced(text) && !text.isEmpty) {
            guard index < self.lines.count else { break }
            let line = self.lines[index]
            if !line.isBlank, line.indent <= parentIndent, !text.isEmpty { break }
            text += "\n" + line.raw
            index += 1
        }
        return try FlowValueParser.parseDocument(text)
    }

    private func foldPlain(initial: String, from index: inout Int, parentIndent: Int) -> String {
        var parts = initial.isEmpty ? [] : [initial]
        while index < self.lines.count {
            let line = self.lines[index]
            if line.content.isEmpty {
                index += 1
                continue
            }
            if line.indent <= parentIndent { break }
            parts.append(Self.stripTrailingComment(line.content))
            index += 1
        }
        return parts.joined(separator: " ")
    }

    private func parseBlockScalar(header: String, from index: inout Int, parentIndent: Int) -> String {
        let literal = header.hasPrefix("|")
        let chomping: Character? = header.contains("-") ? "-" : (header.contains("+") ? "+" : nil)
        var collected: [String] = []
        var blockIndent: Int?
        while index < self.lines.count {
            let line = self.lines[index]
            if line.content.isEmpty {
                collected.append("")
                index += 1
                continue
            }
            if line.indent <= parentIndent { break }
            let indent = blockIndent ?? line.indent
            blockIndent = indent
            collected.append(String(line.raw.dropFirst(min(indent, line.raw.count))))
            index += 1
        }
        var trailingEmpty = 0
        while collected.last == "" {
            collected.removeLast()
            trailingEmpty += 1
        }
        var body: String
        if literal {
            body = collected.joined(separator: "\n")
        } else {
            body = ""
            for (offset, part) in collected.enumerated() {
                if offset == 0 {
                    body = part
                } else if part.isEmpty || collected[offset - 1].isEmpty {
                    body += "\n" + part
                } else {
                    body += " " + part
                }
            }
        }
        switch chomping {
        case "-":
            return body
        case "+":
            return body + String(repeating: "\n", count: trailingEmpty + 1)
        default:
            return body.isEmpty ? body : body + "\n"
        }
    }

    /// Splits `key: rest` (key may be quoted); returns `nil` when the line is not a mapping entry.
    static func splitKey(_ content: String) -> (String, String)? {
        if content.hasPrefix("\"") || content.hasPrefix("'") {
            let quote = content.first!
            guard let close = content.dropFirst().firstIndex(of: quote) else { return nil }
            let key = String(content[content.index(after: content.startIndex)..<close])
            let after = content[content.index(after: close)...]
            guard after.hasPrefix(":") else { return nil }
            return (key, String(after.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        guard let match = content.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.\\-]*[ \\t]*:([ \\t]|$)", options: .regularExpression) else {
            return nil
        }
        let keyPart = content[match].trimmingCharacters(in: .whitespaces)
        let key = String(keyPart.dropLast()).trimmingCharacters(in: .whitespaces)
        return (key, String(content[match.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    static func stripTrailingComment(_ value: String) -> String {
        guard !value.hasPrefix("\""), !value.hasPrefix("'"), let range = value.range(of: " #") else {
            return value.hasPrefix("#") ? "" : value
        }
        return String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    static func isClosedQuote(_ text: String) -> Bool {
        guard let quote = text.first, text.count >= 2 else { return false }
        var escaped = false
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && quote == "\"" {
                escaped = true
            } else if character == quote {
                let next = text.index(after: index)
                if quote == "'" && next < text.endIndex && text[next] == "'" {
                    index = text.index(after: next)
                    continue
                }
                return true
            }
            index = text.index(after: index)
        }
        return false
    }
}
