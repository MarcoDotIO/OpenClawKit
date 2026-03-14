import SwiftUI

public enum ChatMarkdownVariant: String, CaseIterable, Sendable {
    case standard
    case compact
}

@MainActor
struct ChatMarkdownRenderer: View {
    enum Context {
        case user
        case assistant
    }

    let text: String
    let context: Context
    let variant: ChatMarkdownVariant
    let font: Font
    let textColor: Color

    var body: some View {
        let processed = ChatMarkdownPreprocessor.preprocess(markdown: self.text)
        VStack(alignment: .leading, spacing: 10) {
            self.renderedMarkdown(processed.cleaned)

            if !processed.images.isEmpty {
                InlineImageList(images: processed.images)
            }
        }
    }

    @ViewBuilder
    private func renderedMarkdown(_ markdown: String) -> some View {
        if let attributed = self.attributedMarkdown(markdown) {
            Text(attributed)
                .font(self.font)
                .foregroundStyle(self.textColor)
                .textSelection(.enabled)
                .lineSpacing(self.variant == .compact ? 2 : 4)
        } else {
            Text(markdown)
                .font(self.font)
                .foregroundStyle(self.textColor)
                .textSelection(.enabled)
                .lineSpacing(self.variant == .compact ? 2 : 4)
        }
    }

    private func attributedMarkdown(_ markdown: String) -> AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return try? AttributedString(markdown: markdown, options: options)
    }
}

@MainActor
private struct InlineImageList: View {
    let images: [ChatMarkdownPreprocessor.InlineImage]

    var body: some View {
        ForEach(images, id: \.id) { item in
            if let img = item.image {
                OpenClawPlatformImageFactory.image(img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            } else {
                Text(item.label.isEmpty ? "Image" : item.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
