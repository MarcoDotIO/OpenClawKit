import CoreGraphics
import Foundation
import ImageIO
import OpenClawKit
import UniformTypeIdentifiers
import Testing
@testable import OpenClawChatUI

// Ported from upstream OpenClaw 2026.9.6 (XCTest converted to Swift Testing). Trimmed until the GRDB-backed
// OpenClawChatStore lands (W5d): healthyLegacyGatewayUsesLiveAttachmentPath,
// indeterminateOutboxRouteRetainsAttachmentAndRetriesOnceAvailable,
// legacyGatewayRetainsAttachmentUntilOutboxRestoreCompletes,
// voiceNoteSendUsesExistingAttachmentPayloadAndOptimisticDuration,
// ambiguousVoiceNoteSurvivesViewModelRecreation and
// canonicalVoiceNoteConfirmationPreservesDurationAndDeletesDurableBytes (all need OpenClawChatSQLiteTranscriptCache).

private actor AttachmentSendCapture {
    private(set) var attachments: [OpenClawChatAttachmentPayload] = []
    private(set) var sends = 0

    func store(_ attachments: [OpenClawChatAttachmentPayload]) {
        self.attachments = attachments
        self.sends += 1
    }

    func count() -> Int {
        self.attachments.count
    }

    func sendCount() -> Int {
        self.sends
    }

    func first() -> OpenClawChatAttachmentPayload? {
        self.attachments.first
    }
}

private enum AttachmentRouteLeaseAvailability: Sendable {
    case available
    case unsupported
    case indeterminate
}

private actor AttachmentRouteLeasePlan {
    private var availability: [AttachmentRouteLeaseAvailability]

    init(_ availability: [AttachmentRouteLeaseAvailability]) {
        self.availability = availability
    }

    func next() -> AttachmentRouteLeaseAvailability {
        guard self.availability.count > 1 else {
            return self.availability.first ?? .available
        }
        return self.availability.removeFirst()
    }
}

private actor AttachmentHealthGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        self.entered = true
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasEntered() -> Bool {
        self.entered
    }

    func release() {
        self.released = true
        self.continuation?.resume()
        self.continuation = nil
    }
}

@MainActor
private final class AttachmentOwnerActivity {
    var isActive = true
}

private struct AttachmentProcessingTransport: OpenClawChatTransport {
    let capture: AttachmentSendCapture?
    let healthGate: AttachmentHealthGate?
    let failsAmbiguously: Bool
    let responseStatus: String
    let returnsEmptyHistory: Bool
    let durableOutboxAvailable: Bool
    let routeLeasePlan: AttachmentRouteLeasePlan?

    init(
        capture: AttachmentSendCapture? = nil,
        healthGate: AttachmentHealthGate? = nil,
        failsAmbiguously: Bool = false,
        responseStatus: String = "started",
        returnsEmptyHistory: Bool = false,
        durableOutboxAvailable: Bool = true,
        routeLeasePlan: AttachmentRouteLeasePlan? = nil)
    {
        self.capture = capture
        self.healthGate = healthGate
        self.failsAmbiguously = failsAmbiguously
        self.responseStatus = responseStatus
        self.returnsEmptyHistory = returnsEmptyHistory
        self.durableOutboxAvailable = durableOutboxAvailable
        self.routeLeasePlan = routeLeasePlan
    }

    func requestHistory(sessionKey _: String) async throws -> OpenClawChatHistoryPayload {
        if self.returnsEmptyHistory {
            return OpenClawChatHistoryPayload(
                sessionKey: "main",
                sessionId: "session-main",
                messages: [],
                thinkingLevel: "off")
        }
        throw NSError(domain: "ChatViewModelAttachmentTests", code: 1)
    }

