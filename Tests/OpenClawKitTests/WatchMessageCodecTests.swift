import Foundation
import Testing
@testable import OpenClawKit

struct WatchMessageCodecTests {
    private static let context = OpenClawWatchChatDeliveryContext(
        gatewayStableID: "gateway",
        routeGeneration: "generation",
        agentId: "main",
        sessionKey: "global",
        deliverySessionKey: "global",
        sessionRoutingContract: "agent-scoped-v1")

    @Test func `notify messages use the flat wire shape and default to active priority`() throws {
        let message = OpenClawWatchNotifyMessage(
            id: "invoke-1",
            params: OpenClawWatchNotifyParams(
                title: "Build finished",
                body: "All green",
                promptId: "prompt-1",
                expiresAtMs: Int64(1_900_000_000_000),
                actions: [OpenClawWatchAction(id: "done", label: "Done")]),
            sentAtMs: Int64(1_800_000_000_000),
            chatDeliveryContext: Self.context)
        let payload = try OpenClawWatchMessageCodec.encode(.notify(message))
        #expect(payload["type"] as? String == "watch.notify")
        #expect(payload["id"] as? String == "invoke-1")
        #expect(payload["title"] as? String == "Build finished")
        #expect(payload["priority"] as? String == "active")
        #expect((payload["sentAtMs"] as? NSNumber)?.int64Value == Int64(1_800_000_000_000))
        #expect((payload["expiresAtMs"] as? NSNumber)?.int64Value == Int64(1_900_000_000_000))
        #expect(payload["params"] == nil)
        #expect(PropertyListSerialization.propertyList(payload, isValidFor: .binary))
        let context = try #require(payload["chatDeliveryContext"] as? [String: Any])
        #expect(try OpenClawWatchChatDeliveryCodec.decodeContext(context) == Self.context)

        guard case let .notify(decoded) = try OpenClawWatchMessageCodec.decode(payload) else {
            Issue.record("expected a notify message")
            return
        }
        #expect(decoded.id == "invoke-1")
        #expect(decoded.params.priority == .active)
        #expect(decoded.params.promptId == "prompt-1")
        #expect(decoded.chatDeliveryContext == Self.context)
    }

    @Test func `app snapshots write the upstream avatar key and read either spelling`() throws {
        let snapshot = OpenClawWatchAppSnapshotMessage(
            gatewayStatusText: "Connected",
            gatewayConnected: true,
            agentName: "Claw",
            agentAvatarURL: "https://example.com/a.png",
            sessionKey: "main",
            talkStatusText: "Off",
            talkEnabled: false,
            talkListening: false,
            talkSpeaking: false,
            pendingApprovalCount: 1,
            chatItems: [OpenClawWatchChatItem(id: "m1", role: "assistant", text: "Hi", timestampMs: 5)],
            chatDeliveryContext: Self.context)
        let payload = try OpenClawWatchMessageCodec.encode(.appSnapshot(snapshot))
        #expect(payload["agentAvatarUrl"] as? String == "https://example.com/a.png")
        #expect(payload["agentAvatarURL"] == nil)
        #expect(try OpenClawWatchMessageCodec.decode(payload) == .appSnapshot(snapshot))

        var codableSpelling = payload
        codableSpelling["agentAvatarURL"] = codableSpelling.removeValue(forKey: "agentAvatarUrl")
        guard case let .appSnapshot(decoded) = try OpenClawWatchMessageCodec.decode(codableSpelling) else {
            Issue.record("expected an app snapshot")
            return
        }
        #expect(decoded.agentAvatarURL == "https://example.com/a.png")
    }

