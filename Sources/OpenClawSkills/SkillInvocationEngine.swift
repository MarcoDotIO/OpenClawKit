import Foundation
import OpenClawCore

/// Result payload from a matched skill invocation.
public struct SkillInvocationResult: Sendable, Equatable {
    /// Invoked skill name.
    public let skillName: String
    /// Raw skill output payload.
    public let output: String
    /// Executor backend that handled invocation.
    public let executorID: String?
    /// Total invocation runtime in milliseconds.
    public let durationMs: Int?

    /// Creates a skill invocation result.
    /// - Parameters:
    ///   - skillName: Invoked skill name.
    ///   - output: Raw output text.
    ///   - executorID: Executor backend identifier.
    ///   - durationMs: Invocation runtime in milliseconds.
    public init(skillName: String, output: String, executorID: String? = nil, durationMs: Int? = nil) {
        self.skillName = skillName
        self.output = output
        self.executorID = executorID
        self.durationMs = durationMs
    }
}

/// Pluggable executor contract for skill entrypoint execution.
public protocol SkillExecutor: Sendable {
    /// Stable executor identifier.
    var id: String { get }
    /// Returns whether the executor can handle a skill entrypoint.
    func canExecute(skill: SkillDefinition, entrypoint: URL) -> Bool
    /// Executes a skill entrypoint and returns raw output text.
    func execute(skill: SkillDefinition, entrypoint: URL, input: String) async throws -> String
}

private struct JavaScriptSkillExecutorBackend: SkillExecutor {
    let id: String
    let workspaceRoot: URL
    let executor: JSSkillExecutor

