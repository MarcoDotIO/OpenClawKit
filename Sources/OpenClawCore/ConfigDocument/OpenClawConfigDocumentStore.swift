import Foundation
import OpenClawProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Reads and writes the upstream `openclaw.json` (JSON or JSON5) with upstream's write guards.
///
/// This store is separate from ``ConfigStore``, which keeps the SDK-native ``OpenClawConfig`` file.
/// Never point an upstream gateway at an SDK-native file (or vice versa): upstream validates strictly
/// and refuses unknown keys.
///
/// Writes follow `src/config/io.ts` and the macOS app fallback writer:
/// - optimistic concurrency against the file hash (`expectedHash`, like `config.patch` `baseHash`),
/// - refusal for files using `$include` (the SDK does not own include ownership),
/// - the future-version guard (`OPENCLAW_ALLOW_OLDER_BINARY_DESTRUCTIVE_ACTIONS=1|true|yes` overrides it),
/// - removal of the retired `meta.lastTouchedAt` and SDK-only keys, and a `meta.lastTouchedVersion` stamp,
/// - the five-slot backup ring `openclaw.json.bak`, `.bak.1` … `.bak.4`,
/// - an atomic write with `0600` permissions on POSIX systems.
public actor OpenClawConfigDocumentStore {
    /// Number of backups kept (`openclaw.json.bak` plus `.bak.1` … `.bak.4`).
    public static let backupCount = 5
    /// Maximum `$include` depth upstream resolves.
    public static let maxIncludeDepth = 10
    /// Environment variable that allows older binaries to write newer-written configs.
    public static let allowOlderBinaryEnvironmentKey = "OPENCLAW_ALLOW_OLDER_BINARY_DESTRUCTIVE_ACTIONS"
    /// Config file name inside the state directory.
    public static let configFileName = "openclaw.json"

    /// Result of ``load(migrateLegacyKeys:)``.
    public struct LoadedConfigDocument: Sendable, Equatable {
        /// Whether the file exists (a missing file loads as an empty document).
        public var exists: Bool
        /// Decoded document (canonical shapes when loaded with migration).
        public var document: OpenClawConfigDocument
        /// Raw file bytes (empty when missing).
        public var rawData: Data
        /// SHA-256 hex digest of ``rawData`` (`nil` when the file is missing).
        public var hash: String?
        /// Lenient-decoding issues.
        public var issues: [ConfigDecodeIssue]
        /// Legacy and retired keys found in the file (migrated in ``document`` when requested).
        public var legacyIssues: [ConfigDecodeIssue]
        /// Migrations applied to ``document``.
        public var migrationChanges: [ConfigMigrationChange]
        /// Whether any object uses `$include` (such files are read-only for the SDK).
        public var hasIncludes: Bool
        /// `meta.lastTouchedVersion` of the file.
        public var touchedVersion: String?
        /// Authored key order (used to preserve it on write).
        public var keyOrder: ConfigKeyOrder
    }

    /// Options for ``save(_:expectedHash:options:)``.
    public struct WriteOptions: Sendable, Equatable {
        /// Version stamped into `meta.lastTouchedVersion` (`nil` leaves the stamp unchanged).
        public var touchedVersion: String?
        /// Upstream version this SDK build is compatible with (future-version guard).
        public var currentVersion: String
        /// Run the doctor-migration port on the tree before writing.
        public var migrateLegacyKeys: Bool
        /// Remove SDK-only keys that upstream rejects (`routing`, `runtime`, `models.openAI`, …).
        public var stripSDKOnlyKeys: Bool

        /// Creates write options.
        /// - Parameters:
        ///   - touchedVersion: Version stamp.
        ///   - currentVersion: Compatible upstream version.
        ///   - migrateLegacyKeys: Migrate legacy keys before writing.
        ///   - stripSDKOnlyKeys: Strip SDK-only keys.
        public init(
            touchedVersion: String? = OpenClawConfigDocument.upstreamParityVersion,
            currentVersion: String = OpenClawConfigDocument.upstreamParityVersion,
            migrateLegacyKeys: Bool = true,
            stripSDKOnlyKeys: Bool = true
        ) {
            self.touchedVersion = touchedVersion
            self.currentVersion = currentVersion
            self.migrateLegacyKeys = migrateLegacyKeys
            self.stripSDKOnlyKeys = stripSDKOnlyKeys
        }
    }

    /// Write-guard failures.
    public enum StoreError: Error, LocalizedError, Sendable, Equatable {
        /// The file changed since it was read (`expectedHash` mismatch).
        case conflict(expectedHash: String, actualHash: String?)
        /// The file (or the document) uses `$include`.
        case includesNotWritable
        /// The file was last written by a newer OpenClaw than this SDK supports.
        case futureVersion(touchedVersion: String, currentVersion: String)
        /// The file's root is not a JSON object.
        case notAnObject

        /// Human-readable description.
        public var errorDescription: String? {
            switch self {
            case .conflict(let expected, let actual):
                return "openclaw.json changed since it was read (expected hash \(expected), found \(actual ?? "no file")); reload and retry."
            case .includesNotWritable:
                return "openclaw.json uses $include; the SDK cannot write it safely. Edit the included files instead."
            case .futureVersion(let touched, let current):
                return "Refusing to write openclaw.json last written by OpenClaw \(touched) with an SDK compatible with \(current). "
                    + "Set \(OpenClawConfigDocumentStore.allowOlderBinaryEnvironmentKey)=1 only for an intentional downgrade."
            case .notAnObject:
                return "openclaw.json must contain a JSON object at the root."
            }
        }
    }

    /// Config file location.
    public let fileURL: URL
    private let environment: [String: String]
    private var lastKeyOrder = ConfigKeyOrder()

    /// Creates a store.
    /// - Parameters:
    ///   - fileURL: Config file; defaults to ``defaultConfigURL(environment:)``.
    ///   - environment: Environment used for path resolution and the future-version override.
    public init(fileURL: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        self.fileURL = fileURL ?? Self.defaultConfigURL(environment: environment)
    }

    // MARK: Paths

    /// Resolves the config path like upstream `resolveConfigPath` (`src/config/paths.ts`):
    /// `OPENCLAW_CONFIG_PATH` (with `~` expansion), else `<state dir>/openclaw.json`.
    /// - Parameter environment: Process environment.
    /// - Returns: Config file URL.
    public static func defaultConfigURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["OPENCLAW_CONFIG_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: Self.expandHome(override, environment: environment))
        }
        return self.defaultStateDirectory(environment: environment).appendingPathComponent(Self.configFileName, isDirectory: false)
    }

    /// Resolves the state directory like upstream `resolveStateDir`: `OPENCLAW_STATE_DIR`, else
    /// `~/.openclaw-<profile>` for a non-default `OPENCLAW_PROFILE`, else `~/.openclaw` (or an existing
    /// legacy `~/.clawdbot` when `~/.openclaw` does not exist).
    /// - Parameter environment: Process environment.
    /// - Returns: State directory URL.
    public static func defaultStateDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["OPENCLAW_STATE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: Self.expandHome(override, environment: environment), isDirectory: true)
        }
        let home = Self.homeDirectory(environment: environment)
        if let profile = Self.normalizedProfileName(environment["OPENCLAW_PROFILE"]) {
            return home.appendingPathComponent(".openclaw-\(profile)", isDirectory: true)
        }
        let newDirectory = home.appendingPathComponent(".openclaw", isDirectory: true)
        if FileManager.default.fileExists(atPath: newDirectory.path) {
            return newDirectory
        }
        let legacy = home.appendingPathComponent(".clawdbot", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return newDirectory
    }

    /// Upstream `normalizeProfileName`: trimmed, not `default`, matching `^[a-z0-9][a-z0-9_-]{0,63}$` (case-insensitive).
    static func normalizedProfileName(_ raw: String?) -> String? {
        guard let profile = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !profile.isEmpty,
              profile.lowercased() != "default", OpenClawConfigDocument.isValidAgentID(profile)
        else {
            return nil
        }
        return profile
    }

    static func homeDirectory(environment: [String: String]) -> URL {
        for key in ["OPENCLAW_HOME", "HOME"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
        }
        return OpenClawFileSystem.resolveHomeDirectory()
    }

    static func expandHome(_ path: String, environment: [String: String]) -> String {
        guard path == "~" || path.hasPrefix("~/") else {
            return path
        }
        let home = self.homeDirectory(environment: environment).path
        return path == "~" ? home : home + String(path.dropFirst())
    }

    // MARK: Loading

    /// Reads and decodes the config file (a missing file loads as an empty document).
    /// - Parameter migrateLegacyKeys: Apply the doctor-migration port to the typed view (default `true`).
    /// - Returns: The loaded document with its hash and issues.
    /// - Throws: ``OpenClawJSON5/ParseError`` for malformed files, ``StoreError/notAnObject``.
    public func load(migrateLegacyKeys: Bool = true) throws -> LoadedConfigDocument {
        guard OpenClawFileSystem.fileExists(self.fileURL) else {
            self.lastKeyOrder = ConfigKeyOrder()
            return LoadedConfigDocument(
                exists: false, document: OpenClawConfigDocument(), rawData: Data(), hash: nil, issues: [], legacyIssues: [],
                migrationChanges: [], hasIncludes: false, touchedVersion: nil, keyOrder: ConfigKeyOrder()
            )
        }
        let data = try OpenClawFileSystem.readData(self.fileURL)
        let loaded = try Self.decodeLoaded(data, migrateLegacyKeys: migrateLegacyKeys)
        self.lastKeyOrder = loaded.keyOrder
        return loaded
    }

    /// SHA-256 hex digest of the current file, or `nil` when it does not exist.
    /// - Returns: Current file hash.
    public func currentHash() throws -> String? {
        guard OpenClawFileSystem.fileExists(self.fileURL) else {
            return nil
        }
        return OpenClawCrypto.sha256Hex(try OpenClawFileSystem.readData(self.fileURL))
    }

    static func decodeLoaded(_ data: Data, migrateLegacyKeys: Bool) throws -> LoadedConfigDocument {
        // Strict JSON first (like the macOS app), then JSON5.
        let parsed: (value: AnyCodable, keyOrder: ConfigKeyOrder)
        if let strict = try? OpenClawJSON5.parseWithKeyOrder(data, allowJSON5: false) {
            parsed = strict
        } else {
            parsed = try OpenClawJSON5.parseWithKeyOrder(data, allowJSON5: true)
        }
        guard let object = parsed.value.dictionaryValue else {
            throw StoreError.notAnObject
        }
        var tree = object
        var keyOrder = parsed.keyOrder
        let changes: [ConfigMigrationChange]
        if migrateLegacyKeys {
            changes = OpenClawConfigMigrator.migrate(&tree, keyOrder: &keyOrder)
        } else {
            changes = OpenClawConfigMigrator.proposedChanges(for: tree)
        }
        let collector = ConfigDecodeIssueCollector()
        var document = try ConfigTreeCoding.decode(OpenClawConfigDocument.self, from: AnyCodable(.object(tree)), issues: collector)
        if let entries = document.agents?.entries {
            document.agents?.entryOrder = ConfigOrderHint(keyOrder.keys(at: ["agents", "entries"]) ?? []).ordered(entries.keys)
        }
        let legacyIssues = OpenClawConfigMigrator.issues(for: changes) + OpenClawConfigMigrator.unportedIssues(in: tree)
        return LoadedConfigDocument(
            exists: true,
            document: document,
            rawData: data,
            hash: OpenClawCrypto.sha256Hex(data),
            issues: collector.issues,
            legacyIssues: legacyIssues,
            migrationChanges: changes,
            hasIncludes: ConfigIncludes.containsInclude(AnyCodable(.object(object))),
            touchedVersion: object["meta"]?.dictionaryValue?["lastTouchedVersion"]?.stringValue,
            keyOrder: keyOrder
        )
    }

    // MARK: Writing

    /// Writes `document` after applying the write guards.
    /// - Parameters:
    ///   - document: Document to persist.
    ///   - expectedHash: Hash from the last ``load(migrateLegacyKeys:)``; `nil` skips the conflict check
    ///     (required only for a first write).
    ///   - options: Write options.
    /// - Returns: The persisted document as re-loaded from the written bytes.
    /// - Throws: ``StoreError`` when a guard refuses the write, or I/O errors.
    @discardableResult
    public func save(
        _ document: OpenClawConfigDocument,
        expectedHash: String?,
        options: WriteOptions = WriteOptions()
    ) throws -> LoadedConfigDocument {
        let fileManager = FileManager.default
        let exists = OpenClawFileSystem.fileExists(self.fileURL)
        let previousData = exists ? try OpenClawFileSystem.readData(self.fileURL) : nil
        let currentHash = previousData.map(OpenClawCrypto.sha256Hex)
        if let expectedHash, expectedHash != currentHash {
            throw StoreError.conflict(expectedHash: expectedHash, actualHash: currentHash)
        }
        var previousTree: [String: AnyCodable]?
        if let previousData {
            let parsed = (try? OpenClawJSON5.parseWithKeyOrder(previousData, allowJSON5: true))
            previousTree = parsed?.value.dictionaryValue
            if let parsed, self.lastKeyOrder.paths.isEmpty {
                self.lastKeyOrder = parsed.keyOrder
            }
            if let previousTree, ConfigIncludes.containsInclude(AnyCodable(.object(previousTree))) {
                throw StoreError.includesNotWritable
            }
        }
        var tree = document.jsonObject
        if ConfigIncludes.containsInclude(AnyCodable(.object(tree))) {
            throw StoreError.includesNotWritable
        }
        try self.checkFutureVersion(previousTree: previousTree, tree: tree, currentVersion: options.currentVersion)

        var keyOrder = self.lastKeyOrder
        if let entryOrder = document.agents?.entryOrder, !entryOrder.isEmpty {
            keyOrder.set(entryOrder, at: ["agents", "entries"])
        }
        if options.migrateLegacyKeys {
            OpenClawConfigMigrator.migrate(&tree, keyOrder: &keyOrder)
        }
        if options.stripSDKOnlyKeys {
            OpenClawConfigDocument.stripSDKOnlyKeys(from: &tree)
        }
        Self.stampMeta(&tree, touchedVersion: options.touchedVersion)

        let text = OpenClawJSON5.serialize(AnyCodable(.object(tree)), keyOrder: keyOrder, prettyPrinted: true) + "\n"
        let data = Data(text.utf8)
        try OpenClawFileSystem.ensureDirectory(self.fileURL.deletingLastPathComponent())
        if let previousData {
            try self.rotateBackups(previous: previousData, fileManager: fileManager)
        }
        try Self.atomicWrite(data, to: self.fileURL)
        let loaded = try Self.decodeLoaded(data, migrateLegacyKeys: false)
        self.lastKeyOrder = loaded.keyOrder
        return loaded
    }

    private func checkFutureVersion(previousTree: [String: AnyCodable]?, tree: [String: AnyCodable], currentVersion: String) throws {
        let override = self.environment[Self.allowOlderBinaryEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if override == "1" || override == "true" || override == "yes" {
            return
        }
        let touched = previousTree?["meta"]?.dictionaryValue?["lastTouchedVersion"]?.stringValue
            ?? tree["meta"]?.dictionaryValue?["lastTouchedVersion"]?.stringValue
        guard let touched = touched?.trimmingCharacters(in: .whitespacesAndNewlines), !touched.isEmpty,
              OpenClawVersionComparison.shouldWarnOnTouchedVersion(current: currentVersion, touched: touched)
        else {
            return
        }
        throw StoreError.futureVersion(touchedVersion: touched, currentVersion: currentVersion)
    }

    static func stampMeta(_ tree: inout [String: AnyCodable], touchedVersion: String?) {
        var meta = tree["meta"]?.dictionaryValue ?? [:]
        let hadMeta = tree["meta"] != nil
        meta.removeValue(forKey: "lastTouchedAt")
        if let touchedVersion = ConfigValueSupport.nonEmpty(touchedVersion) {
            meta["lastTouchedVersion"] = AnyCodable(.string(touchedVersion))
        }
        if hadMeta || !meta.isEmpty {
            tree["meta"] = AnyCodable(.object(meta))
        }
    }

    private func rotateBackups(previous: Data, fileManager: FileManager) throws {
        let base = self.fileURL.path + ".bak"
        func url(_ index: Int) -> URL {
            URL(fileURLWithPath: index == 0 ? base : "\(base).\(index)")
        }
        let oldest = url(Self.backupCount - 1)
        if fileManager.fileExists(atPath: oldest.path) {
            try? fileManager.removeItem(at: oldest)
        }
        for index in stride(from: Self.backupCount - 2, through: 0, by: -1) {
            let source = url(index)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(at: source, to: url(index + 1))
        }
        try Self.atomicWrite(previous, to: url(0))
    }

    /// Writes `data` to a temporary sibling with `0600` permissions and renames it into place.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        #if os(Windows)
        try data.write(to: url, options: [.atomic])
        #else
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw OpenClawCoreError.unavailable("Could not create a temporary file next to \(url.path)")
        }
        if rename(temporary.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw OpenClawCoreError.unavailable("Could not replace \(url.path) (errno \(code))")
        }
        #endif
    }
}

