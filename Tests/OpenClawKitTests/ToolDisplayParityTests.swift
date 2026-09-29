import Foundation
import Testing
@testable import OpenClawKit

struct ToolDisplayParityTests {
    /// Tool keys of upstream OpenClaw v2026.9.6 `apps/shared/OpenClawKit/Sources/OpenClawKit/Resources/tool-display.json`.
    private static let upstreamToolKeys = [
        "agents_list", "agents_wait", "api", "apply_patch", "ask_user", "attach", "bash", "browser", "canvas",
        "code_execution", "computer", "conversations_list", "conversations_send", "conversations_turn",
        "create_goal", "cron", "dashboard", "dismiss_task", "edit", "exec", "gateway", "gateway_process",
        "get_goal", "github_identity_status", "github_publish", "image", "image_generate", "memory_get",
        "memory_search", "message", "mobile_ui", "music_generate", "nodes", "openclaw", "pdf", "plugins",
        "portal", "process", "progress_card", "read", "screen", "secrets", "session_status", "sessions",
        "sessions_history", "sessions_list", "sessions_search", "sessions_send", "sessions_spawn",
        "sessions_yield", "skill_workshop", "structured_output", "subagents", "suggest_task", "terminal",
        "theme", "tool_call", "tool_call_update", "transcripts", "tts", "update_goal", "video_generate",
        "view_image", "web_fetch", "web_search", "write",
    ]

    @Test func `bundled tool display keys match the upstream snapshot`() {
        #expect(ToolDisplayRegistry.knownToolNames == Self.upstreamToolKeys)
    }

    @Test func `canonical names resolve through legacy aliases`() {
        let automations = ToolDisplayRegistry.resolve(name: "automations", args: nil)
        #expect(automations.title == "Cron")
        #expect(automations.emoji == "⏰")
        #expect(ToolDisplayRegistry.resolve(name: "apply-patch", args: nil).title
            == ToolDisplayRegistry.resolve(name: "apply_patch", args: nil).title)
        #expect(ToolDisplayRegistry.resolve(name: "Exec", args: nil).title == "Exec")
    }

    @Test func `MCP tools without entries render as server and tool`() {
        let summary = ToolDisplayRegistry.resolve(name: "github__create_issue", args: nil)
        #expect(summary.label == "github: create_issue")
        #expect(summary.title == "Create Issue")
        #expect(summary.emoji == "🧩")
    }

    @Test func `descriptor metadata fills tools without entries`() {
        var descriptor = AgentToolDescriptor(name: "weather_lookup", description: "Look up the weather")
        descriptor.label = "Weather"
        descriptor.display = AgentToolDisplay(title: "Weather lookup", emoji: "🌦️")
        descriptor.displaySummary = "Forecast for a city"
        let hints = ToolDisplayHints(
            title: descriptor.display?.title,
            emoji: descriptor.display?.emoji,
            label: descriptor.label,
            summary: descriptor.displaySummary)
        let summary = ToolDisplayRegistry.resolve(name: "weather_lookup", args: nil, hints: hints)
        #expect(summary.title == "Weather lookup")
        #expect(summary.emoji == "🌦️")
        #expect(summary.label == "Weather")
        #expect(summary.detail == "Forecast for a city")

        // Explicit JSON entries still win over hints.
        let shell = ToolDisplayHints(title: "Shell", emoji: "🐚")
        #expect(ToolDisplayRegistry.resolve(name: "exec", args: nil, hints: shell).title == "Exec")
    }

    @Test func `display aliases mirror the agent tool registry`() {
        #expect(ToolDisplayRegistry.toolNameAliases == AgentToolRegistry.toolNameAliases)
    }

    @Test func `new upstream tools resolve their detail keys`() {
        let args = AnyCodable(["url": AnyCodable("https://docs.openclaw.ai"), "query": AnyCodable("ignored")])
        let fetch = ToolDisplayRegistry.resolve(name: "web_fetch", args: args)
        #expect(fetch.detail == "https://docs.openclaw.ai")
        #expect(fetch.title == "Web Fetch")
        #expect(fetch.emoji == "📄")
    }
}
