import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

/// Projects the runtime's ``AgentEventFrame`` stream onto gateway events, from one subscription:
///
/// - every frame → `agent` (upstream `AgentEvent` payload, plus `sessionKey`);
/// - `assistant` deltas and the terminal `lifecycle` event → protocol-v4 `chat` events
///   (``ChatEventFrame``: `status` at start, `delta` with `deltaText`/`replace` and a message snapshot,
///   then `final`, `aborted` or `error` with `stopReason`, `usage`, `errorKind`);
/// - `tool` frames → `session.tool`, and transcript appends → `session.message`, for sessions a
///   connection subscribed to with `sessions.messages.subscribe`;
/// - `lifecycle` start/end/error → `sessions.changed` (`reason: "lifecycle"`, `phase`, `runId`,
///   `hasActiveRun`, `activeRunIds`, `status`, `startedAt`/`endedAt`/`runtimeMs`).
actor AgentGatewayEventBridge {
    private struct RunState {
        let sessionKey: String
        let agentID: String
        let spawnedBy: String?
        let startedAt: Int64
        var itemID: String?
        var itemText = ""
        var finalText = ""
        var broadcastText = ""
        var usage: [String: Int64] = [:]
    }

    private weak var server: GatewayServer?
    private weak var runtime: EmbeddedAgentRuntime?
    private let options: AgentGatewayOptions
    private var runs: [String: RunState] = [:]
    private var transcriptCursors: [String: Int] = [:]

    init(runtime: EmbeddedAgentRuntime, server: GatewayServer, options: AgentGatewayOptions) {
        self.runtime = runtime
        self.server = server
        self.options = options
    }

    /// Handles one runtime frame; frames of a run arrive in `seq` order.
    func handle(_ frame: AgentEventFrame) async {
        guard let server else { return }
        if self.options.forwardAgentEvents {
            await server.broadcast(event: GatewayEventName.agent.rawValue, payload: frame.gatewayPayload)
        }
        guard let sessionKey = frame.sessionKey else { return }
        switch frame.stream {
        case .lifecycle:
            await self.handleLifecycle(frame, sessionKey: sessionKey, server: server)
        case .assistant:
            await self.handleAssistant(frame, sessionKey: sessionKey, server: server)
        case .tool:
            await self.handleTool(frame, sessionKey: sessionKey, server: server)
        case .usage:
            var state = await self.state(for: frame, sessionKey: sessionKey)
            for key in ["input", "output", "cacheRead", "cacheWrite", "totalTokens"] {
                state.usage[key, default: 0] += frame.data[key]?.int64Value ?? 0
            }
            self.runs[frame.runID] = state
        default:
            break
        }
    }

    // MARK: - Lifecycle

    private func handleLifecycle(_ frame: AgentEventFrame, sessionKey: String, server: GatewayServer) async {
        switch frame.lifecyclePhase {
        case "start":
            let state = await self.state(for: frame, sessionKey: sessionKey)
            if self.options.forwardChatEvents {
                let status = ChatStatusEvent(
                    runid: frame.runID,
                    sessionkey: sessionKey,
                    agentid: state.agentID,
                    spawnedby: state.spawnedBy,
                    seq: frame.seq,
                    state: "status",
                    phase: .startingModel
                )
                await self.emitChat(.status(status), server: server)
            }
            if self.options.forwardSessionEvents {
                await self.syncTranscript(sessionKey: sessionKey, server: server)
                await self.emitLifecycleChange(frame, state: state, phase: "start", server: server)
            }
        case "end", "error":
            let state = await self.state(for: frame, sessionKey: sessionKey)
            self.runs[frame.runID] = nil
            if self.options.forwardChatEvents {
                await self.emitChat(self.terminalChatEvent(frame, state: state), server: server)
            }
            if self.options.forwardSessionEvents {
                await self.syncTranscript(sessionKey: sessionKey, server: server)
                await self.emitLifecycleChange(frame, state: state, phase: frame.lifecyclePhase ?? "end", server: server)
            }
        default:
            break
        }
    }

    private func terminalChatEvent(_ frame: AgentEventFrame, state: RunState) -> ChatEventFrame {
        let now = SessionTranscriptClock.nowMs()
        let message = state.finalText.isEmpty ? nil : ChatEventFrame.assistantMessage(text: state.finalText, timestampMs: now)
        let usage = state.usage.isEmpty ? nil : AnyCodable(state.usage.mapValues { AnyCodable($0) })
        if frame.lifecyclePhase == "end" {
            return .final(
                ChatFinalEvent(
                    runid: frame.runID,
                    sessionkey: state.sessionKey,
                    agentid: state.agentID,
                    spawnedby: state.spawnedBy,
                    seq: frame.seq,
                    state: "final",
                    message: message,
                    usage: usage,
                    stopreason: frame.data["stopReason"]?.stringValue ?? "stop",
                    yielded: frame.data["yielded"]?.boolValue == true ? true : nil
                )
            )
        }
        let errorMessage = frame.data["error"]?.stringValue
        if frame.data["aborted"]?.boolValue == true {
            return .aborted(
                ChatAbortedEvent(
                    runid: frame.runID,
                    sessionkey: state.sessionKey,
                    agentid: state.agentID,
                    spawnedby: state.spawnedBy,
                    seq: frame.seq,
                    state: "aborted",
                    message: message,
                    errormessage: errorMessage,
                    stopreason: "aborted"
                )
            )
        }
        let timedOut = frame.data["timedOut"]?.boolValue == true
        return .error(
            ChatErrorEvent(
                runid: frame.runID,
                sessionkey: state.sessionKey,
                agentid: state.agentID,
                spawnedby: state.spawnedBy,
                seq: frame.seq,
                state: "error",
                message: message,
                errormessage: errorMessage,
                errorkind: timedOut ? AnyCodable("timeout") : frame.data["errorKind"],
                errordetail: frame.data["errorDetail"]?.dictionaryValue,
                usage: usage,
                stopreason: timedOut ? "timeout" : "error"
            )
        )
    }

    private func emitLifecycleChange(_ frame: AgentEventFrame, state: RunState, phase: String, server: GatewayServer) async {
        // The runtime retires a run only after its terminal frame, so correct the snapshot for this run.
        var active = await self.runtime?.activeRunIDs(sessionKey: state.sessionKey) ?? []
        if phase == "start" {
            if !active.contains(frame.runID) { active.append(frame.runID) }
        } else {
            active.removeAll { $0 == frame.runID }
        }
        var extra: [String: AnyCodable] = [
            "agentId": AnyCodable(state.agentID),
            "phase": AnyCodable(phase),
            "runId": AnyCodable(frame.runID),
            "hasActiveRun": AnyCodable(!active.isEmpty),
            "activeRunIds": AnyCodable(active.map { AnyCodable($0) }),
            "startedAt": AnyCodable(state.startedAt),
        ]
        if let spawnedBy = state.spawnedBy {
            extra["spawnedBy"] = AnyCodable(spawnedBy)
        }
        switch phase {
        case "start":
            extra["status"] = AnyCodable("running")
        default:
            let endedAt = frame.data["endedAt"]?.int64Value ?? frame.ts
            let aborted = frame.data["aborted"]?.boolValue == true
            let timedOut = frame.data["timedOut"]?.boolValue == true
            extra["endedAt"] = AnyCodable(endedAt)
            extra["runtimeMs"] = AnyCodable(max(0, endedAt - state.startedAt))
            extra["updatedAt"] = AnyCodable(endedAt)
            extra["abortedLastRun"] = AnyCodable(aborted)
            extra["status"] = AnyCodable(phase == "end" ? "done" : (aborted ? "killed" : (timedOut ? "timeout" : "failed")))
            if phase == "error", let error = frame.data["error"]?.stringValue {
                extra["lastRunError"] = AnyCodable(error)
            }
        }
        await server.emitSessionsChanged(sessionKey: state.sessionKey, reason: "lifecycle", extra: extra)
    }

    // MARK: - Assistant

    private func handleAssistant(_ frame: AgentEventFrame, sessionKey: String, server: GatewayServer) async {
        var state = await self.state(for: frame, sessionKey: sessionKey)
        let itemID = frame.data["itemId"]?.stringValue
        let text = frame.data["text"]?.stringValue ?? ""
        if itemID != state.itemID {
            state.itemID = itemID
            state.itemText = ""
        }
        if frame.data["replace"]?.boolValue == true || !text.isEmpty {
            state.itemText = text
        } else if let delta = frame.data["delta"]?.stringValue {
            state.itemText += delta
        }
        if !state.itemText.isEmpty {
            state.finalText = state.itemText
        }
        let previous = state.broadcastText
        let delta = ChatEventFrame.broadcastDelta(text: state.itemText, previous: previous)
        if delta != nil {
            state.broadcastText = state.itemText
        }
        self.runs[frame.runID] = state
        guard self.options.forwardChatEvents, let delta, !state.itemText.isEmpty else { return }
        let event = ChatDeltaEvent(
            runid: frame.runID,
            sessionkey: sessionKey,
            agentid: state.agentID,
            spawnedby: state.spawnedBy,
            seq: frame.seq,
            state: "delta",
            message: ChatEventFrame.assistantMessage(text: state.itemText, timestampMs: frame.ts),
            deltatext: delta.deltaText,
            replace: delta.replace ? true : nil
        )
        await self.emitChat(.delta(event), server: server)
    }

    // MARK: - Tools and transcript

    private func handleTool(_ frame: AgentEventFrame, sessionKey: String, server: GatewayServer) async {
        guard self.options.forwardSessionEvents, await server.wantsSessionEvents(sessionKey: sessionKey) else { return }
        let state = await self.state(for: frame, sessionKey: sessionKey)
        var payload = frame.gatewayPayload.dictionaryValue ?? [:]
        payload["sessionKey"] = AnyCodable(sessionKey)
        payload["agentId"] = AnyCodable(state.agentID)
        await server.broadcast(event: GatewayEventName.sessionTool.rawValue, payload: AnyCodable(payload))
        let phase = frame.data["phase"]?.stringValue
        if phase == "start" || phase == "result" {
            await self.syncTranscript(sessionKey: sessionKey, server: server)
        }
    }

    /// Emits `session.message` for transcript rows appended since the last sync of the session.
    private func syncTranscript(sessionKey: String, server: GatewayServer) async {
        guard await server.wantsSessionEvents(sessionKey: sessionKey),
              let runtime, let store = runtime.transcriptStore
        else { return }
        let sessionID = await runtime.transcriptSessionID(for: sessionKey)
        guard let path = try? await store.activePath(sessionID: sessionID) else { return }
        let rows: [(id: String, message: AgentMessage)] = path.compactMap { entry in
            guard case .message(let message) = entry.payload else { return nil }
            if case .other("custom", let raw) = message, raw["display"]?.boolValue == false {
                return nil
            }
            return (entry.id, message)
        }
        let cursorKey = "\(sessionKey)\u{0}\(sessionID)"
        guard let cursor = self.transcriptCursors[cursorKey], cursor <= rows.count else {
            // First sync (or the active path moved backwards): start from the current tail.
            self.transcriptCursors[cursorKey] = rows.count
            return
        }
        guard cursor < rows.count else { return }
        let active = await runtime.activeRunIDs(sessionKey: sessionKey)
        let agentID = await self.agentID(sessionKey: sessionKey)
        for index in cursor..<rows.count {
            let row = rows[index]
            var payload: [String: AnyCodable] = [
                "sessionKey": AnyCodable(sessionKey),
                "agentId": AnyCodable(agentID),
                "sessionId": AnyCodable(sessionID),
                "messageId": AnyCodable(row.id),
                "messageSeq": AnyCodable(index + 1),
                "hasActiveRun": AnyCodable(!active.isEmpty),
                "activeRunIds": AnyCodable(active.map { AnyCodable($0) }),
            ]
            payload["message"] = (try? AnyCodable(encoding: row.message)) ?? .nullValue
            await server.broadcast(event: GatewayEventName.sessionMessage.rawValue, payload: AnyCodable(payload))
        }
        self.transcriptCursors[cursorKey] = rows.count
    }

    // MARK: - Helpers

    private func emitChat(_ event: ChatEventFrame, server: GatewayServer) async {
        guard let payload = try? event.payload() else { return }
        await server.broadcast(event: GatewayEventName.chat.rawValue, payload: payload)
    }

    private func state(for frame: AgentEventFrame, sessionKey: String) async -> RunState {
        if let existing = self.runs[frame.runID] {
            return existing
        }
        let state = RunState(
            sessionKey: sessionKey,
            agentID: await self.agentID(sessionKey: sessionKey),
            spawnedBy: frame.spawnedBy,
            startedAt: frame.data["startedAt"]?.int64Value ?? frame.ts
        )
        self.runs[frame.runID] = state
        return state
    }

    private func agentID(sessionKey: String) async -> String {
        if let record = await self.runtime?.sessionStore?.recordForKey(sessionKey) {
            return record.agentID
        }
        return SessionKey.agentID(from: sessionKey, fallback: self.runtime?.defaultAgentID ?? SessionKey.defaultAgentID)
    }
}