/// `$include` detection (`src/config/includes.ts`).
public enum ConfigIncludes {
    /// The include directive key.
    public static let key = "$include"

    /// Whether any object in `value` contains `$include`.
    /// - Parameter value: JSON tree.
    /// - Returns: `true` when an include directive is present.
    public static func containsInclude(_ value: AnyCodable) -> Bool {
        switch value.value {
        case .object(let object):
            if object[self.key] != nil {
                return true
            }
            return object.values.contains(where: self.containsInclude)
        case .array(let array):
            return array.contains(where: self.containsInclude)
        default:
            return false
        }
    }
}

/// OpenClaw version comparison (`src/config/version.ts`, `src/infra/semver.ts`).
public enum OpenClawVersionComparison {
    struct Version: Comparable {
        var major: Int
        var minor: Int
        var patch: Int
        /// Prerelease identifiers (empty for stable releases).
        var prerelease: [String]

        /// OpenClaw "correction" releases (`2026.7.1-2`) sort after their base release.
        var isCorrection: Bool {
            self.prerelease.count == 1 && Int(self.prerelease[0]) != nil
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
                return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
            }
            switch (lhs.isCorrection, rhs.isCorrection) {
            case (true, true):
                return Int(lhs.prerelease[0])! < Int(rhs.prerelease[0])!
            case (true, false):
                return false
            case (false, true):
                return true
            case (false, false):
                return Self.comparePrerelease(lhs.prerelease, rhs.prerelease) < 0
            }
        }

