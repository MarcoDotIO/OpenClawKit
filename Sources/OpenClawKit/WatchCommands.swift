import Foundation

/// Gateway node commands an iPhone host advertises on behalf of its paired Apple Watch.
///
/// Only these two commands cross the Gateway boundary. Every ``OpenClawWatchPayloadType`` message is
/// companion-app protocol that the iPhone and Watch exchange over WatchConnectivity.
public enum OpenClawWatchCommand: String, Codable, Sendable {
    /// `watch.status`: report WatchConnectivity support, pairing, install, and reachability
    /// (``OpenClawWatchStatusPayload``).
    case status = "watch.status"
    /// `watch.notify`: relay a notification or prompt to the Watch (``OpenClawWatchNotifyParams`` →
    /// ``OpenClawWatchNotifyPayload``).
    case notify = "watch.notify"
}

/// `type` discriminator of every iPhone ↔ Watch companion message.
///
/// The SDK only defines the payloads; moving them through `WCSession` (`sendMessage`,
/// `transferUserInfo`, application context) is the host app's job. See ``OpenClawWatchMessageCodec``.
public enum OpenClawWatchPayloadType: String, Codable, Sendable, Equatable {
    /// iPhone → Watch notification or prompt (`watch.notify`).
    case notify = "watch.notify"
    /// iPhone → Watch setup code for the direct HTTPS node (``OpenClawWatchNodeSetupMessage``).
    case directNodeSetup = "watch.node.setup"
    /// Watch → iPhone legacy quick reply.
    case reply = "watch.reply"
    /// iPhone → Watch app state snapshot (``OpenClawWatchAppSnapshotMessage``).
    case appSnapshot = "watch.app.snapshot"
    /// Watch → iPhone request for a fresh ``OpenClawWatchAppSnapshotMessage``.
    case appSnapshotRequest = "watch.app.snapshotRequest"
    /// Watch → iPhone app action (``OpenClawWatchAppCommandMessage``).
    case appCommand = "watch.app.command"
    /// iPhone → Watch completion text for a Watch chat command (``OpenClawWatchChatCompletionMessage``).
    case chatCompletion = "watch.chat.completion"
    /// Watch → iPhone durable chat delivery command (``OpenClawWatchChatDeliveryCommand``).
    case chatDeliveryCommand = "watch.chat.delivery.command"
    /// iPhone → Watch chat delivery receipt (``OpenClawWatchChatDeliveryReceipt``).
    case chatDeliveryReceipt = "watch.chat.delivery.receipt"
    /// Watch → iPhone acknowledgment of a terminal receipt (``OpenClawWatchChatDeliveryReceiptAck``).
    case chatDeliveryReceiptAck = "watch.chat.delivery.receiptAck"
    /// iPhone → Watch exec approval prompt (``OpenClawWatchExecApprovalPromptMessage``).
    case execApprovalPrompt = "watch.execApproval.prompt"
    /// Watch → iPhone exec approval decision (``OpenClawWatchExecApprovalResolveMessage``).
    case execApprovalResolve = "watch.execApproval.resolve"
    /// iPhone → Watch exec approval resolution (``OpenClawWatchExecApprovalResolvedMessage``).
    case execApprovalResolved = "watch.execApproval.resolved"
    /// iPhone → Watch exec approval closure (``OpenClawWatchExecApprovalExpiredMessage``).
    case execApprovalExpired = "watch.execApproval.expired"
    /// iPhone → Watch full list of pending approvals (``OpenClawWatchExecApprovalSnapshotMessage``).
    case execApprovalSnapshot = "watch.execApproval.snapshot"
    /// Watch → iPhone request for an approval snapshot (``OpenClawWatchExecApprovalSnapshotRequestMessage``).
    case execApprovalSnapshotRequest = "watch.execApproval.snapshotRequest"
}

/// Risk hint that the Watch uses to style a prompt.
public enum OpenClawWatchRisk: String, Codable, Sendable, Equatable {
    /// Low risk (maps to passive priority).
    case low
    /// Medium risk (maps to active priority).
    case medium
    /// High risk (maps to time-sensitive priority).
    case high
}

/// Exec approval decisions the Watch may send. The Watch only gets this subset: "allow always"
/// stays an iPhone/Control UI decision.
public enum OpenClawWatchExecApprovalDecision: String, Codable, Sendable, Equatable {
    /// Allow this one execution.
    case allowOnce = "allow-once"
    /// Deny the execution.
    case deny
}

/// Why an exec approval disappeared from the Watch without a Watch decision.
public enum OpenClawWatchExecApprovalCloseReason: String, Codable, Sendable, Equatable {
    /// The approval expired.
    case expired
    /// The approval no longer exists on the Gateway.
    case notFound = "not-found"
    /// The iPhone cannot reach the approval owner.
    case unavailable
    /// A newer prompt replaced this approval.
    case replaced
    /// Another reviewer resolved the approval.
    case resolved
}

/// Quick action attached to a Watch prompt.
public struct OpenClawWatchAction: Codable, Sendable, Equatable, Identifiable {
    /// Action identifier sent back in the reply.
    public var id: String
    /// Button label.
    public var label: String
    /// Optional style hint (for example `destructive`).
    public var style: String?

    /// Creates a prompt action.
    public init(id: String, label: String, style: String? = nil) {
        self.id = id
        self.label = label
        self.style = style
    }
}

