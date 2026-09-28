import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// Port of the upstream exec-approval allowlist contract (`src/infra/exec-command-resolution.ts`,
// `src/infra/command-carriers.ts`, `src/infra/exec-allowlist-pattern.ts` and the macOS
// `ExecAllowlistMatcher` / `ExecEnvInvocationUnwrapper`). It runs on Apple platforms and Linux.

/// One exec allowlist rule (upstream `ExecAllowlistEntry`).
///
/// Every field round-trips, including ``source`` (`allow-always` for generated grants) and the
/// display-only ``commandText``. The legacy bare-string form decodes as a ``pattern``.
public struct ExecAllowlistEntry: Codable, Sendable, Hashable, Identifiable {
    /// Source marker of generated "always allow" grants.
    public static let allowAlwaysSource = "allow-always"

    /// Rule identifier (generated when missing).
    public var id: String
    /// Executable pattern: a path glob (`/opt/**/rg`), a basename glob (`rg`, `r?`) or `*`.
    public var pattern: String
    /// Origin of the rule (``allowAlwaysSource`` for generated grants, `nil` for manual rules).
    public var source: String?
    /// Display text of the command that created the rule.
    public var commandText: String?
    /// Argument restriction: a cwd-bound hash (`sha256:cwd-argv:v1:…`) or a JavaScript regular expression.
    public var argPattern: String?
    /// Last use in epoch milliseconds.
    public var lastUsedAt: Int64?
    /// Last command that matched the rule.
    public var lastUsedCommand: String?
    /// Last resolved executable path.
    public var lastResolvedPath: String?

    /// Creates an entry.
    /// - Parameters:
    ///   - id: Rule identifier.
    ///   - pattern: Executable pattern.
    ///   - source: Origin marker.
    ///   - commandText: Display text of the creating command.
    ///   - argPattern: Argument restriction.
    ///   - lastUsedAt: Last use in epoch milliseconds.
    ///   - lastUsedCommand: Last matching command.
    ///   - lastResolvedPath: Last resolved executable path.
    public init(
        id: String = UUID().uuidString,
        pattern: String,
        source: String? = nil,
        commandText: String? = nil,
        argPattern: String? = nil,
        lastUsedAt: Int64? = nil,
        lastUsedCommand: String? = nil,
        lastResolvedPath: String? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.source = source
        self.commandText = commandText
        self.argPattern = argPattern
        self.lastUsedAt = lastUsedAt
        self.lastUsedCommand = lastUsedCommand
        self.lastResolvedPath = lastResolvedPath
    }

    /// Whether the rule is a generated "always allow" grant.
    public var isAllowAlways: Bool {
        self.source == Self.allowAlwaysSource
    }

    private enum CodingKeys: String, CodingKey {
        case id, pattern, source, commandText, argPattern, lastUsedAt, lastUsedCommand, lastResolvedPath
    }

    /// Decodes the object form or a legacy bare-string pattern.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let legacy = try? container.decode(String.self) {
            self.init(pattern: legacy.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(String.self, forKey: .id).flatMap { $0.isEmpty ? nil : $0 }
        var lastUsedAt: Int64? = (try? container.decodeIfPresent(Int64.self, forKey: .lastUsedAt)) ?? nil
        if lastUsedAt == nil, let double = (try? container.decodeIfPresent(Double.self, forKey: .lastUsedAt)) ?? nil,
           double.isFinite, abs(double) < 9.0e18
        {
            // The Node gateway writes `Date.now()` as a JSON number.
            lastUsedAt = Int64(double.rounded())
        }
        self.init(
            id: id ?? UUID().uuidString,
            pattern: try container.decode(String.self, forKey: .pattern),
            source: try container.decodeIfPresent(String.self, forKey: .source),
            commandText: try container.decodeIfPresent(String.self, forKey: .commandText),
            argPattern: try container.decodeIfPresent(String.self, forKey: .argPattern),
            lastUsedAt: lastUsedAt,
            lastUsedCommand: try container.decodeIfPresent(String.self, forKey: .lastUsedCommand),
            lastResolvedPath: try container.decodeIfPresent(String.self, forKey: .lastResolvedPath)
        )
    }

    /// Encodes every present field (including ``source`` and ``commandText``).
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.pattern, forKey: .pattern)
        try container.encodeIfPresent(self.source, forKey: .source)
        try container.encodeIfPresent(self.commandText, forKey: .commandText)
        try container.encodeIfPresent(self.argPattern, forKey: .argPattern)
        try container.encodeIfPresent(self.lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(self.lastUsedCommand, forKey: .lastUsedCommand)
        try container.encodeIfPresent(self.lastResolvedPath, forKey: .lastResolvedPath)
    }
}

