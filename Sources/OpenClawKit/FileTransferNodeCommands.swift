#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// Local policy for the optional file-transfer node commands.
///
/// The gateway enforces its own per-node path policy and operator approval
/// (`plugins.entries.file-transfer.config.nodes`); this is the node's independent, default-deny check.
public struct FileTransferPolicy: Sendable, Equatable {
    /// Absolute directories the node may read or write below. Empty denies everything.
    public var allowedRoots: [String]
    /// Per-round-trip byte ceiling (16 MiB upstream hard maximum).
    public var maxBytes: Int
    /// Maximum `dir.list` page size.
    public var maxDirectoryEntries: Int

    /// Upstream hard byte ceiling per round trip (16 MiB).
    public static let hardMaxBytes = 16 * 1024 * 1024

    /// Creates a policy; `maxBytes` is capped at ``hardMaxBytes``.
    public init(allowedRoots: [String] = [], maxBytes: Int = Self.hardMaxBytes, maxDirectoryEntries: Int = 5000) {
        self.allowedRoots = allowedRoots
        self.maxBytes = min(max(0, maxBytes), Self.hardMaxBytes)
        self.maxDirectoryEntries = max(1, maxDirectoryEntries)
    }
}

/// Optional macOS node host for the plugin-owned file-transfer commands (`file.fetch`, `dir.list`,
/// `file.write`), mirroring `extensions/file-transfer/src/node-host` result shapes.
///
/// Opt-in: advertise ``advertisedCommands(negotiatedProtocol:)`` only when the host enables file
/// transfer and the session negotiated protocol 4 (plugin-owned node commands are withheld from older
/// nodes). Paths must be absolute and resolve inside ``FileTransferPolicy/allowedRoots``; symlinks are
/// refused unless `followSymlinks` is true, `file.write` requires strict base64, and every round trip
/// is bounded by ``FileTransferPolicy/maxBytes``. `dir.fetch` (archive streaming) and binary transport
/// are not supported and answer `INVALID_PARAMS`.
public struct FileTransferNodeCommands: Sendable {
    /// Wire command names.
    public enum Command: String, Sendable, CaseIterable {
        /// `file.fetch`: read one file (base64, bounded).
        case fileFetch = "file.fetch"
        /// `dir.list`: list one directory page.
        case dirList = "dir.list"
        /// `file.write`: write one file from strict base64.
        case fileWrite = "file.write"
    }

    /// Local policy.
    public let policy: FileTransferPolicy

    /// Creates the command host.
    public init(policy: FileTransferPolicy) {
        self.policy = policy
    }

    /// Commands to declare in `connect.commands`: all of them for protocol 4+, none otherwise.
    public func advertisedCommands(negotiatedProtocol: Int) -> [String] {
        negotiatedProtocol >= 4 ? Command.allCases.map(\.rawValue) : []
    }

    /// Handles a file-transfer invoke; returns `nil` for other commands.
    public func handle(_ request: BridgeInvokeRequest) async -> BridgeInvokeResponse? {
        guard let command = Command(rawValue: request.command) else { return nil }
        let params: [String: AnyCodable]
        do {
            params = try Self.decodeParams(request.paramsJSON)
        } catch {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: paramsJSON malformed JSON"))
        }
        let result: AnyCodable = switch command {
        case .fileFetch: self.fileFetch(params)
        case .dirList: self.dirList(params)
        case .fileWrite: self.fileWrite(params)
        }
        let payloadJSON = (try? JSONEncoder().encode(result)).map { String(decoding: $0, as: UTF8.self) }
        return BridgeInvokeResponse(id: request.id, ok: true, payloadJSON: payloadJSON)
    }

    // MARK: - Commands