    func canExecute(skill: SkillDefinition, entrypoint: URL) -> Bool {
        let pathExtension = entrypoint.pathExtension.lowercased()
        if pathExtension == "js" || pathExtension == "mjs" || pathExtension == "cjs" {
            return true
        }
        let primaryEnv = (skill.metadata.primaryEnv ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return primaryEnv == "js" || primaryEnv == "javascript" || primaryEnv == "javascriptcore" || primaryEnv == "node"
    }

    func execute(skill _: SkillDefinition, entrypoint: URL, input: String) async throws -> String {
        let rootPath = self.workspaceRoot.standardizedFileURL.path
        let targetPath = entrypoint.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(prefix) else {
            throw OpenClawCoreError.invalidConfiguration("Skill entrypoint must stay within workspace root")
        }
        let relativePath = String(targetPath.dropFirst(prefix.count))
        let result = try await self.executor.executeFile(scriptPath: relativePath, input: input)
        let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOutput.isEmpty {
            return trimmedOutput
        }
        return result.logs.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct ProcessSkillExecutorBackend: SkillExecutor {
    let id: String
    let processRunner: ProcessRunner

    func canExecute(skill _: SkillDefinition, entrypoint _: URL) -> Bool {
        true
    }

    func execute(skill: SkillDefinition, entrypoint: URL, input: String) async throws -> String {
        let command = self.buildProcessCommand(
            entrypoint: entrypoint,
            pathExtension: entrypoint.pathExtension.lowercased(),
            primaryEnv: (skill.metadata.primaryEnv ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            input: input
        )
        let result = try await self.processRunner.run(command, cwd: entrypoint.deletingLastPathComponent())
        if result.exitCode != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpenClawCoreError.unavailable(
                "Skill '\(skill.name)' failed with exit code \(result.exitCode): \(message)"
            )
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout.isEmpty ? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) : stdout
    }

    private func buildProcessCommand(
        entrypoint: URL,
        pathExtension: String,
        primaryEnv: String,
        input: String
    ) -> [String] {
        var command: [String]
        if !primaryEnv.isEmpty {
            let normalizedPrimaryEnv: String
            switch primaryEnv {
            case "js", "javascript", "javascriptcore":
                normalizedPrimaryEnv = "node"
            default:
                normalizedPrimaryEnv = primaryEnv
            }
            let envParts = normalizedPrimaryEnv
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            command = ["/usr/bin/env"] + envParts + [entrypoint.path]
        } else {
            switch pathExtension {
            case "py":
                command = ["/usr/bin/env", "python3", entrypoint.path]
            case "sh":
                command = ["/usr/bin/env", "sh", entrypoint.path]
            case "js", "mjs", "cjs":
                command = ["/usr/bin/env", "node", entrypoint.path]
            default:
                command = [entrypoint.path]
            }
        }

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInput.isEmpty {
            command.append(trimmedInput)
        }
        return command
    }
}

private struct WASMSkillExecutorBackend: SkillExecutor {
    let id: String
    let workspaceRoot: URL
    let executor: WASMSkillExecutor

    func canExecute(skill: SkillDefinition, entrypoint: URL) -> Bool {
        let pathExtension = entrypoint.pathExtension.lowercased()
        if pathExtension == "wasm" {
            return true
        }
        let primaryEnv = (skill.metadata.primaryEnv ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return primaryEnv == "wasm" || primaryEnv == "wasi"
    }

    func execute(skill _: SkillDefinition, entrypoint: URL, input: String) async throws -> String {
        let rootPath = self.workspaceRoot.standardizedFileURL.path
        let targetPath = entrypoint.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(prefix) else {
            throw OpenClawCoreError.invalidConfiguration("Skill entrypoint must stay within workspace root")
        }
        let result = try await self.executor.executeModule(
            modulePath: entrypoint,
            input: input
        )
        return result.output
    }
}

/// Resolves and executes workspace skills for inbound user messages.
public actor SkillInvocationEngine {
    private struct InvocationMatch: Sendable {
        let skill: SkillDefinition
        let input: String
        let explicitCommand: Bool
    }

    private let workspaceRoot: URL
    private let registry: SkillRegistry
    private let executors: [any SkillExecutor]
    private let defaultInvocationTimeoutMs: Int

    /// Creates a skill invocation engine.
    /// - Parameters:
    ///   - workspaceRoot: Workspace root that contains skills.
    ///   - processRunner: Process execution runtime for non-JS entrypoints.
    ///   - invocationTimeoutMs: Default skill invocation timeout in milliseconds.
    ///   - executors: Optional explicit executor chain override.
    public init(
        workspaceRoot: URL,
        processRunner: ProcessRunner = ProcessRunner(),
        invocationTimeoutMs: Int = 30_000,
        executors: [any SkillExecutor]? = nil
    ) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.registry = SkillRegistry(workspaceRoot: self.workspaceRoot)
        self.defaultInvocationTimeoutMs = max(1, invocationTimeoutMs)
        if let executors, !executors.isEmpty {
            self.executors = executors
        } else {
            var defaults: [any SkillExecutor] = []
            if let jsExecutor = try? JSSkillExecutor(workspaceRoot: self.workspaceRoot) {
                defaults.append(
                    JavaScriptSkillExecutorBackend(
                        id: "javascript",
                        workspaceRoot: self.workspaceRoot,
                        executor: jsExecutor
                    )
                )
            }
            defaults.append(
                WASMSkillExecutorBackend(
                    id: "wasm",
                    workspaceRoot: self.workspaceRoot,
                    executor: WASMSkillExecutor(processRunner: processRunner)
                )
            )
            defaults.append(
                ProcessSkillExecutorBackend(
                    id: "process",
                    processRunner: processRunner
                )
            )
            self.executors = defaults
        }
    }

    /// Attempts to resolve and execute a skill from a user message.
    ///
    /// Supported invocation styles:
    /// - `/skill <name> [args]`
    /// - `/<name> [args]`
    /// - Natural-language references to discovered skill names.
    ///
    /// - Parameter message: Raw inbound message text.
    /// - Returns: Invocation result, or `nil` when no skill applies.
    public func invokeIfRequested(message: String) async throws -> SkillInvocationResult? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let skills = try await self.registry.loadSkills()
            .filter { $0.invocation.userInvocable }
        guard !skills.isEmpty else {
            return nil
        }

        if let explicit = self.resolveExplicitInvocation(from: trimmed, skills: skills) {
            return try await self.execute(match: explicit)
        }
        if let inferred = self.resolveInferredInvocation(from: trimmed, skills: skills) {
            do {
                return try await self.execute(match: inferred)
            } catch {
                // Avoid failing the full response for best-effort implicit invocation.
                return nil
            }
        }
        return nil
    }

    private func resolveExplicitInvocation(
        from message: String,
        skills: [SkillDefinition]
    ) -> InvocationMatch? {
        guard message.hasPrefix("/") else {
            return nil
        }
        let parts = message.split(
            maxSplits: 2,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        )
        guard let head = parts.first else {
            return nil
        }

        let command = String(head.dropFirst())
        guard !command.isEmpty else {
            return nil
        }

        var requestedSkillName = command
        var rawArgs: String = ""

        if command.caseInsensitiveCompare("skill") == .orderedSame {
            guard parts.count >= 2 else {
                return nil
            }
            requestedSkillName = String(parts[1])
            if parts.count >= 3 {
                rawArgs = String(parts[2])
            }
        } else if parts.count >= 2 {
            rawArgs = String(parts[1])
            if parts.count >= 3 {
                rawArgs += " " + String(parts[2])
            }
        }

        guard let skill = self.resolveSkill(named: requestedSkillName, in: skills) else {
            return nil
        }
        let normalizedInput = Self.normalizeExplicitInput(rawArgs)
        return InvocationMatch(skill: skill, input: normalizedInput, explicitCommand: true)
    }

    private func resolveInferredInvocation(
        from message: String,
        skills: [SkillDefinition]
    ) -> InvocationMatch? {
        let normalizedMessage = Self.normalizedNaturalLanguage(message)
        guard !normalizedMessage.isEmpty else {
            return nil
        }

        let sortedSkills = skills.sorted {
            Self.normalizedNaturalLanguage($0.name).count > Self.normalizedNaturalLanguage($1.name).count
        }

        for skill in sortedSkills {
            guard !skill.invocation.requiresExplicitInvocation else {
                continue
            }
            let token = Self.normalizedNaturalLanguage(skill.name)
            guard !token.isEmpty else {
                continue
            }
            if Self.message(normalizedMessage, containsSkillToken: token) {
                return InvocationMatch(skill: skill, input: message, explicitCommand: false)
            }
        }
        return nil
    }

    private func resolveSkill(named name: String, in skills: [SkillDefinition]) -> SkillDefinition? {
        let lookup = Self.normalizedSkillLookup(name)
        return skills.first { Self.normalizedSkillLookup($0.name) == lookup }
    }

    private func execute(match: InvocationMatch) async throws -> SkillInvocationResult {
        guard let entrypoint = try await self.registry.resolveEntrypoint(for: match.skill) else {
            throw OpenClawCoreError.invalidConfiguration(
                "Skill '\(match.skill.name)' is missing an entrypoint"
            )
        }
        let execution = try await self.executeEntrypoint(
            skill: match.skill,
            entrypoint: entrypoint,
            input: match.input
        )
        let trimmedOutput = execution.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOutput.isEmpty && match.explicitCommand {
            throw OpenClawCoreError.unavailable("Skill '\(match.skill.name)' returned no output")
        }
        return SkillInvocationResult(
            skillName: match.skill.name,
            output: trimmedOutput,
            executorID: execution.executorID,
            durationMs: execution.durationMs
        )
    }

    private func executeEntrypoint(
        skill: SkillDefinition,
        entrypoint: URL,
        input: String
    ) async throws -> (output: String, executorID: String, durationMs: Int) {
        guard let executor = self.executors.first(where: { $0.canExecute(skill: skill, entrypoint: entrypoint) }) else {
            throw OpenClawCoreError.unavailable("No skill executor available for '\(skill.name)'")
        }
        let timeoutMs = self.resolveTimeoutMs(for: skill)
        let startedAt = Date()
        let output = try await self.executeWithTimeout(timeoutMs: timeoutMs) {
            try await executor.execute(skill: skill, entrypoint: entrypoint, input: input)
        }
        let durationMs = Int(max(0, Date().timeIntervalSince(startedAt) * 1_000))
        return (output, executor.id, durationMs)
    }

    private func executeWithTimeout(
        timeoutMs: Int,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let timeoutNs = UInt64(max(1, timeoutMs)) * 1_000_000
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw OpenClawCoreError.unavailable("Skill execution timed out after \(timeoutMs)ms")
            }
            guard let result = try await group.next() else {
                throw OpenClawCoreError.unavailable("Skill execution timed out after \(timeoutMs)ms")
            }
            group.cancelAll()
            return result
        }
    }

    private func resolveTimeoutMs(for skill: SkillDefinition) -> Int {
        let keys = ["timeoutMs", "timeout-ms", "timeout_ms"]
        for key in keys {
            if let raw = skill.frontmatter[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               let value = Int(raw),
               value > 0
            {
                return value
            }
        }
        return self.defaultInvocationTimeoutMs
    }

    private static func normalizedSkillLookup(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
    }

    private static func normalizedNaturalLanguage(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func message(_ normalizedMessage: String, containsSkillToken token: String) -> Bool {
        let paddedMessage = " " + normalizedMessage + " "
        let paddedToken = " " + token + " "
        return paddedMessage.contains(paddedToken)
    }

    private static func normalizeExplicitInput(_ rawArgs: String) -> String {
        rawArgs.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
