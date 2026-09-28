import Foundation

/// Shared defaults-backed settings for the share-to-agent flow.
///
/// Deprecated: upstream OpenClaw removed the stored default instruction, and
/// ``ShareToAgentDeepLink/buildMessage(from:instruction:)`` no longer appends it. Pass an explicit
/// `instruction` instead. Scheduled for removal in the next breaking release. Storage now follows
/// ``OpenClawAppGroup`` instead of the hard-coded `group.ai.openclaw.shared` suite.
@available(*, deprecated, message: "Pass an explicit instruction to ShareToAgentDeepLink instead")
public enum ShareToAgentSettings {
    private static let defaultInstructionKey = "share.defaultInstruction"
    private static let fallbackInstruction = "Please help me with this."

    private static var defaults: UserDefaults {
        OpenClawAppGroup.sharedDefaults
    }

    /// Loads the default instruction appended to shared content.
    public static func loadDefaultInstruction() -> String {
        let raw = self.defaults.string(forKey: self.defaultInstructionKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty {
            return raw
        }
        return self.fallbackInstruction
    }

    /// Saves or clears the default instruction appended to shared content.
    public static func saveDefaultInstruction(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            self.defaults.removeObject(forKey: self.defaultInstructionKey)
            return
        }
        self.defaults.set(trimmed, forKey: self.defaultInstructionKey)
    }
}
