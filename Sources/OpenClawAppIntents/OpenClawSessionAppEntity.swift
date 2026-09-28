#if canImport(AppIntents)
import AppIntents
import Foundation
import OpenClawKit

/// An OpenClaw chat session exposed to Siri, Shortcuts and Spotlight.
///
/// The entity identifier is the gateway session key, so saved shortcuts keep working across launches.
public struct OpenClawSessionAppEntity: AppEntity, Sendable {
    /// Type name shown by the system.
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "OpenClaw Session")
    }

    /// Query used to resolve and suggest sessions.
    public static var defaultQuery: OpenClawSessionAppEntityQuery {
        OpenClawSessionAppEntityQuery()
    }

    /// Session key.
    public let id: String

    /// Session title.
    @Property(title: "Title")
    public var title: String

    /// Owning agent id, when known.
    public var agentId: String?
    /// Last update time, when known.
    public var updatedAt: Date?
    /// Whether the session is a group or channel conversation.
    public var isGroup: Bool

    /// System display representation.
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(self.title)")
    }

    /// Creates an entity from a host summary.
    /// - Parameter summary: Session summary.
    public init(summary: OpenClawIntentSessionSummary) {
        self.id = summary.sessionKey
        self.agentId = summary.agentId
        self.updatedAt = summary.updatedAt
        self.isGroup = summary.isGroup
        self.title = summary.title
    }

    /// Creates an entity.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - title: Display title (defaults to the key).
    ///   - agentId: Owning agent id.
    ///   - isGroup: Whether the session is shared.
    public init(sessionKey: String, title: String? = nil, agentId: String? = nil, isGroup: Bool = false) {
        self.init(summary: OpenClawIntentSessionSummary(
            sessionKey: sessionKey,
            title: title ?? sessionKey,
            agentId: agentId,
            isGroup: isGroup))
    }

    /// Host summary for this entity.
    public var summary: OpenClawIntentSessionSummary {
        OpenClawIntentSessionSummary(
            sessionKey: self.id,
            title: self.title,
            agentId: self.agentId,
            updatedAt: self.updatedAt,
            isGroup: self.isGroup)
    }
}

/// Resolves, searches and suggests ``OpenClawSessionAppEntity`` values through the configured host.
public struct OpenClawSessionAppEntityQuery: EntityStringQuery {
    /// Maximum sessions suggested by the system picker.
    public static let suggestionLimit = 10
    /// Maximum sessions returned for a search.
    public static let searchLimit = 20

    /// Creates the query.
    public init() {}

    /// Resolves sessions by key.
    public func entities(for identifiers: [String]) async throws -> [OpenClawSessionAppEntity] {
        let summaries = try await OpenClawAppIntents.host.sessions(forKeys: identifiers)
        OpenClawIntentSessionCache.shared.store(summaries)
        return summaries.map(OpenClawSessionAppEntity.init(summary:))
    }

    /// Searches sessions by title.
    public func entities(matching string: String) async throws -> [OpenClawSessionAppEntity] {
        let summaries = try await OpenClawAppIntents.host.sessions(matching: string, limit: Self.searchLimit)
        OpenClawIntentSessionCache.shared.store(summaries)
        return summaries.map(OpenClawSessionAppEntity.init(summary:))
    }

    /// Suggests recent sessions.
    public func suggestedEntities() async throws -> [OpenClawSessionAppEntity] {
        let summaries = try await OpenClawAppIntents.host.sessions(matching: nil, limit: Self.suggestionLimit)
        OpenClawIntentSessionCache.shared.store(summaries)
        return summaries.map(OpenClawSessionAppEntity.init(summary:))
    }
}

/// Process-wide cache of session summaries seen by queries (serves display representations).
final class OpenClawIntentSessionCache: @unchecked Sendable {
    static let shared = OpenClawIntentSessionCache()

    private let lock = NSLock()
    private var summaries: [String: OpenClawIntentSessionSummary] = [:]

    func store(_ values: [OpenClawIntentSessionSummary]) {
        self.lock.withLock {
            for value in values {
                self.summaries[value.sessionKey] = value
            }
        }
    }

    func summary(for key: String) -> OpenClawIntentSessionSummary? {
        self.lock.withLock { self.summaries[key] }
    }

    func removeAll() {
        self.lock.withLock { self.summaries.removeAll() }
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
extension OpenClawSessionAppEntityQuery {
    /// Sessions resolve in the app process or an App Intents extension.
    public static var allowedExecutionTargets: IntentExecutionTargets {
        [.main, .appIntentsExtension]
    }

    /// Display representations served from the query cache, fetching only unknown keys.
    public func displayRepresentations(for identifiers: [String]) async throws -> [String: DisplayRepresentation] {
        var result: [String: DisplayRepresentation] = [:]
        var missing: [String] = []
        for key in identifiers {
            if let cached = OpenClawIntentSessionCache.shared.summary(for: key) {
                result[key] = DisplayRepresentation(title: "\(cached.title)")
            } else {
                missing.append(key)
            }
        }
        if !missing.isEmpty {
            for entity in try await self.entities(for: missing) {
                result[entity.id] = entity.displayRepresentation
            }
        }
        return result
    }
}

@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
extension OpenClawSessionAppEntity: OwnershipProvidingEntity {
    /// Group and channel sessions are shared with other people; direct sessions are unknown.
    public var ownership: EntityOwnership {
        self.isGroup ? .shared : .unknown
    }
}
#endif
#endif
