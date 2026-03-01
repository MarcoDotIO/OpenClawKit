import Foundation
import OpenClawCore

private struct TelegramUpdateOffsetState: Codable {
    let version: Int
    let lastUpdateID: Int64?

    private enum CodingKeys: String, CodingKey {
        case version
        case lastUpdateID = "lastUpdateId"
    }
}

/// Storage contract for remembering the latest processed Telegram update ID.
public protocol TelegramUpdateOffsetStore: Sendable {
    /// Returns the most recently persisted Telegram update ID.
    func readLastUpdateID() async -> Int64?

    /// Persists the latest processed Telegram update ID.
    func writeLastUpdateID(_ updateID: Int64) async
}

/// File-backed Telegram update offset store used by default adapter instances.
public actor FileTelegramUpdateOffsetStore: TelegramUpdateOffsetStore {
    private static let currentVersion = 1
    private let fileURL: URL

    /// Creates a file-backed store.
    /// - Parameter fileURL: Optional override for offset file location.
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = OpenClawFileSystem.resolveHomeDirectory()
                .appendingPathComponent(".openclaw", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
                .appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("update-offset-default.json", isDirectory: false)
        }
    }

    public func readLastUpdateID() async -> Int64? {
        guard let data = try? Data(contentsOf: self.fileURL),
              let decoded = try? JSONDecoder().decode(TelegramUpdateOffsetState.self, from: data),
              decoded.version == Self.currentVersion
        else {
            return nil
        }
        return decoded.lastUpdateID
    }

    public func writeLastUpdateID(_ updateID: Int64) async {
        let state = TelegramUpdateOffsetState(version: Self.currentVersion, lastUpdateID: updateID)
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: self.fileURL, options: [.atomic])
            #if !os(Windows)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: self.fileURL.path
            )
            #endif
        } catch {
            // Best-effort persistence; runtime polling continues even when writes fail.
        }
    }
}
