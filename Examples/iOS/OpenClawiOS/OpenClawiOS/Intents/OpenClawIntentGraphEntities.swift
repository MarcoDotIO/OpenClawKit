import AppIntents
import Foundation
import OpenClawKit

/// AppIntents-facing node kind enum that mirrors SDK intent-graph node kinds.
enum IntentGraphNodeKindValue: String, AppEnum, CaseIterable {
    case run
    case prompt
    case tool
    case skill
    case model
    case output
    case channel
    case memory

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Intent Graph Node Kind")
    }

    static var caseDisplayRepresentations: [IntentGraphNodeKindValue: DisplayRepresentation] {
        [
            .run: "Run",
            .prompt: "Prompt",
            .tool: "Tool",
            .skill: "Skill",
            .model: "Model",
            .output: "Output",
            .channel: "Channel",
            .memory: "Memory",
        ]
    }

    var protocolKind: IntentGraphNodeKind {
        IntentGraphNodeKind(rawValue: self.rawValue) ?? .run
    }
}

/// AppEntity wrapper around selectable node kinds for graph-aware intents.
struct IntentGraphNodeKindEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Intent Graph Focus Node")
    }

    static var defaultQuery: IntentGraphNodeKindEntityQuery {
        IntentGraphNodeKindEntityQuery()
    }

    let id: String
    let kind: IntentGraphNodeKindValue

    init(kind: IntentGraphNodeKindValue) {
        self.id = kind.rawValue
        self.kind = kind
    }

    var displayRepresentation: DisplayRepresentation {
        let title = IntentGraphNodeKindValue.caseDisplayRepresentations[self.kind]?.title ??
            LocalizedStringResource(stringLiteral: self.kind.rawValue.capitalized)
        return DisplayRepresentation(title: title)
    }
}

/// Query provider for intent-graph node-kind entities.
struct IntentGraphNodeKindEntityQuery: EntityStringQuery {
    func entities(for identifiers: [IntentGraphNodeKindEntity.ID]) async throws -> [IntentGraphNodeKindEntity] {
        let ids = Set(identifiers)
        return IntentGraphNodeKindValue.allCases
            .map(IntentGraphNodeKindEntity.init(kind:))
            .filter { ids.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [IntentGraphNodeKindEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return try await self.suggestedEntities()
        }
        return IntentGraphNodeKindValue.allCases
            .filter { kind in
                kind.rawValue.contains(needle) ||
                    kind.rawValue.capitalized.lowercased().contains(needle)
            }
            .map(IntentGraphNodeKindEntity.init(kind:))
    }

    func suggestedEntities() async throws -> [IntentGraphNodeKindEntity] {
        IntentGraphNodeKindValue.allCases.map(IntentGraphNodeKindEntity.init(kind:))
    }
}
