import Foundation
import Testing
@testable import OpenClawKit

/// Records every report (lock-protected so it can be shared across tasks).
final class RecordingStateReporter: OpenClawSystemStateReporting, @unchecked Sendable {
    enum Report: Equatable {
        case transition(OpenClawStateDomain, String?, OpenClawStateMetadata, OpenClawStateMetadata)
        case volatile(OpenClawStateDomain, OpenClawStateMetadata)
    }

    private let lock = NSLock()
    private var storage: [Report] = []

    var reports: [Report] {
        self.lock.withLock { self.storage }
    }

    var transitions: [(domain: OpenClawStateDomain, label: String?, stable: OpenClawStateMetadata, volatile: OpenClawStateMetadata)] {
        self.reports.compactMap { report in
            guard case let .transition(domain, label, stable, volatile) = report else { return nil }
            return (domain, label, stable, volatile)
        }
    }

    var labels: [String?] {
        self.transitions.map(\.label)
    }

    func reportTransition(
        _ domain: OpenClawStateDomain,
        to label: String?,
        stable: OpenClawStateMetadata,
        volatile: OpenClawStateMetadata)
    {
        self.lock.withLock { self.storage.append(.transition(domain, label, stable, volatile)) }
    }

    func reportVolatileUpdate(_ domain: OpenClawStateDomain, _ volatile: OpenClawStateMetadata) {
        self.lock.withLock { self.storage.append(.volatile(domain, volatile)) }
    }

    /// Every string that appears as a metadata value.
    var allStringValues: [String] {
        self.reports.flatMap { report -> [String] in
            switch report {
            case let .transition(_, label, stable, volatile):
                return [label].compactMap { $0 } + Self.strings(stable) + Self.strings(volatile)
            case let .volatile(_, volatile):
                return Self.strings(volatile)
            }
        }
    }

    private static func strings(_ metadata: OpenClawStateMetadata) -> [String] {
        metadata.flatMap { key, value -> [String] in
            if case let .string(text) = value { return [key, text] }
            return [key]
        }
    }
}

/// Mutable clock for coalescing tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000)

    var now: Date { self.lock.withLock { self.current } }

    func advance(_ seconds: TimeInterval) {
        self.lock.withLock { self.current = self.current.addingTimeInterval(seconds) }
    }
}

@Suite("System state reporting")
struct SystemStateReportingTests {
    private func event(_ name: String, metadata: [String: String] = [:], sessionKey: String? = "agent:main:main") -> RuntimeDiagnosticEvent {
        RuntimeDiagnosticEvent(subsystem: "runtime", name: name, runID: "run-1", sessionKey: sessionKey, metadata: metadata)
    }

    @Test
    func diagnosticSinkMapsRunLifecycleToAgentRunStates() async {
        let recorder = RecordingStateReporter()
        let sink = OpenClawSystemState.diagnosticSink(reporter: recorder)
        await sink(self.event("run.started", metadata: ["providerID": "openai"]))
        await sink(self.event("model.call.started", metadata: ["providerID": "openai", "modelID": "gpt-5"]))
        await sink(self.event("model.stream.chunk", metadata: ["chunkIndex": "3"]))
        await sink(self.event("model.call.completed", metadata: ["providerID": "openai", "latencyMs": "42"]))
        await sink(self.event("run.completed"))
        await sink(RuntimeDiagnosticEvent(subsystem: "channel", name: "run.started"))

        #expect(recorder.labels == ["running", "modelCall", "finalizing", nil])
        #expect(recorder.transitions.allSatisfy { $0.domain == .agentRun })
        let stable = recorder.transitions[1].stable
        #expect(stable["runId"] == "run-1")
        #expect(stable["providerID"] == "openai")
        #expect(stable["modelID"] == "gpt-5")
        guard case let .string(hash)? = stable["sessionKeyHash"] else {
            Issue.record("missing session key hash")
            return
        }
        #expect(hash.count == 16)
        #expect(hash == OpenClawSystemState.sessionKeyHash("agent:main:main"))
        #expect(recorder.transitions[2].volatile["latencyMs"] == .int(42))
        let volatileUpdates = recorder.reports.compactMap { report -> OpenClawStateMetadata? in
            if case let .volatile(.agentRun, metadata) = report { return metadata }
            return nil
        }
        #expect(volatileUpdates.count == 1)
        #expect(volatileUpdates.first?["chunkIndex"] == .int(3))
        if case .date? = volatileUpdates.first?["lastChunkAt"] {} else {
            Issue.record("expected a lastChunkAt date")
        }
    }

