import Foundation
import OpenClawProtocol

// JSON Schema -> Foundation Models generation schema conversion, platform-neutral half.
//
// Port of upstream `extensions/apple-fm/assets/AppleFoundationModels.swift` `dynamicSchema(_:name:)`
// (MIT): the same keyword allowlist, the same rules and the same error messages. Parsing produces a
// ``FoundationModelsSchemaNode`` tree that is validated here (Linux included); the Apple-only
// `AppleFoundationModelsDynamicSchema.swift` turns the tree into a `DynamicGenerationSchema`.
//
// Foundation Models has no string length guides and rejects regex guides, so `minLength`,
// `maxLength` and `pattern` are validated but not emitted. Callers keep those constraints by
// re-validating model output against the original schema (``FoundationModelsStructuredOutputValidator``).

/// Framework-neutral Foundation Models generation schema converted from a JSON Schema.
public indirect enum FoundationModelsSchemaNode: Sendable, Equatable {
    /// A choice between alternatives (`anyOf`, or a `type` array), named `<name>`.
    case anyOf(name: String, options: [FoundationModelsSchemaNode])
    /// A choice between string literals (`enum` or string `const`), named `<name>`.
    case choices(name: String, values: [String])
    /// An object with properties sorted by key.
    case object(name: String, properties: [FoundationModelsSchemaProperty])
    /// An array with optional element-count bounds.
    case array(item: FoundationModelsSchemaNode, minimumElements: Int?, maximumElements: Int?)
    /// An integer with optional inclusive bounds.
    case integer(minimum: Int?, maximum: Int?)
    /// A number with optional inclusive bounds.
    case number(minimum: Double?, maximum: Double?)
    /// A Boolean.
    case boolean
    /// JSON `null` (emitted as `DynamicGenerationSchema.null`, OS 26.4+).
    case null
    /// A string (length and pattern constraints are validated but never emitted).
    case string
}

/// Object property of a ``FoundationModelsSchemaNode``.
public struct FoundationModelsSchemaProperty: Sendable, Equatable {
    /// Property key.
    public var name: String
    /// Property description from the field schema.
    public var description: String?
    /// Property value schema.
    public var schema: FoundationModelsSchemaNode
    /// Whether the key is absent from the object's `required` list.
    public var isOptional: Bool

    /// Creates a property.
    /// - Parameters:
    ///   - name: Property key.
    ///   - description: Property description.
    ///   - schema: Value schema.
    ///   - isOptional: Whether the property may be omitted.
    public init(name: String, description: String? = nil, schema: FoundationModelsSchemaNode, isOptional: Bool) {
        self.name = name
        self.description = description
        self.schema = schema
        self.isOptional = isOptional
    }
}

/// Converts JSON Schemas into Foundation Models generation schemas using upstream apple-fm rules.
public enum FoundationModelsSchemaConverter {
    /// JSON Schema keywords the converter accepts (upstream allowlist). Any other keyword throws.
    public static let supportedKeywords: Set<String> = [
        "type",
        "title",
        "description",
        "properties",
        "required",
        "items",
        "enum",
        "const",
        "anyOf",
        "default",
        "minLength",
        "maxLength",
        "minimum",
        "maximum",
        "minItems",
        "maxItems",
        "pattern",
        "additionalProperties",
        "$schema",
        "x-order",
    ]

    /// Keywords that may accompany `anyOf`.
    static let anyOfAnnotations: Set<String> = ["anyOf", "title", "description", "default", "$schema"]

    /// Root schema name used for structured output (upstream `"Response"`).
    public static let responseSchemaName = "Response"

