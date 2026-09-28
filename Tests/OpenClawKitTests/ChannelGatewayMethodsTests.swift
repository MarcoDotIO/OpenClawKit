import Foundation
import Testing
@testable import OpenClawKit

@Suite("Channel control gateway methods")
struct ChannelGatewayMethodsTests {
    private static func newServer() -> GatewayServer {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-channel-gateway-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return GatewayServer(
            sessionStore: SessionStore(fileURL: root.appendingPathComponent("sessions.json")),
            secretVault: GatewaySecretVault(
                credentialStore: FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json")),
                indexURL: root.appendingPathComponent("secret-index.json")
            )
        )
    }

    private func makeServer(
        channels: ChannelsConfig = ChannelsConfig(telegram: TelegramChannelConfig(enabled: true, botToken: "t"))
    ) async throws -> (GatewayServer, ChannelRegistry, ChannelPairingStore) {
        let server = Self.newServer()
        let registry = ChannelRegistry()
        await registry.register(InMemoryChannelAdapter(id: .telegram))
        await registry.register(InMemoryChannelAdapter(id: .webchat))
        let store = ChannelPairingStore()
        await registerChannelGatewayMethods(
            on: server,
            context: ChannelGatewayContext(registry: registry, pairingStore: store, config: channels)
        )
        return (server, registry, store)
    }

