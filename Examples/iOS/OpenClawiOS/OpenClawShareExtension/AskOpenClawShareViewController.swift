import Foundation
import Social
import UniformTypeIdentifiers

private enum SharePromptInboxContract {
    static let appGroupSuiteName = "group.io.marcodotio.OpenClawKit"
    static let defaultsKey = "openclaw.share.prompt.inbox"
}

private struct SharePromptInboxItem: Codable {
    let id: UUID
    let prompt: String
    let createdAt: Date

    init(prompt: String) {
        self.id = UUID()
        self.prompt = prompt
        self.createdAt = Date()
    }
}

/// Share Extension entrypoint for "Ask OpenClaw".
final class AskOpenClawShareViewController: SLComposeServiceViewController {
    override func isContentValid() -> Bool {
        let text = (self.contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
    }

    override func didSelectPost() {
        let prompt = (self.contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        let payload = SharePromptInboxItem(prompt: prompt)
        if let encoded = try? JSONEncoder().encode(payload) {
            let defaults = UserDefaults(suiteName: SharePromptInboxContract.appGroupSuiteName) ?? .standard
            defaults.set(encoded, forKey: SharePromptInboxContract.defaultsKey)
        }

        self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    override func configurationItems() -> [Any]! {
        []
    }
}
