import Foundation
import OpenClawProtocol

/// Errors raised by ``GatewaySessionGroupCatalog`` (mapped to `INVALID_REQUEST`).
public enum GatewaySessionGroupError: Error, LocalizedError, Sendable, Equatable {
    /// The named group does not exist.
    case notFound(String)
    /// `sessions.groups.put` tried to drop groups that still have member sessions.
    case notEmpty([String: Int])
    /// A group name was empty.
    case emptyName

    /// Human-readable message (upstream wording).
    public var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return "unknown session group: \(name)"
        case .notEmpty(let groups):
            let listed = groups.keys.sorted().map { "\"\($0)\" (\(groups[$0] ?? 0))" }.joined(separator: ", ")
            return "sessions.groups.put cannot drop groups that still have member sessions: \(listed); "
                + "include them in names or remove them via sessions.groups.delete"
        case .emptyName:
            return "session group name must not be empty"
        }
    }
}

/// Gateway-owned catalog of custom session groups (upstream `session-groups.ts`).
///
/// Membership stays on each session's `category` field; the catalog owns which groups exist, their
/// order, the sidebar section order and per-group defaults (`cwd`, `worktree`). The catalog is kept
/// in memory and, when a file URL is given, persisted as JSON after every mutation.
public actor GatewaySessionGroupCatalog {
    /// One group (`SessionGroup`: `{name, position}`).
    public struct Group: Codable, Sendable, Equatable {
        /// Group name (the session `category` value).
        public var name: String
        /// Zero-based display position.
        public var position: Int

        /// Creates a group.
        /// - Parameters:
        ///   - name: Group name.
        ///   - position: Display position.
        public init(name: String, position: Int) {
            self.name = name
            self.position = position
        }
    }

    /// Per-group session defaults (`SessionGroupDefaults`: `{name, cwd?, worktree?}`).
    public struct Defaults: Codable, Sendable, Equatable {
        /// Group name.
        public var name: String
        /// Default working directory of sessions created in the group.
        public var cwd: String?
        /// Whether sessions created in the group default to a worktree.
        public var worktree: Bool?

        /// Creates group defaults.
        /// - Parameters:
        ///   - name: Group name.
        ///   - cwd: Default working directory.
        ///   - worktree: Default worktree flag.
        public init(name: String, cwd: String? = nil, worktree: Bool? = nil) {
            self.name = name
            self.cwd = cwd
            self.worktree = worktree
        }
    }

    private struct Snapshot: Codable {
        var names: [String]
        var sectionOrder: [String]
        var defaults: [Defaults]
    }

    private let fileURL: URL?
    private var names: [String] = []
    private var storedSectionOrder: [String] = []
    private var storedDefaults: [String: Defaults] = [:]

    /// Creates a catalog.
    /// - Parameter fileURL: Optional JSON file; loaded now and rewritten after each mutation.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        {
            self.names = Self.normalize(snapshot.names)
            self.storedSectionOrder = snapshot.sectionOrder
            self.storedDefaults = Dictionary(snapshot.defaults.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    /// Groups in display order.
    public func groups() -> [Group] {
        self.names.enumerated().map { Group(name: $0.element, position: $0.offset) }
    }

    /// Sidebar section order (`ungrouped`, `groups`, `work`, `category:<name>`, `catalog:<id>`).
    public func sectionOrder() -> [String] {
        Self.normalizeSectionOrder(self.storedSectionOrder, groupNames: self.names)
    }

    /// Group defaults, in group order.
    public func defaults() -> [Defaults] {
        self.names.compactMap { self.storedDefaults[$0] }
    }

    /// Whether a group exists.
    /// - Parameter name: Group name.
    public func contains(_ name: String) -> Bool {
        self.names.contains(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Replaces the ordered catalog (`sessions.groups.put`).
    ///
    /// Dropping a group that still has member sessions is rejected; remove it with ``delete(_:)``.
    /// - Parameters:
    ///   - names: New ordered names (trimmed, de-duplicated, empty names dropped).
    ///   - sectionOrder: Optional new sidebar section order.
    ///   - memberCounts: Current member count per group name.
    /// - Returns: The new groups.
    /// - Throws: ``GatewaySessionGroupError/notEmpty(_:)``.
    @discardableResult
    public func put(names: [String], sectionOrder: [String]?, memberCounts: [String: Int]) throws -> [Group] {
        let normalized = Self.normalize(names)
        let kept = Set(normalized)
        var nonEmpty: [String: Int] = [:]
        for name in self.names where !kept.contains(name) {
            if let count = memberCounts[name], count > 0 {
                nonEmpty[name] = count
            }
        }
        guard nonEmpty.isEmpty else {
            throw GatewaySessionGroupError.notEmpty(nonEmpty)
        }
        self.names = normalized
        if let sectionOrder {
            self.storedSectionOrder = Self.normalizeSectionOrder(sectionOrder, groupNames: normalized)
        }
        self.storedDefaults = self.storedDefaults.filter { kept.contains($0.key) }
        self.persist()
        return self.groups()
    }

    /// Appends a group assigned through `sessions.patch` so the catalog covers every observable group.
    /// - Parameter name: Group name.
    /// - Returns: `true` when the group was added.
    @discardableResult
    public func register(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !self.names.contains(trimmed) else { return false }
        self.names.append(trimmed)
        self.persist()
        return true
    }

    /// Renames a group in place (members are moved by the caller).
    /// - Parameters:
    ///   - name: Current name.
    ///   - newName: New name.
    /// - Throws: ``GatewaySessionGroupError``.
    public func rename(_ name: String, to newName: String) throws {
        let from = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { throw GatewaySessionGroupError.emptyName }
        guard let index = self.names.firstIndex(of: from) else { throw GatewaySessionGroupError.notFound(from) }
        guard from != to else { return }
        if self.names.contains(to) {
            self.names.remove(at: index)
        } else {
            self.names[index] = to
        }
        self.storedSectionOrder = self.storedSectionOrder.map { $0 == "category:\(from)" ? "category:\(to)" : $0 }
        if var moved = self.storedDefaults.removeValue(forKey: from), self.storedDefaults[to] == nil {
            moved.name = to
            self.storedDefaults[to] = moved
        }
        self.persist()
    }

    /// Deletes a group (members keep their sessions; the caller clears their category).
    /// - Parameter name: Group name.
    /// - Throws: ``GatewaySessionGroupError``.
    public func delete(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GatewaySessionGroupError.emptyName }
        guard let index = self.names.firstIndex(of: trimmed) else { throw GatewaySessionGroupError.notFound(trimmed) }
        self.names.remove(at: index)
        self.storedDefaults[trimmed] = nil
        self.storedSectionOrder.removeAll { $0 == "category:\(trimmed)" }
        self.persist()
    }

    /// Updates a group's defaults (`sessions.groups.update`), registering the group when needed.
    /// - Parameters:
    ///   - name: Group name.
    ///   - cwd: Default working directory (`nil` clears it).
    ///   - worktree: Default worktree flag.
    /// - Returns: The updated defaults list.
    /// - Throws: ``GatewaySessionGroupError/emptyName``.
    @discardableResult
    public func updateDefaults(name: String, cwd: String?, worktree: Bool) throws -> [Defaults] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GatewaySessionGroupError.emptyName }
        if !self.names.contains(trimmed) {
            self.names.append(trimmed)
        }
        let normalizedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.storedDefaults[trimmed] = Defaults(name: trimmed, cwd: normalizedCwd?.isEmpty == false ? normalizedCwd : nil, worktree: worktree)
        self.persist()
        return self.defaults()
    }

    // MARK: - Normalization (upstream normalizeGroupNames / normalizeSidebarSectionOrder)

    static func normalize(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            normalized.append(name)
        }
        return normalized
    }

    static func normalizeSectionOrder(_ sectionOrder: [String], groupNames: [String]) -> [String] {
        let groups = Set(groupNames)
        var seen: Set<String> = []
        var normalized: [String] = []
        for raw in sectionOrder {
            let section = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var canonical: String?
            if ["ungrouped", "groups", "work"].contains(section) {
                canonical = section
            } else if section.hasPrefix("category:") {
                let name = section.dropFirst("category:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, groups.contains(name) {
                    canonical = "category:\(name)"
                }
            } else if section.hasPrefix("catalog:") {
                let id = section.dropFirst("catalog:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty {
                    canonical = "catalog:\(id)"
                }
            }
            if let canonical, seen.insert(canonical).inserted {
                normalized.append(canonical)
            }
        }
        return normalized
    }

    private func persist() {
        guard let fileURL else { return }
        let snapshot = Snapshot(names: self.names, sectionOrder: self.storedSectionOrder, defaults: self.defaults())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}
