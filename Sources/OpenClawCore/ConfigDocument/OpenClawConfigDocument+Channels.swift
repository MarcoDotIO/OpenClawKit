import Foundation
import OpenClawProtocol

extension OpenClawConfigDocument {
    /// `channels`: channel defaults, per-channel model overrides, and plugin-owned channel blocks.
    ///
    /// This is the channels slice's lossless ``ChannelsConfigDocument`` (upstream `ChannelsSchema`,
    /// `.passthrough()`): `defaults` and `modelByChannel` are typed and every other key is a channel
    /// id holding that channel's block, kept raw. Import it into the SDK runtime model with
    /// ``ChannelsConfigDocument/channelsConfig``; project SDK settings back with
    /// ``ChannelsConfigDocument/init(exporting:preserving:)``.
    public typealias Channels = ChannelsConfigDocument

    /// Built-in channel ids with typed upstream schemas (every other `channels.<id>` block belongs
    /// to a channel plugin).
    public static let builtInChannelIDs: Set<String> = [
        "discord", "googlechat", "imessage", "irc", "msteams", "signal", "slack", "telegram", "whatsapp",
    ]

    /// Generic checks over every channel block and its `accounts.<id>` entries (upstream
    /// `ChannelsSchema` refinements): DM policy allowlists, multi-account defaults and the removed
    /// channel-local ACP bindings.
    /// - Parameter channels: Channels section.
    /// - Returns: Issues with dotted paths.
    static func channelValidationIssues(_ channels: Channels) -> [ConfigDecodeIssue] {
        var issues: [ConfigDecodeIssue] = []
        for (channelID, block) in channels.channels {
            let path = "channels.\(channelID)"
            let raw = block.raw
            let dmPolicy = raw["dmPolicy"]?.stringValue
            let allowFrom = Self.stringList(raw["allowFrom"])
            if dmPolicy == "open", !allowFrom.contains("*") {
                issues.append(Self.invalid("\(path).allowFrom", "dmPolicy \"open\" requires allowFrom to contain \"*\""))
            }
            if dmPolicy == "allowlist", allowFrom.isEmpty {
                issues.append(Self.invalid("\(path).allowFrom", "dmPolicy \"allowlist\" requires a non-empty allowFrom"))
            }
            let accounts = raw["accounts"]?.dictionaryValue ?? [:]
            let defaultAccount = raw["defaultAccount"]?.stringValue
            if accounts.count >= 2, defaultAccount == nil, accounts["default"] == nil {
                issues.append(Self.invalid(
                    "\(path).defaultAccount",
                    "\(path) has \(accounts.count) accounts without defaultAccount or accounts.default; "
                        + "fallback routing can pick an unexpected account"
                ))
            }
            if let defaultAccount, !accounts.isEmpty, accounts[defaultAccount] == nil {
                issues.append(Self.invalid(
                    "\(path).defaultAccount",
                    "\(path).defaultAccount names unknown account \"\(defaultAccount)\" "
                        + "(configured: \(accounts.keys.sorted().joined(separator: ", ")))"
                ))
            }
            if raw["bindings"]?.dictionaryValue?["acp"] != nil {
                issues.append(Self.invalid(
                    "\(path).bindings.acp",
                    "channel-local bindings.acp is not supported; use top-level bindings[] entries"
                ))
            }
        }
        return issues
    }

    private static func stringList(_ value: AnyCodable?) -> [String] {
        (value?.arrayValue ?? []).compactMap { entry in
            if let string = entry.stringValue {
                return string
            }
            if let int = entry.intValue {
                return String(int)
            }
            return entry.doubleValue.map(OpenClawJSON5.formatNumber)
        }
    }
}
