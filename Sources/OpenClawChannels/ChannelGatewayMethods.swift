import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

/// Command-owner bootstrap hook result used by `channels.pairing.approve`.
public typealias ChannelCommandOwnerBootstrap = @Sendable (_ channel: ChannelID, _ accountID: String, _ senderID: String) async
    -> ChannelsPairingApproveReport.CommandOwnerBootstrap

/// Dependencies of the channel control gateway methods.
public struct ChannelGatewayContext: Sendable {
    /// Adapter registry.
    public var registry: ChannelRegistry
    /// DM pairing store (share it with ``AutoReplyEngine/pairingStore``).
    public var pairingStore: ChannelPairingStore
    /// Current channel config.
    public var channelsConfig: @Sendable () async -> ChannelsConfig
    /// Whether a command owner is configured (upstream `commands.ownerAllowFrom`).
    public var commandOwnerConfigured: @Sendable () async -> Bool
    /// Optional command-owner bootstrap used when `bootstrapCommandOwner` is requested.
    public var bootstrapCommandOwner: ChannelCommandOwnerBootstrap?
    /// Text sent to an approved sender when `notify` is requested.
    public var approvalNotificationText: String

    /// Creates a context.
    /// - Parameters:
    ///   - registry: Adapter registry.
    ///   - pairingStore: DM pairing store.
    ///   - channelsConfig: Current channel config provider.
    ///   - commandOwnerConfigured: Whether a command owner is configured.
    ///   - bootstrapCommandOwner: Optional command-owner bootstrap.
    ///   - approvalNotificationText: Approval notification text.
    public init(
        registry: ChannelRegistry,
        pairingStore: ChannelPairingStore,
        channelsConfig: @escaping @Sendable () async -> ChannelsConfig,
        commandOwnerConfigured: @escaping @Sendable () async -> Bool = { false },
        bootstrapCommandOwner: ChannelCommandOwnerBootstrap? = nil,
        approvalNotificationText: String = "OpenClaw: access approved. You can message this bot now."
    ) {
        self.registry = registry
        self.pairingStore = pairingStore
        self.channelsConfig = channelsConfig
        self.commandOwnerConfigured = commandOwnerConfigured
        self.bootstrapCommandOwner = bootstrapCommandOwner
        self.approvalNotificationText = approvalNotificationText
    }

    /// Creates a context over a fixed channel config.
    /// - Parameters:
    ///   - registry: Adapter registry.
    ///   - pairingStore: DM pairing store.
    ///   - config: Channel config.
    public init(registry: ChannelRegistry, pairingStore: ChannelPairingStore, config: ChannelsConfig) {
        self.init(registry: registry, pairingStore: pairingStore, channelsConfig: { config })
    }
}

/// Registers `channels.status`, `channels.start`, `channels.stop`, `channels.logout` and
/// `channels.pairing.list/approve/dismiss` on a gateway method registrar (for example
/// ``GatewayServer``), backed by ``ChannelRegistry``, the channel metadata catalog and
/// ``ChannelPairingStore``.
///
/// Scopes come from the upstream method catalog (`operator.read` for status, `operator.admin`
/// for start/stop/logout, `operator.pairing` for pairing; approve additionally requires
/// `operator.admin` when `bootstrapCommandOwner` is set).
/// - Parameters:
///   - registrar: Method registrar.
///   - context: Channel dependencies.
public func registerChannelGatewayMethods(on registrar: some GatewayMethodRegistrar, context: ChannelGatewayContext) async {
    let handlers = ChannelGatewayHandlers(context: context)
    await registrar.register(method: "channels.status") { request in
        try await handlers.status(request)
    }
    await registrar.register(method: "channels.start") { request in
        try await handlers.lifecycle(request, action: .start)
    }
    await registrar.register(method: "channels.stop") { request in
        try await handlers.lifecycle(request, action: .stop)
    }
    await registrar.register(method: "channels.logout") { request in
        try await handlers.lifecycle(request, action: .logout)
    }
    await registrar.register(method: "channels.pairing.list") { request in
        try await handlers.pairingList(request)
    }
    await registrar.register(method: "channels.pairing.approve") { request in
        try await handlers.pairingApprove(request)
    }
    await registrar.register(method: "channels.pairing.dismiss") { request in
        try await handlers.pairingDismiss(request)
    }
}

/// Channel control method implementations (exposed for direct unit testing).
public struct ChannelGatewayHandlers: Sendable {
    /// Lifecycle action for `channels.start/stop/logout`.
    public enum LifecycleAction: String, Sendable {
        /// `channels.start`.
        case start
        /// `channels.stop`.
        case stop
        /// `channels.logout`.
        case logout
    }

