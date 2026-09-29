#if canImport(AppIntents)
import AppIntents
import Foundation
import OpenClawKit

/// An OpenClaw agent exposed to Siri and Shortcuts.
public struct OpenClawAgentAppEntity: AppEntity, Sendable {
    /// Type name shown by the system.
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "OpenClaw Agent")
    }

    /// Query used to list agents.
    public static var defaultQuery: OpenClawAgentAppEntityQuery {
        OpenClawAgentAppEntityQuery()
    }

    /// Agent id.
    public let id: String

    /// Agent display name.
    @Property(title: "Name")
    public var name: String

    /// Optional emoji badge.
    public var emoji: String?

    /// System display representation.
    public var displayRepresentation: DisplayRepresentation {
        if let emoji, !emoji.isEmpty {
            return DisplayRepresentation(title: "\(emoji) \(self.name)")
        }
        return DisplayRepresentation(title: "\(self.name)")
    }

    /// Creates an entity from a host summary.
    /// - Parameter summary: Agent summary.
    public init(summary: OpenClawIntentAgentSummary) {
        self.id = summary.agentId
        self.emoji = summary.emoji
        self.name = summary.displayName
    }
}

/// Lists ``OpenClawAgentAppEntity`` values through the configured host.
public struct OpenClawAgentAppEntityQuery: EnumerableEntityQuery {
    /// Creates the query.
    public init() {}

    /// All selectable agents.
    public func allEntities() async throws -> [OpenClawAgentAppEntity] {
        try await OpenClawAppIntents.host.agents().map(OpenClawAgentAppEntity.init(summary:))
    }

    /// Resolves agents by id (unknown ids are dropped).
    public func entities(for identifiers: [String]) async throws -> [OpenClawAgentAppEntity] {
        let wanted = Set(identifiers)
        return try await self.allEntities().filter { wanted.contains($0.id) }
    }
}
#endif
