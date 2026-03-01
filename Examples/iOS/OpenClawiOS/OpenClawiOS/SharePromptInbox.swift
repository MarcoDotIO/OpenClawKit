import Foundation

/// Shared payload format consumed from the Ask OpenClaw share extension.
struct SharePromptInboxItem: Codable, Equatable {
    let id: UUID
    let prompt: String
    let createdAt: Date

    init(id: UUID = UUID(), prompt: String, createdAt: Date = Date()) {
        self.id = id
        self.prompt = prompt
        self.createdAt = createdAt
    }
}

/// Bridge between the app process and Share Extension via App Group defaults.
enum SharePromptInbox {
    static let appGroupSuiteName = "group.io.marcodotio.OpenClawKit"
    static let defaultsKey = "openclaw.share.prompt.inbox"

    static func enqueue(
        prompt: String,
        userDefaults: UserDefaults? = UserDefaults(suiteName: appGroupSuiteName)
    ) {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        let defaults = userDefaults ?? .standard
        let item = SharePromptInboxItem(prompt: normalized)
        guard let encoded = try? JSONEncoder().encode(item) else {
            return
        }
        defaults.set(encoded, forKey: defaultsKey)
    }

    static func dequeue(
        userDefaults: UserDefaults? = UserDefaults(suiteName: appGroupSuiteName)
    ) -> SharePromptInboxItem? {
        let defaults = userDefaults ?? .standard
        guard let encoded = defaults.data(forKey: defaultsKey) else {
            return nil
        }
        defaults.removeObject(forKey: defaultsKey)
        return try? JSONDecoder().decode(SharePromptInboxItem.self, from: encoded)
    }
}
