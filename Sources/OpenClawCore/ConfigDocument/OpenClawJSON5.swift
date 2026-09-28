import Foundation
import OpenClawProtocol

/// Authored key order of every object in a parsed JSON/JSON5 document.
///
/// Swift dictionaries do not preserve order, so ``OpenClawJSON5`` records each object's keys by path
/// (array elements use their decimal index as the path component). ``OpenClawJSON5/serialize(_:keyOrder:sortedKeys:prettyPrinted:)``
/// uses it to write keys back in authored order, appending new keys alphabetically.
public struct ConfigKeyOrder: Sendable, Equatable {
    private var storage: [[String]: [String]] = [:]

    /// Creates an empty key order.
    public init() {}

    /// The recorded key order of the object at `path`, if any.
    /// - Parameter path: Object path (object keys and array indices).
    /// - Returns: Keys in authored order.
    public func keys(at path: [String]) -> [String]? {
        self.storage[path]
    }

    /// Records the key order of the object at `path`.
    /// - Parameters:
    ///   - keys: Keys in authored order.
    ///   - path: Object path.
    public mutating func set(_ keys: [String], at path: [String]) {
        self.storage[path] = keys
    }

    /// Every recorded object path.
    public var paths: [[String]] {
        Array(self.storage.keys)
    }
}

/// Small, dependency-free JSON5 reader and upstream-compatible JSON writer for `openclaw.json`.
///
/// Parsing accepts strict JSON and JSON5 (comments, trailing commas, unquoted keys, single-quoted
/// strings, hexadecimal numbers, leading/trailing decimal points, `+`, `Infinity`, `NaN` and line
/// continuations). It behaves the same on every platform, including Linux, and records authored key
/// order. Serialization matches `JSON.stringify(value, null, 2)`, which upstream uses for config writes.
public enum OpenClawJSON5 {
    /// A JSON/JSON5 syntax error with its 1-based position.
    public struct ParseError: Error, LocalizedError, Sendable, Equatable {
        /// Description of the problem.
        public var message: String
        /// 1-based line.
        public var line: Int
        /// 1-based column (in UTF-8 bytes).
        public var column: Int

        /// Human-readable description.
        public var errorDescription: String? {
            "Invalid config JSON at line \(self.line), column \(self.column): \(self.message)"
        }
    }

    /// Parses JSON (or JSON5 when allowed) into a JSON tree.
    /// - Parameters:
    ///   - data: UTF-8 document bytes.
    ///   - allowJSON5: Accept JSON5 syntax; `false` enforces strict JSON.
    /// - Returns: The parsed value.
    /// - Throws: ``ParseError`` for malformed input.
    public static func parse(_ data: Data, allowJSON5: Bool = true) throws -> AnyCodable {
        try self.parseWithKeyOrder(data, allowJSON5: allowJSON5).value
    }

    /// Parses a JSON/JSON5 string into a JSON tree.
    /// - Parameters:
    ///   - text: Document text.
    ///   - allowJSON5: Accept JSON5 syntax; `false` enforces strict JSON.
    /// - Returns: The parsed value.
    /// - Throws: ``ParseError`` for malformed input.
    public static func parse(_ text: String, allowJSON5: Bool = true) throws -> AnyCodable {
        try self.parse(Data(text.utf8), allowJSON5: allowJSON5)
    }

    /// Parses JSON/JSON5 and records the authored key order of every object.
    /// - Parameters:
    ///   - data: UTF-8 document bytes.
    ///   - allowJSON5: Accept JSON5 syntax; `false` enforces strict JSON.
    /// - Returns: The parsed value and its key order.
    /// - Throws: ``ParseError`` for malformed input.
    public static func parseWithKeyOrder(_ data: Data, allowJSON5: Bool = true) throws -> (value: AnyCodable, keyOrder: ConfigKeyOrder) {
        var parser = JSON5Parser(bytes: Array(data), allowJSON5: allowJSON5)
        let value = try parser.parseDocument()
        return (value, parser.keyOrder)
    }

