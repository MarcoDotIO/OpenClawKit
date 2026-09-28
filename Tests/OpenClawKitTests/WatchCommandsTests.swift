import Foundation
import Testing
@testable import OpenClawKit

struct WatchCommandsTests {
    @Test func `app snapshot dual writes semantic and legacy status fields`() throws {
        let message = OpenClawWatchAppSnapshotMessage(
            gatewayStatus: OpenClawWatchAppStatus(code: .gatewayConnected),
            gatewayStatusText: "Connected",
            gatewayConnected: true,
            agentName: "Main",
            sessionKey: "main",
            talkStatus: OpenClawWatchAppStatus(code: .talkOff),
            talkStatusText: "Off",
            talkEnabled: false,
            talkListening: false,
            talkSpeaking: false,
            pendingApprovalCount: 0,
            chatStatus: OpenClawWatchAppStatus(code: .chatNoMessages),
            chatStatusText: "No chat messages yet")

        let encoded = try JSONEncoder().encode(message)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["type"] as? String == "watch.app.snapshot")
        #expect(object["gatewayStatus"] != nil)
        #expect(object["gatewayStatusText"] as? String == "Connected")
        #expect(object["talkStatus"] != nil)
        #expect(object["talkStatusText"] as? String == "Off")
        #expect(object["chatStatus"] != nil)
        #expect(object["chatStatusText"] as? String == "No chat messages yet")
    }

    @Test func `shipped snapshot initializer remains available`() {
        let message = OpenClawWatchAppSnapshotMessage(
            gatewayStatusText: "Connected",
            gatewayConnected: true,
            agentName: "Main",
            sessionKey: "main",
            talkStatusText: "Off",
            talkEnabled: false,
            talkListening: false,
            talkSpeaking: false,
            pendingApprovalCount: 0)

        #expect(message.gatewayStatus.code == .gatewayConnected)
        #expect(message.talkStatus.code == .talkOff)
    }

    @Test func `semantic chat status always writes the shipped text field`() throws {
        let message = OpenClawWatchAppSnapshotMessage(
            gatewayStatus: OpenClawWatchAppStatus(code: .gatewayConnected),
            gatewayStatusText: "Connected",
            gatewayConnected: true,
            agentName: "Main",
            sessionKey: "main",
            talkStatus: OpenClawWatchAppStatus(code: .talkOff),
            talkStatusText: "Off",
            talkEnabled: false,
            talkListening: false,
            talkSpeaking: false,
            pendingApprovalCount: 0,
            chatStatus: OpenClawWatchAppStatus(code: .chatUnavailable))

        let encoded = try JSONEncoder().encode(message)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(message.chatStatusText == "Chat unavailable")
        #expect(object["chatStatusText"] as? String == "Chat unavailable")
    }

    @Test func `unknown semantic statuses fall back to legacy text`() throws {
        let json = """
        {
          "type": "watch.app.snapshot",
          "gatewayStatus": {"code": "futureGateway", "arguments": []},
          "gatewayStatusText": "Future gateway state",
          "gatewayConnected": true,
          "agentName": "Main",
          "sessionKey": "main",
          "talkStatus": {"code": "futureTalk", "arguments": []},
          "talkStatusText": "Future Talk state",
          "talkEnabled": false,
          "talkListening": false,
          "talkSpeaking": true,
          "pendingApprovalCount": 0,
          "chatStatus": {"code": "futureChat", "arguments": []},
          "chatStatusText": "Future chat state"
        }
        """

        let message = try JSONDecoder().decode(
            OpenClawWatchAppSnapshotMessage.self,
            from: Data(json.utf8))

        #expect(message.gatewayStatus == OpenClawWatchAppStatus(
            code: .legacy,
            verbatim: "Future gateway state"))
        #expect(message.talkStatus == OpenClawWatchAppStatus(
            code: .legacy,
            verbatim: "Future Talk state"))
        #expect(message.chatStatus == OpenClawWatchAppStatus(
            code: .legacy,
            verbatim: "Future chat state"))
    }

    @Test func `approval resolution dual writes semantic and legacy outcomes`() throws {
        let message = OpenClawWatchExecApprovalResolvedMessage(
            approvalId: "approval-a",
            outcome: .allowedAlways,
            source: "another-reviewer",
            outcomeText: "This approval was already set to Always Allow.")

        let encoded = try JSONEncoder().encode(message)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["outcome"] as? String == "allowedAlways")
        #expect(object["outcomeText"] as? String ==
            "This approval was already set to Always Allow.")
    }

    @Test func `statuses without arguments keep their semantic code`() throws {
        // The iPhone omits empty argument arrays on the WatchConnectivity wire.
        let json = """
        {
          "type": "watch.app.snapshot",
          "gatewayStatus": {"code": "gatewayReconnecting"},
          "gatewayStatusText": "Reconnecting…",
          "gatewayConnected": false,
          "agentName": "Main",
          "sessionKey": "main",
          "talkStatus": {"code": "talkReady", "localizationKey": "talk.ready"},
          "talkStatusText": "Ready",
          "talkEnabled": true,
          "talkListening": false,
          "talkSpeaking": false,
          "pendingApprovalCount": 2,
          "chatStatusCode": "noMessages"
        }
        """
        let message = try JSONDecoder().decode(OpenClawWatchAppSnapshotMessage.self, from: Data(json.utf8))
        #expect(message.gatewayStatus == OpenClawWatchAppStatus(code: .gatewayReconnecting))
        #expect(message.talkStatus == OpenClawWatchAppStatus(code: .talkReady, localizationKey: "talk.ready"))
        #expect(message.chatStatus == OpenClawWatchAppStatus(code: .chatNoMessages))
        #expect(message.chatStatusText == "No chat messages yet")
        #expect(message.pendingApprovalCount == 2)
    }

    @Test func `millisecond timestamps round trip as Int64`() throws {
        let expiresAtMs = Int64(1_900_000_000_123)
        let params = OpenClawWatchNotifyParams(
            title: "Deploy",
            body: "Approve?",
            gatewayStableID: "gateway-a",
            expiresAtMs: expiresAtMs,
            risk: .high,
            actions: [OpenClawWatchAction(id: "approve", label: "Approve")])
        let data = try JSONEncoder().encode(params)
        #expect(String(bytes: data, encoding: .utf8)?.contains("\"expiresAtMs\":1900000000123") == true)
        let decoded = try JSONDecoder().decode(OpenClawWatchNotifyParams.self, from: data)
        #expect(decoded == params)
        #expect(decoded.expiresAtMs == Int64(1_900_000_000_123))
        #expect(decoded.gatewayStableID == "gateway-a")
        #expect(decoded.actions?.first?.id == "approve")

        let item = OpenClawWatchExecApprovalItem(
            id: "approval",
            commandText: "rm -rf build",
            expiresAtMs: expiresAtMs,
            allowedDecisions: [.allowOnce, .deny])
        let prompt = OpenClawWatchExecApprovalPromptMessage(approval: item, sentAtMs: Int64(1_900_000_000_000))
        let promptData = try JSONEncoder().encode(prompt)
        let decodedPrompt = try JSONDecoder().decode(OpenClawWatchExecApprovalPromptMessage.self, from: promptData)
        #expect(decodedPrompt == prompt)
        #expect(decodedPrompt.type == .execApprovalPrompt)
        let object = try #require(JSONSerialization.jsonObject(with: promptData) as? [String: Any])
        let approval = try #require(object["approval"] as? [String: Any])
        #expect(approval["allowedDecisions"] as? [String] == ["allow-once", "deny"])
    }

    @Test func `payload types match the upstream companion vocabulary`() {
        let expected: [OpenClawWatchPayloadType: String] = [
            .notify: "watch.notify",
            .directNodeSetup: "watch.node.setup",
            .reply: "watch.reply",
            .appSnapshot: "watch.app.snapshot",
            .appSnapshotRequest: "watch.app.snapshotRequest",
            .appCommand: "watch.app.command",
            .chatCompletion: "watch.chat.completion",
            .chatDeliveryCommand: "watch.chat.delivery.command",
            .chatDeliveryReceipt: "watch.chat.delivery.receipt",
            .chatDeliveryReceiptAck: "watch.chat.delivery.receiptAck",
            .execApprovalPrompt: "watch.execApproval.prompt",
            .execApprovalResolve: "watch.execApproval.resolve",
            .execApprovalResolved: "watch.execApproval.resolved",
            .execApprovalExpired: "watch.execApproval.expired",
            .execApprovalSnapshot: "watch.execApproval.snapshot",
            .execApprovalSnapshotRequest: "watch.execApproval.snapshotRequest",
        ]
        for (type, raw) in expected {
            #expect(type.rawValue == raw)
        }
        #expect(OpenClawWatchCommand.status.rawValue == "watch.status")
        #expect(OpenClawWatchCommand.notify.rawValue == "watch.notify")
        #expect(OpenClawWatchAppCommand.openChat.rawValue == "open-chat")
        #expect(OpenClawWatchExecApprovalCloseReason.notFound.rawValue == "not-found")
    }
}