/// Executable resolution for one command (upstream `ExecutableResolution` / macOS `ExecCommandResolution`).
public struct ExecCommandResolution: Sendable, Equatable {
    /// Executable token as written (after transparent `env` unwrapping).
    public var rawExecutable: String
    /// Absolute path found through `PATH` or the working directory (lexically standardized).
    public var resolvedPath: String?
    /// POSIX `realpath` of ``resolvedPath`` (symlinks resolved), used as the trust path.
    public var resolvedRealPath: String?
    /// Executable basename.
    public var executableName: String
    /// Working directory.
    public var cwd: String?
    /// Effective argv (the executable first).
    public var argv: [String]?
    /// Wrapper whose semantic use (for example `env` with assignments or `-P`) blocks allowlisting.
    ///
    /// Blocked resolutions stay bound to the wrapper itself (`/usr/bin/env`), so only a rule for the
    /// wrapper (or `*`) can match, and no "always allow" grant is generated.
    public var blockedWrapper: String?

    /// Creates a resolution.
    /// - Parameters:
    ///   - rawExecutable: Executable token.
    ///   - resolvedPath: Resolved absolute path.
    ///   - resolvedRealPath: Symlink-free path.
    ///   - executableName: Executable basename.
    ///   - cwd: Working directory.
    ///   - argv: Effective argv.
    ///   - blockedWrapper: Wrapper that blocks allowlisting.
    public init(
        rawExecutable: String,
        resolvedPath: String?,
        resolvedRealPath: String? = nil,
        executableName: String,
        cwd: String?,
        argv: [String]? = nil,
        blockedWrapper: String? = nil
    ) {
        self.rawExecutable = rawExecutable
        self.resolvedPath = resolvedPath
        self.resolvedRealPath = resolvedRealPath
        self.executableName = executableName
        self.cwd = cwd
        self.argv = argv
        self.blockedWrapper = blockedWrapper
    }

    /// Maximum transparent wrapper depth (upstream `maxWrapperDepth`).
    public static let maxWrapperDepth = 4