    /// Parses and validates a JSON Schema.
    /// - Parameters:
    ///   - schema: JSON Schema object.
    ///   - name: Schema name (tool name, or ``responseSchemaName`` for structured output).
    /// - Returns: The converted schema tree.
    /// - Throws: ``FoundationModelsError`` with code ``FoundationModelsError/Code/invalidSchema`` and
    ///   the upstream message (for example `Unsupported schema keyword oneOf in search`).
    public static func parse(_ schema: [String: AnyCodable], name: String) throws -> FoundationModelsSchemaNode {
        if let key = schema.keys.sorted().first(where: { !Self.supportedKeywords.contains($0) }) {
            throw FoundationModelsError.invalidSchema("Unsupported schema keyword \(key) in \(name)")
        }
        if let alternatives = schema["anyOf"] {
            guard schema.keys.allSatisfy(Self.anyOfAnnotations.contains),
                  let options = alternatives.arrayValue?.compactMap(\.dictionaryValue),
                  options.count == alternatives.arrayValue?.count,
                  !options.isEmpty
            else {
                throw FoundationModelsError.invalidSchema("Unsupported combined anyOf schema: \(name)")
            }
            return .anyOf(
                name: name,
                options: try options.enumerated().map { index, option in
                    try Self.parse(option, name: "\(name)_option\(index)")
                }
            )
        }
        if let types = schema["type"]?.arrayValue {
            let names = types.compactMap(\.stringValue)
            guard names.count == types.count else {
                throw FoundationModelsError.invalidSchema("Expected string: \(name).type")
            }
            guard !names.isEmpty else {
                throw FoundationModelsError.invalidSchema("Schema type union is empty: \(name)")
            }
            return .anyOf(
                name: name,
                options: try names.enumerated().map { index, type in
                    var alternative = schema
                    alternative["type"] = AnyCodable(type)
                    return try Self.parse(alternative, name: "\(name)_option\(index)")
                }
            )
        }
        guard let type = schema["type"]?.stringValue else {
            throw FoundationModelsError.invalidSchema("Expected string: \(name).type")
        }
        if let literal = schema["const"] {
            guard type == "string", let value = literal.stringValue else {
                throw FoundationModelsError.invalidSchema("Only string literal schemas are supported: \(name)")
            }
            return .choices(name: name, values: [value])
        }
        if let choices = schema["enum"] {
            guard type == "string",
                  let values = choices.arrayValue,
                  !values.isEmpty,
                  values.allSatisfy({ $0.stringValue != nil })
            else {
                throw FoundationModelsError.invalidSchema("Only nonempty string enums are supported: \(name)")
            }
            return .choices(name: name, values: values.compactMap(\.stringValue))
        }
        switch type {
        case "object":
            return try Self.parseObject(schema, name: name)
        case "array":
            guard let items = schema["items"]?.dictionaryValue else {
                throw FoundationModelsError.invalidSchema("Expected object: \(name).items")
            }
            return .array(
                item: try Self.parse(items, name: "\(name)_item"),
                minimumElements: try Self.countBound(schema["minItems"], "\(name).minItems", isMinimum: true),
                maximumElements: try Self.countBound(schema["maxItems"], "\(name).maxItems", isMinimum: false)
            )
        case "integer":
            return .integer(
                minimum: try Self.integerBound(schema["minimum"], "\(name).minimum", isMinimum: true),
                maximum: try Self.integerBound(schema["maximum"], "\(name).maximum", isMinimum: false)
            )
        case "number":
            return .number(
                minimum: try Self.number(schema["minimum"], "\(name).minimum"),
                maximum: try Self.number(schema["maximum"], "\(name).maximum")
            )
        case "boolean":
            return .boolean
        case "null":
            return .null
        case "string":
            let minimum = try Self.countBound(schema["minLength"], "\(name).minLength", isMinimum: true) ?? 0
            let maximum = try Self.countBound(schema["maxLength"], "\(name).maxLength", isMinimum: false)
            guard minimum >= 0, maximum.map({ $0 >= minimum }) ?? true else {
                throw FoundationModelsError.invalidSchema("Invalid string length bounds: \(name)")
            }
            return .string
        default:
            throw FoundationModelsError.invalidSchema("Unsupported schema type \(type) in \(name)")
        }
    }

    /// Whether a JSON Schema converts without error.
    /// - Parameters:
    ///   - schema: JSON Schema object.
    ///   - name: Schema name.
    /// - Returns: `true` when ``parse(_:name:)`` succeeds.
    public static func canConvert(_ schema: [String: AnyCodable], name: String) -> Bool {
        (try? Self.parse(schema, name: name)) != nil
    }

    /// Rewrites a JSON Schema into the subset ``parse(_:name:)`` accepts, reporting every change.
    ///
    /// Lenient companion to the strict upstream rules, used when bridging arbitrary agent tools:
    /// unsupported keywords are dropped, `oneOf` becomes `anyOf`, open objects are closed, non-string
    /// `enum`/`const` literals are dropped, `required` is trimmed to declared properties, and a
    /// missing `type` is inferred (`object` with properties, `array` with items, else `string`).
    /// Model output should still be validated against the original schema.
    /// - Parameters:
    ///   - schema: JSON Schema object.
    ///   - path: Path used in notices.
    /// - Returns: The rewritten schema and human-readable notices (empty when nothing changed).
    public static func sanitize(_ schema: [String: AnyCodable], path: String = "<root>") -> (schema: [String: AnyCodable], notices: [String]) {
        var notices: [String] = []
        let sanitized = Self.sanitizeNode(schema, path: path, notices: &notices)
        return (sanitized, notices)
    }