/// One pending exec approval as shown on the Watch.
public struct OpenClawWatchExecApprovalItem: Codable, Sendable, Equatable, Identifiable {
    /// Approval identifier.
    public var id: String
    /// Stable identifier of the Gateway that owns the approval.
    public var gatewayStableID: String?
    /// Full command text.
    public var commandText: String
    /// Shortened command preview for small screens.
    public var commandPreview: String?
    /// Warning shown above the decision buttons.
    public var warningText: String?
    /// Host that will run the command.
    public var host: String?
    /// Node that will run the command.
    public var nodeId: String?
    /// Agent that requested the command.
    public var agentId: String?
    /// Expiry in milliseconds since the Unix epoch (`Int64`, safe on arm64_32 watchOS).
    public var expiresAtMs: Int64?
    /// Decisions the Watch may offer.
    public var allowedDecisions: [OpenClawWatchExecApprovalDecision]
    /// Risk hint.
    public var risk: OpenClawWatchRisk?

    /// Creates an approval item.
    public init(
        id: String,
        gatewayStableID: String? = nil,
        commandText: String,
        commandPreview: String? = nil,
        warningText: String? = nil,
        host: String? = nil,
        nodeId: String? = nil,
        agentId: String? = nil,
        expiresAtMs: Int64? = nil,
        allowedDecisions: [OpenClawWatchExecApprovalDecision] = [],
        risk: OpenClawWatchRisk? = nil)
    {
        self.id = id
        self.gatewayStableID = gatewayStableID
        self.commandText = commandText
        self.commandPreview = commandPreview
        self.warningText = warningText
        self.host = host
        self.nodeId = nodeId
        self.agentId = agentId
        self.expiresAtMs = expiresAtMs
        self.allowedDecisions = allowedDecisions
        self.risk = risk
    }
}

/// `watch.execApproval.prompt`: iPhone → Watch prompt for one approval.
public struct OpenClawWatchExecApprovalPromptMessage: Codable, Sendable, Equatable {
    /// Always ``OpenClawWatchPayloadType/execApprovalPrompt``.
    public var type: OpenClawWatchPayloadType
    /// Approval to show.
    public var approval: OpenClawWatchExecApprovalItem
    /// Send time in milliseconds since the Unix epoch.
    public var sentAtMs: Int64?
    /// Resolution attempt the Watch must discard (a retry after a failed decision).
    public var resetResolutionAttemptId: String?

    /// Creates a prompt message.
    public init(
        approval: OpenClawWatchExecApprovalItem,
        sentAtMs: Int64? = nil,
        resetResolutionAttemptId: String? = nil)
    {
        self.type = .execApprovalPrompt
        self.approval = approval
        self.sentAtMs = sentAtMs
        self.resetResolutionAttemptId = resetResolutionAttemptId
    }
}

/// `watch.execApproval.resolve`: Watch → iPhone decision for one approval.
public struct OpenClawWatchExecApprovalResolveMessage: Codable, Sendable, Equatable {
    /// Always ``OpenClawWatchPayloadType/execApprovalResolve``.
    public var type: OpenClawWatchPayloadType
    /// Approval identifier.
    public var approvalId: String
    /// Gateway that owns the approval.
    public var gatewayStableID: String?
    /// Watch decision.
    public var decision: OpenClawWatchExecApprovalDecision
    /// Unique identifier of this decision attempt.
    public var replyId: String
    /// Send time in milliseconds since the Unix epoch.
    public var sentAtMs: Int64?

    /// Creates a resolve message.
    public init(
        approvalId: String,
        gatewayStableID: String? = nil,
        decision: OpenClawWatchExecApprovalDecision,
        replyId: String,
        sentAtMs: Int64? = nil)
    {
        self.type = .execApprovalResolve
        self.approvalId = approvalId
        self.gatewayStableID = gatewayStableID
        self.decision = decision
        self.replyId = replyId
        self.sentAtMs = sentAtMs
    }
}

/// Semantic outcome of a resolved approval, including decisions the Watch cannot make itself.
public enum OpenClawWatchExecApprovalOutcome: String, Codable, Sendable, Equatable {
    /// Allowed once.
    case allowedOnce
    /// Allowed always (decided elsewhere).
    case allowedAlways
    /// Denied.
    case denied
}

/// `watch.execApproval.resolved`: iPhone → Watch notice that an approval was resolved.
public struct OpenClawWatchExecApprovalResolvedMessage: Codable, Sendable, Equatable {
    /// Always ``OpenClawWatchPayloadType/execApprovalResolved``.
    public var type: OpenClawWatchPayloadType
    /// Approval identifier.
    public var approvalId: String
    /// Gateway that owns the approval.
    public var gatewayStableID: String?
    /// Watch-vocabulary decision, when the outcome maps to one.
    public var decision: OpenClawWatchExecApprovalDecision?
    /// Semantic outcome (dual-written with ``outcomeText`` for older Watch builds).
    public var outcome: OpenClawWatchExecApprovalOutcome?
    /// Resolution time in milliseconds since the Unix epoch.
    public var resolvedAtMs: Int64?
    /// Who resolved it (for example `watch` or `another-reviewer`).
    public var source: String?
    /// Human-readable outcome text.
    public var outcomeText: String?