        static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> Int {
            if lhs.isEmpty || rhs.isEmpty {
                return lhs.isEmpty == rhs.isEmpty ? 0 : (lhs.isEmpty ? 1 : -1)
            }
            for (left, right) in zip(lhs, rhs) where left != right {
                switch (Int(left), Int(right)) {
                case (let l?, let r?):
                    return l < r ? -1 : 1
                case (_?, nil):
                    return -1
                case (nil, _?):
                    return 1
                default:
                    return left < right ? -1 : 1
                }
            }
            return lhs.count == rhs.count ? 0 : (lhs.count < rhs.count ? -1 : 1)
        }
    }

    static func parse(_ raw: String?) -> Version? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        if let range = text.range(of: ".beta") {
            // Legacy `1.2.3.beta.N` tags become `1.2.3-beta.N`.
            text.replaceSubrange(range, with: "-beta")
        }
        if let plus = text.firstIndex(of: "+") {
            text = String(text[..<plus])
        }
        let parts = text.split(separator: "-", maxSplits: 1)
        let core = parts[0].split(separator: ".")
        guard core.count == 3, let major = Int(core[0]), let minor = Int(core[1]), let patch = Int(core[2]) else {
            return nil
        }
        let prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        return Version(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    /// Compares two OpenClaw versions.
    /// - Parameters:
    ///   - lhs: First version.
    ///   - rhs: Second version.
    /// - Returns: `-1`, `0` or `1`, or `nil` when either version is unparseable.
    public static func compare(_ lhs: String, _ rhs: String) -> Int? {
        guard let left = self.parse(lhs), let right = self.parse(rhs) else {
            return nil
        }
        if left < right {
            return -1
        }
        return right < left ? 1 : 0
    }

    /// Upstream `shouldWarnOnTouchedVersion`: whether a config touched by `touched` is newer than `current`.
    /// - Parameters:
    ///   - current: Running (SDK-compatible) version.
    ///   - touched: `meta.lastTouchedVersion`.
    /// - Returns: `true` when writing would downgrade the config.
    public static func shouldWarnOnTouchedVersion(current: String, touched: String) -> Bool {
        guard let parsedCurrent = self.parse(current), let parsedTouched = self.parse(touched) else {
            return false
        }
        let sameMain = (parsedCurrent.major, parsedCurrent.minor, parsedCurrent.patch)
            == (parsedTouched.major, parsedTouched.minor, parsedTouched.patch)
        if sameMain, parsedTouched.prerelease.isEmpty || parsedTouched.isCorrection {
            return false
        }
        return parsedCurrent < parsedTouched
    }
}