    /// Maximum `statusIssues` entries (upstream schema `maxItems`).
    public static let maxStatusIssues = 50

    let context: ChannelGatewayContext

    /// Creates handlers.
    /// - Parameter context: Channel dependencies.
    public init(context: ChannelGatewayContext) {
        self.context = context
    }

    // MARK: channels.status

    /// Builds the typed `channels.status` report.
    /// - Parameters:
    ///   - probe: Whether to probe adapters.
    ///   - timeoutMs: Probe timeout.
    ///   - channelFilter: Optional channel filter.
    /// - Returns: Status report.
    public func statusReport(probe: Bool = false, timeoutMs: Int = 10_000, channelFilter: ChannelID? = nil) async -> ChannelsStatusReport {
        let config = await self.context.channelsConfig()
        let registered = Set(await self.context.registry.adapterIDs())
        let entries = OpenClawChannelMetadataCatalog.orderedEntries.filter { entry in
            if let channelFilter { return entry.id == channelFilter }
            return registered.contains(entry.id) || config.isChannelEnabled(entry.id.rawValue)
        }
        var labels: [String: String] = [:]
        var detailLabels: [String: String] = [:]
        var systemImages: [String: String] = [:]
        var meta: [ChannelUIMeta] = []
        var summaries: [String: ChannelStatusSummary] = [:]
        var accounts: [String: [ChannelAccountStatusSnapshot]] = [:]
        var defaultAccounts: [String: String] = [:]
        var issues: [ChannelStatusIssue] = []

        for entry in entries {
            let id = entry.id.rawValue
            labels[id] = entry.label
            detailLabels[id] = entry.resolvedDetailLabel
            if let image = entry.systemImage {
                systemImages[id] = image
            }
            meta.append(ChannelUIMeta(id: id, label: entry.label, detailLabel: entry.resolvedDetailLabel, systemImage: entry.systemImage))

            let isRegistered = registered.contains(entry.id)
            let configured = config.isChannelEnabled(id)
            let policy = config.messagingPolicy(for: id)
            let health = await self.context.registry.healthSnapshot(for: entry.id)
            var runtime = await self.context.registry.runtimeState(for: entry.id)
            if probe, isRegistered {
                runtime.lastProbe = await self.context.registry.probe(id: entry.id, timeoutMs: timeoutMs)
            }
            let healthState = Self.healthState(registered: isRegistered, runtime: runtime, health: health)
            var snapshot = ChannelAccountStatusSnapshot(
                accountID: "default",
                enabled: configured,
                configured: configured || isRegistered,
                running: runtime.running,
                connected: runtime.running && health.status != .offline,
                lastError: health.lastError ?? runtime.lastError,
                healthState: healthState
            )
            snapshot.lastInboundAt = runtime.lastInboundAt.map(Self.epochMs)
            snapshot.lastOutboundAt = runtime.lastOutboundAt.map(Self.epochMs)
            snapshot.lastStartAt = runtime.lastStartAt.map(Self.epochMs)
            snapshot.lastStopAt = runtime.lastStopAt.map(Self.epochMs)
            snapshot.dmPolicy = entry.distribution == .core ? nil : policy.effectiveDMPolicy.rawValue
            snapshot.allowFrom = policy.allowFrom
            if let probeResult = runtime.lastProbe {
                snapshot.lastProbeAt = Self.epochMs(probeResult.probedAt)
                snapshot.probe = try? AnyCodable(encoding: probeResult)
            }
            Self.applyChannelFields(&snapshot, channel: entry.id, config: config)
            var channelAccounts = [snapshot]
            for accountID in Self.configuredAccountIDs(for: entry.id, config: config) where accountID != "default" {
                let accountPolicy = config.messagingPolicy(for: id, accountID: accountID)
                var account = ChannelAccountStatusSnapshot(
                    accountID: accountID,
                    enabled: configured,
                    configured: true,
                    running: false,
                    connected: false,
                    healthState: "not-running"
                )
                account.dmPolicy = accountPolicy.effectiveDMPolicy.rawValue
                account.allowFrom = accountPolicy.allowFrom
                channelAccounts.append(account)
            }
            accounts[id] = channelAccounts
            defaultAccounts[id] = Self.defaultAccountID(for: entry.id, config: config)
            summaries[id] = ChannelStatusSummary(
                configured: configured || isRegistered,
                running: runtime.running,
                connected: snapshot.connected ?? false,
                lastError: snapshot.lastError
            )
            issues.append(contentsOf: Self.statusIssues(entry: entry, registered: isRegistered, configured: configured, policy: policy, health: health))
        }

        return ChannelsStatusReport(
            ts: Self.epochMs(Date()),
            channelOrder: entries.map(\.id.rawValue),
            channelLabels: labels,
            channelDetailLabels: detailLabels,
            channelSystemImages: systemImages,
            channelMeta: meta,
            channels: summaries,
            channelAccounts: accounts,
            channelDefaultAccountID: defaultAccounts,
            statusIssues: issues.isEmpty ? nil : Array(issues.prefix(Self.maxStatusIssues))
        )
    }

