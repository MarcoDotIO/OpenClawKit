import Foundation
import OpenClawProtocol

/// Transport an MCP server is reached over.
public enum MCPTransportKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Child process speaking newline-delimited JSON-RPC on stdin/stdout (macOS and Linux only).
    case stdio
    /// Legacy HTTP+SSE transport (2024-11-05).
    case sse
    /// Streamable HTTP transport (2025-03-26 and later).
    case streamableHTTP = "streamable-http"
}

/// Include-then-exclude tool filter with `*` globs (upstream `toolFilter`).
public struct MCPToolFilter: Codable, Sendable, Equatable {
    /// When non-empty, only matching tools are kept.
    public var include: [String]?
    /// Matching tools are removed after `include` is applied.
    public var exclude: [String]?

    /// Creates a filter.
    /// - Parameters:
    ///   - include: Include patterns.
    ///   - exclude: Exclude patterns.
    public init(include: [String]? = nil, exclude: [String]? = nil) {
        self.include = include
        self.exclude = exclude
    }

    /// Upstream `isMcpToolAllowed`.
    /// - Parameter toolName: Server tool name.
    /// - Returns: `true` when the tool passes the filter.
    public func allows(_ toolName: String) -> Bool {
        let include = (self.include ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let exclude = self.exclude ?? []
        let included = include.isEmpty || include.contains { Self.matches(pattern: $0, value: toolName) }
        return included && !exclude.contains { Self.matches(pattern: $0, value: toolName) }
    }

    /// Upstream `matchesMcpToolFilterPattern`: exact text plus `*`.
    /// - Parameters:
    ///   - pattern: Pattern.
    ///   - value: Tool name.
    /// - Returns: `true` when the pattern matches.
    public static func matches(pattern: String, value: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.contains("*") else { return trimmed == value }
        let parts = trimmed.components(separatedBy: "*")
        let first = parts.first ?? ""
        let last = parts.last ?? ""
        if !first.isEmpty && !value.hasPrefix(first) { return false }
        let characters = Array(value)
        var cursor = first.count
        let endBound = last.isEmpty ? characters.count : characters.count - last.count
        if !last.isEmpty && (!value.hasSuffix(last) || endBound < cursor) { return false }
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            let partChars = Array(part)
            var found: Int?
            var index = cursor
            while index + partChars.count <= endBound {
                if Array(characters[index..<(index + partChars.count)]) == partChars {
                    found = index
                    break
                }
                index += 1
            }
            guard let found else { return false }
            cursor = found + partChars.count
        }
        return true
    }
}

/// OAuth settings for an HTTP MCP server (`auth: "oauth"`).
public struct MCPOAuthConfig: Codable, Sendable, Equatable {
    /// `shared` (default) or `per-requester` (unsupported in the embedded runtime).
    public var identity: String?
    /// Auth profile the tokens are stored under.
    public var authProfileId: String?
    /// Requested scope.
    public var scope: String?
    /// Redirect URL (http/https or a custom scheme).
    public var redirectUrl: String?
    /// Client ID metadata document URL (https, non-root path).
    public var clientMetadataUrl: String?

    /// Creates OAuth settings.
    /// - Parameters:
    ///   - identity: Identity mode.
    ///   - authProfileId: Auth profile.
    ///   - scope: Scope.
    ///   - redirectUrl: Redirect URL.
    ///   - clientMetadataUrl: Client metadata URL.
    public init(identity: String? = nil, authProfileId: String? = nil, scope: String? = nil, redirectUrl: String? = nil, clientMetadataUrl: String? = nil) {
        self.identity = identity
        self.authProfileId = authProfileId
        self.scope = scope
        self.redirectUrl = redirectUrl
        self.clientMetadataUrl = clientMetadataUrl
    }
}

/// One MCP server definition (upstream `mcp.servers.<name>`).
///
/// Decodes the upstream JSON shape; unknown keys are preserved in ``extra``. `env` and `headers`
/// values may be strings, numbers or booleans (stringified).
public struct MCPServerConfig: Codable, Sendable, Equatable {
    /// Upstream default connection timeout.
    public static let defaultConnectionTimeoutMs = 30_000
    /// Upstream default request timeout.
    public static let defaultRequestTimeoutMs = 60_000

