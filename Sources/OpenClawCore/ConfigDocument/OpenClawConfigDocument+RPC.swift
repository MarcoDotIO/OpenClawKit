import Foundation
import OpenClawProtocol

/// One validation issue in a `config.get` snapshot (upstream `ConfigValidationIssue`).
public struct ConfigValidationIssue: Codable, Sendable, Equatable {
    /// Machine-readable error code.
    public var errorCode: String?
    /// Suggested fix.
    public var fixHint: String?
    /// Plugin diagnostic code.
    public var code: String?
    /// Issue source.
    public var source: String?
    /// Dotted path of the invalid value.
    public var path: String
    /// Structured path (strings and array indices).
    public var pathSegments: [ConfigStringOrNumber]?
    /// Human-readable message.
    public var message: String
    /// Allowed values shown to the operator.
    public var allowedValues: [String]?
    /// Number of allowed values omitted from ``allowedValues``.
    public var allowedValuesHiddenCount: Int?

    /// Creates an issue.
    /// - Parameters:
    ///   - path: Dotted path.
    ///   - message: Message.
    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case errorCode, fixHint, code, source, path, pathSegments, message, allowedValues, allowedValuesHiddenCount
    }

    /// Decodes an issue leniently (missing `path`/`message` become empty strings).
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.errorCode = container.decodeLenient(String.self, forKey: .errorCode)
        self.fixHint = container.decodeLenient(String.self, forKey: .fixHint)
        self.code = container.decodeLenient(String.self, forKey: .code)
        self.source = container.decodeLenient(String.self, forKey: .source)
        self.path = container.decodeLenient(String.self, forKey: .path) ?? ""
        self.pathSegments = container.decodeLenient([ConfigStringOrNumber].self, forKey: .pathSegments)
        self.message = container.decodeLenient(String.self, forKey: .message) ?? ""
        self.allowedValues = container.decodeLenient([String].self, forKey: .allowedValues)
        self.allowedValuesHiddenCount = container.decodeLenient(Int.self, forKey: .allowedValuesHiddenCount)
    }
}

