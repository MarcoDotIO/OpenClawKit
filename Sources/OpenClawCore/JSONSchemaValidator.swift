import Foundation
import OpenClawProtocol

/// Validation failure raised by ``JSONSchemaValidator``.
public struct JSONSchemaValidationError: Error, LocalizedError, Sendable, Equatable {
    /// JSON path of the failing value (for example `$.items[2].name`).
    public let path: String
    /// Human-readable failure message, prefixed with ``path``.
    public let message: String

    /// Creates a validation error.
    /// - Parameters:
    ///   - path: JSON path of the failing value.
    ///   - message: Failure message.
    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    /// Human-readable message.
    public var errorDescription: String? {
        self.message
    }
}

/// Small JSON Schema validator shared by `llm-task`, the agent loop and MCP tool bridges.
///
/// Supports the subset tool schemas use in practice: `type` (string or array; `integer` satisfies
/// `number`), `enum`, `const`, `required`, `properties`, `additionalProperties` (boolean or schema),
/// `items`, `minItems`/`maxItems`, `minimum`/`maximum`/`exclusiveMinimum`/`exclusiveMaximum`,
/// `minLength`/`maxLength`, `pattern`, and `anyOf`/`oneOf`/`allOf`. Unknown keywords are ignored.
public enum JSONSchemaValidator {
    /// Validates a JSON value against a schema.
    /// - Parameters:
    ///   - instance: Value to validate.
    ///   - schema: JSON Schema object.
    /// - Throws: ``JSONSchemaValidationError`` for the first violation.
    public static func validate(instance: AnyCodable, against schema: [String: AnyCodable]) throws {
        try self.validate(instance: instance, against: schema, path: "$")
    }

    /// Validates tool arguments (an object) against a tool parameter schema.
    /// - Parameters:
    ///   - arguments: Tool arguments.
    ///   - schema: JSON Schema object.
    /// - Throws: ``JSONSchemaValidationError`` for the first violation.
    public static func validate(arguments: [String: AnyCodable], against schema: [String: AnyCodable]) throws {
        try self.validate(instance: AnyCodable(.object(arguments)), against: schema, path: "$")
    }