    /// Creates a resolved message.
    public init(
        approvalId: String,
        gatewayStableID: String? = nil,
        decision: OpenClawWatchExecApprovalDecision? = nil,
        outcome: OpenClawWatchExecApprovalOutcome? = nil,
        resolvedAtMs: Int64? = nil,
        source: String? = nil,
        outcomeText: String? = nil)
    {
        self.type = .execApprovalResolved
        self.approvalId = approvalId
        self.gatewayStableID = gatewayStableID
        self.decision = decision
        self.outcome = outcome
        self.resolvedAtMs = resolvedAtMs
        self.source = source
        self.outcomeText = outcomeText
    }
}

/// `watch.execApproval.expired`: iPhone → Watch notice that an approval closed without a decision.
public struct OpenClawWatchExecApprovalExpiredMessage: Codable, Sendable, Equatable {
    /// Always ``OpenClawWatchPayloadType/execApprovalExpired``.
    public var type: OpenClawWatchPayloadType
    /// Approval identifier.
    public var approvalId: String
    /// Gateway that owns the approval.
    public var gatewayStableID: String?
    /// Why the approval closed.
    public var reason: OpenClawWatchExecApprovalCloseReason
    /// Close time in milliseconds since the Unix epoch.
    public var expiredAtMs: Int64?

    /// Creates an expired message.
    public init(
        approvalId: String,
        gatewayStableID: String? = nil,
        reason: OpenClawWatchExecApprovalCloseReason,
        expiredAtMs: Int64? = nil)
    {
        self.type = .execApprovalExpired
        self.approvalId = approvalId
        self.gatewayStableID = gatewayStableID
        self.reason = reason
        self.expiredAtMs = expiredAtMs
    }
}

/// `watch.execApproval.snapshot`: iPhone → Watch full list of pending approvals.
public struct OpenClawWatchExecApprovalSnapshotMessage: Codable, Sendable, Equatable {
    /// Always ``OpenClawWatchPayloadType/execApprovalSnapshot``.
    public var type: OpenClawWatchPayloadType
    /// Every approval the Watch should show.
    public var approvals: [OpenClawWatchExecApprovalItem]
    /// Gateway the snapshot describes.
    public var gatewayStableID: String?
    /// Send time in milliseconds since the Unix epoch.
    public var sentAtMs: Int64?
    /// Snapshot identifier.
    public var snapshotId: String?
    /// Request this snapshot answers, if any.
    public var requestId: String?
    /// Gateway named by the answered request.
    public var requestGatewayStableID: String?

    /// Creates a snapshot message.
    public init(
        approvals: [OpenClawWatchExecApprovalItem],
        gatewayStableID: String? = nil,
        sentAtMs: Int64? = nil,
        snapshotId: String? = nil,
        requestId: String? = nil,
        requestGatewayStableID: String? = nil)
    {
        self.type = .execApprovalSnapshot
        self.approvals = approvals
        self.gatewayStableID = gatewayStableID
        self.sentAtMs = sentAtMs
        self.snapshotId = snapshotId
        self.requestId = requestId
        self.requestGatewayStableID = requestGatewayStableID
    }
}

/// Approval the Watch still holds when it asks for a snapshot.
public struct OpenClawWatchExecApprovalSnapshotRequestItem: Codable, Sendable, Equatable {
    /// Approval identifier.
    public var approvalId: String
    /// Decision attempt still in flight on the Watch, if any.
    public var activeResolutionAttemptId: String?

    /// Creates a held-approval entry.
    public init(
        approvalId: String,
        activeResolutionAttemptId: String? = nil)
    {
        self.approvalId = approvalId
        self.activeResolutionAttemptId = activeResolutionAttemptId
    }
}

/// `watch.execApproval.snapshotRequest`: Watch → iPhone request for an approval snapshot.
public struct OpenClawWatchExecApprovalSnapshotRequestMessage: Codable, Sendable, Equatable {
    /// Always ``OpenClawWatchPayloadType/execApprovalSnapshotRequest``.
    public var type: OpenClawWatchPayloadType
    /// Request identifier echoed by the snapshot.
    public var requestId: String
    /// Send time in milliseconds since the Unix epoch.
    public var sentAtMs: Int64?
    /// Gateway the Watch believes is current.
    public var gatewayStableID: String?
    /// Approvals the Watch currently shows.
    public var heldApprovals: [OpenClawWatchExecApprovalSnapshotRequestItem]

    /// Creates a snapshot request.
    public init(
        requestId: String,
        sentAtMs: Int64? = nil,
        gatewayStableID: String? = nil,
        heldApprovals: [OpenClawWatchExecApprovalSnapshotRequestItem] = [])
    {
        self.type = .execApprovalSnapshotRequest
        self.requestId = requestId
        self.sentAtMs = sentAtMs
        self.gatewayStableID = gatewayStableID
        self.heldApprovals = heldApprovals
    }
}

/// One chat transcript line mirrored to the Watch.
public struct OpenClawWatchChatItem: Codable, Sendable, Equatable, Identifiable {
    /// Message identifier.
    public var id: String
    /// Author role (`user` or `assistant`).
    public var role: String
    /// Visible text.
    public var text: String
    /// Message time in milliseconds since the Unix epoch.
    public var timestampMs: Int64?