/// Typed `config.get` payload: a redacted config file snapshot plus revision fields
/// (`src/gateway/config-get-response.ts`).
///
/// Secret values arrive as redaction markers (``ConfigRedaction/sentinel``). Build patches with
/// ``ConfigMergePatchBuilder``; the gateway restores redacted values during `config.patch`.
public struct ConfigGetSnapshot: Decodable, Sendable, Equatable {
    /// Config file path.
    public var path: String
    /// Whether the file exists.
    public var exists: Bool
    /// Redacted raw file text.
    public var raw: String?
    /// Parsed value before normalization.
    public var parsed: AnyCodable?
    /// Authored config after `$include` and `${ENV}` resolution (empty when invalid).
    @ConfigIndirect public var sourceConfig: OpenClawConfigDocument?
    /// Same as ``sourceConfig`` (write base without runtime defaults).
    @ConfigIndirect public var resolved: OpenClawConfigDocument?
    /// Runtime-shaped config with defaults applied.
    @ConfigIndirect public var runtimeConfig: OpenClawConfigDocument?
    /// Deprecated alias of ``runtimeConfig``.
    @ConfigIndirect public var config: OpenClawConfigDocument?
    /// Whether the config validated.
    public var valid: Bool
    /// Raw-content hash; pass it as `baseHash` to `config.patch`/`config.apply`.
    public var hash: String?
    /// Validation errors.
    public var issues: [ConfigValidationIssue]
    /// Validation warnings.
    public var warnings: [ConfigValidationIssue]
    /// Legacy keys (path and message).
    public var legacyIssues: [ConfigValidationIssue]
    /// Files reached through `$include`.
    public var includedPaths: [String]?
    /// Revision hash of the resolved config (`nil` while invalid).
    public var configRevisionHash: String?
    /// Revision hash of the config the gateway applied.
    public var appliedConfigHash: String?
    /// Last write error, if any.
    public var writeError: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case path, exists, raw, parsed, sourceConfig, resolved, runtimeConfig, config, valid, hash, issues, warnings
        case legacyIssues, includedPaths, configRevisionHash, appliedConfigHash, writeError
    }

    /// Decodes the snapshot leniently; config objects decode as documents without migration.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func document(_ key: CodingKeys) -> OpenClawConfigDocument? {
            guard let object = container.decodeLenient(AnyCodable.self, forKey: key)?.dictionaryValue else { return nil }
            return try? OpenClawConfigDocument.decode(jsonObject: object, migrateLegacyKeys: false)
        }
        self.path = container.decodeLenient(String.self, forKey: .path) ?? ""
        self.exists = container.decodeLenient(Bool.self, forKey: .exists) ?? false
        self.raw = container.decodeLenient(String.self, forKey: .raw)
        self.parsed = container.decodeLenient(AnyCodable.self, forKey: .parsed)
        self.sourceConfig = document(.sourceConfig)
        self.resolved = document(.resolved)
        self.runtimeConfig = document(.runtimeConfig)
        self.config = document(.config)
        self.valid = container.decodeLenient(Bool.self, forKey: .valid) ?? false
        self.hash = container.decodeLenient(String.self, forKey: .hash)
        self.issues = container.decodeLossyArrayIfPresent(ConfigValidationIssue.self, forKey: .issues) ?? []
        self.warnings = container.decodeLossyArrayIfPresent(ConfigValidationIssue.self, forKey: .warnings) ?? []
        self.legacyIssues = container.decodeLossyArrayIfPresent(ConfigValidationIssue.self, forKey: .legacyIssues) ?? []
        self.includedPaths = container.decodeLenient([String].self, forKey: .includedPaths)
        self.configRevisionHash = container.decodeLenient(String.self, forKey: .configRevisionHash)
        self.appliedConfigHash = container.decodeLenient(String.self, forKey: .appliedConfigHash)
        self.writeError = container.decodeLenient(AnyCodable.self, forKey: .writeError)
    }

    /// Decodes a `config.get` response payload.
    /// - Parameter data: Response payload bytes.
    /// - Returns: The snapshot.
    public static func decode(_ data: Data) throws -> ConfigGetSnapshot {
        try JSONDecoder().decode(ConfigGetSnapshot.self, from: data)
    }

    /// The runtime view (``runtimeConfig``, else the deprecated ``config``).
    public var effectiveRuntimeConfig: OpenClawConfigDocument? {
        self.runtimeConfig ?? self.config
    }

    /// `runtimeConfig.tools.web.search.enabled` (default `true`), as the upstream iOS composer reads it.
    public var isWebSearchEnabled: Bool {
        self.effectiveRuntimeConfig?.tools?.isWebSearchEnabled ?? true
    }

    /// `runtimeConfig.mcp.servers.*.enabled` (default `true`).
    public var mcpServerEnabledStates: [String: Bool] {
        self.effectiveRuntimeConfig?.mcp?.serverEnabledStates ?? [:]
    }

    /// The write base for patches (``sourceConfig`` as a JSON tree).
    public var patchBase: [String: AnyCodable] {
        (self.sourceConfig ?? self.resolved)?.jsonObject ?? [:]
    }
}

/// JSON merge patch (RFC 7386) builder for `config.patch` that computes `replacePaths` automatically.
///
/// Objects merge, `null` deletes, arrays replace. The gateway rejects a patch that removes existing
/// array entries or deletes an array unless the array's exact path is listed in `replacePaths`;
/// arrays of objects with stable `id` fields merge by id, and their nested arrays use `[]` segments
/// (for example `models.providers.custom.models[].input`). Redaction markers copied from a
/// `config.get` snapshot are never sent as replacements: the gateway restores them.
public struct ConfigMergePatchBuilder: Sendable {
    /// Upstream limit on `replacePaths`.
    public static let maxReplacePaths = 256