    /// `false` disables the server.
    public var enabled: Bool?
    /// Executable for stdio servers.
    public var command: String?
    /// Arguments for stdio servers.
    public var args: [String]?
    /// Extra environment for stdio servers.
    public var env: [String: String]?
    /// Working directory for stdio servers.
    public var cwd: String?
    /// HTTP(S) URL for SSE / Streamable HTTP servers.
    public var url: String?
    /// Explicit transport.
    public var transport: String?
    /// CLI-style alias (`http` → streamable-http, `sse`, `stdio`); used only when `transport` is unset.
    public var type: String?
    /// Extra HTTP headers (for example a static bearer token).
    public var headers: [String: String]?
    /// Connection/initialize timeout in milliseconds (default 30000).
    public var connectionTimeoutMs: Int?
    /// Per-request timeout in milliseconds (default 60000).
    public var requestTimeoutMs: Int?
    /// Whether tool calls may run in parallel (default `false`).
    public var supportsParallelToolCalls: Bool?
    /// `oauth` enables the MCP authorization flow.
    public var auth: String?
    /// OAuth settings.
    public var oauth: MCPOAuthConfig?
    /// `false` accepts any TLS certificate (development only).
    public var sslVerify: Bool?
    /// Client certificate reference (Apple platforms).
    public var clientCert: String?
    /// Client key reference (Apple platforms).
    public var clientKey: String?
    /// Tool filter.
    public var toolFilter: MCPToolFilter?
    /// Unknown keys, preserved for round-tripping.
    public var extra: [String: AnyCodable]

    /// Creates a server definition.
    /// - Parameters:
    ///   - enabled: Enabled flag.
    ///   - command: Stdio command.
    ///   - args: Stdio arguments.
    ///   - env: Stdio environment.
    ///   - cwd: Stdio working directory.
    ///   - url: HTTP URL.
    ///   - transport: Transport.
    ///   - type: CLI transport alias.
    ///   - headers: HTTP headers.
    ///   - connectionTimeoutMs: Connection timeout.
    ///   - requestTimeoutMs: Request timeout.
    ///   - supportsParallelToolCalls: Parallel tool calls.
    ///   - auth: Auth mode.
    ///   - oauth: OAuth settings.
    ///   - sslVerify: TLS verification.
    ///   - clientCert: Client certificate.
    ///   - clientKey: Client key.
    ///   - toolFilter: Tool filter.
    ///   - extra: Unknown keys.
    public init(
        enabled: Bool? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        cwd: String? = nil,
        url: String? = nil,
        transport: String? = nil,
        type: String? = nil,
        headers: [String: String]? = nil,
        connectionTimeoutMs: Int? = nil,
        requestTimeoutMs: Int? = nil,
        supportsParallelToolCalls: Bool? = nil,
        auth: String? = nil,
        oauth: MCPOAuthConfig? = nil,
        sslVerify: Bool? = nil,
        clientCert: String? = nil,
        clientKey: String? = nil,
        toolFilter: MCPToolFilter? = nil,
        extra: [String: AnyCodable] = [:]
    ) {
        self.enabled = enabled
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.url = url
        self.transport = transport
        self.type = type
        self.headers = headers
        self.connectionTimeoutMs = connectionTimeoutMs
        self.requestTimeoutMs = requestTimeoutMs
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.auth = auth
        self.oauth = oauth
        self.sslVerify = sslVerify
        self.clientCert = clientCert
        self.clientKey = clientKey
        self.toolFilter = toolFilter
        self.extra = extra
    }

    /// Effective connection timeout.
    public var effectiveConnectionTimeoutMs: Int {
        (self.connectionTimeoutMs ?? 0) > 0 ? self.connectionTimeoutMs! : Self.defaultConnectionTimeoutMs
    }

    /// Effective request timeout.
    public var effectiveRequestTimeoutMs: Int {
        (self.requestTimeoutMs ?? 0) > 0 ? self.requestTimeoutMs! : Self.defaultRequestTimeoutMs
    }

    /// Whether the server is enabled (default `true`).
    public var isEnabled: Bool {
        self.enabled != false
    }

