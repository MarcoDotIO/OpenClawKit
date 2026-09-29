#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct ChatComposerTextViewIOS: UIViewRepresentable {
    @Binding var text: String
    var focusRequested: Bool
    var isEnabled: Bool
    var minHeight: CGFloat
    var maxHeight: CGFloat
    var onFocusChange: (Bool) -> Void
    var onHistoryUp: (Bool) -> Bool
    var onHistoryDown: () -> Bool
    /// Receives images pasted while the pasteboard has no text (SwiftUI text editors cannot intercept image paste
    /// before iOS 27's `pasteDestination`).
    var onPasteImageAttachment: ((_ data: Data, _ fileName: String, _ mimeType: String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ChatComposerUITextView {
        let textView = ChatComposerTextViewIOSFactory.makeConfiguredTextView()
        textView.delegate = context.coordinator
        textView.text = self.text
        self.configureHistoryHandlers(textView)
        return textView
    }

    func updateUIView(_ textView: ChatComposerUITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.scheduleInteractionUpdate(textView)
        self.configureHistoryHandlers(textView)

        let isEcho = context.coordinator.lastReportedText == self.text
        if textView.isFirstResponder, isEcho {
            return
        }

        if textView.text != self.text {
            context.coordinator.isProgrammaticUpdate = true
            defer { context.coordinator.isProgrammaticUpdate = false }
            textView.text = self.text
            if textView.isFirstResponder {
                textView.selectedRange = NSRange(location: (self.text as NSString).length, length: 0)
            }
            textView.invalidateIntrinsicContentSize()
        }
        context.coordinator.lastReportedText = self.text
    }

    private func configureHistoryHandlers(_ textView: ChatComposerUITextView) {
        textView.onHistoryUp = self.onHistoryUp
        textView.onHistoryDown = self.onHistoryDown
        textView.onPasteImageAttachment = self.onPasteImageAttachment
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ChatComposerUITextView,
        context _: Context) -> CGSize?
    {
        guard let width = proposal.width else { return nil }
        let fitting = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(
            width: width,
            height: min(max(fitting.height, self.minHeight), self.maxHeight))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatComposerTextViewIOS
        var isProgrammaticUpdate = false
        var lastReportedText: String?
        private var interactionUpdateScheduled = false

        init(_ parent: ChatComposerTextViewIOS) {
            self.parent = parent
        }

        func scheduleInteractionUpdate(_ textView: ChatComposerUITextView) {
            guard !self.interactionUpdateScheduled else { return }
            self.interactionUpdateScheduled = true
            // Disabling a focused UITextView synchronously resigns first responder.
            // Inside updateUIView that re-enters SwiftUI's responder graph and can
            // spin in AttributeGraph. Apply UIKit state after the graph update,
            // reading the latest parent so a queued disable cannot outlive recovery.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.interactionUpdateScheduled = false
                guard let textView else { return }
                if textView.isEditable != self.parent.isEnabled {
                    textView.isEditable = self.parent.isEnabled
                }
                if textView.isSelectable != self.parent.isEnabled {
                    textView.isSelectable = self.parent.isEnabled
                }
                // UIKit owns user-initiated focus; false is not a blur request.
                if self.parent.focusRequested, self.parent.isEnabled,
                   !textView.isFirstResponder
                {
                    textView.becomeFirstResponder()
                } else if !self.parent.isEnabled, textView.isFirstResponder {
                    textView.resignFirstResponder()
                }
            }
        }

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            self.parent.isEnabled
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            self.parent.isEnabled
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            self.parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            self.parent.onFocusChange(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !self.isProgrammaticUpdate, textView.isFirstResponder else { return }
            self.lastReportedText = textView.text
            self.parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }
    }
}