    func status(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let params = request.params
        var filter: ChannelID?
        if let raw = request.stringParam("channel") {
            guard let id = ChannelID(normalizing: raw) else {
                throw GatewayMethodError.invalidRequest("unknown channel: \(raw)")
            }
            filter = id
        }
        let probe = params["probe"]?.boolValue ?? false
        let timeoutMs = params["timeoutMs"]?.intValue ?? 10_000
        let report = await self.statusReport(probe: probe, timeoutMs: max(1, timeoutMs), channelFilter: filter)
        return try AnyCodable(encoding: report)
    }

    // MARK: channels.start / stop / logout

    func lifecycle(_ request: GatewayMethodRequest, action: LifecycleAction) async throws -> AnyCodable? {
        let channel = try Self.requireChannel(request)
        let accountID = request.stringParam("accountId", "accountID") ?? "default"
        guard await self.context.registry.hasAdapter(id: channel) else {
            throw GatewayMethodError.unavailable("channel \(channel.rawValue) has no native adapter registered")
        }
        var payload: [String: AnyCodable] = [
            "channel": AnyCodable(channel.rawValue),
            "accountId": AnyCodable(accountID),
        ]
        switch action {
        case .start:
            do {
                try await self.context.registry.start(id: channel)
                payload["started"] = AnyCodable(true)
                payload["outcome"] = AnyCodable("started")
            } catch {
                payload["started"] = AnyCodable(false)
                payload["outcome"] = AnyCodable("failed")
                let issue = ChannelStatusIssue(
                    channel: channel.rawValue,
                    accountID: accountID,
                    kind: .runtime,
                    message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                )
                payload["statusIssues"] = try AnyCodable(encoding: [issue])
            }
        case .stop:
            try await self.context.registry.stop(id: channel)
            payload["stopped"] = AnyCodable(!(await self.context.registry.runtimeState(for: channel).running))
        case .logout:
            try await self.context.registry.logout(id: channel)
            payload["cleared"] = AnyCodable(true)
            payload["loggedOut"] = AnyCodable(true)
        }
        return AnyCodable(AnySendableValue.object(payload))
    }

    // MARK: channels.pairing.*

    /// Builds the typed `channels.pairing.list` report.
    /// - Parameters:
    ///   - channel: Channel filter.
    ///   - accountID: Account filter.
    /// - Returns: List report.
    public func pairingListReport(channel: ChannelID? = nil, accountID: String? = nil) async throws -> ChannelsPairingListReport {
        let config = await self.context.channelsConfig()
        let registered = Set(await self.context.registry.adapterIDs())
        var accounts: [ChannelPairingAccountInfo] = []
        for entry in OpenClawChannelMetadataCatalog.orderedEntries where entry.distribution != .core {
            if let channel, entry.id != channel { continue }
            guard registered.contains(entry.id) || config.isChannelEnabled(entry.id.rawValue) else { continue }
            let accountIDs = ["default"] + Self.configuredAccountIDs(for: entry.id, config: config).filter { $0 != "default" }
            for account in accountIDs {
                if let accountID, ChannelPairingStore.normalizeAccountID(accountID) != account { continue }
                let policy = config.messagingPolicy(for: entry.id.rawValue, accountID: account)
                guard policy.effectiveDMPolicy == .pairing else { continue }
                accounts.append(
                    ChannelPairingAccountInfo(
                        channel: entry.id.rawValue,
                        channelLabel: entry.label,
                        accountID: account,
                        notifySupported: registered.contains(entry.id)
                    )
                )
            }
        }
        let listings = try await self.context.pairingStore.list(channel: channel, accountID: accountID)
        let requests = listings.map { listing in
            let request = listing.request
            let metadata = request.meta.filter { $0.key != "accountId" && $0.key != "senderId" && !$0.value.isEmpty }
            return ChannelPairingRequestInfo(
                requestID: listing.requestID,
                channel: listing.channel.rawValue,
                channelLabel: listing.channel.metadata.label,
                accountID: request.accountID,
                senderID: request.meta["senderId"] ?? request.id,
                senderLabel: "userId",
                metadata: metadata.isEmpty ? nil : metadata,
                createdAt: request.createdAt,
                lastSeenAt: request.lastSeenAt,
                expiresAt: request.expiresAt.map(ChannelPairingStore.formatTimestamp) ?? request.createdAt,
                notifySupported: registered.contains(listing.channel)
            )
        }
        return ChannelsPairingListReport(
            accounts: accounts,
            requests: requests,
            commandOwnerConfigured: await self.context.commandOwnerConfigured(),
            limits: ChannelsPairingListReport.Limits(
                pendingPerAccount: ChannelPairingStore.maxPendingPerAccount,
                ttlMs: ChannelPairingStore.pendingTTLMs
            )
        )
    }