    /// Returns the first violation message, or `nil` when the value is valid.
    /// - Parameters:
    ///   - instance: Value to validate.
    ///   - schema: JSON Schema object.
    /// - Returns: The violation message.
    public static func firstViolation(instance: AnyCodable, against schema: [String: AnyCodable]) -> String? {
        do {
            try self.validate(instance: instance, against: schema)
            return nil
        } catch let error as JSONSchemaValidationError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    private static func fail(_ path: String, _ message: String) -> JSONSchemaValidationError {
        JSONSchemaValidationError(path: path, message: "\(path) \(message)")
    }

    private static func validate(instance: AnyCodable, against schema: [String: AnyCodable], path: String) throws {
        if let allowedTypes = self.stringArray(schema["type"]) {
            let actualType = self.typeName(for: instance)
            let accepts = allowedTypes.contains(actualType) || (actualType == "integer" && allowedTypes.contains("number"))
                || (actualType == "number" && allowedTypes.contains("integer") && self.isIntegral(instance))
            if !accepts {
                throw self.fail(path, "expected \(allowedTypes.joined(separator: "|")) but received \(actualType)")
            }
        }
        if let enumValues = schema["enum"]?.arrayValue, !enumValues.contains(where: { self.jsonEqual($0, instance) }) {
            throw self.fail(path, "value is not in enum set")
        }
        if let constant = schema["const"], !self.jsonEqual(constant, instance) {
            throw self.fail(path, "value does not match const")
        }
        if let all = schema["allOf"]?.arrayValue {
            for option in all.compactMap(\.dictionaryValue) {
                try self.validate(instance: instance, against: option, path: path)
            }
        }
        if let any = schema["anyOf"]?.arrayValue {
            let options = any.compactMap(\.dictionaryValue)
            if !options.isEmpty, !options.contains(where: { (try? self.validate(instance: instance, against: $0, path: path)) != nil }) {
                throw self.fail(path, "does not match any allowed schema")
            }
        }
        if let one = schema["oneOf"]?.arrayValue {
            let options = one.compactMap(\.dictionaryValue)
            let matches = options.filter { (try? self.validate(instance: instance, against: $0, path: path)) != nil }.count
            if !options.isEmpty, matches != 1 {
                throw self.fail(path, "must match exactly one schema (matched \(matches))")
            }
        }

        switch instance.value {
        case .object(let object):
            try self.validateObject(object, schema: schema, path: path)
        case .array(let array):
            try self.validateArray(array, schema: schema, path: path)
        case .int(let number):
            try self.validateNumber(Double(number), schema: schema, path: path)
        case .double(let number):
            try self.validateNumber(number, schema: schema, path: path)
        case .string(let string):
            try self.validateString(string, schema: schema, path: path)
        case .null, .bool:
            break
        }
    }

    private static func validateObject(_ object: [String: AnyCodable], schema: [String: AnyCodable], path: String) throws {
        for key in self.stringArray(schema["required"]) ?? [] where object[key] == nil {
            throw self.fail("\(path).\(key)", "is required")
        }
        let propertySchemas = schema["properties"]?.dictionaryValue ?? [:]
        for key in object.keys.sorted() {
            guard let value = object[key] else { continue }
            if let propertySchema = propertySchemas[key]?.dictionaryValue {
                try self.validate(instance: value, against: propertySchema, path: "\(path).\(key)")
                continue
            }
            if let additionalSchema = schema["additionalProperties"]?.dictionaryValue {
                try self.validate(instance: value, against: additionalSchema, path: "\(path).\(key)")
                continue
            }
            if schema["additionalProperties"]?.boolValue == false {
                throw self.fail("\(path).\(key)", "is not allowed")
            }
        }
    }

    private static func validateArray(_ array: [AnyCodable], schema: [String: AnyCodable], path: String) throws {
        if let minItems = schema["minItems"]?.intValue, array.count < minItems {
            throw self.fail(path, "requires at least \(minItems) items")
        }
        if let maxItems = schema["maxItems"]?.intValue, array.count > maxItems {
            throw self.fail(path, "allows at most \(maxItems) items")
        }
        if let itemSchema = schema["items"]?.dictionaryValue {
            for (index, item) in array.enumerated() {
                try self.validate(instance: item, against: itemSchema, path: "\(path)[\(index)]")
            }
        }
    }

    private static func validateNumber(_ number: Double, schema: [String: AnyCodable], path: String) throws {
        if let minimum = schema["minimum"]?.doubleValue, number < minimum {
            throw self.fail(path, "must be >= \(self.render(minimum))")
        }
        if let maximum = schema["maximum"]?.doubleValue, number > maximum {
            throw self.fail(path, "must be <= \(self.render(maximum))")
        }
        if let exclusive = schema["exclusiveMinimum"]?.doubleValue, number <= exclusive {
            throw self.fail(path, "must be > \(self.render(exclusive))")
        }
        if let exclusive = schema["exclusiveMaximum"]?.doubleValue, number >= exclusive {
            throw self.fail(path, "must be < \(self.render(exclusive))")
        }
    }

    private static func validateString(_ string: String, schema: [String: AnyCodable], path: String) throws {
        let length = string.count
        if let minLength = schema["minLength"]?.intValue, length < minLength {
            throw self.fail(path, "must be at least \(minLength) characters")
        }
        if let maxLength = schema["maxLength"]?.intValue, length > maxLength {
            throw self.fail(path, "must be at most \(maxLength) characters")
        }
        if let pattern = schema["pattern"]?.stringValue,
           let regex = try? NSRegularExpression(pattern: pattern),
           regex.firstMatch(in: string, range: NSRange(string.startIndex..<string.endIndex, in: string)) == nil
        {
            throw self.fail(path, "does not match pattern \(pattern)")
        }
    }

    private static func render(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func isIntegral(_ value: AnyCodable) -> Bool {
        if case .double(let number) = value.value {
            return number.isFinite && number.rounded() == number
        }
        return false
    }

    private static func jsonEqual(_ lhs: AnyCodable, _ rhs: AnyCodable) -> Bool {
        if lhs == rhs {
            return true
        }
        if let left = lhs.doubleValue, let right = rhs.doubleValue {
            return left == right
        }
        return false
    }

    private static func typeName(for value: AnyCodable) -> String {
        switch value.value {
        case .null:
            return "null"
        case .bool:
            return "boolean"
        case .int:
            return "integer"
        case .double:
            return "number"
        case .string:
            return "string"
        case .object:
            return "object"
        case .array:
            return "array"
        }
    }

    private static func stringArray(_ value: AnyCodable?) -> [String]? {
        guard let value else { return nil }
        switch value.value {
        case .string(let string):
            return [string]
        case .array(let array):
            return array.compactMap(\.stringValue)
        default:
            return nil
        }
    }
}
