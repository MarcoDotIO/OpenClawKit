import Foundation

/// Path-based exec allowlist with glob matching and realpath normalization.
public struct ExecCommandAllowlist: Sendable, Equatable {
    /// Allowed executable path patterns.
    public let patterns: [String]

    /// Creates an exec allowlist from glob-like path patterns.
    /// - Parameter patterns: Allowed executable patterns.
    public init(patterns: [String]) {
        self.patterns = patterns
            .map(Self.normalizePattern)
            .filter { !$0.isEmpty }
    }

    /// Creates an allowlist matching one exact executable path.
    /// - Parameter executableURL: Exact executable URL to allow.
    /// - Returns: Allowlist matching the provided executable.
    public static func exact(_ executableURL: URL) -> ExecCommandAllowlist {
        ExecCommandAllowlist(patterns: [Self.normalizeResolvedPath(executableURL)])
    }

    /// Creates an allowlist matching everything under a workspace root.
    /// - Parameter workspaceRoot: Workspace root URL.
    /// - Returns: Allowlist matching descendants of the workspace root.
    public static func workspace(_ workspaceRoot: URL) -> ExecCommandAllowlist {
        ExecCommandAllowlist(patterns: [Self.normalizeResolvedPath(workspaceRoot) + "/**"])
    }

    /// Resolves and validates an executable against the allowlist.
    /// - Parameters:
    ///   - executable: Executable name or path.
    ///   - cwd: Optional working directory used for relative paths.
    /// - Returns: Canonical executable URL.
    public func authorizedExecutableURL(for executable: String, cwd: URL? = nil) throws -> URL {
        let resolved = try Self.resolveExecutableURL(executable, cwd: cwd)
        guard self.matches(url: resolved) else {
            throw OpenClawCoreError.invalidConfiguration(
                "Executable is not permitted by the exec allowlist: \(resolved.path)"
            )
        }
        return resolved
    }

    /// Returns whether a candidate path is permitted by the allowlist.
    /// - Parameters:
    ///   - path: Candidate executable name or path.
    ///   - cwd: Optional working directory used for relative paths.
    /// - Returns: `true` when the candidate matches any allowlist pattern.
    public func matches(path: String, cwd: URL? = nil) -> Bool {
        guard let resolved = try? Self.resolveExecutableURL(path, cwd: cwd) else {
            return false
        }
        return self.matches(url: resolved)
    }

    /// Returns whether a canonical URL is permitted by the allowlist.
    /// - Parameter url: Candidate executable URL.
    /// - Returns: `true` when the candidate matches any allowlist pattern.
    public func matches(url: URL) -> Bool {
        let normalized = Self.normalizeResolvedPath(url)
        return self.patterns.contains { pattern in
            Self.regex(for: pattern).firstMatch(
                in: normalized,
                options: [],
                range: NSRange(normalized.startIndex..., in: normalized)
            ) != nil
        }
    }

    /// Resolves an executable name or path to a canonical URL.
    /// - Parameters:
    ///   - executable: Executable name or path.
    ///   - cwd: Optional working directory used for relative paths.
    /// - Returns: Canonical executable URL.
    public static func resolveExecutableURL(_ executable: String, cwd: URL? = nil) throws -> URL {
        let trimmed = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Process command cannot be empty")
        }

        if trimmed.contains("/") {
            let baseURL: URL
            if trimmed.hasPrefix("/") {
                baseURL = URL(fileURLWithPath: trimmed)
            } else if let cwd {
                baseURL = cwd.appendingPathComponent(trimmed)
            } else {
                baseURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(trimmed)
            }
            return baseURL.standardizedFileURL.resolvingSymlinksInPath()
        }

        let resolved = try BinaryUtils.ensureBinary(trimmed)
        return URL(fileURLWithPath: resolved).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func normalizeResolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func normalizePattern(_ rawPattern: String) -> String {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        if trimmed.contains("*") || trimmed.contains("?") {
            let normalized = Self.normalizeGlobPath(trimmed)
            if normalized.hasPrefix("/") {
                return normalized
            }
            return Self.normalizeGlobPath(FileManager.default.currentDirectoryPath + "/" + normalized)
        }

        return Self.normalizeResolvedPath(URL(fileURLWithPath: trimmed))
    }

    private static func normalizeGlobPath(_ rawPattern: String) -> String {
        let normalizedSeparators = rawPattern.replacingOccurrences(of: "\\", with: "/")
        let absolute = normalizedSeparators.hasPrefix("/")
        let parts = normalizedSeparators.split(separator: "/", omittingEmptySubsequences: true)
        var normalizedParts: [String] = []

        for part in parts {
            let segment = String(part)
            if segment == "." {
                continue
            }
            if segment == "..",
               let last = normalizedParts.last,
               last != "..",
               last != "**",
               last.contains("*") == false,
               last.contains("?") == false
            {
                normalizedParts.removeLast()
                continue
            }
            normalizedParts.append(segment)
        }

        let joined = normalizedParts.joined(separator: "/")
        if absolute {
            return "/" + joined
        }
        return joined
    }

    private static func regex(for pattern: String) -> NSRegularExpression {
        var regex = "^"
        let scalars = Array(pattern.unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "*":
                if index + 1 < scalars.count, scalars[index + 1] == "*" {
                    regex += ".*"
                    index += 2
                } else {
                    regex += "[^/]*"
                    index += 1
                }
            case "?":
                regex += "[^/]"
                index += 1
            default:
                let character = String(scalar)
                if #"\/.^$+()[]{}|"#.contains(character) {
                    regex += "\\" + character
                } else {
                    regex += character
                }
                index += 1
            }
        }

        regex += "$"
        return try! NSRegularExpression(pattern: regex)
    }
}
