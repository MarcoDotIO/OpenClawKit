import Foundation
import OpenClawCore
import OpenClawMedia
import OpenClawProtocol

/// `music_analyze` agent tool: analyzes an audio attachment or local audio file with on-device music
/// understanding (key, tempo/BPM, structure, loudness, pace, instrument activity) and returns a compact
/// JSON ``MusicAnalysisSummary`` with all times in seconds.
///
/// The analysis service lives in OpenClawMedia (``MusicAnalyzing``; ``AppleMusicAnalyzerService`` uses
/// MusicUnderstanding on Apple platforms at version 27). This adapter sits in OpenClawAgents because
/// OpenClawMedia cannot depend on the agent-tool contract. Because the tool publishes an
/// ``AgentToolDescriptor``, the Apple Foundation Models tool bridge can expose it as an FM tool too.
///
/// Arguments: `attachmentId` (UUID or file name of an attachment supplied through the resolver) or
/// `path` (absolute path under ``allowedRoots``), plus optional `analyses` (names from
/// ``MusicAnalysisKind``; defaults to all six). Protected (DRM) audio yields an error result.
public struct MusicAnalyzeTool: AgentTool {
    /// Resolves an attachment reference (UUID string or file name) to its attachment.
    public typealias AttachmentResolver = @Sendable (String) async -> MediaAttachment?

    /// Model-facing tool name.
    public static let toolName = "music_analyze"

    /// Stable tool name.
    public let name = MusicAnalyzeTool.toolName

    /// Local roots a `path` argument must stay inside.
    public let allowedRoots: [URL]

    private let analyzer: (any MusicAnalyzing)?
    private let attachmentResolver: AttachmentResolver?
    private let fileMaterializer: MediaUnderstandingPreprocessor

    /// Creates the tool.
    /// - Parameters:
    ///   - analyzer: Music analysis service; defaults to the platform's (nil when unavailable).
    ///   - allowedRoots: Roots a `path` argument must stay inside; defaults to ``MediaPipeline/defaultLocalRoots(storageDirectory:)``.
    ///   - attachmentResolver: Resolves `attachmentId` arguments; `nil` disables attachment references.
    ///   - scratchDirectory: Directory for temporary copies of attachments.
    public init(
        analyzer: (any MusicAnalyzing)? = MediaUnderstandingServices.platformDefault.music,
        allowedRoots: [URL] = MediaPipeline.defaultLocalRoots(),
        attachmentResolver: AttachmentResolver? = nil,
        scratchDirectory: URL? = nil
    ) {
        self.analyzer = analyzer
        self.allowedRoots = allowedRoots.filter(\.isFileURL).map { $0.resolvingSymlinksInPath().standardizedFileURL }
        self.attachmentResolver = attachmentResolver
        self.fileMaterializer = MediaUnderstandingPreprocessor(services: .none, scratchDirectory: scratchDirectory)
    }

    /// Creates the tool over a fixed attachment list (matched by UUID, then by file name).
    /// - Parameters:
    ///   - attachments: Attachments the model may reference.
    ///   - analyzer: Music analysis service.
    ///   - allowedRoots: Roots a `path` argument must stay inside.
    public init(
        attachments: [MediaAttachment],
        analyzer: (any MusicAnalyzing)? = MediaUnderstandingServices.platformDefault.music,
        allowedRoots: [URL] = MediaPipeline.defaultLocalRoots()
    ) {
        self.init(
            analyzer: analyzer,
            allowedRoots: allowedRoots,
            attachmentResolver: { reference in
                MusicAnalyzeTool.match(reference, in: attachments)
            }
        )
    }

    /// Whether music analysis is available with the platform's default service.
    public static var isAvailable: Bool {
        MediaUnderstandingServices.platformDefault.music != nil
    }