    /// Creates a chat item.
    public init(
        id: String,
        role: String,
        text: String,
        timestampMs: Int64? = nil)
    {
        self.id = id
        self.role = role
        self.text = text
        self.timestampMs = timestampMs
    }
}

/// `watch.chat.completion`: iPhone → Watch reply text for a Watch chat command.
public struct OpenClawWatchChatCompletionMessage: Codable, Sendable, Equatable {
    /// Always ``OpenClawWatchPayloadType/chatCompletion``.
    public var type: OpenClawWatchPayloadType
    /// Command the reply answers.
    public var commandId: String
    /// Reply text.
    public var replyText: String
    /// Send time in milliseconds since the Unix epoch.
    public var sentAtMs: Int64?

    /// Creates a completion message.
    public init(commandId: String, replyText: String, sentAtMs: Int64? = nil) {
        self.type = .chatCompletion
        self.commandId = commandId
        self.replyText = replyText
        self.sentAtMs = sentAtMs
    }
}

/// Semantic status codes the Watch localizes itself, so the iPhone does not ship display strings.
public enum OpenClawWatchAppStatusCode: String, Codable, Sendable, Equatable {
    /// Gateway connected.
    case gatewayConnected
    /// Gateway connecting.
    case gatewayConnecting
    /// Gateway reconnecting.
    case gatewayReconnecting
    /// Gateway offline.
    case gatewayOffline
    /// Gateway reported a problem.
    case gatewayProblem
    /// Gateway problem with a request identifier argument.
    case gatewayProblemWithRequestID
    /// Talk is off.
    case talkOff
    /// Talk is ready.
    case talkReady
    /// Talk is connecting.
    case talkConnecting
    /// Talk is listening.
    case talkListening
    /// Talk is thinking.
    case talkThinking
    /// Talk is speaking.
    case talkSpeaking
    /// Talk is offline.
    case talkOffline
    /// Talk needs a Gateway permission.
    case talkPermissionRequired
    /// Talk is requesting approval.
    case talkRequestingApproval
    /// Talk approval was requested.
    case talkApprovalRequested
    /// Talk provider API key is missing.
    case talkAPIKeyMissing
    /// Talk failed.
    case talkFailure
    /// Chat needs the iPhone connection.
    case chatConnectIPhone
    /// Chat has no messages yet.
    case chatNoMessages
    /// Chat is unavailable.
    case chatUnavailable
    /// Unknown or legacy status; show ``OpenClawWatchAppStatus/verbatim``.
    case legacy
}

/// Semantic status with optional localization key, arguments, and verbatim fallback text.
public struct OpenClawWatchAppStatus: Codable, Sendable, Equatable {
    /// Status code.
    public var code: OpenClawWatchAppStatusCode
    /// Localization key overriding the code's default string.
    public var localizationKey: String?
    /// Format arguments for the localized string.
    public var arguments: [String]
    /// Verbatim text for ``OpenClawWatchAppStatusCode/legacy`` statuses.
    public var verbatim: String?

    /// Creates a status.
    public init(
        code: OpenClawWatchAppStatusCode,
        localizationKey: String? = nil,
        arguments: [String] = [],
        verbatim: String? = nil)
    {
        self.code = code
        self.localizationKey = localizationKey
        self.arguments = arguments
        self.verbatim = verbatim
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case localizationKey
        case arguments
        case verbatim
    }

    /// Decodes a status; a missing `arguments` array (the iPhone omits empty ones) decodes as `[]`.
    /// An unknown `code` throws so snapshot decoding can fall back to the legacy text.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(OpenClawWatchAppStatusCode.self, forKey: .code)
        self.localizationKey = try container.decodeIfPresent(String.self, forKey: .localizationKey)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.verbatim = try container.decodeIfPresent(String.self, forKey: .verbatim)
    }

    /// Maps a legacy `gatewayStatusText` to a semantic status.
    public static func decodeLegacyGateway(
        text: String?,
        connected: Bool) -> OpenClawWatchAppStatus
    {
        if connected {
            return OpenClawWatchAppStatus(code: .gatewayConnected)
        }
        guard let text, !text.isEmpty else {
            return OpenClawWatchAppStatus(code: .gatewayOffline)
        }
        return OpenClawWatchAppStatus(code: .legacy, verbatim: text)
    }

    /// Maps a legacy `talkStatusText` plus Talk flags to a semantic status.
    public static func decodeLegacyTalk(
        text: String?,
        enabled: Bool,
        listening: Bool,
        speaking: Bool) -> OpenClawWatchAppStatus
    {
        if speaking {
            return OpenClawWatchAppStatus(code: .talkSpeaking)
        }
        if listening {
            return OpenClawWatchAppStatus(code: .talkListening)
        }
        if !enabled {
            return OpenClawWatchAppStatus(code: .talkOff)
        }
        guard let text, !text.isEmpty else {
            return OpenClawWatchAppStatus(code: .talkReady)
        }
        return OpenClawWatchAppStatus(code: .legacy, verbatim: text)
    }

    /// Maps a legacy `chatStatusCode` (`connectIPhone`, `noMessages`, `unavailable`) or text to a status.
    public static func decodeLegacyChat(
        code: String?,
        text: String?) -> OpenClawWatchAppStatus?
    {
        let statusCode: OpenClawWatchAppStatusCode? = switch code {
        case "connectIPhone":
            OpenClawWatchAppStatusCode.chatConnectIPhone
        case "noMessages":
            OpenClawWatchAppStatusCode.chatNoMessages
        case "unavailable":
            OpenClawWatchAppStatusCode.chatUnavailable
        default:
            nil
        }
        if let statusCode {
            return OpenClawWatchAppStatus(code: statusCode)
        }
        guard let text, !text.isEmpty else { return nil }
        return OpenClawWatchAppStatus(code: .legacy, verbatim: text)
    }
}