    @Test
    func diagnosticSinkReportsFailuresWithoutErrorText() async {
        let recorder = RecordingStateReporter()
        let sink = OpenClawSystemState.diagnosticSink(reporter: recorder)
        await sink(self.event(
            "run.failed",
            metadata: [
                "timedOut": "true",
                "error": "Authorization: Bearer sk-live-SECRET",
                "token": "tok_123",
                "providerID": "anthropic",
            ],
            sessionKey: "agent:main:telegram:dm:+15551234567"))

        #expect(recorder.labels == ["failed"])
        #expect(recorder.transitions[0].volatile["timedOut"] == .bool(true))
        let strings = recorder.allStringValues.joined(separator: "|")
        #expect(!strings.contains("SECRET"))
        #expect(!strings.contains("tok_123"))
        #expect(!strings.contains("+1555"))
        #expect(!strings.contains("telegram"))
        #expect(!strings.lowercased().contains("error"))
    }

    @Test
    func diagnosticSinkForwardsEveryEvent() async {
        let forwarded = RecordingStateReporter()
        let sink = OpenClawSystemState.diagnosticSink(reporter: NoopSystemStateReporter()) { event in
            forwarded.reportTransition(.agentRun, to: event.name)
        }
        await sink(self.event("run.started"))
        await sink(RuntimeDiagnosticEvent(subsystem: "channel", name: "outbound.sent"))
        #expect(forwarded.labels == ["run.started", "outbound.sent"])
    }