    func sendMessage(
        sessionKey _: String,
        message _: String,
        thinking _: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        await self.capture?.store(attachments)
        if self.failsAmbiguously {
            throw NSError(
                domain: "ChatViewModelAttachmentTests",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Connection lost"])
        }
        return OpenClawChatSendResponse(runId: idempotencyKey, status: self.responseStatus)
    }

    func requestHealth(timeoutMs _: Int) async throws -> Bool {
        await self.healthGate?.wait()
        return true
    }

    func listSessions(
        limit _: Int?,
        search _: String?,
        archived _: Bool) async throws -> OpenClawChatSessionsListResponse
    {
        OpenClawChatSessionsListResponse(ts: nil, path: nil, count: 0, defaults: nil, sessions: [])
    }

    func acquireOutboxRouteLease() async -> OpenClawChatTransportRouteLeaseResult {
        let availability: AttachmentRouteLeaseAvailability = if let routeLeasePlan {
            await routeLeasePlan.next()
        } else {
            self.durableOutboxAvailable ? .available : .unsupported
        }
        switch availability {
        case .indeterminate:
            return .unavailable(reason: nil)
        case .unsupported:
            return .unavailable(
                reason: OpenClawChatTransportUpgradeMessage.routingContract,
                allowsLiveSend: true)
        case .available:
            break
        }
        let transport = self
        return .available(OpenClawChatTransportRouteLease(
            sendMessage: { sessionKey, message, thinking, idempotencyKey, attachments in
                try await transport.sendMessage(
                    sessionKey: sessionKey,
                    message: message,
                    thinking: thinking,
                    idempotencyKey: idempotencyKey,
                    attachments: attachments)
            },
            requestHistory: { sessionKey in
                try await transport.requestHistory(sessionKey: sessionKey)
            }))
    }

    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { _ in }
    }
}



private func makeChatAttachmentJPEG(width: Int, height: Int) throws -> Data {
    guard
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
        throw NSError(domain: "ChatViewModelAttachmentTests", code: 3)
    }

    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))

    guard let image = context.makeImage() else {
        throw NSError(domain: "ChatViewModelAttachmentTests", code: 4)
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw NSError(domain: "ChatViewModelAttachmentTests", code: 5)
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "ChatViewModelAttachmentTests", code: 6)
    }
    return data as Data
}

private func chatAttachmentDimensions(for data: Data) -> (width: Int, height: Int)? {
    guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
        let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
        return nil
    }
    return (width.intValue, height.intValue)
}

struct ChatViewModelAttachmentTests {
    @Test func imageAttachmentsAreProcessedBeforeStaging() async throws {
        let imageData = try makeChatAttachmentJPEG(width: 3000, height: 4000)
        let viewModel = await MainActor.run {
            OpenClawChatViewModel(sessionKey: "main", transport: AttachmentProcessingTransport())
        }

        await MainActor.run {
            viewModel.addImageAttachment(data: imageData, fileName: "camera.heic", mimeType: "image/jpeg")
        }

        try await waitUntil("attachment processed") {
            await MainActor.run { !viewModel.attachments.isEmpty || viewModel.errorText != nil }
        }

        let attachment = try await MainActor.run {
            guard let attachment = viewModel.attachments.first else {
                throw NSError(domain: "ChatViewModelAttachmentTests", code: 7)
            }
            return (attachment.fileName, attachment.mimeType, attachment.data)
        }
        let dimensions = try #require(chatAttachmentDimensions(for: attachment.2))

        #expect(attachment.0 == "camera.jpg")
        #expect(attachment.1 == "image/jpeg")
        #expect(attachment.2.count <= ChatImageProcessor.maxPayloadBytes)
        #expect(max(dimensions.width, dimensions.height) <= ChatImageProcessor.maxLongEdgePx)
        let errorText = await MainActor.run { viewModel.errorText }
        #expect(errorText == nil)
    }

