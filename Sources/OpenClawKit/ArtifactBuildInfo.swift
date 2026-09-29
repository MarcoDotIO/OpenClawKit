import Foundation

/// Build provenance of an app artifact, read from its Info.plist.
///
/// Reads `CFBundleShortVersionString` (or custom `versionKeys`), `CFBundleVersion`, and the optional
/// `OpenClawGitCommit` (40 hex characters) and `OpenClawBuildTimestamp` (strict UTC ISO 8601 with at
/// most three fractional digits) keys that release builds stamp. Invalid values are dropped.
public struct ArtifactBuildInfo: Equatable, Sendable {
    /// Marketing version (`dev` when absent).
    public let version: String
    /// Build number (empty when absent).
    public let build: String
    /// Lowercased 40-hex git commit, when valid.
    public let gitCommit: String?
    /// Original build timestamp string, when it parsed.
    public let buildTimestamp: String?
    /// Parsed build date.
    public let builtAt: Date?

    /// Reads build info from an Info.plist dictionary.
    public init(
        infoDictionary: [String: Any],
        versionKeys: [String] = ["CFBundleShortVersionString"])
    {
        self.version = versionKeys.lazy.compactMap { Self.nonEmptyString(infoDictionary[$0]) }.first ?? "dev"
        self.build = Self.nonEmptyString(infoDictionary["CFBundleVersion"]) ?? ""
        self.gitCommit = Self.validGitCommit(Self.nonEmptyString(infoDictionary["OpenClawGitCommit"]))
        let buildTimestamp = Self.nonEmptyString(infoDictionary["OpenClawBuildTimestamp"])
        self.builtAt = buildTimestamp.flatMap(Self.parseBuildTimestamp)
        self.buildTimestamp = self.builtAt == nil ? nil : buildTimestamp
    }

    /// Reads build info from a bundle's Info.plist (the main bundle by default).
    public init(bundle: Bundle = .main, versionKeys: [String] = ["CFBundleShortVersionString"]) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:], versionKeys: versionKeys)
    }

    /// `version (build)`, or just `version` when the build is empty or equal.
    public var versionDisplay: String {
        if self.build.isEmpty || self.build == self.version {
            return self.version
        }
        return "\(self.version) (\(self.build))"
    }

    /// First 12 characters of the commit.
    public var shortCommit: String? {
        self.gitCommit.map { String($0.prefix(12)) }
    }

    /// Commit spelled out character by character for VoiceOver.
    public var spokenCommit: String? {
        self.gitCommit.map { $0.map(String.init).joined(separator: " ") }
    }

    /// Medium-style build date in `locale` and `timeZone` (UTC by default).
    public func localizedBuildDate(
        locale: Locale = .current,
        timeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .current) -> String?
    {
        guard let builtAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: builtAt)
    }

    /// Multi-line text for a "copy build info" action.
    public var copyText: String {
        [
            "Version \(self.versionDisplay)",
            "Commit \(self.gitCommit ?? "Unavailable")",
            "Built \(self.buildTimestamp ?? "Unavailable")",
        ].joined(separator: "\n")
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func validGitCommit(_ value: String?) -> String? {
        guard let value, value.utf8.count == 40 else { return nil }
        let isAsciiHex = value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        guard isAsciiHex else { return nil }
        return value.lowercased()
    }

    private static func parseBuildTimestamp(_ value: String) -> Date? {
        let utcPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$"#
        guard value.range(of: utcPattern, options: .regularExpression) != nil else { return nil }
        let withoutZulu = String(value.dropLast())
        let canonicalValue: String
        if let fractionSeparator = withoutZulu.lastIndex(of: ".") {
            let prefix = withoutZulu[...fractionSeparator]
            let fraction = withoutZulu[withoutZulu.index(after: fractionSeparator)...]
            let paddedFraction = String(fraction).padding(toLength: 3, withPad: "0", startingAt: 0)
            canonicalValue = "\(prefix)\(paddedFraction)Z"
        } else {
            canonicalValue = "\(withoutZulu).000Z"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: canonicalValue) else { return nil }
        return formatter.string(from: date) == canonicalValue ? date : nil
    }
}
