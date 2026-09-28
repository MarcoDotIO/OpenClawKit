// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core.
//
// Newer-OS composer integrations, each behind `#if compiler`/`canImport` and `if #available` with a pre-OS fallback:
// - iOS 27 `pasteDestination` accepts pasted images and files as attachments (iOS 17-26 use the UITextView paste
//   override in ChatComposerTextViewIOS.swift; macOS uses the NSTextView paste override).
// - Image Playground (iOS 18.1 / macOS 15.1 / visionOS 2.4) creates an image from the draft; on OS 27 the
//   `ImagePlaygroundOptions.creationStrategy` edits the first staged image instead of generating a new one.
//   Programmatic `ImageCreator` generation is deprecated in 27 and intentionally unused.
#if os(iOS) || os(macOS) || os(visionOS)
import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(ImagePlayground)
import ImagePlayground
#endif

// MARK: - Paste destination (iOS 27)

/// One pasted attachment: image bytes with their type, or a file URL.
struct ChatPastedAttachment: Transferable, Sendable {
    enum Payload: Sendable, Equatable {
        case image(data: Data, contentType: UTType)
        case file(URL)
    }

    let payload: Payload

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .png) { data in
            ChatPastedAttachment(payload: .image(data: data, contentType: .png))
        }
        DataRepresentation(importedContentType: .jpeg) { data in
            ChatPastedAttachment(payload: .image(data: data, contentType: .jpeg))
        }
        DataRepresentation(importedContentType: .heic) { data in
            ChatPastedAttachment(payload: .image(data: data, contentType: .heic))
        }
        ProxyRepresentation(importing: { (url: URL) in
            ChatPastedAttachment(payload: .file(url))
        })
    }

    /// File name and MIME type for a pasted image (`pasted-image-<n>.<ext>`).
    static func imageMetadata(contentType: UTType, index: Int) -> (fileName: String, mimeType: String) {
        let ext = contentType.preferredFilenameExtension ?? "png"
        return ("pasted-image-\(index + 1).\(ext)", contentType.preferredMIMEType ?? "image/\(ext)")
    }

    /// Whether a pasted file URL is a local image or movie the composer can stage.
    static func acceptsFile(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return OpenClawChatPickerAttachmentMetadata.allowedFileContentTypes.contains { type.conforms(to: $0) }
    }
}

/// Registers the composer as an iOS 27 paste destination for images and media files.
struct ChatComposerPasteDestination: ViewModifier {
    let isEnabled: Bool
    let viewModel: OpenClawChatViewModel

    func body(content: Content) -> some View {
        #if compiler(>=6.4) && os(iOS)
        if #available(iOS 27.0, *) {
            content.pasteDestination(for: ChatPastedAttachment.self) { attachments in
                self.stage(attachments)
            } validator: { attachments in
                self.isEnabled ? attachments.filter(Self.isStageable) : []
            }
        } else {
            content
        }
        #else
        content
        #endif
    }

    private static func isStageable(_ attachment: ChatPastedAttachment) -> Bool {
        switch attachment.payload {
        case .image: true
        case let .file(url): ChatPastedAttachment.acceptsFile(url)
        }
    }

    @MainActor
    private func stage(_ attachments: [ChatPastedAttachment]) {
        guard self.isEnabled else { return }
        var files: [URL] = []
        for (index, attachment) in attachments.enumerated() {
            switch attachment.payload {
            case let .image(data, contentType):
                let metadata = ChatPastedAttachment.imageMetadata(contentType: contentType, index: index)
                self.viewModel.addImageAttachment(data: data, fileName: metadata.fileName, mimeType: metadata.mimeType)
            case let .file(url) where ChatPastedAttachment.acceptsFile(url):
                files.append(url)
            case .file:
                continue
            }
        }
        if !files.isEmpty {
            self.viewModel.addAttachments(urls: files)
        }
    }
}

// MARK: - Image Playground

enum ChatImagePlaygroundSupport {
    /// Whether the system Image Playground sheet can run on this device (Apple Intelligence enabled).
    @MainActor
    static var isAvailable: Bool {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, macOS 15.1, visionOS 2.4, *) {
            return ImagePlaygroundViewController.isAvailable
        }
        #endif
        return false
    }

    /// Concept text from the draft: trimmed and capped so a long prompt stays a single concept.
    static func concept(fromDraft draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        return String(trimmed.prefix(500))
    }
}

/// Presents the Image Playground sheet seeded with the draft text and the first staged image, and stages the
/// created image as a draft attachment.
struct ChatImagePlaygroundModifier: ViewModifier {
    @Binding var isPresented: Bool
    let viewModel: OpenClawChatViewModel

    func body(content: Content) -> some View {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, macOS 15.1, visionOS 2.4, *) {
            self.playgroundSheet(content)
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if canImport(ImagePlayground)
    @available(iOS 18.1, macOS 15.1, visionOS 2.4, *)
    @ViewBuilder
    private func playgroundSheet(_ content: Content) -> some View {
        let concepts = ChatImagePlaygroundSupport.concept(fromDraft: self.viewModel.input)
            .map { [ImagePlaygroundConcept.text($0)] } ?? []
        let sourceImage = self.viewModel.attachments.first(where: { $0.preview != nil })?.preview
            .map(OpenClawPlatformImageFactory.image)
        let sheet = content.imagePlaygroundSheet(
            isPresented: self.$isPresented,
            concepts: concepts,
            sourceImage: sourceImage,
            onCompletion: { url in
                self.viewModel.addAttachments(urls: [url])
            },
            onCancellation: nil)
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            sheet.imagePlaygroundOptions(Self.options(editingExisting: sourceImage != nil))
        } else {
            sheet
        }
        #else
        sheet
        #endif
    }

    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    static func options(editingExisting: Bool) -> ImagePlaygroundOptions {
        var options = ImagePlaygroundOptions()
        options.creationStrategy = editingExisting ? .editExisting : .automatic
        return options
    }
    #endif
    #endif
}

extension OpenClawChatComposer {
    /// "Create Image" action for attachment menus; hidden where Image Playground is unavailable.
    @ViewBuilder
    var createImageButton: some View {
        if ChatImagePlaygroundSupport.isAvailable {
            Button {
                self.showsImagePlayground = true
            } label: {
                Label {
                    Text("Create Image")
                        .font(OpenClawChatTypography.body)
                } icon: {
                    Image(systemName: "apple.image.playground")
                }
            }
            .disabled(!self.isAttachmentInputEnabled)
            .accessibilityIdentifier("chat-composer-create-image")
        }
    }
}
#endif
