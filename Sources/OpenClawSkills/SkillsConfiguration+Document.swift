import Foundation
import OpenClawCore

public extension SkillsConfiguration {
    /// Builds skill settings from a config document's `skills` section (`allowBundled`, `load`,
    /// `entries`, `limits`), which shares the upstream JSON shape this type decodes.
    /// - Parameter document: Config document.
    /// - Returns: The settings (defaults when the document has no `skills` section).
    /// - Throws: `DecodingError` when the section does not match the upstream shape.
    static func resolve(from document: OpenClawConfigDocument) throws -> SkillsConfiguration {
        guard let section = document.skills else { return SkillsConfiguration() }
        let data = try JSONEncoder().encode(section)
        return try JSONDecoder().decode(SkillsConfiguration.self, from: data)
    }
}