@MainActor
final class ChatComposerUITextView: UITextView {
    var onHistoryUp: ((Bool) -> Bool)?
    var onHistoryDown: (() -> Bool)?
    var onPasteImageAttachment: ((_ data: Data, _ fileName: String, _ mimeType: String) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(self.paste(_:)), self.onPasteImageAttachment != nil, UIPasteboard.general.hasImages {
            return self.isEditable
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        // Text wins when present (rich copies often carry both); image-only pastes become attachments.
        if let handler = self.onPasteImageAttachment, !pasteboard.hasStrings, pasteboard.hasImages {
            let attachments = ChatComposerIOSPasteSupport.imageAttachments(items: pasteboard.items)
            for attachment in attachments {
                handler(attachment.data, attachment.fileName, attachment.mimeType)
            }
            if !attachments.isEmpty { return }
        }
        super.paste(sender)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandledPresses = presses
        for press in presses {
            guard let key = press.key else { continue }
            if self.handleHardwareKey(key.keyCode, modifierFlags: key.modifierFlags) {
                unhandledPresses.remove(press)
            }
        }
        guard !unhandledPresses.isEmpty else { return }
        super.pressesBegan(unhandledPresses, with: event)
    }

    /// Internal for focused responder-level keyboard routing coverage.
    func handleHardwareKey(
        _ keyCode: UIKeyboardHIDUsage,
        modifierFlags: UIKeyModifierFlags) -> Bool
    {
        let commandModifiers: UIKeyModifierFlags = [.shift, .control, .alternate, .command]
        guard modifierFlags.isDisjoint(with: commandModifiers) else { return false }
        switch keyCode {
        case .keyboardUpArrow:
            return self.onHistoryUp?(self.caretOnFirstLine) == true
        case .keyboardDownArrow:
            return self.onHistoryDown?() == true
        default:
            return false
        }
    }

    private var caretOnFirstLine: Bool {
        let location = min(max(self.selectedRange.location, 0), (self.text as NSString).length)
        let prefix = (self.text as NSString).substring(to: location)
        return !prefix.contains("\n") && !prefix.contains("\r")
    }
}

enum ChatComposerIOSPasteSupport {
    typealias ImageAttachment = (data: Data, fileName: String, mimeType: String)

    /// Image attachments from `UIPasteboard.items`: the first image representation per item (raw bytes when the
    /// pasteboard holds data, PNG for `UIImage` values).
    static func imageAttachments(items: [[String: Any]]) -> [ImageAttachment] {
        items.enumerated().compactMap { index, item in
            let candidates = item.compactMap { key, value -> (UTType, Any)? in
                guard let type = UTType(key), type.conforms(to: .image) else { return nil }
                return (type, value)
            }
            .sorted { lhs, rhs in Self.preference(lhs.0) < Self.preference(rhs.0) }
            for (type, value) in candidates {
                if let data = value as? Data, !data.isEmpty {
                    let ext = type.preferredFilenameExtension ?? "png"
                    return (data, "pasted-image-\(index + 1).\(ext)", type.preferredMIMEType ?? "image/\(ext)")
                }
                if let image = value as? UIImage, let data = image.pngData() {
                    return (data, "pasted-image-\(index + 1).png", "image/png")
                }
            }
            return nil
        }
    }

    private static func preference(_ type: UTType) -> Int {
        if type.conforms(to: .png) { return 0 }
        if type.conforms(to: .jpeg) { return 1 }
        if type.conforms(to: .heic) { return 2 }
        return 3
    }
}

enum ChatComposerTextViewIOSFactory {
    /// Internal for @testable import coverage of native multiline input defaults.
    @MainActor
    static func makeConfiguredTextView() -> ChatComposerUITextView {
        let textView = ChatComposerUITextView()
        textView.backgroundColor = .clear
        textView.font = OpenClawChatTypography.bodyUIFont
        textView.adjustsFontForContentSizeCategory = true
        textView.allowsEditingTextAttributes = false
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.returnKeyType = .default
        textView.accessibilityIdentifier = "chat-message-input"
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }
}
#endif