/// `watch.app.snapshot`: iPhone → Watch state for the Watch app's home, chat, and Talk surfaces.
///
/// Encoding dual-writes the semantic statuses and the shipped `*StatusText` fields, because iPhone
/// and Watch updates are staggered. Decoding accepts snapshots without semantic statuses, the
/// legacy `chatStatusCode`, and unknown future status codes (which fall back to the text fields).
public struct OpenClawWatchAppSnapshotMessage: Codable, Sendable, Equatable {
    /// Always ``OpenClawWatchPayloadType/appSnapshot``.
    public var type: OpenClawWatchPayloadType
    /// Semantic Gateway status.
    public var gatewayStatus: OpenClawWatchAppStatus
    /// Legacy Gateway status text.
    public var gatewayStatusText: String
    /// Whether the iPhone is connected to the Gateway.
    public var gatewayConnected: Bool
    /// Agent display name.
    public var agentName: String
    /// Agent avatar URL.
    public var agentAvatarURL: String?
    /// Agent avatar text (emoji or initials).
    public var agentAvatarText: String?
    /// Chat session key.
    public var sessionKey: String
    /// Stable identifier of the current Gateway.
    public var gatewayStableID: String?
    /// Semantic Talk status.
    public var talkStatus: OpenClawWatchAppStatus
    /// Legacy Talk status text.
    public var talkStatusText: String
    /// Whether Talk is enabled.
    public var talkEnabled: Bool
    /// Whether Talk is listening.
    public var talkListening: Bool
    /// Whether Talk is speaking.
    public var talkSpeaking: Bool
    /// Number of pending exec approvals.
    public var pendingApprovalCount: Int
    /// Recent chat lines.
    public var chatItems: [OpenClawWatchChatItem]?
    /// Semantic chat status.
    public var chatStatus: OpenClawWatchAppStatus?
    /// Legacy chat status text.
    public var chatStatusText: String?
    /// Send time in milliseconds since the Unix epoch.
    public var sentAtMs: Int64?
    /// Snapshot identifier.
    public var snapshotId: String?
    /// Routing owner that Watch chat commands must carry (see ``OpenClawWatchChatDeliveryCommand``).
    public var chatDeliveryContext: OpenClawWatchChatDeliveryContext?

    /// Creates a snapshot from semantic statuses; `chatStatusText` defaults to the status's legacy text.
    public init(
        gatewayStatus: OpenClawWatchAppStatus,
        gatewayStatusText: String,
        gatewayConnected: Bool,
        agentName: String,
        agentAvatarURL: String? = nil,
        agentAvatarText: String? = nil,
        sessionKey: String,
        gatewayStableID: String? = nil,
        talkStatus: OpenClawWatchAppStatus,
        talkStatusText: String,
        talkEnabled: Bool,
        talkListening: Bool,
        talkSpeaking: Bool,
        pendingApprovalCount: Int,
        chatItems: [OpenClawWatchChatItem]? = nil,
        chatStatus: OpenClawWatchAppStatus? = nil,
        chatStatusText: String? = nil,
        sentAtMs: Int64? = nil,
        snapshotId: String? = nil,
        chatDeliveryContext: OpenClawWatchChatDeliveryContext? = nil)
    {
        self.type = .appSnapshot
        self.gatewayStatus = gatewayStatus
        self.gatewayStatusText = gatewayStatusText
        self.gatewayConnected = gatewayConnected
        self.agentName = agentName
        self.agentAvatarURL = agentAvatarURL
        self.agentAvatarText = agentAvatarText
        self.sessionKey = sessionKey
        self.gatewayStableID = gatewayStableID
        self.talkStatus = talkStatus
        self.talkStatusText = talkStatusText
        self.talkEnabled = talkEnabled
        self.talkListening = talkListening
        self.talkSpeaking = talkSpeaking
        self.pendingApprovalCount = pendingApprovalCount
        self.chatItems = chatItems
        self.chatStatus = chatStatus
        self.chatStatusText = chatStatusText ?? chatStatus.map(Self.legacyText)
        self.sentAtMs = sentAtMs
        self.snapshotId = snapshotId
        self.chatDeliveryContext = chatDeliveryContext
    }

