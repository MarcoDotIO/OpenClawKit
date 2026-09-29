#if os(macOS) || os(Linux)
import Foundation
import Testing
import OpenClawCore
import OpenClawProtocol
@testable import OpenClawMCP

@Suite("MCP stdio transport", .timeLimit(.minutes(1)))
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
    func closeDoesNotWaitForAWriteBlockedOnAFullPipe() async throws {
        // The server never reads stdin, so a 200 KB message fills the pipe and the write blocks.
        let transport = try MCPStdioTransport(
            serverName: "deaf",
            config: self.config("exec sleep 5"),
            allowlist: ExecCommandAllowlist(patterns: ["/bin/*", "/usr/bin/*"]),
            shutdownGraceSeconds: 0.2
        )
        try await transport.start()
        let big = MCPJSONRPCMessage.request(id: .int(1), method: "tools/call", params: AnyCodable(["blob": AnyCodable(String(repeating: "x", count: 200_000))]))
        let pending = Task { try await transport.send(big) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let startedAt = Date()
        await transport.close()
        #expect(Date().timeIntervalSince(startedAt) < 3, "close escalates without waiting for the blocked write")
        // Once the child is gone the blocked write fails with EPIPE (no SIGPIPE crash).
        await #expect(throws: MCPTransportError.self) {
            try await pending.value
        }
    }

    @Test
    func writesAfterTheServerExitsThrowInsteadOfRaisingSIGPIPE() async throws {
        let transport = try MCPStdioTransport(
            serverName: "short-lived",
            config: self.config("head -n 50 >/dev/null; exit 1"),
            allowlist: ExecCommandAllowlist(patterns: ["/bin/*", "/usr/bin/*"]),
            shutdownGraceSeconds: 0.2
        )
        try await transport.start()
        let text = AnyCodable(String(repeating: "y", count: 2_000))
        let line = MCPJSONRPCMessage.notification(method: "notifications/message", params: AnyCodable(["text": text]))
        var failure: Error?
        for _ in 0..<5_000 {
            do {
                try await transport.send(line)
            } catch {
                failure = error
                break
            }
        }
        #expect(failure is MCPTransportError)
        await transport.close()
    }

    @Test
    func dangerousEnvironmentVariablesAreDropped() async throws {
        let lines = Lines()
        let env = [
            "LD_PRELOAD": "/nonexistent/evil.so",
            "DYLD_INSERT_LIBRARIES": "/nonexistent/evil.dylib",
            "NODE_OPTIONS": "--require /nonexistent/payload.js",
            "BASH_ENV": "/nonexistent/rc",
            "GITHUB_TOKEN": "gh-token",
            "FAKE": "1",
        ]
        let transport = try MCPStdioTransport(
            serverName: "env",
            config: MCPServerConfig(command: "/bin/sh", args: ["-c", "env >&2"], env: env),
            allowlist: ExecCommandAllowlist(patterns: ["/bin/*", "/usr/bin/*"]),
            diagnostics: { event in
                if event.name == "mcp.stderr" { await lines.append(event.metadata["line"] ?? "") }
                if event.name == "mcp.env.dropped" { await lines.append("dropped:" + (event.metadata["key"] ?? "")) }
            },
            shutdownGraceSeconds: 0.2
        )
        #expect(transport.droppedEnvironmentKeys == ["BASH_ENV", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "NODE_OPTIONS"])
        try await transport.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        let captured = await lines.values
        #expect(captured.contains("bundle-mcp:env: FAKE=1"))
        #expect(captured.contains("bundle-mcp:env: GITHUB_TOKEN=gh-token"))
        let stderr = captured.filter { $0.hasPrefix("bundle-mcp:") }
        #expect(!stderr.contains { $0.contains("LD_PRELOAD") || $0.contains("DYLD_INSERT") || $0.contains("NODE_OPTIONS=") || $0.contains("BASH_ENV=") })
        #expect(captured.filter { $0.hasPrefix("dropped:") }.sorted() == [
            "dropped:BASH_ENV", "dropped:DYLD_INSERT_LIBRARIES", "dropped:LD_PRELOAD", "dropped:NODE_OPTIONS",
        ])
        await transport.close()
    }

    @Test
    func environmentPolicyMatchesUpstream() {
        let dangerous = ["LD_PRELOAD", "ld_library_path", " DYLD_INSERT_LIBRARIES ", "NODE_OPTIONS", "PYTHONPATH", "BASH_FUNC_x%%"]
        for key in dangerous + ["GIT_SSH_COMMAND", "OPENSSL_CONF", "SHELL"] {
            #expect(MCPStdioEnvironmentPolicy.isDangerous(key), "\(key) is dropped")
        }
        for key in ["GITHUB_TOKEN", "AWS_ACCESS_KEY_ID", "DATABASE_URL", "HOME", "FAKE", "API_KEY", "PATH", ""] {
            #expect(!MCPStdioEnvironmentPolicy.isDangerous(key), "\(key) is kept")
        }
        let sanitized = MCPStdioEnvironmentPolicy.sanitize(["LD_PRELOAD": "x", "TOKEN": "y"])
        #expect(sanitized.allowed == ["TOKEN": "y"])
        #expect(sanitized.dropped == ["LD_PRELOAD"])
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