    /// A built patch.
    public struct Payload: Sendable, Equatable {
        /// Merge patch as compact JSON text (the `raw` field of `config.patch`).
        public var raw: String
        /// Merge patch tree.
        public var patch: [String: AnyCodable]
        /// Exact array paths whose replacement or deletion is intentional.
        public var replacePaths: [String]

        /// Dotted paths of every value the patch sets or deletes (leaves of the patch tree).
        public var touchedPaths: [String] {
            var paths: [String] = []
            func visit(_ object: [String: AnyCodable], prefix: String) {
                for (key, value) in object {
                    let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                    if let child = value.dictionaryValue, !child.isEmpty {
                        visit(child, prefix: path)
                    } else {
                        paths.append(path)
                    }
                }
            }
            visit(self.patch, prefix: "")
            return paths.sorted()
        }
    }

    /// Patch construction failures.
    public enum BuildError: Error, LocalizedError, Sendable, Equatable {
        /// More than ``maxReplacePaths`` array paths would be replaced.
        case tooManyReplacePaths(Int)

        /// Human-readable description.
        public var errorDescription: String? {
            switch self {
            case .tooManyReplacePaths(let count):
                return "config.patch allows at most \(ConfigMergePatchBuilder.maxReplacePaths) replacePaths (needed \(count)); use config.apply."
            }
        }
    }

    /// Base config tree (usually ``ConfigGetSnapshot/patchBase``).
    public let base: [String: AnyCodable]
    private var patch: [String: AnyCodable] = [:]

    /// Creates a builder over a base tree.
    /// - Parameter base: Current config tree.
    public init(base: [String: AnyCodable]) {
        self.base = base
    }

    /// Sets (or, with `nil`, deletes) the value at `path`.
    /// - Parameters:
    ///   - path: Object path (record keys, no dots inside keys needed).
    ///   - value: New value; `nil` deletes the key.
    public mutating func set(_ path: [String], _ value: AnyCodable?) {
        guard !path.isEmpty else { return }
        self.patch = Self.setting(self.patch, path: path[...], value: value ?? AnyCodable(.null))
    }

    /// Adds the minimal patch that turns ``base`` into `target` (unchanged redaction markers are skipped).
    /// - Parameter target: Desired config tree.
    public mutating func diff(to target: [String: AnyCodable]) {
        if let object = Self.diffValue(base: AnyCodable(.object(self.base)), target: AnyCodable(.object(target)))?.dictionaryValue {
            for (key, value) in object {
                self.patch = Self.setting(self.patch, path: [key][...], value: value)
            }
        }
    }

    /// Whether the patch is empty.
    public var isEmpty: Bool {
        self.patch.isEmpty
    }

    /// Builds the patch and its `replacePaths`.
    /// - Returns: The payload.
    /// - Throws: ``BuildError/tooManyReplacePaths(_:)``.
    public func build() throws -> Payload {
        var paths: Set<String> = []
        Self.collectReplacePaths(patch: AnyCodable(.object(self.patch)), base: AnyCodable(.object(self.base)), path: "", into: &paths)
        guard paths.count <= Self.maxReplacePaths else {
            throw BuildError.tooManyReplacePaths(paths.count)
        }
        let raw = OpenClawJSON5.serialize(AnyCodable(.object(self.patch)), sortedKeys: true, prettyPrinted: false)
        return Payload(raw: raw, patch: self.patch, replacePaths: paths.sorted())
    }

