import CoreGraphics
import Foundation
import ImageIO
import OpenClawKit
import UniformTypeIdentifiers
import Testing
@testable import OpenClawChatStore
@testable import OpenClawChatUI

// Ported from upstream OpenClaw 2026.9.6 (XCTest converted to Swift Testing), including the durable-outbox
// cases backed by the GRDB OpenClawChatStore (`OpenClawChatSQLiteTranscriptCache`).

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



private func makeAttachmentOutbox() throws -> OpenClawChatSQLiteTranscriptCache {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("attachment-outbox-\(UUID().uuidString)", isDirectory: true)
    return try OpenClawClientDatabases(directoryURL: directory).store(gatewayID: "attachment-tests")
}

@MainActor
private func makeDurableAttachmentViewModel(
    transport: AttachmentProcessingTransport,
    outbox: OpenClawChatSQLiteTranscriptCache) -> OpenClawChatViewModel
{
    OpenClawChatViewModel(
        sessionKey: "main",
        transport: transport,
        transcriptCache: outbox,
        outbox: outbox)
}

/// A file URL with `name` inside a fresh per-test directory. Parallel test processes (other
/// checkouts) share the user temp directory, so fixed names there race each other.
private func uniqueVoiceNoteURL(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voice-note-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(name)
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
        let fileURL = try uniqueVoiceNoteURL("voice-note-20260706-120000.m4a")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
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
        let fileURL = try uniqueVoiceNoteURL("voice-note-oversize.m4a")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
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
        let fileURL = try uniqueVoiceNoteURL("voice-note-malformed-duration.m4a")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
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

    @Test func healthyLegacyGatewayUsesLiveAttachmentPath() async throws {
        let capture = AttachmentSendCapture()
        let outbox = try makeAttachmentOutbox()
        let viewModel = await MainActor.run {
            makeDurableAttachmentViewModel(
                transport: AttachmentProcessingTransport(
                    capture: capture,
                    returnsEmptyHistory: true,
                    durableOutboxAvailable: false),
                outbox: outbox)
        }
        await MainActor.run { viewModel.load() }
        // Wait for outbox restore too: until it completes, sends deliberately
        // route behind the outbox (FIFO gate), which is not the path under test.
        try await waitUntil("legacy gateway bootstrap completed") {
            await MainActor.run {
                viewModel.healthOK && !viewModel.isLoading && viewModel.hasRestoredOutboxMessages
            }
        }
        await MainActor.run {
            viewModel.attachments = [
                OpenClawPendingAttachment(
                    url: nil,
                    data: Data("legacy-voice-note".utf8),
                    fileName: "legacy.m4a",
                    mimeType: "audio/mp4",
                    preview: nil,
                    durationSeconds: 3),
            ]
            viewModel.send()
        }
        try await waitUntil("legacy attachment sent live") {
            await capture.count() == 1
        }

        let commands = await outbox.loadCommands()
        #expect(commands.isEmpty)
    }

    @Test func indeterminateOutboxRouteRetainsAttachmentAndRetriesOnceAvailable() async throws {
        let capture = AttachmentSendCapture()
        let routeLeasePlan = AttachmentRouteLeasePlan([
            .indeterminate,
            .available,
            .available,
        ])
        let outbox = try makeAttachmentOutbox()
        let attachmentData = Data("retry-image".utf8)
        let viewModel = await MainActor.run {
            makeDurableAttachmentViewModel(
                transport: AttachmentProcessingTransport(
                    capture: capture,
                    returnsEmptyHistory: true,
                    routeLeasePlan: routeLeasePlan),
                outbox: outbox)
        }
        await MainActor.run { viewModel.load() }
        try await waitUntil("attachment outbox bootstrap completed") {
            await MainActor.run {
                viewModel.healthOK && !viewModel.isLoading && viewModel.hasRestoredOutboxMessages
            }
        }
        let attachmentID = await MainActor.run {
            let attachment = OpenClawPendingAttachment(
                url: nil,
                data: attachmentData,
                fileName: "retry.jpg",
                mimeType: "image/jpeg",
                preview: nil)
            viewModel.input = "retry caption"
            viewModel.attachments = [attachment]
            viewModel.send()
            return attachment.id
        }

        let routeError =
            "Could not verify this attachment's delivery route. Reconnect, then try again."
        try await waitUntil("indeterminate attachment route is visible") {
            await MainActor.run { viewModel.errorText == routeError }
        }
        let retainedState = await MainActor.run {
            (viewModel.input, viewModel.attachments.map(\.id))
        }
        #expect(retainedState.0 == "retry caption")
        #expect(retainedState.1 == [attachmentID])
        let retainedCommands = await outbox.loadCommands()
        let initialSendCount = await capture.sendCount()
        #expect(retainedCommands.isEmpty)
        #expect(initialSendCount == 0)

        await MainActor.run { viewModel.send() }
        try await waitUntil("attachment retry sent") {
            await capture.sendCount() == 1
        }
        try await Task.sleep(for: .milliseconds(100))

        let capturedPayload = await capture.first()
        let payload = try #require(capturedPayload)
        #expect(payload.fileName == "retry.jpg")
        #expect(payload.mimeType == "image/jpeg")
        #expect(payload.content == attachmentData.base64EncodedString())
        let finalSendCount = await capture.sendCount()
        #expect(finalSendCount == 1)
        let sentState = await MainActor.run {
            (viewModel.input, viewModel.attachments.isEmpty, viewModel.errorText)
        }
        #expect(sentState.0 == "")
        #expect(sentState.1)
        #expect(sentState.2 == nil)
    }

    @Test func legacyGatewayRetainsAttachmentUntilOutboxRestoreCompletes() async throws {
        let capture = AttachmentSendCapture()
        let outbox = try makeAttachmentOutbox()
        let viewModel = await MainActor.run {
            let viewModel = makeDurableAttachmentViewModel(
                transport: AttachmentProcessingTransport(
                    capture: capture,
                    durableOutboxAvailable: false),
                outbox: outbox)
            viewModel.attachments = [
                OpenClawPendingAttachment(
                    url: nil,
                    data: Data("restore-race".utf8),
                    fileName: "restore-race.m4a",
                    mimeType: "audio/mp4",
                    preview: nil,
                    durationSeconds: 2),
            ]
            return viewModel
        }

        await MainActor.run { viewModel.send() }
        try await waitUntil("legacy draft held during restore") {
            await MainActor.run { viewModel.errorText?.contains("Restoring queued messages") == true }
        }

        let state = await MainActor.run { (viewModel.attachments.count, viewModel.input) }
        let sendCount = await capture.count()
        let commands = await outbox.loadCommands()
        #expect(state.0 == 1)
        #expect(state.1 == "")
        #expect(sendCount == 0)
        #expect(commands.isEmpty)
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

    @Test func voiceNoteSendUsesExistingAttachmentPayloadAndOptimisticDuration() async throws {
        let capture = AttachmentSendCapture()
        let transport = AttachmentProcessingTransport(capture: capture)
        let fileURL = try uniqueVoiceNoteURL("voice-note-20260706-120001.m4a")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let data = Data("encoded-voice-note".utf8)
        try data.write(to: fileURL)
        let outbox = try makeAttachmentOutbox()
        let viewModel = await MainActor.run {
            makeDurableAttachmentViewModel(transport: transport, outbox: outbox)
        }

        await viewModel.addVoiceNoteAttachment(fileURL: fileURL, durationSeconds: 21.2)
        await MainActor.run { viewModel.send() }
        try await waitUntil("voice note sent") {
            await capture.count() == 1
        }

        let capturedPayload = await capture.first()
        let payload = try #require(capturedPayload)
        #expect(payload.type == "file")
        #expect(payload.mimeType == "audio/mp4")
        #expect(payload.fileName == "voice-note-20260706-120001.m4a")
        #expect(payload.content == data.base64EncodedString())

        let optimisticAudio = await MainActor.run {
            viewModel.messages.last?.content.first { $0.mimeType == "audio/mp4" }
        }
        #expect(optimisticAudio?.type == "file")
        #expect(optimisticAudio?.mimeType == "audio/mp4")
        #expect(optimisticAudio?.durationSeconds == 21.2)
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

    @Test func ambiguousVoiceNoteSurvivesViewModelRecreation() async throws {
        let outbox = try makeAttachmentOutbox()
        var firstViewModel: OpenClawChatViewModel? = await MainActor.run {
            let viewModel = makeDurableAttachmentViewModel(
                transport: AttachmentProcessingTransport(failsAmbiguously: true),
                outbox: outbox)
            viewModel.attachments = [
                OpenClawPendingAttachment(
                    url: nil,
                    data: Data("durable-voice-note".utf8),
                    fileName: "durable.m4a",
                    mimeType: "audio/mp4",
                    preview: nil,
                    durationSeconds: 42),
            ]
            return viewModel
        }

        await MainActor.run { firstViewModel?.send() }
        try await waitUntil("ambiguous voice note is durably parked") {
            let command = await outbox.loadCommands().first
            return command?.status == .failed &&
                command?.lastError == OpenClawChatSQLiteTranscriptCache.outboxUnconfirmedError
        }
        let persistedCommands = await outbox.loadCommands()
        let persisted = try #require(persistedCommands.first)
        #expect(persisted.attachments.first?.data == Data("durable-voice-note".utf8))
        #expect(persisted.attachments.first?.durationSeconds == 42)

        await MainActor.run { firstViewModel = nil }
        let restoredViewModel = await MainActor.run {
            makeDurableAttachmentViewModel(
                transport: AttachmentProcessingTransport(returnsEmptyHistory: true),
                outbox: outbox)
        }
        await MainActor.run { restoredViewModel.load() }
        try await waitUntil("durable voice note bubble is restored") {
            await MainActor.run {
                restoredViewModel.messages.contains { message in
                    message.content.contains { $0.mimeType == "audio/mp4" }
                }
            }
        }

        let restored = try await MainActor.run { () throws -> (String?, Double?, Bool) in
            let message = try #require(restoredViewModel.messages.first)
            let audio = try #require(message.content.first { $0.mimeType == "audio/mp4" })
            return (
                audio.content?.stringValue,
                audio.durationSeconds,
                restoredViewModel.outboxState(for: message.id)?.isFailed == true)
        }
        #expect(restored.0 == Data("durable-voice-note".utf8).base64EncodedString())
        #expect(restored.1 == 42)
        #expect(restored.2)
    }

    @Test func canonicalVoiceNoteConfirmationPreservesDurationAndDeletesDurableBytes() async throws {
        let outbox = try makeAttachmentOutbox()
        let viewModel = await MainActor.run {
            let viewModel = makeDurableAttachmentViewModel(
                transport: AttachmentProcessingTransport(),
                outbox: outbox)
            viewModel.attachments = [
                OpenClawPendingAttachment(
                    url: nil,
                    data: Data("confirmed-voice-note".utf8),
                    fileName: "confirmed.m4a",
                    mimeType: "audio/mp4",
                    preview: nil,
                    durationSeconds: 7),
            ]
            return viewModel
        }

        await MainActor.run { viewModel.send() }
        try await waitUntil("voice note awaits canonical confirmation") {
            await outbox.loadCommands().first?.status == .awaitingConfirmation
        }
        let awaitingCommands = await outbox.loadCommands()
        let command = try #require(awaitingCommands.first)
        let canonical = try JSONDecoder().decode(
            OpenClawChatMessage.self,
            from: Data(
                """
                {"role":"user","content":"See attached.","__openclaw":{"idempotencyKey":"\(command
                    .id):user"},"MediaPaths":["media/inbound/media-1.m4a"],"MediaTypes":["audio/mp4"]}
                """.utf8))
        await viewModel.confirmOutboxCommandsNow(in: [canonical])

        let remainingCommands = await outbox.loadCommands()
        #expect(remainingCommands.isEmpty)
        let cached = await outbox.loadTranscript(sessionKey: "main", agentID: nil)
        let cachedMessage = try #require(cached.first)
        let cachedAudio = try #require(cachedMessage.content.first { $0.mimeType == "audio/mp4" })
        #expect(cachedAudio.fileName == "media-1.m4a")
        #expect(cachedAudio.content == nil)
        #expect(cachedAudio.durationSeconds == 7)
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
