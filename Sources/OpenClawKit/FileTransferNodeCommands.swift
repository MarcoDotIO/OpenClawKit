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
/// refused unless `followSymlinks` is true, `file.write` requires strict (padded or unpadded, standard or
/// URL-safe) base64, and every round trip is bounded by ``FileTransferPolicy/maxBytes``. Files are read
/// and written through descriptors whose identity and real path are verified against the authorized
/// target, so a path swapped after preflight is refused rather than followed. `dir.fetch` (archive streaming) and binary transport
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
        // Every remaining check runs on the opened descriptor, so a path swapped after the checks
        // above can never be read (and a FIFO cannot block the handler).
        let opened: OpenedPath
        switch self.openVerified(resolved, params: params, directory: false) {
        case let .success(value): opened = value
        case let .failure(error): return error.payload
        }
        defer { close(opened.descriptor) }
        let limit = Self.clampedLimit(params["maxBytes"], default: 8 * 1024 * 1024, hardMax: self.policy.maxBytes)
        guard opened.size <= limit else {
            return Self.error("FILE_TOO_LARGE", "file size \(opened.size) exceeds limit \(limit)", canonical: opened.path)
        }
        if params["preflightOnly"]?.boolValue == true {
            return Self.object([
                "ok": true, "path": opened.path, "size": opened.size, "mimeType": "", "base64": "",
                "sha256": "", "preflightOnly": true, "binding": opened.identity.existingBinding,
            ])
        }
        let flags = fcntl(opened.descriptor, F_GETFL)
        guard flags >= 0, fcntl(opened.descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            return Self.error("READ_ERROR", "read failed", canonical: opened.path)
        }
        let handle = FileHandle(fileDescriptor: opened.descriptor, closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            return Self.error("READ_ERROR", "read failed", canonical: opened.path)
        }
        guard data.count <= limit else {
            return Self.error("FILE_TOO_LARGE", "file grew beyond limit \(limit)", canonical: opened.path)
        }
        return Self.object([
            "ok": true,
            "path": opened.path,
            "size": data.count,
            "mimeType": Self.mimeType(for: opened.path, data: data),
            "base64": data.base64EncodedString(),
            "sha256": Self.sha256Hex(data),
            "binding": opened.identity.existingBinding,
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
        let opened: OpenedPath
        switch self.openVerified(resolved, params: params, directory: true) {
        case let .success(value): opened = value
        case let .failure(error): return error.payload
        }
        defer { close(opened.descriptor) }
        let maxEntries = Self.clampedLimit(params["maxEntries"], default: 200, hardMax: self.policy.maxDirectoryEntries)
        let offset = params["pageToken"]?.stringValue.flatMap { Int($0) }.map { max(0, $0) } ?? 0
        if params["preflightOnly"]?.boolValue == true {
            return Self.object([
                "ok": true, "path": opened.path, "entries": [AnyCodable](), "truncated": false,
                "preflight": true, "binding": opened.identity.existingBinding,
            ])
        }
        guard let names = Self.directoryEntryNames(opened.descriptor)?.sorted() else {
            return Self.error("PERMISSION_DENIED", "read failed", canonical: opened.path)
        }
        let page = names.dropFirst(offset).prefix(maxEntries)
        let entries: [AnyCodable] = page.map { name in
            let path = (opened.path as NSString).appendingPathComponent(name)
            var info = stat()
            let found = fstatat(opened.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            let isDirectory = found && (info.st_mode & S_IFMT) == S_IFDIR
            let size = found && !isDirectory ? Int(info.st_size) : 0
            let modifiedMs = found
                ? Int64(((Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9) * 1000).rounded())
                : 0
            return Self.object([
                "name": name,
                "path": path,
                "size": size,
                "mimeType": isDirectory ? "inode/directory" : Self.mimeType(for: path, data: nil),
                "isDir": isDirectory,
                "mtime": modifiedMs,
            ])
        }
        let nextOffset = offset + page.count
        var result: [String: AnyCodable] = [
            "ok": AnyCodable(true),
            "path": AnyCodable(opened.path),
            "entries": AnyCodable(entries),
            "truncated": AnyCodable(nextOffset < names.count),
            "binding": opened.identity.existingBinding,
        ]
        if nextOffset < names.count {
            result["nextPageToken"] = AnyCodable(String(nextOffset))
        }
        return AnyCodable(result)
    }

    func fileWrite(_ params: [String: AnyCodable]) -> AnyCodable {
        let request: WriteRequest
        switch Self.writeRequest(params, maxBytes: self.policy.maxBytes) {
        case let .success(value): request = value
        case let .failure(error): return error.payload
        }
        let target: WriteTarget
        switch self.resolveWriteTarget(request, params: params) {
        case let .success(value): target = value
        case let .failure(error): return error.payload
        }
        if let expected = request.expectedSha256, expected.lowercased() != request.sha256 {
            return Self.error(
                "INTEGRITY_FAILURE",
                "sha256 mismatch: expected \(expected.lowercased()), got \(request.sha256)",
                canonical: target.canonical)
        }
        if request.preflightOnly {
            var binding: [String: Any] = [
                "kind": "write",
                "anchorPath": target.anchorPath,
                "anchorDevice": target.anchorIdentity.device,
                "anchorInode": target.anchorIdentity.inode,
            ]
            if let existing = target.existingIdentity {
                binding["targetDevice"] = existing.device
                binding["targetInode"] = existing.inode
            }
            var result: [String: Any] = [
                "ok": true, "path": target.canonical, "size": request.content.count, "sha256": request.sha256,
                "overwritten": target.existingIdentity != nil, "preflightOnly": true, "binding": Self.object(binding),
            ]
            if request.rejectHardlinks {
                result["rejectHardlinks"] = true
            }
            return Self.object(result)
        }
        let written: WrittenFile
        switch self.performWrite(request, target: target) {
        case let .success(value): written = value
        case let .failure(error): return error.payload
        }
        return Self.object([
            "ok": true, "path": written.path, "size": request.content.count, "sha256": request.sha256,
            "overwritten": written.overwritten, "binding": written.identity.existingBinding,
        ])
    }

    // MARK: - Path policy

    struct ResolvedPath {
        let canonical: String
        let isDirectory: Bool
        let identity: FileIdentity
    }

    /// A descriptor whose identity and real path were verified against the authorized path.
    struct OpenedPath {
        let descriptor: Int32
        let path: String
        let size: Int
        let identity: FileIdentity
    }

    struct PathError: Error {
        let payload: AnyCodable
    }

    struct FileIdentity: Equatable {
        let device: String
        let inode: String

        init(device: String, inode: String) {
            self.device = device
            self.inode = inode
        }

        init(_ info: stat) {
            self.device = String(info.st_dev)
            self.inode = String(info.st_ino)
        }

        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            self.init(info)
        }

        var existingBinding: AnyCodable {
            AnyCodable(["kind": AnyCodable("existing"), "device": AnyCodable(self.device), "inode": AnyCodable(self.inode)])
        }
    }

    func resolveExisting(_ params: [String: AnyCodable]) -> Result<ResolvedPath, PathError> {
        guard let rawPath = params["path"]?.stringValue, !rawPath.isEmpty else {
            return .failure(PathError(payload: Self.error("INVALID_PATH", "path required")))
        }
        guard !rawPath.utf8.contains(0) else {
            return .failure(PathError(payload: Self.error("INVALID_PATH", "path contains NUL byte")))
        }
        guard rawPath.hasPrefix("/") else {
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
        var info = stat()
        guard lstat(canonical, &info) == 0 else {
            return .failure(PathError(payload: Self.error("NOT_FOUND", "path not found")))
        }
        return .success(ResolvedPath(
            canonical: canonical,
            isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
            identity: FileIdentity(info)))
    }

    /// Opens `resolved` without following a final symlink (and without blocking on a FIFO), then
    /// requires the descriptor to be a regular file (or a directory), to keep the identity checked
    /// by path, to match any expected binding, and to really live at the authorized canonical path
    /// inside the allowed roots (`F_GETPATH`, which also catches a swapped parent directory).
    func openVerified(
        _ resolved: ResolvedPath,
        params: [String: AnyCodable],
        directory: Bool) -> Result<OpenedPath, PathError>
    {
        let canonical = resolved.canonical
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : O_NONBLOCK)
        let descriptor = open(canonical, flags)
        guard descriptor >= 0 else {
            let failure = errno
            let payload: AnyCodable = switch failure {
            case ELOOP:
                Self.error("SYMLINK_REDIRECT", "path became a symlink; retry with followSymlinks", canonical: canonical)
            case ENOTDIR where directory:
                Self.error("IS_FILE", "path is a file", canonical: canonical)
            case ENOENT, ENOTDIR:
                Self.error("NOT_FOUND", "path not found", canonical: canonical)
            case EACCES, EPERM:
                Self.error("PERMISSION_DENIED", "open failed", canonical: canonical)
            default:
                Self.error("READ_ERROR", "open failed", canonical: canonical)
            }
            return .failure(PathError(payload: payload))
        }
        func fail(_ code: String, _ message: String, _ path: String = canonical) -> Result<OpenedPath, PathError> {
            close(descriptor)
            return .failure(PathError(payload: Self.error(code, message, canonical: path)))
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return fail("READ_ERROR", "stat failed") }
        let kind = info.st_mode & S_IFMT
        if directory {
            guard kind == S_IFDIR else { return fail("IS_FILE", "path is a file") }
        } else {
            guard kind != S_IFDIR else { return fail("IS_DIRECTORY", "path is a directory") }
            guard kind == S_IFREG else { return fail("IS_DIRECTORY", "path is not a regular file") }
        }
        let identity = FileIdentity(info)
        guard identity == resolved.identity else {
            return fail("CANONICAL_PATH_CHANGED", "filesystem identity changed while opening")
        }
        if let mismatch = Self.bindingMismatch(params, identity: identity, canonical: canonical) {
            close(descriptor)
            return .failure(PathError(payload: mismatch))
        }
        guard let openedPath = Self.descriptorPath(descriptor) else { return fail("READ_ERROR", "open failed") }
        guard openedPath == canonical, self.isAllowed(openedPath) else {
            return fail("CANONICAL_PATH_CHANGED", "opened path differs from the authorized path", openedPath)
        }
        return .success(OpenedPath(descriptor: descriptor, path: openedPath, size: Int(info.st_size), identity: identity))
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

    // MARK: - Writes

    struct WriteRequest {
        let rawPath: String
        let content: Data
        let sha256: String
        let expectedSha256: String?
        let overwrite: Bool
        let createParents: Bool
        let followSymlinks: Bool
        let rejectHardlinks: Bool
        let preflightOnly: Bool
    }

    /// The anchor binding the gateway authorized in preflight (`expectedBinding`, kind `write`).
    struct WriteBinding {
        let anchorPath: String
        let anchorIdentity: FileIdentity
        let targetIdentity: FileIdentity?

        /// Mirrors upstream `readPathBinding`: `nil` unless it is a complete `write` binding.
        init?(_ value: AnyCodable?) {
            guard let object = value?.dictionaryValue,
                  object["kind"]?.stringValue == "write",
                  let anchorPath = object["anchorPath"]?.stringValue,
                  let anchorDevice = object["anchorDevice"]?.stringValue,
                  let anchorInode = object["anchorInode"]?.stringValue
            else { return nil }
            let targetDevice = object["targetDevice"]?.stringValue
            let targetInode = object["targetInode"]?.stringValue
            guard (targetDevice == nil) == (targetInode == nil) else { return nil }
            self.anchorPath = anchorPath
            self.anchorIdentity = FileIdentity(device: anchorDevice, inode: anchorInode)
            self.targetIdentity = targetDevice.flatMap { device in
                targetInode.map { FileIdentity(device: device, inode: $0) }
            }
        }
    }

    struct WriteTarget {
        /// Canonical target path (canonical nearest existing ancestor plus the missing components).
        let canonical: String
        /// Canonical nearest existing ancestor directory.
        let anchorPath: String
        let anchorIdentity: FileIdentity
        /// Identity of the existing target file, when it exists.
        let existingIdentity: FileIdentity?
        let binding: WriteBinding?
    }

    struct WrittenFile {
        let path: String
        let overwritten: Bool
        let identity: FileIdentity
    }

    private static func writeRequest(_ params: [String: AnyCodable], maxBytes: Int) -> Result<WriteRequest, PathError> {
        func failure(_ code: String, _ message: String) -> Result<WriteRequest, PathError> {
            .failure(PathError(payload: Self.error(code, message)))
        }
        guard let rawPath = params["path"]?.stringValue, !rawPath.isEmpty else {
            return failure("INVALID_PATH", "path is required")
        }
        guard !rawPath.utf8.contains(0) else { return failure("INVALID_PATH", "path must not contain NUL bytes") }
        guard rawPath.hasPrefix("/") else { return failure("INVALID_PATH", "path must be absolute") }
        guard let contentBase64 = params["contentBase64"]?.stringValue else {
            return failure("INVALID_BASE64", "contentBase64 is required")
        }
        // Validate and bound the decoded size before allocating the decode buffer.
        guard let decodedBytes = Self.inspectStrictBase64(contentBase64) else {
            return failure("INVALID_BASE64", "contentBase64 is not valid base64")
        }
        guard decodedBytes <= maxBytes else {
            return failure("FILE_TOO_LARGE", "decoded content is \(decodedBytes) bytes; maximum is \(maxBytes) bytes")
        }
        guard let content = Self.strictBase64Decode(contentBase64) else {
            return failure("INVALID_BASE64", "contentBase64 is not valid base64")
        }
        return .success(WriteRequest(
            rawPath: rawPath,
            content: content,
            sha256: Self.sha256Hex(content),
            expectedSha256: params["expectedSha256"]?.stringValue,
            overwrite: params["overwrite"]?.boolValue == true,
            createParents: params["createParents"]?.boolValue == true,
            followSymlinks: params["followSymlinks"]?.boolValue == true,
            rejectHardlinks: params["rejectHardlinks"]?.boolValue == true,
            preflightOnly: params["preflightOnly"]?.boolValue == true))
    }

    /// Resolves the canonical target and rejects drift from what the gateway authorized
    /// (`expectedCanonicalPath`, `expectedBinding`) before anything touches the disk.
    private func resolveWriteTarget(
        _ request: WriteRequest,
        params: [String: AnyCodable]) -> Result<WriteTarget, PathError>
    {
        func failure(_ code: String, _ message: String, _ canonical: String? = nil) -> Result<WriteTarget, PathError> {
            .failure(PathError(payload: Self.error(code, message, canonical: canonical)))
        }
        let target = Self.lexicallyNormalized(request.rawPath)
        // The nearest existing ancestor anchors the write inside an allowed root.
        var anchor = (target as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: anchor), anchor != "/" {
            anchor = (anchor as NSString).deletingLastPathComponent
        }
        guard let canonicalAnchor = Self.realPath(anchor) else {
            return failure("PARENT_NOT_FOUND", "parent directory does not exist")
        }
        let relative = String(target.dropFirst(anchor.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let canonicalTarget = relative.isEmpty ? canonicalAnchor : (canonicalAnchor as NSString).appendingPathComponent(relative)
        if !request.followSymlinks, canonicalAnchor != anchor {
            return failure("SYMLINK_REDIRECT", "parent path traverses a symlink; retry with followSymlinks", canonicalTarget)
        }
        guard self.isAllowed(canonicalTarget) else {
            return failure("PATH_TRAVERSAL", "path is outside the node's allowed roots", canonicalTarget)
        }
        if let expected = params["expectedCanonicalPath"]?.stringValue, expected != canonicalTarget {
            return failure("CANONICAL_PATH_CHANGED", "canonical path differs from the authorized target", canonicalTarget)
        }
        let binding = WriteBinding(params["expectedBinding"])
        if params["expectedBinding"] != nil, binding == nil {
            return failure("CANONICAL_PATH_CHANGED", "filesystem identity differs from the authorized target", canonicalTarget)
        }
        guard let anchorIdentity = FileIdentity(path: canonicalAnchor) else {
            return failure("PARENT_NOT_FOUND", "parent directory does not exist")
        }
        var existingIdentity: FileIdentity?
        var info = stat()
        if lstat(canonicalTarget, &info) == 0 {
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                // Never write through a final symlink; without followSymlinks, report where it points.
                return request.followSymlinks
                    ? failure("SYMLINK_TARGET_DENIED", "path is a symlink; refusing to write through it", canonicalTarget)
                    : failure(
                        "SYMLINK_REDIRECT",
                        "path is a symlink; retry with followSymlinks",
                        Self.realPath(canonicalTarget) ?? canonicalTarget)
            case S_IFDIR:
                return failure("IS_DIRECTORY", "path resolves to a directory", canonicalTarget)
            default:
                break
            }
            guard request.overwrite else {
                return failure("EXISTS_NO_OVERWRITE", "file already exists and overwrite is false", canonicalTarget)
            }
            if request.rejectHardlinks, info.st_nlink > 1 {
                return failure("HARDLINK_TARGET_DENIED", "refusing to overwrite a file with hard links", canonicalTarget)
            }
            existingIdentity = FileIdentity(info)
        } else if errno != ENOENT {
            return failure("PERMISSION_DENIED", "cannot inspect the target", canonicalTarget)
        }
        let parent = (canonicalTarget as NSString).deletingLastPathComponent
        if !request.createParents, !FileManager.default.fileExists(atPath: parent) {
            return failure("PARENT_NOT_FOUND", "parent directory does not exist", canonicalTarget)
        }
        return .success(WriteTarget(
            canonical: canonicalTarget,
            anchorPath: canonicalAnchor,
            anchorIdentity: anchorIdentity,
            existingIdentity: existingIdentity,
            binding: binding))
    }

    /// Writes relative to a verified anchor descriptor: missing parents are created with `mkdirat`,
    /// every component is opened without following symlinks, a bound existing target is overwritten
    /// in place only if it is still the authorized inode, and a new file is created exclusively.
    private func performWrite(_ request: WriteRequest, target: WriteTarget) -> Result<WrittenFile, PathError> {
        let canonical = target.canonical
        func failure(_ code: String, _ message: String) -> Result<WrittenFile, PathError> {
            .failure(PathError(payload: Self.error(code, message, canonical: canonical)))
        }
        func changed() -> Result<WrittenFile, PathError> {
            failure("CANONICAL_PATH_CHANGED", "filesystem identity differs from the authorized target")
        }
        let anchorPath = target.binding?.anchorPath ?? target.anchorPath
        let anchorIdentity = target.binding?.anchorIdentity ?? target.anchorIdentity
        let anchorPrefix = anchorPath.hasSuffix("/") ? anchorPath : anchorPath + "/"
        guard canonical.hasPrefix(anchorPrefix) else {
            return failure("WRITE_ERROR", "write target is outside the authorized anchor")
        }
        let components = canonical.dropFirst(anchorPrefix.count).split(separator: "/").map(String.init)
        guard let name = components.last, !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return failure("WRITE_ERROR", "write target is outside the authorized anchor")
        }
        var directory = open(anchorPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return changed() }
        defer { close(directory) }
        var anchorInfo = stat()
        guard fstat(directory, &anchorInfo) == 0,
              FileIdentity(anchorInfo) == anchorIdentity,
              Self.descriptorPath(directory) == anchorPath
        else { return changed() }
        for component in components.dropLast() {
            if mkdirat(directory, component, 0o777) != 0, errno != EEXIST {
                return failure("WRITE_ERROR", "failed to create parent directories")
            }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return changed() }
            close(directory)
            directory = next
        }
        if let expected = target.binding?.targetIdentity {
            return Self.overwriteBound(request, directory: directory, name: name, expected: expected, canonical: canonical)
        }
        if target.binding == nil, request.overwrite, target.existingIdentity != nil {
            return Self.replaceAtomically(request, directory: directory, name: name, canonical: canonical)
        }
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else {
            // With a binding, a target that appeared after preflight is drift, not a plain conflict.
            if errno == EEXIST {
                return target.binding == nil
                    ? failure("EXISTS_NO_OVERWRITE", "file already exists and overwrite is false")
                    : changed()
            }
            return failure(errno == EACCES || errno == EPERM ? "PERMISSION_DENIED" : "WRITE_ERROR", "failed to create file")
        }
        defer { close(descriptor) }
        guard Self.writeAll(request.content, to: descriptor), fsync(descriptor) == 0 else {
            unlinkat(directory, name, 0)
            return failure("WRITE_ERROR", "failed to write file")
        }
        return Self.writtenFile(descriptor, overwritten: false, canonical: canonical)
    }

    private static func overwriteBound(
        _ request: WriteRequest,
        directory: Int32,
        name: String,
        expected: FileIdentity,
        canonical: String) -> Result<WrittenFile, PathError>
    {
        let changed = Result<WrittenFile, PathError>.failure(PathError(payload: Self.error(
            "CANONICAL_PATH_CHANGED",
            "filesystem identity differs from the authorized target",
            canonical: canonical)))
        let descriptor = openat(directory, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return changed }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, FileIdentity(info) == expected else {
            return changed
        }
        if request.rejectHardlinks, info.st_nlink > 1 {
            return .failure(PathError(payload: Self.error(
                "HARDLINK_TARGET_DENIED",
                "refusing to overwrite a file with hard links",
                canonical: canonical)))
        }
        // Preserve the authorized inode: write in place, then drop any tail beyond the new content.
        guard Self.writeAll(request.content, to: descriptor),
              ftruncate(descriptor, off_t(request.content.count)) == 0,
              fsync(descriptor) == 0
        else {
            return .failure(PathError(payload: Self.error("WRITE_ERROR", "failed to write file", canonical: canonical)))
        }
        return Self.writtenFile(descriptor, overwritten: true, canonical: canonical)
    }

    private static func replaceAtomically(
        _ request: WriteRequest,
        directory: Int32,
        name: String,
        canonical: String) -> Result<WrittenFile, PathError>
    {
        let failure = Result<WrittenFile, PathError>.failure(PathError(payload: Self.error(
            "WRITE_ERROR",
            "failed to write file",
            canonical: canonical)))
        let temporary = ".\(name).openclaw-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { return failure }
        defer { close(descriptor) }
        // rename(2) replaces the directory entry itself and never follows a symlink placed there.
        guard Self.writeAll(request.content, to: descriptor),
              fsync(descriptor) == 0,
              renameat(directory, temporary, directory, name) == 0
        else {
            unlinkat(directory, temporary, 0)
            return failure
        }
        return Self.writtenFile(descriptor, overwritten: true, canonical: canonical)
    }

    private static func writtenFile(_ descriptor: Int32, overwritten: Bool, canonical: String) -> Result<WrittenFile, PathError> {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            return .failure(PathError(payload: Self.error("WRITE_ERROR", "failed to stat written file", canonical: canonical)))
        }
        return .success(WrittenFile(path: canonical, overwritten: overwritten, identity: FileIdentity(info)))
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    // MARK: - Helpers

    /// Real path of an open descriptor (`F_GETPATH`).
    static func descriptorPath(_ descriptor: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Entry names of an open directory, read through the descriptor (never by path).
    private static func directoryEntryNames(_ descriptor: Int32) -> [String]? {
        let enumeration = dup(descriptor)
        guard enumeration >= 0 else { return nil }
        guard let stream = fdopendir(enumeration) else {
            close(enumeration)
            return nil
        }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return errno == 0 ? names : nil
    }

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

    /// Validates base64 structure like upstream `inspectStrictBase64`: the standard and URL-safe
    /// alphabets, optional `=` padding (at most two, only as a tail), and no length remainder of 1.
    /// - Returns: The decoded size, or `nil` when malformed.
    static func inspectStrictBase64(_ value: String) -> Int? {
        var dataCharacters = 0
        var padding = 0
        for byte in value.utf8 {
            if byte == UInt8(ascii: "=") {
                padding += 1
                guard padding <= 2 else { return nil }
                continue
            }
            let isData = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
            guard padding == 0, isData else { return nil }
            dataCharacters += 1
        }
        guard dataCharacters > 0 else { return padding == 0 ? 0 : nil }
        let remainder = dataCharacters % 4
        if padding == 0 {
            return remainder == 1 ? nil : dataCharacters * 3 / 4
        }
        guard (dataCharacters + padding) % 4 == 0,
              (padding == 1 && remainder == 3) || (padding == 2 && remainder == 2)
        else { return nil }
        return dataCharacters * 3 / 4
    }

    /// Decodes base64 the way upstream `file.write` accepts it (padded or unpadded, standard or
    /// URL-safe), rejecting input whose decoded bytes do not re-encode to the same characters.
    static func strictBase64Decode(_ value: String) -> Data? {
        guard self.inspectStrictBase64(value) != nil else { return nil }
        var unpadded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while unpadded.hasSuffix("=") {
            unpadded.removeLast()
        }
        let remainder = unpadded.utf8.count % 4
        let padded = remainder == 0 ? unpadded : unpadded + String(repeating: "=", count: 4 - remainder)
        guard let data = Data(base64Encoded: padded) else { return nil }
        var reEncoded = data.base64EncodedString()
        while reEncoded.hasSuffix("=") {
            reEncoded.removeLast()
        }
        return reEncoded == unpadded ? data : nil
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
