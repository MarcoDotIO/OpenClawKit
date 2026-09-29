import Foundation
import Testing
@testable import OpenClawChatUI

private actor RecordingLinkFlagger: ChatLinkFlagging {
    private(set) var flagged: [URL] = []

    func addFlaggedURLs(_ urls: [URL]) async {
        self.flagged.append(contentsOf: urls)
    }

    func isFlaggedURL(_ url: URL) async -> Bool {
        self.flagged.contains(url)
    }
}

@Suite("Chat link security")
struct ChatLinkSecurityTests {
    private func message(
        role: String,
        text: String,
        toolName: String? = nil,
        provenance: OpenClawChatInputProvenance? = nil) -> OpenClawChatMessage
    {
        OpenClawChatMessage(
            role: role,
            content: [OpenClawChatMessageContent(type: "text", text: text, mimeType: nil, fileName: nil, content: nil)],
            timestamp: 1,
            toolName: toolName,
            provenance: provenance)
    }

    @Test func `provenance decides which messages are untrusted`() {
        #expect(ChatLinkSecurity.isUntrustedProvenance(self.message(role: "toolResult", text: "x")))
        #expect(ChatLinkSecurity.isUntrustedProvenance(self.message(role: "tool_result", text: "x")))
        #expect(ChatLinkSecurity.isUntrustedProvenance(self.message(
            role: "user",
            text: "x",
            provenance: OpenClawChatInputProvenance(kind: "external_user", sourceChannel: "telegram"))))
        #expect(ChatLinkSecurity.isUntrustedProvenance(self.message(
            role: "user",
            text: "x",
            provenance: OpenClawChatInputProvenance(kind: "inter_session", sourceChannel: "slack"))))
        #expect(!ChatLinkSecurity.isUntrustedProvenance(self.message(
            role: "user",
            text: "x",
            provenance: OpenClawChatInputProvenance(kind: "internal_system", sourceChannel: "slack"))))
        #expect(!ChatLinkSecurity.isUntrustedProvenance(self.message(role: "user", text: "x")))
        #expect(!ChatLinkSecurity.isUntrustedProvenance(self.message(role: "assistant", text: "x")))
    }

    @Test func `untrusted messages flag every web link once in reading order`() {
        let message = self.message(
            role: "toolResult",
            text: "See https://b.example/path and [docs](https://a.example/docs), again https://b.example/path.",
            toolName: "web_fetch")

        #expect(ChatLinkSecurity.untrustedLinks(in: message).map(\.absoluteString) == [
            "https://b.example/path",
            "https://a.example/docs",
        ])
    }

    @Test func `assistant prose is trusted but merged web tool results are not`() throws {
        let prose = self.message(role: "assistant", text: "Read https://docs.example/guide")
        #expect(ChatLinkSecurity.untrustedLinks(in: prose).isEmpty)

        let merged = OpenClawChatMessage(
            role: "assistant",
            content: [
                OpenClawChatMessageContent(
                    type: "text", text: "Summary at https://own.example", mimeType: nil, fileName: nil, content: nil),
                OpenClawChatMessageContent(
                    type: "toolResult", text: "Result https://third.example/page", mimeType: nil,
                    fileName: nil, content: nil, id: "call-1", name: "browser"),
                OpenClawChatMessageContent(
                    type: "toolResult", text: "Local https://local.example/file", mimeType: nil,
                    fileName: nil, content: nil, id: "call-2", name: "read"),
            ],
            timestamp: 1)
        #expect(try ChatLinkSecurity.untrustedLinks(in: merged) == [#require(URL(string: "https://third.example/page"))])
    }

    @Test func `code and non web links are never flagged`() {
        let message = self.message(
            role: "toolResult",
            text: "`https://code.example` mailto:someone@example.com ftp://files.example/x")

        #expect(ChatLinkSecurity.untrustedLinks(in: message).isEmpty)
    }

    @Test func `flagging goes through the injected store`() async throws {
        let flagger = RecordingLinkFlagger()
        let url = try #require(URL(string: "https://tracker.example/x"))

        await ChatLinkSecurity.flagUntrustedLinks(
            in: self.message(role: "toolResult", text: "go to \(url.absoluteString)"),
            flagger: flagger)
        await ChatLinkSecurity.flagUntrustedLinks(
            in: self.message(role: "assistant", text: "https://safe.example"),
            flagger: flagger)

        #expect(await flagger.flagged == [url])
        #expect(await ChatLinkSecurity.requiresConfirmation(url, flagger: flagger))
        #expect(try await !ChatLinkSecurity.requiresConfirmation(
            #require(URL(string: "https://safe.example")),
            flagger: flagger))
    }

    @Test func `web tool names are recognized`() {
        for name in ["web_fetch", "WebSearch", "browser", "http_request", "url_fetch", "crawl"] {
            #expect(ChatLinkSecurity.isWebTool(name))
        }
        for name in ["read", "exec", "apply_patch", nil] {
            #expect(!ChatLinkSecurity.isWebTool(name))
        }
    }

    #if compiler(>=6.4) && canImport(LinkSecurity) && os(macOS)
    @Test func `system store flags and checks links on macOS 27`() async throws {
        guard #available(macOS 27.0, *) else { return }
        let flagger = SystemChatLinkFlagger()
        let flagged = try #require(URL(string: "https://openclawkit-\(UUID().uuidString.lowercased()).example.invalid/x"))
        let other = try #require(URL(string: "https://openclawkit-\(UUID().uuidString.lowercased()).example.invalid/y"))

        await flagger.addFlaggedURLs([flagged])

        #expect(await flagger.isFlaggedURL(flagged))
        #expect(await !flagger.isFlaggedURL(other))
    }
    #endif
}
