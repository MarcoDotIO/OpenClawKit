import Foundation
import OpenClawCore

/// Path jail for the file-read tool the v6 skill catalog relies on.
///
/// The `<available_skills>` prompt asks the model to read `SKILL.md` (and files it references)
/// itself, so the runtime's `read` tool must allow the skill roots in addition to the workspace.
/// Resolve every requested path through ``resolve(_:)`` before reading.
public struct SkillReadAccess: Sendable, Equatable {
    /// Allowed roots (standardized, symlinks resolved).
    public let roots: [URL]

    /// Creates a jail over explicit roots.
    /// - Parameter roots: Allowed directories.
    public init(roots: [URL]) {
        var seen = Set<String>()
        self.roots = roots.compactMap { root in
            let normalized = root.standardizedFileURL.resolvingSymlinksInPath()
            return seen.insert(normalized.path).inserted ? normalized : nil
        }
    }

    /// Resolves a path (absolute, or relative to the first root) inside an allowed root.
    /// - Parameter path: Requested path.
    /// - Returns: Canonical URL.
    /// - Throws: ``WorkspaceGuardError/pathOutsideWorkspace(_:)`` when the path escapes every root.
    public func resolve(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), let first = self.roots.first else {
            throw WorkspaceGuardError.pathOutsideWorkspace(path)
        }
        let candidate = (trimmed.hasPrefix("/") ? URL(fileURLWithPath: trimmed) : first.appendingPathComponent(trimmed))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        for root in self.roots {
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if candidate.path == root.path || candidate.path.hasPrefix(prefix) {
                return candidate
            }
        }
        throw WorkspaceGuardError.pathOutsideWorkspace(path)
    }

    /// Whether a path resolves inside an allowed root.
    /// - Parameter path: Requested path.
    /// - Returns: `true` when readable.
    public func allows(_ path: String) -> Bool {
        (try? self.resolve(path)) != nil
    }
}

public extension SkillRegistry {
    /// Read jail covering the workspace and every existing skill root.
    /// - Returns: The jail (workspace first).
    func readAccess() -> SkillReadAccess {
        let roots = [self.workspaceDirectory] + self.orderedRoots()
            .map(\.url)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return SkillReadAccess(roots: roots)
    }
}
