import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Normalized media categories.
public enum MediaKind: String, Sendable {
    case image
    case audio
    case video
    case document
    case unknown
}

/// Raw media payload passed through the media pipeline.
public struct MediaBlob: Sendable, Equatable {
    /// Blob identifier.
    public let id: UUID
    /// MIME type label.
    public let mimeType: String
    /// Raw media bytes.
    public let data: Data

    /// Creates a media blob.
    /// - Parameters:
    ///   - id: Blob identifier.
    ///   - mimeType: MIME type label.
    ///   - data: Raw media bytes.
    public init(id: UUID = UUID(), mimeType: String, data: Data) {
        self.id = id
        self.mimeType = mimeType
        self.data = data
    }
}

/// Supported media inputs accepted by the staged pipeline.
public enum MediaSource: Sendable, Equatable {
    case blob(MediaBlob, fileName: String? = nil)
    case file(URL)
    case remote(URL, headers: [String: String] = [:], fileNameHint: String? = nil)
}

/// Canonical source kind recorded for one stored media handle.
public enum MediaHandleSource: String, Sendable, Equatable {
    case memory
    case localFile
    case remote
}

/// Persisted media handle describing the staged on-disk artifact for one attachment.
public struct MediaHandle: Sendable, Equatable, Identifiable {
    /// Stable handle identifier.
    public let id: UUID
    /// Source category used to produce the handle.
    public let source: MediaHandleSource
    /// Final MIME type used by runtime/provider consumers.
    public let mimeType: String
    /// Normalized media kind derived from the MIME type.
    public let kind: MediaKind
    /// Normalized file name for the staged attachment.
    public let fileName: String
    /// Stored on-disk file URL.
    public let storageURL: URL
    /// Optional original source URL.
    public let originalURL: URL?
    /// Total byte count of the staged payload.
    public let byteCount: Int
}

/// Prepared attachment returned by the staged media pipeline.
public struct PreparedMediaAttachment: Sendable, Equatable {
    /// Attachment payload used by the runtime and model providers.
    public let attachment: MediaAttachment
    /// On-disk handle describing the staged payload.
    public let handle: MediaHandle
}

/// Remote fetch result injected into the staged media pipeline.
public struct MediaRemoteFetchResult: Sendable, Equatable {
    /// Downloaded bytes.
    public let data: Data
    /// Optional MIME type supplied by the remote source.
    public let mimeType: String?
    /// Optional file name supplied by the remote source.
    public let fileName: String?
    /// Optional final URL after redirects.
    public let finalURL: URL?

    /// Creates a remote fetch result.
    /// - Parameters:
    ///   - data: Downloaded bytes.
    ///   - mimeType: Optional MIME type.
    ///   - fileName: Optional file name.
    ///   - finalURL: Optional final source URL.
    public init(data: Data, mimeType: String? = nil, fileName: String? = nil, finalURL: URL? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
        self.finalURL = finalURL
    }
}

