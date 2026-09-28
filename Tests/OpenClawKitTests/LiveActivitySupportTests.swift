import Foundation
import Testing
import OpenClawKit

@Suite("Live Activity support")
struct LiveActivitySupportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(_ status: OpenClawLiveActivityContentState.Status, session: String = "main") -> OpenClawLiveActivityPresentationRequest {
        OpenClawLiveActivityPresentationRequest(
            state: OpenClawLiveActivityContentState(status: status, verbatimDetail: nil, startedAt: self.now),
            staleDate: nil,
            agentName: "Aiden",
            sessionKey: session)
    }

    @Test
    func contentStateRoundTripsAndDecodesTheLegacySchema() throws {
        let state = OpenClawLiveActivityContentState(
            status: .toolRunning,
            verbatimDetail: nil,
            startedAt: self.now,
            agentBadge: "🐕",
            toolName: "exec",
            voiceSamples: [1, 2, 3])
        let decoded = try JSONDecoder().decode(OpenClawLiveActivityContentState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)

        let startedAt = try String(data: JSONEncoder().encode(self.now), encoding: .utf8) ?? "0"
        func legacy(_ fields: String) throws -> OpenClawLiveActivityContentState {
            try JSONDecoder().decode(
                OpenClawLiveActivityContentState.self,
                from: Data("{\"startedAt\":\(startedAt),\(fields)}".utf8))
        }
        #expect(try legacy("\"isDisconnected\":true").status == .disconnected)
        #expect(try legacy("\"isIdle\":true").status == .idle)
        #expect(try legacy("\"isConnecting\":true,\"statusText\":\"Reconnecting...\"").status == .reconnecting)
        #expect(try legacy("\"isConnecting\":true,\"statusText\":\"Pairing\"").verbatimDetail == "Pairing")
        #expect(try legacy("\"statusText\":\"Approval needed\"").status == .approvalNeeded)
        let other = try legacy("\"statusText\":\"Gateway busy\"")
        #expect(other.status == .attention)
        #expect(other.verbatimDetail == "Gateway busy")
    }

    @Test
    func arbiterPrefersAttentionThenToolsThenVoiceThenConnection() {
        var arbiter = OpenClawLiveActivityPresentationArbiter()
        #expect(arbiter.current == nil)
        arbiter.setConnection(self.request(.connecting))
        #expect(arbiter.current?.state.status == .connecting)
        arbiter.setVoice(self.request(.voiceSpeaking))
        #expect(arbiter.current?.state.status == .voiceSpeaking)
        arbiter.startTool(id: "t1", request: self.request(.toolRunning))
        #expect(arbiter.current?.state.status == .toolRunning)
        arbiter.setAttention(self.request(.approvalNeeded))
        #expect(arbiter.current?.state.status == .approvalNeeded)
        arbiter.setAttention(nil)
        arbiter.endTool(id: "t1", sessionKey: "main")
        #expect(arbiter.activeToolCount == 0)
        #expect(arbiter.current?.state.status == .voiceSpeaking)
        arbiter.clearAll()
        #expect(arbiter.current == nil)
    }

    @Test
    func connectionEventsFollowUpstreamLifecycleRules() {
        var arbiter = OpenClawLiveActivityPresentationArbiter()
        #expect(arbiter.apply(.connecting(attempt: 0), agentName: "Aiden", sessionKey: "main", now: self.now)?.state.status == .connecting)
        let reconnect = arbiter.apply(.connecting(attempt: 2), agentName: "Aiden", sessionKey: "main", now: self.now.addingTimeInterval(5))
        #expect(reconnect?.state.status == .reconnecting)
        #expect(reconnect?.state.startedAt == self.now)
        #expect(reconnect?.staleDate == self.now.addingTimeInterval(5 + OpenClawLiveActivityPresentationArbiter.connectingStaleInterval))

        // Plain problems do not show attention; approval-required and paused reconnects do.
        #expect(arbiter.apply(.problem(needsPairingApproval: false, pausesReconnect: false), agentName: "Aiden", sessionKey: "main")?
            .state.status == .reconnecting)
        #expect(arbiter.apply(.problem(needsPairingApproval: true, pausesReconnect: false), agentName: "Aiden", sessionKey: "main")?
            .state.status == .approvalNeeded)
        #expect(arbiter.apply(.problem(needsPairingApproval: false, pausesReconnect: true), agentName: "Aiden", sessionKey: "main")?
            .state.status == .actionRequired)

        // Connected ends the activity unless another producer still presents.
        #expect(arbiter.apply(.connected, agentName: "Aiden", sessionKey: "main") == nil)
        arbiter.startTool(id: "t", request: self.request(.toolRunning))
        #expect(arbiter.apply(.connected, agentName: "Aiden", sessionKey: "main")?.state.status == .toolRunning)
        #expect(arbiter.apply(.disconnected, agentName: "Aiden", sessionKey: "main") == nil)
        arbiter.setVoice(self.request(.voiceListening))
        #expect(arbiter.apply(.idle, agentName: "Aiden", sessionKey: "main") == nil)
    }

    @Test
    func voiceSampleBufferQuantizesAndBoundsSamples() {
        #expect(OpenClawLiveActivityVoiceSampleBuffer.quantize(nil) == nil)
        #expect(OpenClawLiveActivityVoiceSampleBuffer.quantize(.nan) == nil)
        #expect(OpenClawLiveActivityVoiceSampleBuffer.quantize(-1) == 0)
        #expect(OpenClawLiveActivityVoiceSampleBuffer.quantize(0.5) == 128)
        #expect(OpenClawLiveActivityVoiceSampleBuffer.quantize(2) == 255)
        var buffer = OpenClawLiveActivityVoiceSampleBuffer(capacity: 3)
        #expect(buffer.payload == nil)
        for sample: UInt8 in [1, 2, 3, 4] {
            buffer.append(sample)
        }
        #expect(buffer.payload == [2, 3, 4])
        buffer.reset()
        #expect(buffer.payload == nil)
    }

    @Test
    func runReducerMapsDiagnosticsToActivityUpdates() {
        var reducer = OpenClawAgentRunActivityReducer()
        func event(_ name: String, _ metadata: [String: String] = [:]) -> RuntimeDiagnosticEvent {
            RuntimeDiagnosticEvent(subsystem: "runtime", name: name, runID: "run-9", sessionKey: "main", occurredAt: self.now, metadata: metadata)
        }
        #expect(reducer.reduce(event("model.call.completed")) == nil) // unknown run
        guard case let .upsert(runID, sessionKey, started)? = reducer.reduce(event("run.started")) else {
            Issue.record("expected upsert")
            return
        }
        #expect(runID == "run-9")
        #expect(sessionKey == "main")
        #expect(started.phase == .running)
        #expect(started.progress == 0.05)
        guard case let .upsert(_, _, modelCall)? = reducer.reduce(event("model.call.started", ["providerID": "openai"])) else {
            Issue.record("expected upsert")
            return
        }
        #expect(modelCall.detail == "Provider: openai")
        guard case let .upsert(_, _, finishing)? = reducer.reduce(event("model.call.completed")) else {
            Issue.record("expected upsert")
            return
        }
        #expect(finishing.progress == 0.65)
        #expect(reducer.reduce(event("run.completed")) == .end(
            runID: "run-9",
            sessionKey: "main",
            state: OpenClawAgentRunActivityContentState(phase: .completed, detail: "Run completed", progress: 1, updatedAt: self.now),
            immediately: false))
        _ = reducer.reduce(event("run.started"))
        guard case let .end(_, _, failed, immediately)? = reducer.reduce(event("run.failed", ["timedOut": "true", "error": "secret"])) else {
            Issue.record("expected end")
            return
        }
        #expect(immediately)
        #expect(failed.detail == "Run timed out")
    }
}