    func fileFetch(_ params: [String: AnyCodable]) -> AnyCodable {
        if params["transport"] != nil {
            return Self.error("INVALID_PARAMS", "binary file.fetch transport is not supported by this node")
        }
        let resolved: ResolvedPath
        switch self.resolveExisting(params) {
        case let .success(value): resolved = value
        case let .failure(error): return error.payload
        }
        guard !resolved.isDirectory else {
            return Self.error("IS_DIRECTORY", "path is a directory", canonical: resolved.canonical)
        }
        if let mismatch = Self.bindingMismatch(params, identity: resolved.identity, canonical: resolved.canonical) {
            return mismatch
        }
        let limit = Self.clampedLimit(params["maxBytes"], default: 8 * 1024 * 1024, hardMax: self.policy.maxBytes)
        guard resolved.size <= limit else {
            return Self.error("FILE_TOO_LARGE", "file size \(resolved.size) exceeds limit \(limit)", canonical: resolved.canonical)
        }
        if params["preflightOnly"]?.boolValue == true {
            return Self.object([
                "ok": true, "path": resolved.canonical, "size": resolved.size, "mimeType": "", "base64": "",
                "sha256": "", "preflightOnly": true, "binding": resolved.identity.existingBinding,
            ])
        }
        guard let handle = FileHandle(forReadingAtPath: resolved.canonical) else {
            return Self.error("PERMISSION_DENIED", "open failed", canonical: resolved.canonical)
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        guard data.count <= limit else {
            return Self.error("FILE_TOO_LARGE", "file grew beyond limit \(limit)", canonical: resolved.canonical)
        }
        return Self.object([
            "ok": true,
            "path": resolved.canonical,
            "size": data.count,
            "mimeType": Self.mimeType(for: resolved.canonical, data: data),
            "base64": data.base64EncodedString(),
            "sha256": Self.sha256Hex(data),
            "binding": resolved.identity.existingBinding,
        ])
    }

    func dirList(_ params: [String: AnyCodable]) -> AnyCodable {
        let resolved: ResolvedPath
        switch self.resolveExisting(params) {
        case let .success(value): resolved = value
        case let .failure(error): return error.payload
        }
        guard resolved.isDirectory else {
            return Self.error("IS_FILE", "path is a file", canonical: resolved.canonical)
        }
        if let mismatch = Self.bindingMismatch(params, identity: resolved.identity, canonical: resolved.canonical) {
            return mismatch
        }
        let maxEntries = Self.clampedLimit(params["maxEntries"], default: 200, hardMax: self.policy.maxDirectoryEntries)
        let offset = params["pageToken"]?.stringValue.flatMap { Int($0) }.map { max(0, $0) } ?? 0
        if params["preflightOnly"]?.boolValue == true {
            return Self.object([
                "ok": true, "path": resolved.canonical, "entries": [AnyCodable](), "truncated": false,
                "preflight": true, "binding": resolved.identity.existingBinding,
            ])
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: resolved.canonical).sorted()
        } catch {
            return Self.error("PERMISSION_DENIED", "read failed", canonical: resolved.canonical)
        }
        let page = names.dropFirst(offset).prefix(maxEntries)
        let entries: [AnyCodable] = page.map { name in
            let path = (resolved.canonical as NSString).appendingPathComponent(name)
            let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
            let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let modified = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            return Self.object([
                "name": name,
                "path": path,
                "size": isDirectory ? 0 : size,
                "mimeType": isDirectory ? "inode/directory" : Self.mimeType(for: path, data: nil),
                "isDir": isDirectory,
                "mtime": Int64((modified.timeIntervalSince1970 * 1000).rounded()),
            ])
        }
        let nextOffset = offset + page.count
        var result: [String: AnyCodable] = [
            "ok": AnyCodable(true),
            "path": AnyCodable(resolved.canonical),
            "entries": AnyCodable(entries),
            "truncated": AnyCodable(nextOffset < names.count),
            "binding": resolved.identity.existingBinding,
        ]
        if nextOffset < names.count {
            result["nextPageToken"] = AnyCodable(String(nextOffset))
        }
        return AnyCodable(result)
    }