    @Test
    func coalescingReporterLimitsVolatileUpdatesAndFlushesBeforeTransitions() {
        let recorder = RecordingStateReporter()
        let clock = TestClock()
        let reporter = CoalescingSystemStateReporter(
            wrapping: recorder,
            minimumInterval: 1,
            scheduleTrailingFlush: false,
            now: { clock.now })

        reporter.reportTransition(.gateway, to: "connected", stable: ["role": "node"], volatile: [:])
        reporter.reportVolatileUpdate(.gateway, ["pendingRequests": 1])
        clock.advance(0.2)
        reporter.reportVolatileUpdate(.gateway, ["pendingRequests": 2])
        clock.advance(0.2)
        reporter.reportVolatileUpdate(.gateway, ["pendingRequests": 3])
        // Other domains are coalesced independently.
        reporter.reportVolatileUpdate(.talk, ["level": 1])
        #expect(recorder.reports == [
            .transition(.gateway, "connected", ["role": "node"], [:]),
            .volatile(.gateway, ["pendingRequests": 1]),
            .volatile(.talk, ["level": 1]),
        ])

        reporter.reportTransition(.gateway, to: "reconnecting", stable: ["role": "node"], volatile: ["backoffMs": 500])
        #expect(Array(recorder.reports.suffix(2)) == [
            .volatile(.gateway, ["pendingRequests": 3]),
            .transition(.gateway, "reconnecting", ["role": "node"], ["backoffMs": 500]),
        ])

        clock.advance(0.5)
        reporter.reportVolatileUpdate(.gateway, ["backoffMs": 1000])
        #expect(recorder.reports.last == .transition(.gateway, "reconnecting", ["role": "node"], ["backoffMs": 500]))
        clock.advance(0.6)
        reporter.reportVolatileUpdate(.gateway, ["backoffMs": 2000])
        #expect(recorder.reports.last == .volatile(.gateway, ["backoffMs": 2000]))

        clock.advance(0.1)
        reporter.reportVolatileUpdate(.gateway, ["backoffMs": 4000])
        reporter.flushPendingUpdates()
        #expect(recorder.reports.last == .volatile(.gateway, ["backoffMs": 4000]))
    }

    @Test(.timeLimit(.minutes(1)))
    func coalescingReporterSchedulesTrailingFlush() async throws {
        let recorder = RecordingStateReporter()
        // The clock stands still, so the second update always lands inside the interval; only the
        // trailing flush can forward it.
        let clock = TestClock()
        let reporter = CoalescingSystemStateReporter(wrapping: recorder, minimumInterval: 0.05, now: { clock.now })
        reporter.reportVolatileUpdate(.talk, ["level": 1])
        reporter.reportVolatileUpdate(.talk, ["level": 2])
        #expect(recorder.reports == [.volatile(.talk, ["level": 1])])
        try await waitUntil("trailing flush forwarded the held update") { recorder.reports.count >= 2 }
        #expect(recorder.reports == [.volatile(.talk, ["level": 1]), .volatile(.talk, ["level": 2])])
    }

    @Test
    func gatewayReporterWalksTheConnectionLifecycle() throws {
        let recorder = RecordingStateReporter()
        let url = try #require(URL(string: "wss://gateway.example.com:18789/ws"))
        let options = GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: [],
            commands: [],
            permissions: [:],
            clientId: "ios-app",
            clientMode: "node",
            clientDisplayName: "Phone")
        let reporter = OpenClawGatewayStateReporter(
            reporter: recorder,
            context: OpenClawGatewayStateContext(url: url, options: options, authSource: .deviceToken, tlsPinned: true))

        reporter.connecting()
        reporter.authenticating()
        reporter.connected(pendingRequests: 0, lastSeq: 7)
        reporter.reconnecting(backoffMs: 500, pendingRequests: 2)
        reporter.authPaused(authDetailCode: GatewayConnectAuthDetailCode.pairingRequired.rawValue)
        reporter.disconnected()

        #expect(recorder.labels == ["connecting", "authenticating", "connected", "reconnecting", "authPaused", nil])
        let stable = recorder.transitions[0].stable
        #expect(stable["role"] == "node")
        #expect(stable["clientMode"] == "node")
        #expect(stable["clientId"] == "ios-app")
        #expect(stable["authSource"] == "device-token")
        #expect(stable["protocolVersion"] == .int(GATEWAY_PROTOCOL_VERSION))
        #expect(stable["endpointKind"] == "remote")
        #expect(stable["tlsPinned"] == .bool(true))
        #expect(recorder.transitions[2].volatile == ["pendingRequests": 0, "lastSeq": 7])
        #expect(recorder.transitions[3].volatile == ["backoffMs": 500, "pendingRequests": 2])
        #expect(recorder.transitions[4].volatile == ["authDetailCode": "PAIRING_REQUIRED"])
        #expect(recorder.transitions[5].stable.isEmpty)
        #expect(!recorder.allStringValues.contains { $0.contains("example.com") })
    }

    @Test
    func endpointKindClassifiesWithoutKeepingTheHost() throws {
        #expect(OpenClawGatewayEndpointKind(url: try #require(URL(string: "ws://127.0.0.1:18789"))) == .loopback)
        #expect(OpenClawGatewayEndpointKind(url: try #require(URL(string: "ws://localhost:18789"))) == .loopback)
        #expect(OpenClawGatewayEndpointKind(url: try #require(URL(string: "ws://192.168.1.20:18789"))) == .lan)
        #expect(OpenClawGatewayEndpointKind(url: try #require(URL(string: "ws://studio.local:18789"))) == .lan)
        #expect(OpenClawGatewayEndpointKind(url: try #require(URL(string: "wss://gw.example.org"))) == .remote)
    }

    @Test
    func nodeInvokeAndTalkReportersUseTheirDomains() {
        let recorder = RecordingStateReporter()
        let invoke = OpenClawNodeInvokeStateReporter(reporter: recorder)
        invoke.invoking(command: "camera.snap", invokeId: "inv-1")
        invoke.finished(ok: true)
        let talk = OpenClawTalkStateReporter(reporter: recorder)
        talk.listening()
        talk.thinking()
        talk.speaking(provider: "system")
        talk.idle()

        #expect(recorder.reports == [
            .transition(.nodeInvoke, "invoking", ["command": "camera.snap", "invokeId": "inv-1"], [:]),
            .volatile(.nodeInvoke, ["ok": true]),
            .transition(.nodeInvoke, nil, [:], [:]),
            .transition(.talk, "listening", [:], [:]),
            .transition(.talk, "thinking", [:], [:]),
            .transition(.talk, "speaking", ["provider": "system"], [:]),
            .transition(.talk, nil, [:], [:]),
        ])
    }

    @Test
    func configReporterReportsCountsAndRevisionPrefixOnly() {
        let recorder = RecordingStateReporter()
        let issues = [
            ConfigDecodeIssue(path: "gateway.baseURL", message: "legacy key", kind: .legacyKey),
            ConfigDecodeIssue(path: "models.providers.x.api", message: "unknown", kind: .unknownEnumValue),
        ]
        let revision = OpenClawConfigHealthSnapshot.revisionHash(for: Data("{\"gateway\":{}}".utf8))
        let snapshot = OpenClawConfigHealthSnapshot(
            issues: issues,
            upstreamParityVersion: "2026.9.6",
            pathKind: .override,
            lastTouchedVersion: "2026.9.5",
            revisionHash: revision,
            migrationCount: 1)
        OpenClawConfigStateReporter(reporter: recorder).report(snapshot)
        OpenClawConfigStateReporter(reporter: recorder, isEnabled: false).report(snapshot)

        #expect(recorder.transitions.count == 1)
        let transition = recorder.transitions[0]
        #expect(transition.domain == .config)
        #expect(transition.label == "migrated")
        #expect(transition.stable == ["upstreamParityVersion": "2026.9.6", "configPathKind": "override"])
        #expect(transition.volatile["issueCount"] == .int(2))
        #expect(transition.volatile["legacyIssueCount"] == .int(1))
        #expect(transition.volatile["migrationCount"] == .int(1))
        #expect(transition.volatile["configRevisionHash"] == .string(String(revision.prefix(8))))
        #expect(!recorder.allStringValues.contains { $0.contains("baseURL") })
    }

    @Test
    func sanitizerDropsSensitiveKeysAndValues() {
        let sanitized = OpenClawSystemState.sanitized([
            "role": "node",
            "deviceToken": "abc",
            "gatewayURL": "wss://x",
            "note": "see https://example.com",
            "who": "person@example.com",
            "auth": "Bearer abc",
            "text": "hello",
            "count": 3,
            "long": .string(String(repeating: "a", count: 100)),
        ])
        #expect(sanitized["role"] == "node")
        #expect(sanitized["count"] == .int(3))
        #expect(sanitized["long"] == .string(String(repeating: "a", count: 64)))
        #expect(Set(sanitized.keys) == ["role", "count", "long"])
    }
}

