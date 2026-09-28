import Foundation

/// Display-ready summary of one tool invocation.
public struct ToolDisplaySummary: Sendable, Equatable {
    /// Raw (trimmed) tool name.
    public let name: String
    /// Display emoji.
    public let emoji: String
    /// Display title.
    public let title: String
    /// Short label.
    public let label: String
    /// Action verb (for example `open` for `browser` with `action: "open"`).
    public let verb: String?
    /// Most relevant argument detail (path, command, URL, …).
    public let detail: String?

    /// `verb · detail`, or `nil` when both are empty.
    public var detailLine: String? {
        var parts: [String] = []
        if let verb, !verb.isEmpty { parts.append(verb) }
        if let detail, !detail.isEmpty { parts.append(detail) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `emoji label: detailLine` (or `emoji label`).
    public var summaryLine: String {
        if let detailLine {
            return "\(self.emoji) \(self.label): \(detailLine)"
        }
        return "\(self.emoji) \(self.label)"
    }
}

/// Registry that maps raw tool invocations into user-facing display summaries.
public enum ToolDisplayRegistry {
    private struct ToolDisplayActionSpec: Decodable {
        let label: String?
        let detailKeys: [String]?
    }

    private struct ToolDisplaySpec: Decodable {
        let emoji: String?
        let title: String?
        let label: String?
        let detailKeys: [String]?
        let actions: [String: ToolDisplayActionSpec]?
    }

    private struct ToolDisplayConfig: Decodable {
        let version: Int?
        let fallback: ToolDisplaySpec?
        let tools: [String: ToolDisplaySpec]?
    }

    private static let config: ToolDisplayConfig = loadConfig()

    /// Resolves a tool invocation into a display-ready summary.
    public static func resolve(name: String?, args: AnyCodable?, meta: String? = nil) -> ToolDisplaySummary {
        self.resolve(name: name, args: args, meta: meta, descriptor: nil)
    }

    /// Resolves a tool invocation, falling back to the tool's descriptor for tools without a
    /// `tool-display.json` entry (plugin, MCP and client tools).
    ///
    /// Lookup order: the exact name, then the upstream tool-name aliases in both directions
    /// (`automations` ↔ `cron`, `exec` ↔ `bash`, `apply-patch` ↔ `apply_patch`), then the descriptor's
    /// ``AgentToolDisplay`` and label, and finally MCP-style `server__tool` names, rendered as
    /// `server: tool`.
    public static func resolve(
        name: String?,
        args: AnyCodable?,
        meta: String? = nil,
        descriptor: AgentToolDescriptor?) -> ToolDisplaySummary
    {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "tool"
        let resolvedKey = self.resolvedSpecKey(for: trimmedName)
        let key = resolvedKey ?? trimmedName.lowercased()
        let spec = resolvedKey.flatMap { self.config.tools?[$0] }
        let fallback = self.config.fallback
        let mcpName = spec == nil ? self.mcpDisplayName(trimmedName) : nil

        let emoji = spec?.emoji ?? descriptor?.display?.emoji ?? fallback?.emoji ?? "🧩"
        let title = spec?.title
            ?? self.nonEmpty(descriptor?.display?.title)
            ?? mcpName.map { self.titleFromName($0.tool) }
            ?? self.titleFromName(trimmedName)
        let label = spec?.label
            ?? self.nonEmpty(descriptor?.label).flatMap { $0 == descriptor?.name ? nil : $0 }
            ?? mcpName.map { "\($0.server): \($0.tool)" }
            ?? trimmedName

        let actionRaw = self.valueForKeyPath(args, path: "action") as? String
        let action = actionRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionSpec = action.flatMap { spec?.actions?[$0] }
        let verb = self.normalizeVerb(actionSpec?.label ?? action)

        var detail: String?
        if key == "read" {
            detail = self.readDetail(args)
        } else if key == "write" || key == "edit" || key == "attach" {
            detail = self.pathDetail(args)
        }

        let detailKeys = actionSpec?.detailKeys ?? spec?.detailKeys ?? fallback?.detailKeys ?? []
        if detail == nil {
            detail = self.firstValue(args, keys: detailKeys)
        }

        if detail == nil {
            detail = meta
        }

        if detail == nil {
            detail = self.nonEmpty(descriptor?.displaySummary)
        }

        if let detailValue = detail {
            detail = self.shortenHomeInString(detailValue)
        }

        return ToolDisplaySummary(
            name: trimmedName,
            emoji: emoji,
            title: title,
            label: label,
            verb: verb,
            detail: detail)
    }

    /// Tool names with an explicit `tool-display.json` entry.
    public static var knownToolNames: [String] {
        (self.config.tools.map { Array($0.keys) } ?? []).sorted()
    }

    /// JSON key for a tool name: the exact lowercased name, else an alias in either direction.
    static func resolvedSpecKey(for name: String) -> String? {
        let key = name.lowercased()
        guard let tools = self.config.tools else { return nil }
        if tools[key] != nil { return key }
        if let canonical = AgentToolRegistry.toolNameAliases[key], tools[canonical] != nil {
            return canonical
        }
        for (legacy, canonical) in AgentToolRegistry.toolNameAliases where canonical == key && tools[legacy] != nil {
            return legacy
        }
        return nil
    }

    /// Splits `server__tool` MCP names; `nil` for anything else.
    static func mcpDisplayName(_ name: String) -> (server: String, tool: String)? {
        guard let range = name.range(of: "__") else { return nil }
        let server = String(name[..<range.lowerBound])
        let tool = String(name[range.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server: server, tool: tool)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadConfig() -> ToolDisplayConfig {
        guard let url = OpenClawKitResources.bundle.url(forResource: "tool-display", withExtension: "json") else {
            return self.defaultConfig()
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ToolDisplayConfig.self, from: data)
        } catch {
            return self.defaultConfig()
        }
    }

    private static func defaultConfig() -> ToolDisplayConfig {
        ToolDisplayConfig(
            version: 1,
            fallback: ToolDisplaySpec(
                emoji: "🧩",
                title: nil,
                label: nil,
                detailKeys: [
                    "command",
                    "path",
                    "url",
                    "targetUrl",
                    "targetId",
                    "ref",
                    "element",
                    "node",
                    "nodeId",
                    "id",
                    "requestId",
                    "to",
                    "channelId",
                    "guildId",
                    "userId",
                    "name",
                    "query",
                    "pattern",
                    "messageId",
                ],
                actions: nil),
            // Safety net when the bundled JSON cannot be loaded (upstream falls back to no tools).
            tools: [
                "exec": ToolDisplaySpec(
                    emoji: "🛠️",
                    title: "Exec",
                    label: nil,
                    detailKeys: ["command"],
                    actions: nil),
                "bash": ToolDisplaySpec(
                    emoji: "🛠️",
                    title: "Bash",
                    label: nil,
                    detailKeys: ["command"],
                    actions: nil),
                "read": ToolDisplaySpec(
                    emoji: "📖",
                    title: "Read",
                    label: nil,
                    detailKeys: ["path"],
                    actions: nil),
                "write": ToolDisplaySpec(
                    emoji: "✍️",
                    title: "Write",
                    label: nil,
                    detailKeys: ["path"],
                    actions: nil),
                "edit": ToolDisplaySpec(
                    emoji: "📝",
                    title: "Edit",
                    label: nil,
                    detailKeys: ["path"],
                    actions: nil),
                "attach": ToolDisplaySpec(
                    emoji: "📎",
                    title: "Attach",
                    label: nil,
                    detailKeys: ["path", "url", "fileName"],
                    actions: nil),
                "process": ToolDisplaySpec(
                    emoji: "🧰",
                    title: "Process",
                    label: nil,
                    detailKeys: ["sessionId"],
                    actions: nil),
            ])
    }

    private static func titleFromName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return "Tool" }
        return cleaned
            .split(separator: " ")
            .map { part in
                let upper = part.uppercased()
                if part.count <= 2, part == upper { return String(part) }
                return String(upper.prefix(1)) + String(part.lowercased().dropFirst())
            }
            .joined(separator: " ")
    }

    private static func normalizeVerb(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: "_", with: " ")
    }