    func fileWrite(_ params: [String: AnyCodable]) -> AnyCodable {
        guard let rawPath = params["path"]?.stringValue, rawPath.hasPrefix("/") else {
            return Self.error("INVALID_PATH", "path must be absolute")
        }
        guard let contentBase64 = params["contentBase64"]?.stringValue,
              let content = Self.strictBase64Decode(contentBase64)
        else {
            return Self.error("INVALID_BASE64", "contentBase64 must be strict base64")
        }
        guard content.count <= self.policy.maxBytes else {
            return Self.error("FILE_TOO_LARGE", "content size \(content.count) exceeds limit \(self.policy.maxBytes)")
        }
        let sha256 = Self.sha256Hex(content)
        if let expected = params["expectedSha256"]?.stringValue, expected.lowercased() != sha256 {
            return Self.error("SHA256_MISMATCH", "content hash does not match expectedSha256")
        }
        let overwrite = params["overwrite"]?.boolValue == true
        let createParents = params["createParents"]?.boolValue == true
        let followSymlinks = params["followSymlinks"]?.boolValue == true
        let target = Self.lexicallyNormalized(rawPath)

        // Resolve the nearest existing ancestor; it anchors the write inside an allowed root.
        var anchor = (target as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: anchor), anchor != "/" {
            anchor = (anchor as NSString).deletingLastPathComponent
        }
        guard let canonicalAnchor = Self.realPath(anchor) else {
            return Self.error("NOT_FOUND", "parent directory not found")
        }
        if !followSymlinks, canonicalAnchor != anchor {
            return Self.error("SYMLINK_REDIRECT", "parent path traverses a symlink", canonical: canonicalAnchor)
        }
        let relative = String(target.dropFirst(anchor.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let canonicalTarget = relative.isEmpty ? canonicalAnchor : (canonicalAnchor as NSString).appendingPathComponent(relative)
        guard self.isAllowed(canonicalTarget) else {
            return Self.error("PATH_TRAVERSAL", "path is outside the node's allowed roots", canonical: canonicalTarget)
        }
        guard let anchorIdentity = FileIdentity(path: canonicalAnchor) else {
            return Self.error("NOT_FOUND", "parent directory not found")
        }
        if let expected = params["expectedBinding"]?.dictionaryValue {
            guard expected["kind"]?.stringValue == "write",
                  expected["anchorDevice"]?.stringValue == anchorIdentity.device,
                  expected["anchorInode"]?.stringValue == anchorIdentity.inode
            else {
                return Self.error(
                    "CANONICAL_PATH_CHANGED",
                    "filesystem identity differs from the authorized target",
                    canonical: canonicalTarget)
            }
        }
        var existing: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: canonicalTarget, isDirectory: &existing)
        if exists, existing.boolValue {
            return Self.error("IS_DIRECTORY", "path is a directory", canonical: canonicalTarget)
        }
        if exists, !overwrite {
            return Self.error("EXISTS", "file exists and overwrite is false", canonical: canonicalTarget)
        }
        if exists, !followSymlinks, Self.isSymlink(canonicalTarget) {
            return Self.error("SYMLINK_REDIRECT", "target is a symlink", canonical: canonicalTarget)
        }
        let parent = (canonicalTarget as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: parent) {
            guard createParents else {
                return Self.error("NOT_FOUND", "parent directory not found", canonical: canonicalTarget)
            }
        }
        let binding = Self.object([
            "kind": "write",
            "anchorPath": canonicalAnchor,
            "anchorDevice": anchorIdentity.device,
            "anchorInode": anchorIdentity.inode,
        ])
        if params["preflightOnly"]?.boolValue == true {
            return Self.object([
                "ok": true, "path": canonicalTarget, "size": content.count, "sha256": sha256,
                "overwritten": exists, "preflightOnly": true, "binding": binding,
            ])
        }
        do {
            if createParents {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
            try content.write(to: URL(fileURLWithPath: canonicalTarget), options: [.atomic])
        } catch {
            return Self.error("WRITE_ERROR", "write failed", canonical: canonicalTarget)
        }
        return Self.object([
            "ok": true, "path": canonicalTarget, "size": content.count, "sha256": sha256,
            "overwritten": exists, "binding": binding,
        ])
    }

    // MARK: - Path policy

    struct ResolvedPath {
        let canonical: String
        let isDirectory: Bool
        let size: Int
        let identity: FileIdentity
    }

    struct PathError: Error {
        let payload: AnyCodable
    }

    struct FileIdentity {
        let device: String
        let inode: String

        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            self.device = String(info.st_dev)
            self.inode = String(info.st_ino)
        }

        var existingBinding: AnyCodable {
            AnyCodable(["kind": AnyCodable("existing"), "device": AnyCodable(self.device), "inode": AnyCodable(self.inode)])
        }
    }

    private func resolveExisting(_ params: [String: AnyCodable]) -> Result<ResolvedPath, PathError> {
        guard let rawPath = params["path"]?.stringValue, rawPath.hasPrefix("/") else {
            return .failure(PathError(payload: Self.error("INVALID_PATH", "path must be absolute")))
        }
        let requested = Self.lexicallyNormalized(rawPath)
        guard let canonical = Self.realPath(requested) else {
            return .failure(PathError(payload: Self.error("NOT_FOUND", "path not found")))
        }
        let followSymlinks = params["followSymlinks"]?.boolValue == true
        if !followSymlinks, canonical != requested {
            return .failure(PathError(payload: Self.error(
                "SYMLINK_REDIRECT",
                "path traverses a symlink; retry with followSymlinks",
                canonical: canonical)))
        }
        guard self.isAllowed(canonical) else {
            return .failure(PathError(payload: Self.error(
                "PATH_TRAVERSAL",
                "path is outside the node's allowed roots",
                canonical: canonical)))
        }
        if let expected = params["expectedCanonicalPath"]?.stringValue, expected != canonical {
            return .failure(PathError(payload: Self.error(
                "CANONICAL_PATH_CHANGED",
                "canonical path differs from the authorized path",
                canonical: canonical)))
        }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory)
        let size = ((try? FileManager.default.attributesOfItem(atPath: canonical))?[.size] as? NSNumber)?.intValue ?? 0
        guard let identity = FileIdentity(path: canonical) else {
            return .failure(PathError(payload: Self.error("NOT_FOUND", "path not found")))
        }
        return .success(ResolvedPath(canonical: canonical, isDirectory: isDirectory.boolValue, size: size, identity: identity))
    }