    /// Applies an RFC 7386 merge patch to a tree (arrays replace, `null` deletes).
    /// - Parameters:
    ///   - patch: Merge patch.
    ///   - target: Tree to patch.
    /// - Returns: The patched tree.
    public static func apply(_ patch: [String: AnyCodable], to target: [String: AnyCodable]) -> [String: AnyCodable] {
        var result = target
        for (key, value) in patch {
            if value.isNull {
                result.removeValue(forKey: key)
            } else if let object = value.dictionaryValue {
                result[key] = AnyCodable(.object(self.apply(object, to: result[key]?.dictionaryValue ?? [:])))
            } else {
                result[key] = value
            }
        }
        return result
    }

    // MARK: Internals

    private static func setting(_ object: [String: AnyCodable], path: ArraySlice<String>, value: AnyCodable) -> [String: AnyCodable] {
        guard let key = path.first else { return object }
        var result = object
        if path.count == 1 {
            result[key] = value
        } else {
            let child = result[key]?.dictionaryValue ?? [:]
            result[key] = AnyCodable(.object(self.setting(child, path: path.dropFirst(), value: value)))
        }
        return result
    }

    private static func diffValue(base: AnyCodable?, target: AnyCodable) -> AnyCodable? {
        if let base, base == target {
            return nil
        }
        if ConfigRedaction.isRedactedSecretValue(target), base != nil {
            // The snapshot's marker stands for the stored secret; keep it unchanged.
            return nil
        }
        guard let targetObject = target.dictionaryValue, let baseObject = base?.dictionaryValue else {
            return target
        }
        var patch: [String: AnyCodable] = [:]
        for (key, value) in targetObject {
            if let child = self.diffValue(base: baseObject[key], target: value) {
                patch[key] = child
            }
        }
        for key in baseObject.keys where targetObject[key] == nil {
            patch[key] = AnyCodable(.null)
        }
        return patch.isEmpty ? nil : AnyCodable(.object(patch))
    }

    private static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    private static func collectReplacePaths(patch: AnyCodable, base: AnyCodable?, path: String, into paths: inout Set<String>) {
        guard let patchObject = patch.dictionaryValue else { return }
        let baseObject = base?.dictionaryValue ?? [:]
        for (key, value) in patchObject {
            let childPath = self.join(path, key)
            let baseValue = baseObject[key]
            if value.isNull {
                if let baseValue {
                    self.collectDeletedArrays(baseValue, path: childPath, into: &paths)
                }
                continue
            }
            if let newArray = value.arrayValue {
                if let baseArray = baseValue?.arrayValue {
                    self.compareArrays(base: baseArray, new: newArray, path: childPath, into: &paths)
                } else if let baseValue, baseValue.dictionaryValue != nil {
                    self.collectDeletedArrays(baseValue, path: childPath, into: &paths)
                }
                continue
            }
            if value.dictionaryValue != nil {
                if baseValue?.arrayValue != nil {
                    paths.insert(childPath)
                } else {
                    self.collectReplacePaths(patch: value, base: baseValue, path: childPath, into: &paths)
                }
                continue
            }
            // A scalar replaces a container: every array inside it is deleted.
            if let baseValue {
                self.collectDeletedArrays(baseValue, path: childPath, into: &paths)
            }
        }
    }

    /// Deleting a value deletes every array it contains (whole arrays need only their own path).
    private static func collectDeletedArrays(_ value: AnyCodable, path: String, into paths: inout Set<String>) {
        if value.arrayValue != nil {
            paths.insert(path)
            return
        }
        for (key, child) in value.dictionaryValue ?? [:] {
            self.collectDeletedArrays(child, path: self.join(path, key), into: &paths)
        }
    }

    private static func stableID(_ value: AnyCodable) -> String? {
        value.dictionaryValue?["id"]?.stringValue
    }

