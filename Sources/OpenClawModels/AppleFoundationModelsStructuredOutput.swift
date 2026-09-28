import Foundation
import OpenClawProtocol

// Host-side validation of Apple Foundation Models structured output.
//
// Port of upstream `extensions/apple-fm/stream.ts`: Foundation Models cannot enforce string length
// or pattern constraints, so the raw response text is re-validated against the caller's original
// JSON Schema before it is published. Numbers that JavaScript (and therefore upstream) cannot
// represent exactly -- non-finite values and integers beyond +/-(2^53 - 1) -- are rejected, and
// malformed JSON is reported without echoing the model text.

/// Validates structured output text against a caller-supplied JSON Schema (upstream parity).
public enum FoundationModelsStructuredOutputValidator {
    /// Largest integer JavaScript represents exactly (`Number.MAX_SAFE_INTEGER`).
    static let maxSafeInteger: Double = 9_007_199_254_740_991
    static let maxSafeIntegerDigits = "9007199254740991"

    /// Validates structured output text.
    ///
    /// The text itself is never modified; callers publish it unchanged when validation passes.
    /// - Parameters:
    ///   - text: Raw model output (`GeneratedContent.jsonString`).
    ///   - schema: The caller's original JSON Schema.
    /// - Throws: ``FoundationModelsError`` with code ``FoundationModelsError/Code/invalidStructuredOutput``:
    ///   unsafe numbers, malformed JSON, or schema violations listing the failing paths.
    public static func validate(_ text: String, against schema: [String: AnyCodable]) throws {
        if Self.containsUnsafeIntegerLiteral(text) {
            throw FoundationModelsError.unsafeNumber
        }
        var parser = FoundationModelsJSONParser(text)
        let value: FoundationModelsJSONValue
        do {
            value = try parser.parseDocument()
        } catch {
            throw FoundationModelsError.malformedJSON
        }
        if value.containsUnsafeNumber {
            throw FoundationModelsError.unsafeNumber
        }
        var errors: [String] = []
        Self.validate(value, schema: schema, path: "<root>", errors: &errors)
        if !errors.isEmpty {
            var seen = Set<String>()
            throw FoundationModelsError.schemaViolation(paths: errors.filter { seen.insert($0).inserted })
        }
    }