    /// Shells whose inline payloads (`sh -c …`) are not split by this port; they never match an allowlist.
    public static let shellWrapperNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "ash", "csh", "tcsh", "pwsh", "powershell", "cmd",
    ]

    /// Resolves a command's executable for allowlist matching.
    ///
    /// Transparent `env` invocations (no assignments or options) are unwrapped; `env` with modifiers
    /// stays bound to `env` and is marked ``blockedWrapper``. Shell wrappers with an inline command
    /// (`sh -c`, `bash -lc`, …) are marked blocked, because this port does not split shell payloads.
    /// - Parameters:
    ///   - argv: Command argv.
    ///   - cwd: Working directory (defaults to the process directory for relative paths).
    ///   - environment: Environment whose `PATH` is searched.
    /// - Returns: The resolution, or `nil` for an empty command.
    public static func resolve(
        argv: [String],
        cwd: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ExecCommandResolution? {
        var current = argv
        var blocked: String?
        for _ in 0..<Self.maxWrapperDepth {
            guard let first = current.first, ExecCommandToken.basenameLower(first) == "env" else { break }
            guard let prelude = ExecEnvInvocation.parsePrelude(current) else {
                blocked = "env"
                break
            }
            if prelude.usesModifiers {
                blocked = "env"
                break
            }
            current = Array(current[prelude.commandIndex...])
        }
        if blocked == nil, let first = current.first, ExecCommandToken.basenameLower(first) == "env" {
            // Wrapper depth overflow stays bound to the wrapper.
            blocked = "env"
        }
        if blocked == nil, let first = current.first, Self.shellWrapperNames.contains(ExecCommandToken.basenameLower(first)),
           current.dropFirst().contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") })
        {
            blocked = ExecCommandToken.basenameLower(first)
        }
        guard let raw = current.first?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        var resolution = Self.resolveExecutable(rawExecutable: raw, argv: current, cwd: cwd, environment: environment)
        resolution.blockedWrapper = blocked
        return resolution
    }

    /// Resolves each command of a shell command line (`a && b | c`); every segment must resolve.
    ///
    /// Fails closed (`nil`) for command substitution, process substitution, redirections, background
    /// jobs, comments followed by more lines, or unterminated quotes.
    /// - Parameters:
    ///   - commandText: Shell command text.
    ///   - cwd: Working directory.
    ///   - environment: Environment whose `PATH` is searched.
    /// - Returns: One resolution per segment, or `nil`.
    public static func resolve(
        commandText: String,
        cwd: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ExecCommandResolution]? {
        guard let segments = ExecShellWords.splitCommandChain(commandText), !segments.isEmpty else {
            return nil
        }
        var resolutions: [ExecCommandResolution] = []
        for segment in segments {
            guard let argv = ExecShellWords.split(segment), !argv.isEmpty,
                  let resolution = Self.resolve(argv: argv, cwd: cwd, environment: environment)
            else {
                return nil
            }
            resolutions.append(resolution)
        }
        return resolutions
    }

    /// Approval working-directory identity: POSIX `realpath` when the directory exists, else the
    /// standardized path (upstream `canonicalApprovalCwd`).
    /// - Parameter cwd: Working directory (`nil` uses the process directory).
    /// - Returns: Canonical path.
    public static func canonicalApprovalCwd(_ cwd: String?) -> String {
        let requested = cwd ?? FileManager.default.currentDirectoryPath
        return ExecPathSupport.canonicalPath(requested) ?? URL(fileURLWithPath: requested).standardizedFileURL.path
    }

    /// Whether a durable path-only grant for this executable would be too broad (interpreters and
    /// tools that run code from ordinary argv; upstream `isInterpreterLikePersistentGrantTarget`).
    /// - Parameter resolution: Resolution.
    /// - Returns: `true` for interpreter-like targets.
    public static func isInterpreterLikePersistentGrantTarget(_ resolution: ExecCommandResolution) -> Bool {
        [resolution.rawExecutable, resolution.resolvedPath, resolution.resolvedRealPath]
            .compactMap { $0 }
            .map(ExecCommandToken.basenameLower)
            .contains(where: Self.isInterpreterLikeName)
    }

    static let interpreterLikeNames: Set<String> = [
        "awk", "bun", "deno", "find", "gawk", "gmake", "gsed", "lua", "make", "mawk", "nawk",
        "node", "nodejs", "osascript", "perl", "php", "pypy", "pypy3", "python", "python2", "python3",
        "r", "rscript", "ruby", "sed", "xargs",
    ]

    private static func isInterpreterLikeName(_ value: String) -> Bool {
        let normalized = value.hasSuffix(".exe") ? String(value.dropLast(4)) : value
        if Self.interpreterLikeNames.contains(normalized) {
            return true
        }
        let stripped = normalized.replacingOccurrences(of: #"-?\d+(?:\.\d+)*$"#, with: "", options: .regularExpression)
        return stripped.count >= 2 && Self.interpreterLikeNames.contains(stripped)
    }

    private static func resolveExecutable(
        rawExecutable: String,
        argv: [String],
        cwd: String?,
        environment: [String: String]
    ) -> ExecCommandResolution {
        let expanded = rawExecutable.hasPrefix("~")
            ? OpenClawConfigDocumentStore.expandHome(rawExecutable, environment: environment)
            : rawExecutable
        let resolvedPath: String?
        if expanded.contains("/") || expanded.contains("\\") {
            if expanded.hasPrefix("/") {
                resolvedPath = expanded
            } else {
                let base = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
                let root = (base?.isEmpty == false) ? base! : FileManager.default.currentDirectoryPath
                resolvedPath = URL(fileURLWithPath: root).appendingPathComponent(expanded).path
            }
        } else {
            resolvedPath = try? BinaryUtils.ensureBinary(expanded, pathEnv: environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"])
        }
        let normalized = resolvedPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let realPath = normalized.flatMap(ExecPathSupport.canonicalPath)
        let name = normalized.map { URL(fileURLWithPath: $0).lastPathComponent } ?? expanded
        return ExecCommandResolution(
            rawExecutable: expanded,
            resolvedPath: normalized,
            resolvedRealPath: realPath,
            executableName: name,
            cwd: cwd,
            argv: argv
        )
    }
}

/// Command-token helpers.
public enum ExecCommandToken {
    /// Lowercased basename of a command token (`/usr/bin/ENV` → `env`).
    /// - Parameter token: Command token.
    /// - Returns: Lowercased basename.
    public static func basenameLower(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/").last.map { String($0).lowercased() } ?? normalized.lowercased()
    }
}

/// `env` invocation parsing (upstream `parseEnvInvocationPrelude` / `unwrapEnvInvocation`).
public enum ExecEnvInvocation {
    /// Options that take a value (`env -P /usr/bin cmd`, `--chdir=/tmp`, …).
    public static let optionsWithValue: Set<String> = [
        "-C", "-P", "-S", "-s", "-u", "--argv0", "--block-signal", "--chdir", "--default-signal",
        "--ignore-signal", "--split-string", "--unset",
    ]
    /// Options that split a string into argv.
    public static let splitStringOptions: Set<String> = ["-S", "-s", "--split-string"]
    /// Standalone options.
    public static let standaloneOptions: Set<String> = ["-0", "-i", "--ignore-environment", "--null"]
    /// Maximum `env -S` recursion depth.
    public static let maxSplitPayloadDepth = 32

    /// Parsed `env` prelude.
    public struct Prelude: Sendable, Equatable {
        /// Names assigned with `NAME=value`.
        public var assignmentKeys: [String]
        /// Index of the carried command in the original argv.
        public var commandIndex: Int
        /// Argv reconstructed from `env -S`, when used.
        public var splitArgv: [String]?
        /// Whether assignments or options change the environment or executable lookup.
        public var usesModifiers: Bool
    }

    /// Parses the options and assignments of an `env` invocation.
    /// - Parameters:
    ///   - argv: Argv whose first token is `env`.
    ///   - depth: `env -S` recursion depth.
    /// - Returns: The prelude, or `nil` when `argv` is not a well-formed `env` invocation.
    public static func parsePrelude(_ argv: [String], depth: Int = 0) -> Prelude? {
        guard depth <= Self.maxSplitPayloadDepth, let first = argv.first, ExecCommandToken.basenameLower(first) == "env" else {
            return nil
        }
        var usesModifiers = false
        var assignmentKeys: [String] = []
        var index = 1
        while index < argv.count {
            let token = argv[index]
            if token.isEmpty {
                return nil
            }
            if Self.isAssignment(token) {
                usesModifiers = true
                if let delimiter = token.firstIndex(of: "="), delimiter != token.startIndex {
                    assignmentKeys.append(String(token[..<delimiter]))
                }
                index += 1
                continue
            }
            if token == "--" || token == "-" {
                return index + 1 < argv.count
                    ? Prelude(assignmentKeys: assignmentKeys, commandIndex: index + 1, splitArgv: nil, usesModifiers: usesModifiers || token == "-")
                    : nil
            }
            if token.hasPrefix("-") {
                guard let options = Self.parseOptionToken(token) else {
                    return nil
                }
                usesModifiers = true
                if let split = options.first(where: { Self.splitStringOptions.contains($0.name) }) {
                    let payloadIndex = split.inlineValue == nil ? index + 1 : index
                    guard let payload = split.inlineValue ?? (payloadIndex < argv.count ? argv[payloadIndex] : nil),
                          let inner = ExecShellWords.split(payload), !inner.isEmpty
                    else {
                        return nil
                    }
                    let trailing = Array(argv[min(payloadIndex + 1, argv.count)...])
                    let carried = inner + trailing
                    let nested = Self.parsePrelude(["env"] + carried, depth: depth + 1)
                    let resolved = nested.map { $0.splitArgv ?? Array((["env"] + carried)[$0.commandIndex...]) } ?? carried
                    return Prelude(assignmentKeys: assignmentKeys, commandIndex: payloadIndex + 1, splitArgv: resolved, usesModifiers: true)
                }
                if let last = options.last, Self.optionsWithValue.contains(last.name), last.inlineValue == nil {
                    index += 1
                }
                index += 1
                continue
            }
            return Prelude(assignmentKeys: assignmentKeys, commandIndex: index, splitArgv: nil, usesModifiers: usesModifiers)
        }
        return nil
    }

    /// The argv carried by `env` (including argv reconstructed from `env -S`).
    /// - Parameter argv: Argv whose first token is `env`.
    /// - Returns: The carried argv, or `nil`.
    public static func unwrap(_ argv: [String]) -> [String]? {
        guard let prelude = self.parsePrelude(argv) else { return nil }
        return prelude.splitArgv ?? Array(argv[prelude.commandIndex...])
    }

    /// Whether an `env` invocation changes the environment or executable lookup.
    /// - Parameter argv: Argv whose first token is `env`.
    /// - Returns: `true` when modifiers are used (malformed invocations count as modified).
    public static func usesModifiers(_ argv: [String]) -> Bool {
        self.parsePrelude(argv)?.usesModifiers ?? (ExecCommandToken.basenameLower(argv.first ?? "") == "env")
    }

    static func isAssignment(_ token: String) -> Bool {
        token.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=.*$"#, options: .regularExpression) != nil
    }

    private struct ParsedOption {
        var name: String
        var inlineValue: String?
    }

    private static func parseOptionToken(_ token: String) -> [ParsedOption]? {
        if token.hasPrefix("--") {
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            guard Self.standaloneOptions.contains(name) || Self.optionsWithValue.contains(name) else {
                return nil
            }
            return [ParsedOption(name: name, inlineValue: parts.count > 1 ? String(parts[1]) : nil)]
        }
        guard token.range(of: #"^-[A-Za-z0-9]"#, options: .regularExpression) != nil else {
            return nil
        }
        var options: [ParsedOption] = []
        let characters = Array(token.dropFirst())
        for (offset, character) in characters.enumerated() {
            let name = "-\(character)"
            if Self.optionsWithValue.contains(name) {
                let rest = String(characters[(offset + 1)...])
                options.append(ParsedOption(name: name, inlineValue: rest.isEmpty ? nil : rest))
                return options
            }
            guard Self.standaloneOptions.contains(name) else {
                return nil
            }
            options.append(ParsedOption(name: name, inlineValue: nil))
        }
        return options.isEmpty ? nil : options
    }
}

/// Shell word helpers (upstream `src/utils/shell-argv.ts`).
public enum ExecShellWords {
    private static let doubleQuoteEscapes: Set<Character> = ["\\", "\"", "$", "`", "\n", "\r"]

    /// Splits a shell-like argv string into tokens (POSIX quoting; `#` starts a comment at a word start).
    /// - Parameter raw: Command text.
    /// - Returns: Tokens, or `nil` for unterminated quotes or a trailing escape.
    public static func split(_ raw: String) -> [String]? {
        var tokens: [String] = []
        var buffer = ""
        var inSingle = false
        var inDouble = false
        var escaped = false
        let characters = Array(raw)
        var index = 0
        func push() {
            if !buffer.isEmpty {
                tokens.append(buffer)
                buffer = ""
            }
        }
        while index < characters.count {
            let character = characters[index]
            defer { index += 1 }
            if escaped {
                buffer.append(character)
                escaped = false
                continue
            }
            if !inSingle, !inDouble, character == "\\" {
                escaped = true
                continue
            }
            if inSingle {
                if character == "'" {
                    inSingle = false
                } else {
                    buffer.append(character)
                }
                continue
            }
            if inDouble {
                if character == "\\", index + 1 < characters.count, Self.doubleQuoteEscapes.contains(characters[index + 1]) {
                    buffer.append(characters[index + 1])
                    index += 1
                    continue
                }
                if character == "\"" {
                    inDouble = false
                } else {
                    buffer.append(character)
                }
                continue
            }
            if character == "'" {
                inSingle = true
                continue
            }
            if character == "\"" {
                inDouble = true
                continue
            }
            if character == "#", buffer.isEmpty {
                break
            }
            if character.isWhitespace {
                push()
                continue
            }
            buffer.append(character)
        }
        if escaped || inSingle || inDouble {
            return nil
        }
        push()
        return tokens
    }

    /// Splits a command line on unquoted `;`, `&&`, `||`, `|` and newlines.
    ///
    /// Fails closed (`nil`) on unquoted command or process substitution (`$(`, backticks, `<(`, `>(`),
    /// redirections (`<`, `>`), background `&`, and unterminated quotes; `$(` and backticks inside
    /// double quotes also fail closed.
    /// - Parameter raw: Command text.
    /// - Returns: Trimmed, non-empty segments, or `nil`.
    public static func splitCommandChain(_ raw: String) -> [String]? {
        var segments: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false
        let characters = Array(raw)
        var index = 0
        func flush() -> Bool {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !trimmed.isEmpty else { return false }
            segments.append(trimmed)
            return true
        }
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if escaped {
                current.append(character)
                escaped = false
                index += 1
                continue
            }
            if !inSingle, character == "\\" {
                if next == "\n" {
                    // Line continuation.
                    index += 2
                    continue
                }
                current.append(character)
                escaped = true
                index += 1
                continue
            }
            if inSingle {
                if character == "'" { inSingle = false }
                current.append(character)
                index += 1
                continue
            }
            if inDouble {
                if character == "`" || (character == "$" && next == "(") {
                    return nil
                }
                if character == "\"" { inDouble = false }
                current.append(character)
                index += 1
                continue
            }
            switch character {
            case "'":
                inSingle = true
            case "\"":
                inDouble = true
            case "`":
                return nil
            case "$" where next == "(":
                return nil
            case "<", ">":
                return nil
            case ";", "\n", "\r":
                guard flush() || character != ";" else { return nil }
                index += 1
                continue
            case "|":
                guard flush() else { return nil }
                index += next == "|" ? 2 : 1
                continue
            case "&":
                guard next == "&", flush() else { return nil }
                index += 2
                continue
            default:
                break
            }
            current.append(character)
            index += 1
        }
        if escaped || inSingle || inDouble {
            return nil
        }
        _ = flush()
        return segments
    }
}

/// Allowlist matching (upstream `matchAllowlist` and the macOS `ExecAllowlistMatcher`).
public enum ExecAllowlistMatcher {
    /// Prefix of generated cwd-bound argv hashes.
    public static let cwdBoundArgPatternPrefix = "sha256:cwd-argv:v1:"
    /// Prefix of legacy argv hashes (never match).
    public static let legacyArgPatternPrefix = "sha256:argv:"

    /// Returns the first rule that authorizes `resolution`.
    ///
    /// A bare `*` rule without `argPattern` (not generated) matches any resolved command. Path
    /// patterns match the symlink-free trust path; basename patterns match only PATH-resolved commands.
    /// Rules with an `argPattern` must match the argv (generated grants only through their cwd-bound
    /// hash) and win over path-only rules; generated grants without a cwd-bound hash never match.
    /// Resolutions blocked by a wrapper only match rules for the wrapper itself.
    /// - Parameters:
    ///   - entries: Allowlist rules.
    ///   - resolution: Command resolution.
    /// - Returns: The matching rule, or `nil`.
    public static func match(entries: [ExecAllowlistEntry], resolution: ExecCommandResolution?) -> ExecAllowlistEntry? {
        guard let resolution, !entries.isEmpty else { return nil }
        if let wildcard = entries.first(where: {
            $0.pattern.trimmingCharacters(in: .whitespacesAndNewlines) == "*" && ($0.argPattern?.isEmpty ?? true) && !$0.isAllowAlways
        }) {
            return wildcard
        }
        guard resolution.resolvedRealPath?.isEmpty == false || resolution.resolvedPath?.isEmpty == false else {
            return nil
        }
        var pathOnlyMatch: ExecAllowlistEntry?
        var cwdBoundHash: String?
        for entry in entries {
            let pattern = entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            // Durable TypeScript command markers are metadata, never executable patterns.
            if pattern.isEmpty || pattern.hasPrefix("=command:") || pattern.hasPrefix("=node-command:") {
                continue
            }
            guard self.matchesExecutable(pattern: pattern, resolution: resolution) else { continue }
            guard let argPattern = entry.argPattern, !argPattern.isEmpty else {
                // Old generated grants were path-only and could authorize changed argv.
                if !entry.isAllowAlways, pathOnlyMatch == nil {
                    pathOnlyMatch = entry
                }
                continue
            }
            guard let argv = resolution.argv else { continue }
            if argPattern.hasPrefix(self.cwdBoundArgPatternPrefix) {
                guard let cwd = resolution.cwd else { continue }
                if cwdBoundHash == nil {
                    cwdBoundHash = self.cwdBoundArgPattern(argv: argv, cwd: cwd)
                }
                if argPattern == cwdBoundHash {
                    return entry
                }
            } else if !entry.isAllowAlways, self.matchesArgPattern(argPattern, argv: argv) {
                return entry
            }
        }
        return pathOnlyMatch
    }

    /// Matches every resolution; returns one rule per resolution, or an empty array when any misses.
    /// - Parameters:
    ///   - entries: Allowlist rules.
    ///   - resolutions: Resolutions (for example the segments of a command chain).
    /// - Returns: Matching rules, or `[]`.
    public static func matchAll(entries: [ExecAllowlistEntry], resolutions: [ExecCommandResolution]) -> [ExecAllowlistEntry] {
        guard !entries.isEmpty, !resolutions.isEmpty else { return [] }
        var matches: [ExecAllowlistEntry] = []
        for resolution in resolutions {
            guard let match = self.match(entries: entries, resolution: resolution) else {
                return []
            }
            matches.append(match)
        }
        return matches
    }

    /// The cwd-bound argv hash of a generated grant (`sha256:cwd-argv:v1:<hex>`, upstream
    /// `buildCwdBoundHashedArgPattern`); the cwd is canonicalized with ``ExecCommandResolution/canonicalApprovalCwd(_:)``.
    /// - Parameters:
    ///   - argv: Argv (the executable first; only arguments are hashed).
    ///   - cwd: Working directory.
    /// - Returns: The hashed arg pattern.
    public static func cwdBoundArgPattern(argv: [String], cwd: String) -> String {
        let normalizedCwd = ExecCommandResolution.canonicalApprovalCwd(cwd)
        let arguments = Array(argv.dropFirst())
        let argvSubject = "\(arguments.count)\0" + arguments.map { "\($0.utf8.count)\0\($0)\0" }.joined()
        let subject = "\(normalizedCwd.utf8.count)\0\(normalizedCwd)\0\(argvSubject)"
        return self.cwdBoundArgPatternPrefix + OpenClawCrypto.sha256Hex(Data(subject.utf8))
    }

    /// Builds the generated "always allow" grant for an approved command (upstream allow-always
    /// patterns): the trust path plus a cwd-bound argv hash, source `allow-always`.
    ///
    /// Returns `nil` for blocked wrappers, unresolved executables and interpreter-like targets (a
    /// durable grant would be too broad; configure a manual rule instead).
    /// - Parameters:
    ///   - resolution: Resolution of the approved command.
    ///   - commandText: Display text stored on the rule.
    /// - Returns: The grant, or `nil`.
    public static func allowAlwaysEntry(for resolution: ExecCommandResolution, commandText: String? = nil) -> ExecAllowlistEntry? {
        guard resolution.blockedWrapper == nil, !ExecCommandResolution.isInterpreterLikePersistentGrantTarget(resolution),
              let pattern = resolution.resolvedRealPath ?? resolution.resolvedPath, !pattern.isEmpty,
              let argv = resolution.argv
        else {
            return nil
        }
        return ExecAllowlistEntry(
            pattern: pattern,
            source: ExecAllowlistEntry.allowAlwaysSource,
            commandText: commandText,
            argPattern: self.cwdBoundArgPattern(argv: argv, cwd: resolution.cwd ?? FileManager.default.currentDirectoryPath)
        )
    }

    /// Whether an executable glob matches a target (upstream `matchesExecAllowlistPattern`).
    /// - Parameters:
    ///   - pattern: Glob (`*` within a segment, `**` across segments, `?` one character).
    ///   - target: Path or basename.
    /// - Returns: `true` on a match.
    public static func matches(pattern: String, target: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let expanded = trimmed.hasPrefix("~")
            ? OpenClawConfigDocumentStore.expandHome(trimmed, environment: ProcessInfo.processInfo.environment)
            : trimmed
        let normalizedPattern = self.normalizeMatchTarget(expanded)
        var normalizedTarget = self.normalizeMatchTarget(target)
        if expanded.contains("*") || expanded.contains("?"),
           normalizedTarget.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        {
            normalizedTarget = self.normalizeMatchTarget(URL(fileURLWithPath: normalizedTarget).standardizedFileURL.path)
        }
        guard let regex = self.globRegex(normalizedPattern) else { return false }
        return regex.firstMatch(in: normalizedTarget, range: NSRange(normalizedTarget.startIndex..., in: normalizedTarget)) != nil
    }

    static func hasPathSelector(_ value: String) -> Bool {
        value.contains("/") || value.contains("\\") || value.contains("~")
    }

    private static func matchesExecutable(pattern: String, resolution: ExecCommandResolution) -> Bool {
        if self.hasPathSelector(pattern) {
            guard let trustPath = resolution.resolvedRealPath ?? resolution.resolvedPath else { return false }
            return self.matches(pattern: pattern, target: trustPath)
        }
        // Bare names trust PATH-resolved commands only; `./rg` must use a path rule.
        guard pattern != "*", !self.hasPathSelector(resolution.rawExecutable) else { return false }
        var candidates: Set<String> = []
        if !resolution.executableName.isEmpty {
            candidates.insert(resolution.executableName)
        }
        if let resolvedPath = resolution.resolvedPath, !resolvedPath.isEmpty {
            candidates.insert(URL(fileURLWithPath: resolvedPath).lastPathComponent)
        }
        return candidates.contains { self.matches(pattern: pattern, target: $0) }
    }

    /// Generated patterns use NUL separators plus a trailing sentinel (`^\0\0$` for zero arguments);
    /// hand-authored patterns match the arguments joined with one space. Patterns follow JavaScript
    /// `RegExp` semantics (see ``ExecArgPatternRegex``).
    static func matchesArgPattern(_ argPattern: String, argv: [String]) -> Bool {
        if argPattern.hasPrefix(self.legacyArgPatternPrefix) {
            return false
        }
        let arguments = Array(argv.dropFirst())
        let subject: String
        if argPattern.contains("\0") {
            subject = arguments.isEmpty ? "\0\0" : arguments.joined(separator: "\0") + "\0"
        } else {
            subject = arguments.joined(separator: " ")
        }
        guard let regex = ExecArgPatternRegex.compile(argPattern) else { return false }
        return regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
    }

    private static func normalizeMatchTarget(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\\\\", with: "/")
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        if normalized == "/private/var" {
            return "/var"
        }
        if normalized.hasPrefix("/private/var/") {
            return String(normalized.dropFirst("/private".count))
        }
        #endif
        return normalized
    }

    private static func globRegex(_ pattern: String) -> NSRegularExpression? {
        var regex = "^"
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    regex += ".*"
                    index += 2
                } else {
                    regex += "[^/]*"
                    index += 1
                }
                continue
            }
            if character == "?" {
                regex += "[^/]"
                index += 1
                continue
            }
            regex += NSRegularExpression.escapedPattern(for: String(character))
            index += 1
        }
        regex += "\\z"
        return try? NSRegularExpression(pattern: regex)
    }
}

