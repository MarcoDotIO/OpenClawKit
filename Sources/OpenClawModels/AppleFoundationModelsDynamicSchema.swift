import Foundation
import OpenClawProtocol

// Apple-only half of the JSON Schema converter: emits `DynamicGenerationSchema` values from the
// validated ``FoundationModelsSchemaNode`` tree (upstream apple-fm `dynamicSchema`/`generationSchema`).
//
// FoundationModels exists on tvOS with the 27 SDKs but every declaration is unavailable there, and
// on watchOS the generation-schema API starts at watchOS 27 (27 SDK only), hence the guard.
#if canImport(FoundationModels) && !os(tvOS) && (!os(watchOS) || compiler(>=6.4))
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0, *)
public extension FoundationModelsSchemaNode {
    /// Builds the equivalent `DynamicGenerationSchema`.
    ///
    /// `null` schemas need OS 26.4 (`DynamicGenerationSchema.null`); earlier systems throw.
    /// - Returns: The dynamic schema.
    /// - Throws: ``FoundationModelsError`` when a node cannot be represented on this OS.
    func dynamicGenerationSchema() throws -> DynamicGenerationSchema {
        switch self {
        case .anyOf(let name, let options):
            return DynamicGenerationSchema(name: name, anyOf: try options.map { try $0.dynamicGenerationSchema() })
        case .choices(let name, let values):
            return DynamicGenerationSchema(name: name, anyOf: values)
        case .object(let name, let properties):
            return DynamicGenerationSchema(
                name: name,
                properties: try properties.map { property in
                    DynamicGenerationSchema.Property(
                        name: property.name,
                        description: property.description,
                        schema: try property.schema.dynamicGenerationSchema(),
                        isOptional: property.isOptional
                    )
                }
            )
        case .array(let item, let minimumElements, let maximumElements):
            return DynamicGenerationSchema(
                arrayOf: try item.dynamicGenerationSchema(),
                minimumElements: minimumElements,
                maximumElements: maximumElements
            )
        case .integer(let minimum, let maximum):
            var guides: [GenerationGuide<Int>] = []
            if let minimum { guides.append(.minimum(minimum)) }
            if let maximum { guides.append(.maximum(maximum)) }
            return DynamicGenerationSchema(type: Int.self, guides: guides)
        case .number(let minimum, let maximum):
            var guides: [GenerationGuide<Double>] = []
            if let minimum { guides.append(.minimum(minimum)) }
            if let maximum { guides.append(.maximum(maximum)) }
            return DynamicGenerationSchema(type: Double.self, guides: guides)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .null:
            #if compiler(>=6.4)
            if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
                return .null
            }
            #endif
            throw FoundationModelsError(
                code: .unsupported,
                message: "Null schemas require Apple OS 26.4 or later."
            )
        case .string:
            // AFM has no length guides and rejects regex guides; host validation keeps them.
            return DynamicGenerationSchema(type: String.self)
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0, *)
public extension FoundationModelsSchemaConverter {
    /// Converts a JSON Schema into a `DynamicGenerationSchema` (upstream `dynamicSchema(_:name:)`).
    /// - Parameters:
    ///   - schema: JSON Schema object.
    ///   - name: Schema name.
    /// - Returns: The dynamic schema.
    /// - Throws: ``FoundationModelsError`` with the upstream conversion messages.
    static func dynamicSchema(_ schema: [String: AnyCodable], name: String) throws -> DynamicGenerationSchema {
        try Self.parse(schema, name: name).dynamicGenerationSchema()
    }

    /// Converts a JSON Schema into a `GenerationSchema` rooted at `name` (upstream `generationSchema`).
    /// - Parameters:
    ///   - schema: JSON Schema object.
    ///   - name: Root schema name (``responseSchemaName`` for structured output).
    /// - Returns: The generation schema.
    /// - Throws: ``FoundationModelsError`` for unconvertible schemas, or the framework's schema error.
    static func generationSchema(_ schema: [String: AnyCodable], name: String) throws -> GenerationSchema {
        let root = try Self.dynamicSchema(schema, name: name)
        do {
            return try GenerationSchema(root: root, dependencies: [])
        } catch {
            throw FoundationModelsError.invalidSchema("Invalid generation schema \(name): \(error.localizedDescription)")
        }
    }

    /// Encodes a `GenerationSchema` as a JSON Schema object (the framework's `Codable` form, with
    /// `$defs`/`$ref` for named nested schemas), for sending Foundation Models tool and response
    /// schemas to other providers.
    /// - Parameter schema: Generation schema.
    /// - Returns: JSON Schema object, or the empty-object schema when encoding fails.
    static func jsonSchema(from schema: GenerationSchema) -> [String: AnyCodable] {
        guard let data = try? JSONEncoder().encode(schema),
              let object = try? JSONDecoder().decode([String: AnyCodable].self, from: data)
        else {
            return ModelToolDefinition.emptyParametersSchema
        }
        return object
    }
}
#endif