    /// Whether the text holds an integer literal (outside JSON strings) beyond `Number.MAX_SAFE_INTEGER`
    /// (upstream `quoteUnsafeIntegerLiterals(text) !== text`).
    static func containsUnsafeIntegerLiteral(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var run = 0
        var hasLongDigitRun = false
        for byte in bytes {
            run = Self.isDigit(byte) ? run + 1 : 0
            if run >= 16 {
                hasLongDigitRun = true
                break
            }
        }
        guard hasLongDigitRun else { return false }
        var index = 0
        var inString = false
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                index += 1
                continue
            }
            if byte == UInt8(ascii: "\"") {
                inString = true
                index += 1
                continue
            }
            if byte == UInt8(ascii: "-") || Self.isDigit(byte), let token = Self.numberToken(bytes, start: index) {
                if token.isInteger, Self.isUnsafeIntegerLiteral(bytes[index..<token.end]) {
                    return true
                }
                index = token.end
                continue
            }
            index += 1
        }
        return false
    }

    // MARK: Schema validation (JSON Schema subset used by apple-fm tool and response schemas)

    static func validate(_ value: FoundationModelsJSONValue, schema: [String: AnyCodable], path: String, errors: inout [String]) {
        if let type = schema["type"] {
            let names = type.arrayValue?.compactMap(\.stringValue) ?? type.stringValue.map { [$0] } ?? []
            if !names.isEmpty, !names.contains(where: { value.matches(type: $0) }) {
                errors.append(path)
                return
            }
        }
        if let constant = schema["const"], !value.equals(constant) {
            errors.append(path)
        }
        if let choices = schema["enum"]?.arrayValue, !choices.contains(where: { value.equals($0) }) {
            errors.append(path)
        }
        if let options = schema["anyOf"]?.arrayValue?.compactMap(\.dictionaryValue), !options.isEmpty {
            let matched = options.contains { option in
                var branch: [String] = []
                Self.validate(value, schema: option, path: path, errors: &branch)
                return branch.isEmpty
            }
            if !matched {
                errors.append(path)
            }
        }
        if let options = schema["oneOf"]?.arrayValue?.compactMap(\.dictionaryValue), !options.isEmpty {
            let matches = options.filter { option in
                var branch: [String] = []
                Self.validate(value, schema: option, path: path, errors: &branch)
                return branch.isEmpty
            }.count
            if matches != 1 {
                errors.append(path)
            }
        }
        if let all = schema["allOf"]?.arrayValue?.compactMap(\.dictionaryValue) {
            for option in all {
                Self.validate(value, schema: option, path: path, errors: &errors)
            }
        }
        switch value {
        case .object(let object, _):
            Self.validateObject(object, schema: schema, path: path, errors: &errors)
        case .array(let items):
            Self.validateArray(items, schema: schema, path: path, errors: &errors)
        case .string(let string):
            Self.validateString(string, schema: schema, path: path, errors: &errors)
        case .number(let number, _):
            Self.validateNumber(number, schema: schema, path: path, errors: &errors)
        case .null, .bool:
            break
        }
    }

    private static func validateObject(
        _ object: [String: FoundationModelsJSONValue],
        schema: [String: AnyCodable],
        path: String,
        errors: inout [String]
    ) {
        let properties = schema["properties"]?.dictionaryValue ?? [:]
        for key in object.keys.sorted() {
            guard let child = object[key] else { continue }
            if let propertySchema = properties[key]?.dictionaryValue {
                Self.validate(child, schema: propertySchema, path: Self.append(path, key), errors: &errors)
            } else if let additional = schema["additionalProperties"] {
                if additional.boolValue == false {
                    errors.append(path)
                } else if let additionalSchema = additional.dictionaryValue {
                    Self.validate(child, schema: additionalSchema, path: Self.append(path, key), errors: &errors)
                }
            }
        }
        for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
            errors.append(Self.append(path, key))
        }
    }

    private static func validateArray(
        _ items: [FoundationModelsJSONValue],
        schema: [String: AnyCodable],
        path: String,
        errors: inout [String]
    ) {
        if let minimum = schema["minItems"]?.intValue, items.count < minimum {
            errors.append(path)
        }
        if let maximum = schema["maxItems"]?.intValue, items.count > maximum {
            errors.append(path)
        }
        if let itemSchema = schema["items"]?.dictionaryValue {
            for (index, item) in items.enumerated() {
                Self.validate(item, schema: itemSchema, path: Self.append(path, String(index)), errors: &errors)
            }
        }
    }

    private static func validateString(_ string: String, schema: [String: AnyCodable], path: String, errors: inout [String]) {
        let length = string.unicodeScalars.count
        if let minimum = schema["minLength"]?.intValue, length < minimum {
            errors.append(path)
        }
        if let maximum = schema["maxLength"]?.intValue, length > maximum {
            errors.append(path)
        }
        if let pattern = schema["pattern"]?.stringValue {
            // Invalid patterns fail closed, like a schema compile error would upstream.
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                errors.append(path)
                return
            }
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            if regex.firstMatch(in: string, options: [], range: range) == nil {
                errors.append(path)
            }
        }
    }

    private static func validateNumber(_ number: Double, schema: [String: AnyCodable], path: String, errors: inout [String]) {
        if let minimum = schema["minimum"]?.doubleValue, number < minimum {
            errors.append(path)
        }
        if let maximum = schema["maximum"]?.doubleValue, number > maximum {
            errors.append(path)
        }
        if let minimum = schema["exclusiveMinimum"]?.doubleValue, number <= minimum {
            errors.append(path)
        }
        if let maximum = schema["exclusiveMaximum"]?.doubleValue, number >= maximum {
            errors.append(path)
        }
        if let divisor = schema["multipleOf"]?.doubleValue, divisor > 0 {
            let quotient = number / divisor
            if quotient.rounded() != quotient {
                errors.append(path)
            }
        }
    }

    private static func append(_ path: String, _ segment: String) -> String {
        path == "<root>" ? segment : "\(path).\(segment)"
    }

    // MARK: Number tokens

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    /// Upstream `parseJsonNumberToken`: returns the token end and whether it is an integer literal.
    static func numberToken(_ bytes: [UInt8], start: Int) -> (end: Int, isInteger: Bool)? {
        var index = start
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        guard index < bytes.count else { return nil }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if Self.isDigit(bytes[index]) {
            while index < bytes.count, Self.isDigit(bytes[index]) {
                index += 1
            }
        } else {
            return nil
        }
        var isInteger = true
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            guard index < bytes.count, Self.isDigit(bytes[index]) else { return nil }
            while index < bytes.count, Self.isDigit(bytes[index]) {
                index += 1
            }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count, Self.isDigit(bytes[index]) else { return nil }
            while index < bytes.count, Self.isDigit(bytes[index]) {
                index += 1
            }
        }
        return (index, isInteger)
    }

    static func isUnsafeIntegerLiteral(_ token: ArraySlice<UInt8>) -> Bool {
        let digits = token.first == UInt8(ascii: "-") ? token.dropFirst() : token
        let limit = Array(Self.maxSafeIntegerDigits.utf8)
        if digits.count != limit.count {
            return digits.count > limit.count
        }
        return digits.lexicographicallyPrecedes(limit) == false && !digits.elementsEqual(limit)
    }
}