/// Compiles an `argPattern` written for JavaScript `RegExp` (no flags) into an ICU expression with
/// the same meaning, failing closed (`nil`) for syntax whose meaning differs.
///
/// Upstream evaluates `argPattern` with JavaScript (the macOS app uses JavaScriptCore). ICU accepts a
/// broader syntax, so a direct `NSRegularExpression` could authorize more than the gateway would.
/// This translator maps `\d`, `\w`, `\s`, `\b` and their negations to their ASCII/JS definitions,
/// maps `$` to end-of-input, and rejects ICU-only constructs (possessive quantifiers, atomic groups,
/// inline flags, `\A`/`\Z`/`\z`/`\G`/`\Q`, `\p{…}`, POSIX classes, nested sets, …).
public enum ExecArgPatternRegex {
    private static let jsWhitespaceClassBody = #"\t\n\x{0B}\f\r \x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}"#
    private static let wordClassBody = "A-Za-z0-9_"
    private static let wordBoundary = "(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))"
    private static let nonWordBoundary = "(?:(?<=[A-Za-z0-9_])(?=[A-Za-z0-9_])|(?<![A-Za-z0-9_])(?![A-Za-z0-9_]))"

    /// Compiles a JavaScript-semantics pattern.
    /// - Parameter pattern: JavaScript regular expression source.
    /// - Returns: The ICU expression, or `nil` when the pattern is invalid or not portable.
    public static func compile(_ pattern: String) -> NSRegularExpression? {
        guard let translated = self.translate(pattern) else { return nil }
        return try? NSRegularExpression(pattern: translated)
    }