    /// Creates a snapshot from legacy status text, deriving the semantic statuses.
    public init(
        gatewayStatusText: String,
        gatewayConnected: Bool,
        agentName: String,
        agentAvatarURL: String? = nil,
        agentAvatarText: String? = nil,
        sessionKey: String,
        gatewayStableID: String? = nil,
        talkStatusText: String,
        talkEnabled: Bool,
        talkListening: Bool,
        talkSpeaking: Bool,
        pendingApprovalCount: Int,
        chatItems: [OpenClawWatchChatItem]? = nil,
        chatStatusText: String? = nil,
        sentAtMs: Int64? = nil,
        snapshotId: String? = nil,
        chatDeliveryContext: OpenClawWatchChatDeliveryContext? = nil)
    {
        // Preserve the shipped source API while producers migrate to semantic statuses.
        self.init(
            gatewayStatus: OpenClawWatchAppStatus.decodeLegacyGateway(
                text: gatewayStatusText,
                connected: gatewayConnected),
            gatewayStatusText: gatewayStatusText,
            gatewayConnected: gatewayConnected,
            agentName: agentName,
            agentAvatarURL: agentAvatarURL,
            agentAvatarText: agentAvatarText,
            sessionKey: sessionKey,
            gatewayStableID: gatewayStableID,
            talkStatus: OpenClawWatchAppStatus.decodeLegacyTalk(
                text: talkStatusText,
                enabled: talkEnabled,
                listening: talkListening,
                speaking: talkSpeaking),
            talkStatusText: talkStatusText,
            talkEnabled: talkEnabled,
            talkListening: talkListening,
            talkSpeaking: talkSpeaking,
            pendingApprovalCount: pendingApprovalCount,
            chatItems: chatItems,
            chatStatus: OpenClawWatchAppStatus.decodeLegacyChat(code: nil, text: chatStatusText),
            chatStatusText: chatStatusText,
            sentAtMs: sentAtMs,
            snapshotId: snapshotId,
            chatDeliveryContext: chatDeliveryContext)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case gatewayStatus
        case gatewayStatusText
        case gatewayConnected
        case agentName
        case agentAvatarURL
        case agentAvatarText
        case sessionKey
        case gatewayStableID
        case talkStatus
        case talkStatusText
        case talkEnabled
        case talkListening
        case talkSpeaking
        case pendingApprovalCount
        case chatItems
        case chatStatus
        case chatStatusCode
        case chatStatusText
        case sentAtMs
        case snapshotId
        case chatDeliveryContext
    }

    /// Decodes a snapshot, tolerating missing or unknown semantic statuses and the legacy `chatStatusCode`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(OpenClawWatchPayloadType.self, forKey: .type)
        self.gatewayConnected = try container.decode(Bool.self, forKey: .gatewayConnected)
        self.agentName = try container.decode(String.self, forKey: .agentName)
        self.agentAvatarURL = try container.decodeIfPresent(String.self, forKey: .agentAvatarURL)
        self.agentAvatarText = try container.decodeIfPresent(String.self, forKey: .agentAvatarText)
        self.sessionKey = try container.decode(String.self, forKey: .sessionKey)
        self.gatewayStableID = try container.decodeIfPresent(String.self, forKey: .gatewayStableID)
        self.talkEnabled = try container.decode(Bool.self, forKey: .talkEnabled)
        self.talkListening = try container.decode(Bool.self, forKey: .talkListening)
        self.talkSpeaking = try container.decode(Bool.self, forKey: .talkSpeaking)
        self.pendingApprovalCount = try container.decode(Int.self, forKey: .pendingApprovalCount)
        self.chatItems = try container.decodeIfPresent([OpenClawWatchChatItem].self, forKey: .chatItems)
        self.sentAtMs = try container.decodeIfPresent(Int64.self, forKey: .sentAtMs)
        self.snapshotId = try container.decodeIfPresent(String.self, forKey: .snapshotId)
        self.chatDeliveryContext = try container.decodeIfPresent(
            OpenClawWatchChatDeliveryContext.self, forKey: .chatDeliveryContext)