extension OpenClawConfigDocument {
    /// SDK-native key paths that upstream's strict schema rejects; stores strip them before writing.
    public static let sdkOnlyKeyPaths: [[String]] = [
        ["routing"], ["runtime"],
        ["agents", "defaultAgentID"], ["agents", "workspaceRoot"], ["agents", "skillInvocationTimeoutMs"],
        ["agents", "agentIDs"], ["agents", "routeAgentMap"], ["agents", "thinkingLevel"], ["agents", "verboseLevel"],
        ["agents", "reasoningLevel"], ["agents", "responseUsage"], ["agents", "elevatedLevel"], ["agents", "groupActivation"],
        ["agents", "groupActivationNeedsSystemIntro"], ["agents", "sendPolicy"], ["agents", "modelOverride"],
        ["agents", "execHost"], ["agents", "execSecurity"], ["agents", "execAsk"], ["agents", "execNode"],
        ["models", "defaultProviderID"], ["models", "systemPrompt"], ["models", "openAI"], ["models", "openAICompatible"],
        ["models", "anthropic"], ["models", "gemini"], ["models", "foundation"], ["models", "local"],
        ["models", "bedrockDiscovery"], ["channels", "pluginChannels"], ["channels", "whatsappCloud"],
        ["gateway", "host"], ["gateway", "authMode"], ["auth", "cooldowns"], ["secrets", "resolution"],
    ]