    private static func readDetail(_ args: AnyCodable?) -> String? {
        guard let path = valueForKeyPath(args, path: "path") as? String else { return nil }
        let offsetAny = self.valueForKeyPath(args, path: "offset")
        let limitAny = self.valueForKeyPath(args, path: "limit")
        let offset = (offsetAny as? Double) ?? (offsetAny as? Int).map(Double.init)
        let limit = (limitAny as? Double) ?? (limitAny as? Int).map(Double.init)
        if let offset, let limit {
            let end = offset + limit
            return "\(path):\(Int(offset))-\(Int(end))"
        }
        return path
    }

    private static func pathDetail(_ args: AnyCodable?) -> String? {
        self.valueForKeyPath(args, path: "path") as? String
    }

    private static func firstValue(_ args: AnyCodable?, keys: [String]) -> String? {
        for key in keys {
            if let value = valueForKeyPath(args, path: key),
               let rendered = renderValue(value)
            {
                return rendered
            }
        }
        return nil
    }

    private static func renderValue(_ value: Any) -> String? {
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let first = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
            if first.count > 160 { return String(first.prefix(157)) + "…" }
            return first
        }
        if let num = value as? Int { return String(num) }
        if let num = value as? Double { return String(num) }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let array = value as? [Any] {
            let items = array.compactMap { self.renderValue($0) }
            guard !items.isEmpty else { return nil }
            let preview = items.prefix(3).joined(separator: ", ")
            return items.count > 3 ? "\(preview)…" : preview
        }
        if let dict = value as? [String: Any] {
            if let label = dict["name"].flatMap({ renderValue($0) }) { return label }
            if let label = dict["id"].flatMap({ renderValue($0) }) { return label }
        }
        return nil
    }

    private static func valueForKeyPath(_ args: AnyCodable?, path: String) -> Any? {
        guard let args else { return nil }
        let parts = path.split(separator: ".").map(String.init)
        var current: AnyCodable? = args
        for part in parts {
            guard let dict = current?.dictionaryValue else {
                return nil
            }
            current = dict[part]
        }
        return current?.foundationValue
    }

    private static func shortenHomeInString(_ value: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return value }
        return value.replacingOccurrences(of: home, with: "~")
    }
}
