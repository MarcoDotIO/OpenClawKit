// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import OpenClawKit
import SwiftUI

// Adapted from upstream OpenClaw 2026.9.6 `ChatMermaidBlockView.swift`: the card, source toggle,
// retry and expanded preview are ported; rendering goes through the host-supplied
// `OpenClawChatMermaidRenderer` instead of upstream's bundled WebKit renderer.
@MainActor
struct ChatMermaidBlockView: View {
    let source: String
    let renderer: OpenClawChatMermaidRenderer

    @Environment(\.self) private var environment
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var width = 0
    @State private var result: Result<OpenClawChatMermaidDiagram, OpenClawChatMermaidRenderError>?
    @State private var renderGeneration = 0
    @State private var showSource = false
    @State private var isHovered = false
    @State private var expanded: PreviewSelection?

    private struct PreviewSelection: Identifiable {
        let id = UUID()
        let diagram: OpenClawChatMermaidDiagram
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                ChatCopyButton(text: self.source, label: "Copy diagram source", revealed: self.isHovered)
                Menu {
                    Button {
                        self.showSource.toggle()
                    } label: {
                        if self.showSource {
                            Text("View diagram").font(OpenClawChatTypography.body)
                        } else {
                            Text("View source").font(OpenClawChatTypography.body)
                        }
                    }
                    Button {
                        self.expand()
                    } label: {
                        Text("Expand diagram").font(OpenClawChatTypography.body)
                    }
                    .disabled(self.rendered == nil)
                    if self.canRetry {
                        Button {
                            self.renderGeneration += 1
                        } label: {
                            Text("Retry diagram").font(OpenClawChatTypography.body)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: ChatCopyButton.controlSize, height: ChatCopyButton.controlSize)
                }
                .accessibilityLabel("Diagram options")
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Diagram options")
                #endif
            }
            .foregroundStyle(.secondary)
            if self.showSource {
                self.sourceView
            } else if let rendered = self.rendered {
                Button {
                    self.expand()
                } label: {
                    OpenClawPlatformImageFactory.image(rendered.image)
                        .resizable()
                        .aspectRatio(self.aspectRatio(of: rendered), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mermaid diagram")
                .accessibilityHint("Expand diagram")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    self.status
                        .font(OpenClawChatTypography.caption)
                        .foregroundStyle(.secondary)
                    self.sourceView
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenClawChatTheme.assistantBubble)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.2)))
        .onGeometryChange(for: Int.self) { geometry in
            Int(geometry.size.width.rounded(.up))
        } action: { self.width = $0 }
        .task(id: RenderKey(request: self.request, generation: self.renderGeneration)) {
            await self.render()
        }
        .onHover { self.isHovered = $0 }
        .sheet(item: self.$expanded) { selection in
            ChatMermaidPreviewView(diagram: selection.diagram)
        }
    }

    private struct RenderKey: Equatable {
        let request: OpenClawChatMermaidRenderRequest?
        let generation: Int
    }

    private func aspectRatio(of diagram: OpenClawChatMermaidDiagram) -> CGFloat {
        guard diagram.size.width > 0, diagram.size.height > 0 else { return 1 }
        return diagram.size.width / diagram.size.height
    }

    private func expand() {
        guard let rendered = self.rendered else { return }
        self.expanded = PreviewSelection(diagram: rendered)
    }

    private var sourceView: some View {
        ChatCodeBlockView(block: ChatCodeBlock(language: nil, code: self.source, isComplete: true))
    }

    private var rendered: OpenClawChatMermaidDiagram? {
        guard case let .success(diagram)? = self.result else { return nil }
        return diagram
    }

    private var canRetry: Bool {
        guard case let .failure(error)? = self.result else { return false }
        return error.retryable
    }

    @ViewBuilder
    private var status: some View {
        if self.result == nil {
            Text("Rendering diagram…")
        } else if self.canRetry {
            Text(
                "Diagram temporarily unavailable. Use the menu to retry, or read and copy its source.")
        } else {
            Text(
                "Diagram unavailable. Check the syntax or simplify the diagram. You can still read or copy its source.")
        }
    }

    private var request: OpenClawChatMermaidRenderRequest? {
        guard self.width > 0 else { return nil }
        return OpenClawChatMermaidRenderRequest(
            source: self.source,
            width: self.width,
            displayScale: self.displayScale,
            theme: OpenClawChatMermaidTheme(
                background: self.cssColor(OpenClawChatTheme.assistantBubble),
                foreground: self.cssColor(OpenClawChatTheme.assistantText),
                muted: self.cssColor(.secondary),
                border: self.cssColor(OpenClawChatTheme.divider),
                accent: self.cssColor(OpenClawChatTheme.accent),
                fontFamily: "sans-serif",
                darkMode: self.colorScheme == .dark))
    }

    private func cssColor(_ color: Color) -> String {
        let resolved = color.resolve(in: self.environment)
        return String(
            format: "#%02x%02x%02x",
            Int(max(0, min(1, resolved.red)) * 255),
            Int(max(0, min(1, resolved.green)) * 255),
            Int(max(0, min(1, resolved.blue)) * 255))
    }

    private func render() async {
        self.result = nil
        guard let request = self.request else { return }
        guard request.isAdmissible else {
            self.result = .failure(OpenClawChatMermaidRenderError(message: "invalid request", retryable: false))
            return
        }
        do {
            let diagram = try await self.renderer.render(request)
            guard !Task.isCancelled else { return }
            self.result = .success(diagram)
        } catch let error as OpenClawChatMermaidRenderError {
            guard !Task.isCancelled else { return }
            self.result = .failure(error)
        } catch {
            guard !Task.isCancelled else { return }
            self.result = .failure(OpenClawChatMermaidRenderError(
                message: error.localizedDescription,
                retryable: true))
        }
    }
}

@MainActor
private struct ChatMermaidPreviewView: View {
    let diagram: OpenClawChatMermaidDiagram
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close diagram preview")
                #if os(macOS)
                .keyboardShortcut(.cancelAction)
                #endif
            }
            ScrollView([.horizontal, .vertical]) {
                OpenClawPlatformImageFactory.image(self.diagram.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: max(1, self.diagram.size.width), height: max(1, self.diagram.size.height))
                    .padding(16)
                    .accessibilityLabel("Mermaid diagram")
            }
            .defaultScrollAnchor(.center)
        }
        .background(OpenClawChatTheme.assistantBubble)
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 900, minHeight: 350, idealHeight: 600)
        .modifier(ChatFittedPresentationSizing())
        #endif
    }
}

#if os(macOS)
/// Mac sheets default to a form width; fit both axes so Expand honors the ideal size (macOS 15+).
private struct ChatFittedPresentationSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.presentationSizing(.fitted)
        } else {
            content
        }
    }
}
#endif
#endif