/// Actor-backed media normalizer, fetcher, and staging pipeline.
public actor MediaPipeline {
    /// Injected remote-fetch implementation.
    public typealias RemoteFetcher = @Sendable (URL, [String: String], Int) async throws -> MediaRemoteFetchResult

    private let maxBytes: Int
    private let storageDirectory: URL
    private let allowedLocalRoots: [URL]
    private let remoteFetcher: RemoteFetcher

    /// Creates a media pipeline with the default staging policy.
    /// - Parameter maxBytes: Maximum allowed blob size.
    public init(maxBytes: Int = 10 * 1024 * 1024) {
        self.init(
            maxBytes: maxBytes,
            storageDirectory: nil,
            allowedLocalRoots: [],
            remoteFetcher: nil
        )
    }

    /// Creates a media pipeline.
    /// - Parameters:
    ///   - maxBytes: Maximum allowed blob size.
    ///   - storageDirectory: Optional on-disk staging directory override.
    ///   - allowedLocalRoots: Optional allowlisted roots for local-file ingestion.
    ///   - remoteFetcher: Optional remote-fetch implementation.
    public init(
        maxBytes: Int = 10 * 1024 * 1024,
        storageDirectory: URL? = nil,
        allowedLocalRoots: [URL] = [],
        remoteFetcher: RemoteFetcher? = nil
    ) {
        let resolvedStorageDirectory = storageDirectory ?? Self.defaultStorageDirectory()
        self.maxBytes = max(1, maxBytes)
        self.storageDirectory = resolvedStorageDirectory.standardizedFileURL
        self.allowedLocalRoots = Self.normalizeRoots(allowedLocalRoots + Self.defaultLocalRoots(storageDirectory: resolvedStorageDirectory))
        self.remoteFetcher = remoteFetcher ?? Self.urlSessionRemoteFetcher
    }

    /// Returns the on-disk staging directory used by the media pipeline.
    public func stagingDirectory() -> URL {
        self.storageDirectory
    }

    /// Returns the default allowlisted local roots used by the staged pipeline.
    /// - Parameter storageDirectory: Optional staging directory used to derive the media root.
    /// - Returns: Ordered root list.
    public static func defaultLocalRoots(storageDirectory: URL? = nil) -> [URL] {
        let resolvedStorageDirectory = (storageDirectory ?? Self.defaultStorageDirectory()).standardizedFileURL
        return Self.normalizeRoots([
            FileManager.default.temporaryDirectory
                .appendingPathComponent("openclaw", isDirectory: true),
            resolvedStorageDirectory,
            resolvedStorageDirectory.deletingLastPathComponent(),
        ])
    }

    /// Validates and normalizes a media blob.
    /// - Parameter blob: Media blob to normalize.
    /// - Returns: Unmodified blob when valid.
    public func normalize(_ blob: MediaBlob) async throws -> MediaBlob {
        guard !blob.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("mimeType must not be empty")
        }
        guard blob.data.count <= self.maxBytes else {
            throw OpenClawCoreError.unavailable("Media blob exceeds maximum supported size")
        }
        return blob
    }

    /// Classifies a MIME type into a normalized media category.
    /// - Parameter mimeType: MIME type string.
    /// - Returns: Detected media kind.
    public func kind(for mimeType: String) -> MediaKind {
        Self.kind(for: mimeType)
    }

    /// Prepares a runtime attachment and stages a matching on-disk handle.
    /// - Parameter attachment: Attachment to normalize and stage.
    /// - Returns: Prepared attachment plus stable handle metadata.
    public func prepare(_ attachment: MediaAttachment) async throws -> PreparedMediaAttachment {
        let blob = try await self.normalize(
            MediaBlob(id: attachment.id, mimeType: attachment.mimeType, data: attachment.data)
        )
        return try await self.prepareNormalized(
            blob: blob,
            fileName: attachment.fileName,
            metadata: attachment.metadata,
            source: .memory,
            originalURL: nil
        )
    }

    /// Prepares a generic media source and stages a matching on-disk handle.
    /// - Parameters:
    ///   - source: Source to load, normalize, and stage.
    ///   - additionalLocalRoots: Optional extra roots allowed for one local-file ingest.
    /// - Returns: Prepared attachment plus stable handle metadata.
    public func prepare(
        source: MediaSource,
        additionalLocalRoots: [URL] = []
    ) async throws -> PreparedMediaAttachment {
        switch source {
        case .blob(let blob, let fileName):
            return try await self.prepareNormalized(
                blob: try await self.normalize(blob),
                fileName: fileName,
                metadata: [:],
                source: .memory,
                originalURL: nil
            )
        case .file(let url):
            let localFile = try self.loadLocalFile(url, additionalLocalRoots: additionalLocalRoots)
            let blob = try await self.normalize(
                MediaBlob(
                    id: UUID(),
                    mimeType: localFile.mimeType,
                    data: localFile.data
                )
            )
            return try await self.prepareNormalized(
                blob: blob,
                fileName: localFile.fileName,
                metadata: [:],
                source: .localFile,
                originalURL: localFile.originalURL
            )
        case .remote(let url, let headers, let fileNameHint):
            let fetched = try await self.remoteFetcher(url, headers, self.maxBytes)
            let blob = try await self.normalize(
                MediaBlob(
                    id: UUID(),
                    mimeType: fetched.mimeType ?? "application/octet-stream",
                    data: fetched.data
                )
            )
            return try await self.prepareNormalized(
                blob: blob,
                fileName: fetched.fileName ?? fileNameHint ?? url.lastPathComponent,
                metadata: [:],
                source: .remote,
                originalURL: fetched.finalURL ?? url
            )
        }
    }

    /// Removes one staged handle when it exists.
    /// - Parameter handle: Handle to remove.
    public func cleanup(_ handle: MediaHandle) throws {
        if FileManager.default.fileExists(atPath: handle.storageURL.path) {
            try FileManager.default.removeItem(at: handle.storageURL)
        }
    }

    /// Removes a collection of staged handles.
    /// - Parameter handles: Handles to remove.
    public func cleanup(_ handles: [MediaHandle]) throws {
        for handle in handles {
            try self.cleanup(handle)
        }
    }

    /// Removes staged files older than the provided age.
    /// - Parameter age: Expiration age.
    /// - Returns: Removed file count.
    public func cleanupExpired(olderThan age: TimeInterval) throws -> Int {
        guard age >= 0 else {
            return 0
        }
        guard FileManager.default.fileExists(atPath: self.storageDirectory.path) else {
            return 0
        }
        let expirationDate = Date().addingTimeInterval(-age)
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: self.storageDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var removedCount = 0
        for fileURL in fileURLs {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true else {
                continue
            }
            if let modifiedAt = values.contentModificationDate, modifiedAt <= expirationDate {
                try FileManager.default.removeItem(at: fileURL)
                removedCount += 1
            }
        }
        return removedCount
    }

    private func prepareNormalized(
        blob: MediaBlob,
        fileName: String?,
        metadata: [String: String],
        source: MediaHandleSource,
        originalURL: URL?
    ) async throws -> PreparedMediaAttachment {
        let normalizedMimeType = Self.detectMime(data: blob.data, headerMime: blob.mimeType, fileName: fileName)
        let normalizedKind = Self.kind(for: normalizedMimeType)
        let normalizedFileName = Self.normalizedFileName(fileName, mimeType: normalizedMimeType, id: blob.id)
        let storageURL = try self.write(blob.data, fileName: normalizedFileName, id: blob.id)
        let handle = MediaHandle(
            id: blob.id,
            source: source,
            mimeType: normalizedMimeType,
            kind: normalizedKind,
            fileName: normalizedFileName,
            storageURL: storageURL,
            originalURL: originalURL,
            byteCount: blob.data.count
        )
        var mergedMetadata = metadata
        mergedMetadata["kind"] = normalizedKind.rawValue
        mergedMetadata["bytes"] = String(blob.data.count)
        mergedMetadata["mediaSource"] = source.rawValue
        mergedMetadata["mediaHandleID"] = handle.id.uuidString
        mergedMetadata["mediaHandlePath"] = handle.storageURL.path
        if let originalURL {
            mergedMetadata["mediaOriginalURL"] = originalURL.absoluteString
        }
        let attachment = MediaAttachment(
            id: blob.id,
            mimeType: normalizedMimeType,
            data: blob.data,
            fileName: normalizedFileName,
            metadata: mergedMetadata
        )
        return PreparedMediaAttachment(attachment: attachment, handle: handle)
    }

    private func loadLocalFile(
        _ url: URL,
        additionalLocalRoots: [URL]
    ) throws -> (data: Data, mimeType: String, fileName: String, originalURL: URL) {
        guard url.isFileURL else {
            throw OpenClawCoreError.invalidConfiguration("Media file source must use a file URL")
        }
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let effectiveRoots = Self.normalizeRoots(self.allowedLocalRoots + additionalLocalRoots)
        guard effectiveRoots.contains(where: { Self.isDescendant(resolvedURL, of: $0) }) else {
            throw OpenClawCoreError.unavailable("Media file source is outside allowed local roots")
        }
        let data = try Data(contentsOf: resolvedURL)
        guard data.count <= self.maxBytes else {
            throw OpenClawCoreError.unavailable("Media blob exceeds maximum supported size")
        }
        let fileName = resolvedURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            data,
            Self.detectMime(data: data, headerMime: nil, fileName: fileName),
            fileName,
            resolvedURL
        )
    }

    private func write(_ data: Data, fileName: String, id: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
        let baseName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: fileName).pathExtension
        let storedName: String
        if ext.isEmpty {
            storedName = "\(baseName)---\(id.uuidString)"
        } else {
            storedName = "\(baseName)---\(id.uuidString).\(ext)"
        }
        let destination = self.storageDirectory.appendingPathComponent(storedName, isDirectory: false)
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    private static func defaultStorageDirectory() -> URL {
        let rootDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenClaw", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("openclaw", isDirectory: true)
        return rootDirectory.appendingPathComponent("media", isDirectory: true)
    }

    private static func urlSessionRemoteFetcher(
        url: URL,
        headers: [String: String],
        maxBytes: Int
    ) async throws -> MediaRemoteFetchResult {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw OpenClawCoreError.invalidConfiguration("Media remote source must use HTTP or HTTPS")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse {
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw OpenClawCoreError.unavailable("Media remote source failed with status \(httpResponse.statusCode)")
            }
        }
        guard data.count <= maxBytes else {
            throw OpenClawCoreError.unavailable("Media blob exceeds maximum supported size")
        }
        return MediaRemoteFetchResult(
            data: data,
            mimeType: response.mimeType,
            fileName: response.suggestedFilename,
            finalURL: response.url
        )
    }

    private static func normalizeRoots(_ roots: [URL]) -> [URL] {
        var normalized: [URL] = []
        var seen: Set<String> = []
        for root in roots {
            guard root.isFileURL else {
                continue
            }
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let path = resolvedRoot.path
            if seen.insert(path).inserted {
                normalized.append(resolvedRoot)
            }
        }
        return normalized
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        if candidatePath == rootPath {
            return true
        }
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func normalizeMimeType(_ mimeType: String?) -> String? {
        guard let mimeType else {
            return nil
        }
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalized, !normalized.isEmpty {
            return normalized
        }
        return nil
    }

    private static func kind(for mimeType: String) -> MediaKind {
        let normalized = Self.normalizeMimeType(mimeType) ?? ""
        if normalized.hasPrefix("image/") { return .image }
        if normalized.hasPrefix("audio/") { return .audio }
        if normalized.hasPrefix("video/") { return .video }
        if normalized.hasPrefix("application/") || normalized.hasPrefix("text/") { return .document }
        return .unknown
    }

    private static func detectMime(data: Data, headerMime: String?, fileName: String?) -> String {
        let sniffedMimeType = Self.sniffMime(data)
        let fileExtensionMimeType = Self.mimeType(forFileName: fileName)
        let normalizedHeaderMimeType = Self.normalizeMimeType(headerMime)
        if sniffedMimeType != "application/octet-stream" {
            if sniffedMimeType == "text/plain",
               let normalizedHeaderMimeType,
               normalizedHeaderMimeType != "application/octet-stream",
               normalizedHeaderMimeType != sniffedMimeType
            {
                return fileExtensionMimeType ?? normalizedHeaderMimeType
            }
            return sniffedMimeType
        }
        if let fileExtensionMimeType {
            return fileExtensionMimeType
        }
        return normalizedHeaderMimeType ?? sniffedMimeType
    }

    private static func sniffMime(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.starts(with: Array("%PDF".utf8)) { return "application/pdf" }
        if bytes.starts(with: Array("ID3".utf8)) { return "audio/mpeg" }
        if bytes.starts(with: Array("OggS".utf8)) { return "audio/ogg" }
        if bytes.count >= 12,
           Array(bytes[0...3]) == [0x52, 0x49, 0x46, 0x46],
           Array(bytes[8...11]) == [0x57, 0x41, 0x56, 0x45]
        {
            return "audio/wav"
        }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "application/zip" }
        if let text = String(data: data.prefix(512), encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                return "application/json"
            }
            if !trimmed.isEmpty {
                return "text/plain"
            }
        }
        return "application/octet-stream"
    }

    private static func mimeType(forFileName fileName: String?) -> String? {
        guard let fileName else {
            return nil
        }
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch ext {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "pdf":
            return "application/pdf"
        case "json":
            return "application/json"
        case "txt", "md":
            return "text/plain"
        case "wav":
            return "audio/wav"
        case "ogg":
            return "audio/ogg"
        case "mp3":
            return "audio/mpeg"
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        default:
            return nil
        }
    }

    private static func fileExtension(forMimeType mimeType: String) -> String? {
        switch Self.normalizeMimeType(mimeType) {
        case "image/png":
            return "png"
        case "image/jpeg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "application/pdf":
            return "pdf"
        case "application/json":
            return "json"
        case "text/plain":
            return "txt"
        case "audio/wav":
            return "wav"
        case "audio/ogg":
            return "ogg"
        case "audio/mpeg":
            return "mp3"
        case "video/mp4":
            return "mp4"
        case "video/quicktime":
            return "mov"
        default:
            return nil
        }
    }

    private static func normalizedFileName(_ fileName: String?, mimeType: String, id: UUID) -> String {
        let rawName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parsedURL = rawName.isEmpty ? nil : URL(fileURLWithPath: rawName)
        var baseName = parsedURL?.deletingPathExtension().lastPathComponent ?? ""
        var ext = parsedURL?.pathExtension.lowercased() ?? ""
        if baseName.isEmpty {
            baseName = "attachment-\(id.uuidString.prefix(8))"
        }
        baseName = Self.sanitizeFileNameComponent(baseName)
        if baseName.isEmpty {
            baseName = "attachment-\(id.uuidString.prefix(8))"
        }
        if ext.isEmpty, let inferredExt = Self.fileExtension(forMimeType: mimeType) {
            ext = inferredExt
        }
        if ext.isEmpty {
            return baseName
        }
        return "\(baseName).\(ext)"
    }

    private static func sanitizeFileNameComponent(_ value: String) -> String {
        let filteredScalars = value.unicodeScalars.map { scalar -> UnicodeScalar in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-" {
                return scalar
            }
            return "_"
        }
        let sanitized = String(String.UnicodeScalarView(filteredScalars))
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return sanitized
    }
}
