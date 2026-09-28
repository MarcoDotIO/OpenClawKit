import Foundation

/// Renders skills into model prompt text.
///
/// ``catalog(skills:maxSkillsInPrompt:maxSkillsPromptChars:)`` ports upstream `prepareSkillsForPrompt`
/// (`src/skills/loading/skill-prompt-limits.ts`) and `formatSkillCatalog`
/// (`src/skills/loading/skill-contract.ts`): the v6 `<available_skills>` catalog, limited to 150 skills
/// and 18000 characters, falling back to a compact form with shortened (or omitted) descriptions.
public enum SkillPromptFormatter {
    /// Upstream `DEFAULT_MAX_SKILLS_IN_PROMPT`.
    public static let defaultMaxSkillsInPrompt = 150
    /// Upstream `DEFAULT_MAX_SKILLS_PROMPT_CHARS`.
    public static let defaultMaxSkillsPromptChars = 18_000
    /// Upstream `COMPACT_DESCRIPTION_MAX_CHARS`.
    public static let compactDescriptionMaxChars = 220
    private static let compactDescriptionMinChars = 4

    private enum Format {
        case full
        case compact(descriptionMaxChars: Int)
    }

    /// XML-escapes `& < > " '` (upstream `escapeSkillXml`).
    /// - Parameter value: Raw text.
    /// - Returns: Escaped text.
    public static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Reverses ``escapeXML(_:)``.
    /// - Parameter value: Escaped text.
    /// - Returns: Raw text.
    public static func unescapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Renders the v6 catalog within the prompt limits.
    /// - Parameters:
    ///   - skills: Prompt-visible skills (sorted by name unless `preserveOrder`).
    ///   - maxSkillsInPrompt: Maximum skills (default 150).
    ///   - maxSkillsPromptChars: Maximum characters (default 18000).
    ///   - preserveOrder: Keep the given order instead of sorting by name.
    /// - Returns: Prompt text and the skills it lists.
    public static func catalog(
        skills: [SkillDefinition],
        maxSkillsInPrompt: Int? = nil,
        maxSkillsPromptChars: Int? = nil,
        preserveOrder: Bool = false
    ) -> (prompt: String, skills: [SkillDefinition]) {
        let maxCount = maxSkillsInPrompt ?? self.defaultMaxSkillsInPrompt
        let maxChars = maxSkillsPromptChars ?? self.defaultMaxSkillsPromptChars
        let ordered = preserveOrder ? skills : skills.sorted(by: self.nameOrder)
        let total = ordered.count
        let byCount = Array(ordered.prefix(max(0, maxCount)))
        var selected = byCount

        func render(_ list: [SkillDefinition], _ format: Format, includeLimitNote: Bool = true) -> String? {
            let prompt = self.renderBounded(list, total: total, format: format, includeLimitNote: includeLimitNote)
            return prompt.utf16.count <= maxChars ? prompt : nil
        }
        func fitsCompact(_ list: [SkillDefinition], _ descriptionMax: Int, includeLimitNote: Bool = true) -> Bool {
            render(list, .compact(descriptionMaxChars: descriptionMax), includeLimitNote: includeLimitNote) != nil
        }

        if let full = render(selected, .full) {
            return (full, selected)
        }
        if !fitsCompact(selected, 0) {
            var low = 0
            var high = selected.count
            while low < high {
                let mid = (low + high + 1) / 2
                if fitsCompact(Array(selected.prefix(mid)), 0) { low = mid } else { high = mid - 1 }
            }
            selected = Array(selected.prefix(low))
        }
        if selected.isEmpty, !byCount.isEmpty {
            if let fullWithoutNote = render(byCount, .full, includeLimitNote: false) {
                return (fullWithoutNote, byCount)
            }
            var low = 0
            var high = byCount.count
            while low < high {
                let mid = (low + high + 1) / 2
                if fitsCompact(Array(byCount.prefix(mid)), 0, includeLimitNote: false) { low = mid } else { high = mid - 1 }
            }
            if low > 0 {
                selected = Array(byCount.prefix(low))
            }
        }
        let includeLimitNote = fitsCompact(selected, 0)
        var descriptionMax = 0
        if !selected.isEmpty, fitsCompact(selected, self.compactDescriptionMinChars, includeLimitNote: includeLimitNote) {
            var low = self.compactDescriptionMinChars
            var high = self.compactDescriptionMaxChars
            while low < high {
                let mid = (low + high + 1) / 2
                if fitsCompact(selected, mid, includeLimitNote: includeLimitNote) { low = mid } else { high = mid - 1 }
            }
            descriptionMax = low
        }
        let prompt = render(selected, .compact(descriptionMaxChars: descriptionMax), includeLimitNote: includeLimitNote) ?? ""
        return (prompt, prompt.isEmpty ? [] : selected)
    }

