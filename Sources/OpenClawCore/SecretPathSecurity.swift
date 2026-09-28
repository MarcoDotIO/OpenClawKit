import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// POSIX trust checks for secret-provider paths (upstream `readSecureFile` with
/// `allowInsecure: false` and `src/secrets/exec-provider-path-validation.ts`).
///
/// - Secret files must be regular files (not symlinks, directories or devices) with exactly one hard
///   link, no group or other permission bits (`mode & 0o077 == 0`), owned by the current user.
/// - Exec provider commands must be absolute regular files (never symlinks: the retired
///   `allowSymlinkCommand`/`allowInsecurePath` opt-outs stay fail-closed, like upstream), inside
///   `trustedDirs` when configured, not group- or world-writable, and owned by the current user.
///
/// Checks run on Apple platforms and Linux; on other platforms they are skipped.
public enum SecretPathSecurity {
    /// A path that fails a trust check.
    public struct Violation: Error, LocalizedError, Sendable, Equatable {
        /// Stable failure code.
        public enum Code: String, Sendable, Equatable {
            /// The path does not exist or cannot be inspected.
            case unreadable
            /// The path is a symbolic link.
            case symlink
            /// The path is not a regular file.
            case notRegularFile = "not-regular-file"
            /// The file has more than one hard link.
            case hardlink
            /// Permissions are too open.
            case insecurePermissions = "insecure-permissions"
            /// The file is owned by another user.
            case foreignOwner = "foreign-owner"
            /// The command is not an absolute path.
            case notAbsolute = "not-absolute"
            /// The command is outside the configured trusted directories.
            case outsideTrustedDirs = "outside-trusted-dirs"
        }

        /// Failure code.
        public let code: Code
        /// Config label of the checked path (for example `secrets.providers.vault.path`).
        public let label: String
        /// Checked path.
        public let path: String

        /// Creates a violation.
        /// - Parameters:
        ///   - code: Failure code.
        ///   - label: Config label.
        ///   - path: Checked path.
        public init(code: Code, label: String, path: String) {
            self.code = code
            self.label = label
            self.path = path
        }

        /// Human-readable description (matches upstream wording).
        public var errorDescription: String? {
            switch self.code {
            case .unreadable:
                return "\(self.label) is not readable: \(self.path)"
            case .symlink:
                return "\(self.label) must not be a symlink: \(self.path)"
            case .notRegularFile:
                return "\(self.label) must be a file: \(self.path)"
            case .hardlink:
                return "\(self.label) must not have additional hard links: \(self.path)"
            case .insecurePermissions:
                return "\(self.label) permissions are too open: \(self.path)"
            case .foreignOwner:
                return "\(self.label) must be owned by the current user: \(self.path)"
            case .notAbsolute:
                return "\(self.label) must be an absolute path."
            case .outsideTrustedDirs:
                return "\(self.label) is outside trustedDirs: \(self.path)"
            }
        }
    }

    /// File facts read with `lstat` (the link itself, never its target).
    struct FileFacts: Sendable, Equatable {
        /// File type bits (`st_mode & S_IFMT`).
        var type: UInt32
        /// Permission bits (`st_mode & 0o7777`).
        var permissions: UInt32
        /// Hard link count.
        var linkCount: UInt64
        /// Owner uid.
        var ownerUID: UInt32

        static let typeMask: UInt32 = 0o170000
        static let regularFile: UInt32 = 0o100000
        static let symbolicLink: UInt32 = 0o120000
        static let directory: UInt32 = 0o040000
    }

    /// Verifies a file-provider secret file before it is read.
    /// - Parameters:
    ///   - path: Absolute (already `~`-expanded) path.
    ///   - label: Config label used in errors.
    /// - Throws: ``Violation`` when a check fails.
    public static func assertSecureSecretFile(_ path: String, label: String) throws {
        #if canImport(Glibc) || canImport(Musl) || canImport(Darwin)
        guard let facts = self.lstatFacts(path) else {
            throw Violation(code: .unreadable, label: label, path: path)
        }
        try self.checkSecretFile(facts, path: path, label: label, currentUID: UInt32(getuid()))
        #endif
    }

