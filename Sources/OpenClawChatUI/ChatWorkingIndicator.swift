// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import Foundation
import SwiftUI

// Upstream OpenClaw 2026.9.6 draws its claw mascot (`ChatWorkingClawView`, OpenClaw brand art) next to
// the working status line, in subagent rows and in the turn recap. OpenClawKit ships no mascot art:
// the indicator is pluggable. The default is a neutral three-dot typing indicator; hosts can draw
// their own through `.openClawChatWorkingIndicatorStyle(.custom(...))`, using the seeded stance and
// the parked/animation state upstream's mascot uses. `ChatWorkingStatusText` and `ChatTurnRecapRow`
// are ported from upstream `ChatWorkingClawView.swift` unchanged apart from the indicator.

/// What a working indicator should draw.
public struct OpenClawChatWorkingIndicatorContext: Equatable, Sendable {
    /// Stable seed for the run, subagent or recap row; use it to vary motion deterministically.
    public let seed: String
    /// True for resting rows (turn recap, completed subagents): draw a static pose.
    public let isParked: Bool
    /// Tint requested by the row (for example a subagent's color); nil means the chat accent.
    public let tint: Color?
    /// Whether motion is allowed. False when parked, under Reduce Motion, while the scene is
    /// inactive, or when the system prefers reduced resource usage (27+).
    public let animates: Bool
    /// Upstream's weighted, seeded animation stance name (for example "standard", "southpaw",
    /// "spin"), so custom indicators can reproduce the mascot's per-run variety.
    public let stance: String
}

/// A host-drawn working indicator.
public struct OpenClawChatWorkingIndicator: Sendable {
    let make: @MainActor @Sendable (OpenClawChatWorkingIndicatorContext) -> AnyView

    /// Creates an indicator from a view builder. Keep it within about 28 x 24 points.
    public init<Content: View>(
        @ViewBuilder content: @escaping @MainActor @Sendable (OpenClawChatWorkingIndicatorContext) -> Content)
    {
        self.make = { AnyView(content($0)) }
    }
}

/// Style of the transcript's working indicator.
public enum OpenClawChatWorkingIndicatorStyle: Sendable {
    /// Neutral three-dot typing indicator (the default).
    case dots
    /// A host-supplied indicator.
    case custom(OpenClawChatWorkingIndicator)
}

extension EnvironmentValues {
    /// Working indicator style used by chat transcript rows.
    @Entry public var openClawChatWorkingIndicatorStyle: OpenClawChatWorkingIndicatorStyle = .dots
}

extension View {
    /// Sets the working indicator drawn next to the working status, subagent rows and turn recaps.
    public func openClawChatWorkingIndicatorStyle(_ style: OpenClawChatWorkingIndicatorStyle) -> some View {
        self.environment(\.openClawChatWorkingIndicatorStyle, style)
    }
}

private enum ChatWorkingIndicatorSeed {
    /// Process lifetime is the native equivalent of the web page-load salt (as upstream).
    static let salt = UInt32.random(in: UInt32.min...UInt32.max)
}

