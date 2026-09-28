import Foundation
import OpenClawCore
import OpenClawProtocol
import OpenClawSkills

/// Path-jailed `read` tool backing the v6 `<available_skills>` catalog (upstream `read` session tool).
///
/// The catalog prompt asks the model to open `SKILL.md` (and files it references) itself, so the
/// runtime offers this tool jailed by ``SkillReadAccess`` (the workspace plus every skill root, see
/// `SkillRegistry.readAccess()`). Text is paged by line (`offset` is 1-based, `limit` caps lines) and
/// capped at ``defaultMaxLines`` lines or ``defaultMaxBytes`` bytes per call, with an upstream-style
/// continuation notice. `jpg`/`png`/`gif`/`webp`/`bmp` files up to ``maxImageBytes`` return an image
/// block. Paths outside the jail, directories and unreadable files return error results.
public struct SkillReadTool: AgentTool {
    /// Tool name (upstream `read`).
    public static let toolName = "read"
    /// Upstream `DEFAULT_MAX_LINES`.
    public static let defaultMaxLines = 2_000
    /// Upstream `DEFAULT_MAX_BYTES` (50 KB).
    public static let defaultMaxBytes = 50 * 1_024
    /// Largest image returned as an image block (SDK limit; upstream resizes instead).
    public static let maxImageBytes = 5 * 1_024 * 1_024

    /// Tool name.
    public let name = SkillReadTool.toolName
    /// Read jail.
    public let access: SkillReadAccess

    private static let imageMIMETypes: [String: String] = [
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "gif": "image/gif",
        "webp": "image/webp",
        "bmp": "image/bmp",
    ]

    /// Creates the tool.
    /// - Parameter access: Read jail (workspace and skill roots).
    public init(access: SkillReadAccess) {
        self.access = access
    }

    /// JSON Schema of the arguments (upstream `readToolInputSchema` without `cursor`/`optional`).
    public static let parametersSchema: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "path": AnyCodable(["type": AnyCodable("string"), "description": AnyCodable("File path; relative/absolute.")]),
            "offset": AnyCodable([
                "type": AnyCodable("integer"),
                "minimum": AnyCodable(1),
                "description": AnyCodable("Start line; 1-based."),
            ]),
            "limit": AnyCodable(["type": AnyCodable("number"), "description": AnyCodable("Max lines.")]),
        ]),
        "required": AnyCodable([AnyCodable("path")]),
    ]

    /// Model- and UI-facing description.
    public var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "Read",
            description: "Read text/image file (jpg/png/gif/webp/bmp); images attach to model context. "
                + "Text caps \(Self.defaultMaxLines) lines or \(Self.defaultMaxBytes / 1_024)KB. Continue with offset/limit.",
            parameters: Self.parametersSchema,
            sectionID: "fs",
            defaultProfiles: [.coding],
            risk: .low,
            tags: ["fs", "skills"],
            executionMode: .parallel,
            replaySafe: true
        )
    }

    /// Reads the requested file inside the jail.
    public func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        guard let rawPath = invocation.arguments["path"]?.stringValue, !rawPath.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .error("read requires a path")
        }
        let url: URL
        do {
            url = try self.access.resolve(rawPath)
        } catch {
            return .error("Path is outside the readable workspace and skill roots: \(rawPath)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .error("File not found: \(rawPath)")
        }
        if isDirectory.boolValue {
            return .error("Read requires a file path, but \(rawPath) is a directory. List the directory, then read a specific file.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .error("Could not read \(rawPath): \(error.localizedDescription)")
        }
        if let mimeType = Self.imageMIMETypes[url.pathExtension.lowercased()] {
            guard data.count <= Self.maxImageBytes else {
                return .error("Image \(rawPath) is larger than \(Self.maxImageBytes / 1_048_576)MB")
            }
            return AgentToolOutput(
                content: [.text("Read image file [\(mimeType)]"), .image(data: data.base64EncodedString(), mimeType: mimeType)],
                details: AnyCodable(["kind": AnyCodable("image"), "mimeType": AnyCodable(mimeType)])
            )
        }
        let offset = max(1, invocation.arguments["offset"]?.intValue ?? 1)
        let limit = invocation.arguments["limit"]?.doubleValue.map { max(1, Int($0)) }
        return Self.page(text: String(decoding: data, as: UTF8.self), offset: offset, limit: limit)
    }

    /// Pages text by line with the upstream byte and line caps.
    /// - Parameters:
    ///   - text: File contents.
    ///   - offset: 1-based start line.
    ///   - limit: Optional maximum line count.
    /// - Returns: The page with a continuation notice when more lines remain.
    static func page(text: String, offset: Int, limit: Int?) -> AgentToolOutput {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        let total = lines.count
        guard offset <= max(total, 1) else {
            return .error("Offset \(offset) is beyond the end of the file (\(total) lines)")
        }
        let start = offset - 1
        let lineCap = min(limit ?? Self.defaultMaxLines, Self.defaultMaxLines)
        var selected: [String] = []
        var bytes = 0
        var truncatedByBytes = false
        for line in lines.dropFirst(start).prefix(lineCap) {
            let lineBytes = line.utf8.count + (selected.isEmpty ? 0 : 1)
            if bytes + lineBytes > Self.defaultMaxBytes, !selected.isEmpty {
                truncatedByBytes = true
                break
            }
            selected.append(line)
            bytes += lineBytes
        }
        let endLine = start + selected.count
        var body = selected.joined(separator: "\n")
        let remaining = total - endLine
        if remaining > 0 {
            if truncatedByBytes {
                body += "\n\n[Showing lines \(offset)-\(endLine) of \(total) (\(Self.defaultMaxBytes / 1_024)KB limit). "
                    + "Use offset=\(endLine + 1) to continue.]"
            } else {
                body += "\n\n[\(remaining) more line\(remaining == 1 ? "" : "s") in file. Use offset=\(endLine + 1) to continue.]"
            }
        }
        var details: [String: AnyCodable] = ["kind": AnyCodable(remaining > 0 ? "truncated" : "text")]
        if remaining > 0 {
            details["continuation"] = AnyCodable(["kind": AnyCodable("line"), "offset": AnyCodable(endLine + 1)])
        }
        return AgentToolOutput(content: [.text(body)], details: AnyCodable(details))
    }
}