    func pairingList(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let channel = try request.stringParam("channel").map { raw -> ChannelID in
            guard let id = ChannelID(normalizing: raw) else {
                throw GatewayMethodError.invalidRequest("unknown channel: \(raw)")
            }
            return id
        }
        let report = try await self.pairingListReport(channel: channel, accountID: request.stringParam("accountId"))
        return try AnyCodable(encoding: report)
    }

    func pairingApprove(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let bootstrap = request.params["bootstrapCommandOwner"]?.boolValue ?? false
        let requiredScope = bootstrap ? GatewayConnectionContext.operatorAdminScope : "operator.pairing"
        guard request.connection.allows(scope: requiredScope) else {
            throw GatewayMethodError.missingScope(requiredScope)
        }
        let channel = try Self.requireChannel(request)
        guard let accountID = request.stringParam("accountId"), let requestID = request.stringParam("requestId") else {
            throw GatewayMethodError.invalidRequest("channels.pairing.approve requires accountId and requestId")
        }
        guard let approved = try await self.context.pairingStore.approve(channel: channel, accountID: accountID, requestID: requestID) else {
            throw GatewayMethodError.invalidRequest("pairing request not found or expired: \(requestID)")
        }
        let senderID = approved.meta["senderId"] ?? approved.id
        var notification = ChannelsPairingApproveReport.Notification.notRequested
        if request.params["notify"]?.boolValue == true {
            if await self.context.registry.hasAdapter(id: channel) {
                do {
                    try await self.context.registry.send(
                        OutboundMessage(
                            channel: channel,
                            accountID: accountID == "default" ? nil : accountID,
                            peerID: senderID,
                            text: self.context.approvalNotificationText,
                            chatType: .direct
                        )
                    )
                    notification = .sent
                } catch {
                    notification = .failed
                }
            } else {
                notification = .unsupported
            }
        }
        var commandOwnerBootstrap = ChannelsPairingApproveReport.CommandOwnerBootstrap.notRequested
        if bootstrap {
            if let hook = self.context.bootstrapCommandOwner {
                commandOwnerBootstrap = await hook(channel, approved.accountID, senderID)
            } else {
                commandOwnerBootstrap = await self.context.commandOwnerConfigured() ? .alreadyConfigured : .unavailable
            }
        }
        return try AnyCodable(
            encoding: ChannelsPairingApproveReport(
                requestID: requestID,
                senderID: senderID,
                notification: notification,
                commandOwnerBootstrap: commandOwnerBootstrap
            )
        )
    }

    func pairingDismiss(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let channel = try Self.requireChannel(request)
        guard let accountID = request.stringParam("accountId"), let requestID = request.stringParam("requestId") else {
            throw GatewayMethodError.invalidRequest("channels.pairing.dismiss requires accountId and requestId")
        }
        guard let dismissed = try await self.context.pairingStore.dismiss(channel: channel, accountID: accountID, requestID: requestID) else {
            throw GatewayMethodError.invalidRequest("pairing request not found or expired: \(requestID)")
        }
        return try AnyCodable(
            encoding: ChannelsPairingDismissReport(requestID: requestID, senderID: dismissed.meta["senderId"] ?? dismissed.id)
        )
    }

    // MARK: Helpers

    static func requireChannel(_ request: GatewayMethodRequest) throws -> ChannelID {
        guard let raw = request.stringParam("channel") else {
            throw GatewayMethodError.invalidRequest("\(request.method) requires channel")
        }
        guard let id = ChannelID(normalizing: raw) else {
            throw GatewayMethodError.invalidRequest("unknown channel: \(raw)")
        }
        return id
    }

    /// Maps registry state onto the health vocabulary the macOS app understands.
    static func healthState(registered: Bool, runtime: ChannelRuntimeState, health: ChannelHealthSnapshot) -> String {
        guard registered, runtime.running else {
            return "not-running"
        }
        switch health.status {
        case .healthy:
            return "healthy"
        case .degraded:
            return "disconnected"
        case .offline:
            return health.consecutiveFailures > 0 ? "blocked" : "healthy"
        }
    }