    @Test func videoFileStagesWithoutTranscodeAndSendsOriginalPayloadMetadata() async throws {
        let capture = AttachmentSendCapture()
        let data = Data("fixture-video-container".utf8)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-video-\(UUID().uuidString).mp4")
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let viewModel = await MainActor.run {
            OpenClawChatViewModel(
                sessionKey: "main",
                transport: AttachmentProcessingTransport(capture: capture))
        }

        await MainActor.run { viewModel.addAttachments(urls: [fileURL]) }
        try await waitUntil("video attachment staged") {
            await MainActor.run { !viewModel.attachments.isEmpty || viewModel.errorText != nil }
        }

        let staged = try await MainActor.run { () throws -> (Data, String, String) in
            let attachment = try #require(viewModel.attachments.first)
            return (attachment.data, attachment.fileName, attachment.mimeType)
        }
        #expect(staged.0 == data)
        #expect(staged.1 == fileURL.lastPathComponent)
        #expect(staged.2 == "video/mp4")

        await MainActor.run { viewModel.send() }
        try await waitUntil("video attachment sent") {
            await capture.count() == 1
        }
        let capturedPayload = await capture.first()
        let payload = try #require(capturedPayload)
        #expect(payload.type == "file")
        #expect(payload.fileName == fileURL.lastPathComponent)
        #expect(payload.mimeType == "video/mp4")
        #expect(payload.content == data.base64EncodedString())
    }

    @Test func videoFileUsesServerDefaultTwentyMiBCap() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-video-oversize-\(UUID().uuidString).mp4")
        try Data(count: OpenClawChatViewModel.maxVideoAttachmentBytes + 1).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let viewModel = await MainActor.run {
            OpenClawChatViewModel(sessionKey: "main", transport: AttachmentProcessingTransport())
        }

        await MainActor.run { viewModel.addAttachments(urls: [fileURL]) }
        try await waitUntil("oversize video rejected") {
            await MainActor.run { viewModel.errorText != nil }
        }