        let gatewayStatusText = try container.decodeIfPresent(String.self, forKey: .gatewayStatusText)
        if let gatewayStatus = try? container.decode(
            OpenClawWatchAppStatus.self,
            forKey: .gatewayStatus)
        {
            self.gatewayStatus = gatewayStatus
        } else if container.contains(.gatewayStatus),
                  let gatewayStatusText,
                  !gatewayStatusText.isEmpty
        {
            self.gatewayStatus = OpenClawWatchAppStatus(
                code: .legacy,
                verbatim: gatewayStatusText)
        } else {
            self.gatewayStatus = OpenClawWatchAppStatus.decodeLegacyGateway(
                text: gatewayStatusText,
                connected: self.gatewayConnected)
        }
        self.gatewayStatusText = gatewayStatusText ?? Self.legacyText(for: self.gatewayStatus)
        let talkStatusText = try container.decodeIfPresent(String.self, forKey: .talkStatusText)
        if let talkStatus = try? container.decode(
            OpenClawWatchAppStatus.self,
            forKey: .talkStatus)
        {
            self.talkStatus = talkStatus
        } else if container.contains(.talkStatus),
                  let talkStatusText,
                  !talkStatusText.isEmpty
        {
            self.talkStatus = OpenClawWatchAppStatus(
                code: .legacy,
                verbatim: talkStatusText)
        } else {
            self.talkStatus = OpenClawWatchAppStatus.decodeLegacyTalk(
                text: talkStatusText,
                enabled: self.talkEnabled,
                listening: self.talkListening,
                speaking: self.talkSpeaking)
        }
        self.talkStatusText = talkStatusText ?? Self.legacyText(for: self.talkStatus)
        let chatStatusText = try container.decodeIfPresent(String.self, forKey: .chatStatusText)
        let chatStatusCode = try container.decodeIfPresent(String.self, forKey: .chatStatusCode)
        self.chatStatus = (try? container.decode(
            OpenClawWatchAppStatus.self,
            forKey: .chatStatus)) ?? OpenClawWatchAppStatus.decodeLegacyChat(
            code: chatStatusCode,
            text: chatStatusText)
        self.chatStatusText = chatStatusText ?? self.chatStatus.map(Self.legacyText)
    }

    /// Encodes the snapshot, dual-writing semantic statuses and legacy text fields.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.type, forKey: .type)
        try container.encode(self.gatewayStatus, forKey: .gatewayStatus)
        // iPhone and watchOS updates are staggered. Keep the shipped text fields
        // until every supported Watch build decodes the semantic status payload.
        try container.encode(self.gatewayStatusText, forKey: .gatewayStatusText)
        try container.encode(self.gatewayConnected, forKey: .gatewayConnected)
        try container.encode(self.agentName, forKey: .agentName)
        try container.encodeIfPresent(self.agentAvatarURL, forKey: .agentAvatarURL)
        try container.encodeIfPresent(self.agentAvatarText, forKey: .agentAvatarText)
        try container.encode(self.sessionKey, forKey: .sessionKey)
        try container.encodeIfPresent(self.gatewayStableID, forKey: .gatewayStableID)
        try container.encode(self.talkStatus, forKey: .talkStatus)
        try container.encode(self.talkStatusText, forKey: .talkStatusText)
        try container.encode(self.talkEnabled, forKey: .talkEnabled)
        try container.encode(self.talkListening, forKey: .talkListening)
        try container.encode(self.talkSpeaking, forKey: .talkSpeaking)
        try container.encode(self.pendingApprovalCount, forKey: .pendingApprovalCount)
        try container.encodeIfPresent(self.chatItems, forKey: .chatItems)
        try container.encodeIfPresent(self.chatStatus, forKey: .chatStatus)
        try container.encodeIfPresent(self.chatStatusText, forKey: .chatStatusText)
        try container.encodeIfPresent(self.sentAtMs, forKey: .sentAtMs)
        try container.encodeIfPresent(self.snapshotId, forKey: .snapshotId)
        try container.encodeIfPresent(self.chatDeliveryContext, forKey: .chatDeliveryContext)
    }

    private static func legacyText(for status: OpenClawWatchAppStatus) -> String {
        if let verbatim = status.verbatim, !verbatim.isEmpty {
            return verbatim
        }
        if let localizationKey = status.localizationKey, !localizationKey.isEmpty {
            return localizationKey
        }
        return switch status.code {
        case .gatewayConnected,
             .gatewayConnecting,
             .gatewayReconnecting,
             .gatewayOffline,
             .gatewayProblem,
             .gatewayProblemWithRequestID:
            self.legacyGatewayText(for: status.code)
        case .talkOff,
             .talkReady,
             .talkConnecting,
             .talkListening,
             .talkThinking,
             .talkSpeaking,
             .talkOffline,
             .talkPermissionRequired,
             .talkRequestingApproval,
             .talkApprovalRequested,
             .talkAPIKeyMissing,
             .talkFailure:
            self.legacyTalkText(for: status.code)
        case .chatConnectIPhone, .chatNoMessages, .chatUnavailable:
            self.legacyChatText(for: status.code)
        case .legacy:
            "Unavailable"
        }
    }

    private static func legacyGatewayText(for code: OpenClawWatchAppStatusCode) -> String {
        switch code {
        case .gatewayConnected: "Connected"
        case .gatewayConnecting: "Connecting…"
        case .gatewayReconnecting: "Reconnecting…"
        case .gatewayOffline: "Offline"
        case .gatewayProblem, .gatewayProblemWithRequestID: "Gateway unavailable"
        default: "Gateway unavailable"
        }
    }

    private static func legacyTalkText(for code: OpenClawWatchAppStatusCode) -> String {
        switch code {
        case .talkOff: "Off"
        case .talkReady: "Ready"
        case .talkConnecting: "Connecting"
        case .talkListening: "Listening"
        case .talkThinking: "Thinking"
        case .talkSpeaking: "Speaking"
        case .talkOffline: "Offline"
        case .talkPermissionRequired: "Gateway permission required"
        case .talkRequestingApproval: "Requesting Talk approval"
        case .talkApprovalRequested: "Approval requested"
        case .talkAPIKeyMissing: "API key missing"
        case .talkFailure: "Talk unavailable"
        default: "Talk unavailable"
        }
    }

    private static func legacyChatText(for code: OpenClawWatchAppStatusCode) -> String {
        switch code {
        case .chatConnectIPhone: "Connect iPhone chat to read messages"
        case .chatNoMessages: "No chat messages yet"
        case .chatUnavailable: "Chat unavailable"
        default: "Chat unavailable"
        }
    }
}

/// `watch.app.snapshotRequest`: Watch → iPhone request for a fresh app snapshot.
public struct OpenClawWatchAppSnapshotRequestMessage: Codable, Sendable, Equatable {
    /// Always ``OpenClawWatchPayloadType/appSnapshotRequest``.
    public var type: OpenClawWatchPayloadType
    /// Request identifier.
    public var requestId: String
    /// Send time in milliseconds since the Unix epoch.
    public var sentAtMs: Int64?

    /// Creates a snapshot request.
    public init(requestId: String, sentAtMs: Int64? = nil) {
        self.type = .appSnapshotRequest
        self.requestId = requestId
        self.sentAtMs = sentAtMs
    }
}

