import Foundation
import Testing
@testable import OpenClawCore

@Suite("Exec allowlist rules (upstream parity)", .serialized)
struct ExecAllowlistRulesTests {
    private static func resolution(
        _ executable: String,
        name: String? = nil,
        raw: String? = nil,
        realPath: String? = nil,
        cwd: String? = nil,
        argv: [String]? = nil
    ) -> ExecCommandResolution {
        ExecCommandResolution(
            rawExecutable: raw ?? executable,
            resolvedPath: executable,
            resolvedRealPath: realPath ?? executable,
            executableName: name ?? URL(fileURLWithPath: executable).lastPathComponent,
            cwd: cwd,
            argv: argv
        )
    }

    private static let homebrewRG = ExecCommandResolution(
        rawExecutable: "rg",
        resolvedPath: "/opt/homebrew/bin/rg",
        executableName: "rg",
        cwd: nil
    )

    // MARK: Entries

    @Test
    func entriesRoundTripSourceAndCommandText() throws {
        let entry = ExecAllowlistEntry(
            id: "e1",
            pattern: "/usr/bin/printf",
            source: ExecAllowlistEntry.allowAlwaysSource,
            commandText: "printf ok",
            argPattern: "sha256:cwd-argv:v1:abc",
            lastUsedAt: Int64(4_102_444_800_000),
            lastUsedCommand: "printf ok",
            lastResolvedPath: "/usr/bin/printf"
        )
        let decoded = try JSONDecoder().decode(ExecAllowlistEntry.self, from: try JSONEncoder().encode(entry))
        #expect(decoded == entry)
        #expect(decoded.isAllowAlways)
        // Legacy bare strings and Node's floating `Date.now()` values decode.
        let legacy = try JSONDecoder().decode([ExecAllowlistEntry].self, from: Data(#"[" /usr/bin/rg ", {"pattern": "x", "lastUsedAt": 1700000000000.4}]"#.utf8))
        #expect(legacy[0].pattern == "/usr/bin/rg")
        #expect(legacy[1].lastUsedAt == Int64(1_700_000_000_000))
    }

    // MARK: Pattern matching

    @Test
    func matchesResolvedPathsBasenamesAndGlobs() {
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: "/opt/homebrew/bin/rg")], resolution: Self.homebrewRG) != nil)
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: "rg")], resolution: Self.homebrewRG) != nil)
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: "r?")], resolution: Self.homebrewRG) != nil)
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: "/opt/**/rg")], resolution: Self.homebrewRG) != nil)
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: "/OPT/HOMEBREW/BIN/RG")], resolution: Self.homebrewRG) == nil)
        let slash = Self.resolution("/tmp/a/b")
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: "/tmp/a?b")], resolution: slash) == nil)
        // A bare `*` (not generated, no argPattern) allows any resolved command.
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: "*")], resolution: Self.homebrewRG) != nil)
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: "*", source: "allow-always")], resolution: Self.homebrewRG) == nil)
    }

    @Test
    func basenamesNeverTrustPathSelectedExecutablesOrCommandMarkers() {
        let entry = ExecAllowlistEntry(pattern: "echo")
        let relative = Self.resolution("/tmp/oc-basename/echo", raw: "./echo", cwd: "/tmp/oc-basename")
        let absolute = Self.resolution("/tmp/oc-basename/echo", cwd: "/tmp/oc-basename")
        #expect(ExecAllowlistMatcher.match(entries: [entry], resolution: relative) == nil)
        #expect(ExecAllowlistMatcher.match(entries: [entry], resolution: absolute) == nil)
        for marker in ["=command:0123456789abcdef", "=node-command:0123456789abcdef"] {
            let markerEntry = ExecAllowlistEntry(pattern: marker, source: "allow-always")
            let resolution = Self.resolution("/Users/test/.local/bin/\(marker)", name: marker, raw: marker)
            #expect(ExecAllowlistMatcher.match(entries: [markerEntry], resolution: resolution) == nil)
        }
    }

    @Test
    func handAuthoredArgPatternsWinOverPathOnlyFallback() {
        let executable = "/usr/bin/python3"
        let fallback = ExecAllowlistEntry(id: "fallback", pattern: executable)
        let restricted = ExecAllowlistEntry(id: "restricted", pattern: executable, argPattern: #"^safe\.py$"#)
        let safe = Self.resolution(executable, argv: [executable, "safe.py"])
        let unsafe = Self.resolution(executable, argv: [executable, "unsafe.py"])
        #expect(ExecAllowlistMatcher.match(entries: [fallback, restricted], resolution: safe)?.id == "restricted")
        #expect(ExecAllowlistMatcher.match(entries: [fallback, restricted], resolution: unsafe)?.id == "fallback")
        #expect(ExecAllowlistMatcher.match(entries: [restricted], resolution: unsafe) == nil)
    }

    @Test
    func legacyGeneratedGrantsNeverMatch() {
        let executable = "/usr/bin/python3"
        let resolution = Self.resolution(executable, argv: [executable, "unsafe.py"])
        for entry in [
            ExecAllowlistEntry(pattern: executable, source: "allow-always"),
            ExecAllowlistEntry(pattern: executable, source: "allow-always", argPattern: "sha256:argv:obsolete"),
            ExecAllowlistEntry(pattern: executable, source: "allow-always", argPattern: #"^unsafe\.py$"#),
        ] {
            #expect(ExecAllowlistMatcher.match(entries: [entry], resolution: resolution) == nil)
        }
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: executable)], resolution: resolution) != nil)
    }

    @Test
    func generatedNulArgPatternsIncludingZeroArgs() {
        let executable = "/usr/bin/printf"
        let zeroArgs = ExecAllowlistEntry(pattern: executable, argPattern: "^\0\0$")
        let oneArg = ExecAllowlistEntry(pattern: executable, argPattern: "^hello world\0$")
        let base = Self.resolution(executable, argv: [executable])
        let withSpace = Self.resolution(executable, argv: [executable, "hello world"])
        #expect(ExecAllowlistMatcher.match(entries: [zeroArgs], resolution: base) != nil)
        #expect(ExecAllowlistMatcher.match(entries: [oneArg], resolution: withSpace) != nil)
        #expect(ExecAllowlistMatcher.match(entries: [zeroArgs], resolution: withSpace) == nil)
    }

    @Test
    func cwdBoundHashesMatchTheSharedVectorAndBindArgvAndCwd() {
        let vector = "sha256:cwd-argv:v1:2b4f4aed226aa1fd771c852b8f74e4c162d440aafaf60bfef19746f3b2ee5890"
        #expect(ExecAllowlistMatcher.cwdBoundArgPattern(argv: ["/usr/bin/printf", "hello world", ""], cwd: "/workspace") == vector)

        let executable = "/usr/bin/curl"
        let approvedArgv = [executable, "https://trusted.example/install.sh"]
        let entry = ExecAllowlistEntry(
            pattern: executable,
            source: "allow-always",
            argPattern: ExecAllowlistMatcher.cwdBoundArgPattern(argv: approvedArgv, cwd: "/workspace")
        )
        #expect(ExecAllowlistMatcher.match(entries: [entry], resolution: Self.resolution(executable, cwd: "/workspace", argv: approvedArgv)) != nil)
        let changed = Self.resolution(executable, cwd: "/workspace", argv: [executable, entry.argPattern ?? "", "https://attacker.example/x"])
        #expect(ExecAllowlistMatcher.match(entries: [entry], resolution: changed) == nil)
        let moved = Self.resolution(executable, cwd: "/other-workspace", argv: approvedArgv)
        #expect(ExecAllowlistMatcher.match(entries: [entry], resolution: moved) == nil)
        #expect(entry.argPattern?.contains("trusted.example") == false)

        let zero = ExecAllowlistMatcher.cwdBoundArgPattern(argv: ["/usr/bin/tool"], cwd: "/workspace")
        #expect(zero != ExecAllowlistMatcher.cwdBoundArgPattern(argv: ["/usr/bin/tool", "", ""], cwd: "/workspace"))
    }

    @Test
    func argPatternsUseJavaScriptRegExpSemanticsAndFailClosed() {
        let executable = "/usr/bin/printf"
        func matches(_ pattern: String, _ argument: String) -> Bool {
            ExecAllowlistMatcher.match(
                entries: [ExecAllowlistEntry(pattern: executable, argPattern: pattern)],
                resolution: Self.resolution(executable, argv: [executable, argument])
            ) != nil
        }
        #expect(matches(#"^\d$"#, "1"))
        #expect(!matches(#"^\d$"#, "١"))
        #expect(matches(#"^\w$"#, "a"))
        #expect(!matches(#"^\w$"#, "é"))
        #expect(matches("^safe$", "safe"))
        #expect(!matches("^safe$", "safe\n"))
        #expect(matches(#"^a\b"#, "a b"))
        // JavaScript `\b` is ASCII-based: `é` is a non-word character there (ICU would disagree).
        #expect(matches(#"^é\b"#, "éa"))
        #expect(matches("^a{2}$", "aa"))
        #expect(matches("^a{$", "a{"))
        #expect(matches(#"^(?<name>x)\k<name>$"#, "xx"))
        #expect(matches(#"^[\d_]+$"#, "1_2"))
        for icuOnly in [#"^a++$"#, #"^(?>a)$"#, #"(?i)^A$"#, #"^\Aa"#, #"\p{L}"#, #"^[[:alpha:]]$"#, "[", "^a**$"] {
            #expect(!matches(icuOnly, "aa"), "\(icuOnly) must fail closed")
        }
        // Redirect-shaped argv literals stay authorization-significant.
        let redirect = Self.resolution("/usr/bin/python3", argv: ["/usr/bin/python3", "safe.py", "2>/dev/null"])
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: "/usr/bin/python3", argPattern: #"^safe\.py$"#)], resolution: redirect) == nil)
        #expect(ExecAllowlistMatcher.match(
            entries: [ExecAllowlistEntry(pattern: "/usr/bin/python3", argPattern: #"^safe\.py 2>/dev/null$"#)],
            resolution: redirect
        ) != nil)
        // No argv: argPattern rules never match.
        let noArgv = Self.resolution(executable)
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: executable, argPattern: "^ok$")], resolution: noArgv) == nil)
    }

    #if os(macOS)
    @Test
    func privateVarAliasMatchesOnApplePlatforms() {
        let resolution = Self.resolution("/var/tmp/openclaw-tool", realPath: "/private/var/tmp/openclaw-tool")
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: "/var/tmp/openclaw-tool")], resolution: resolution) != nil)
    }
    #endif

    // MARK: env unwrapping

    @Test
    func envInvocationsUnwrapLikeUpstream() {
        #expect(ExecEnvInvocation.unwrap(["env", "FOO=bar", "bash", "-lc", "echo hi"]) == ["bash", "-lc", "echo hi"])
        #expect(ExecEnvInvocation.unwrap(["env", "-i", "--unset", "PATH", "--", "sh", "-lc", "echo hi"]) == ["sh", "-lc", "echo hi"])
        #expect(ExecEnvInvocation.unwrap(["env", "--chdir=/tmp", "pwsh", "-Command", "Get-Date"]) == ["pwsh", "-Command", "Get-Date"])
        #expect(ExecEnvInvocation.unwrap(["env", "-P", "/usr/bin", "python3", "-c", "print(1)"]) == ["python3", "-c", "print(1)"])
        #expect(ExecEnvInvocation.unwrap(["env", "-S", "python3 -c", "print(1)"]) == ["python3", "-c", "print(1)"])
        #expect(ExecEnvInvocation.unwrap(["env", "--split-string=python3 -c", "print(1)"]) == ["python3", "-c", "print(1)"])
        #expect(ExecEnvInvocation.unwrap(["env", "-Spython3 -c", "print(1)"]) == ["python3", "-c", "print(1)"])
        #expect(ExecEnvInvocation.unwrap(["env", "-", "bash", "-lc", "echo hi"]) == ["bash", "-lc", "echo hi"])
        #expect(ExecEnvInvocation.unwrap(["env", "--bogus", "bash", "-lc", "echo hi"]) == nil)
        #expect(ExecEnvInvocation.unwrap(["env", "--unset"]) == nil)
        #expect(ExecEnvInvocation.usesModifiers(["env", "-P", "/usr/bin", "python3"]))
        #expect(!ExecEnvInvocation.usesModifiers(["/usr/bin/env", "python3"]))
    }

    @Test
    func resolutionUnwrapsTransparentEnvAndStaysBoundToModifiedEnv() throws {
        let path = ["PATH": "/usr/bin:/bin"]
        let transparent = try #require(ExecCommandResolution.resolve(argv: ["/usr/bin/env", "printf", "ok"], environment: path))
        #expect(transparent.executableName == "printf")
        #expect(transparent.argv == ["printf", "ok"])
        #expect(transparent.blockedWrapper == nil)

        // `env -P <dir>` changes executable lookup: the resolution stays bound to env itself.
        let lookup = try #require(ExecCommandResolution.resolve(argv: ["/usr/bin/env", "-P", "/tmp/evil", "printf", "ok"], environment: path))
        #expect(lookup.blockedWrapper == "env")
        #expect(lookup.executableName == "env")
        let printfRule = ExecAllowlistEntry(pattern: transparent.resolvedRealPath ?? "/usr/bin/printf")
        #expect(ExecAllowlistMatcher.match(entries: [printfRule], resolution: lookup) == nil)
        #expect(ExecAllowlistMatcher.allowAlwaysEntry(for: lookup) == nil)

        let shell = try #require(ExecCommandResolution.resolve(argv: ["/bin/sh", "-lc", "printf ok"], environment: path))
        #expect(shell.blockedWrapper == "sh")
    }

    // MARK: Command lines

    @Test
    func commandChainsRequireEverySegmentAndFailClosedOnSubstitution() throws {
        #expect(ExecShellWords.splitCommandChain("ls -la && grep x file | wc -l; echo done") == ["ls -la", "grep x file", "wc -l", "echo done"])
        #expect(ExecShellWords.splitCommandChain("echo 'a && b'") == ["echo 'a && b'"])
        for unsafe in ["echo $(id)", "echo `id`", "echo \"$(id)\"", "cat < /etc/passwd", "echo hi > out", "sleep 1 &", "echo 'open", ";;"] {
            #expect(ExecShellWords.splitCommandChain(unsafe) == nil, "\(unsafe) must fail closed")
        }
        #expect(ExecShellWords.split(#"printf "a b" 'c d' e\ f # comment"#) == ["printf", "a b", "c d", "e f"])
        #expect(ExecShellWords.split("echo \"unterminated") == nil)

        let path = ["PATH": "/usr/bin:/bin"]
        let echo = try #require(ExecCommandResolution.resolve(argv: ["echo"], environment: path))
        let evaluator = ExecAllowlistEvaluator(
            entries: [ExecAllowlistEntry(pattern: echo.resolvedRealPath ?? "/bin/echo")],
            environment: path
        )
        #expect(evaluator.allows(commandText: "echo hi"))
        #expect(evaluator.allows(commandText: "echo a && echo b"))
        #expect(!evaluator.allows(commandText: "echo a && rm -rf /tmp/x"))
        #expect(!evaluator.allows(commandText: "echo $(rm -rf /tmp/x)"))
    }

    // MARK: Realpath and allow-always

    @Test
    func symlinkedExecutablesMatchTheirCanonicalTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oc-exec-allow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("real-tool")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: target.path)
        let link = root.appendingPathComponent("tool-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let resolution = try #require(ExecCommandResolution.resolve(argv: [link.path], environment: [:]))
        let canonicalTarget = try #require(ExecCommandResolution.resolve(argv: [target.path], environment: [:])?.resolvedRealPath)
        #expect(resolution.resolvedRealPath == canonicalTarget)
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: canonicalTarget)], resolution: resolution) != nil)
        // A rule for the link path does not authorize the symlink's target identity.
        #expect(ExecAllowlistMatcher.match(entries: [ExecAllowlistEntry(pattern: link.path)], resolution: resolution) == nil)
    }

    @Test
    func allowAlwaysGrantsBindArgvAndSkipInterpreters() async throws {
        let path = ["PATH": "/usr/bin:/bin"]
        let security = SecurityRuntime()
        let grant = try #require(try await security.recordAllowAlways(argv: ["printf", "safe_marker"], cwd: "/", commandText: "printf safe_marker", environment: path))
        #expect(grant.isAllowAlways)
        #expect(grant.commandText == "printf safe_marker")
        #expect(grant.argPattern?.hasPrefix(ExecAllowlistMatcher.cwdBoundArgPatternPrefix) == true)
        // Recording the same approval again reuses the grant.
        #expect(try await security.recordAllowAlways(argv: ["printf", "safe_marker"], cwd: "/", environment: path)?.id == grant.id)
        #expect(try await security.execAllowlist().count == 1)

        let matched = try await security.evaluateExec(argv: ["printf", "safe_marker"], cwd: "/", environment: path)
        #expect(matched?.id == grant.id)
        #expect((matched?.lastUsedAt ?? 0) > Int64(0))
        #expect(try await security.evaluateExec(argv: ["printf", "other"], cwd: "/", environment: path) == nil)

        for interpreter in ["sed", "awk", "python3", "node", "perl", "xargs", "find"] {
            #expect(try await security.recordAllowAlways(argv: [interpreter, "inline-program"], cwd: "/", environment: path) == nil)
        }
        let r2 = ExecCommandResolution(rawExecutable: "r2", resolvedPath: "/usr/local/bin/r2", resolvedRealPath: "/usr/local/bin/r2", executableName: "r2", cwd: nil, argv: ["r2"])
        #expect(!ExecCommandResolution.isInterpreterLikePersistentGrantTarget(r2))
        #expect(ExecCommandResolution.isInterpreterLikePersistentGrantTarget(Self.resolution("/usr/bin/python3.13")))
    }

    @Test
    func allowlistsPersistThroughTheStoreSeam() async throws {
        final class MemoryStore: ExecAllowlistPersisting, @unchecked Sendable {
            let lock = NSLock()
            var stored: [String: [ExecAllowlistEntry]] = [:]
            func loadAllowlist(agentID: String) throws -> [ExecAllowlistEntry] {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.stored[agentID] ?? []
            }
            func saveAllowlist(_ entries: [ExecAllowlistEntry], agentID: String) throws {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.stored[agentID] = entries
            }
        }
        let store = MemoryStore()
        store.stored["ops"] = [ExecAllowlistEntry(id: "seed", pattern: "*")]
        let security = SecurityRuntime(allowlistStore: store)
        #expect(try await security.execAllowlist(agentID: "ops").map(\.id) == ["seed"])
        try await security.addExecAllowlistEntry(ExecAllowlistEntry(id: "rg", pattern: "rg", commandText: "rg foo"), agentID: "ops")
        #expect(try store.loadAllowlist(agentID: "ops").map(\.id) == ["seed", "rg"])
        #expect(try store.loadAllowlist(agentID: "ops").last?.commandText == "rg foo")
        let evaluator = try await security.allowlistEvaluator(agentID: "ops", environment: ["PATH": "/usr/bin:/bin"])
        #expect(evaluator.allows(commandText: "ls"))
    }
}