    private static func compareArrays(base: [AnyCodable], new: [AnyCodable], path: String, into paths: inout Set<String>) {
        let baseIDs = base.map(self.stableID)
        let newIDs = new.map(self.stableID)
        let idMerged = !base.isEmpty && baseIDs.allSatisfy { $0 != nil } && newIDs.allSatisfy { $0 != nil }
        if idMerged {
            let newByID = Dictionary(new.map { (self.stableID($0)!, $0) }, uniquingKeysWith: { _, last in last })
            for entry in base {
                guard let id = self.stableID(entry) else { continue }
                guard let replacement = newByID[id] else {
                    // An id-merged entry disappears: the array must be replaced explicitly.
                    paths.insert(path)
                    return
                }
                // Nested arrays inside id-merged entries use `[]`.
                self.compareEntry(base: entry, new: replacement, path: "\(path)[]", into: &paths)
            }
            return
        }
        let removes = base.contains { element in !new.contains(element) }
        if removes || new.count < base.count {
            paths.insert(path)
        }
    }

    private static func compareEntry(base: AnyCodable, new: AnyCodable, path: String, into paths: inout Set<String>) {
        guard let baseObject = base.dictionaryValue, let newObject = new.dictionaryValue else { return }
        for (key, baseValue) in baseObject {
            let childPath = self.join(path, key)
            guard let newValue = newObject[key] else {
                self.collectDeletedArrays(baseValue, path: childPath, into: &paths)
                continue
            }
            if let baseArray = baseValue.arrayValue, let newArray = newValue.arrayValue {
                self.compareArrays(base: baseArray, new: newArray, path: childPath, into: &paths)
            } else if baseValue.dictionaryValue != nil {
                self.compareEntry(base: baseValue, new: newValue, path: childPath, into: &paths)
            }
        }
    }
}

/// Request builders for the config RPCs (`config.get`, `config.patch`, `config.apply`, `config.schema.lookup`).
///
/// `baseHash` is required once a config file exists. Control-plane writes are rate-limited upstream
/// to 30 requests per 60 seconds per method and `deviceId+clientIp`; `config.set` acknowledges
/// persistence only, while `config.apply` replaces the whole config.
public enum ConfigRPC {
    /// `config.schema.lookup` path limit.
    public static let maxSchemaLookupPathLength = 1_024

    /// Builds `config.patch` params from a patch payload and the snapshot hash.
    /// - Parameters:
    ///   - payload: Built merge patch.
    ///   - baseHash: ``ConfigGetSnapshot/hash``.
    ///   - sessionKey: Session to notify about restarts.
    ///   - deliveryContext: Delivery context (`channel`, `to`, `accountId`, `threadId`).
    ///   - note: Operator note.
    ///   - restartDelayMs: Restart delay.
    /// - Returns: Protocol params.
    public static func patchParams(
        _ payload: ConfigMergePatchBuilder.Payload,
        baseHash: String?,
        sessionKey: String? = nil,
        deliveryContext: [String: AnyCodable]? = nil,
        note: String? = nil,
        restartDelayMs: Int? = nil
    ) -> ConfigPatchParams {
        ConfigPatchParams(
            raw: payload.raw,
            basehash: baseHash,
            sessionkey: sessionKey,
            deliverycontext: deliveryContext,
            note: note,
            restartdelayms: restartDelayMs,
            replacepaths: payload.replacePaths.isEmpty ? nil : payload.replacePaths
        )
    }

    /// Builds `config.apply` params that replace the whole config with `document`.
    /// - Parameters:
    ///   - document: Full replacement document.
    ///   - baseHash: ``ConfigGetSnapshot/hash``.
    ///   - note: Operator note.
    /// - Returns: Protocol params.
    public static func applyParams(_ document: OpenClawConfigDocument, baseHash: String?, note: String? = nil) throws -> ConfigApplyParams {
        let raw = String(decoding: try document.encoded(prettyPrinted: false, sortedKeys: true), as: UTF8.self)
        return ConfigApplyParams(raw: raw, basehash: baseHash, note: note)
    }

    /// Whether `path` is accepted by `config.schema.lookup` (`^[A-Za-z0-9_./\[\]\-*]+$`, ≤ 1024 characters).
    /// - Parameter path: Schema path.
    /// - Returns: `true` when valid.
    public static func isValidSchemaLookupPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= self.maxSchemaLookupPathLength else { return false }
        return path.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "_./[]-*".contains(character))
        }
    }

    /// Parameters for encoding RPC params into the `[String: AnyCodable]` shape gateway clients send.
    /// - Parameter params: Encodable params.
    /// - Returns: JSON object tree.
    public static func paramsObject(_ params: some Encodable) throws -> [String: AnyCodable] {
        try AnyCodable(encoding: params).dictionaryValue ?? [:]
    }
}

/// `config.patch` / `config.apply` / `config.set` success payload.
public struct ConfigWriteResult: Decodable, Sendable, Equatable {
    /// Always `true` on success.
    public var ok: Bool
    /// `true` when the patch changed nothing.
    public var noop: Bool
    /// Config file path.
    public var path: String?
    /// New raw-content hash (adopt it as the next `baseHash`).
    public var hash: String?
    /// Canonical persisted config (redacted).
    @ConfigIndirect public var config: OpenClawConfigDocument?
    /// Effective runtime paths the write changed (`config.patch` only).
    public var changedPaths: [String]
    /// Restart details.
    public var restart: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case ok, noop, path, hash, config, changedPaths, restart
    }

    /// Decodes the payload leniently.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ok = container.decodeLenient(Bool.self, forKey: .ok) ?? false
        self.noop = container.decodeLenient(Bool.self, forKey: .noop) ?? false
        self.path = container.decodeLenient(String.self, forKey: .path)
        self.hash = container.decodeLenient(String.self, forKey: .hash)
        if let object = container.decodeLenient(AnyCodable.self, forKey: .config)?.dictionaryValue {
            self.config = try? OpenClawConfigDocument.decode(jsonObject: object, migrateLegacyKeys: false)
        } else {
            self.config = nil
        }
        self.changedPaths = container.decodeLenient([String].self, forKey: .changedPaths) ?? []
        self.restart = container.decodeLenient(AnyCodable.self, forKey: .restart)
    }
}

/// Minimal request seam for config RPC helpers; `GatewayChannelActor` conforms in OpenClawKit.
public protocol ConfigRPCRequestSending: Sendable {
    /// Sends one gateway request and returns the response payload.
    /// - Parameters:
    ///   - method: RPC method.
    ///   - params: Request params.
    ///   - timeoutMs: Timeout in milliseconds.
    /// - Returns: Response payload bytes.
    func request(method: String, params: [String: AnyCodable]?, timeoutMs: Double?) async throws -> Data
}

extension ConfigRPCRequestSending {
    /// Fetches the current `config.get` snapshot.
    /// - Returns: The typed snapshot.
    public func fetchConfigSnapshot() async throws -> ConfigGetSnapshot {
        try ConfigGetSnapshot.decode(try await self.request(method: "config.get", params: [:], timeoutMs: nil))
    }

    /// Sends a `config.patch` built against `snapshot` and returns the write result.
    /// - Parameters:
    ///   - snapshot: Snapshot the patch was built from (its hash becomes `baseHash`).
    ///   - build: Mutates a builder seeded with ``ConfigGetSnapshot/patchBase``.
    /// - Returns: The write result (noop when the patch is empty).
    public func patchConfig(
        from snapshot: ConfigGetSnapshot,
        note: String? = nil,
        _ build: (inout ConfigMergePatchBuilder) -> Void
    ) async throws -> ConfigWriteResult {
        var builder = ConfigMergePatchBuilder(base: snapshot.patchBase)
        build(&builder)
        let params = ConfigRPC.patchParams(try builder.build(), baseHash: snapshot.hash, note: note)
        let data = try await self.request(method: "config.patch", params: try ConfigRPC.paramsObject(params), timeoutMs: nil)
        return try JSONDecoder().decode(ConfigWriteResult.self, from: data)
    }
}