    /// JSON Schema of the tool arguments.
    public static let parametersSchema: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "attachmentId": AnyCodable([
                "type": AnyCodable("string"),
                "description": AnyCodable("ID (UUID) or file name of an audio attachment from this conversation."),
            ] as [String: AnyCodable]),
            "path": AnyCodable([
                "type": AnyCodable("string"),
                "description": AnyCodable("Absolute path of a local audio file inside the app's media folders."),
            ] as [String: AnyCodable]),
            "analyses": AnyCodable([
                "type": AnyCodable("array"),
                "items": AnyCodable([
                    "type": AnyCodable("string"),
                    "enum": AnyCodable(MusicAnalysisKind.allCases.map(\.rawValue)),
                ] as [String: AnyCodable]),
                "description": AnyCodable("Analyses to run; defaults to all of them."),
            ] as [String: AnyCodable]),
        ] as [String: AnyCodable]),
        "additionalProperties": AnyCodable(false),
    ]

    /// Model-facing description of the tool.
    public var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "Music Analyze",
            description: "Analyze music in an audio attachment or local audio file on device: musical key, tempo (BPM), "
                + "song structure, loudness, pace, and instrument activity. Returns JSON with times in seconds. "
                + "Pass attachmentId or path.",
            displaySummary: "Analyze key, tempo, structure, and loudness of audio",
            display: AgentToolDisplay(title: "Music Analyze", category: "media"),
            parameters: Self.parametersSchema,
            source: .core,
            risk: .low,
            tags: ["media", "audio", "music", "on-device"],
            replaySafe: true
        )
    }

    /// Runs the analysis.
    /// - Parameters:
    ///   - invocation: Call arguments and context.
    ///   - update: Optional progress callback.
    /// - Returns: JSON summary, or an error output for invalid arguments and failed analyses.
    public func invoke(_ invocation: AgentToolInvocation, update: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        guard let analyzer = self.analyzer else {
            return .error("music_analyze is unavailable: on-device music understanding needs iOS, macOS, tvOS, watchOS, or visionOS 27.")
        }
        let analyses: Set<MusicAnalysisKind>
        switch Self.parseAnalyses(invocation.arguments["analyses"]) {
        case .success(let parsed):
            analyses = parsed
        case .failure(let message):
            return .error(message.text)
        }
        let attachmentReference = Self.stringArgument(invocation.arguments, keys: ["attachmentId", "attachmentID", "attachment_id", "attachment"])
        let path = Self.stringArgument(invocation.arguments, keys: ["path", "file", "filePath"])
        if let update {
            await update(AgentToolOutput(progress: AgentToolProgress(message: "Analyzing music…")))
        }
        do {
            let summary: MusicAnalysisSummary
            if let attachmentReference {
                guard let resolver = self.attachmentResolver, let attachment = await resolver(attachmentReference) else {
                    return .error("No attachment matches '\(attachmentReference)'.")
                }
                let kind = MediaPipeline.classify(mimeType: attachment.mimeType)
                guard kind == .audio || kind == .video else {
                    return .error("Attachment '\(attachmentReference)' is \(attachment.mimeType), not audio.")
                }
                summary = try await self.fileMaterializer.withLocalFile(for: attachment, defaultExtension: "m4a") { url in
                    try await analyzer.analyze(audioAt: url, analyses: analyses)
                }
            } else if let path {
                let url: URL
                switch self.resolvePath(path) {
                case .success(let resolved):
                    url = resolved
                case .failure(let message):
                    return .error(message.text)
                }
                summary = try await analyzer.analyze(audioAt: url, analyses: analyses)
            } else {
                return .error("Pass attachmentId or path.")
            }
            return .json(try AnyCodable(encoding: summary))
        } catch MediaUnderstandingError.protectedContent {
            return .error("The audio contains protected (DRM) content and cannot be analyzed.")
        } catch let error as MediaUnderstandingError {
            return .error(error.errorDescription ?? String(describing: error))
        }
    }

    // MARK: Argument handling

    struct ArgumentError: Error, Equatable {
        let text: String
    }

    static func parseAnalyses(_ value: AnyCodable?) -> Result<Set<MusicAnalysisKind>, ArgumentError> {
        guard let value, !value.isNull else {
            return .success(Set(MusicAnalysisKind.allCases))
        }
        let names: [String]
        if let array = value.arrayValue {
            names = array.compactMap(\.stringValue)
            guard names.count == array.count else {
                return .failure(ArgumentError(text: "analyses must be an array of strings."))
            }
        } else if let single = value.stringValue {
            names = single.split(separator: ",").map(String.init)
        } else {
            return .failure(ArgumentError(text: "analyses must be an array of strings."))
        }
        var kinds = Set<MusicAnalysisKind>()
        var unknown: [String] = []
        for name in names where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let kind = MusicAnalysisKind(normalizing: name) {
                kinds.insert(kind)
            } else {
                unknown.append(name)
            }
        }
        if !unknown.isEmpty {
            let valid = MusicAnalysisKind.allCases.map(\.rawValue).joined(separator: ", ")
            return .failure(ArgumentError(text: "Unknown analyses: \(unknown.joined(separator: ", ")). Valid: \(valid)."))
        }
        return .success(kinds.isEmpty ? Set(MusicAnalysisKind.allCases) : kinds)
    }

    static func stringArgument(_ arguments: [String: AnyCodable], keys: [String]) -> String? {
        for key in keys {
            if let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    func resolvePath(_ path: String) -> Result<URL, ArgumentError> {
        let url: URL
        if path.hasPrefix("file://") {
            guard let parsed = URL(string: path), parsed.isFileURL else {
                return .failure(ArgumentError(text: "path must be an absolute file path."))
            }
            url = parsed
        } else {
            guard path.hasPrefix("/") else {
                return .failure(ArgumentError(text: "path must be an absolute file path."))
            }
            url = URL(fileURLWithPath: path)
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let isAllowed = self.allowedRoots.contains { root in
            resolved.path == root.path || resolved.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
        }
        guard isAllowed else {
            return .failure(ArgumentError(text: "path is outside the allowed media folders."))
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return .failure(ArgumentError(text: "No file exists at \(resolved.path)."))
        }
        return .success(resolved)
    }

    static func match(_ reference: String, in attachments: [MediaAttachment]) -> MediaAttachment? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed), let attachment = attachments.first(where: { $0.id == id }) {
            return attachment
        }
        return attachments.first { $0.fileName?.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
}
