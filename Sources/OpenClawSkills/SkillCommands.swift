import Foundation

/// Slash command derived from a user-invocable skill (upstream `SkillCommandSpec`).
public struct SkillCommandSpec: Sendable, Equatable, Codable {
    /// Sanitized, de-duplicated command name (without the leading `/`).
    public let name: String
    /// Skill name.
    public let skillName: String
    /// Display title (first H1 or name).
    public let displayName: String
    /// Command description (skill description, or the name).
    public let description: String
    /// SKILL.md path.
    public let skillFile: String
    /// Whether the skill is listed in the model prompt.
    public let modelVisible: Bool
    /// Tool dispatch, when the skill declares `command-dispatch: tool`.
    public let dispatch: SkillCommandDispatch?

    /// Creates a command spec.
    /// - Parameters:
    ///   - name: Command name.
    ///   - skillName: Skill name.
    ///   - displayName: Display title.
    ///   - description: Description.
    ///   - skillFile: SKILL.md path.
    ///   - modelVisible: Model visibility.
    ///   - dispatch: Tool dispatch.
    public init(
        name: String,
        skillName: String,
        displayName: String,
        description: String,
        skillFile: String,
        modelVisible: Bool,
        dispatch: SkillCommandDispatch? = nil
    ) {
        self.name = name
        self.skillName = skillName
        self.displayName = displayName
        self.description = description
        self.skillFile = skillFile
        self.modelVisible = modelVisible
        self.dispatch = dispatch
    }
}

/// Skill slash-command naming (upstream `src/skills/discovery/command-name.ts` and `command-specs.ts`).
public enum SkillCommandNaming {
    /// Maximum command name length (upstream `SKILL_COMMAND_MAX_LENGTH`).
    public static let maxLength = 32

    /// Sanitizes a skill name into a command name: lowercase, runs of `[^a-z0-9_]` become `_`,
    /// repeated `_` collapse, leading/trailing `_` trimmed, at most 32 characters, fallback `skill`.
    /// - Parameter raw: Skill name.
    /// - Returns: Command name.
    public static func sanitize(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let replaced = lowered
            .replacingOccurrences(of: "[^a-z0-9_]+", with: "_", options: .regularExpression)
            .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
            .replacingOccurrences(of: "^_+|_+$", with: "", options: .regularExpression)
        let truncated = String(replaced.prefix(self.maxLength))
        return truncated.isEmpty ? "skill" : truncated
    }

    /// Returns `base` or the first free `base_2`, `base_3`, … (kept within 32 characters).
    /// - Parameters:
    ///   - base: Sanitized base name.
    ///   - used: Lowercased names already taken.
    /// - Returns: A unique name.
    public static func unique(_ base: String, used: Set<String>) -> String {
        guard used.contains(base.lowercased()) else { return base }
        for index in 2..<1000 {
            let suffix = "_\(index)"
            let candidate = String(base.prefix(max(1, self.maxLength - suffix.count))) + suffix
            if !used.contains(candidate.lowercased()) {
                return candidate
            }
        }
        return String(base.prefix(max(1, self.maxLength - 2))) + "_x"
    }

    /// Builds command specs for user-invocable skills in order, de-duplicating sanitized names.
    /// - Parameters:
    ///   - skills: Skills (only user-invocable ones produce commands).
    ///   - reservedNames: Names that must not be reused (for example native commands).
    ///   - modelVisible: Whether a skill is listed in the model prompt.
    /// - Returns: Command specs.
    public static func commandSpecs(
        for skills: [SkillDefinition],
        reservedNames: [String] = [],
        modelVisible: (SkillDefinition) -> Bool = { !$0.invocation.disableModelInvocation }
    ) -> [SkillCommandSpec] {
        var used = Set(reservedNames.map { $0.lowercased() })
        var specs: [SkillCommandSpec] = []
        for skill in skills where skill.invocation.userInvocable {
            let unique = self.unique(self.sanitize(skill.name), used: used)
            used.insert(unique.lowercased())
            let description = skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
            specs.append(
                SkillCommandSpec(
                    name: unique,
                    skillName: skill.name,
                    displayName: skill.displayName,
                    description: description.isEmpty ? skill.name : description,
                    skillFile: skill.filePath,
                    modelVisible: modelVisible(skill),
                    dispatch: skill.commandDispatch
                )
            )
        }
        return specs
    }
}