    /// Removes ``sdkOnlyKeyPaths`` from a raw tree.
    /// - Parameter tree: Raw config object.
    /// - Returns: Removed dotted paths.
    @discardableResult
    public static func stripSDKOnlyKeys(from tree: inout [String: AnyCodable]) -> [String] {
        let root = MigrationObject(tree)
        var removed: [String] = []
        for path in self.sdkOnlyKeyPaths {
            MigrationSupport.deleteRetiredPath(root, path[...], removed: &removed)
        }
        if !removed.isEmpty {
            tree = root.dictionary
        }
        return removed
    }

    /// Resolves `${VAR}` references (uppercase names only; `$${VAR}` escapes a literal) for runtime use.
    ///
    /// Stores never substitute when loading for write, so the authored source is preserved.
    /// - Parameter environment: Environment variables.
    /// - Returns: The resolved document and one issue per missing or empty variable (with its path).
    public func resolvedForRuntime(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (document: OpenClawConfigDocument, issues: [ConfigDecodeIssue]) {
        var issues: [ConfigDecodeIssue] = []
        let resolved = ConfigEnvSubstitution.resolve(AnyCodable(.object(self.jsonObject)), environment: environment, path: "", issues: &issues)
        var document = (try? ConfigTreeCoding.decode(OpenClawConfigDocument.self, from: resolved, issues: nil)) ?? self
        document.agents?.entryOrder = self.agents?.entryOrder ?? []
        return (document, issues)
    }
}

/// `${VAR}` substitution (`src/config/env-substitution.ts`).
public enum ConfigEnvSubstitution {
    /// Substitutes `${VAR}` references in one string.
    /// - Parameters:
    ///   - value: Authored string.
    ///   - environment: Environment variables.
    ///   - missing: Receives names of missing or empty variables (their placeholders are preserved).
    /// - Returns: The substituted string.
    public static func substitute(_ value: String, environment: [String: String], missing: inout [String]) -> String {
        guard value.contains("$") else {
            return value
        }
        let characters = Array(value)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "$" else {
                output.append(character)
                index += 1
                continue
            }
            if index + 2 < characters.count, characters[index + 1] == "$", characters[index + 2] == "{",
               let (name, end) = self.placeholder(characters, openBrace: index + 2)
            {
                output += "${\(name)}"
                index = end + 1
                continue
            }
            if index + 1 < characters.count, characters[index + 1] == "{",
               let (name, end) = self.placeholder(characters, openBrace: index + 1)
            {
                if let replacement = environment[name], !replacement.isEmpty {
                    output += replacement
                } else {
                    missing.append(name)
                    output += "${\(name)}"
                }
                index = end + 1
                continue
            }
            output.append(character)
            index += 1
        }
        return output
    }