    private static func sanitizeNode(_ input: [String: AnyCodable], path: String, notices: inout [String]) -> [String: AnyCodable] {
        var schema = input
        if let oneOf = schema.removeValue(forKey: "oneOf") {
            if schema["anyOf"] == nil {
                schema["anyOf"] = oneOf
                notices.append("\(path): oneOf treated as anyOf")
            } else {
                notices.append("\(path): dropped oneOf next to anyOf")
            }
        }
        for key in schema.keys.sorted() where !Self.supportedKeywords.contains(key) {
            schema[key] = nil
            notices.append("\(path): dropped unsupported keyword \(key)")
        }
        if let alternatives = schema["anyOf"]?.arrayValue {
            for key in schema.keys.sorted() where !Self.anyOfAnnotations.contains(key) {
                schema[key] = nil
                notices.append("\(path): dropped \(key) next to anyOf")
            }
            let options = alternatives.enumerated().compactMap { index, option -> AnyCodable? in
                guard let object = option.dictionaryValue else {
                    notices.append("\(path).anyOf.\(index): dropped non-object alternative")
                    return nil
                }
                return AnyCodable(Self.sanitizeNode(object, path: "\(path).anyOf.\(index)", notices: &notices))
            }
            if options.isEmpty {
                schema["anyOf"] = nil
                schema["type"] = AnyCodable("string")
                notices.append("\(path): empty anyOf replaced by string")
            } else {
                schema["anyOf"] = AnyCodable(options)
                return schema
            }
        }
        if schema["type"] == nil {
            let inferred = schema["properties"] != nil ? "object" : schema["items"] != nil ? "array" : "string"
            schema["type"] = AnyCodable(inferred)
            notices.append("\(path): missing type inferred as \(inferred)")
        }
        let types = schema["type"]?.arrayValue?.compactMap(\.stringValue) ?? schema["type"]?.stringValue.map { [$0] } ?? []
        if let literal = schema["const"], !(types == ["string"] && literal.stringValue != nil) {
            schema["const"] = nil
            notices.append("\(path): dropped non-string const")
        }
        let stringChoices = schema["enum"]?.arrayValue.map { !$0.isEmpty && $0.allSatisfy { $0.stringValue != nil } } ?? false
        if schema["enum"] != nil, !(types == ["string"] && stringChoices) {
            schema["enum"] = nil
            notices.append("\(path): dropped non-string enum")
        }
        if types.contains("object") {
            if let additional = schema["additionalProperties"], additional.boolValue != false {
                schema["additionalProperties"] = nil
                notices.append("\(path): open object closed (additionalProperties dropped)")
            }
            var properties: [String: AnyCodable] = [:]
            for (key, value) in schema["properties"]?.dictionaryValue ?? [:] {
                guard let object = value.dictionaryValue else {
                    notices.append("\(path).\(key): dropped non-object property schema")
                    continue
                }
                properties[key] = AnyCodable(Self.sanitizeNode(object, path: "\(path).\(key)", notices: &notices))
            }
            if schema["properties"] != nil {
                schema["properties"] = AnyCodable(properties)
            }
            if let required = schema["required"] {
                let names = required.arrayValue?.compactMap(\.stringValue) ?? []
                let kept = names.filter { properties[$0] != nil }
                if kept.count != (required.arrayValue?.count ?? -1) {
                    notices.append("\(path): required trimmed to declared properties")
                }
                schema["required"] = AnyCodable(kept.map { AnyCodable($0) })
            }
        }
        if types.contains("array") {
            if let items = schema["items"]?.dictionaryValue {
                schema["items"] = AnyCodable(Self.sanitizeNode(items, path: "\(path).items", notices: &notices))
            } else {
                schema["items"] = AnyCodable(["type": AnyCodable("string")])
                notices.append("\(path): array items defaulted to string")
            }
        }
        // The bound helpers return `nil` for valid-but-unbounded values, so check for a throw.
        func accepts(_ check: () throws -> Void) -> Bool {
            do {
                try check()
                return true
            } catch {
                return false
            }
        }
        for key in ["minItems", "maxItems", "minLength", "maxLength"] where schema[key] != nil {
            if !accepts({ _ = try Self.countBound(schema[key], key, isMinimum: key.hasPrefix("min")) }) {
                schema[key] = nil
                notices.append("\(path): dropped non-integer \(key)")
            }
        }
        for key in ["minimum", "maximum"] where schema[key] != nil {
            let valid = types.contains("integer")
                ? accepts({ _ = try Self.integerBound(schema[key], key, isMinimum: key == "minimum") })
                : accepts({ _ = try Self.number(schema[key], key) })
            if !valid {
                schema[key] = nil
                notices.append("\(path): dropped invalid \(key)")
            }
        }
        return schema
    }

