import Foundation

/// Recoverable problem found while parsing SKILL.md frontmatter.
public struct SkillFrontmatterIssue: Codable, Sendable, Equatable {
    /// Machine-readable code (for example `UNTERMINATED_FRONTMATTER`, `BAD_INDENT`).
    public let code: String
    /// Human-readable message.
    public let message: String

    /// Creates an issue.
    /// - Parameters:
    ///   - code: Issue code.
    ///   - message: Issue message.
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Result of parsing a SKILL.md file's frontmatter.
public struct ParsedSkillFrontmatter: Sendable, Equatable {
    /// Flat frontmatter map; structured YAML values are re-serialized as compact JSON strings.
    public let frontmatter: [String: String]
    /// Markdown body after the closing delimiter (the whole normalized file when there is no block).
    public let body: String
    /// Recoverable parse issues.
    public let issues: [SkillFrontmatterIssue]

    /// Creates a parse result.
    /// - Parameters:
    ///   - frontmatter: Flat frontmatter.
    ///   - body: Markdown body.
    ///   - issues: Issues.
    public init(frontmatter: [String: String], body: String, issues: [SkillFrontmatterIssue] = []) {
        self.frontmatter = frontmatter
        self.body = body
        self.issues = issues
    }
}

/// Public entry point for parsing SKILL.md frontmatter (upstream `packages/markdown-core` frontmatter).
public enum SkillFrontmatter {
    /// Parses a SKILL.md document.
    ///
    /// The BOM is stripped and CRLF/CR normalized. The block must open with `---` on the first line
    /// and closes at the next `---` line (trailing spaces allowed). An unterminated block yields empty
    /// frontmatter plus an `UNTERMINATED_FRONTMATTER` issue.
    /// - Parameter content: File contents.
    /// - Returns: Frontmatter, body and issues.
    public static func parse(_ content: String) -> ParsedSkillFrontmatter {
        SkillFrontmatterParser.parseDetailed(content)
    }
}

enum SkillFrontmatterParser {
    static func parse(_ content: String) -> (frontmatter: [String: String], body: String) {
        let parsed = self.parseDetailed(content)
        return (parsed.frontmatter, parsed.body)
    }

    static func normalize(_ content: String) -> String {
        var text = content
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func extractBlock(_ normalized: String) -> (block: String, body: String)? {
        let lines = normalized.components(separatedBy: "\n")
        guard let first = lines.first, Self.isDelimiter(first) else { return nil }
        guard let closing = lines.dropFirst().firstIndex(where: Self.isDelimiter) else { return nil }
        let block = lines[1..<closing].joined(separator: "\n")
        let body = lines[(closing + 1)...].joined(separator: "\n")
        return (block, body)
    }

    private static func isDelimiter(_ line: String) -> Bool {
        guard line.hasPrefix("---") else { return false }
        return line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func parseDetailed(_ content: String) -> ParsedSkillFrontmatter {
        let normalized = self.normalize(content)
        guard let extracted = self.extractBlock(normalized) else {
            if let first = normalized.components(separatedBy: "\n").first, self.isDelimiter(first) {
                return ParsedSkillFrontmatter(
                    frontmatter: [:],
                    body: normalized,
                    issues: [SkillFrontmatterIssue(code: "UNTERMINATED_FRONTMATTER", message: "missing closing --- delimiter")]
                )
            }
            return ParsedSkillFrontmatter(frontmatter: [:], body: normalized)
        }
        let (frontmatter, issues) = self.parseBlock(extracted.block)
        return ParsedSkillFrontmatter(frontmatter: frontmatter, body: extracted.body, issues: issues)
    }

    /// YAML-subset parse with the upstream line parser as a per-key fallback.
    static func parseBlock(_ block: String) -> (frontmatter: [String: String], issues: [SkillFrontmatterIssue]) {
        guard !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ([:], []) }
        let fallback = self.parseLineFrontmatter(block)
        let members: [FrontmatterMember]
        do {
            members = try YAMLSubsetParser(block).parseTopLevel()
        } catch let error as FrontmatterSyntaxError {
            return (fallback, [SkillFrontmatterIssue(code: error.code, message: error.message)])
        } catch {
            return (fallback, [SkillFrontmatterIssue(code: "YAML_EXCEPTION", message: String(describing: error))])
        }
        let inlineColonKeys = self.inlineColonKeys(block)
        var result: [String: String] = [:]
        for member in members {
            let key = member.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let text = member.value.frontmatterText else { continue }
            // Upstream keeps the raw line value when a structured value was written inline with colons.
            if member.value.isStructured, inlineColonKeys.contains(key), let raw = fallback[key] {
                result[key] = raw
            } else {
                result[key] = text
            }
        }
        for (key, value) in fallback where result[key] == nil {
            result[key] = value
        }
        return (result, [])
    }

    /// Upstream `parseLineFrontmatter`: `key: value` lines, with indented continuation lines joined.
    static func parseLineFrontmatter(_ block: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = block.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard let match = line.range(of: "^[\\w-]+:", options: .regularExpression) else {
                index += 1
                continue
            }
            let key = String(line[match].dropLast())
            var value = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty, index + 1 < lines.count, lines[index + 1].first == " " || lines[index + 1].first == "\t" {
                var collected: [String] = []
                while index + 1 < lines.count {
                    let next = lines[index + 1]
                    if !next.isEmpty && !(next.first == " " || next.first == "\t") { break }
                    collected.append(next)
                    index += 1
                }
                value = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                value = self.stripQuotes(value)
            }
            if !value.isEmpty {
                result[key] = value
            }
            index += 1
        }
        return result
    }