    /// Serializes a JSON tree.
    ///
    /// With `prettyPrinted` the output matches `JSON.stringify(value, null, 2)` (two-space indent,
    /// `"key": value`), followed by no trailing newline. Keys follow `keyOrder` when recorded, otherwise
    /// alphabetical order; `sortedKeys` forces alphabetical order everywhere.
    /// - Parameters:
    ///   - value: JSON tree.
    ///   - keyOrder: Optional authored key order.
    ///   - sortedKeys: Ignore `keyOrder` and sort every object's keys.
    ///   - prettyPrinted: Indent with two spaces.
    /// - Returns: JSON text.
    public static func serialize(
        _ value: AnyCodable,
        keyOrder: ConfigKeyOrder? = nil,
        sortedKeys: Bool = false,
        prettyPrinted: Bool = true
    ) -> String {
        var writer = JSONTextWriter(keyOrder: sortedKeys ? nil : keyOrder, prettyPrinted: prettyPrinted)
        writer.write(value, path: [], indent: 0)
        return writer.output
    }

    /// Formats a double like ECMAScript `Number.prototype.toString`.
    /// - Parameter value: Finite number.
    /// - Returns: Shortest round-trip decimal text.
    public static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else {
            return "null"
        }
        if value == 0 {
            return "0"
        }
        let negative = value < 0
        let magnitude = abs(value)
        // Swift's description is the shortest round-trip representation; re-shape it per ECMAScript.
        let description = String(describing: magnitude)
        var mantissa = description
        var exponent = 0
        if let eIndex = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(description[..<eIndex])
            exponent = Int(description[description.index(after: eIndex)...]) ?? 0
        }
        var integerPart = mantissa
        var fractionPart = ""
        if let dot = mantissa.firstIndex(of: ".") {
            integerPart = String(mantissa[..<dot])
            fractionPart = String(mantissa[mantissa.index(after: dot)...])
        }
        var digits = integerPart + fractionPart
        var pointPosition = integerPart.count + exponent
        while digits.hasPrefix("0"), digits.count > 1 {
            digits.removeFirst()
            pointPosition -= 1
        }
        while digits.hasSuffix("0"), digits.count > 1 {
            digits.removeLast()
        }
        let digitCount = digits.count
        var result: String
        if digitCount <= pointPosition, pointPosition <= 21 {
            result = digits + String(repeating: "0", count: pointPosition - digitCount)
        } else if pointPosition > 0, pointPosition <= 21 {
            let split = digits.index(digits.startIndex, offsetBy: pointPosition)
            result = String(digits[..<split]) + "." + String(digits[split...])
        } else if pointPosition > -6, pointPosition <= 0 {
            result = "0." + String(repeating: "0", count: -pointPosition) + digits
        } else {
            let exponentValue = pointPosition - 1
            let first = String(digits.prefix(1))
            let rest = String(digits.dropFirst())
            result = first + (rest.isEmpty ? "" : "." + rest) + "e" + (exponentValue >= 0 ? "+" : "-") + String(abs(exponentValue))
        }
        return negative ? "-" + result : result
    }
}

// MARK: - Parser

private struct JSON5Parser {
    let bytes: [UInt8]
    let allowJSON5: Bool
    var index = 0
    var keyOrder = ConfigKeyOrder()
    private var depth = 0
    private static let maxDepth = 512