@Suite("System state reporting gate", .serialized)
struct SystemStateReportingGateTests {
    @Test
    func gatedReporterHonorsIsEnabled() {
        let recorder = RecordingStateReporter()
        let gated = GatedSystemStateReporter(base: recorder)
        let original = OpenClawSystemState.isEnabled
        defer { OpenClawSystemState.isEnabled = original }

        OpenClawSystemState.isEnabled = false
        gated.reportTransition(.talk, to: "speaking")
        #expect(recorder.reports.isEmpty)

        OpenClawSystemState.isEnabled = true
        gated.reportTransition(.talk, to: "speaking", stable: ["provider": "system", "sessionToken": "x"], volatile: [:])
        gated.reportVolatileUpdate(.talk, ["level": 1])
        #expect(recorder.reports == [
            .transition(.talk, "speaking", ["provider": "system"], [:]),
            .volatile(.talk, ["level": 1]),
        ])
    }

    @Test
    func reportingIsOptInByDefaultAndResolveFallsBackToShared() {
        #expect(OpenClawSystemState.resolve(nil) is GatedSystemStateReporter)
        let recorder = RecordingStateReporter()
        #expect(OpenClawSystemState.resolve(recorder) is RecordingStateReporter)
    }

    @Test
    func appleReporterRegistersEachDomainOnce() {
        #if compiler(>=6.4) && canImport(StateReporting)
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) else { return }
        #expect(OpenClawSystemState.isSystemReportingAvailable)
        let first = AppleSystemStateReporter()
        let second = AppleSystemStateReporter()
        #expect(first.reporter(for: .gateway) === second.reporter(for: .gateway))
        #expect(first.reporter(for: .talk).domain == OpenClawStateDomain.talk.rawValue)
        first.reportTransition(.gateway, to: "connecting", stable: ["role": "node"], volatile: ["backoffMs": 500])
        first.reportVolatileUpdate(.gateway, ["pendingRequests": 1, "lastTickAt": .date(Date()), "ok": true, "ratio": 0.5])
        second.reportTransition(.gateway, to: nil, stable: [:], volatile: [:])
        let metadata = OpenClawReportableMetadata(["a": "b", "n": 2, "f": true])
        #expect(metadata.metadataDictionary.count == 3)
        #endif
    }
}
