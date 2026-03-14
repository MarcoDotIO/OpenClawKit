import Foundation

/// Shared content payload used when building a share-to-agent deep link.
public struct SharedContentPayload: Sendable, Equatable {
    /// Shared title, when available.
    public let title: String?
    /// Shared URL, when available.
    public let url: URL?
    /// Shared text body, when available.
    public let text: String?

    /// Creates a share payload from optional title, URL, and text values.
    public init(title: String?, url: URL?, text: String?) {
        self.title = title
        self.url = url
        self.text = text
    }
}

/// Helpers for turning shared content into an `openclaw://agent` deep link.
public enum ShareToAgentDeepLink {
    /// Builds a deep-link URL for the shared content when there is anything to send.
    public static func buildURL(from payload: SharedContentPayload, instruction: String? = nil) -> URL? {
        let message = self.buildMessage(from: payload, instruction: instruction)
        guard !message.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "openclaw"
        components.host = "agent"
        components.queryItems = [
            URLQueryItem(name: "message", value: message),
            URLQueryItem(name: "thinking", value: "low"),
        ]
        return components.url
    }

    /// Builds the text payload inserted into the deep link.
    public static func buildMessage(from payload: SharedContentPayload, instruction: String? = nil) -> String {
        let title = self.clean(payload.title)
        let text = self.clean(payload.text)
        let urlText = payload.url?.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInstruction = self.clean(instruction) ?? ShareToAgentSettings.loadDefaultInstruction()

        var lines: [String] = ["Shared from iOS."]
        if let title, !title.isEmpty {
            lines.append("Title: \(title)")
        }
        if let urlText, !urlText.isEmpty {
            lines.append("URL: \(urlText)")
        }
        if let text, !text.isEmpty {
            lines.append("Text:\n\(text)")
        }
        lines.append(resolvedInstruction)

        let message = lines.joined(separator: "\n\n")
        return self.limit(message, maxCharacters: 2400)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func limit(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters))
    }
}