    init(bytes: [UInt8], allowJSON5: Bool) {
        self.bytes = bytes
        self.allowJSON5 = allowJSON5
        // Skip a UTF-8 byte order mark.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            self.index = 3
        }
    }

    mutating func parseDocument() throws -> AnyCodable {
        try self.skipTrivia()
        guard self.index < self.bytes.count else {
            throw self.error("Unexpected end of input")
        }
        let value = try self.parseValue(path: [])
        try self.skipTrivia()
        guard self.index == self.bytes.count else {
            throw self.error("Unexpected trailing content")
        }
        return value
    }

    private mutating func parseValue(path: [String]) throws -> AnyCodable {
        try self.skipTrivia()
        guard let byte = self.peek() else {
            throw self.error("Unexpected end of input")
        }
        switch byte {
        case UInt8(ascii: "{"):
            return try self.parseObject(path: path)
        case UInt8(ascii: "["):
            return try self.parseArray(path: path)
        case UInt8(ascii: "\""):
            return AnyCodable(.string(try self.parseString(quote: byte)))
        case UInt8(ascii: "'") where self.allowJSON5:
            return AnyCodable(.string(try self.parseString(quote: byte)))
        case UInt8(ascii: "t"):
            try self.expectKeyword("true")
            return AnyCodable(.bool(true))
        case UInt8(ascii: "f"):
            try self.expectKeyword("false")
            return AnyCodable(.bool(false))
        case UInt8(ascii: "n"):
            try self.expectKeyword("null")
            return AnyCodable(.null)
        default:
            return try self.parseNumber()
        }
    }

    private mutating func parseObject(path: [String]) throws -> AnyCodable {
        try self.enter()
        defer { self.depth -= 1 }
        self.index += 1
        var object: [String: AnyCodable] = [:]
        var order: [String] = []
        try self.skipTrivia()
        if self.peek() == UInt8(ascii: "}") {
            self.index += 1
            self.keyOrder.set([], at: path)
            return AnyCodable(.object(object))
        }
        while true {
            try self.skipTrivia()
            let key = try self.parseKey()
            try self.skipTrivia()
            guard self.peek() == UInt8(ascii: ":") else {
                throw self.error("Expected ':' after object key")
            }
            self.index += 1
            let value = try self.parseValue(path: path + [key])
            if object[key] == nil {
                order.append(key)
            }
            object[key] = value
            try self.skipTrivia()
            guard let next = self.peek() else {
                throw self.error("Unterminated object")
            }
            if next == UInt8(ascii: ",") {
                self.index += 1
                try self.skipTrivia()
                if self.peek() == UInt8(ascii: "}") {
                    guard self.allowJSON5 else {
                        throw self.error("Trailing comma is not allowed in strict JSON")
                    }
                    self.index += 1
                    break
                }
                continue
            }
            if next == UInt8(ascii: "}") {
                self.index += 1
                break
            }
            throw self.error("Expected ',' or '}' in object")
        }
        self.keyOrder.set(order, at: path)
        return AnyCodable(.object(object))
    }

    private mutating func parseArray(path: [String]) throws -> AnyCodable {
        try self.enter()
        defer { self.depth -= 1 }
        self.index += 1
        var array: [AnyCodable] = []
        try self.skipTrivia()
        if self.peek() == UInt8(ascii: "]") {
            self.index += 1
            return AnyCodable(.array(array))
        }
        while true {
            array.append(try self.parseValue(path: path + [String(array.count)]))
            try self.skipTrivia()
            guard let next = self.peek() else {
                throw self.error("Unterminated array")
            }
            if next == UInt8(ascii: ",") {
                self.index += 1
                try self.skipTrivia()
                if self.peek() == UInt8(ascii: "]") {
                    guard self.allowJSON5 else {
                        throw self.error("Trailing comma is not allowed in strict JSON")
                    }
                    self.index += 1
                    break
                }
                continue
            }
            if next == UInt8(ascii: "]") {
                self.index += 1
                break
            }
            throw self.error("Expected ',' or ']' in array")
        }
        return AnyCodable(.array(array))
    }

    private mutating func parseKey() throws -> String {
        guard let byte = self.peek() else {
            throw self.error("Unexpected end of input in object")
        }
        if byte == UInt8(ascii: "\"") || (self.allowJSON5 && byte == UInt8(ascii: "'")) {
            return try self.parseString(quote: byte)
        }
        guard self.allowJSON5 else {
            throw self.error("Object keys must be double-quoted strings")
        }
        let start = self.index
        while let current = self.peek(), Self.isIdentifierByte(current, first: self.index == start) {
            self.index += 1
        }
        guard self.index > start else {
            throw self.error("Invalid object key")
        }
        guard let key = String(bytes: self.bytes[start..<self.index], encoding: .utf8) else {
            throw self.error("Invalid UTF-8 in object key")
        }
        return key
    }

    private static func isIdentifierByte(_ byte: UInt8, first: Bool) -> Bool {
        if byte >= 0x80 {
            return true
        }
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "$"), UInt8(ascii: "_"):
            return true
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return !first
        default:
            return false
        }
    }

    private mutating func parseString(quote: UInt8) throws -> String {
        self.index += 1
        var buffer: [UInt8] = []
        while true {
            guard let byte = self.peek() else {
                throw self.error("Unterminated string")
            }
            if byte == quote {
                self.index += 1
                break
            }
            if byte == UInt8(ascii: "\\") {
                self.index += 1
                try self.parseEscape(into: &buffer)
                continue
            }
            if byte == 0x0A || byte == 0x0D {
                throw self.error("Unescaped line break in string")
            }
            if byte < 0x20, !self.allowJSON5 {
                throw self.error("Unescaped control character in string")
            }
            buffer.append(byte)
            self.index += 1
        }
        guard let string = String(bytes: buffer, encoding: .utf8) else {
            throw self.error("Invalid UTF-8 in string")
        }
        return string
    }

    private mutating func parseEscape(into buffer: inout [UInt8]) throws {
        guard let byte = self.peek() else {
            throw self.error("Unterminated escape sequence")
        }
        self.index += 1
        switch byte {
        case UInt8(ascii: "\""):
            buffer.append(byte)
        case UInt8(ascii: "\\"):
            buffer.append(byte)
        case UInt8(ascii: "/"):
            buffer.append(byte)
        case UInt8(ascii: "b"):
            buffer.append(0x08)
        case UInt8(ascii: "f"):
            buffer.append(0x0C)
        case UInt8(ascii: "n"):
            buffer.append(0x0A)
        case UInt8(ascii: "r"):
            buffer.append(0x0D)
        case UInt8(ascii: "t"):
            buffer.append(0x09)
        case UInt8(ascii: "u"):
            var scalarValue = try self.readHex(count: 4)
            if (0xD800...0xDBFF).contains(scalarValue),
               self.peek() == UInt8(ascii: "\\"),
               self.index + 1 < self.bytes.count,
               self.bytes[self.index + 1] == UInt8(ascii: "u")
            {
                let saved = self.index
                self.index += 2
                let low = try self.readHex(count: 4)
                if (0xDC00...0xDFFF).contains(low) {
                    scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                } else {
                    self.index = saved
                }
            }
            let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
            buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
        default:
            guard self.allowJSON5 else {
                throw self.error("Invalid escape sequence")
            }
            try self.parseJSON5Escape(byte, into: &buffer)
        }
    }

    private mutating func parseJSON5Escape(_ byte: UInt8, into buffer: inout [UInt8]) throws {
        switch byte {
        case UInt8(ascii: "'"):
            buffer.append(byte)
        case UInt8(ascii: "v"):
            buffer.append(0x0B)
        case UInt8(ascii: "0"):
            if let next = self.peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(next) {
                throw self.error("Octal escapes are not allowed")
            }
            buffer.append(0x00)
        case UInt8(ascii: "x"):
            let value = try self.readHex(count: 2)
            let scalar = Unicode.Scalar(value) ?? "\u{FFFD}"
            buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
        case 0x0A:
            // Line continuation.
            break
        case 0x0D:
            if self.peek() == 0x0A {
                self.index += 1
            }
        case 0xE2 where self.index + 1 < self.bytes.count
            && self.bytes[self.index] == 0x80
            && (self.bytes[self.index + 1] == 0xA8 || self.bytes[self.index + 1] == 0xA9):
            // U+2028 / U+2029 line continuation.
            self.index += 2
        case UInt8(ascii: "1")...UInt8(ascii: "9"):
            throw self.error("Invalid escape sequence")
        default:
            // Non-escape character: the character itself (including multi-byte UTF-8 sequences).
            buffer.append(byte)
        }
    }

    private mutating func readHex(count: Int) throws -> UInt32 {
        guard self.index + count <= self.bytes.count else {
            throw self.error("Truncated hexadecimal escape")
        }
        var value: UInt32 = 0
        for _ in 0..<count {
            guard let digit = Self.hexValue(self.bytes[self.index]) else {
                throw self.error("Invalid hexadecimal escape")
            }
            value = value * 16 + UInt32(digit)
            self.index += 1
        }
        return value
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }

    private mutating func parseNumber() throws -> AnyCodable {
        let start = self.index
        var negative = false
        if let sign = self.peek(), sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") {
            guard sign == UInt8(ascii: "-") || self.allowJSON5 else {
                throw self.error("Unexpected '+'")
            }
            negative = sign == UInt8(ascii: "-")
            self.index += 1
        }
        if self.allowJSON5, self.matches("Infinity") {
            self.index += 8
            return AnyCodable(.double(negative ? -.infinity : .infinity))
        }
        if self.allowJSON5, self.matches("NaN") {
            self.index += 3
            return AnyCodable(.double(.nan))
        }
        if self.allowJSON5, self.peek() == UInt8(ascii: "0"),
           self.index + 1 < self.bytes.count,
           self.bytes[self.index + 1] == UInt8(ascii: "x") || self.bytes[self.index + 1] == UInt8(ascii: "X")
        {
            self.index += 2
            let digitsStart = self.index
            while let byte = self.peek(), Self.hexValue(byte) != nil {
                self.index += 1
            }
            guard self.index > digitsStart,
                  let text = String(bytes: self.bytes[digitsStart..<self.index], encoding: .ascii)
            else {
                throw self.error("Invalid hexadecimal number")
            }
            if let value = Int64(text, radix: 16) {
                return Self.integerValue(negative ? -value : value)
            }
            let magnitude = text.reduce(0.0) { $0 * 16 + Double(Self.hexValue($1.asciiValue ?? 0) ?? 0) }
            return AnyCodable(.double(negative ? -magnitude : magnitude))
        }
        var isInteger = true
        let integerStart = self.index
        let integerDigits = self.skipDigits()
        if integerDigits > 1, self.bytes[integerStart] == UInt8(ascii: "0") {
            throw self.error("Leading zeros are not allowed")
        }
        if self.peek() == UInt8(ascii: ".") {
            isInteger = false
            self.index += 1
            let fractionDigits = self.skipDigits()
            if self.allowJSON5 {
                guard integerDigits > 0 || fractionDigits > 0 else {
                    throw self.error("Invalid number")
                }
            } else {
                guard integerDigits > 0, fractionDigits > 0 else {
                    throw self.error("Invalid number")
                }
            }
        } else if integerDigits == 0 {
            throw self.error("Unexpected character")
        }
        if let byte = self.peek(), byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
            isInteger = false
            self.index += 1
            if let sign = self.peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                self.index += 1
            }
            guard self.skipDigits() > 0 else {
                throw self.error("Expected exponent digits")
            }
        }
        guard var text = String(bytes: self.bytes[start..<self.index], encoding: .ascii) else {
            throw self.error("Invalid number")
        }
        if text.hasPrefix("+") {
            text.removeFirst()
        }
        if isInteger, let value = Int64(text) {
            return Self.integerValue(value)
        }
        var normalized = text
        if normalized.hasSuffix(".") {
            normalized += "0"
        }
        if normalized.hasPrefix(".") {
            normalized = "0" + normalized
        } else if normalized.hasPrefix("-.") {
            normalized = "-0" + normalized.dropFirst()
        }
        guard let double = Double(normalized) else {
            throw self.error("Invalid number")
        }
        if double.rounded() == double, let exact = Int(exactly: double) {
            return AnyCodable(.int(exact))
        }
        return AnyCodable(.double(double))
    }

    private mutating func skipDigits() -> Int {
        let start = self.index
        while let byte = self.peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
            self.index += 1
        }
        return self.index - start
    }

    private static func integerValue(_ value: Int64) -> AnyCodable {
        if let int = Int(exactly: value) {
            return AnyCodable(.int(int))
        }
        return AnyCodable(.double(Double(value)))
    }

    private mutating func expectKeyword(_ keyword: String) throws {
        guard self.matches(keyword) else {
            throw self.error("Unexpected token")
        }
        self.index += keyword.utf8.count
    }

    private func matches(_ keyword: String) -> Bool {
        let utf8 = Array(keyword.utf8)
        guard self.index + utf8.count <= self.bytes.count else {
            return false
        }
        return Array(self.bytes[self.index..<(self.index + utf8.count)]) == utf8
    }

    private mutating func skipTrivia() throws {
        while self.index < self.bytes.count {
            let byte = self.bytes[self.index]
            switch byte {
            case 0x20, 0x0A, 0x0D, 0x09:
                self.index += 1
            case 0x0B where self.allowJSON5:
                self.index += 1
            case 0x0C where self.allowJSON5:
                self.index += 1
            case 0xC2 where self.allowJSON5 && self.index + 1 < self.bytes.count && self.bytes[self.index + 1] == 0xA0:
                self.index += 2
            case 0xE2 where self.allowJSON5 && self.index + 2 < self.bytes.count
                && self.bytes[self.index + 1] == 0x80
                && (self.bytes[self.index + 2] == 0xA8 || self.bytes[self.index + 2] == 0xA9):
                self.index += 3
            case 0xEF where self.allowJSON5 && self.index + 2 < self.bytes.count
                && self.bytes[self.index + 1] == 0xBB && self.bytes[self.index + 2] == 0xBF:
                self.index += 3
            case UInt8(ascii: "/") where self.allowJSON5:
                guard self.index + 1 < self.bytes.count else {
                    throw self.error("Unexpected '/'")
                }
                let next = self.bytes[self.index + 1]
                if next == UInt8(ascii: "/") {
                    self.index += 2
                    while self.index < self.bytes.count, self.bytes[self.index] != 0x0A, self.bytes[self.index] != 0x0D {
                        self.index += 1
                    }
                } else if next == UInt8(ascii: "*") {
                    self.index += 2
                    var closed = false
                    while self.index + 1 < self.bytes.count {
                        if self.bytes[self.index] == UInt8(ascii: "*"), self.bytes[self.index + 1] == UInt8(ascii: "/") {
                            self.index += 2
                            closed = true
                            break
                        }
                        self.index += 1
                    }
                    guard closed else {
                        throw self.error("Unterminated block comment")
                    }
                } else {
                    throw self.error("Unexpected '/'")
                }
            default:
                return
            }
        }
    }

    private mutating func enter() throws {
        self.depth += 1
        guard self.depth <= Self.maxDepth else {
            throw self.error("Nesting is too deep")
        }
    }

    private func peek() -> UInt8? {
        self.index < self.bytes.count ? self.bytes[self.index] : nil
    }

    private func error(_ message: String) -> OpenClawJSON5.ParseError {
        var line = 1
        var column = 1
        var position = 0
        while position < min(self.index, self.bytes.count) {
            if self.bytes[position] == 0x0A {
                line += 1
                column = 1
            } else {
                column += 1
            }
            position += 1
        }
        return OpenClawJSON5.ParseError(message: message, line: line, column: column)
    }
}

// MARK: - Writer

private struct JSONTextWriter {
    let keyOrder: ConfigKeyOrder?
    let prettyPrinted: Bool
    var output = ""

    init(keyOrder: ConfigKeyOrder?, prettyPrinted: Bool) {
        self.keyOrder = keyOrder
        self.prettyPrinted = prettyPrinted
    }

    mutating func write(_ value: AnyCodable, path: [String], indent: Int) {
        switch value.value {
        case .null:
            self.output += "null"
        case .bool(let flag):
            self.output += flag ? "true" : "false"
        case .int(let int):
            self.output += String(int)
        case .double(let double):
            self.output += OpenClawJSON5.formatNumber(double)
        case .string(let string):
            Self.writeString(string, into: &self.output)
        case .array(let array):
            guard !array.isEmpty else {
                self.output += "[]"
                return
            }
            self.output += "["
            for (index, element) in array.enumerated() {
                if index > 0 {
                    self.output += ","
                }
                self.newline(indent: indent + 1)
                self.write(element, path: path + [String(index)], indent: indent + 1)
            }
            self.newline(indent: indent)
            self.output += "]"
        case .object(let object):
            guard !object.isEmpty else {
                self.output += "{}"
                return
            }
            self.output += "{"
            for (index, key) in self.orderedKeys(object, path: path).enumerated() {
                if index > 0 {
                    self.output += ","
                }
                self.newline(indent: indent + 1)
                Self.writeString(key, into: &self.output)
                self.output += self.prettyPrinted ? ": " : ":"
                self.write(object[key] ?? AnyCodable(.null), path: path + [key], indent: indent + 1)
            }
            self.newline(indent: indent)
            self.output += "}"
        }
    }

    private func orderedKeys(_ object: [String: AnyCodable], path: [String]) -> [String] {
        guard let recorded = self.keyOrder?.keys(at: path) else {
            return object.keys.sorted()
        }
        return ConfigOrderHint(recorded).ordered(object.keys)
    }

    private mutating func newline(indent: Int) {
        guard self.prettyPrinted else {
            return
        }
        self.output += "\n" + String(repeating: "  ", count: indent)
    }

    static func writeString(_ string: String, into output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\u{08}":
                output += "\\b"
            case "\u{0C}":
                output += "\\f"
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