    /// Translates JavaScript regular expression source into ICU source.
    /// - Parameter pattern: JavaScript regular expression source.
    /// - Returns: ICU source, or `nil` for unsupported syntax.
    public static func translate(_ pattern: String) -> String? {
        let characters = Array(pattern)
        var output = ""
        var index = 0
        var lastWasQuantifier = false
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            switch character {
            case "\\":
                guard let next, let escape = self.translateEscape(next, characters: characters, at: index + 1, inClass: false) else {
                    return nil
                }
                output += escape.text
                index = escape.nextIndex
                lastWasQuantifier = false
                continue
            case "[":
                guard let set = self.translateClass(characters, at: index) else { return nil }
                output += set.text
                index = set.nextIndex
                lastWasQuantifier = false
                continue
            case "(":
                if next == "?" {
                    let after = index + 2 < characters.count ? characters[index + 2] : nil
                    let afterNext = index + 3 < characters.count ? characters[index + 3] : nil
                    switch after {
                    case ":", "=", "!":
                        output += "(?\(after!)"
                        index += 3
                    case "<" where afterNext == "=" || afterNext == "!":
                        output += "(?<\(afterNext!)"
                        index += 4
                    case "<" where afterNext.map({ $0.isLetter || $0 == "_" || $0 == "$" }) == true:
                        output += "(?<"
                        index += 3
                    default:
                        return nil
                    }
                    lastWasQuantifier = false
                    continue
                }
                output.append(character)
            case "$":
                output += "\\z"
                index += 1
                lastWasQuantifier = false
                continue
            case "*", "+", "?":
                if lastWasQuantifier {
                    // `+` after a quantifier is possessive in ICU and a syntax error in JS; `?` is lazy in both.
                    guard character == "?" else { return nil }
                    output.append(character)
                    lastWasQuantifier = false
                    index += 1
                    continue
                }
                output.append(character)
                lastWasQuantifier = true
                index += 1
                continue
            case "{":
                guard let close = characters[index...].firstIndex(of: "}"),
                      String(characters[(index + 1)..<close]).range(of: #"^\d+(,\d*)?$"#, options: .regularExpression) != nil
                else {
                    // A literal `{` is valid in JS (non-unicode mode) but an error in ICU: escape it.
                    output += "\\{"
                    index += 1
                    lastWasQuantifier = false
                    continue
                }
                output += String(characters[index...close])
                index = close + 1
                lastWasQuantifier = true
                continue
            case "}":
                output += "\\}"
                index += 1
                lastWasQuantifier = false
                continue
            case "#", " ":
                // Literal in both engines (no `x` flag).
                output.append(character)
            case "\0":
                output += "\\x{00}"
                index += 1
                lastWasQuantifier = false
                continue
            default:
                output.append(character)
            }
            index += 1
            lastWasQuantifier = false
        }
        return output
    }

