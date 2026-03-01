import Foundation

/// Binary media attachment carried by protocol and runtime surfaces.
public struct MediaAttachment: Codable, Sendable, Equatable, Identifiable {
    /// Stable attachment identifier.
    public let id: UUID
    /// MIME type for attachment payload.
    public let mimeType: String
    /// Raw attachment bytes.
    public let data: Data
    /// Optional source file name.
    public let fileName: String?
    /// Optional metadata bag.
    public let metadata: [String: String]

    /// Creates a media attachment payload.
    /// - Parameters:
    ///   - id: Stable attachment identifier.
    ///   - mimeType: MIME type label.
    ///   - data: Raw bytes.
    ///   - fileName: Optional source file name.
    ///   - metadata: Optional metadata bag.
    public init(
        id: UUID = UUID(),
        mimeType: String,
        data: Data,
        fileName: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.mimeType = mimeType
        self.data = data
        self.fileName = fileName
        self.metadata = metadata
    }

    /// Attachment byte size.
    public var byteCount: Int {
        self.data.count
    }
}
