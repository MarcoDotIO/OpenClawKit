// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import Foundation
import SwiftUI

// Ported from upstream OpenClaw 2026.9.6 `Swarm.swift` (progress views). The Swarm projection model lives
// in Swarm.swift.
struct OpenClawChatSwarmProgressView: View {
    let groups: [OpenClawChatSwarmGroup]

    var body: some View {
        if !self.groups.isEmpty {
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    ForEach(self.groups) { group in
                        OpenClawChatSwarmGroupView(group: group)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 260)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Swarm"))
        }
    }
}

private struct OpenClawChatSwarmGroupView: View {
    let group: OpenClawChatSwarmGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: self.group.label)
                    .font(OpenClawChatTypography.captionSemiBold)
                    .lineLimit(1)
                Text(verbatim: String(
                    format: String(localized: "%1$lld Running · %2$lld Done · %3$lld Failed"),
                    Int64(self.group.running),
                    Int64(self.group.done),
                    Int64(self.group.failed)))
                    .font(OpenClawChatTypography.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if let narrator = self.group.narrator, !narrator.isEmpty {
                Text(verbatim: narrator)
                    .font(OpenClawChatTypography.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ForEach(self.group.phases) { phase in
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: phase.title ?? String(localized: "Unphased"))
                        .font(OpenClawChatTypography.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minWidth: 56, alignment: .leading)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 9, maximum: 9), spacing: 6)],
                        alignment: .leading,
                        spacing: 6)
                    {
                        ForEach(phase.dots) { dot in
                            OpenClawChatSwarmDotView(dot: dot)
                        }
                        if phase.hidden > 0 {
                            Text(verbatim: "+\(phase.hidden)")
                                .font(OpenClawChatTypography.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text(
                                    verbatim: phase.hidden == 1
                                        ? String(localized: "1 more worker")
                                        : String(
                                            format: String(localized: "%1$lld more workers"),
                                            Int64(phase.hidden))))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(OpenClawChatTheme.assistantBubble.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(OpenClawChatTheme.accent.opacity(0.2), lineWidth: 1)
        }
    }
}

private struct OpenClawChatSwarmDotView: View {
    let dot: OpenClawChatSwarmDot

    var body: some View {
        self.shape
            .frame(width: 9, height: 9)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: "\(self.dot.label): \(self.dot.status.label)"))
    }

    @ViewBuilder
    private var shape: some View {
        switch self.dot.status {
        case .queued:
            Circle().stroke(OpenClawChatTheme.muted, lineWidth: 1)
        case .running:
            Circle().fill(OpenClawChatTheme.accent)
        case .done:
            Circle().fill(OpenClawChatTheme.success)
        case .failed:
            RoundedRectangle(cornerRadius: 2)
                .fill(OpenClawChatTheme.danger)
                .rotationEffect(.degrees(45))
                .scaleEffect(0.82)
        }
    }
}
#endif