    /// Verifies an exec-provider command before it runs.
    /// - Parameters:
    ///   - command: Configured command (`~` is expanded with `environment`).
    ///   - label: Config label used in errors.
    ///   - trustedDirs: Directories the command must live in (empty allows any directory).
    ///   - environment: Environment used for `~` expansion.
    /// - Returns: The command path to execute.
    /// - Throws: ``Violation`` when a check fails.
    @discardableResult
    public static func assertSecureExecCommand(
        _ command: String,
        label: String,
        trustedDirs: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let expanded = OpenClawConfigDocumentStore.expandHome(command.trimmingCharacters(in: .whitespacesAndNewlines), environment: environment)
        guard expanded.hasPrefix("/") else {
            throw Violation(code: .notAbsolute, label: label, path: expanded)
        }
        let commandPath = URL(fileURLWithPath: expanded).standardizedFileURL.path
        #if canImport(Glibc) || canImport(Musl) || canImport(Darwin)
        guard let facts = self.lstatFacts(commandPath) else {
            throw Violation(code: .unreadable, label: label, path: commandPath)
        }
        try self.checkExecCommand(
            facts,
            path: commandPath,
            label: label,
            trustedDirs: trustedDirs.map {
                URL(fileURLWithPath: OpenClawConfigDocumentStore.expandHome($0, environment: environment)).standardizedFileURL.path
            },
            currentUID: UInt32(getuid())
        )
        #endif
        return commandPath
    }

    /// Whether `path` is `directory` or inside it (lexical comparison of standardized paths).
    /// - Parameters:
    ///   - directory: Directory path.
    ///   - path: Candidate path.
    /// - Returns: `true` when `path` is inside `directory`.
    public static func isPath(_ path: String, inside directory: String) -> Bool {
        let base = directory.hasSuffix("/") && directory.count > 1 ? String(directory.dropLast()) : directory
        return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }

    // MARK: Checks (pure; unit-tested with synthetic facts)

    static func checkSecretFile(_ facts: FileFacts, path: String, label: String, currentUID: UInt32) throws {
        if facts.type == FileFacts.symbolicLink {
            throw Violation(code: .symlink, label: label, path: path)
        }
        guard facts.type == FileFacts.regularFile else {
            throw Violation(code: .notRegularFile, label: label, path: path)
        }
        guard facts.linkCount == 1 else {
            throw Violation(code: .hardlink, label: label, path: path)
        }
        guard facts.permissions & 0o077 == 0 else {
            throw Violation(code: .insecurePermissions, label: label, path: path)
        }
        guard facts.ownerUID == currentUID else {
            throw Violation(code: .foreignOwner, label: label, path: path)
        }
    }

    static func checkExecCommand(
        _ facts: FileFacts,
        path: String,
        label: String,
        trustedDirs: [String],
        currentUID: UInt32
    ) throws {
        if facts.type == FileFacts.directory {
            throw Violation(code: .notRegularFile, label: label, path: path)
        }
        // Symlinks are rejected before trusted-directory evaluation (upstream order).
        if facts.type == FileFacts.symbolicLink {
            throw Violation(code: .symlink, label: label, path: path)
        }
        guard facts.type == FileFacts.regularFile else {
            throw Violation(code: .notRegularFile, label: label, path: path)
        }
        if !trustedDirs.isEmpty, !trustedDirs.contains(where: { self.isPath(path, inside: $0) }) {
            throw Violation(code: .outsideTrustedDirs, label: label, path: path)
        }
        guard facts.permissions & 0o022 == 0 else {
            throw Violation(code: .insecurePermissions, label: label, path: path)
        }
        guard facts.ownerUID == currentUID else {
            throw Violation(code: .foreignOwner, label: label, path: path)
        }
    }

    #if canImport(Glibc) || canImport(Musl) || canImport(Darwin)
    static func lstatFacts(_ path: String) -> FileFacts? {
        var info = stat()
        guard !path.utf8.contains(0), lstat(path, &info) == 0 else {
            return nil
        }
        let mode = UInt32(info.st_mode)
        return FileFacts(
            type: mode & FileFacts.typeMask,
            permissions: mode & 0o7777,
            linkCount: UInt64(info.st_nlink),
            ownerUID: UInt32(info.st_uid)
        )
    }
    #endif
}
