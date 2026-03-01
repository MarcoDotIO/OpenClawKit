import Foundation

enum SkillFrontmatterParser {
    static func parse(_ content: String) -> (frontmatter: [String: String], body: String) {
        var frontmatter: [String: String] = [:]
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return (frontmatter, content)
        }

        var endIndex: Int?
        var idx = 1
        while idx < lines.count {
            let line = lines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "---" {
                endIndex = idx
                break
            }
            if let sep = line.firstIndex(of: ":") {
                let key = String(line[..<sep]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rawValue = String(line[line.index(after: sep)...])
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !key.isEmpty {
                    frontmatter[key] = value
                }
            }
            idx += 1
        }

        guard let endIndex else {
            return (frontmatter, content)
        }
        let bodyLines = lines[(endIndex + 1)...]
        return (frontmatter, bodyLines.joined(separator: "\n"))
    }

    static func resolveMetadata(from frontmatter: [String: String]) -> SkillMetadata {
        SkillMetadata(
            always: parseBool(frontmatter["always"] ?? frontmatter["openclaw.always"]),
            skillKey: frontmatter["skillKey"] ?? frontmatter["openclaw.skillKey"],
            primaryEnv: frontmatter["primaryEnv"] ?? frontmatter["openclaw.primaryEnv"],
            connectors: self.parseConnectorPermissions(frontmatter)
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

    private static func parseBool(_ value: String?, defaultValue: Bool? = nil) -> Bool? {
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
            .split { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" || $0 == "\t" }
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
            .split { $0 == "," || $0 == ";" }
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