    private static func parseObject(_ schema: [String: AnyCodable], name: String) throws -> FoundationModelsSchemaNode {
        if let additional = schema["additionalProperties"], additional.boolValue != false {
            throw FoundationModelsError.invalidSchema("Additional object properties are unsupported: \(name)")
        }
        let fields: [String: AnyCodable]
        if let raw = schema["properties"] {
            guard let object = raw.dictionaryValue else {
                throw FoundationModelsError.invalidSchema("Expected object: \(name).properties")
            }
            fields = object
        } else {
            fields = [:]
        }
        var required: [String] = []
        if let raw = schema["required"] {
            guard let values = raw.arrayValue, values.allSatisfy({ $0.stringValue != nil }) else {
                throw FoundationModelsError.invalidSchema("Invalid required properties: \(name)")
            }
            required = values.compactMap(\.stringValue)
        }
        guard Set(required).isSubset(of: Set(fields.keys)) else {
            throw FoundationModelsError.invalidSchema("Invalid required properties: \(name)")
        }
        let properties = try fields.keys.sorted().map { key -> FoundationModelsSchemaProperty in
            guard let field = fields[key]?.dictionaryValue else {
                throw FoundationModelsError.invalidSchema("Expected object: \(name).\(key)")
            }
            return FoundationModelsSchemaProperty(
                name: key,
                description: field["description"]?.stringValue,
                schema: try Self.parse(field, name: "\(name)_\(key)"),
                isOptional: !required.contains(key)
            )
        }
        return .object(name: name, properties: properties)
    }

    /// Upstream `integer(_:_:)`: absent -> `nil`; otherwise an exact, finite, non-Boolean integer.
    static func integer(_ value: AnyCodable?, _ label: String) throws -> Int? {
        guard let value else { return nil }
        switch value.value {
        case .int(let int):
            return int
        case .double(let double):
            guard double.isFinite, double.rounded() == double, let int = Int(exactly: double) else {
                throw FoundationModelsError.invalidSchema("Expected integer: \(label)")
            }
            return int
        default:
            throw FoundationModelsError.invalidSchema("Expected integer: \(label)")
        }
    }

    /// Integer-schema `minimum`/`maximum`: ``integer(_:_:)``, except that an integral bound outside the
    /// platform `Int` range that is looser than every `Int` (a minimum below `Int.min` or a maximum above
    /// `Int.max`) means no guide instead of an error.
    ///
    /// JSON integers that do not fit `Int` decode as `.double`, so zod's `±(2^53-1)` bounds would
    /// otherwise fail the whole request on 32-bit watchOS (arm64_32) while working on 64-bit
    /// platforms. Host-side validation against the original schema still enforces the bound.
    /// Fractional, non-finite and unsatisfiable (a minimum above `Int.max`, a maximum below `Int.min`)
    /// bounds still throw.
    static func integerBound(_ value: AnyCodable?, _ label: String, isMinimum: Bool) throws -> Int? {
        if let value, case .double(let double) = value.value, double.isFinite, double.rounded() == double, Int(exactly: double) == nil {
            guard isMinimum ? double < 0 : double > 0 else {
                throw FoundationModelsError.invalidSchema("Expected integer: \(label)")
            }
            return nil
        }
        return try Self.integer(value, label)
    }

    /// Count bounds (`minItems`, `maxItems`, `minLength`, `maxLength`): ``integer(_:_:)``, except that an
    /// integral maximum above `Int.max` means unbounded (see ``integerBound(_:_:isMinimum:)``).
    static func countBound(_ value: AnyCodable?, _ label: String, isMinimum: Bool) throws -> Int? {
        if !isMinimum, let value, case .double(let double) = value.value,
           double.isFinite, double.rounded() == double, double > 0, Int(exactly: double) == nil
        {
            return nil
        }
        return try Self.integer(value, label)
    }

    /// Upstream `number(_:_:)`: absent -> `nil`; otherwise a finite, non-Boolean number.
    static func number(_ value: AnyCodable?, _ label: String) throws -> Double? {
        guard let value else { return nil }
        switch value.value {
        case .int(let int):
            return Double(int)
        case .double(let double) where double.isFinite:
            return double
        default:
            throw FoundationModelsError.invalidSchema("Expected number: \(label)")
        }
    }
}