    private static func translateEscape(
        _ escaped: Character,
        characters: [Character],
        at index: Int,
        inClass: Bool
    ) -> (text: String, nextIndex: Int)? {
        let next = index + 1
        switch escaped {
        case "d": return (inClass ? "0-9" : "[0-9]", next)
        case "w": return (inClass ? self.wordClassBody : "[\(self.wordClassBody)]", next)
        case "s": return (inClass ? self.jsWhitespaceClassBody : "[\(self.jsWhitespaceClassBody)]", next)
        case "D": return inClass ? nil : ("[^0-9]", next)
        case "W": return inClass ? nil : ("[^\(self.wordClassBody)]", next)
        case "S": return inClass ? nil : ("[^\(self.jsWhitespaceClassBody)]", next)
        case "b": return (inClass ? "\\x{08}" : self.wordBoundary, next)
        case "B": return inClass ? nil : (self.nonWordBoundary, next)
        case "t": return ("\\t", next)
        case "n": return ("\\n", next)
        case "r": return ("\\r", next)
        case "f": return ("\\f", next)
        case "v": return ("\\x{0B}", next)
        case "0":
            // `\0` not followed by a digit is NUL; octal escapes differ between engines.
            if next < characters.count, characters[next].isNumber { return nil }
            return ("\\x{00}", next)
        case "x":
            guard next + 1 < characters.count, characters[next].isHexDigit, characters[next + 1].isHexDigit else { return nil }
            return ("\\x{\(characters[next])\(characters[next + 1])}", next + 2)
        case "u":
            guard next + 3 < characters.count, characters[next...(next + 3)].allSatisfy(\.isHexDigit) else { return nil }
            return ("\\x{\(String(characters[next...(next + 3)]))}", next + 4)
        case "c":
            guard next < characters.count, characters[next].isASCII, characters[next].isLetter else { return nil }
            return ("\\c\(characters[next])", next + 1)
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            return inClass ? nil : ("\\\(escaped)", next)
        case "k":
            return inClass ? nil : ("\\k", next)
        default:
            // Escaped punctuation is literal in both engines; letters and digits are not portable.
            guard !escaped.isLetter, !escaped.isNumber, escaped.isASCII else { return nil }
            return ("\\\(escaped)", next)
        }
    }