/// Watch app actions relayed to the iPhone.
public enum OpenClawWatchAppCommand: String, Codable, Sendable, Equatable {
    /// Refresh the snapshot.
    case refresh
    /// Open chat on the iPhone.
    case openChat = "open-chat"
    /// Send chat text (legacy path; durable delivery uses ``OpenClawWatchChatDeliveryCommand``).
    case sendChat = "send-chat"
    /// Start iPhone-relayed Talk.
    case startTalk = "start-talk"
    /// Stop iPhone-relayed Talk.
    case stopTalk = "stop-talk"
}

/// `watch.app.command`: Watch → iPhone app action.
public struct OpenClawWatchAppCommandMessage: Codable, Sendable, Equatable {
    /// Always ``OpenClawWatchPayloadType/appCommand``.
    public var type: OpenClawWatchPayloadType
    /// Requested action.
    public var command: OpenClawWatchAppCommand
    /// Unique identifier of this command.
    public var commandId: String
    /// Chat session the command targets.
    public var sessionKey: String?
    /// Gateway the command targets.
    public var gatewayStableID: String?
    /// Text for ``OpenClawWatchAppCommand/sendChat``.
    public var text: String?
    /// Send time in milliseconds since the Unix epoch.
    public var sentAtMs: Int64?

    /// Creates an app command message.
    public init(
        command: OpenClawWatchAppCommand,
        commandId: String,
        sessionKey: String? = nil,
        gatewayStableID: String? = nil,
        text: String? = nil,
        sentAtMs: Int64? = nil)
    {
        self.type = .appCommand
        self.command = command
        self.commandId = commandId
        self.sessionKey = sessionKey
        self.gatewayStableID = gatewayStableID
        self.text = text
        self.sentAtMs = sentAtMs
    }
}

/// `watch.status` result: WatchConnectivity state as seen from the iPhone.
public struct OpenClawWatchStatusPayload: Codable, Sendable, Equatable {
    /// Whether WatchConnectivity is supported on this device.
    public var supported: Bool
    /// Whether an Apple Watch is paired.
    public var paired: Bool
    /// Whether the companion Watch app is installed.
    public var appInstalled: Bool
    /// Whether the Watch app is currently reachable for live messages.
    public var reachable: Bool
    /// `WCSession` activation state (`activated`, `inactive`, `notActivated`).
    public var activationState: String

    /// Creates a status payload.
    public init(
        supported: Bool,
        paired: Bool,
        appInstalled: Bool,
        reachable: Bool,
        activationState: String)
    {
        self.supported = supported
        self.paired = paired
        self.appInstalled = appInstalled
        self.reachable = reachable
        self.activationState = activationState
    }
}

/// `watch.notify` params: a notification or prompt relayed to the Watch through the iPhone.
public struct OpenClawWatchNotifyParams: Codable, Sendable, Equatable {
    /// Notification title.
    public var title: String
    /// Notification body.
    public var body: String
    /// Interruption priority.
    public var priority: OpenClawNotificationPriority?
    /// Prompt identifier that quick replies reference.
    public var promptId: String?
    /// Chat session a reply should go to.
    public var sessionKey: String?
    /// Gateway that issued the prompt; replies only get a delivery context when it is current.
    public var gatewayStableID: String?
    /// Prompt kind (for example `approval`).
    public var kind: String?
    /// Extra detail text.
    public var details: String?
    /// Expiry in milliseconds since the Unix epoch (`Int64`, safe on arm64_32 watchOS).
    public var expiresAtMs: Int64?
    /// Risk hint.
    public var risk: OpenClawWatchRisk?
    /// Quick actions (at most four are shown).
    public var actions: [OpenClawWatchAction]?

    /// Creates notify params.
    public init(
        title: String,
        body: String,
        priority: OpenClawNotificationPriority? = nil,
        promptId: String? = nil,
        sessionKey: String? = nil,
        gatewayStableID: String? = nil,
        kind: String? = nil,
        details: String? = nil,
        expiresAtMs: Int64? = nil,
        risk: OpenClawWatchRisk? = nil,
        actions: [OpenClawWatchAction]? = nil)
    {
        self.title = title
        self.body = body
        self.priority = priority
        self.promptId = promptId
        self.sessionKey = sessionKey
        self.gatewayStableID = gatewayStableID
        self.kind = kind
        self.details = details
        self.expiresAtMs = expiresAtMs
        self.risk = risk
        self.actions = actions
    }
}

/// `watch.notify` result.
///
/// A receipt reports transport delivery or queuing (`sendMessage` versus `transferUserInfo`), not that
/// the Watch displayed the prompt or that an iPhone mirror notification completed.
public struct OpenClawWatchNotifyPayload: Codable, Sendable, Equatable {
    /// Whether the message reached a reachable Watch immediately.
    public var deliveredImmediately: Bool
    /// Whether the message was queued for later delivery.
    public var queuedForDelivery: Bool
    /// Transport used (for example `sendMessage` or `transferUserInfo`).
    public var transport: String

    /// Creates a notify result.
    public init(deliveredImmediately: Bool, queuedForDelivery: Bool, transport: String) {
        self.deliveredImmediately = deliveredImmediately
        self.queuedForDelivery = queuedForDelivery
        self.transport = transport
    }
}
