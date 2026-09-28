import Foundation
import OpenClawAgents
import OpenClawCore
import OpenClawProtocol

/// Namespace for the OpenClaw Model Context Protocol (MCP) client runtime.
///
/// `OpenClawMCP` connects to MCP servers and exposes their tools as OpenClaw agent tools. The
/// module is cross-platform (Apple platforms and Linux). The stdio transport is only available on
/// macOS and Linux, where child processes can be spawned; other platforms use the HTTP transports
/// (Streamable HTTP and legacy SSE).
///
/// Entry points: ``MCPConfig`` / ``MCPServerConfig`` (upstream `mcp` config shape), ``MCPClient``
/// (JSON-RPC over any ``MCPTransport``), and ``MCPClientManager`` (lazy connections, tool catalog,
/// `<server>__<tool>` agent tools, probes).
public enum OpenClawMCP {
    /// Release of OpenClawKit that introduced this module surface.
    public static let moduleVersion = "2026.3.0"

    /// Size cap for one MCP message, SSE event, or stdio line (upstream MCP SDK
    /// `STDIO_DEFAULT_MAX_BUFFER_SIZE`, 10 MiB).
    public static let defaultMaxMessageBytes = 10 * 1_024 * 1_024

    /// Whether this platform can launch stdio MCP servers as child processes.
    public static var supportsStdioTransport: Bool {
        #if os(macOS) || os(Linux)
        return true
        #else
        return false
        #endif
    }
}