    private func call(
        _ server: GatewayServer,
        _ method: String,
        _ params: [String: AnyCodable] = [:],
        connection: GatewayConnectionContext = .inProcess
    ) async -> ResponseFrame {
        let frame = RequestFrame(type: "req", id: UUID().uuidString, method: method, params: AnyCodable(AnySendableValue.object(params)))
        return await server.handle(frame, connection: connection)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: ResponseFrame) throws -> T {
        let data = try JSONEncoder().encode(try #require(response.payload))
        return try JSONDecoder().decode(type, from: data)
    }

    @Test
    func statusReportsCatalogMetadataAndHealthStates() async throws {
        let (server, registry, _) = try await self.makeServer()
        try await registry.start(id: .telegram)
        let response = await self.call(server, "channels.status", ["probe": AnyCodable(true)])
        #expect(response.ok)
        let report = try self.decode(ChannelsStatusReport.self, response)
        #expect(report.channelOrder.contains("telegram"))
        #expect(report.channelOrder.contains("webchat"))
        #expect(report.channelLabels["telegram"] == "Telegram")
        #expect(report.channelDetailLabels?["telegram"] == "Telegram Bot")
        #expect(report.channelSystemImages?["telegram"] == "paperplane")
        #expect(report.channelMeta?.first { $0.id == "webchat" }?.detailLabel == "WebChat")
        let telegram = try #require(report.channelAccounts["telegram"]?.first)
        #expect(telegram.accountID == "default")
        #expect(telegram.running == true)
        #expect(telegram.dmPolicy == "pairing")
        #expect(telegram.probe != nil)
        #expect(report.channelAccounts["webchat"]?.first?.healthState == "not-running")
        #expect(report.channelDefaultAccountID["telegram"] == "default")
        #expect(report.ts > 1_700_000_000_000)

        // Also decodes into the generated upstream model.
        let generated = try JSONDecoder().decode(ChannelsStatusResult.self, from: try JSONEncoder().encode(try #require(response.payload)))
        #expect(generated.channelorder == report.channelOrder)
    }

    @Test
    func statusReportsIssuesForConfiguredChannelsWithoutAdapters() async throws {
        var channels = ChannelsConfig()
        channels.extensionChannels["sms"] = AnyCodable(AnySendableValue.object(["accountSid": AnyCodable("AC1")]))
        channels.bluebubbles.enabled = true
        let (server, _, _) = try await self.makeServer(channels: channels)
        let report = try self.decode(ChannelsStatusReport.self, await self.call(server, "channels.status"))
        #expect(report.channelOrder.contains("sms"))
        let issues = report.statusIssues ?? []
        #expect(issues.contains { $0.channel == "sms" && $0.kind == .runtime })
        #expect(issues.contains { $0.channel == "bluebubbles" && $0.kind == .config && ($0.fix ?? "").contains("imessage") })
        let filtered = try self.decode(ChannelsStatusReport.self, await self.call(server, "channels.status", ["channel": AnyCodable("Telegram")]))
        #expect(filtered.channelOrder == ["telegram"])
    }

    @Test
    func startStopAndLogoutNormalizeChannelAliases() async throws {
        let (server, registry, _) = try await self.makeServer()
        let started = await self.call(server, "channels.start", ["channel": AnyCodable("Telegram")])
        #expect(started.ok)
        #expect(started.payload?.dictionaryValue?["started"] == AnyCodable(true))
        #expect(await registry.runtimeState(for: .telegram).running)
        let stopped = await self.call(server, "channels.stop", ["channel": AnyCodable("telegram")])
        #expect(stopped.payload?.dictionaryValue?["stopped"] == AnyCodable(true))
        let logout = await self.call(server, "channels.logout", ["channel": AnyCodable("telegram"), "accountId": AnyCodable("default")])
        #expect(logout.payload?.dictionaryValue?["cleared"] == AnyCodable(true))

        let unknown = await self.call(server, "channels.start", ["channel": AnyCodable("nope")])
        #expect(unknown.ok == false)
        #expect(unknown.error?.code == ErrorCode.invalidRequest.rawValue)
        let noAdapter = await self.call(server, "channels.start", ["channel": AnyCodable("slack")])
        #expect(noAdapter.error?.code == ErrorCode.unavailable.rawValue)

        let readOnly = GatewayConnectionContext(scopes: [GatewayConnectionContext.operatorReadScope])
        let forbidden = await self.call(server, "channels.stop", ["channel": AnyCodable("telegram")], connection: readOnly)
        #expect(forbidden.error?.code == ErrorCode.forbidden.rawValue)
        let allowedStatus = await self.call(server, "channels.status", connection: readOnly)
        #expect(allowedStatus.ok)
    }

    @Test
    func pairingListApproveAndDismiss() async throws {
        let (server, registry, store) = try await self.makeServer()
        try await registry.start(id: .telegram)
        _ = try await store.upsert(channel: .telegram, accountID: nil, senderID: "42", meta: ["name": "Ada"])
        _ = try await store.upsert(channel: .telegram, accountID: nil, senderID: "43")

        let listed = try self.decode(ChannelsPairingListReport.self, await self.call(server, "channels.pairing.list"))
        #expect(listed.accounts.contains { $0.channel == "telegram" && $0.accountID == "default" && $0.notifySupported })
        #expect(listed.requests.count == 2)
        #expect(listed.limits.pendingPerAccount == 3)
        #expect(listed.limits.ttlMs == 3_600_000)
        let ada = try #require(listed.requests.first { $0.senderID == "42" })
        #expect(ada.metadata?["name"] == "Ada")
        #expect(ada.senderLabel == "userId")
        #expect(ada.expiresAt > ada.createdAt)

        let approve = await self.call(
            server,
            "channels.pairing.approve",
            [
                "channel": AnyCodable("telegram"),
                "accountId": AnyCodable("default"),
                "requestId": AnyCodable(ada.requestID),
                "notify": AnyCodable(true),
            ]
        )
        let approved = try self.decode(ChannelsPairingApproveReport.self, approve)
        #expect(approved.senderID == "42")
        #expect(approved.notification == .sent)
        #expect(approved.commandOwnerBootstrap == .notRequested)
        #expect(try await store.approvedSenders(channel: .telegram, accountID: nil) == ["42"])

        let other = try #require(listed.requests.first { $0.senderID == "43" })
        let dismissed = try self.decode(
            ChannelsPairingDismissReport.self,
            await self.call(
                server,
                "channels.pairing.dismiss",
                ["channel": AnyCodable("telegram"), "accountId": AnyCodable("default"), "requestId": AnyCodable(other.requestID)]
            )
        )
        #expect(dismissed.senderID == "43")
        #expect(try await store.list(channel: .telegram).isEmpty)

        let missing = await self.call(
            server,
            "channels.pairing.approve",
            ["channel": AnyCodable("telegram"), "accountId": AnyCodable("default"), "requestId": AnyCodable("nope")]
        )
        #expect(missing.error?.code == ErrorCode.invalidRequest.rawValue)

        let pairingOnly = GatewayConnectionContext(scopes: ["operator.pairing"])
        let bootstrapDenied = await self.call(
            server,
            "channels.pairing.approve",
            [
                "channel": AnyCodable("telegram"),
                "accountId": AnyCodable("default"),
                "requestId": AnyCodable("x"),
                "bootstrapCommandOwner": AnyCodable(true),
            ],
            connection: pairingOnly
        )
        #expect(bootstrapDenied.error?.code == ErrorCode.forbidden.rawValue)
    }

    @Test
    func typedClientDecodesResponses() async throws {
        let (server, _, store) = try await self.makeServer()
        _ = try await store.upsert(channel: .telegram, accountID: nil, senderID: "99")
        let client = ChannelsGatewayClient { method, params in
            let frame = RequestFrame(
                type: "req",
                id: UUID().uuidString,
                method: method,
                params: params.map { AnyCodable(AnySendableValue.object($0)) }
            )
            let response = await server.handle(frame, connection: .inProcess)
            return try JSONEncoder().encode(response.payload ?? AnyCodable.nullValue)
        }
        let status = try await client.status()
        #expect(status.channelOrder.contains("telegram"))
        let list = try await client.pairingList(channel: "telegram")
        #expect(list.requests.first?.senderID == "99")
        let request = try #require(list.requests.first)
        let approved = try await client.pairingApprove(channel: "telegram", accountID: request.accountID, requestID: request.requestID)
        #expect(approved.notification == .notRequested)
    }

    @Test
    func messageActionsRouteToAdapters() async throws {
        let server = Self.newServer()
        let registry = ChannelRegistry()
        let adapter = InMemoryChannelAdapter(id: .telegram)
        try await adapter.start()
        await registry.register(adapter)
        await registerChannelMessageActionGatewayMethod(on: server, registry: registry)
        let send = await self.call(
            server,
            "message.action",
            [
                "channel": AnyCodable("telegram"),
                "action": AnyCodable("send"),
                "params": AnyCodable(AnySendableValue.object(["to": AnyCodable("123"), "text": AnyCodable("hello")])),
                "idempotencyKey": AnyCodable("k1"),
            ]
        )
        #expect(send.ok)
        #expect(await adapter.sentMessages().first?.text == "hello")
        let react = await self.call(
            server,
            "message.action",
            [
                "channel": AnyCodable("telegram"),
                "action": AnyCodable("react"),
                "params": AnyCodable(AnySendableValue.object(["to": AnyCodable("123"), "messageId": AnyCodable("1"), "emoji": AnyCodable("👍")])),
                "idempotencyKey": AnyCodable("k2"),
            ]
        )
        #expect(react.error?.code == ErrorCode.unavailable.rawValue)
        let poll = await self.call(
            server,
            "message.action",
            [
                "channel": AnyCodable("signal"),
                "action": AnyCodable("poll"),
                "params": AnyCodable(AnySendableValue.object(["to": AnyCodable("+1")])),
                "idempotencyKey": AnyCodable("k3"),
            ]
        )
        #expect(poll.error?.code == ErrorCode.invalidRequest.rawValue)
    }
}