    /// Upstream CLI alias map: `http` → `streamable-http`; `sse`, `stdio`, `streamable-http` pass through.
    /// - Parameter value: Raw `type` value.
    /// - Returns: Canonical transport, if known.
    public static func canonicalTransportAlias(_ value: String?) -> MCPTransportKind? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "http", "streamable-http":
            return .streamableHTTP
        case "sse":
            return .sse
        case "stdio":
            return .stdio
        default:
            return nil
        }
    }

    /// Resolves the transport exactly like upstream `resolveMcpTransportConfig`:
    /// a non-empty `command` always means stdio (even with a `url`); otherwise an explicit
    /// `transport` (or `type` alias) other than `sse`/`streamable-http` is unsupported; otherwise a
    /// `url` uses `streamable-http` only when explicitly requested and legacy `sse` by default.
    /// - Returns: Transport, or a reason the server is skipped.
    public func resolveTransport() -> Result<MCPTransportKind, MCPConfigIssue> {
        if let command = self.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            return .success(.stdio)
        }
        let requested = self.transport?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let effective = requested.isEmpty ? (Self.canonicalTransportAlias(self.type)?.rawValue ?? "") : requested
        if !effective.isEmpty, effective != MCPTransportKind.sse.rawValue, effective != MCPTransportKind.streamableHTTP.rawValue {
            return .failure(MCPConfigIssue(path: "transport", message: "transport \"\(effective)\" is not supported"))
        }
        guard let url = self.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            return .failure(MCPConfigIssue(path: "command", message: "server has neither a command nor an HTTP url"))
        }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(MCPConfigIssue(path: "url", message: "url must be http:// or https://"))
        }
        return .success(effective == MCPTransportKind.streamableHTTP.rawValue ? .streamableHTTP : .sse)
    }

    // MARK: - Codable

    private static let knownKeys: Set<String> = [
        "enabled", "command", "args", "env", "cwd", "url", "transport", "type", "headers",
        "connectionTimeoutMs", "requestTimeoutMs", "supportsParallelToolCalls", "auth", "oauth",
        "sslVerify", "clientCert", "clientKey", "toolFilter",
    ]

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { self.stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    /// Decodes a server definition, stringifying scalar `env`/`headers` values and keeping unknown keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        func value(_ key: String) -> AnyCodable? {
            try? container.decodeIfPresent(AnyCodable.self, forKey: AnyKey(key))
        }
        self.enabled = value("enabled")?.boolValue
        self.command = value("command")?.stringValue
        self.args = value("args")?.arrayValue?.compactMap(\.stringValue)
        self.env = Self.stringMap(value("env"))
        self.cwd = value("cwd")?.stringValue
        self.url = value("url")?.stringValue
        self.transport = value("transport")?.stringValue
        self.type = value("type")?.stringValue
        self.headers = Self.stringMap(value("headers"))
        self.connectionTimeoutMs = Self.positiveInt(value("connectionTimeoutMs"))
        self.requestTimeoutMs = Self.positiveInt(value("requestTimeoutMs"))
        self.supportsParallelToolCalls = value("supportsParallelToolCalls")?.boolValue
        self.auth = value("auth")?.stringValue
        self.oauth = try? container.decodeIfPresent(MCPOAuthConfig.self, forKey: AnyKey("oauth"))
        self.sslVerify = value("sslVerify")?.boolValue
        self.clientCert = value("clientCert")?.stringValue
        self.clientKey = value("clientKey")?.stringValue
        self.toolFilter = try? container.decodeIfPresent(MCPToolFilter.self, forKey: AnyKey("toolFilter"))
        var extra: [String: AnyCodable] = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extra[key.stringValue] = value(key.stringValue)
        }
        self.extra = extra
    }

    /// Encodes the server definition in the upstream shape (unknown keys included).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in self.extra where !Self.knownKeys.contains(key) {
            try container.encode(value, forKey: AnyKey(key))
        }
        try container.encodeIfPresent(self.enabled, forKey: AnyKey("enabled"))
        try container.encodeIfPresent(self.command, forKey: AnyKey("command"))
        try container.encodeIfPresent(self.args, forKey: AnyKey("args"))
        try container.encodeIfPresent(self.env, forKey: AnyKey("env"))
        try container.encodeIfPresent(self.cwd, forKey: AnyKey("cwd"))
        try container.encodeIfPresent(self.url, forKey: AnyKey("url"))
        try container.encodeIfPresent(self.transport, forKey: AnyKey("transport"))
        try container.encodeIfPresent(self.type, forKey: AnyKey("type"))
        try container.encodeIfPresent(self.headers, forKey: AnyKey("headers"))
        try container.encodeIfPresent(self.connectionTimeoutMs, forKey: AnyKey("connectionTimeoutMs"))
        try container.encodeIfPresent(self.requestTimeoutMs, forKey: AnyKey("requestTimeoutMs"))
        try container.encodeIfPresent(self.supportsParallelToolCalls, forKey: AnyKey("supportsParallelToolCalls"))
        try container.encodeIfPresent(self.auth, forKey: AnyKey("auth"))
        try container.encodeIfPresent(self.oauth, forKey: AnyKey("oauth"))
        try container.encodeIfPresent(self.sslVerify, forKey: AnyKey("sslVerify"))
        try container.encodeIfPresent(self.clientCert, forKey: AnyKey("clientCert"))
        try container.encodeIfPresent(self.clientKey, forKey: AnyKey("clientKey"))
        try container.encodeIfPresent(self.toolFilter, forKey: AnyKey("toolFilter"))
    }

    private static func stringMap(_ value: AnyCodable?) -> [String: String]? {
        guard let object = value?.dictionaryValue else { return nil }
        var result: [String: String] = [:]
        for (key, entry) in object {
            switch entry.value {
            case .string(let text): result[key] = text
            case .int(let number): result[key] = String(number)
            case .double(let number): result[key] = number.rounded() == number ? String(Int(number)) : String(number)
            case .bool(let flag): result[key] = flag ? "true" : "false"
            default: continue
            }
        }
        return result
    }

    private static func positiveInt(_ value: AnyCodable?) -> Int? {
        if let int = value?.intValue, int > 0 { return int }
        if let double = value?.doubleValue, double > 0, double.isFinite { return Int(min(double, Double(Int32.max))) }
        return nil
    }
}

