import Testing
import OpenClawMCP

@Suite("OpenClawMCP module smoke")
struct MCPModuleSmokeTests {
    @Test
    func moduleBuildsOnEveryRuntimePlatform() {
        #expect(OpenClawMCP.moduleVersion == "2026.3.0")
        #if os(macOS) || os(Linux)
        #expect(OpenClawMCP.supportsStdioTransport)
        #endif
    }
}
