import Foundation
import Markdown
import OpenClawKit

// Ported subset of upstream OpenClaw 2026.9.6 `ChatLinkPreview.swift`: citation URL extraction shared by
// source previews. The OpenGraph fetcher and link preview cards belong with the transcript views.

/// Returns HTTP(S) links in reading order, without treating code or image labels as citations.
func chatPreviewURLs(in markdown: String) -> [URL] {
    chatPreviewURLs(in: Document(parsing: markdown))
}

/// First previewable link in `markdown`.
func chatFirstPreviewURL(in markdown: String) -> URL? {
    chatPreviewURLs(in: markdown).first
}

private func chatPreviewURLs(in markup: any Markup) -> [URL] {
    if markup is InlineCode || markup is CodeBlock || markup is Markdown.Image {
        return []
    }
    if let link = markup as? Markdown.Link {
        return link.destination.flatMap(chatSafeWebURL).map { [$0] } ?? []
    }
    if let text = markup as? Markdown.Text {
        return chatBarePreviewURLs(in: text.string)
    }
    return markup.children.flatMap(chatPreviewURLs)
}

private func chatBarePreviewURLs(in text: String) -> [URL] {
    let pattern = #"(?i)https?://[^\s<>\"`]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
        guard let range = Range(match.range, in: text) else { return nil }
        var candidate = String(text[range])
        while let last = candidate.last, ".,;:!?".contains(last) {
            candidate.removeLast()
        }
        for pair: (open: Character, close: Character) in [("(", ")"), ("[", "]"), ("{", "}")] {
            while candidate.hasSuffix(String(pair.close)),
                  candidate.chatLinkPreviewCount(of: pair.close) > candidate.chatLinkPreviewCount(of: pair.open)
            {
                candidate.removeLast()
            }
        }
        return chatSafeWebURL(candidate)
    }
}

extension String {
    fileprivate func chatLinkPreviewCount(of character: Character) -> Int {
        self.reduce(into: 0) { count, current in
            if current == character {
                count += 1
            }
        }
    }
}

private func chatSafeWebURL(_ value: String) -> URL? {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host != nil
    else { return nil }
    return url
}