    private static func inlineColonKeys(_ block: String) -> Set<String> {
        var keys = Set<String>()
        for line in block.components(separatedBy: "\n") {
            guard let match = line.range(of: "^[\\w-]+:", options: .regularExpression) else { continue }
            if line[match.upperBound...].contains(":") {
                keys.insert(String(line[match].dropLast()))
            }
        }
        return keys
    }

    static func stripQuotes(_ value: String) -> String {
        guard let first = value.first, first == "\"" || first == "'", value.count >= 2, value.last == first else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    // MARK: - Metadata resolution

    static func resolveMetadata(from frontmatter: [String: String]) -> SkillMetadata {
        let manifest = SkillManifestParser.parse(metadata: frontmatter["metadata"])
        return SkillMetadata(
            always: manifest?.always ?? parseBool(frontmatter["always"] ?? frontmatter["openclaw.always"]),
            skillKey: manifest?.skillKey ?? frontmatter["skillKey"] ?? frontmatter["openclaw.skillKey"],
            primaryEnv: manifest?.primaryEnv ?? frontmatter["primaryEnv"] ?? frontmatter["openclaw.primaryEnv"],
            connectors: self.parseConnectorPermissions(frontmatter),
            emoji: manifest?.emoji,
            homepage: manifest?.homepage ?? frontmatter["homepage"],
            os: manifest?.os ?? [],
            requires: manifest?.requires,
            install: manifest?.install ?? []
        )
    }

    static func resolveInvocationPolicy(from frontmatter: [String: String]) -> SkillInvocationPolicy {
        SkillInvocationPolicy(
            userInvocable: parseBool(frontmatter["user-invocable"], defaultValue: true) ?? true,
            requiresExplicitInvocation: parseBool(
                frontmatter["requires-explicit-invocation"] ?? frontmatter["explicit-only"],
                defaultValue: false
            ) ?? false,
            disableModelInvocation: parseBool(
                frontmatter["disable-model-invocation"],
                defaultValue: false
            ) ?? false
        )
    }

    /// Upstream command dispatch: `command-dispatch: tool` plus a required `command-tool`.
    static func resolveCommandDispatch(from frontmatter: [String: String]) -> SkillCommandDispatch? {
        let kind = (frontmatter["command-dispatch"] ?? frontmatter["command_dispatch"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard kind == "tool" else { return nil }
        let toolName = (frontmatter["command-tool"] ?? frontmatter["command_tool"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else { return nil }
        // Unknown `command-arg-mode` values fall back to raw, like upstream.
        return SkillCommandDispatch(toolName: toolName, argMode: .raw)
    }

    /// First Markdown `# H1` of the body, else `fallback`.
    static func resolveDisplayName(body: String, fallback: String) -> String {
        var inFence = false
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, trimmed.hasPrefix("# ") else { continue }
            let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\s+#+$", with: "", options: .regularExpression)
            if !title.isEmpty {
                return title
            }
        }
        return fallback
    }

    static func parseBool(_ value: String?, defaultValue: Bool? = nil) -> Bool? {
        guard let value else { return defaultValue }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }

    private static func parseConnectorPermissions(_ frontmatter: [String: String]) -> [SkillConnectorPermission] {
        let connectorRaw = frontmatter["connectors"] ?? frontmatter["connector"] ?? ""
        let connectors = connectorRaw
            .split { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "[" || $0 == "]" || $0 == "\"" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { token in
                SkillConnectorType.allCases.first { connector in
                    connector.rawValue.caseInsensitiveCompare(token) == .orderedSame
                }
            }
        guard !connectors.isEmpty else {
            return []
        }

        let scopeRaw = frontmatter["connectorScopes"] ??
            frontmatter["connector-scopes"] ??
            frontmatter["scopes"] ??
            ""
        let scopes = scopeRaw
            .split { $0 == "," || $0 == ";" || $0 == "[" || $0 == "]" || $0 == "\"" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let consentRaw = (frontmatter["connectorConsent"] ??
            frontmatter["connector-consent"] ??
            frontmatter["consent"] ??
            "explicit")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let consent = ConnectorConsentRequirement(rawValue: consentRaw) ?? .explicit

        return connectors.map { connector in
            SkillConnectorPermission(
                connector: connector,
                scopes: scopes,
                consent: consent
            )
        }
    }
}