// MARK: - Minimal strict JSON value and parser

/// JSON value used for structured-output validation; numbers keep integer-literal information.
indirect enum FoundationModelsJSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double, isIntegerLiteral: Bool)
    case string(String)
    case array([FoundationModelsJSONValue])
    case object([String: FoundationModelsJSONValue], keys: [String])

    /// JSON Schema `type` check (`integer` accepts any integral number, as JavaScript does).
    func matches(type: String) -> Bool {
        switch (type, self) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object):
            return true
        case ("number", .number):
            return true
        case ("integer", .number(let value, _)):
            return value.isFinite && value.rounded() == value
        default:
            return false
        }
    }

    /// Whether the tree holds a number JavaScript cannot represent exactly (non-finite, or an
    /// integral value beyond `Number.MAX_SAFE_INTEGER`).
    var containsUnsafeNumber: Bool {
        switch self {
        case .number(let value, _):
            if !value.isFinite { return true }
            return value.rounded() == value && Swift.abs(value) > FoundationModelsStructuredOutputValidator.maxSafeInteger
        case .array(let items):
            return items.contains { $0.containsUnsafeNumber }
        case .object(let object, _):
            return object.values.contains { $0.containsUnsafeNumber }
        case .null, .bool, .string:
            return false
        }
    }

    /// Deep equality with a schema literal (`const`/`enum`); numbers compare by value.
    func equals(_ literal: AnyCodable) -> Bool {
        switch (self, literal.value) {
        case (.null, .null):
            return true
        case (.bool(let lhs), .bool(let rhs)):
            return lhs == rhs
        case (.string(let lhs), .string(let rhs)):
            return lhs == rhs
        case (.number(let lhs, _), .int(let rhs)):
            return lhs == Double(rhs)
        case (.number(let lhs, _), .double(let rhs)):
            return lhs == rhs
        case (.array(let lhs), .array(let rhs)):
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.equals($1) }
        case (.object(let lhs, _), .object(let rhs)):
            return lhs.count == rhs.count && lhs.allSatisfy { key, value in rhs[key].map { value.equals($0) } ?? false }
        default:
            return false
        }
    }
}

/// Strict RFC 8259 parser (no trailing content, no comments, control characters rejected).
struct FoundationModelsJSONParser {
    struct Failure: Error {}

    private let bytes: [UInt8]
    private var index = 0
    private static let maxDepth = 512

    init(_ text: String) {
        self.bytes = Array(text.utf8)
    }

