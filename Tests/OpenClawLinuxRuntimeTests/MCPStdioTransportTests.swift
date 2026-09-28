#if os(macOS) || os(Linux)
import Foundation
import Testing
import OpenClawCore
import OpenClawProtocol
@testable import OpenClawMCP

@Suite("MCP stdio transport")
struct MCPStdioTransportTests {
    actor Lines {
        private(set) var values: [String] = []
        func append(_ value: String) { self.values.append(value) }
    }

    /// Minimal MCP server in POSIX sh: answers by method, echoing the request id (keys are sorted, so
    /// `"id"` comes first in every request the client sends).
    static let fakeServer = #"""
    printf 'server starting\n' >&2
    printf 'partial-no-newline' >&2
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/^{"id":\([0-9]*\),.*/\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"sh"}}}\n' "$id" ;;
        *'"method":"tools/list"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"hello","inputSchema":{"type":"object"}}]}}\r\n' "$id" ;;
        *'"method":"tools/call"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"hi from sh"}]}}\n' "$id" ;;
        *'"method":"ping"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id" ;;
      esac
    done
    """#

    private func config(_ script: String) -> MCPServerConfig {
        MCPServerConfig(command: "/bin/sh", args: ["-c", script], env: ["FAKE": "1"])
    }

    @Test
    func initializeListCallAndStderrCapture() async throws {
        let lines = Lines()
        let transport = try MCPStdioTransport(
            serverName: "sh",
            config: self.config(Self.fakeServer),
            allowlist: ExecCommandAllowlist(patterns: ["/bin/*", "/usr/bin/*"]),
            diagnostics: { event in
                if event.name == "mcp.stderr" { await lines.append(event.metadata["line"] ?? "") }
            },
            shutdownGraceSeconds: 0.5
        )
        let client = MCPClient(serverName: "sh", transport: transport, requestTimeoutMs: 5_000, connectionTimeoutMs: 5_000)
        let initialize = try await client.connect()
        #expect(initialize.serverInfo.name == "sh")
        #expect(try await client.listTools().map(\.name) == ["hello"])
        let result = try await client.callTool(name: "hello", arguments: [:])
        #expect(result.content.first?.dictionaryValue?["text"]?.stringValue == "hi from sh")
        try await client.ping()
        try await Task.sleep(nanoseconds: 400_000_000)
        let captured = await lines.values
        #expect(captured.contains("bundle-mcp:sh: server starting"))
        #expect(captured.contains("bundle-mcp:sh: partial-no-newline"))
        await client.close()
    }

    @Test
    func commandMustBeAllowlisted() {
        #expect(throws: OpenClawCoreError.self) {
            _ = try MCPStdioTransport(serverName: "sh", config: self.config("true"), allowlist: ExecCommandAllowlist(patterns: []))
        }
        #expect(throws: OpenClawCoreError.self) {
            _ = try MCPStdioTransport(serverName: "empty", config: MCPServerConfig(command: " "), allowlist: ExecCommandAllowlist(patterns: ["/bin/*"]))
        }
        #expect((try? MCPStdioTransport(
            serverName: "sh",
            config: self.config("true"),
            allowlist: ExecCommandAllowlist(patterns: []),
            allowUnlistedCommands: true
        )) != nil)
    }

    @Test
    func closeEscalatesToKillWhenTheServerIgnoresTerm() async throws {
        let transport = try MCPStdioTransport(
            serverName: "stubborn",
            config: self.config("trap '' TERM; while true; do sleep 1; done"),
            // /bin/sh resolves to /usr/bin/dash on Debian/Ubuntu; the allowlist matches the real path.
            allowlist: ExecCommandAllowlist(patterns: ["/bin/*", "/usr/bin/*"]),
            shutdownGraceSeconds: 0.2
        )
        try await transport.start()
        let pid = try #require(await transport.processIdentifier)
        let startedAt = Date()
        await transport.close()
        #expect(Date().timeIntervalSince(startedAt) < 5)
        #expect(kill(pid, 0) != 0)
    }

    @Test
    func pendingRequestsFailWhenTheProcessExits() async throws {
        let transport = try MCPStdioTransport(
            serverName: "quitter",
            config: self.config("read -r line; exit 3"),
            allowlist: ExecCommandAllowlist(patterns: ["/bin/*", "/usr/bin/*"])
        )
        let client = MCPClient(serverName: "quitter", transport: transport, requestTimeoutMs: 5_000, connectionTimeoutMs: 5_000)
        await #expect(throws: MCPTransportError.self) {
            try await client.connect()
        }
        await client.close()
    }

    @Test
    func lineDecoderAndUTF8Boundaries() throws {
        let decoder = LineDecoder(maxLineBytes: 32)
        #expect(try decoder.feed(Data("{\"a\":1}\r\n{\"b\"".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}"])
        #expect(try decoder.feed(Data(":2}\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["{\"b\":2}"])
        #expect(throws: MCPTransportError.self) {
            _ = try decoder.feed(Data(String(repeating: "x", count: 64).utf8))
        }
        let euro = Array("€".utf8)
        #expect(StderrCollector.completeUTF8Prefix(Data([0x61] + euro.prefix(2))) == 1)
        #expect(StderrCollector.completeUTF8Prefix(Data([0x61] + euro)) == 4)
    }
}
#endif
