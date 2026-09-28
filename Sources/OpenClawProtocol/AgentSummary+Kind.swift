// Vendored by Scripts/protocol-gen-swift.mjs from OpenClaw 2026.9.6 (eb377ac59e) — do not edit by hand
import Foundation

extension AgentSummary {
    /// Whether users may select the agent (system agents such as the setup agent are hidden).
    public var isSelectableAgent: Bool {
        kind != .system
    }
}