/// The transcript's working indicator (upstream `ChatWorkingClawView` call sites).
struct ChatWorkingIndicatorView: View {
    @Environment(\.openClawChatWorkingIndicatorStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let seed: String
    var parked = false
    var tint: Color?

    init(seed: String, parked: Bool = false, tint: Color? = nil) {
        self.seed = seed
        self.parked = parked
        self.tint = tint
    }

    var body: some View {
        ChatReducedResourceUsageReader { prefersReducedResourceUsage in
            let context = OpenClawChatWorkingIndicatorContext(
                seed: self.seed,
                isParked: self.parked,
                tint: self.tint,
                animates: !self.parked && !self.reduceMotion && self.scenePhase == .active &&
                    !prefersReducedResourceUsage,
                stance: String(describing: ChatWorkingClawStance.seeded(self.seed, salt: ChatWorkingIndicatorSeed.salt)))
            switch self.style {
            case .dots:
                ChatWorkingDots(context: context)
            case let .custom(indicator):
                indicator.make(context)
            }
        }
        .frame(width: 28, height: 24)
        .accessibilityHidden(true)
    }
}

/// Default indicator: three pulsing dots, static when motion is not allowed.
private struct ChatWorkingDots: View {
    let context: OpenClawChatWorkingIndicatorContext
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill((self.context.tint ?? OpenClawChatTheme.accent).opacity(self.context.isParked ? 0.55 : 0.85))
                    .frame(width: 5, height: 5)
                    .scaleEffect(self.context.animates ? (self.animate ? 1.05 : 0.7) : 0.85)
                    .opacity(self.context.animates ? (self.animate ? 0.95 : 0.35) : 0.7)
                    .animation(
                        self.context.animates
                            ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(Double(index) * 0.16)
                            : nil,
                        value: self.animate)
            }
        }
        .onAppear { self.animate = self.context.animates }
        .onDisappear { self.animate = false }
        .onChange(of: self.context.animates) { _, animates in
            self.animate = animates
        }
    }
}

/// Reads `systemPrefersReducedResourceUsage` on 27+ SDKs and OSes; false elsewhere.
struct ChatReducedResourceUsageReader<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            ChatReducedResourceUsageReader27(content: self.content)
        } else {
            self.content(false)
        }
        #else
        self.content(false)
        #endif
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private struct ChatReducedResourceUsageReader27<Content: View>: View {
    @Environment(\.systemPrefersReducedResourceUsage) private var prefersReducedResourceUsage
    let content: (Bool) -> Content

    var body: some View {
        self.content(self.prefersReducedResourceUsage)
    }
}
#endif

struct ChatWorkingStatusText: View {
    @Environment(\.scenePhase) private var scenePhase

    let startedAt: Date
    let seed: String
    let outputTokens: Int?

    var body: some View {
        Group {
            if self.scenePhase == .active {
                TimelineView(.periodic(from: self.startedAt, by: 1)) { context in
                    self.label(at: context.date)
                }
            } else {
                self.label(at: Date())
            }
        }
        .foregroundStyle(.secondary)
    }

    private func label(at date: Date) -> some View {
        let elapsedMilliseconds = max(1000, Int(date.timeIntervalSince(self.startedAt) * 1000))
        let duration = ChatWorkingDurationFormatter.compact(milliseconds: Double(elapsedMilliseconds))
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(duration)
                .font(OpenClawChatTypography.captionSemiBold)
                .monospacedDigit()
            if let tokensText = ChatTurnRecapText.tokens(self.outputTokens) {
                Text("·")
                    .font(OpenClawChatTypography.caption)
                    .accessibilityHidden(true)
                Text(tokensText)
                    .font(OpenClawChatTypography.caption)
                    .monospacedDigit()
            }
            if let index = ChatWorkingPhrase.index(
                seed: self.seed,
                elapsedMilliseconds: elapsedMilliseconds)
            {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("·")
                        .font(OpenClawChatTypography.caption)
                    Text(ChatWorkingPhrase.resources[index] + "…")
                        .font(OpenClawChatTypography.caption)
                }
                .accessibilityHidden(true)
            }
        }
    }
}

struct ChatTurnRecapRow: View {
    let recap: ChatTurnRecap

    var body: some View {
        HStack(spacing: 7) {
            ChatWorkingIndicatorView(seed: "turn-recap", parked: true)
            Text(ChatTurnRecapText.done(runtimeMs: self.recap.runtimeMs))
                .font(OpenClawChatTypography.caption)
            if let tokensText = ChatTurnRecapText.tokens(self.recap.outputTokens) {
                Text("·")
                    .font(OpenClawChatTypography.caption)
                    .accessibilityHidden(true)
                Text(tokensText)
                    .font(OpenClawChatTypography.caption)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
#endif