    func isAllowed(_ canonicalPath: String) -> Bool {
        self.policy.allowedRoots.contains { root in
            guard let canonicalRoot = Self.realPath(Self.lexicallyNormalized(root)) else { return false }
            let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
            return canonicalPath == canonicalRoot || canonicalPath.hasPrefix(prefix)
        }
    }

    private static func bindingMismatch(
        _ params: [String: AnyCodable],
        identity: FileIdentity,
        canonical: String) -> AnyCodable?
    {
        guard let expected = params["expectedBinding"] else { return nil }
        let object = expected.dictionaryValue ?? [:]
        guard object["kind"]?.stringValue == "existing",
              object["device"]?.stringValue == identity.device,
              object["inode"]?.stringValue == identity.inode
        else {
            return self.error(
                "CANONICAL_PATH_CHANGED",
                "filesystem identity differs from the authorized target",
                canonical: canonical)
        }
        return nil
    }

    // MARK: - Helpers

    /// Resolves `.` and `..` segments and duplicate slashes without touching the filesystem (unlike
    /// `standardizingPath`, which also strips `/private` and would hide symlink redirects).
    static func lexicallyNormalized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Decodes canonical, padded base64 only (no whitespace, no URL-safe alphabet).
    static func strictBase64Decode(_ value: String) -> Data? {
        guard value.count % 4 == 0,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") }),
              let data = Data(base64Encoded: value),
              data.base64EncodedString() == value
        else { return nil }
        return data
    }

    private static func clampedLimit(_ value: AnyCodable?, default defaultValue: Int, hardMax: Int) -> Int {
        guard let requested = value?.intValue, requested > 0 else { return min(defaultValue, hardMax) }
        return min(requested, hardMax)
    }

    private static func mimeType(for path: String, data: Data?) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "txt", "log", "md": return "text/plain"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "pdf": return "application/pdf"
        case "html", "htm": return "text/html"
        case "csv": return "text/csv"
        default:
            guard let data else { return "application/octet-stream" }
            return !data.contains(0) && String(data: data.prefix(8192), encoding: .utf8) != nil
                ? "text/plain" : "application/octet-stream"
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeParams(_ json: String?) throws -> [String: AnyCodable] {
        guard let json, !json.isEmpty else { return [:] }
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        guard let object = decoded.dictionaryValue else { throw CocoaError(.coderReadCorrupt) }
        return object
    }

    private static func error(_ code: String, _ message: String, canonical: String? = nil) -> AnyCodable {
        var object: [String: AnyCodable] = [
            "ok": AnyCodable(false),
            "code": AnyCodable(code),
            "message": AnyCodable(message),
        ]
        if let canonical {
            object["canonicalPath"] = AnyCodable(canonical)
        }
        return AnyCodable(object)
    }

    private static func object(_ values: [String: Any]) -> AnyCodable {
        AnyCodable(values.mapValues { value -> AnyCodable in
            if let value = value as? AnyCodable { return value }
            return AnyCodable.fromFoundation(value) ?? AnyCodable.nullValue
        })
    }
}
#endif
