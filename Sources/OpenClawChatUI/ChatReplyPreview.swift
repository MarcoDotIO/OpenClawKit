// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

struct ChatReplyPreview: View {
    let target: OpenClawChatReplyTarget
    let onCancel: () -> Void

    var body: some View {
        let preview = ChatReplyQuote.previewText(self.target.text)
        HStack(spacing: 6) {
            Image(systemName: "message")
                .foregroundStyle(.secondary)
            Text(String(format: String(localized: "Replying to %@"), self.target.senderLabel))
                .font(OpenClawChatTypography.captionSemiBold)
                .lineLimit(1)
            Text(preview.text + (preview.isTruncated ? "..." : ""))
                .font(OpenClawChatTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: self.onCancel) {
                Image(systemName: "xmark")
                    .font(OpenClawChatTypography.captionSemiBold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Cancel reply"))
            .help(String(localized: "Cancel reply"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(OpenClawChatTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif
