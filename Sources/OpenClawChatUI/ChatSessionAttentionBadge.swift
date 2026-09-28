// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import Foundation
import SwiftUI

// Ported from upstream OpenClaw 2026.9.6 `ChatSessionAttention.swift` (badge view). The attention models
// live in ChatSessionAttentionModels.swift.

/// Compact badge for a session's oldest pending question or approval; tapping it toggles the
/// attention disclosure identified by `presentation`.
public struct OpenClawChatAttentionBadge: View {
    /// The attention summary the badge represents.
    public let summary: OpenClawChatAttentionSummary
    private let targetID: String
    @Binding private var presentation: OpenClawChatAttentionPresentation?

    /// Creates a badge for `summary` anchored to `targetID` (for example a session row).
    public init(
        summary: OpenClawChatAttentionSummary,
        targetID: String,
        presentation: Binding<OpenClawChatAttentionPresentation?>)
    {
        self.summary = summary
        self.targetID = targetID
        self._presentation = presentation
    }

    private var selection: OpenClawChatAttentionPresentation {
        OpenClawChatAttentionPresentation(targetID: self.targetID, requestID: self.summary.disclosureIdentity)
    }

    private var isPresented: Binding<Bool> {
        let selection = self.selection
        return Binding(
            get: { self.presentation == selection },
            set: { presented in
                if presented {
                    self.presentation = selection
                } else if self.presentation == selection {
                    self.presentation = nil
                }
            })
    }

    public var body: some View {
        Button {
            self.isPresented.wrappedValue.toggle()
        } label: {
            Image(systemName: self.summary.kind == .question ? "hand.raised.fill" : "checkmark.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OpenClawChatTheme.warning)
                #if os(iOS) || os(visionOS)
                .frame(width: 44, height: 44)
                #else
                .frame(width: 22, height: 22)
                #endif
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(self.summary.accessibilityText)
        .accessibilityHint(String(localized: "Show pending request details"))
        .accessibilityIdentifier("sidebar-attention-\(self.summary.kind.rawValue)")
        .help(self.summary.accessibilityText)
        .popover(isPresented: self.isPresented) {
            VStack(alignment: .leading, spacing: 10) {
                Text(self.summary.title)
                    .font(OpenClawChatTypography.body(size: 14, weight: .semibold, relativeTo: .body))
                    .lineLimit(nil)
                ViewThatFits(in: .vertical) {
                    self.preview
                    ScrollView { self.preview }
                }
                .frame(maxHeight: 280)
                if let additional = self.summary.additionalRequestsText {
                    Text(additional)
                        .font(OpenClawChatTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                }
            }
            .padding(16)
            .frame(minWidth: 220, idealWidth: 300, maxWidth: 360, alignment: .leading)
            #if os(iOS) || os(visionOS)
            .presentationCompactAdaptation(.popover)
            #endif
        }
        .onChange(of: self.selection) { previous, _ in
            if self.presentation == previous { self.presentation = nil }
        }
        .onDisappear {
            if self.presentation == self.selection { self.presentation = nil }
        }
    }

    private var preview: some View {
        Text(verbatim: self.summary.oldest.preview)
            .font(OpenClawChatTypography.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
    }
}
#endif