    mutating func parseDocument() throws -> FoundationModelsJSONValue {
        self.skipWhitespace()
        let value = try self.parseValue(depth: 0)
        self.skipWhitespace()
        guard self.index == self.bytes.count else { throw Failure() }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> FoundationModelsJSONValue {
        guard depth < Self.maxDepth, self.index < self.bytes.count else { throw Failure() }
        switch self.bytes[self.index] {
        case UInt8(ascii: "{"):
            return try self.parseObject(depth: depth)
        case UInt8(ascii: "["):
            return try self.parseArray(depth: depth)
        case UInt8(ascii: "\""):
            return .string(try self.parseString())
        case UInt8(ascii: "t"):
            try self.expect("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try self.expect("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try self.expect("null")
            return .null
        default:
            return try self.parseNumber()
        }
    }

    private mutating func parseObject(depth: Int) throws -> FoundationModelsJSONValue {
        self.index += 1
        var object: [String: FoundationModelsJSONValue] = [:]
        var keys: [String] = []
        self.skipWhitespace()
        if self.peek(UInt8(ascii: "}")) {
            self.index += 1
            return .object(object, keys: keys)
        }
        while true {
            self.skipWhitespace()
            guard self.peek(UInt8(ascii: "\"")) else { throw Failure() }
            let key = try self.parseString()
            self.skipWhitespace()
            guard self.peek(UInt8(ascii: ":")) else { throw Failure() }
            self.index += 1
            self.skipWhitespace()
            let value = try self.parseValue(depth: depth + 1)
            if object.updateValue(value, forKey: key) == nil {
                keys.append(key)
            }
            self.skipWhitespace()
            if self.peek(UInt8(ascii: ",")) {
                self.index += 1
                continue
            }
            guard self.peek(UInt8(ascii: "}")) else { throw Failure() }
            self.index += 1
            return .object(object, keys: keys)
        }
    }

    private mutating func parseArray(depth: Int) throws -> FoundationModelsJSONValue {
        self.index += 1
        var items: [FoundationModelsJSONValue] = []
        self.skipWhitespace()
        if self.peek(UInt8(ascii: "]")) {
            self.index += 1
            return .array(items)
        }
        while true {
            self.skipWhitespace()
            items.append(try self.parseValue(depth: depth + 1))
            self.skipWhitespace()
            if self.peek(UInt8(ascii: ",")) {
                self.index += 1
                continue
            }
            guard self.peek(UInt8(ascii: "]")) else { throw Failure() }
            self.index += 1
            return .array(items)
        }
    }

    private mutating func parseString() throws -> String {
        self.index += 1
        var scalars = String.UnicodeScalarView()
        var pendingBytes: [UInt8] = []
        func flush() {
            if !pendingBytes.isEmpty {
                scalars.append(contentsOf: String(decoding: pendingBytes, as: UTF8.self).unicodeScalars)
                pendingBytes.removeAll(keepingCapacity: true)
            }
        }
        while self.index < self.bytes.count {
            let byte = self.bytes[self.index]
            switch byte {
            case UInt8(ascii: "\""):
                self.index += 1
                flush()
                return String(scalars)
            case UInt8(ascii: "\\"):
                flush()
                self.index += 1
                guard self.index < self.bytes.count else { throw Failure() }
                let escape = self.bytes[self.index]
                self.index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    scalars.append(try self.parseUnicodeEscape())
                default:
                    throw Failure()
                }
            default:
                guard byte >= 0x20 else { throw Failure() }
                pendingBytes.append(byte)
                self.index += 1
            }
        }
        throw Failure()
    }

    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let high = try self.parseHex4()
        if (0xD800...0xDBFF).contains(high) {
            guard self.index + 1 < self.bytes.count,
                  self.bytes[self.index] == UInt8(ascii: "\\"),
                  self.bytes[self.index + 1] == UInt8(ascii: "u")
            else {
                return "\u{FFFD}"
            }
            self.index += 2
            let low = try self.parseHex4()
            guard (0xDC00...0xDFFF).contains(low),
                  let scalar = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
            else {
                return "\u{FFFD}"
            }
            return scalar
        }
        return Unicode.Scalar(high) ?? "\u{FFFD}"
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard self.index + 4 <= self.bytes.count else { throw Failure() }
        var value: UInt32 = 0
        for byte in self.bytes[self.index..<(self.index + 4)] {
            value <<= 4
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value |= UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): value |= UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): value |= UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw Failure()
            }
        }
        self.index += 4
        return value
    }

    private mutating func parseNumber() throws -> FoundationModelsJSONValue {
        guard let token = FoundationModelsStructuredOutputValidator.numberToken(self.bytes, start: self.index) else {
            throw Failure()
        }
        let literal = String(decoding: self.bytes[self.index..<token.end], as: UTF8.self)
        self.index = token.end
        // Swift's Double parser follows IEEE rounding like JavaScript's; out-of-range literals become infinity.
        let value = Double(literal) ?? (literal.hasPrefix("-") ? -Double.infinity : Double.infinity)
        return .number(value, isIntegerLiteral: token.isInteger)
    }

    private mutating func expect(_ word: String) throws {
        let expected = Array(word.utf8)
        guard self.index + expected.count <= self.bytes.count,
              Array(self.bytes[self.index..<(self.index + expected.count)]) == expected
        else {
            throw Failure()
        }
        self.index += expected.count
    }

    private func peek(_ byte: UInt8) -> Bool {
        self.index < self.bytes.count && self.bytes[self.index] == byte
    }

    private mutating func skipWhitespace() {
        while self.index < self.bytes.count {
            switch self.bytes[self.index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                self.index += 1
            default:
                return
            }
        }
    }
}
