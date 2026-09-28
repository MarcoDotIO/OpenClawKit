import Foundation
import OpenClawProtocol

/// Model-facing names for MCP servers and tools (upstream `src/agents/agent-bundle-mcp-names.ts`).
public enum MCPToolNaming {
    /// Separator between the server and tool fragments.
    public static let separator = "__"
    /// Maximum server fragment length.
    public static let maxServerNameLength = 30
    /// Maximum total tool name length.
    public static let maxToolNameLength = 64

    static func sanitizeFragment(_ raw: String, fallback: String, maxChars: Int? = nil) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let normalized = cleaned.isEmpty ? fallback : cleaned
        let startsWithLetter = normalized.unicodeScalars.first.map { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) } ?? false
        let providerSafe = startsWithLetter ? normalized : "\(fallback)-\(normalized)"
        guard let maxChars else { return providerSafe }
        return String(providerSafe.prefix(maxChars))
    }

    /// Sanitizes one server name and reserves it (collisions get `-2`, `-3`, … suffixes).
    /// - Parameters:
    ///   - raw: Declared server name.
    ///   - used: Lowercased names already assigned (updated).
    /// - Returns: Safe server name.
    public static func sanitizeServerName(_ raw: String, used: inout Set<String>) -> String {
        let base = self.sanitizeFragment(raw, fallback: "mcp", maxChars: self.maxServerNameLength)
        var candidate = base
        var index = 2
        while used.contains(candidate.lowercased()) {
            let suffix = "-\(index)"
            candidate = String(base.prefix(max(1, self.maxServerNameLength - suffix.count))) + suffix
            index += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// Assigns safe names for every declared server, in declaration order.
    /// - Parameter serverNames: Declared names.
    /// - Returns: Declared name → safe name.
    public static func assignSafeServerNames(_ serverNames: [String]) -> [String: String] {
        var used = Set<String>()
        var result: [String: String] = [:]
        for name in serverNames {
            result[name] = self.sanitizeServerName(name, used: &used)
        }
        return result
    }

    /// Builds `<server>__<tool>` within 64 characters, suffixing `-2`, `-3`, … on reserved collisions.
    /// - Parameters:
    ///   - serverName: Safe server name.
    ///   - toolName: Server tool name.
    ///   - reservedNames: Lowercased names already taken (core tools, earlier MCP tools).
    /// - Returns: Safe tool name.
    public static func buildSafeToolName(serverName: String, toolName: String, reservedNames: Set<String>) -> String {
        let cleaned = self.sanitizeFragment(toolName, fallback: "tool")
        let maxToolChars = max(1, self.maxToolNameLength - serverName.count - self.separator.count)
        let truncated = String(cleaned.prefix(maxToolChars))
        let base = truncated.isEmpty ? "tool" : truncated
        var candidate = serverName + self.separator + base
        var index = 2
        while reservedNames.contains(candidate.lowercased()) {
            let suffix = "-\(index)"
            candidate = serverName + self.separator + String(base.prefix(max(1, maxToolChars - suffix.count))) + suffix
            index += 1
        }
        return candidate
    }
}

/// Tool catalog normalization for one server (upstream `normalizeMcpToolCatalog` and `sanitizeMcpMetadataText`).
public enum MCPToolCatalogNormalizer {
    /// Upstream `MCP_METADATA_TEXT_LIMIT` (UTF-16 units).
    public static let metadataTextLimit = 1_200

    /// Trims names, drops empty names, every copy of an ambiguous (duplicated) name, tools with
    /// `execution.taskSupport == "required"`, then applies the tool filter.
    /// - Parameters:
    ///   - tools: Tools from `tools/list`.
    ///   - filter: Server tool filter.
    /// - Returns: Included tools in server order.
    public static func normalize(_ tools: [MCPToolDefinition], filter: MCPToolFilter?) -> [MCPToolDefinition] {
        let names = tools.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        var counts: [String: Int] = [:]
        for name in names where !name.isEmpty {
            counts[name, default: 0] += 1
        }
        var included: [MCPToolDefinition] = []
        for (index, tool) in tools.enumerated() {
            let name = names[index]
            guard !name.isEmpty, counts[name] == 1, tool.taskSupport != "required" else { continue }
            guard filter?.allows(name) ?? true else { continue }
            included.append(
                MCPToolDefinition(
                    name: name,
                    title: tool.title,
                    description: tool.description,
                    inputSchema: tool.inputSchema,
                    outputSchema: tool.outputSchema,
                    annotations: tool.annotations,
                    taskSupport: tool.taskSupport
                )
            )
        }
        return included
    }

    /// Scrubs untrusted metadata: redacts "ignore/disregard previous instructions" phrases and caps
    /// the text at 1200 UTF-16 units (plus `...`).
    /// - Parameter value: Raw text.
    /// - Returns: Sanitized text, or `nil` when empty.
    public static func sanitizeMetadataText(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else { return nil }
        var scrubbed = normalized
        for pattern in [
            "ignore\\s+(?:all\\s+)?(?:previous|prior|above)\\s+instructions",
            "disregard\\s+(?:all\\s+)?(?:previous|prior|above)\\s+instructions",
        ] {
            scrubbed = scrubbed.replacingOccurrences(
                of: pattern,
                with: "[redacted MCP metadata instruction]",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        guard scrubbed.utf16.count > self.metadataTextLimit else { return scrubbed }
        var result = ""
        var units = 0
        for scalar in scrubbed.unicodeScalars {
            let width = scalar.utf16.count
            if units + width > self.metadataTextLimit { break }
            result.unicodeScalars.append(scalar)
            units += width
        }
        return result + "..."
    }
}

/// Minimal JSON Schema validator (type, enum, const, required, properties, additionalProperties,
/// items, minItems/maxItems, minLength/maxLength, minimum/maximum, anyOf/oneOf/allOf).
///
/// Used for MCP `outputSchema` enforcement and plugin `configSchema` validation. Unsupported keywords
/// are ignored (the validator errs on the side of accepting).
public enum MCPJSONSchemaValidator {
    /// Validation failure with the JSON path of the offending value.
    public struct Failure: Error, LocalizedError, Sendable, Equatable {
        /// JSON path (`$`, `$.items[0]`, …).
        public let path: String
        /// Message.
        public let message: String

        /// Human-readable description.
        public var errorDescription: String? {
            "\(self.path) \(self.message)"
        }
    }

    /// Validates `instance` against `schema`.
    /// - Parameters:
    ///   - instance: Value.
    ///   - schema: JSON Schema object.
    /// - Throws: ``Failure`` for the first violation.
    public static func validate(_ instance: AnyCodable, against schema: [String: AnyCodable]) throws {
        try self.validate(instance, schema: schema, path: "$")
    }

    private static func validate(_ instance: AnyCodable, schema: [String: AnyCodable], path: String) throws {
        if let options = schema["anyOf"]?.arrayValue?.compactMap(\.dictionaryValue), !options.isEmpty {
            guard options.contains(where: { (try? self.validate(instance, schema: $0, path: path)) != nil }) else {
                throw Failure(path: path, message: "does not match anyOf")
            }
        }
        if let options = schema["oneOf"]?.arrayValue?.compactMap(\.dictionaryValue), !options.isEmpty {
            let matches = options.filter { (try? self.validate(instance, schema: $0, path: path)) != nil }.count
            guard matches == 1 else { throw Failure(path: path, message: "must match exactly one oneOf schema") }
        }
        for option in schema["allOf"]?.arrayValue?.compactMap(\.dictionaryValue) ?? [] {
            try self.validate(instance, schema: option, path: path)
        }
        if let constant = schema["const"], constant != instance {
            throw Failure(path: path, message: "must equal const")
        }
        if let options = schema["enum"]?.arrayValue, !options.contains(instance) {
            throw Failure(path: path, message: "is not in the enum set")
        }
        let types: [String] = schema["type"]?.stringValue.map { [$0] } ?? schema["type"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !types.isEmpty, !types.contains(where: { self.matches(instance, type: $0) }) {
            throw Failure(path: path, message: "must be \(types.joined(separator: " or "))")
        }
        switch instance.value {
        case .object(let object):
            for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
                throw Failure(path: path, message: "is missing required property \(key)")
            }
            let properties = schema["properties"]?.dictionaryValue ?? [:]
            for (key, value) in object {
                if let propertySchema = properties[key]?.dictionaryValue {
                    try self.validate(value, schema: propertySchema, path: "\(path).\(key)")
                } else if let additional = schema["additionalProperties"] {
                    if additional.boolValue == false {
                        throw Failure(path: path, message: "has unexpected property \(key)")
                    }
                    if let additionalSchema = additional.dictionaryValue {
                        try self.validate(value, schema: additionalSchema, path: "\(path).\(key)")
                    }
                }
            }
        case .array(let items):
            if let minItems = schema["minItems"]?.intValue, items.count < minItems {
                throw Failure(path: path, message: "must have at least \(minItems) items")
            }
            if let maxItems = schema["maxItems"]?.intValue, items.count > maxItems {
                throw Failure(path: path, message: "must have at most \(maxItems) items")
            }
            if let itemSchema = schema["items"]?.dictionaryValue {
                for (index, item) in items.enumerated() {
                    try self.validate(item, schema: itemSchema, path: "\(path)[\(index)]")
                }
            }
        case .string(let text):
            if let minLength = schema["minLength"]?.intValue, text.count < minLength {
                throw Failure(path: path, message: "must be at least \(minLength) characters")
            }
            if let maxLength = schema["maxLength"]?.intValue, text.count > maxLength {
                throw Failure(path: path, message: "must be at most \(maxLength) characters")
            }
        case .int, .double:
            let number = instance.doubleValue ?? 0
            if let minimum = schema["minimum"]?.doubleValue, number < minimum {
                throw Failure(path: path, message: "must be >= \(minimum)")
            }
            if let maximum = schema["maximum"]?.doubleValue, number > maximum {
                throw Failure(path: path, message: "must be <= \(maximum)")
            }
        default:
            break
        }
    }

    private static func matches(_ instance: AnyCodable, type: String) -> Bool {
        switch (type, instance.value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null):
            return true
        case ("integer", .int):
            return true
        case ("integer", .double(let value)):
            return value.rounded() == value
        case ("number", .int), ("number", .double):
            return true
        default:
            return false
        }
    }
}
