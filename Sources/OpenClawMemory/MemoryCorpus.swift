import Foundation
import OpenClawCore

/// Additional memory root, optionally narrowed by a root-relative glob (upstream `MemoryExtraPath`).
///
/// Decodes either a string (`"notes"`) or an object (`{"path": "notes", "pattern": "**/*.md"}`).
public struct MemoryExtraPath: Codable, Sendable, Equatable {
    /// Directory or file path (relative paths resolve against the workspace).
    public var path: String
    /// Optional glob relative to ``path`` (`*`, `**`, `?`).
    public var pattern: String?

    /// Creates an extra path.
    /// - Parameters:
    ///   - path: Path.
    ///   - pattern: Glob.
    public init(path: String, pattern: String? = nil) {
        self.path = path
        self.pattern = pattern
    }

    private enum CodingKeys: String, CodingKey {
        case path, pattern
    }

    /// Decodes a string or `{path, pattern}` object.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            self.init(path: single)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try container.decode(String.self, forKey: .path), pattern: try container.decodeIfPresent(String.self, forKey: .pattern))
    }

    /// Encodes as a string when there is no pattern, else as an object.
    public func encode(to encoder: Encoder) throws {
        if self.pattern == nil {
            var container = encoder.singleValueContainer()
            try container.encode(self.path)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.path, forKey: .path)
            try container.encodeIfPresent(self.pattern, forKey: .pattern)
        }
    }
}

/// One Markdown file in the memory corpus.
public struct MemoryCorpusFile: Sendable, Equatable {
    /// Workspace-relative path with `/` separators (absolute for extra paths outside the workspace).
    public let path: String
    /// File URL.
    public let url: URL
    /// Modification time.
    public let modifiedAt: Date
    /// Size in bytes.
    public let size: Int

    /// Creates a corpus file.
    /// - Parameters:
    ///   - path: Relative path.
    ///   - url: File URL.
    ///   - modifiedAt: Modification time.
    ///   - size: Size.
    public init(path: String, url: URL, modifiedAt: Date, size: Int) {
        self.path = path
        self.url = url
        self.modifiedAt = modifiedAt
        self.size = size
    }
}

/// The memory file corpus of a workspace (upstream memory-core source contract).
///
/// Sources: `MEMORY.md` and `USER.md` (evergreen), every `memory/**/*.md` file, and ``extraPaths``.
/// Hidden files are skipped, as are symlinks that resolve outside their root.
public struct MemoryCorpus: Sendable, Equatable {
    /// Evergreen root files.
    public static let evergreenFiles = ["MEMORY.md", "USER.md"]
    /// Directory holding memory notes.
    public static let memoryDirectory = "memory"

    /// Workspace root.
    public let workspaceRoot: URL
    /// Extra paths.
    public let extraPaths: [MemoryExtraPath]

    /// Creates a corpus.
    /// - Parameters:
    ///   - workspaceRoot: Workspace root.
    ///   - extraPaths: Extra paths.
    public init(workspaceRoot: URL, extraPaths: [MemoryExtraPath] = []) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.extraPaths = extraPaths
    }

    /// Enumerates corpus files sorted by path.
    public func files() -> [MemoryCorpusFile] {
        var files: [String: MemoryCorpusFile] = [:]
        let root = self.workspaceRoot
        for name in Self.evergreenFiles {
            let url = root.appendingPathComponent(name)
            if let file = Self.file(at: url, relativeTo: root, jail: root) {
                files[file.path] = file
            }
        }
        for file in Self.markdownFiles(under: root.appendingPathComponent(Self.memoryDirectory), relativeTo: root, pattern: nil) {
            files[file.path] = file
        }
        for extra in self.extraPaths {
            let base = Self.resolve(extra.path, workspaceRoot: root)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                for file in Self.markdownFiles(under: base, relativeTo: root, pattern: extra.pattern) {
                    files[file.path] = file
                }
            } else if base.pathExtension.lowercased() == "md", let file = Self.file(at: base, relativeTo: root, jail: base.deletingLastPathComponent()) {
                files[file.path] = file
            }
        }
        return files.values.sorted { $0.path < $1.path }
    }

    /// Whether `path` (workspace-relative) is readable through `memory_get`: `MEMORY.md`, `USER.md`,
    /// `memory/**`, or inside an extra path. Session transcript paths are never allowed.
    /// - Parameter path: Requested path.
    /// - Returns: The resolved file URL when allowed.
    public func resolveReadablePath(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        let normalized = trimmed.hasPrefix("./") ? String(trimmed.dropFirst(2)) : trimmed
        let root = self.workspaceRoot.resolvingSymlinksInPath()
        let candidate = (normalized.hasPrefix("/") ? URL(fileURLWithPath: normalized) : root.appendingPathComponent(normalized))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.pathExtension.lowercased() == "md" || Self.evergreenFiles.contains(candidate.lastPathComponent) else { return nil }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if candidate.path.hasPrefix(rootPath) {
            let relative = String(candidate.path.dropFirst(rootPath.count))
            if Self.evergreenFiles.contains(relative) || relative.hasPrefix(Self.memoryDirectory + "/") {
                return candidate
            }
        }
        for extra in self.extraPaths {
            let base = Self.resolve(extra.path, workspaceRoot: self.workspaceRoot).standardizedFileURL.resolvingSymlinksInPath()
            if candidate.path == base.path { return candidate }
            let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
            if candidate.path.hasPrefix(basePath) {
                if let pattern = extra.pattern, !MemoryGlob.matches(pattern: pattern, path: String(candidate.path.dropFirst(basePath.count))) {
                    continue
                }
                return candidate
            }
        }
        return nil
    }

    // MARK: - Helpers

    static func resolve(_ path: String, workspaceRoot: URL) -> URL {
        if path == "~" { return OpenClawFileSystem.resolveHomeDirectory() }
        if path.hasPrefix("~/") { return OpenClawFileSystem.resolveHomeDirectory().appendingPathComponent(String(path.dropFirst(2))) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return workspaceRoot.appendingPathComponent(path)
    }

    static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    static func file(at url: URL, relativeTo root: URL, jail: URL) -> MemoryCorpusFile? {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            let jailPath = jail.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = jailPath.hasSuffix("/") ? jailPath : jailPath + "/"
            guard resolved.hasPrefix(prefix) else { return nil }
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let resolvedAttributes = (try? fileManager.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)) ?? attributes
        return MemoryCorpusFile(
            path: self.relativePath(of: url, root: root),
            url: url,
            modifiedAt: (resolvedAttributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0),
            size: (resolvedAttributes[.size] as? NSNumber)?.intValue ?? 0
        )
    }

    static func markdownFiles(under directory: URL, relativeTo root: URL, pattern: String?) -> [MemoryCorpusFile] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: directory,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            return []
        }
        var results: [MemoryCorpusFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            if let pattern {
                let relative = self.relativePath(of: url, root: directory)
                guard MemoryGlob.matches(pattern: pattern, path: relative) else { continue }
            }
            if let file = self.file(at: url, relativeTo: root, jail: directory) {
                results.append(file)
            }
        }
        return results
    }
}

/// Minimal glob matcher (`**` any path, `*` within a segment, `?` one character).
enum MemoryGlob {
    static func matches(pattern: String, path: String) -> Bool {
        var regex = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    regex += ".*"
                    index = pattern.index(after: next)
                    if index < pattern.endIndex, pattern[index] == "/" { index = pattern.index(after: index) ; regex += "(?:/)?" }
                    continue
                }
                regex += "[^/]*"
            } else if character == "?" {
                regex += "[^/]"
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}

/// Polling watcher that reports corpus changes after a debounce (upstream default 1500 ms).
///
/// Polling is used on every platform (a directory `DispatchSource` does not see nested changes); it
/// compares file paths, sizes and modification times.
public actor MemoryCorpusWatcher {
    /// Upstream `DEFAULT_WATCH_DEBOUNCE_MS`.
    public static let defaultDebounceMs = 1_500

    private let corpus: MemoryCorpus
    private let intervalMs: Int
    private let debounceMs: Int
    private var task: Task<Void, Never>?

    /// Creates a watcher.
    /// - Parameters:
    ///   - corpus: Corpus to watch.
    ///   - intervalMs: Poll interval.
    ///   - debounceMs: Quiet period before reporting.
    public init(corpus: MemoryCorpus, intervalMs: Int = 1_000, debounceMs: Int = MemoryCorpusWatcher.defaultDebounceMs) {
        self.corpus = corpus
        self.intervalMs = max(50, intervalMs)
        self.debounceMs = max(0, debounceMs)
    }

    /// Starts watching; `onChange` runs after changes settle.
    /// - Parameter onChange: Change handler.
    public func start(onChange: @escaping @Sendable () async -> Void) {
        self.task?.cancel()
        let corpus = self.corpus
        let interval = UInt64(self.intervalMs) * 1_000_000
        let debounce = self.debounceMs
        self.task = Task.detached {
            var last = Self.signature(corpus)
            var pendingSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                let current = Self.signature(corpus)
                if current != last {
                    last = current
                    pendingSince = Date()
                } else if let since = pendingSince, Date().timeIntervalSince(since) * 1_000 >= Double(debounce) {
                    pendingSince = nil
                    await onChange()
                }
            }
        }
    }

    /// Stops watching.
    public func stop() {
        self.task?.cancel()
        self.task = nil
    }

    static func signature(_ corpus: MemoryCorpus) -> [String] {
        corpus.files().map { "\($0.path)|\($0.size)|\($0.modifiedAt.timeIntervalSince1970)" }
    }
}