/// Validation problem found in an MCP config.
public struct MCPConfigIssue: Error, Sendable, Equatable, Codable {
    /// Server name (empty for config-level issues).
    public var server: String
    /// Key path within the server.
    public var path: String
    /// Message.
    public var message: String

    /// Creates an issue.
    /// - Parameters:
    ///   - server: Server name.
    ///   - path: Key path.
    ///   - message: Message.
    public init(server: String = "", path: String, message: String) {
        self.server = server
        self.path = path
        self.message = message
    }
}

/// MCP client settings (the upstream `mcp` config section subset the SDK uses).
public struct MCPConfig: Codable, Sendable, Equatable {
    /// Upstream default idle TTL for cached server sessions (10 minutes).
    public static let defaultSessionIdleTtlMs = 600_000

    /// Servers in declaration order (declaration order decides collision suffixes of safe names).
    public var servers: [(name: String, config: MCPServerConfig)] {
        get { self.orderedServers.map { ($0.name, $0.config) } }
        set { self.orderedServers = newValue.map { NamedServer(name: $0.name, config: $0.config) } }
    }
    /// Idle TTL in milliseconds before a cached server session is closed.
    public var sessionIdleTtlMs: Int?
    /// SDK policy: allow stdio commands that are not in the manager's exec allowlist (default `false`).
    public var allowUnlistedStdioCommands: Bool?

    private struct NamedServer: Equatable, Sendable {
        let name: String
        let config: MCPServerConfig
    }

    private var orderedServers: [NamedServer]

    /// Creates MCP settings.
    /// - Parameters:
    ///   - servers: Servers in declaration order.
    ///   - sessionIdleTtlMs: Idle TTL.
    ///   - allowUnlistedStdioCommands: Allow stdio commands outside the allowlist.
    public init(servers: [(name: String, config: MCPServerConfig)] = [], sessionIdleTtlMs: Int? = nil, allowUnlistedStdioCommands: Bool? = nil) {
        self.orderedServers = servers.map { NamedServer(name: $0.name, config: $0.config) }
        self.sessionIdleTtlMs = sessionIdleTtlMs
        self.allowUnlistedStdioCommands = allowUnlistedStdioCommands
    }

    /// Server definition by name.
    /// - Parameter name: Server name.
    /// - Returns: The definition, if declared.
    public func server(named name: String) -> MCPServerConfig? {
        self.orderedServers.first { $0.name == name }?.config
    }

    /// Effective idle TTL.
    public var effectiveSessionIdleTtlMs: Int {
        (self.sessionIdleTtlMs ?? 0) > 0 ? self.sessionIdleTtlMs! : Self.defaultSessionIdleTtlMs
    }

