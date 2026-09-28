import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

/// Message actions the SDK routes to native adapters (a subset of upstream `CHANNEL_MESSAGE_ACTION_NAMES`).
public enum ChannelMessageActionName: String, Codable, Sendable, Equatable, CaseIterable {
    /// Send a message.
    case send
    /// Add or remove an emoji reaction.
    case react
    /// Edit a sent message.
    case edit
    /// Unsend a sent message.
    case unsend
    /// Delete a message (alias of ``unsend`` for platforms that call it delete).
    case delete
    /// Send a poll.
    case poll

    /// Capability flag that gates the action.
    public var requiredFeature: ChannelCapabilities.DeliveryFeature? {
        switch self {
        case .send: nil
        case .react: .reactions
        case .edit: .edit
        case .unsend, .delete: .unsend
        case .poll: .polls
        }
    }

    /// Per-channel `actions.<key>` toggle name.
    public var configToggleKey: String {
        switch self {
        case .send: "sendMessage"
        case .react: "reactions"
        case .edit: "edit"
        case .unsend: "unsend"
        case .delete: "deleteMessage"
        case .poll: "polls"
        }
    }
}

/// Error thrown for unsupported or disabled message actions.
public enum ChannelMessageActionError: Error, LocalizedError, Sendable, Equatable {
    /// The adapter does not implement the action.
    case unsupported(action: String, channel: ChannelID)
    /// The channel's capabilities do not include the action.
    case notCapable(action: String, channel: ChannelID)
    /// A per-channel `actions.*` toggle disables the action.
    case disabledByConfig(action: String, channel: ChannelID)
    /// Required action params are missing.
    case invalidParams(String)

    /// Localized description.
    public var errorDescription: String? {
        switch self {
        case .unsupported(let action, let channel):
            "\(channel.rawValue) does not support the \(action) message action"
        case .notCapable(let action, let channel):
            "\(channel.rawValue) capabilities do not include \(action)"
        case .disabledByConfig(let action, let channel):
            "channels.\(channel.rawValue).actions disables \(action)"
        case .invalidParams(let detail):
            "Invalid message action params: \(detail)"
        }
    }
}

/// Optional adapter capability for native message actions (react/edit/unsend/poll).
///
/// Every requirement has a default that throws ``ChannelMessageActionError/unsupported(action:channel:)``,
/// so adapters implement only what their platform supports.
public protocol ChannelMessageActions: ChannelAdapter {
    /// Adds (or removes) a reaction.
    /// - Parameters:
    ///   - peerID: Conversation id.
    ///   - messageID: Platform message id.
    ///   - emoji: Unicode emoji.
    ///   - remove: Whether to remove instead of add.
    func react(peerID: String, messageID: String, emoji: String, remove: Bool) async throws
    /// Edits a sent message.
    /// - Parameters:
    ///   - peerID: Conversation id.
    ///   - messageID: Platform message id.
    ///   - text: Replacement text.
    func edit(peerID: String, messageID: String, text: String) async throws
    /// Unsends (deletes) a sent message.
    /// - Parameters:
    ///   - peerID: Conversation id.
    ///   - messageID: Platform message id.
    func unsend(peerID: String, messageID: String) async throws
    /// Sends a native poll.
    /// - Parameters:
    ///   - peerID: Conversation id.
    ///   - question: Poll question.
    ///   - options: Poll options.
    ///   - allowMultiple: Whether multiple answers are allowed.
    /// - Returns: Receipt of the poll message, when available.
    func sendPoll(peerID: String, question: String, options: [String], allowMultiple: Bool) async throws -> ChannelSendReceipt?
}

public extension ChannelMessageActions {
    /// Default: unsupported.
    func react(peerID _: String, messageID _: String, emoji _: String, remove _: Bool) async throws {
        throw ChannelMessageActionError.unsupported(action: "react", channel: self.id)
    }

    /// Default: unsupported.
    func edit(peerID _: String, messageID _: String, text _: String) async throws {
        throw ChannelMessageActionError.unsupported(action: "edit", channel: self.id)
    }

    /// Default: unsupported.
    func unsend(peerID _: String, messageID _: String) async throws {
        throw ChannelMessageActionError.unsupported(action: "unsend", channel: self.id)
    }

    /// Default: unsupported.
    func sendPoll(peerID _: String, question _: String, options _: [String], allowMultiple _: Bool) async throws -> ChannelSendReceipt? {
        throw ChannelMessageActionError.unsupported(action: "poll", channel: self.id)
    }
}