    /// Shrinks catalog descriptions so the prompt fits `contextTokenBudget / 5` characters
    /// (upstream `compactSkillsPromptForContext`; descriptions keep between 64 and 220 characters).
    /// - Parameters:
    ///   - prompt: Catalog prompt.
    ///   - contextTokenBudget: Model context budget in tokens.
    /// - Returns: The compacted prompt (unchanged when it already fits).
    public static func compactForContext(_ prompt: String, contextTokenBudget: Int?) -> String {
        guard let contextTokenBudget, contextTokenBudget > 0 else { return prompt }
        let targetChars = contextTokenBudget / 5
        guard prompt.utf16.count > targetChars,
              let start = prompt.range(of: "<available_skills>"),
              let end = prompt.range(of: "</available_skills>", range: start.upperBound..<prompt.endIndex)
        else {
            return prompt
        }
        let head = String(prompt[..<start.lowerBound])
        let catalog = String(prompt[start.lowerBound..<end.lowerBound])
        let tail = String(prompt[end.lowerBound...])
        func render(_ maxChars: Int) -> String {
            head + self.rewriteDescriptions(catalog) { description in
                self.escapeXML(self.truncateDescription(self.unescapeXML(description), maxChars: maxChars))
            } + tail
        }
        var low = 64
        var high = self.compactDescriptionMaxChars
        var result = render(low)
        while low <= high {
            let mid = (low + high) / 2
            let candidate = render(mid)
            if candidate.utf16.count <= targetChars {
                result = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result.utf16.count < prompt.utf16.count ? result : prompt
    }

    /// Legacy `## Skills` section with inlined bodies (used for models without tool calling).
    /// - Parameters:
    ///   - skills: Prompt-visible skills.
    ///   - entrypoint: Returns a skill's declared entrypoint, if any.
    /// - Returns: Prompt text (empty when there are no skills).
    public static func inlineBodies(skills: [SkillDefinition], entrypoint: (SkillDefinition) -> String? = { _ in nil }) -> String {
        guard !skills.isEmpty else { return "" }
        var lines: [String] = ["## Skills"]
        for skill in skills.sorted(by: { $0.name < $1.name }) {
            lines.append("")
            lines.append("### \(skill.name)")
            if !skill.description.isEmpty {
                lines.append(skill.description)
            }
            if let entry = entrypoint(skill) {
                lines.append("Entrypoint: \(entry)")
            }
            if !skill.body.isEmpty {
                lines.append(skill.body)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Rendering

    private static func renderBounded(_ skills: [SkillDefinition], total: Int, format: Format, includeLimitNote: Bool) -> String {
        let truncated = skills.count < total
        var note = ""
        if includeLimitNote {
            var compactDetails = ""
            if case .compact(let maxChars) = format {
                compactDetails = maxChars > 0 ? "descriptions shortened" : "descriptions omitted"
            }
            if truncated {
                let details = compactDetails.isEmpty ? "" : " (compact format, \(compactDetails))"
                note = "⚠️ Skills truncated: included \(skills.count) of \(total)\(details). Run `openclaw skills check` to audit."
            } else if !compactDetails.isEmpty {
                note = "⚠️ Skills catalog using compact format (\(compactDetails)). Run `openclaw skills check` to audit."
            }
        }
        let catalog: String
        switch format {
        case .full:
            catalog = self.formatCatalog(
                skills,
                loadingInstructions: "Read a skill's file at its listed location when the task matches its description."
            ) { $0.description }
        case .compact(let maxChars):
            let instructions = maxChars > 0
                ? "Read a skill's file at its listed location when the task matches its name or description."
                : "Read a skill's file at its listed location when the task matches its name."
            catalog = self.formatCatalog(skills, loadingInstructions: instructions) { skill in
                guard maxChars > 0 else { return nil }
                let truncated = self.truncateDescription(skill.description, maxChars: maxChars)
                return truncated.isEmpty ? nil : truncated
            }
        }
        return [note, catalog].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func formatCatalog(
        _ skills: [SkillDefinition],
        loadingInstructions: String,
        description: (SkillDefinition) -> String?
    ) -> String {
        guard !skills.isEmpty else { return "" }
        var lines = [
            "\n\nThe following skills provide specialized instructions for specific tasks.",
            loadingInstructions,
            "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) "
                + "and use that absolute path in tool commands.",
            "",
            "<available_skills>",
        ]
        for skill in skills {
            lines.append("  <skill>")
            lines.append("    <name>\(self.escapeXML(skill.name))</name>")
            if let text = description(skill) {
                lines.append("    <description>\(self.escapeXML(text))</description>")
            }
            lines.append("    <location>\(self.escapeXML(skill.filePath))</location>")
            lines.append("  </skill>")
        }
        lines.append("</available_skills>")
        return lines.joined(separator: "\n")
    }

    static func truncateDescription(_ description: String, maxChars: Int) -> String {
        let normalized = description
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.utf16.count <= maxChars {
            return normalized
        }
        if maxChars <= 3 {
            return self.truncateUTF16Safe(normalized, maxUnits: maxChars)
        }
        let head = self.truncateUTF16Safe(normalized, maxUnits: maxChars - 3)
        return head.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "..."
    }

    /// Truncates to at most `maxUnits` UTF-16 code units without splitting a surrogate pair.
    static func truncateUTF16Safe(_ text: String, maxUnits: Int) -> String {
        guard text.utf16.count > maxUnits else { return text }
        var result = ""
        var units = 0
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            if units + width > maxUnits { break }
            result.unicodeScalars.append(scalar)
            units += width
        }
        return result
    }

    private static func rewriteDescriptions(_ catalog: String, transform: (String) -> String) -> String {
        var output = ""
        var remainder = catalog[...]
        while let open = remainder.range(of: "<description>"), let close = remainder.range(of: "</description>", range: open.upperBound..<remainder.endIndex) {
            output += remainder[..<open.upperBound]
            output += transform(String(remainder[open.upperBound..<close.lowerBound]))
            output += remainder[close.lowerBound..<close.upperBound]
            remainder = remainder[close.upperBound...]
        }
        return output + remainder
    }

    static func nameOrder(_ lhs: SkillDefinition, _ rhs: SkillDefinition) -> Bool {
        let order = lhs.name.compare(rhs.name, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: Locale(identifier: "en"))
        if order != .orderedSame {
            return order == .orderedAscending
        }
        return lhs.name < rhs.name
    }
}