    /// Validates the config like the upstream schema: retired aliases, reserved names, stdio without a
    /// command, per-requester OAuth rules, and (on iOS-family platforms) stdio servers.
    /// - Returns: Issues found (empty when valid).
    public func validate() -> [MCPConfigIssue] {
        var issues: [MCPConfigIssue] = []
        for entry in self.orderedServers {
            let name = entry.name
            let server = entry.config
            if name == "__proto__" {
                issues.append(MCPConfigIssue(server: name, path: "", message: "server name \"__proto__\" is reserved"))
            }
            for retired in ["connectTimeout", "connect_timeout", "timeout", "workingDirectory", "supports_parallel_tool_calls", "ssl_verify", "client_cert", "client_key"]
                where server.extra[retired] != nil
            {
                issues.append(MCPConfigIssue(server: name, path: retired, message: "Unrecognized key: \"\(retired)\""))
            }
            if let disabled = server.extra["disabled"] {
                let replacement = disabled.boolValue.map { "\"enabled: \(!$0)\" instead" } ?? "the canonical \"enabled\" boolean instead"
                issues.append(MCPConfigIssue(server: name, path: "disabled", message: "unsupported key \"disabled\"; use \(replacement)"))
            }
            let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if server.transport == MCPTransportKind.stdio.rawValue, command.isEmpty {
                issues.append(MCPConfigIssue(server: name, path: "command", message: "stdio transport requires a non-empty command"))
            }
            if server.oauth?.identity == "per-requester" {
                if server.auth != "oauth" {
                    issues.append(MCPConfigIssue(server: name, path: "oauth.identity", message: "oauth.identity \"per-requester\" requires auth: \"oauth\""))
                }
                if server.oauth?.authProfileId != nil {
                    issues.append(MCPConfigIssue(server: name, path: "oauth.authProfileId", message: "oauth.authProfileId cannot be used with oauth.identity \"per-requester\""))
                }
                if server.url == nil {
                    issues.append(MCPConfigIssue(server: name, path: "oauth.identity", message: "oauth.identity \"per-requester\" requires an HTTP server URL"))
                }
                if server.command != nil || server.transport == MCPTransportKind.stdio.rawValue {
                    issues.append(MCPConfigIssue(server: name, path: "oauth.identity", message: "oauth.identity \"per-requester\" cannot be combined with a command or \"stdio\" transport"))
                }
                issues.append(MCPConfigIssue(server: name, path: "oauth.identity", message: "oauth.identity \"per-requester\" is not supported by the embedded runtime"))
            }
            if let clientMetadataUrl = server.oauth?.clientMetadataUrl {
                let parsed = URL(string: clientMetadataUrl)
                if parsed?.scheme?.lowercased() != "https" || (parsed?.path ?? "/").isEmpty || parsed?.path == "/" {
                    issues.append(MCPConfigIssue(server: name, path: "oauth.clientMetadataUrl", message: "Expected https:// URL with a non-root pathname"))
                }
            }
            if case .success(.stdio) = server.resolveTransport(), !OpenClawMCP.supportsStdioTransport {
                issues.append(MCPConfigIssue(server: name, path: "command", message: "unsupportedOnPlatform: stdio MCP servers cannot run on this platform"))
            }
        }
        return issues
    }

    private enum CodingKeys: String, CodingKey {
        case servers, sessionIdleTtlMs, allowUnlistedStdioCommands
    }

    private struct ServerKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { self.stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    /// Decodes MCP settings; servers keep the decoder's key order.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionIdleTtlMs = try container.decodeIfPresent(Int.self, forKey: .sessionIdleTtlMs)
        self.allowUnlistedStdioCommands = try container.decodeIfPresent(Bool.self, forKey: .allowUnlistedStdioCommands)
        var servers: [NamedServer] = []
        if container.contains(.servers) {
            let nested = try container.nestedContainer(keyedBy: ServerKey.self, forKey: .servers)
            for key in nested.allKeys {
                let config = try nested.decode(MCPServerConfig.self, forKey: key)
                servers.append(NamedServer(name: key.stringValue, config: config))
            }
        }
        self.orderedServers = servers
    }

    /// Encodes MCP settings in the upstream shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.sessionIdleTtlMs, forKey: .sessionIdleTtlMs)
        try container.encodeIfPresent(self.allowUnlistedStdioCommands, forKey: .allowUnlistedStdioCommands)
        var nested = container.nestedContainer(keyedBy: ServerKey.self, forKey: .servers)
        for server in self.orderedServers {
            try nested.encode(server.config, forKey: ServerKey(server.name))
        }
    }

    /// Compares settings, including server order.
    public static func == (lhs: MCPConfig, rhs: MCPConfig) -> Bool {
        lhs.orderedServers == rhs.orderedServers
            && lhs.sessionIdleTtlMs == rhs.sessionIdleTtlMs
            && lhs.allowUnlistedStdioCommands == rhs.allowUnlistedStdioCommands
    }
}