public extension ChannelRegistry {
    /// Routes a gateway `message.action` request to the channel's adapter.
    ///
    /// Supported actions: `send`, `react`, `edit`, `unsend`/`delete`, `poll`. Each call is gated
    /// on the channel's metadata capabilities and on per-channel `actions.<key>` toggles
    /// (default enabled). Params use upstream keys: `to`/`target`/`peerId`, `messageId`, `emoji`,
    /// `remove`, `text`/`message`, `question`, `options`, `allowMultiple`.
    /// - Parameters:
    ///   - params: Upstream message action params.
    ///   - actionToggles: Per-action toggles (for example from `channels.<id>.actions`).
    /// - Returns: Action result payload.
    /// - Throws: ``ChannelMessageActionError`` or delivery errors.
    func performAction(_ params: MessageActionParams, actionToggles: [String: Bool] = [:]) async throws -> AnyCodable {
        guard let channel = ChannelID(normalizing: params.channel) else {
            throw ChannelMessageActionError.invalidParams("unknown channel \(params.channel)")
        }
        guard let action = ChannelMessageActionName(rawValue: params.action) else {
            throw ChannelMessageActionError.unsupported(action: params.action, channel: channel)
        }
        if let feature = action.requiredFeature, !channel.metadata.capabilities.supports(feature) {
            throw ChannelMessageActionError.notCapable(action: action.rawValue, channel: channel)
        }
        if actionToggles[action.configToggleKey] == false {
            throw ChannelMessageActionError.disabledByConfig(action: action.rawValue, channel: channel)
        }
        guard let adapter = self.adapter(for: channel) else {
            throw OpenClawCoreError.unavailable("No adapter registered for \(channel.rawValue)")
        }
        let values = params.params
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = values[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
                if let number = values[key]?.int64Value {
                    return String(number)
                }
            }
            return nil
        }
        guard let peerID = string("to", "target", "peerId", "channelId", "chatId") else {
            throw ChannelMessageActionError.invalidParams("missing target (to)")
        }
        if action == .send {
            guard let text = string("text", "message") else {
                throw ChannelMessageActionError.invalidParams("missing text")
            }
            let outcome = try await self.send(
                OutboundMessage(
                    channel: channel,
                    accountID: params.accountid,
                    peerID: peerID,
                    text: text,
                    replyToID: string("replyTo", "replyToId"),
                    threadID: string("threadId")
                )
            )
            return try AnyCodable(encoding: ActionResult(ok: true, action: action.rawValue, messageID: outcome.receipt?.primaryPlatformMessageID))
        }
        guard let actions = adapter as? any ChannelMessageActions else {
            throw ChannelMessageActionError.unsupported(action: action.rawValue, channel: channel)
        }
        switch action {
        case .react:
            guard let messageID = string("messageId"), let emoji = string("emoji", "reaction") else {
                throw ChannelMessageActionError.invalidParams("react requires messageId and emoji")
            }
            try await actions.react(peerID: peerID, messageID: messageID, emoji: emoji, remove: values["remove"]?.boolValue ?? false)
            return try AnyCodable(encoding: ActionResult(ok: true, action: action.rawValue, messageID: messageID))
        case .edit:
            guard let messageID = string("messageId"), let text = string("text", "message") else {
                throw ChannelMessageActionError.invalidParams("edit requires messageId and text")
            }
            try await actions.edit(peerID: peerID, messageID: messageID, text: text)
            return try AnyCodable(encoding: ActionResult(ok: true, action: action.rawValue, messageID: messageID))
        case .unsend, .delete:
            guard let messageID = string("messageId") else {
                throw ChannelMessageActionError.invalidParams("\(action.rawValue) requires messageId")
            }
            try await actions.unsend(peerID: peerID, messageID: messageID)
            return try AnyCodable(encoding: ActionResult(ok: true, action: action.rawValue, messageID: messageID))
        case .poll:
            guard let question = string("question", "pollQuestion") else {
                throw ChannelMessageActionError.invalidParams("poll requires question")
            }
            let options = (values["options"] ?? values["pollOptions"])?.arrayValue?.compactMap(\.stringValue) ?? []
            guard options.count >= 2 else {
                throw ChannelMessageActionError.invalidParams("poll requires at least two options")
            }
            let receipt = try await actions.sendPoll(
                peerID: peerID,
                question: question,
                options: options,
                allowMultiple: values["allowMultiple"]?.boolValue ?? values["multiple"]?.boolValue ?? false
            )
            return try AnyCodable(encoding: ActionResult(ok: true, action: action.rawValue, messageID: receipt?.primaryPlatformMessageID))
        case .send:
            throw ChannelMessageActionError.unsupported(action: action.rawValue, channel: channel)
        }
    }
}

private struct ActionResult: Encodable {
    let ok: Bool
    let action: String
    let messageID: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case action
        case messageID = "messageId"
    }
}

extension DiscordChannelAdapter: ChannelMessageActions {
    /// Adds or removes the bot's reaction (`PUT`/`DELETE /channels/{c}/messages/{m}/reactions/{emoji}/@me`).
    /// - Parameters:
    ///   - peerID: Channel id.
    ///   - messageID: Message id.
    ///   - emoji: Unicode emoji.
    ///   - remove: Whether to remove the reaction.
    public func react(peerID: String, messageID: String, emoji: String, remove: Bool) async throws {
        if remove {
            try await self.removeReaction(peerID: peerID, messageID: messageID, emoji: emoji)
        } else {
            try await self.addReaction(peerID: peerID, messageID: messageID, emoji: emoji)
        }
    }
}

/// Registers the `message.action` gateway method, routing actions through
/// ``ChannelRegistry/performAction(_:actionToggles:)``.
///
/// Opt-in: hosts whose gateway already serves `message.action` elsewhere should not call it.
/// - Parameters:
///   - registrar: Method registrar.
///   - registry: Adapter registry.
///   - actionToggles: Resolves per-channel `actions.*` toggles (default: every action enabled).
public func registerChannelMessageActionGatewayMethod(
    on registrar: some GatewayMethodRegistrar,
    registry: ChannelRegistry,
    actionToggles: @escaping @Sendable (ChannelID) async -> [String: Bool] = { _ in [:] }
) async {
    await registrar.register(method: "message.action") { request in
        let params = try request.decodeParams(MessageActionParams.self)
        var toggles: [String: Bool] = [:]
        if let channel = ChannelID(normalizing: params.channel) {
            toggles = await actionToggles(channel)
        }
        do {
            return try await registry.performAction(params, actionToggles: toggles)
        } catch let error as ChannelMessageActionError {
            switch error {
            case .invalidParams, .notCapable, .disabledByConfig:
                throw GatewayMethodError.invalidRequest(error.localizedDescription)
            case .unsupported:
                throw GatewayMethodError.unavailable(error.localizedDescription)
            }
        }
    }
}