    private static func translateClass(_ characters: [Character], at start: Int) -> (text: String, nextIndex: Int)? {
        var index = start + 1
        var output = "["
        if index < characters.count, characters[index] == "^" {
            output += "^"
            index += 1
        }
        // `[]` and `[^]` have JS-only meanings.
        if index < characters.count, characters[index] == "]" {
            return nil
        }
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "]":
                return (output + "]", index + 1)
            case "\\":
                guard index + 1 < characters.count,
                      let escape = self.translateEscape(characters[index + 1], characters: characters, at: index + 1, inClass: true)
                else {
                    return nil
                }
                output += escape.text
                index = escape.nextIndex
                continue
            case "[", "&":
                // Literal in JS classes; ICU would read nested sets or intersections.
                output += "\\\(character)"
            case "\0":
                output += "\\x{00}"
            default:
                output.append(character)
            }
            index += 1
        }
        return nil
    }
}

/// POSIX path helpers for exec resolution.
enum ExecPathSupport {
    /// POSIX `realpath(3)` (symlinks resolved; `nil` when the path does not exist).
    static func canonicalPath(_ path: String) -> String? {
        #if canImport(Glibc) || canImport(Musl) || canImport(Darwin)
        guard !path.utf8.contains(0), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
        #else
        return nil
        #endif
    }
}