    static func epochMs(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func configuredAccountIDs(for channel: ChannelID, config: ChannelsConfig) -> [String] {
        let ids: [String]
        switch channel {
        case .discord: ids = config.discord.accountIDs
        case .telegram: ids = config.telegram.accountIDs
        case .whatsapp: ids = config.whatsappCloud.accountIDs
        case .slack: ids = config.slack.accountIDs
        case .googlechat: ids = config.googleChat.accountIDs
        case .signal: ids = config.signal.accountIDs
        case .imessage: ids = config.imessage.accountIDs
        case .msteams: ids = config.msteams.accountIDs
        default:
            ids = (config.rawSection(named: channel.rawValue)?["accounts"]?.dictionaryValue?.keys).map { $0.sorted() } ?? []
        }
        return ids.map { $0.lowercased() }
    }

    static func defaultAccountID(for channel: ChannelID, config: ChannelsConfig) -> String {
        let raw: String?
        switch channel {
        case .discord: raw = config.discord.defaultAccount
        case .telegram: raw = config.telegram.defaultAccount
        case .whatsapp: raw = config.whatsappCloud.defaultAccount
        case .slack: raw = config.slack.defaultAccount
        case .googlechat: raw = config.googleChat.defaultAccount
        case .signal: raw = config.signal.defaultAccount
        case .imessage: raw = config.imessage.defaultAccount
        case .msteams: raw = config.msteams.defaultAccount
        default: raw = config.rawSection(named: channel.rawValue)?["defaultAccount"]?.stringValue
        }
        return ChannelPairingStore.normalizeAccountID(raw)
    }

    static func applyChannelFields(_ snapshot: inout ChannelAccountStatusSnapshot, channel: ChannelID, config: ChannelsConfig) {
        switch channel {
        case .telegram:
            snapshot.baseURL = config.telegram.baseURL
            snapshot.mode = "polling"
        case .slack:
            snapshot.mode = config.slack.mode.rawValue
            snapshot.webhookPath = config.slack.mode == .http ? config.slack.webhookPath : nil
            snapshot.baseURL = config.slack.baseURL
        case .googlechat:
            snapshot.webhookPath = config.googleChat.webhookPath
            snapshot.baseURL = config.googleChat.baseURL
        case .whatsapp:
            snapshot.webhookPath = config.whatsappCloud.webhookPath
            snapshot.baseURL = config.whatsappCloud.baseURL
            snapshot.mode = "cloud-api"
        case .signal:
            snapshot.baseURL = config.signal.serviceURL
        case .msteams:
            snapshot.baseURL = config.msteams.serviceURL
        case .webchat:
            snapshot.webhookPath = config.webchat.webhookPath
        default:
            break
        }
    }

    static func statusIssues(
        entry: ChannelMetadataEntry,
        registered: Bool,
        configured: Bool,
        policy: ChannelMessagingPolicyConfig,
        health: ChannelHealthSnapshot
    ) -> [ChannelStatusIssue] {
        let id = entry.id.rawValue
        var issues: [ChannelStatusIssue] = []
        if configured, !registered {
            let message = entry.nativeTransportAvailable
                ? "\(entry.label) is enabled in config but no adapter is registered."
                : "\(entry.label) has no native Swift transport: \(entry.nativeUnavailableReason ?? "plugin-only channel")."
            issues.append(ChannelStatusIssue(channel: id, kind: .runtime, message: message))
        }
        if case .removed(let replacement, let docs) = entry.status, configured || registered {
            issues.append(
                ChannelStatusIssue(
                    channel: id,
                    kind: .config,
                    message: "\(entry.label) was removed upstream.",
                    fix: replacement.map { "Migrate to \($0.rawValue)" + (docs.map { " (see \($0))" } ?? "") + "." }
                )
            )
        }
        if entry.distribution != .core, policy.dmPolicy == .open, !(policy.allowFrom ?? []).contains("*"), policy.allowFrom != nil {
            issues.append(
                ChannelStatusIssue(
                    channel: id,
                    kind: .config,
                    message: "dmPolicy \"open\" requires allowFrom to contain \"*\".",
                    fix: "Add \"*\" to channels.\(id).allowFrom or switch dmPolicy to allowlist."
                )
            )
        }
        if registered, health.status == .offline, health.consecutiveFailures > 0, let lastError = health.lastError {
            issues.append(ChannelStatusIssue(channel: id, kind: .runtime, message: lastError))
        }
        return issues
    }
}