    @Test func `shipped snapshot requests without held approvals decode as empty`() throws {
        let payload: [String: Any] = [
            "type": "watch.execApproval.snapshotRequest",
            "requestId": "request-1",
            "sentAtMs": NSNumber(value: Int64(1_800_000_000_000)),
        ]
        let decoded = try OpenClawWatchMessageCodec.decode(payload)
        #expect(decoded == .execApprovalSnapshotRequest(OpenClawWatchExecApprovalSnapshotRequestMessage(
            requestId: "request-1",
            sentAtMs: Int64(1_800_000_000_000))))
    }

    @Test func `every message kind round trips and unknown types are ignored`() throws {
        let command = OpenClawWatchChatDeliveryCommand(
            context: Self.context, commandId: "command", submittedAtMs: 1000, body: .chat(text: "Hello"))
        let item = OpenClawWatchExecApprovalItem(id: "approval", commandText: "ls", allowedDecisions: [.deny])
        let messages: [OpenClawWatchMessage] = [
            .directNodeSetup(OpenClawWatchNodeSetupMessage(setupCode: "code", sentAtMs: 10)),
            .appSnapshotRequest(OpenClawWatchAppSnapshotRequestMessage(requestId: "r")),
            .appCommand(OpenClawWatchAppCommandMessage(command: .startTalk, commandId: "c", sessionKey: "main")),
            .chatCompletion(OpenClawWatchChatCompletionMessage(commandId: "c", replyText: "Done")),
            .chatDeliveryCommand(command),
            .chatDeliveryReceipt(OpenClawWatchChatDeliveryReceipt(
                context: Self.context, commandId: "command", state: .admitted(atMs: 1001))),
            .chatDeliveryReceiptAck(OpenClawWatchChatDeliveryReceiptAck(
                context: Self.context, commandId: "command", receiptId: "receipt")),
            .execApprovalPrompt(OpenClawWatchExecApprovalPromptMessage(approval: item)),
            .execApprovalResolve(OpenClawWatchExecApprovalResolveMessage(
                approvalId: "approval", decision: .allowOnce, replyId: "reply")),
            .execApprovalResolved(OpenClawWatchExecApprovalResolvedMessage(approvalId: "approval", outcome: .denied)),
            .execApprovalExpired(OpenClawWatchExecApprovalExpiredMessage(approvalId: "approval", reason: .replaced)),
            .execApprovalSnapshot(OpenClawWatchExecApprovalSnapshotMessage(approvals: [item], snapshotId: "s")),
            .execApprovalSnapshotRequest(OpenClawWatchExecApprovalSnapshotRequestMessage(
                requestId: "r",
                heldApprovals: [.init(approvalId: "approval", activeResolutionAttemptId: "attempt")])),
            .legacyReply,
        ]
        for message in messages {
            let payload = try OpenClawWatchMessageCodec.encode(message)
            #expect(payload["type"] as? String == message.type.rawValue)
            #expect(try OpenClawWatchMessageCodec.decode(payload) == message)
        }
        #expect(try OpenClawWatchMessageCodec.decode(["type": "watch.future"]) == nil)
        #expect(try OpenClawWatchMessageCodec.decode(["title": "no type"]) == nil)
        #expect(throws: OpenClawWatchMessageCodecError.self) {
            try OpenClawWatchMessageCodec.decode(["type": "watch.app.command", "command": "dance", "commandId": "c"])
        }
        var tampered = try OpenClawWatchMessageCodec.encode(.chatDeliveryCommand(command))
        tampered["transport"] = "sendMessage"
        #expect(throws: OpenClawWatchChatDeliveryError.self) {
            try OpenClawWatchMessageCodec.decode(tampered)
        }
    }

    @Test func `application context nests both durable snapshots`() throws {
        let appPayload = try OpenClawWatchMessageCodec.encode(.appSnapshot(OpenClawWatchAppSnapshotMessage(
            gatewayStatusText: "Connected",
            gatewayConnected: true,
            agentName: "Main",
            sessionKey: "main",
            talkStatusText: "Off",
            talkEnabled: false,
            talkListening: false,
            talkSpeaking: false,
            pendingApprovalCount: 0)))
        let approvals = OpenClawWatchExecApprovalSnapshotMessage(approvals: [], snapshotId: "approvals-1")
        let approvalPayload = try OpenClawWatchMessageCodec.encode(.execApprovalSnapshot(approvals))

        let first = OpenClawWatchMessageCodec.applicationContext(for: appPayload, merging: [:])
        let merged = OpenClawWatchMessageCodec.applicationContext(for: approvalPayload, merging: first)
        #expect(merged["type"] as? String == "watch.execApproval.snapshot")
        #expect(merged["watch.app.snapshot"] != nil)
        #expect(merged["watch.execApproval.snapshot"] != nil)
        let extracted = OpenClawWatchMessageCodec.snapshots(fromApplicationContext: merged)
        #expect(extracted.app?.agentName == "Main")
        #expect(extracted.execApprovals == approvals)

        // A legacy top-level context still yields its snapshot.
        let legacy = OpenClawWatchMessageCodec.snapshots(fromApplicationContext: appPayload)
        #expect(legacy.app?.gatewayConnected == true)
        #expect(legacy.execApprovals == nil)
        let passthrough: [String: Any] = ["type": "watch.notify", "title": "t", "body": "b"]
        #expect(OpenClawWatchMessageCodec.applicationContext(for: passthrough, merging: merged).count == 3)
    }

    @Test func `notify normalization trims derives risk and inserts prompt actions`() {
        let approval = OpenClawWatchNotifyParams(
            title: "  Approve deploy  ",
            body: " prod ",
            priority: nil,
            promptId: " prompt ",
            sessionKey: "  ",
            kind: "exec-approval",
            risk: .high).normalized()
        #expect(approval.title == "Approve deploy")
        #expect(approval.body == "prod")
        #expect(approval.promptId == "prompt")
        #expect(approval.sessionKey == nil)
        #expect(approval.priority == .timeSensitive)
        #expect(approval.risk == .high)
        #expect(approval.actions?.map(\.id) == ["approve", "decline", "open_phone", "escalate"])

        let prompt = OpenClawWatchNotifyParams(title: "Reminder", body: "", priority: .passive, promptId: "p")
            .normalized()
        #expect(prompt.risk == .low)
        #expect(prompt.actions?.map(\.id) == ["done", "snooze_10m", "open_phone", "escalate"])

        let informational = OpenClawWatchNotifyParams(title: "FYI", body: "").normalized()
        #expect(informational.actions == nil)
        #expect(informational.priority == nil && informational.risk == nil)

        let custom = OpenClawWatchNotifyParams(
            title: "Pick",
            body: "",
            promptId: "p",
            actions: (1...6).map { OpenClawWatchAction(id: " a\($0) ", label: "L\($0)", style: " ") }
                + [OpenClawWatchAction(id: "", label: "blank")]).normalized()
        #expect(custom.actions?.map(\.id) == ["a1", "a2", "a3", "a4"])
        #expect(custom.actions?.first?.style == nil)
    }

    @Test func `watch unavailable errors carry the stable prefix`() {
        let status = OpenClawWatchStatusPayload(
            supported: true, paired: true, appInstalled: false, reachable: false, activationState: "activated")
        let reason = OpenClawWatchUnavailableReason.blocking(status)
        #expect(reason == .watchAppNotInstalled)
        #expect(reason?.nodeError.code == .unavailable)
        #expect(reason?.message == "WATCH_UNAVAILABLE: OpenClaw watch companion app is not installed")
        #expect(OpenClawWatchUnavailableReason.activationFailed("denied").message.hasPrefix("WATCH_UNAVAILABLE:"))
        #expect(OpenClawWatchUnavailableReason.blocking(OpenClawWatchStatusPayload(
            supported: true, paired: true, appInstalled: true, reachable: false, activationState: "activated")) == nil)
    }

    @Test func `standalone watch talk stays metadata only`() {
        #expect(OpenClawWatchTalkSupport.gatewayControlCapability == "gateway-control-v1")
        #expect(OpenClawWatchTalkSupport.voiceScopes == ["operator.read", "operator.talk"])
        #expect(!OpenClawWatchTalkSupport.supportedTransports.contains(.watchStandalone))
        #expect(OpenClawWatchTalkSupport.supportedTransports == [.iPhoneRelay, .dictationTurn])
    }
}