        let state = await MainActor.run { (viewModel.attachments.isEmpty, viewModel.errorText) }
        #expect(state.0)
        #expect(state.1 == "Attachment \(fileURL.lastPathComponent) exceeds the 20 MB video limit")
    }

    @Test func unsupportedAudioFileIsRejectedBeforeReadingItsPayload() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-audio-oversize-\(UUID().uuidString).mp3")
        #expect(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: UInt64(OpenClawChatViewModel.maxVideoAttachmentBytes * 10))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let viewModel = await MainActor.run {
            OpenClawChatViewModel(sessionKey: "main", transport: AttachmentProcessingTransport())
        }

        await MainActor.run { viewModel.addAttachments(urls: [fileURL]) }
        try await waitUntil("unsupported audio rejected") {
            await MainActor.run { viewModel.errorText != nil }
        }

        let state = await MainActor.run { (viewModel.attachments.isEmpty, viewModel.errorText) }
        #expect(state.0)
        #expect(state.1 == "Only image and video attachments are supported right now")
    }

    @Test func voiceNoteAttachmentStagesAudioAndDeletesTemporaryFile() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-20260706-120000.m4a")
        let data = Data("voice-note-data".utf8)
        try data.write(to: fileURL)
        let viewModel = await MainActor.run {
            OpenClawChatViewModel(sessionKey: "main", transport: AttachmentProcessingTransport())
        }

        await viewModel.addVoiceNoteAttachment(fileURL: fileURL, durationSeconds: 8.4)

        let attachment = try await MainActor.run { () throws -> (Data, String, String, String, Double?, Bool) in
            let attachment = try #require(viewModel.attachments.first)
            return (
                attachment.data,
                attachment.fileName,
                attachment.mimeType,
                attachment.type,
                attachment.durationSeconds,
                attachment.preview == nil)
        }
        #expect(attachment.0 == data)
        #expect(attachment.1 == "voice-note-20260706-120000.m4a")
        #expect(attachment.2 == "audio/mp4")
        #expect(attachment.3 == "file")
        #expect(attachment.4 == 8.4)
        #expect(attachment.5)
        #expect(!(FileManager.default.fileExists(atPath: fileURL.path)))
    }

    @Test func oversizeVoiceNoteIsRejectedAndDeleted() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-oversize.m4a")
        try Data(repeating: 0x41, count: 5_000_001).write(to: fileURL)
        let viewModel = await MainActor.run {
            OpenClawChatViewModel(sessionKey: "main", transport: AttachmentProcessingTransport())
        }

        await viewModel.addVoiceNoteAttachment(fileURL: fileURL, durationSeconds: 180)

        let result = await MainActor.run { (viewModel.attachments.count, viewModel.errorText) }
        #expect(result.0 == 0)
        #expect(result.1 == "Voice note exceeds the 5 MB attachment limit")
        #expect(!(FileManager.default.fileExists(atPath: fileURL.path)))
    }

    @Test func malformedVoiceNoteDurationIsNormalized() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-malformed-duration.m4a")
        try Data("voice-note".utf8).write(to: fileURL)
        let viewModel = await MainActor.run {
            OpenClawChatViewModel(sessionKey: "main", transport: AttachmentProcessingTransport())
        }

        await viewModel.addVoiceNoteAttachment(fileURL: fileURL, durationSeconds: .infinity)

        let duration = await MainActor.run { viewModel.attachments.first?.durationSeconds }
        #expect(duration == 0)
    }

    @Test func partialIdentitySyncPreservesTheOtherDeferredComponent() async {
        let state = await MainActor.run {
            let oldContract = "per-sender|main|main"
            let newContract = "per-sender|work-main|main"
            let contractViewModel = OpenClawChatViewModel(
                sessionKey: "main",
                transport: AttachmentProcessingTransport(),
                activeAgentId: "main",
                sessionRoutingContract: oldContract)
            let contractAttachment = OpenClawPendingAttachment(
                url: nil,
                data: Data("contract".utf8),
                fileName: "contract.m4a",
                mimeType: "audio/mp4",
                preview: nil)
            contractViewModel.attachments = [contractAttachment]

            contractViewModel.syncSessionRoutingContract(newContract)
            contractViewModel.syncActiveAgentId("main")
            contractViewModel.removeAttachment(contractAttachment.id)

            let agentViewModel = OpenClawChatViewModel(
                sessionKey: "main",
                transport: AttachmentProcessingTransport(),
                activeAgentId: "main",
                sessionRoutingContract: oldContract)
            let agentAttachment = OpenClawPendingAttachment(
                url: nil,
                data: Data("agent".utf8),
                fileName: "agent.m4a",
                mimeType: "audio/mp4",
                preview: nil)
            agentViewModel.attachments = [agentAttachment]

            agentViewModel.syncActiveAgentId("work")
            agentViewModel.syncSessionRoutingContract(oldContract)
            agentViewModel.removeAttachment(agentAttachment.id)

            return (
                contractAgentID: contractViewModel.activeAgentId,
                contract: contractViewModel.sessionRoutingContract,
                agentID: agentViewModel.activeAgentId,
                agentContract: agentViewModel.sessionRoutingContract)
        }

        #expect(state.contractAgentID == "main")
        #expect(state.contract == "per-sender|work-main|main")
        #expect(state.agentID == "work")
        #expect(state.agentContract == "per-sender|main|main")
    }

    @Test func attachmentStagingPinsSessionAndIdentityUntilItFinishes() async {
        let state = await MainActor.run {
            let viewModel = OpenClawChatViewModel(
                sessionKey: "main",
                transport: AttachmentProcessingTransport(),
                activeAgentId: "main",
                sessionRoutingContract: "per-sender|main|main")

            viewModel.beginAttachmentStaging()
            viewModel.syncSession(to: "agent:work:main")
            viewModel.syncDeliveryIdentity(
                activeAgentId: "work",
                sessionRoutingContract: "per-sender|main|work")

            let pinned = (
                isPinned: viewModel.isAttachmentOwnerPinned,
                sessionKey: viewModel.sessionKey,
                agentID: viewModel.activeAgentId,
                contract: viewModel.sessionRoutingContract)

            viewModel.endAttachmentStaging()

            let released = (
                isPinned: viewModel.isAttachmentOwnerPinned,
                sessionKey: viewModel.sessionKey,
                agentID: viewModel.activeAgentId,
                contract: viewModel.sessionRoutingContract)
            return (pinned: pinned, released: released)
        }

        #expect(state.pinned.isPinned)
        #expect(state.pinned.sessionKey == "main")
        #expect(state.pinned.agentID == "main")
        #expect(state.pinned.contract == "per-sender|main|main")
        #expect(!state.released.isPinned)
        #expect(state.released.sessionKey == "agent:work:main")
        #expect(state.released.agentID == "work")
        #expect(state.released.contract == "per-sender|main|work")
    }

    @Test func recordingPinsSessionAndIdentityUntilItEnds() async {
        let state = await MainActor.run {
            let ownerActivity = AttachmentOwnerActivity()
            let viewModel = OpenClawChatViewModel(
                sessionKey: "main",
                transport: AttachmentProcessingTransport(),
                activeAgentId: "main",
                sessionRoutingContract: "per-sender|main|main",
                attachmentOwnerIsActive: { ownerActivity.isActive })

            viewModel.syncSession(to: "agent:work:main")
            viewModel.syncDeliveryIdentity(
                activeAgentId: "work",
                sessionRoutingContract: "per-sender|main|work")

            let pinned = (
                isPinned: viewModel.isAttachmentOwnerPinned,
                sessionKey: viewModel.sessionKey,
                agentID: viewModel.activeAgentId,
                contract: viewModel.sessionRoutingContract)

            ownerActivity.isActive = false
            viewModel.attachmentOwnerActivityChanged()

            let released = (
                isPinned: viewModel.isAttachmentOwnerPinned,
                sessionKey: viewModel.sessionKey,
                agentID: viewModel.activeAgentId,
                contract: viewModel.sessionRoutingContract)
            return (pinned: pinned, released: released)
        }

        #expect(state.pinned.isPinned)
        #expect(state.pinned.sessionKey == "main")
        #expect(state.pinned.agentID == "main")
        #expect(state.pinned.contract == "per-sender|main|main")
        #expect(!state.released.isPinned)
        #expect(state.released.sessionKey == "agent:work:main")
        #expect(state.released.agentID == "work")
        #expect(state.released.contract == "per-sender|main|work")
    }

    @Test func attachmentSendWithoutOutboxUsesLiveTransport() async throws {
        let capture = AttachmentSendCapture()
        let viewModel = await MainActor.run {
            let viewModel = OpenClawChatViewModel(
                sessionKey: "main",
                transport: AttachmentProcessingTransport(capture: capture))
            viewModel.attachments = [
                OpenClawPendingAttachment(
                    url: nil,
                    data: Data("fixture-voice-note".utf8),
                    fileName: "fixture.m4a",
                    mimeType: "audio/mp4",
                    preview: nil,
                    durationSeconds: 4),
            ]
            return viewModel
        }

        await MainActor.run { viewModel.send() }
        try await waitUntil("live attachment sent without outbox") {
            await capture.count() == 1
        }

        let capturedPayload = await capture.first()
        let payload = try #require(capturedPayload)
        #expect(payload.content == Data("fixture-voice-note".utf8).base64EncodedString())
        let state = await MainActor.run {
            (
                viewModel.attachments.isEmpty,
                viewModel.errorText,
                viewModel.messages.last?.content.first { $0.mimeType == "audio/mp4" }?.durationSeconds)
        }
        #expect(state.0)
        #expect(state.1 == nil)
        #expect(state.2 == 4)
    }




    @Test func failedAttachmentSendWithoutOutboxRestoresDraft() async throws {
        let capture = AttachmentSendCapture()
        let attachmentData = Data("retry-voice-note".utf8)
        let viewModel = await MainActor.run {
            OpenClawChatViewModel(
                sessionKey: "main",
                transport: AttachmentProcessingTransport(
                    capture: capture,
                    failsAmbiguously: true))
        }
        let attachmentID = await MainActor.run {
            let attachment = OpenClawPendingAttachment(
                url: nil,
                data: attachmentData,
                fileName: "retry.m4a",
                mimeType: "audio/mp4",
                preview: nil,
                durationSeconds: 5)
            viewModel.input = "retry caption"
            viewModel.attachments = [attachment]
            return attachment.id
        }

        await MainActor.run { viewModel.send() }
        try await waitUntil("failed live attachment restores draft") {
            await MainActor.run { viewModel.errorText == "Connection lost" }
        }

        let state = await MainActor.run {
            (
                viewModel.input,
                viewModel.attachments.map(\.id),
                viewModel.attachments.first?.data,
                viewModel.messages.contains { $0.idempotencyKey?.hasSuffix(":user") == true })
        }
        #expect(state.0 == "retry caption")
        #expect(state.1 == [attachmentID])
        #expect(state.2 == attachmentData)
        #expect(!state.3)
    }


    @Test func voiceNoteSendKeepsCapturedDurationWhenDraftChangesDuringHealthCheck() async throws {
        let capture = AttachmentSendCapture()
        let healthGate = AttachmentHealthGate()
        let transport = AttachmentProcessingTransport(capture: capture, healthGate: healthGate)
        let (viewModel, draftAttachmentID) = await MainActor.run {
            let viewModel = OpenClawChatViewModel(sessionKey: "main", transport: transport)
            let draftAttachment = OpenClawPendingAttachment(
                url: nil,
                data: Data("draft-audio".utf8),
                fileName: "draft.m4a",
                mimeType: "audio/mp4",
                preview: nil,
                durationSeconds: 21.2)
            viewModel.attachments = [draftAttachment]
            return (viewModel, draftAttachment.id)
        }

        await MainActor.run { viewModel.send() }
        try await waitUntil("health check started") {
            await healthGate.hasEntered()
        }
        await MainActor.run {
            viewModel.removeAttachment(draftAttachmentID)
            viewModel.attachments.append(
                OpenClawPendingAttachment(
                    url: nil,
                    data: Data("replacement-audio".utf8),
                    fileName: "replacement.m4a",
                    mimeType: "audio/mp4",
                    preview: nil,
                    durationSeconds: 99))
        }
        await healthGate.release()
        try await waitUntil("voice note sent") {
            await capture.count() == 1
        }

        let optimisticAudio = await MainActor.run {
            viewModel.messages.last?.content.first { $0.mimeType == "audio/mp4" }
        }
        #expect(optimisticAudio?.fileName == "draft.m4a")
        #expect(optimisticAudio?.durationSeconds == 21.2)
    }



    @MainActor
    @Test func canonicalVoiceNotePreservesOptimisticDuration() throws {
        let localAudio = OpenClawChatMessageContent(
            type: "file",
            text: nil,
            mimeType: "audio/mp4",
            fileName: "voice-note-local.m4a",
            durationSeconds: 14.6,
            content: AnyCodable("local"))
        let existing = OpenClawChatMessage(
            role: "user",
            content: [localAudio],
            timestamp: nil,
            idempotencyKey: "run:user")
        let incoming = try JSONDecoder().decode(
            OpenClawChatMessage.self,
            from: Data(
                (#"{"role":"user","content":"See attached.","__openclaw":{"idempotencyKey":"run:user"},"#
                    + #""MediaPaths":["media/inbound/media-1.m4a"],"MediaTypes":["audio/mp4"]}"#)
                    .utf8))

        let adopted = OpenClawChatViewModel.adoptingCanonicalMessage(incoming, over: existing)

        let audio = try #require(adopted.content.first { $0.mimeType == "audio/mp4" })
        #expect(audio.fileName == "media-1.m4a")
        #expect(audio.content == nil)
        #expect(audio.durationSeconds == 14.6)
    }
}