    private static func placeholder(_ characters: [Character], openBrace: Int) -> (String, Int)? {
        var end = openBrace + 1
        while end < characters.count, characters[end] != "}" {
            end += 1
        }
        guard end < characters.count else {
            return nil
        }
        let name = String(characters[(openBrace + 1)..<end])
        guard let first = name.unicodeScalars.first,
              ("A"..."Z").contains(first) || first == "_",
              name.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" })
        else {
            return nil
        }
        return (name, end)
    }

    static func resolve(_ value: AnyCodable, environment: [String: String], path: String, issues: inout [ConfigDecodeIssue]) -> AnyCodable {
        switch value.value {
        case .string(let string):
            var missing: [String] = []
            let substituted = self.substitute(string, environment: environment, missing: &missing)
            for name in missing {
                issues.append(ConfigDecodeIssue(
                    path: path,
                    message: "Missing env var \"\(name)\" referenced at config path: \(path)",
                    kind: .invalidValue
                ))
            }
            return AnyCodable(.string(substituted))
        case .object(let object):
            var result: [String: AnyCodable] = [:]
            for (key, child) in object {
                result[key] = self.resolve(child, environment: environment, path: path.isEmpty ? key : "\(path).\(key)", issues: &issues)
            }
            return AnyCodable(.object(result))
        case .array(let array):
            return AnyCodable(.array(array.enumerated().map { index, child in
                self.resolve(child, environment: environment, path: "\(path)[\(index)]", issues: &issues)
            }))
        default:
            return value
        }
    }
}
